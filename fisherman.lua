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
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")
-- A trade list with one traded entry, in the form core.deserialize reads.
local TRADED = "return {{traded_once = true, tier = 0}}"
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
local BOBBER_ENTITY = "living_villages:bobber"
local BOBBER_DISTANCE = 2
-- The bobber (#227) sits on the water, not in it. The sprite is
-- mcl_fishing_bobber.png scaled to BOBBER_SIZE; its float fills rows 2-13 of
-- the 16 and its stem rows 8-13 (read from the png), so the visible part is
-- centred on the sprite's own centre, at most 6 px = 6/16 * BOBBER_SIZE above
-- and below it. The anchor is a water node's centre, and the surface of a
-- source is at most WATER_TOP above that. Raising the sprite centre
-- BOBBER_LIFT above the surface leaves the stem's foot (6 px down) just
-- under it and the float head clear above. The old offset of 0.15 from the
-- node centre put the whole float 0.24 or more under the surface.
local BOBBER_SIZE = 0.3
local WATER_TOP = 0.5
local BOBBER_LIFT = 0.05
local BOBBER_HEIGHT = WATER_TOP + BOBBER_LIFT

core.register_entity(BOBBER_ENTITY, {
	initial_properties = {
		visual = "sprite",
		visual_size = {x = BOBBER_SIZE, y = BOBBER_SIZE},
		textures = {"mcl_fishing_bobber.png"},
		physical = false,
		pointable = false,
		static_save = false,
		collisionbox = {0, 0, 0, 0, 0, 0},
	},
})

-- #87: a held rod for the fishing cycle. mcl_mobs has no wielditem support
-- (see the issue), so this is its own attached entity -- the same pattern
-- mobs_mc/witch.lua uses for its held potion/wand (an entity whose textures
-- are the item's own itemstring, which the engine renders as that item's
-- image; unlike a "sprite" visual (the bobber above), this rotates with its
-- parent instead of always billboarding toward the camera, which a held
-- tool needs). The visual is "item", not witch.lua's "wielditem": the two
-- differ in which image the engine extrudes -- "wielditem" prefers the
-- item's wield_image, and mcl_fishing defines that as
-- "mcl_fishing_fishing_rod.png^[transformFY^[transformR90", i.e. the icon
-- flipped and turned a quarter turn for in-hand use. That baked-in
-- transform is why rotating the rod kept producing angles that made no
-- sense against the artwork. "item" extrudes the plain inventory_image
-- instead, which already draws the wanted pose outright: wooden rod angled
-- up, line hanging off the tip down to a bobber.
-- living_villages_villager.b3d has no witch-style "Wield_R" hand bone to attach
-- to, and no separate left/right arm bones either: the whole crossed-arms
-- pose is rigged onto a single bone named plain "arm" (a child of "body"),
-- which drives two mirrored vertex clusters -- one per hand -- in the
-- model's one shared mesh. (A `strings` dump of the file also turns up an
-- "evo_arm.right", but that name belongs to the model's ROOT node, not an
-- arm -- a red herring confirmed by parsing the b3d's actual NODE chunk
-- tree.) ROD_POSITION is the right-hand vertex cluster's position, read
-- from the mesh's own VRTS/BONE (skin weight) data and converted from
-- mesh space into "arm"'s bone-local space (undoing its rest transform,
-- composed through its parent "body") to get what set_attach expects.
-- ROD_ROTATION then aims that image: upright, and pointing forward over
-- the water rather than sideways across the body. Both fall out of the
-- bone's own frame, since the attach rotation is applied in it. "arm"'s
-- rest rotation is a 180 degree turn about (0, 0.376, 0.927) -- a 44.17
-- degree tilt in the yz plane, in matrix terms -- and composing its
-- inverse with a quarter turn about the vertical axis lands the item's up
-- axis (local +y, the orientation a dropped item stands in at zero
-- rotation) on world up, and its right axis -- the direction the drawn rod
-- points -- on the model's +z, the side the nose is on. So the rod angles
-- up and forward, out over the water the villager is facing.
--
-- ROD_POSITION is then lifted half the sprite's height (~0.3 node, scaled
-- into mesh units and rotated into the bone's frame) above the hand
-- cluster itself: the item's origin is its own center, so attaching at the
-- hand exactly would hang half the rod below it.
local FISHING_ROD_ENTITY = "living_villages:fishing_rod"
local FISHING_ROD_ITEM = "mcl_fishing:fishing_rod"
local ROD_BONE = "arm"
local ROD_POSITION = vector.new(-3.21, 1.74, 0.91)
local ROD_ROTATION = vector.new(90, -45.83, 90)

