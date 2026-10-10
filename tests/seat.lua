-- Run with: lua tests/seat.lua
table.copy = table.copy or function(value)
	local result = {}
	for k, v in pairs(value) do result[k] = v end
	return result
end
local time = 15600 / 24000
local now, day = 0, 3
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

local groups = {
	["mcl_decor:chair_wooden"] = {chair = 1},
	["mcl_decor:table_wooden"] = {table = 1},
}
local facedirs = {[0] = {x = 0, y = 0, z = 1}, {x = 1, y = 0, z = 0}, {x = 0, y = 0, z = -1}, {x = -1, y = 0, z = 0}}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function(name, group) return (groups[name] or {})[group] or 0 end,
	facedir_to_dir = function(param2) return facedirs[param2 % 4] end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_jukebox:jukebox"] = {walkable = true},
		["mcl_decor:chair_wooden"] = {walkable = true, collision_box = {type = "fixed", fixed = {-0.25, -0.5, -0.25, 0.25, 0.5, 0.25}}},
		["mcl_decor:table_wooden"] = {walkable = true},
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

-- A room: a stone floor, a jukebox, and one table with a chair either side
-- facing it. A third chair stands alone and is never a seat.
for x = -3, 8 do
	for z = -4, 6 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
end
local jukebox = {x = 0, y = 0, z = 0}
local west, east, lone = {x = 2, y = 0, z = 0}, {x = 4, y = 0, z = 0}, {x = 0, y = 0, z = 4}
local tabletop = {x = 3, y = 0, z = 0}
nodes[key(jukebox)] = "mcl_jukebox:jukebox"
nodes[key(tabletop)] = "mcl_decor:table_wooden"
-- The backrest is on +z at param2 0, so param2 3 faces +x and 1 faces -x.
nodes[key(west)] = {name = "mcl_decor:chair_wooden", param2 = 3}
nodes[key(east)] = {name = "mcl_decor:chair_wooden", param2 = 1}
nodes[key(lone)] = {name = "mcl_decor:chair_wooden", param2 = 0}

local gopaths = {}
local blocked
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
-- tavern.lua loads seat.lua itself; share that copy to read its reservations.
local seat = dofile("seat.lua")
local load_file = dofile
dofile = function(path)
	if path:match("/seat%.lua$") then return seat end
	return load_file(path)
end
load_file("tavern.lua")(def)
dofile = load_file

local function villager(id, pos)
	local self = {
		_id = id, _profession = "farmer", state = "stand", _bed = {x = 0, y = 0, z = 2},
		_trades = {{traded_once = true}}, collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3},
		bones = {},
	}
	self.set_yaw = function(entity, yaw) entity.target_yaw = yaw end
	self.object = {
		get_pos = function() return pos end,
		set_pos = function(_, p) pos = p end,
		set_velocity = function() end,
		set_acceleration = function() end,
		set_properties = function(_, props) self.props = props end,
		set_bone_override = function(_, bone, override) self.bones[bone] = override end,
	}
	return setmetatable(self, {__index = def})
end

