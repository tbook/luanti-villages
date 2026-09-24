-- A deliberately small farmer activity for VoxeLibre's legacy villager AI.
-- Mineclonia implements this through its POI/activity/inventory systems; here
-- a claimed composter anchors a bounded crop visit, while the villager keeps an
-- implicit seed supply for immediate replanting.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local FARM_RADIUS = 8
local FARM_INTERVAL = 5
local mature_crops = {
	["mcl_farming:wheat"] = "mcl_farming:wheat_1",
	["mcl_farming:potato"] = "mcl_farming:potato_1",
	["mcl_farming:carrot"] = "mcl_farming:carrot_1",
	["mcl_farming:beetroot"] = "mcl_farming:beetroot_0",
}
local crop_names = {}
for name in pairs(mature_crops) do table.insert(crop_names, name) end

local function valid_farmer(self)
	if self.child or self._profession ~= "farmer" or not self._jobsite or not self._id then return false end
	local node = core.get_node_or_nil(self._jobsite)
	return node and node.name == "mcl_composters:composter"
		and core.get_meta(self._jobsite):get_string("villager") == self._id
end

local function nearest_crop(self)
	local job = self._jobsite
	local minp = {x = job.x - FARM_RADIUS, y = job.y - 2, z = job.z - FARM_RADIUS}
	local maxp = {x = job.x + FARM_RADIUS, y = job.y + 2, z = job.z + FARM_RADIUS}
	local pos = self.object:get_pos()
	local best, best_distance
	for _, crop in ipairs(core.find_nodes_in_area(minp, maxp, crop_names)) do
		local distance = vector.distance(pos, crop)
		if not best_distance or distance < best_distance then best, best_distance = crop, distance end
	end
	return best
end

local function harvest_and_replant(self, crop)
	local node = core.get_node_or_nil(crop)
	local replacement = node and mature_crops[node.name]
	if replacement and not core.is_protected(crop, "") then
		core.dig_node(crop, self.object)
		core.set_node(crop, {name = replacement})
	end
	self._villages_farm_target = nil
	self._villages_farm_next = core.get_gametime() + FARM_INTERVAL
end

return function(def)
	local original_custom = def.do_custom
	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		if result == false or not common.is_work_time() or not valid_farmer(self) then return result end

		local now = core.get_gametime()
		if self._villages_farm_target then
			local route = self._villages_farm_route
			if route and route.status == "retry" and now >= route.retry_at then
				self._villages_farm_target = nil
				self._villages_farm_route = nil
			end
			return result
		end
		if self.state == "gowp" or now < (self._villages_farm_next or 0) then return result end

		local crop = nearest_crop(self)
		if not crop then
			self._villages_farm_next = now + FARM_INTERVAL
			return result
		end
		self._villages_farm_target = vector.new(crop)
		if not self:gopath(crop, function(entity)
			harvest_and_replant(entity, crop)
		end, true) then
			self._villages_farm_target = nil
		end
		return result
	end
end
