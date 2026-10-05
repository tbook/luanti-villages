-- Run with: lua tests/lv_probe_metrics.lua
local M = dofile("tools/lv_probe/mod/lv_probe/metrics.lua")

local function check(name, ok)
	if not ok then error("FAILED: " .. name, 2) end
end

local table_ = {
	{name = "belltower", hwidth = 5, hdepth = 5},
	{name = "tavern", hwidth = 12, hdepth = 10},
}

-- Footprints swap width and depth on a quarter turn, as terraform does.
local f = M.footprint({name = "tavern", rotat = "0", pos = {x = 10, y = 5, z = 20}}, table_)
check("footprint 0", f.x1 == 10 and f.x2 == 21 and f.z1 == 20 and f.z2 == 29)
f = M.footprint({name = "tavern", rotat = "90", pos = {x = 10, y = 5, z = 20}}, table_)
check("footprint 90", f.x2 == 19 and f.z2 == 31)
check("footprint unknown", M.footprint({name = "nope", rotat = "0", pos = {x = 0, y = 0, z = 0}}, table_) == nil)

local info = {
	{name = "belltower", pos = {x = 0, y = 10, z = 0}},
	{name = "tavern", pos = {x = 20, y = 14, z = 0}},
	{name = "tavern", pos = {x = 200, y = 40, z = 0}},
}
local counts = M.building_counts(info)
check("counts", counts.belltower == 1 and counts.tavern == 2)
local floors = M.floor_heights(info)
check("floor range", floors.min == 10 and floors.max == 40 and floors.range == 30)
check("neighbor diff ignores the far building", floors.neighbor_diff == 4)
check("no buildings", M.floor_heights({}) == nil)

-- A flat 9x9 area with a one-block step along x = 5 and a wall at z = 9.
local function map(fn)
	local ground = {}
	for x = 0, 8 do
		ground[x] = {}
		for z = 0, 8 do ground[x][z] = fn(x, z) end
	end
	return ground
end
local flat = map(function(x) return x >= 5 and 11 or 10 end)
local steps = M.steps(flat, {})
check("one-block step", steps.largest == 1 and steps.over_one == 0)
local cliff = map(function(x) return x >= 5 and 20 or 10 end)
steps = M.steps(cliff, {})
check("cliff", steps.largest == 10 and steps.over_one == 9)
steps = M.steps(cliff, {{x1 = 5, z1 = 0, x2 = 8, z2 = 8}})
check("footprint columns are skipped", steps.largest == 0)

-- A single column 6 below its surroundings is a pit; a gentle slope is not.
local pit = map(function(x, z) return (x == 4 and z == 4) and 4 or 10 end)
local depth = M.pit_depth(pit)
check("pit depth", depth == 6)
check("slope has no pit", M.pit_depth(map(function(x) return x end)) == 0)

-- A pit with walls two blocks high traps; with a ramp it does not.
local no_wet = {}
local anchor = {x = 0, z = 0}
local trapped = map(function(x, z) return (x >= 3 and x <= 5 and z >= 3 and z <= 5) and 6 or 10 end)
local result = M.traps(trapped, no_wet, {}, {}, anchor)
check("pit traps its nine columns", result.columns == 9 and result.regions == 1)
-- A ramp of one-block steps up the side lets the villager climb out.
trapped[4][2], trapped[4][1], trapped[4][0] = 7, 8, 9
check("a ramp frees the pit", M.traps(trapped, no_wet, {}, {}, anchor).columns == 0)

-- Water columns are not walkable and do not count as traps.
local lake = map(function(x, z) return (x >= 3 and x <= 5 and z >= 3 and z <= 5) and 6 or 10 end)
local wet = {}
for x = 3, 5 do for z = 3, 5 do wet[x .. "," .. z] = true end end
check("a lake is not a trap", M.traps(lake, wet, {}, {}, anchor).columns == 0)

-- Fill and cut compare a floor with the natural ground under it.
local natural = map(function(x) return x < 4 and 5 or 12 end)
local fc = M.fill_and_cut({{pos = {x = 0, y = 9, z = 0}}}, {{x1 = 0, z1 = 0, x2 = 8, z2 = 0}}, natural)
check("fill and cut", fc.fill == 4 and fc.cut == 3)

local range = M.height_range(map(function(x) return x end))
check("height range", range.min == 0 and range.max == 8 and range.range == 8)
check("empty height range", M.height_range({}) == nil)
print("lv_probe_metrics ok")
