-- Run with: lua tests/births.lua
local day, time = 10, 0.4
local nodes, data, objects = {}, {}, {}
local births, fail_spawn = 0, false

local function key(pos)
	return ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
end

local function bed(x, owner)
	local bottom = {x = x, y = 0, z = 0}
	local top = {x = x, y = 0, z = 1}
	nodes[key(bottom)] = {name = "mcl_beds:bed_red_bottom"}
	nodes[key(top)] = {name = "mcl_beds:bed_red_top"}
	data[key(bottom)] = {villager = owner or "", player = ""}
	data[key(top)] = {player = ""}
	return bottom, top
end

local function adult(id, pos, owned)
	local entity = {name = "mobs_mc:villager", _id = id, _bed = owned}
	entity.object = {
		get_pos = function() return pos end,
		get_luaentity = function() return entity end,
	}
	table.insert(objects, entity.object)
	return entity
end

vector = {
	new = function(x, y, z) return {x = x, y = y, z = z} end,
	offset = function(pos, x, y, z)
		return {x = pos.x + x, y = pos.y + y, z = pos.z + z}
	end,
	distance = function(a, b)
		return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
	end,
}

minetest = {
	get_day_count = function() return day end,
	get_timeofday = function() return time end,
	get_node_or_nil = function(pos) return nodes[key(pos)] end,
	get_item_group = function(name, group)
		return group == "bed" and name:find("mcl_beds:bed_", 1, true) and 1 or 0
	end,
	get_meta = function(pos)
		local fields = data[key(pos)]
		return {
			get_string = function(_, field) return fields[field] or "" end,
			set_string = function(_, field, value) fields[field] = value end,
		}
	end,
	find_nodes_in_area = function(minp, maxp)
		local result = {}
		for location in pairs(nodes) do
			local x, y, z = location:match("([^,]+),([^,]+),([^,]+)")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			if x >= minp.x and x <= maxp.x and y >= minp.y and y <= maxp.y
				and z >= minp.z and z <= maxp.z then
				table.insert(result, {x = x, y = y, z = z})
			end
		end
		table.sort(result, function(a, b) return a.x < b.x end)
		return result
	end,
	get_objects_inside_radius = function(pos, radius)
		local result = {}
		for _, object in ipairs(objects) do
			if vector.distance(pos, object:get_pos()) <= radius then
				table.insert(result, object)
			end
		end
		return result
	end,
}

mcl_beds = {get_bed_top = function(pos)
	return {x = pos.x, y = pos.y, z = pos.z + 1}
end}
mcl_mobs = {spawn_child = function(pos, name)
	assert(name == "mobs_mc:villager")
	if fail_spawn then return nil end
	births = births + 1
	local entity = {name = name, _id = "child" .. births, child = true}
	local object = {
		get_luaentity = function() return entity end,
		remove = function() births = births - 1 end,
		get_pos = function() return pos end,
	}
	entity.object = object
	table.insert(objects, object)
	return object
end}

local def = {do_custom = function() end}
dofile("births.lua")(def)

local first_bed = bed(0, "alice")
local second_bed = bed(4, "bob")
local free_bed = bed(8)
local alice = adult("alice", {x = 0, y = 0, z = 0}, first_bed)
local bob = adult("bob", {x = 4, y = 0, z = 0}, second_bed)

def.do_custom(alice, 1)
assert(births == 1, "a free bed should allow one automatic child")
assert(data[key(free_bed)].villager == "child1", "child must own the bed immediately")
assert(data[key(first_bed)].villages_last_birth == "10", "birth cooldown must persist")

local next_bed = bed(12)
day = 11
def.do_custom(alice, 1)
assert(births == 1, "cooldown should block the next day's automatic birth")
day = 12
def.do_custom(alice, 1)
assert(births == 2 and data[key(next_bed)].villager == "child2")

local player_bed, player_top = bed(16)
data[key(player_top)].player = "player"
day = 14
def.do_custom(alice, 1)
assert(births == 2, "player beds must not count")

local spare_bed = bed(20)
local homeless = adult("homeless", {x = 6, y = 0, z = 0})
day = 16
def.do_custom(alice, 1)
assert(births == 2, "a bedless adult should get priority")
homeless._bed = spare_bed
data[key(spare_bed)].villager = "homeless"

local food_bed = bed(22)
time = 0.9
assert(def.on_breed(alice, bob) == false)
assert(births == 3 and data[key(food_bed)].villager == "child3",
	"food breeding should claim a free bed without waiting for daytime")
assert(def.on_breed(alice, bob) == false and births == 3,
	"food breeding must not create an unbedded child")

local failed_bed = bed(23)
fail_spawn = true
assert(def.on_breed(alice, bob) == false)
assert(data[key(failed_bed)].villager == "", "failed spawns must leave the bed free")

print("villager birth tests passed")
