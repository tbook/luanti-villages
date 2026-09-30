-- Run with: lua tests/meal.lua
table.copy = table.copy or function(value)
	local result = {}
	for k, v in pairs(value) do result[k] = v end
	return result
end
local time = 15600 / 24000
local now, day = 0, 3
local nodes, metas, stacks = {}, {}, {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function parse(k)
	local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

vector = {
	equals = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	dir_to_rotation = function() return {x = 0, y = 0, z = 0} end,
}

local groups = {
	["mcl_decor:chair_wooden"] = {chair = 1},
	["mcl_decor:table_wooden"] = {table = 1},
}
local facedirs = {[0] = {x = 0, y = 0, z = 1}, {x = 1, y = 0, z = 0}, {x = 0, y = 0, z = -1}, {x = -1, y = 0, z = 0}}
local entities, objects, particles, sounds = {}, {}, 0, 0

local function stack(name)
	return {is_empty = function() return name == nil or name == "" end}
end

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function(name, group) return (groups[name] or {})[group] or 0 end,
	facedir_to_dir = function(param2) return facedirs[param2 % 4] end,
	wallmounted_to_dir = function() return {x = 0, y = -1, z = 0} end,
	registered_items = {
		["mcl_farming:bread"] = {inventory_image = "bread.png"},
		["mcl_farming:potato_item_baked"] = {inventory_image = "potato.png", wield_scale = {x = 1, y = 1}},
	},
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_jukebox:jukebox"] = {walkable = true},
		["mcl_decor:chair_wooden"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.25, -0.5, -0.25, 0.25, 0.5, 0.25}}},
		["mcl_decor:table_wooden"] = {walkable = true},
		["mcl_itemframes:plate"] = {walkable = false},
	},
	serialize = function(value) return value end,
	deserialize = function(value) return value end,
	log = function() end,
	get_node_or_nil = function(pos)
		local node = nodes[key(pos)]
		if type(node) == "string" then return {name = node, param2 = 1} end
		return node or {name = "air", param2 = 0}
	end,
	get_meta = function(pos)
		local k = key(pos)
		metas[k] = metas[k] or {}
		return {
			get_string = function(_, field) return metas[k][field] or "" end,
			set_string = function(_, field, value) metas[k][field] = value end,
			get_inventory = function()
				return {get_stack = function() return stack(stacks[k]) end}
			end,
		}
	end,
	find_nodes_in_area = function(minp, maxp, names)
		local found = {}
		for k, node in pairs(nodes) do
			local p = parse(k)
			local name = type(node) == "string" and node or node.name
			local group = names[1]:match("^group:(.+)")
			local match = group and minetest.get_item_group(name, group) > 0 or name == names[1]
			if match and p.x >= minp.x and p.x <= maxp.x and p.y >= minp.y and p.y <= maxp.y
				and p.z >= minp.z and p.z <= maxp.z then
				table.insert(found, p)
			end
		end
		table.sort(found, function(a, b) return key(a) < key(b) end)
		return found
	end,
	get_objects_inside_radius = function(pos, radius)
		local found = {}
		for _, object in ipairs(objects) do
			local p = object:get_pos()
			if p and vector.distance(p, pos) <= radius then table.insert(found, object) end
		end
		return found
	end,
	add_entity = function(pos, name)
		local entity = {name = name, pos = pos}
		entity.object = {
			get_pos = function() return not entity.removed and entity.pos or nil end,
			set_rotation = function() end,
			set_properties = function(_, props) entity.props = props end,
			remove = function() entity.removed = true end,
			get_luaentity = function() return entity end,
		}
		table.insert(entities, entity)
		table.insert(objects, entity.object)
		return entity.object
	end,
	add_particle = function() particles = particles + 1 end,
	sound_play = function() sounds = sounds + 1 end,
}

-- A room: a jukebox, and one table with a plate on it and a chair either
-- side facing it.
for x = -3, 8 do
	for z = -4, 6 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
end
local jukebox = {x = 0, y = 0, z = 0}
local west, east = {x = 2, y = 0, z = 0}, {x = 4, y = 0, z = 0}
local tabletop, plate = {x = 3, y = 0, z = 0}, {x = 3, y = 1, z = 0}
nodes[key(jukebox)] = "mcl_jukebox:jukebox"
nodes[key(tabletop)] = "mcl_decor:table_wooden"
nodes[key(plate)] = "mcl_itemframes:plate"
nodes[key(west)] = {name = "mcl_decor:chair_wooden", param2 = 3}
nodes[key(east)] = {name = "mcl_decor:chair_wooden", param2 = 1}

local def = {
	on_activate = function() end,
	do_custom = function() end,
	get_staticdata = function(self)
		local saved = {}
		for k, v in pairs(self) do if type(v) ~= "table" or k:match("^_villages") then saved[k] = v end end
		return saved
	end,
	set_animation = function() end,
	gopath = function(self, target, callback)
		self.state = "gowp"
		self.arrive = callback
		return true
	end,
}
local meal = dofile("meal.lua")
dofile("tavern.lua")(def, meal)

local function villager(id, pos)
	local self = {
		_id = id, _profession = "farmer", state = "stand", _bed = {x = 0, y = 0, z = 2},
		_trades = {{traded_once = true}}, collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3},
	}
	self.set_yaw = function() end
	self.object = {
		get_pos = function() return pos end,
		set_pos = function(_, p) pos = p end,
		set_velocity = function() end,
		set_acceleration = function() end,
		set_properties = function() end,
		set_bone_override = function() end,
		get_luaentity = function() return self end,
	}
	return setmetatable(self, {__index = def})
