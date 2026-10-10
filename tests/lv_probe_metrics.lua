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
-- Overhang slabs (#219): the probe reads the mod's own definition, so load the
-- real village_terrain.lua (no side effects, needs only a `minetest` table).
minetest = minetest or {}
local terrain = dofile("village_terrain.lua")

-- A column is a list of kinds from y = 1 upward.
local function column(spec)
	local kinds = {}
	for y, k in ipairs(spec) do kinds[y] = k end
	return function(y) return kinds[y] or "air" end
end
local function levels(spec)
	local top = #spec
	while spec[top] ~= "ground" do top = top - 1 end
	return M.levels(top, 1, column(spec), terrain.is_overhang)
end
local G, A = "ground", "air"
local function same(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end
-- Ground up to 10, then 5 air, then a 2-thick slab: the slab top (17) or the ground (10).
local slab = {G, G, G, G, G, G, G, G, G, G, A, A, A, A, A, G, G}
check("slab levels", same(levels(slab), {17, 10}))
-- A slab over only 3 air is a crust over a pocket: it stays ground (mod rule).
check("crust over a small pocket", same(levels({G, G, G, G, G, G, G, G, G, G, A, A, A, G, G}), {15}))
-- A run thicker than 6 is a hill, not a slab; a normal column is ground.
check("thick run", same(levels({G, G, G, A, A, A, A, A, G, G, G, G, G, G, G}), {15}))
check("normal column", same(levels({G, G, G, G, G}), {5}))
-- A slab over a slab over ground; leaves on the slab count as part of it.
check("stacked slabs", same(levels({G, G, A, A, A, A, G, A, A, A, A, "leaves", G}), {13, 7, 2}))
-- A slab over a pond: the bed under the water is not a level.
check("slab over water", same(levels({G, G, G, "water", "water", A, A, A, A, A, G, G}), {12}))
-- No ground under the slab inside the scan: it is no level at all.
check("slab over the void", same(M.levels(7, 1, column({A, A, A, A, A, A, G}), terrain.is_overhang), {}))

-- Choosing a level. A 9x9 area of ground at 10 with a block of slab columns in the
-- middle: levels {17, 10} (a slab over the village) or {10, 4} (a cave roof).
local function area(slab_levels)
	local lv = {}
	for x = 0, 8 do
		lv[x] = {}
		for z = 0, 8 do lv[x][z] = (x >= 3 and x <= 5 and z >= 3 and z <= 5) and slab_levels or {10} end
	end
	return lv
end
local ground, lowered = M.resolve(area({17, 10}), 10)
check("slab among level ground is skipped", ground[4][4] == 10 and ground[0][0] == 10 and lowered == 9)
ground, lowered = M.resolve(area({10, 4}), 10)
check("cave roof at the surrounding level stays", ground[4][4] == 10 and lowered == 0)
-- Slab columns only, no certain neighbours: the village floor decides.
local only = {[0] = {[0] = {17, 10}}}
check("floor decides: village under the slab", M.resolve(only, 11)[0][0] == 10)
check("floor decides: village on the slab", M.resolve(only, 17)[0][0] == 17)
-- A column that is only a slab over the void has no ground.
check("slab over the void is unknown", M.resolve({[0] = {[0] = {}}}, 10)[0][0] == nil)
check("median floor", M.median_floor({{pos = {y = 5}}, {pos = {y = 9}}, {pos = {y = 7}}}) == 7)

-- Next to a slab column, the corrected map has no wall; the raw map does.
local raw = map(function(x) return x >= 5 and 17 or 10 end)
local fixed = map(function() return 10 end)
check("raw slab reads as a wall", M.steps(raw, {}).largest == 7)
check("corrected slab is level", M.steps(fixed, {}).largest == 0)

print("lv_probe_metrics ok")
