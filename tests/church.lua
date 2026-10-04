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
						drawtype = "nodebox", node_box = {type = "fixed", fixed = {{-0.5, -0.5, -0.5, 0.5, -0.4375, 0.5}}}}
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
		-- Vanilla marks a failed route search (mcl_mobs/pathfinding.lua).
		if blocked and vector.equals(target, blocked) then
			self._pf_last_failed = (self._pf_last_failed or 0) + 1
			return false
		end
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
	local velocity = {x = 0, y = 0, z = 0}
	self.object = {
		get_pos = function() return pos end,
		set_pos = function(_, p) pos = p end,
		get_velocity = function() return velocity end,
		set_velocity = function(_, v) velocity = v end,
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
local function still(v, cell)
	v.object:set_pos(at(cell))
	v.object:set_velocity({x = 0, y = 0, z = 0})
	v.state = "stand"
end
local cleric = villager("cleric", at({x = 1, y = 2, z = 6}), "cleric")
cleric._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "cleric"}
local count = #gopaths
def.do_custom(cleric, 0.1)
assert(not cleric._villages_seat, "the cleric does not take a pew")
-- The pulpit is walkable, so a straight walk to the cell behind it would be
-- routed over its top. The way is planned once: the floor in front of the dais
-- edge at (8,3,5), the nearest edge along the dais with floor on the
-- congregation's side, then up that step and along the dais in one walk.
local floor_leg, edge, behind_cell = {x = 7, y = 2, z = 5}, {x = 8, y = 3, z = 5}, {x = 9, y = 3, z = 8}
local legs = cleric._villages_church.legs
assert(#legs == 2 and vector.equals(legs[1], floor_leg) and vector.equals(legs[2], behind_cell)
	and vector.equals(cleric._villages_church.edge, edge), "planned legs")