end

local function meals_shown()
	local count = 0
	for _, entity in ipairs(entities) do
		if not entity.removed then count = count + 1 end
	end
	return count
end

-- The keeper: claimed the jukebox, and stands at it working.
local kate = villager("kate", {x = 0, y = 0, z = 1})
kate._villages_keeper, kate._jobsite, kate.order = true, jukebox, "work"
metas[key(jukebox)] = {villager = "kate"}
local keeper_object = kate.object
table.insert(objects, keeper_object)

-- A guest sits, waits a moment, and is served on the plate in front of it.
local alice = villager("alice", {x = 1, y = -0.49, z = 1})
def.do_custom(alice, 0.1)
assert(alice._villages_seated)
def.do_custom(alice, 0.1)
assert(not alice._villages_meal, "not served the moment she sits")
now = now + 3
def.do_custom(alice, 0.1)
assert(alice._villages_meal and meals_shown() == 1, "served")
local shown = entities[#entities]
assert(shown.name == "living_villages:meal" and shown.props.wield_item == alice._villages_meal.item)
assert(shown.pos.x == 3 and math.abs(shown.pos.y - 0.58) < 1e-6, "on the plate")
assert(stacks[key(plate)] == nil, "nothing put in the plate's inventory")
assert(alice._villages_meal_day == day)
def.do_custom(alice, 0.1)
assert(particles > 0 and sounds > 0, "eats: particles and the bite sound")

-- The plate is hers: the guest across the table waits for it.
local bob = villager("bob", {x = 3, y = -0.49, z = 1})
def.do_custom(bob, 0.1)
assert(bob._villages_seated and vector.equals(bob._villages_seat.chair, east))
now = now + 3
def.do_custom(bob, 0.1)
assert(not bob._villages_meal, "one meal per plate")

-- The keeper leaves mid-meal: alice finishes hers.
keeper_object.get_pos = function() return {x = 30, y = 0, z = 30} end
now = now + 3
def.do_custom(alice, 0.1)
assert(alice._villages_meal, "finishes the meal")

-- The meal ends and the plate clears; once per evening.
now = now + 7
def.do_custom(alice, 0.1)
assert(not alice._villages_meal and meals_shown() == 0, "plate empties")
now = now + 10
def.do_custom(alice, 0.1)
assert(not alice._villages_meal, "no second meal")

-- No keeper, no meal; it resumes when the keeper returns.
def.do_custom(bob, 0.1)
assert(not bob._villages_meal, "no keeper on duty")
keeper_object.get_pos = function() return {x = 0, y = 0, z = 1} end
def.do_custom(bob, 0.1)
assert(bob._villages_meal, "keeper back: served")

-- A player puts something on the plate: the meal goes, the item stays.
stacks[key(plate)] = "mcl_core:apple"
def.do_custom(bob, 0.1)
assert(not bob._villages_meal and meals_shown() == 0 and stacks[key(plate)] == "mcl_core:apple")
now = now + 5
def.do_custom(bob, 0.1)
assert(not bob._villages_meal, "counted as the evening's meal")

-- A player's plate is never served on.
alice._villages_meal_day = nil
now = now + 5
def.do_custom(alice, 0.1)
assert(not alice._villages_meal, "plate holds a player's item")
stacks[key(plate)] = nil

-- Saved mid-meal: the entity is not saved, the meal day is, and a reload
-- does not serve again the same evening.
now = now + 5
def.do_custom(alice, 0.1)
assert(alice._villages_meal)
local saved = def.get_staticdata(alice)
assert(saved._villages_meal == nil and saved._villages_meal_day == day)
assert(alice._villages_meal, "still eating after the save")
def.on_activate(alice, saved, 0)
assert(alice._villages_meal == nil)
alice._villages_meal_day = saved._villages_meal_day
now = now + 5
def.do_custom(alice, 0.1)
def.do_custom(alice, 0.1)
assert(not alice._villages_meal, "one meal per evening across a reload")

-- A new evening: served again. Home ends the meal and clears the plate.
-- (The reload unloaded the first meal's entity with the guest.)
for _, entity in ipairs(entities) do entity.removed = true end
day = day + 1
now = now + 5
def.do_custom(alice, 0.1)
assert(alice._villages_seated)
now = now + 5
def.do_custom(alice, 0.1)
assert(alice._villages_meal, "served the next evening")
time = 17600 / 24000
def.do_custom(alice, 0.1)
assert(not alice._villages_meal and meals_shown() == 0 and meal.plates[key(plate)] == nil, "Home clears the meal")

-- A guest unloads mid-meal while its plate stays loaded: once its hold
-- lapses, the other guest is served there, and the orphaned display goes
-- first, so the plate never shows two meals.
time = 15600 / 24000
day = day + 1
now = now + 5
for _, guest in ipairs({alice, bob}) do
	def.do_custom(guest, 0.1)
	assert(guest._villages_seated)
end
now = now + 5
def.do_custom(alice, 0.1)
def.do_custom(bob, 0.1)
local eater, waiter = alice, bob
if bob._villages_meal then eater, waiter = bob, alice end
assert(eater._villages_meal and not waiter._villages_meal and meals_shown() == 1)
-- The eater unloads: it never ticks again, and its display stays.
now = now + 6
def.do_custom(waiter, 0.1)
assert(waiter._villages_meal and meals_shown() == 1, "orphan cleared, one meal on the plate")

print("meal.lua: ok")
