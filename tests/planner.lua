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

local none = planner.find_path({x = 0, y = 1, z = 0}, can_stand,
	function(pos) return pos.x == 9 end, {range = 8})
assert(none == nil)

print("planner.lua: ok")