-- Arriving beside a free seat, a guest takes it: pinned down in the chair,
-- facing the table, legs forward, and the chair held for it.
local alice = villager("alice", {x = 1, y = -0.49, z = 1})
-- She was walking the tavern route when she came within reach of the chair (#230).
alice._villages_follow = {final = {x = 1, y = 0, z = 1}}
alice._villages_tavern_route = {status = "travelling", id = 7, target = {x = 1, y = 0, z = 1}}
def.do_custom(alice, 0.1)
assert(alice._villages_tavern_arrived and alice._villages_seated, "sits at once beside the chair")
-- Sitting ends the walk: a follower flag and a "travelling" route left behind read as a
-- lost walk once she gets up, and cancelled the route (#230).
assert(alice._villages_follow == nil, "the walk is over")
assert(alice._villages_tavern_route.status == "arrived" and alice._villages_tavern_route.id == 7,
	"the tavern route ended with it")
local pos = alice.object:get_pos()
assert(pos.x == 2 and pos.z == 0 and near(pos.y, -(0.585 - 0.108)), "down in the chair")
assert(near(alice.target_yaw, -math.pi / 2), "faces +x, toward the table")
assert(alice.bones["leg.right"].rotation.vec.x < 0 and alice.bones["leg.left"], "legs forward")
assert(alice.collisionbox[4] == 0.2 and alice.props.collisionbox == alice.collisionbox, "narrow box")
assert(seat.reservations[key(west)].id == "alice")
assert(seat.status(alice) == "seated at (2,0,0)")

-- Seated, the vanilla do_custom never runs and the pose holds.
alice.object:set_pos({x = 2.3, y = 0, z = 0.1})
assert(def.do_custom(alice, 0.1) == false)
pos = alice.object:get_pos()
assert(pos.x == 2 and pos.z == 0, "re-pinned")

-- The next guest cannot share it: it takes the other side of the table,
-- walking to the open square beside that chair first.
local bob = villager("bob", {x = 1, y = -0.49, z = -1})
local before = #gopaths
def.do_custom(bob, 0.1)
assert(bob._villages_seat and vector.equals(bob._villages_seat.chair, east), "the other seat")
assert(not bob._villages_seated and #gopaths == before + 1 and vector.equals(gopaths[#gopaths].target, {x = 5, y = 0, z = 0}))
bob.object:set_pos({x = 5, y = -0.49, z = 0})
-- Bob's walk was a goto route to the approach square (church pews walk the same way), beside an
-- unrelated bed route that must stay as it is (#230).
bob._villages_follow = {final = {x = 5, y = 0, z = 0}}
bob._villages_goto_route = {status = "travelling", id = 3, goal = {x = 5, y = 0, z = 0}}
bob._villages_bed_route = {status = "travelling", id = 4, target = {x = 0, y = 0, z = 2}}
gopaths[#gopaths].callback(bob)
assert(bob._villages_seated and near(bob.target_yaw, math.pi / 2), "sits facing -x")
assert(bob._villages_follow == nil, "callback sit ends the walk")
assert(bob._villages_goto_route.status == "arrived" and bob._villages_goto_route.id == 3, "goto route ended")
assert(bob._villages_bed_route.status == "travelling" and bob._villages_bed_route.id == 4, "bed route untouched")

-- No seat left: the third guest stands inside, as before.
local carol = villager("carol", {x = 1, y = -0.49, z = 2})
def.do_custom(carol, 0.1)
assert(carol._villages_tavern_arrived and not carol._villages_seat and carol.order == "stand")

-- A player sits in alice's chair: she gets up, back to where she sat down
-- from, and lets it go. Nobody reserves a chair a player holds.
mcl_cozy = {players = {singleplayer = {{x = 2, y = 0, z = 0}, "sit"}}}
def.do_custom(alice, 0.1)
assert(not alice._villages_seated and not alice.bones["leg.right"], "stands up")
assert(alice._villages_tavern_route.status == "arrived" and not alice._villages_follow,
	"getting up cancels nothing and sets no retry hold")
pos = alice.object:get_pos()
assert(pos.x == 1 and pos.z == 1, "at the square she came from")
assert(alice.collisionbox[4] == 0.3, "box restored")
assert(seat.reservations[key(west)] == nil, "released")
now = now + 6
def.do_custom(carol, 0.1)
assert(not carol._villages_seat, "a player's seat is never reserved")
mcl_cozy = nil

-- The table goes: bob gets up.
nodes[key(tabletop)] = nil
def.do_custom(bob, 0.1)
assert(not bob._villages_seated and not bob._villages_seat and seat.reservations[key(east)] == nil)
nodes[key(tabletop)] = "mcl_decor:table_wooden"

-- A reservation left behind by a villager that is gone lapses on its own.
seat.reservations[key(west)] = {id = "ghost", until_time = now + 10}
seat.reservations[key(east)] = {id = "ghost", until_time = now + 30}
now = now + 6
def.do_custom(carol, 0.1)
assert(not carol._villages_seat, "still held")
now = now + 11
def.do_custom(carol, 0.1)
assert(carol._villages_seat and vector.equals(carol._villages_seat.chair, west), "lapsed, and taken")
carol.object:set_pos({x = 1, y = -0.49, z = 0})
gopaths[#gopaths].callback(carol)
assert(carol._villages_seated)

-- Saved while seated: only the way back up is kept. Reloaded, the villager
-- is set back on its feet beside the chair, and holds nothing.
local saved = def.get_staticdata(carol)
assert(saved._villages_seated == nil and saved._villages_seat == nil and saved._villages_seat_exit)
carol._villages_seated, carol._villages_seat = nil, nil
def.on_activate(carol, saved, 0)
pos = carol.object:get_pos()
assert(pos.x == 1 and pos.z == 0 and not carol._villages_seat_exit, "stood up on reload")
assert(seat.reservations[key(west)] == nil, "reservation released on reload")

-- Its exit walled off while it sat: it stands up beside the chair anyway.
now = now + 6
def.do_custom(carol, 0.1)
assert(carol._villages_seated)
local exit = carol._villages_seat_exit
nodes[key({x = exit.x, y = 0, z = exit.z})] = "mcl_core:stone"
time = 17600 / 24000
def.do_custom(carol, 0.1)
pos = carol.object:get_pos()
assert(not carol._villages_seated and carol._villages_tavern_target == nil, "Home ends dinner")
assert(pos.y > -0.5 and vector.distance(pos, west) <= 1.5 and not (pos.x == exit.x and pos.z == exit.z),
	"on its feet beside the chair, not in the wall")
assert(seat.reservations[key(west)] == nil)

-- A chair it cannot reach is given up at once and passed over: the guest
-- walks to the other one instead of retrying the nearest all evening.
time = 15600 / 24000
day = day + 1
local erin = villager("erin", {x = 1, y = -0.49, z = 2})
-- carol's walled-off exit left one open square beside the west chair.
seat.reservations[key(east)] = nil
blocked = {x = 2, y = 0, z = 1}
def.do_custom(erin, 0.1)
assert(erin._villages_seat_unreachable["2,0,0"] and seat.reservations[key(west)] == nil, "unreachable chair let go")
def.do_custom(erin, 0.1)
assert(erin._villages_seat and vector.equals(erin._villages_seat.chair, east), "tries the other chair")
assert(vector.equals(gopaths[#gopaths].target, {x = 5, y = 0, z = 0}))
-- Timed out on the way: also passed over.
erin._villages_seat.reserved_at = now - 21
erin.state = "stand"
def.do_custom(erin, 0.1)
assert(erin._villages_seat == nil and erin._villages_seat_unreachable["4,0,0"], "timed out chair skipped")
def.do_custom(erin, 0.1)
assert(erin._villages_seat == nil, "neither is retried this evening")
blocked = nil
seat.stand(erin)

-- Dying in the chair lets it go.
local dave = villager("dave", {x = 1, y = -0.49, z = 1})
def.do_custom(dave, 0.1)
assert(dave._villages_seated)
def.on_die(dave, dave.object:get_pos())
assert(seat.reservations[key(west)] == nil)

-- A route still being planned when the guest sits is dropped, so its late result cannot start a
-- walk under a seated guest; a goto route to somewhere else is not the seat's (#230).
local common = dofile("common.lua")
local sitter = {
	_villages_tavern_route = {status = "planning", id = 1},
	_villages_goto_route = {status = "planning", id = 2, goal = {x = 5, y = 0, z = 0}},
}
common.end_seat_walk(sitter, {x = 5, y = 0, z = 0})
assert(sitter._villages_tavern_route == nil and sitter._villages_goto_route == nil, "planning routes dropped")
local elsewhere = {_villages_goto_route = {status = "travelling", id = 5, goal = {x = 9, y = 0, z = 9}}}
common.end_seat_walk(elsewhere, {x = 5, y = 0, z = 0})
assert(elsewhere._villages_goto_route.status == "travelling", "another destination is left alone")

-- stop_walk (tavern end_visit, bell leave) drops the follower's flag with the state.
local walker = {state = "gowp", _villages_follow = {}, _target = {}, object = {set_velocity = function() end}}
assert(common.stop_walk(walker) and walker.state == "stand" and walker._villages_follow == nil and walker._target == nil)
local idle = {state = "stand", _villages_follow = {}}
assert(common.stop_walk(idle) == false and idle._villages_follow, "not a walk: nothing touched")

print("seat.lua: ok")