core.register_entity(FISHING_ROD_ENTITY, {
	initial_properties = {
		visual = "item",
		visual_size = {x = 0.4, y = 0.4},
		textures = {FISHING_ROD_ITEM},
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

-- navigation.lua's approaches() only checks a fishing spot's own four
-- cardinal neighbors (cardinal_only), at the anchor tile's own height and
-- one above it (raised_ok), for an open+supported stand -- not the shore in
-- general. A tile picked purely by straight-line distance can land a tile
-- or two into open water, at a lake corner whose only nearby dry ground is
-- diagonal, or against a steep bank with no standable ground at either
-- height: navigation.lua would then find zero candidates and retry that
-- same doomed tile forever, even with an obviously fishable shore nearby
-- (#72 follow-up). A merely non-liquid neighbor is not enough to rule that
-- out -- a wall or a cliff face is non-liquid too, and so is a sand or dirt
-- shore that meets the water at the water's own height, whose walkable
-- surface -- and the stand on it -- is the block above, not beside. This
-- asks cells.lua, the same classifier navigation.lua uses, rather than a
-- weaker proxy, and skips a tile without at least one cardinal candidate at either
-- height before it ever reaches gopath.
local APPROACH_HEIGHTS = {0, 1}

local function has_open_approach(pos)
	for _, offset in ipairs(SHORE_NEIGHBOR_OFFSETS) do
		for _, dy in ipairs(APPROACH_HEIGHTS) do
			local candidate = {x = pos.x + offset[1], y = pos.y + dy, z = pos.z + offset[2]}
			if cells.is_open(candidate, {thin = true})
				and cells.is_open({x = candidate.x, y = candidate.y + 1, z = candidate.z})
				and cells.has_floor(candidate) then
				return true
			end
		end
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
		if common.is_surface_water(site) and has_open_approach(site) then
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

-- Skip attaching entirely when mcl_fishing (an optional dependency) is not
-- enabled, rather than attaching a wielditem-visual entity for an item that
-- does not exist -- mirrors how the bobber already just reuses mcl_fishing's
-- own texture and accepts looking wrong without it, but a missing wielditem
-- itemstring is a worse failure than a missing texture, so this degrades to
-- no rod at all instead.
local function spawn_fishing_rod(self)
	if not core.registered_items[FISHING_ROD_ITEM] then return nil end
	local pos = self.object:get_pos()
	if not pos then return nil end
	local rod = core.add_entity(pos, FISHING_ROD_ENTITY)
	if rod then rod:set_attach(self.object, ROD_BONE, ROD_POSITION, ROD_ROTATION) end
	return rod
end

-- Mirrors remove_bobber's liveness check and its on_deactivate handling
-- below: static_save = false means an unloaded rod would not persist either
-- way, but removing it explicitly avoids relying on engine behavior for
-- attached entities on their parent's unload.
local function remove_fishing_rod(self)
	local rod = self._villages_fish_rod
	self._villages_fish_rod = nil
	if rod and rod:get_pos() then rod:remove() end
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

-- Face the water using mob_class:turn_in_direction (mcl_mobs/movement.lua),
-- the same method do_states_stand itself uses to turn a standing villager
-- toward a nearby player -- already the proven-correct yaw convention for
-- this model in its standing pose, rather than the quarter-turn correction
-- init.lua's sleep_position needs for the (different) sleeping pose, which
-- an earlier version of this function wrongly copied and got backwards for
-- some directions (facing away, or sideways, depending on which way the
-- water actually was). turn_in_direction itself routes through set_yaw, so
-- it does not fight check_smooth_rotation every tick either.
local function face_water(self, turn_in_direction, stand_pos)
	local water = self._villages_fish_target
	if not water or not stand_pos then return end
	local dx, dz = water.x - stand_pos.x, water.z - stand_pos.z
	if dx == 0 and dz == 0 then return end
	turn_in_direction(self, dx, dz)
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
--
-- do_states_stand's "look at a nearby player, or turn randomly" behavior is
-- not gated by order at all (only the walk roll is), so it can turn the
-- villager away from the water on any tick even though the walk fix above
-- already holds it in place; re-derive facing from the route's own
-- recorded stand every tick too, not just once on arrival.
-- Mirrors mobs_mc/villager.lua's has_traded, on a serialized trade list.
local function has_traded(serialized)
	local trades = serialized and core.deserialize(serialized)
	if type(trades) ~= "table" then return false end
	for _, trade in pairs(trades) do
		if trade.traded_once then return true end
	end
	return false
end

local function hold_still(self, turn_in_direction)
	self.state = "stand"
	self.order = "stand"
	self.object:set_velocity(vector.zero())
	local route = self._villages_fish_route
	face_water(self, turn_in_direction, route and route.target)
end

local function start_fishing_session(self, turn_in_direction)
	self._villages_fish_session = {
		phase = "cast", phase_ends_at = core.get_gametime() + CAST_SECONDS,
		previous_order = self.order,
	}
	self._villages_fish_rod = spawn_fishing_rod(self)
	hold_still(self, turn_in_direction)
end

-- Drop the target and its (by now "arrived", never "travelling" again)
-- route along with the session. Otherwise the fisherman would be stuck once
-- work resumes: the travel trigger below only calls gopath again when the
-- target is nil, and an "arrived" route never satisfies the retry check that
-- clears an existing one. Restore whatever order the villager held before
-- the session pinned it to "stand", so ending a session does not strand a
-- villager that, say, arrived here mid work-order -- but only if order is
-- still that "stand" pin: navigation's own do_custom (already run this
-- tick, above, before this file's own code sees the session-ending
-- condition at all) may have just started a fresh, more urgent order of its
-- own this very tick -- e.g. "sleep" for a bed trip the instant work ends
-- -- which must not be clobbered by restoring a now-stale prior one.
local function end_fishing_session(self)
	local session = self._villages_fish_session
	remove_bobber(self)
	remove_fishing_rod(self)
	if session and self.order == "stand" then self.order = session.previous_order end
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
	local turn_in_direction = def.turn_in_direction or mcl_mobs.mob_class.turn_in_direction

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
		self._villages_fish_rod = nil
		return result
	end

	-- The bobber is a separate entity near the water, not necessarily in the
	-- mapblock that is unloading the fisherman itself; do_custom stops
	-- running the moment this villager unloads, so nothing else would ever
	-- remove it (#73). The rod (#87) is attached to the fisherman itself, so
	-- it would unload alongside it either way, but is cleaned up here too
	-- rather than relying on that.
	def.on_deactivate = function(self, removal)
		if original_deactivate then original_deactivate(self, removal) end
		if self._villages_fish_session then
			remove_bobber(self)
			remove_fishing_rod(self)
		end
	end

	def.do_custom = function(self, dtime)
		if not self._villages_fisherman then
			return original_custom(self, dtime)
		end
		local profession, trades, jobsite = self._profession, self._trades, self._jobsite
		-- A fallback fisherman that has not traded is demoted by remove_job,
		-- and in that same do_activity call get_a_job walks it toward the
		-- nearest free workstation of any type (#110); the restore below
		-- cannot cancel that path. Showing vanilla a traded-looking trade
		-- list stops the demotion, so get_a_job only looks for barrels.
		-- Also with a jobsite, which validate_jobsite may drop mid-call (a
		-- barrel fisherman fishing past RESETTLE_DISTANCE). The entry has
		-- tier 0 and nothing locked so do_work's unlock_trades, which reads
		-- both, passes over it.
		local stand_in = not has_traded(trades)
		if stand_in then self._trades = TRADED end
		local result = original_custom(self, dtime)
		if stand_in then self._trades = trades end

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
				-- A session ends the moment any of its three conditions
				-- stops holding (following, work time, or the water it
				-- anchored on). Work time already covers both nightfall and
				-- thunder, since neither is ever inside an is_work_time()
				-- window. Check these before touching anything: navigation's
				-- own do_custom (already run this tick, above) may have just
				-- started a bed/follow action of its own the moment one of
				-- these flipped, and that action must be left alone, not
				-- immediately stomped by hold_still and then orphaned by
				-- end_fishing_session restoring a now-stale prior order.
				if self.following or not common.is_work_time(self)
					or not (self._villages_fish_target and common.is_surface_water(self._villages_fish_target)) then
					end_fishing_session(self)
				else
					hold_still(self, turn_in_direction)
					advance_fishing_session(self)
					-- mcl_mobs/api.lua only calls do_states() -- whose
					-- do_states_stand unconditionally turns a standing
					-- villager toward a nearby player or a random direction,
					-- unlike its walk roll, not gated by order at all --
					-- when do_custom does not return false, the same way
					-- the sleep pose (init.lua) already suppresses it while
					-- active. Without this, hold_still's facing/state pin
					-- above is undone again before this tick ever renders.
					return false
				end
			elseif common.is_work_time(self) and self.state ~= "gowp" then
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
						self:gopath(water, function(entity)
							start_fishing_session(entity, turn_in_direction)
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
