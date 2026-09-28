-- Keeps the fisherman profession and its trades intact once VoxeLibre's own
-- activity loop sees a jobsite it cannot validate. `do_activity` (called from
-- inside the vanilla `do_custom` this file wraps) runs `validate_jobsite`
-- every ~5s; when `_jobsite` does not resolve, `remove_job`
-- (mobs_mc/villager.lua:1240) clears it and, for a villager that has never
-- traded, also resets `_profession` to "unemployed" and wipes `_trades`.
-- Barrels are no longer required for this profession (#7), so a fallback
-- fisherman has no jobsite by design, and even a barrel-employed one loses
-- jobsite proximity the moment it walks to the water to fish (#72). Both
-- would otherwise be un-professioned within one activity tick.
--
-- Fisherman is for life: this guard never demotes one, so nothing here needs
-- to distinguish a barrel fisherman from a fallback one.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local FISH_SEARCH_RADIUS = 32
-- Asymmetric vertically, matching navigation.lua's promotion search: a lake
-- below the villager's own standing height is common, water above is rare.
local FISH_BELOW_BAND = 6
local FISH_ABOVE_BAND = 2
local FISH_RETRY_INTERVAL = 5
-- Fishing cycle (#73): cast, then wait for a bite, then reel in. Trades
-- restock once per completed cycle, so its length is also the restock rate.
local CAST_SECONDS = 2
local WAIT_SECONDS = 8
local REEL_SECONDS = 2
local BOBBER_ENTITY = "villages:bobber"
local BOBBER_DISTANCE = 2
local BOBBER_HEIGHT = 0.15

core.register_entity(BOBBER_ENTITY, {
	initial_properties = {
		visual = "sprite",
		visual_size = {x = 0.3, y = 0.3},
		textures = {"mcl_fishing_bobber.png"},
		physical = false,
		pointable = false,
		static_save = false,
		collisionbox = {0, 0, 0, 0, 0, 0},
	},
})

local function should_flag(self)
	return not self.child and self._profession == "fisherman"
end

local SHORE_NEIGHBOR_OFFSETS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

local function is_liquid(pos)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	return def ~= nil and def.liquidtype and def.liquidtype ~= "none"
end

-- navigation.lua's approaches() only checks a fishing spot's own four
-- cardinal neighbors (cardinal_only), at the anchor tile's own height, for
-- an open+supported stand -- not the shore in general. A tile picked purely
-- by straight-line distance can land a tile or two into open water, or at a
-- lake corner whose only nearby dry ground is diagonal, and every one of
-- its neighbors would then be water too: navigation.lua would find zero
-- candidates and retry that same doomed tile forever, even with an
-- obviously fishable shore nearby (#72 follow-up). Requiring at least one
-- non-liquid cardinal neighbor here is a cheap proxy for the same shape of
-- check, so a tile without one is skipped before it ever reaches gopath.
local function has_dry_neighbor(pos)
	for _, offset in ipairs(SHORE_NEIGHBOR_OFFSETS) do
		local neighbor = {x = pos.x + offset[1], y = pos.y, z = pos.z + offset[2]}
		if not is_liquid(neighbor) then return true end
	end
	return false
end

-- The nearest surface water tile within range is only an anchor: navigation.lua
-- turns it into an actual stand by finding an open, supported position
-- cardinally adjacent to it (#72).
local function nearest_water(self)
	local pos = self.object:get_pos()
	if not pos then return nil end
	local minp = {x = pos.x - FISH_SEARCH_RADIUS, y = pos.y - FISH_BELOW_BAND, z = pos.z - FISH_SEARCH_RADIUS}
	local maxp = {x = pos.x + FISH_SEARCH_RADIUS, y = pos.y + FISH_ABOVE_BAND, z = pos.z + FISH_SEARCH_RADIUS}
	local best, best_distance
	for _, site in ipairs(core.find_nodes_in_area(minp, maxp, {"group:water"})) do
		if common.is_surface_water(site) and has_dry_neighbor(site) then
			local distance = vector.distance(pos, site)
			if not best_distance or distance < best_distance then best, best_distance = site, distance end
		end
	end
	return best
end

-- A short-lived bobber, a couple of nodes out from the stand toward the
-- water tile that anchored the trip. Not mcl_fishing:bobber_entity -- its
-- on_step is player-coupled -- but its texture is the game's own asset.
local function bobber_position(self)
	local pos = self.object:get_pos()
	local water = self._villages_fish_target
	if not pos or not water then return nil end
	local dx, dz = water.x - pos.x, water.z - pos.z
	local length = math.sqrt(dx * dx + dz * dz)
	if length == 0 then return {x = water.x, y = water.y + BOBBER_HEIGHT, z = water.z} end
	local scale = BOBBER_DISTANCE / length
	return {x = pos.x + dx * scale, y = water.y + BOBBER_HEIGHT, z = pos.z + dz * scale}
end

local function spawn_bobber(self)
	local pos = bobber_position(self)
	return pos and core.add_entity(pos, BOBBER_ENTITY) or nil
end

-- The bobber must not outlive its session, including when the fisherman is
-- unloaded mid-session (def.on_deactivate below); an invalid ObjectRef's
-- get_pos() returns nil rather than erroring, matching the liveness check
-- already used throughout this mod for self.object.
local function remove_bobber(self)
	local bobber = self._villages_fish_bobber
	self._villages_fish_bobber = nil
	if bobber and bobber:get_pos() then bobber:remove() end
end

-- Mirrors mobs_mc/villager.lua's file-local unlock_trades: unlock any locked
-- trade at or below the villager's current max tier and leave the rest. That
-- function is only about twenty lines with no engine coupling, so it is
-- replicated here rather than reached into, since a jobsiteless fisherman
-- never runs through do_work (villager.lua:1301), the only place vanilla
-- calls it from.
local function restock_trades(self)
	if not self._trades or not core.deserialize or not core.serialize then return end
	local trades = core.deserialize(self._trades)
	if type(trades) ~= "table" then return end
	local max_tier = self._max_trade_tier or 1
	local unlocked = false
	for _, trade in pairs(trades) do
		if type(trade) == "table" and trade.locked == true and (trade.tier or 0) <= max_tier then
			trade.locked = false
			trade.trade_counter = 0
			unlocked = true
		end
	end
	if unlocked then self._trades = core.serialize(trades) end
end

-- Face the water once, on arrival, the same way init.lua's sleep_position
-- turns a facedir into a yaw: atan2 the direction, then rotate a quarter turn
-- since the model's forward axis is offset from the raw direction vector.
-- Routed through the mob's own set_yaw (init.lua:196's note) rather than
-- object:set_yaw, so it does not fight check_smooth_rotation every tick.
local function face_water(self, mob_set_yaw, stand_pos)
	local water = self._villages_fish_target
	if not water or not stand_pos then return end
	local dx, dz = water.x - stand_pos.x, water.z - stand_pos.z
	if dx == 0 and dz == 0 then return end
	mob_set_yaw(self, atan2(dz, dx) + math.pi / 2)
end

-- mobs_mc/villager.lua's do_states_stand (run from inside vanilla's own
-- do_custom, called as original_custom before this file's own code) rolls a
-- chance to switch a standing villager to "walk" every second, and only
-- skips that roll while self.order is "stand", "sleep", or "work" --
-- otherwise a periodic player scan there can even reset walk_chance back up
-- from under a session that never touched it. Nothing else here held the
-- villager in place, so the fisherman could wander off mid-session while the
-- bobber stayed behind at the water. Re-pin every tick a session is active,
-- the same way init.lua's sleep pose re-pins position/velocity/yaw each
-- tick against that file's own periodic overrides.
local function hold_still(self)
	self.state = "stand"
	self.order = "stand"
	self.object:set_velocity(vector.zero())
end

local function start_fishing_session(self, mob_set_yaw, stand_pos)
	face_water(self, mob_set_yaw, stand_pos)
	self._villages_fish_session = {
		phase = "cast", phase_ends_at = core.get_gametime() + CAST_SECONDS,
		previous_order = self.order,
	}
	hold_still(self)
end

-- Drop the target and its (by now "arrived", never "travelling" again)
-- route along with the session. Otherwise the fisherman would be stuck once
-- work resumes: the travel trigger below only calls gopath again when the
-- target is nil, and an "arrived" route never satisfies the retry check that
-- clears an existing one. Restore whatever order the villager held before
-- the session pinned it to "stand", so ending a session does not strand a
-- villager that, say, arrived here mid work-order.
local function end_fishing_session(self)
	local session = self._villages_fish_session
	remove_bobber(self)
	if session then self.order = session.previous_order end
	self._villages_fish_session = nil
	self._villages_fish_target = nil
	self._villages_fish_route = nil
end

local function advance_fishing_session(self)
	local session = self._villages_fish_session
	local now = core.get_gametime()
	if now < session.phase_ends_at then return end
	if session.phase == "cast" then
		session.phase, session.phase_ends_at = "wait", now + WAIT_SECONDS
		self._villages_fish_bobber = spawn_bobber(self)
	elseif session.phase == "wait" then
		session.phase, session.phase_ends_at = "reel", now + REEL_SECONDS
	else
		remove_bobber(self)
		restock_trades(self)
		session.phase, session.phase_ends_at = "cast", now + CAST_SECONDS
	end
end

-- A claim made during the wrapped call already mutated real node meta via
-- vanilla's own employ() (mobs_mc/villager.lua:1150); release it rather than
-- leave a node permanently locked to a fisherman who will never work it.
local function release_stray_claim(self, jobsite)
	local meta = core.get_meta(jobsite)
	if meta and meta:get_string("villager") == self._id then
		meta:set_string("villager", "")
	end
end

return function(def)
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_deactivate = def.on_deactivate
	local mob_set_yaw = def.set_yaw or mcl_mobs.mob_class.set_yaw

	-- A villager already employed as a fisherman when its mapblock loads
	-- (existing barrel fishermen, or one #71 promoted before a save) needs
	-- the flag restored; it is not itself part of the saved fields. A
	-- fishing session's phase/timer would survive a reload through the
	-- generic staticdata copy (mcl_mobs/api.lua:87 keeps plain tables), but
	-- its bobber (an ObjectRef, dropped by that same copy since it is
	-- userdata) would not, so drop the whole session rather than resume one
	-- with no visible bobber.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if should_flag(self) then
			self._villages_fisherman = true
		end
		self._villages_fish_session = nil
		self._villages_fish_bobber = nil
		return result
	end

	-- The bobber is a separate entity near the water, not necessarily in the
	-- mapblock that is unloading the fisherman itself; do_custom stops
	-- running the moment this villager unloads, so nothing else would ever
	-- remove it (#73).
	def.on_deactivate = function(self, removal)
		if original_deactivate then original_deactivate(self, removal) end
		if self._villages_fish_session then remove_bobber(self) end
	end

	def.do_custom = function(self, dtime)
		if not self._villages_fisherman then
			return original_custom(self, dtime)
		end
		local profession, trades, jobsite = self._profession, self._trades, self._jobsite
		local result = original_custom(self, dtime)

		-- Fisherman is for life: always restore the profession and its
		-- trades, whatever vanilla changed them to. An untraded fallback
		-- fisherman reaches get_a_job() through the same
		-- `_profession == "unemployed"` branch as any other jobless
		-- villager -- remove_job sets that before do_activity checks it,
		-- inside the very call this wraps -- and unlike a traded
		-- villager's request list (narrowed to its own profession's
		-- jobsite type), an untraded one's covers every profession's
		-- jobsite type. A fisherman standing beside so much as a composter
		-- can be employed straight into "farmer".
		self._profession = profession
		if trades ~= nil and self._trades == nil then self._trades = trades end

		-- A jobsite that is new (was nil, or a different position, before
		-- this call) came from that same employ() call. Keep it if it is a
		-- jobsite this profession would have wanted anyway -- a barrel --
		-- since that is a harmless, legitimate claim; otherwise release it.
		if self._jobsite and (not jobsite or not vector.equals(self._jobsite, jobsite)) then
			local node = core.get_node_or_nil(self._jobsite)
			local matches_profession = node and common.workstation_profession(node.name) == "fisherman"
			if not matches_profession then
				release_stray_claim(self, self._jobsite)
				self._jobsite = nil
			end
		end

		-- Never resurrect a jobsite vanilla invalidated. validate_jobsite
		-- (mobs_mc/villager.lua:1256) only clears `_jobsite` after the
		-- node's own meta already failed an ownership check --
		-- RESETTLE_DISTANCE clears that meta itself first, and every other
		-- path only reaches remove_job because the check had already
		-- failed. `retrieve_my_jobsite` never fails for any other reason
		-- (mobs_mc/villager.lua:1223), so restoring the old position here
		-- could never make next tick's check pass again; it would only
		-- recreate a dangling reference to a claim that is already gone,
		-- or, worse, since the node itself remains genuinely unclaimed,
		-- one another villager may since have taken. A fisherman with no
		-- jobsite is already this mod's intended steady state.

		-- Drive the fishing cycle once at the water's edge, or send the
		-- fisherman there in the first place whenever it is not already
		-- headed somewhere and work time allows it. Both a fallback fisherman
		-- (no jobsite) and a barrel-employed one make this trip; a barrel only
		-- grants the profession, not an exemption from fishing at the shore.
		if not self.child and self._id then
			if self._villages_fish_session then
				-- Re-pin every tick, even one about to end the session below:
				-- vanilla's own do_custom (already run this tick, above) may
				-- have nudged the villager toward walking before this code
				-- gets a say.
				hold_still(self)
				-- A session ends the moment any of its three conditions stops
				-- holding (following, work time, or the water it anchored on).
				-- Work time already covers both nightfall and thunder, since
				-- neither is ever inside an is_work_time() window.
				if self.following or not common.is_work_time()
					or not (self._villages_fish_target and common.is_surface_water(self._villages_fish_target)) then
					end_fishing_session(self)
				else
					advance_fishing_session(self)
				end
			elseif common.is_work_time() and self.state ~= "gowp" then
				if self._villages_fish_target then
					local route = self._villages_fish_route
					if route and route.status == "retry" and core.get_gametime() >= route.retry_at then
						self._villages_fish_target = nil
						self._villages_fish_route = nil
					end
				elseif core.get_gametime() >= (self._villages_fish_next or 0) then
					local water = nearest_water(self)
					if water then
						-- Keep the target even if gopath fails to start: navigation.lua
						-- already recorded a retry route with its own backoff, and the
						-- branch above throttles on that once it exists. Clearing the
						-- target here instead would rescan and retry every tick for the
						-- whole cooldown (a stand-occupied failure is common by design).
						self._villages_fish_target = vector.new(water)
						self:gopath(water, function(entity, stand_pos)
							start_fishing_session(entity, mob_set_yaw, stand_pos)
						end, true)
					else
						self._villages_fish_next = core.get_gametime() + FISH_RETRY_INTERVAL
					end
				end
			end
		end

		return result
	end
end
