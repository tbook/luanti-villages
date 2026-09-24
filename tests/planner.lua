local planner = dofile("planner.lua")

local supports = {
	["0:0:0"] = true,
	["1:1:0"] = true, -- first stair
	["2:2:0"] = true, -- second stair
	["3:2:0"] = true, -- upper floor
}
local function can_stand(pos)
	return supports[pos.x .. ":" .. (pos.y - 1) .. ":" .. pos.z] == true
end

local path, visited = planner.find_path({x = 0, y = 1, z = 0}, can_stand,
	function(pos) return pos.x == 3 and pos.y == 3 and pos.z == 0 end,
	{range = 8, heuristic = function(pos) return planner.heuristic(pos, {x = 3, y = 3, z = 0}) end})
assert(path and #path == 4)
assert(visited <= 4)
assert(path[2].x == 1 and path[2].y == 2)
assert(path[3].x == 2 and path[3].y == 3)

-- When a flat continuation and a rise are both legal, do not turn uphill just
-- because upward neighbors happened to be enumerated first.
local flat_supports = {
	["0:0:0"] = true, ["1:0:0"] = true, ["1:1:0"] = true, ["2:0:0"] = true,
}
local function flat_can_stand(pos)
	return flat_supports[pos.x .. ":" .. (pos.y - 1) .. ":" .. pos.z] == true
end
local flat_path = planner.find_path({x = 0, y = 1, z = 0}, flat_can_stand,
	function(pos) return pos.x == 2 and pos.y == 1 and pos.z == 0 end,
	{range = 8, heuristic = function(pos) return planner.heuristic(pos, {x = 2, y = 1, z = 0}) end})
assert(flat_path and flat_path[2].y == 1)

local none, _, none_status = planner.find_path({x = 0, y = 1, z = 0}, can_stand,
	function(pos) return pos.x == 9 end, {range = 8})
assert(none == nil)
assert(none_status == "unreachable")

local _, limited_visited, limit_status = planner.find_path({x = 0, y = 1, z = 0},
	function() return true end, function() return false end, {
		range = 8, max_nodes = 2, distance = function(pos) return math.abs(pos.x - 2) end,
	})
assert(limited_visited == 2)
assert(limit_status == "search_limit")

-- Waypoints are traversed directly by the mover. A multi-level drop must not
-- become a single diagonal edge through a floor or wall.
local drop_path, _, drop_status = planner.find_path({x = 0, y = 3, z = 0},
	function(pos) return (pos.x == 0 and pos.y == 3) or (pos.x == 1 and pos.y == 0) end,
	function(pos) return pos.x == 1 and pos.y == 0 end, {range = 8})
assert(not drop_path and drop_status == "unreachable")

-- A standable upper floor must not prevent the planner from considering a
-- lower neighboring step that is required to continue the route.
local alternate_levels = {
	["0:4:0"] = true, ["1:4:0"] = true, ["1:3:0"] = true, ["2:2:0"] = true,
}
local alternate_path = planner.find_path({x = 0, y = 4, z = 0},
	function(pos) return alternate_levels[pos.x .. ":" .. pos.y .. ":" .. pos.z] == true end,
	function(pos) return pos.x == 2 and pos.y == 2 and pos.z == 0 end, {range = 8})
assert(alternate_path and #alternate_path == 3)
assert(alternate_path[2].x == 1 and alternate_path[2].y == 3)

print("planner.lua: ok")
