-- Small, bed-limited supplement to VoxeLibre's villager breeding. The birth
-- cooldown survives mapblock unloads in bed metadata, not a mob cache.
local core = minetest
local BED_RADIUS = 24
local BED_HEIGHT = 12
local MATE_RADIUS = 16
local BIRTH_INTERVAL_DAYS = 2
local LAST_BIRTH = "villages_last_birth"

local function valid_claim(villager, near)
	local bed = villager._bed
	if not bed or not villager._id
		or (near and vector.distance(bed, near) > BED_RADIUS) then
		return false
	end
	local node = core.get_node_or_nil(bed)
	local top = mcl_beds.get_bed_top(bed)
	local top_node = top and core.get_node_or_nil(top)
	return node and node.name:find("_bottom", 1, true)
		and core.get_item_group(node.name, "bed") > 0
		and top_node and core.get_item_group(top_node.name, "bed") > 0
		and core.get_meta(bed):get_string("villager") == villager._id
		and core.get_meta(bed):get_string("player") == ""
		and core.get_meta(top):get_string("player") == ""
end

local function nearby_beds(pos)
	local minp = vector.offset(pos, -BED_RADIUS, -BED_HEIGHT, -BED_RADIUS)
	local maxp = vector.offset(pos, BED_RADIUS, BED_HEIGHT, BED_RADIUS)
	local beds = {}
	for _, bed in ipairs(core.find_nodes_in_area(minp, maxp, {"group:bed"})) do
		local node = core.get_node_or_nil(bed)
		if node and node.name:find("_bottom", 1, true) then
			local top = mcl_beds.get_bed_top(bed)
			local top_node = top and core.get_node_or_nil(top)
			if top_node and core.get_item_group(top_node.name, "bed") > 0 then
				local meta = core.get_meta(bed)
				if meta:get_string("player") == ""
					and core.get_meta(top):get_string("player") == "" then
					table.insert(beds, {pos = bed, meta = meta})
				end
			end
		end
	end
	table.sort(beds, function(a, b)
		return vector.distance(a.pos, pos) < vector.distance(b.pos, pos)
	end)
	return beds
end

local function is_free(bed)
	return bed.meta:get_string("villager") == ""
end

local function has_bedless_adult(bed)
	for _, object in ipairs(core.get_objects_inside_radius(bed, BED_RADIUS)) do
		local other = object:get_luaentity()
		if other and other.name == "mobs_mc:villager" and not other.child
			and not valid_claim(other) then
			return true
		end
	end
	return false
end

local function parents_ready(first, second, bed)
	return first and second and first ~= second
		and first.name == "mobs_mc:villager"
		and second.name == "mobs_mc:villager"
		and not first.child and not second.child
		and first.object:get_pos() and second.object:get_pos()
		and vector.distance(first.object:get_pos(), second.object:get_pos()) <= MATE_RADIUS
		and valid_claim(first, bed) and valid_claim(second, bed)
		and not has_bedless_adult(bed)
end

local function nearby_mate(parent, bed)
	for _, object in ipairs(core.get_objects_inside_radius(parent.object:get_pos(), MATE_RADIUS)) do
		local other = object:get_luaentity()
		if parents_ready(parent, other, bed) then return other end
	end
end

local function birth_recent(beds, day)
	for _, bed in ipairs(beds) do
		local last = tonumber(bed.meta:get_string(LAST_BIRTH))
		if last and day - last < BIRTH_INTERVAL_DAYS then return true end
	end
	return false
end

local function create_child(parent, bed, beds, day)
	if not is_free(bed) then return false end
	local child = mcl_mobs.spawn_child(parent.object:get_pos(), "mobs_mc:villager")
	if not child then return false end
	local entity = child:get_luaentity()
	if not entity or not entity._id or bed.meta:get_string("villager") ~= "" then
		child:remove()
		return false
	end
	entity._bed = vector.new(bed.pos.x, bed.pos.y, bed.pos.z)
	bed.meta:set_string("villager", entity._id)
	-- Stamp neighboring beds so another resident cannot birth a second child
	-- before the village has had time to absorb the first.
	for _, nearby in ipairs(beds) do
		nearby.meta:set_string(LAST_BIRTH, tostring(day))
	end
	return true
end

return function(def)
	local original_custom = def.do_custom
	local original_breed = def.on_breed

	def.on_breed = function(first, second)
		if original_breed and original_breed(first, second) == false then return false end
		local pos = first.object:get_pos()
		if not pos then return false end
		local day = core.get_day_count()
		local beds = nearby_beds(pos)
		for _, bed in ipairs(beds) do
			if is_free(bed) and parents_ready(first, second, bed.pos) then
				create_child(first, bed, beds, day)
				break
			end
		end
		-- VoxeLibre's generic child creation has no bed check. We handle even
		-- player-assisted births ourselves so it cannot exceed bed capacity.
		return false
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		if result == false then return false end
		local time = core.get_timeofday()
		if self.child or time < 0.25 or time > 0.6 then return result end
		local day = core.get_day_count()
		if self._villages_birth_check_day == day then return result end
		self._villages_birth_check_day = day
		local pos = self.object:get_pos()
		if not pos or not valid_claim(self, pos) then return result end

		local beds = nearby_beds(pos)
		local recent = birth_recent(beds, day)
		if not recent then
			for _, bed in ipairs(beds) do
				if is_free(bed) and nearby_mate(self, bed.pos) then
					create_child(self, bed, beds, day)
					break
				end
			end
		end
		return result
	end
end
