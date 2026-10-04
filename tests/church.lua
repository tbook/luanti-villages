-- Run with: lua tests/church.lua
table.copy = table.copy or function(value)
	local result = {}
	for k, v in pairs(value) do result[k] = v end
	return result
end
local time = 8000 / 24000
local now, day = 0, 4
local nodes, metas = {}, {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function parse(k)
	local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

vector = {
	equals = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
}

local groups = {["mcl_decor:chair_wooden"] = {chair = 1}}
local facedirs = {[0] = {x = 0, y = 0, z = 1}, {x = 1, y = 0, z = 0}, {x = 0, y = 0, z = -1}, {x = -1, y = 0, z = 0}}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function(name, group)
		if group == "carpet" and name:match("_carpet$") then return 1 end
		return (groups[name] or {})[group] or 0
	end,
	facedir_to_dir = function(param2) return facedirs[param2 % 4] end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["living_villages:pulpit"] = {walkable = true},
		["mcl_decor:chair_wooden"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.25, -0.5, -0.25, 0.25, 0.5, 0.25}}},
	},
	log = function() end,
	get_node_or_nil = function(pos)
		local node = nodes[key(pos)]
		if type(node) == "string" then return {name = node, param2 = 0} end
		return node or {name = "air", param2 = 0}
	end,
	get_meta = function(pos)
		local k = key(pos)
		metas[k] = metas[k] or {}
		return {
			get_string = function(_, field) return metas[k][field] or "" end,
			set_string = function(_, field, value) metas[k][field] = value end,
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
}

-- The furnished stock church (church_schematic.lua), laid out from the real
-- VoxeLibre fixture, in schematic coordinates: carpet over the whole floor, a
-- dais at x 8 to 10, z 5 to 8, the pulpit on it at (8,3,8) facing the pews to the
-- west, and twelve chairs facing east. Carpets are walkable slivers, so every
-- cell a villager can stand in here is one.
local stock = dofile("tests/fixtures/church_voxelibre_0_92_3.lua")
local schematic = {size = stock.size, data = {}}
for i, id in ipairs(stock.ids) do
	schematic.data[i] = {name = stock.names[id + 1], prob = 255, param2 = stock.param2[i]}
end
assert(dofile("church_schematic.lua")(schematic))
for z = 0, stock.size.z - 1 do
	for y = 0, stock.size.y - 1 do
		for x = 0, stock.size.x - 1 do
			local cell = schematic.data[z * stock.size.y * stock.size.x + y * stock.size.x + x + 1]
			if cell.name ~= "air" then
				nodes[key({x = x, y = y, z = z})] = {name = cell.name, param2 = cell.param2}
				if cell.name:match("_carpet$") then
					minetest.registered_nodes[cell.name] = {walkable = true,
						collision_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, -0.4375, 0.5}}}
				elseif not minetest.registered_nodes[cell.name] then
					minetest.registered_nodes[cell.name] = {walkable = true}
				end
			end
		end
	end
end
local pulpit = {x = 8, y = 3, z = 8}
assert(nodes[key(pulpit)].name == "living_villages:pulpit")
local pews = {}
for k, node in pairs(nodes) do
	if node.name == "mcl_decor:chair_wooden" then pews[k] = true end
end

local seat = dofile("seat.lua")
local church = dofile("church.lua")

local gopaths, blocked = {}, nil
local def = {
	on_activate = function() end,
	do_custom = function() end,
	get_staticdata = function(self)
		local saved = {}
		for k, v in pairs(self) do if type(v) ~= "table" or k:match("^_villages") then saved[k] = v end end
		return saved
	end,
	set_animation = function(self, name) self.animation_name = name end,
	gopath = function(self, target, callback)
		if blocked and vector.equals(target, blocked) then return false end
		table.insert(gopaths, {self = self, target = target, callback = callback})
		self.state = "gowp"
		return true
	end,
}
church.install(def, seat)

local function villager(id, pos, profession)
	local self = {
		_id = id, _profession = profession or "farmer", state = "stand", _bed = {x = 1, y = 2, z = 6},
		collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}, bones = {},
	}
	self.set_yaw = function(entity, yaw) entity.target_yaw = yaw end
	self.object = {
		get_pos = function() return pos end,
		set_pos = function(_, p) pos = p end,
		set_velocity = function() end,
		set_acceleration = function() end,
		set_properties = function() end,
		set_bone_override = function(_, bone, override) self.bones[bone] = override end,
	}
	return setmetatable(self, {__index = def})
