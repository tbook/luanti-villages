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
	function() return true end, function() return false end, {range = 8, max_nodes = 2})
assert(limited_visited == 2)
assert(limit_status == "search_limit")

print("planner.lua: ok")
