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
local FISH_SEARCH_RADIUS = 16
local FISH_RETRY_INTERVAL = 5

local function should_flag(self)
	return not self.child and self._profession == "fisherman"
end

-- The nearest surface water tile within range is only an anchor: navigation.lua
-- turns it into an actual stand by finding an open, supported position
-- cardinally adjacent to it (#72).
local function nearest_water(self)
	local pos = self.object:get_pos()
	if not pos then return nil end
	local minp = {x = pos.x - FISH_SEARCH_RADIUS, y = pos.y - 2, z = pos.z - FISH_SEARCH_RADIUS}
	local maxp = {x = pos.x + FISH_SEARCH_RADIUS, y = pos.y + 2, z = pos.z + FISH_SEARCH_RADIUS}
	local best, best_distance
	for _, site in ipairs(core.find_nodes_in_area(minp, maxp, {"group:water"})) do
		if common.is_surface_water(site) then
			local distance = vector.distance(pos, site)
			if not best_distance or distance < best_distance then best, best_distance = site, distance end
		end
	end
	return best
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

	-- A villager already employed as a fisherman when its mapblock loads
	-- (existing barrel fishermen, or one #71 promoted before a save) needs
	-- the flag restored; it is not itself part of the saved fields.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if should_flag(self) then
			self._villages_fisherman = true
		end
		return result
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

		-- Send the fisherman to the water's edge whenever it is not already
		-- headed somewhere and work time allows it. Both a fallback fisherman
		-- (no jobsite) and a barrel-employed one make this trip; a barrel only
		-- grants the profession, not an exemption from fishing at the shore.
		if not self.child and self._id and common.is_work_time() and self.state ~= "gowp" then
			if self._villages_fish_target then
				local route = self._villages_fish_route
				if route and route.status == "retry" and core.get_gametime() >= route.retry_at then
					self._villages_fish_target = nil
					self._villages_fish_route = nil
				end
			elseif core.get_gametime() >= (self._villages_fish_next or 0) then
				local water = nearest_water(self)
				if water then
					self._villages_fish_target = vector.new(water)
					if not self:gopath(water, nil, true) then
						self._villages_fish_target = nil
					end
				else
					self._villages_fish_next = core.get_gametime() + FISH_RETRY_INTERVAL
				end
			end
		end

		return result
	end
end