assert(#gopaths == count + 1 and vector.equals(gopaths[#gopaths].target, floor_leg), "first leg: " .. key(gopaths[#gopaths].target))
local function route(v)
	local cells = {v.current_target.pos}
	for _, waypoint in ipairs(v.waypoints) do cells[#cells + 1] = waypoint.pos end
	return cells
end
local function walks(v, expected, message)
	local walked = route(v)
	assert(#walked == #expected, message .. ": " .. #walked .. " cells")
	for i, cell in ipairs(expected) do assert(vector.equals(walked[i], cell), message .. ", cell " .. i) end
	assert(vector.equals(v._target, behind_cell), message .. ": ends behind the pulpit")
end
-- In the air near the floor leg is not there yet.
cleric.object:set_pos({x = 7, y = 1.8, z = 5})
cleric.object:set_velocity({x = 0, y = 2, z = 0})
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 1 and #gopaths == count + 1, "a jump does not finish a leg")
-- Standing on its level, a node short (where check_gowp stops a carpeted walk):
-- up the step and along the dais, cell by cell, as one walk. Not by the
-- pathfinder, which would leave the dais to cross the pulpit's top, and not a
-- walk that ends at the edge: check_gowp ends a walk within 1.8 nodes of its
-- end, which is mid-jump, and stops the mob dead in the air.
count = #gopaths
still(cleric, {x = 6, y = 2, z = 5})
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 2 and cleric.state == "gowp" and #gopaths == count, "second leg")
local along = {{x = 9, y = 3, z = 5}, {x = 9, y = 3, z = 6}, {x = 9, y = 3, z = 7}, behind_cell}
walks(cleric, {edge, along[1], along[2], along[3], along[4]}, "up the step and along the dais")
-- Mid-jump up the step: the walk is kept.
cleric.object:set_pos({x = 7.6, y = 2.6, z = 5})
cleric.object:set_velocity({x = 1, y = 1.5, z = 0})
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 2 and #gopaths == count and cleric.state == "gowp", "the climb is not cut short")
-- If vanilla stops the walk at the top of the jump, beside the step (feet level
-- with the dais node but under its surface, not rising): not on the dais yet,
-- so the walk starts again from the floor rather than from the dais.
cleric.object:set_pos({x = 7, y = 2.4, z = 5})
cleric.object:set_velocity({x = 0, y = 0, z = 0})
cleric.state = "stand"
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 1 and vector.equals(gopaths[#gopaths].target, floor_leg), "back to the floor in front of the step")
-- Landed on the very edge of the dais, its center hanging past the edge cell
-- over the floor in front: it is on the dais (a headless run landed here).
still(cleric, edge)
cleric.object:set_pos({x = 7.3, y = 2.51, z = 5})
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 2 and cleric.state == "gowp", "on the dais from the edge")
walks(cleric, along, "walks the dais from the edge")
-- Knocked off the dais on the way: it plans the way up again.
still(cleric, {x = 6, y = 2, z = 7})
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 1 and vector.equals(gopaths[#gopaths].target, floor_leg), "back to the floor leg")
still(cleric, floor_leg)
def.do_custom(cleric, 0.1)
assert(cleric._villages_church.leg == 2 and cleric.state == "gowp")
walks(cleric, {edge, along[1], along[2], along[3], along[4]}, "and up again")
-- A node short of its place, on the dais: lined up behind the pulpit, facing
-- the pews, and held there.
count = #gopaths
still(cleric, {x = 9, y = 3, z = 7})
def.do_custom(cleric, 0.1)
local stood = cleric.object:get_pos()
assert(stood.x == 9 and stood.z == 8 and cleric.order == "stand", "behind the pulpit")
assert(near(cleric.target_yaw, math.pi / 2), "faces -x, out at the pews")
def.do_custom(cleric, 0.1)
assert(#gopaths == count and cleric.order == "stand", "and stays")
local cell, dir = church.cleric_stand(pulpit, "cleric")
assert(vector.equals(cell, behind_cell) and dir.x == -1)
-- It already stands there before the service: the Pulpit stage.
time = 6000 / 24000
def.do_custom(cleric, 0.1)
assert(cleric.order == "stand", "waits at the pulpit for the service")
time = 8000 / 24000
-- The cell behind the pulpit is the only one the stock dais offers (the altar is
-- beside it, and the other side is a step down). With it blocked there is
-- nowhere to stand, and the cleric putters rather than walking into the pulpit.
local behind = nodes[key(behind_cell)]
nodes[key(behind_cell)] = "mcl_core:stone"
assert(church.cleric_stand(pulpit, "cleric") == nil)
def.do_custom(cleric, 0.1)
assert(not cleric._villages_church and cleric.order == nil, "putters")
nodes[key(behind_cell)] = behind

-- Up on the dais sooner than planned (here, during the floor leg): once it is
-- standing there it walks the dais.
local early = villager("early", at({x = 1, y = 2, z = 6}), "cleric")
early._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "early"}
def.do_custom(early, 0.1)
assert(early._villages_church.leg == 1)
early.object:set_pos({x = 8, y = 3.2, z = 5})
early.object:set_velocity({x = 0, y = -1, z = 0})
def.do_custom(early, 0.1)
assert(early._villages_church.leg == 1, "not while landing")
still(early, edge)
def.do_custom(early, 0.1)
assert(early._villages_church.leg == 2 and early.state == "gowp" and vector.equals(early._target, behind_cell), "walks the dais")

-- A cleric that sets out from the dais itself walks straight along it.
local up = villager("up", at({x = 10, y = 3, z = 6}), "cleric")
up._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "up"}
def.do_custom(up, 0.1)
assert(#up._villages_church.legs == 1 and up.state == "gowp" and vector.equals(up._target, behind_cell), "already on the dais")
local up_route = route(up)
assert(vector.equals(up_route[#up_route], behind_cell) and up_route[1].y == 3, "walks the dais")

-- A walk under way keeps the route it was given, so a new plan (here, the
-- cleric's old walk was to the cell behind the pulpit) drops it and starts the
-- first leg.
local turned = villager("turned", at({x = 1, y = 2, z = 6}), "cleric")
turned._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "turned"}
turned._villages_church = {role = "cleric", pulpit = pulpit, since = now, limit = 100, goal = behind_cell}
turned.state = "gowp"
count = #gopaths
def.do_custom(turned, 0.1)
assert(#gopaths == count + 1 and vector.equals(gopaths[#gopaths].target, floor_leg), "walks the new first leg, not the old route")

-- A cleric that runs out of time gives up where it is: nobody is moved to a
-- place it did not walk to.
local slow = villager("slow", at({x = 7, y = 2, z = 6}), "cleric")
slow._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "slow"}
def.do_custom(slow, 0.1)
slow._villages_church.since = now - 1000
slow.state = "stand"
def.do_custom(slow, 0.1)
local left = slow.object:get_pos()
assert(not slow._villages_church and left.x == 7 and left.z == 6, "gave up, not moved")

-- While vanilla waits out an earlier failed route (ready_to_path) the villager
-- waits too: that is not another failure.
local settled = villager("settled", at({x = 1, y = 2, z = 6}), "cleric")
settled._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "settled"}
settled.ready_to_path = function() return false end
count = #gopaths
for _ = 1, 5 do def.do_custom(settled, 0.1) end
assert(#gopaths == count and settled._villages_church and not settled._villages_church.failures, "waits")
settled.ready_to_path = nil
def.do_custom(settled, 0.1)
assert(#gopaths == count + 1, "then walks")

-- Vanilla's player scan turns jumping off near a player (villager.lua
-- stand_still). On the way to church it is turned back on, so a villager being
-- watched can still climb; not while a player is trading with it.
local watched = villager("watched", at({x = 1, y = 2, z = 6}), "cleric")
watched._jobsite = {x = pulpit.x, y = pulpit.y, z = pulpit.z}
metas[key(pulpit)] = {villager = "watched"}
def.do_custom(watched, 0.1)
assert(watched.state == "gowp")
watched.jump = false
def.do_custom(watched, 0.1)
assert(watched.jump == true, "can jump again while walking to church")
watched.jump = false
watched._trading_players = {singleplayer = true}
def.do_custom(watched, 0.1)
assert(watched.jump == false, "not while trading")
metas[key(pulpit)] = {villager = "cleric"}

-- A cleric with no pulpit of its own sits with the others during the service.
time = 8000 / 24000
local stray = villager("stray", at({x = 1, y = 2, z = 6}), "cleric")
stray._jobsite = nil
now = now + 6
def.do_custom(stray, 0.1)
assert(stray._villages_church and stray._villages_church.role == "member", "a member of the congregation")

-- Nobody stands on the pews: a chair is solid enough to stand on, but the cell
-- above one is never a place.
for _, place in ipairs(church.back_places(pulpit, "anyone")) do
	local below = nodes[key({x = place.cell.x, y = place.cell.y - 1, z = place.cell.z})]
	assert(not (type(below) == "table" and below.name == "mcl_decor:chair_wooden"), "on a chair: " .. key(place.cell))
end

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

-- A villager across the village does not give up after the 40 s a short walk
-- gets: its allowance grows with the distance. And it walks in before looking
-- for a pew, so the chair's own short timer starts inside the church.
time = 8000 / 24000
now = now + 6
local far = villager("far", {x = -30, y = 1.51, z = 6})
far._bed = {x = -30, y = 2, z = 6}
for k2 in pairs(seat.reservations) do seat.reservations[k2] = nil end
def.do_custom(far, 0.1)
assert(not far._villages_seat and far._villages_church.place, "no chair reserved from a house across the village")
assert(far._villages_church.limit > 100, "a long walk is allowed a long time")
far.state = "stand"
now = now + 100
def.do_custom(far, 0.1)
assert(far._villages_church, "still on its way after 100 s")
far.object:set_pos(at({x = 1, y = 2, z = 6}))
far.state = "stand"
def.do_custom(far, 0.1)
assert(far._villages_seat and far._villages_seat.kind == "pulpit", "takes a pew once inside")
local logged
local log = minetest.log
minetest.log = function(_, text) logged = text end
now = now + 1000
local late = villager("late", {x = -30, y = 1.51, z = 6})
late._bed = {x = -30, y = 2, z = 6}
for k2 in pairs(pews) do seat.reservations[k2] = {id = "other", until_time = now + 1000} end
def.do_custom(late, 0.1)
now = now + 1000
for k2 in pairs(pews) do seat.reservations[k2] = {id = "other", until_time = now + 1000} end
late.state = "stand"
def.do_custom(late, 0.1)
assert(not late._villages_church and logged and logged:match("gave up the church"), logged)
local stayed = late.object:get_pos()
assert(stayed.x == -30 and stayed.z == 6, "a member that runs out of time is not moved toward its place")
minetest.log = log

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
assert(walker._villages_church, "one failed route is not the end: vanilla answers nothing while it waits too")
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
