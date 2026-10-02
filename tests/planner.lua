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

-- A rise must not be taken when the source room's own ceiling blocks the jump,
-- even though the destination column is fully open (#56).
local low_roof = {
	["0:0:0"] = true, ["1:1:0"] = true,
}
local roof_blocked = {["0:3:0"] = true}
local function low_roof_can_stand(pos)
	return low_roof[pos.x .. ":" .. (pos.y - 1) .. ":" .. pos.z] == true
end
local function low_roof_clear(from_pos, to_pos, dy)
	if dy <= 0 then return true end
	return not roof_blocked[from_pos.x .. ":" .. (from_pos.y + 2) .. ":" .. from_pos.z]
end
local blocked_path, _, blocked_status = planner.find_path({x = 0, y = 1, z = 0}, low_roof_can_stand,
	function(pos) return pos.x == 1 and pos.y == 2 and pos.z == 0 end,
	{range = 8, clear = low_roof_clear})
assert(not blocked_path and blocked_status == "unreachable")

-- The same rise is taken once the source room's ceiling is clear.
roof_blocked = {}
local open_path = planner.find_path({x = 0, y = 1, z = 0}, low_roof_can_stand,
	function(pos) return pos.x == 1 and pos.y == 2 and pos.z == 0 end,
	{range = 8, clear = low_roof_clear})
assert(open_path and #open_path == 2)

-- A gate cell can be entered and left only in some combinations (#121). The
-- cell at (1,1) may be crossed straight along x, but not turned in, so a route
-- from the north must go round it.
--   z=0   . . #
--   z=1   . G .
--   z=2   . . .
local floor = {}
for x = 0, 2 do for z = 0, 2 do floor[x .. ":" .. z] = true end end
floor["2:0"] = nil
local function floor_can_stand(pos)
	return pos.y == 1 and floor[pos.x .. ":" .. pos.z] == true
end
local function is_gate(pos) return pos.x == 1 and pos.z == 1 end
local function straight_only(from, gate, to)
	return from.z == gate.z and to.z == gate.z
end
local function at_east_side(pos) return pos.x == 2 and pos.z == 1 end
local ungated = planner.find_path({x = 1, y = 1, z = 0}, floor_can_stand, at_east_side, {range = 8})
assert(ungated and #ungated == 3 and ungated[2].x == 1 and ungated[2].z == 1)
local gated = planner.find_path({x = 1, y = 1, z = 0}, floor_can_stand, at_east_side,
	{range = 8, gate = is_gate, crossing = straight_only})
assert(gated, "a route must exist round the gate")
assert(#gated > 3, "the direct route turns inside the gate")
for i, step in ipairs(gated) do
	if step.x == 1 and step.z == 1 then
		assert(gated[i - 1].z == 1 and gated[i + 1].z == 1, "the gate cannot be turned in")
	end
end
-- The same cell is used for a straight crossing, and a goal reached through it
-- is not lost to the state kept for another way in.
local straight = planner.find_path({x = 0, y = 1, z = 1}, floor_can_stand, at_east_side,
	{range = 8, gate = is_gate, crossing = straight_only})
assert(straight and #straight == 3 and straight[2].x == 1 and straight[2].z == 1)
-- With no way round, a forbidden turn leaves no route.
floor["0:0"], floor["0:1"], floor["0:2"], floor["1:2"] = nil, nil, nil, nil
local none_round, _, none_round_status = planner.find_path({x = 1, y = 1, z = 0}, floor_can_stand, at_east_side,
	{range = 8, gate = is_gate, crossing = straight_only})
assert(not none_round and none_round_status == "unreachable")

print("planner.lua: ok")