end
local function at(cell) return {x = cell.x, y = cell.y - 0.49, z = cell.z} end

-- A chair counts as a pew only if the pulpit is ahead of it and the chair is
-- on the pulpit's audience side: one behind the dais, and one turned away, are
-- not seats. (Twelve members fill the twelve real pews below, so a decoy that
-- was taken would show up as a thirteenth.)
nodes[key({x = 10, y = 2, z = 3})] = {name = "mcl_decor:chair_wooden", param2 = 1}
nodes[key({x = 7, y = 2, z = 3})] = {name = "mcl_decor:chair_wooden", param2 = 1}

local members = {}
local function member(id)
	local m = villager(id, at({x = 1, y = 2, z = 6}))
	members[#members + 1] = m
	return m
end

-- Twelve members fill the twelve pews, no two the same, facing the pulpit.
local chosen = {}
for i = 1, 12 do
	local m = member("m" .. i)
	def.do_custom(m, 0.1)
	local held = m._villages_seat
	assert(held and held.kind == "pulpit", "member " .. i .. " reserves a pew")
	assert(pews[key(held.chair)], "only a real pew: " .. key(held.chair))
	assert(vector.equals(held.table, pulpit))
	assert(not chosen[key(held.chair)], "no two members share a chair")
	chosen[key(held.chair)] = true
	assert(m._villages_church.pulpit.x == 8)
end
-- Arriving beside the chair, the member sits down facing the pulpit.
local first = members[1]
first.object:set_pos(at(first._villages_seat.approach))
for _, path in ipairs(gopaths) do
	if path.self == first then path.callback(first) end
end
assert(first._villages_seated, "sits")
assert(near(first.target_yaw, -math.pi / 2), "faces +x, toward the pulpit")
assert(def.do_custom(first, 0.1) == false and first.order == "stand", "seated members hold their pose")

-- The thirteenth finds the pews full and stands at the back, out of the way of
-- the pews: the carpet in the central aisle, (4,2,7), then (4,2,6). Never the
-- doorway beyond.
local gopath_count = #gopaths
local standee = member("standee")
def.do_custom(standee, 0.1)
assert(not standee._villages_seat and standee._villages_church.place, "stands")
assert(vector.equals(standee._villages_church.place, {x = 4, y = 2, z = 7}), key(standee._villages_church.place))
assert(#gopaths == gopath_count + 1 and vector.equals(gopaths[#gopaths].target, {x = 4, y = 2, z = 7}))
standee.state = "stand"
standee.object:set_pos(at({x = 4, y = 2, z = 7}))
def.do_custom(standee, 0.1)
assert(standee.order == "stand" and near(standee.target_yaw, (math.atan2 or math.atan)(-4, 1)), "facing the pulpit at the back")
local second = member("standee2")
def.do_custom(second, 0.1)
assert(not vector.equals(second._villages_church.place, standee._villages_church.place), "a place of its own")
assert(second._villages_church.place.x == 4 and second._villages_church.place.z == 6, "the next cell out of the pews' way")

-- A pew comes free and the member standing at the back takes it.
seat.stand(members[2])
standee.state = "stand"
now = now + 6
def.do_custom(standee, 0.1)
assert(standee._villages_seat and pews[key(standee._villages_seat.chair)], "takes the free pew")
assert(not standee._villages_church.place, "gives up its place")

-- The cleric who claimed the pulpit stands behind it, on the dais, facing the
-- congregation: its own stage, the Service, begins when the church does.
local cleric = villager("cleric", at({x = 1, y = 2, z = 6}), "cleric")
cleric._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "cleric"}
local count = #gopaths
def.do_custom(cleric, 0.1)
assert(#gopaths == count + 1 and vector.equals(gopaths[#gopaths].target, {x = 9, y = 3, z = 8}), "walks to the dais")
assert(not cleric._villages_seat, "the cleric does not take a pew")
cleric.state = "stand"
cleric.object:set_pos(at({x = 9, y = 3, z = 8}))
def.do_custom(cleric, 0.1)
assert(cleric.order == "stand" and near(cleric.target_yaw, math.pi / 2), "faces -x, out at the pews")
local cell, dir = church.cleric_stand(pulpit, "cleric")
assert(vector.equals(cell, {x = 9, y = 3, z = 8}) and dir.x == -1)
-- It already stands there before the service: the Pulpit stage.
time = 6000 / 24000
cleric.object:set_pos(at({x = 9, y = 3, z = 8}))
def.do_custom(cleric, 0.1)
assert(cleric.order == "stand", "waits at the pulpit for the service")
-- The cell behind the pulpit is the only one the stock dais offers (the altar is
-- beside it, and the other side is a step down). With it blocked there is
-- nowhere to stand, and the cleric putters rather than walking into the pulpit.
local behind = nodes[key({x = 9, y = 3, z = 8})]
nodes[key({x = 9, y = 3, z = 8})] = "mcl_core:stone"
assert(church.cleric_stand(pulpit, "cleric") == nil)
cleric.state = "stand"
def.do_custom(cleric, 0.1)
assert(not cleric._villages_church and cleric.order == nil, "putters")
nodes[key({x = 9, y = 3, z = 8})] = behind
-- A cleric with no pulpit of its own sits with the others during the service.
time = 8000 / 24000
local stray = villager("stray", at({x = 1, y = 2, z = 6}), "cleric")
stray._jobsite = nil
now = now + 6
def.do_custom(stray, 0.1)
assert(stray._villages_church and stray._villages_church.role == "member", "a member of the congregation")

-- Standing places already held are passed over.
local places = church.back_places(pulpit, "someone")
assert(places[1] and not vector.equals(places[1].cell, second._villages_church.place), "the held place is skipped")

-- The end of the stage: seats go, and so do the walk and the hold on the pose.
time = 10600 / 24000
now = now + 6
assert(first._villages_seated)
def.do_custom(first, 0.1)
assert(not first._villages_seated and not first._villages_seat and not first._villages_church, "stands up")
assert(first.order == nil, "free to putter")
for _, hold in pairs(seat.reservations) do assert(hold.id ~= "m1", "chair released") end
def.do_custom(standee, 0.1)
assert(not standee._villages_church and not standee._villages_seat and standee.order == nil)
def.do_custom(cleric, 0.1)
assert(not cleric._villages_church)
local held_place = second._villages_church.place
def.do_custom(second, 0.1)
assert(not church.standing[key(held_place)], "the hold on its place goes")
local gone = church.back_places(pulpit, "someone")
assert(gone[1].cell.z == 7 and gone[1].cell.x == 4, "its place is free again")

-- No church within reach: nothing to walk to, and the villager putters.
time = 8000 / 24000
local lost = villager("lost", {x = 300, y = 1.51, z = 300})
lost._bed = {x = 300, y = 2, z = 300}
count = #gopaths
def.do_custom(lost, 0.1)
assert(#gopaths == count and not lost._villages_church and lost.order == nil, "no church, no trip")
-- And it does not search every tick.
local searches = 0
local find = minetest.find_nodes_in_area
minetest.find_nodes_in_area = function(...) searches = searches + 1 return find(...) end
def.do_custom(lost, 0.1)
assert(searches == 0, "waits before looking again")
minetest.find_nodes_in_area = find

-- A church it cannot reach: the walk fails, and it putters.
local walker = villager("walker", at({x = 1, y = 2, z = 6}))
-- Fill every pew so that it has to stand.
for k2 in pairs(pews) do seat.reservations[k2] = {id = "other", until_time = now + 1000} end
blocked = {x = 4, y = 2, z = 7}
def.do_custom(walker, 0.1)
assert(not walker._villages_church and walker.order == nil, "gave up")
assert(walker._villages_church_skipped[key(pulpit)] > now, "passes the church over for a while")
def.do_custom(walker, 0.1)
assert(not walker._villages_church, "and does not try it again at once")
blocked = nil

-- Saving a villager leaves out the visit.
local keeper_of = villager("saved", at({x = 1, y = 2, z = 6}))
keeper_of._villages_church = {pulpit = pulpit}
local saved = def.get_staticdata(keeper_of)
assert(saved._villages_church == nil and keeper_of._villages_church, "not saved, kept")
print("ok")
