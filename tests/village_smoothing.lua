-- Run with: lua tests/village_smoothing.lua
local logs = {}
minetest = {
	get_modpath = function() return "." end,
	log = function(level, m) table.insert(logs, level .. ": " .. m) end,
}
local smoothing = dofile("village_smoothing.lua")
local cfg = smoothing.config

local schematics = {{name = "house", hwidth = 4, hdepth = 4, hheight = 6}}
local function plan_of(...)
	local plan = {}
	for _, p in ipairs({...}) do
		plan[#plan + 1] = {name = "house", pos = {x = p[1], y = p[3], z = p[2]}, rotat = "0", surface_mat = p[4]}
	end
	return plan
end
local function pads_of(...)
	local pads = assert(smoothing.pads(plan_of(...), schematics))
	return pads
end

-- Pads: footprint, yard and unknown buildings.
local pads = pads_of({0, 0, 10})
assert(pads[1].x1 == 3 and pads[1].yx0 == -2 and pads[1].yx1 == 5 and pads[1].y == 10, "pad geometry")
assert(select(2, smoothing.pads({{name = "nope", pos = {x = 0, y = 0, z = 0}, rotat = "0"}}, schematics)), "unknown building")

local function flat(y) return function() return y end end

-- Flat ground at the pad height: nothing changes.
local t = smoothing.targets(pads, flat(10), cfg)
for z = t.z0, t.z1 do for x = t.x0, t.x1 do assert(t.at(x, z) == 10 and t.was(x, z) == 10) end end
assert(t.violations == 0)

-- Hill: ground 4 above the pad. Footprint and yard are exact, the skirt slopes
-- down to nothing at the radius, and nothing past it changes.
t = smoothing.targets(pads, flat(14), cfg)
assert(t.at(1, 1) == 10 and t.kind(1, 1) == "footprint", "footprint exact")
assert(t.at(-2, 1) == 10 and t.kind(-2, 1) == "yard", "yard flat")
assert(t.kind(-4, 1) == "skirt" and t.at(-4, 1) > 10 and t.at(-4, 1) < 14, "skirt between")
assert(t.at(-2 - cfg.radius, 1) == 14, "untouched at the radius")
for z = t.z0, t.z1 do for x = t.x0, t.x1 do
	assert(math.abs(t.at(x, z) - t.was(x, z)) <= cfg.cap, "cap")
end end
assert(t.violations == 0, "slope walkable, got " .. t.violations)

-- A pit far deeper than the cap: yard clamped to the cap, never beyond.
t = smoothing.targets(pads, flat(0), cfg)
assert(t.at(-2, 1) == 5, "yard capped")
assert(t.at(1, 1) == 10, "footprint is never capped")

-- Walls (#220): adjacent goals 6 or more apart with a footprint or yard on a side,
-- each pair once. Flat ground has none; a hillside 22 above the pad leaves the yard
-- at the cap, 7 above the footprint, along the pad's edge.
t = smoothing.targets(pads, flat(10), cfg)
assert(t.walls == 0 and t.wall_max == 0, "flat ground has no wall")
t = smoothing.targets(pads, flat(22), cfg)
assert(t.at(-2, 1) == 17 and t.at(1, 1) == 10, "yard is cap-limited")
assert(t.wall_max == 7, "tallest wall, got " .. t.wall_max)
local yard_footprint = 0
for z = t.z0, t.z1 do for x = t.x0, t.x1 do
	if t.kind(x, z) == "footprint" then
		for _, d in ipairs({{1, 0}, {0, 1}, {-1, 0}, {0, -1}}) do
			if t.kind(x + d[1], z + d[2]) == "yard" and math.abs(t.at(x, z) - t.at(x + d[1], z + d[2])) >= cfg.wall then
				yard_footprint = yard_footprint + 1
			end
		end
	end
end end
assert(yard_footprint > 0 and t.walls >= yard_footprint, "the yard and footprint sides are counted")
local expect = 0
for z = t.z0, t.z1 do for x = t.x0, t.x1 do
	for _, d in ipairs({{1, 0}, {0, 1}}) do
		local a, b = t.at(x, z), t.at(x + d[1], z + d[2])
		local ka, kb = t.kind(x, z), t.kind(x + d[1], z + d[2])
		if a and b and math.abs(a - b) >= cfg.wall and ((ka and ka ~= "skirt") or (kb and kb ~= "skirt"))
				and (a ~= t.was(x, z) or b ~= t.was(x + d[1], z + d[2])) then
			expect = expect + 1
		end
	end
end end
assert(t.walls == expect, "each pair once: " .. t.walls .. " vs " .. expect)
-- A lower wall setting counts more.
local low_wall = {}
for k, v in pairs(cfg) do low_wall[k] = v end
low_wall.wall = 3
assert(smoothing.targets(pads, flat(22), low_wall).walls >= t.walls)

-- Two pads at different heights: the ground between lies between them, and the
-- steps stay walkable.
local two = pads_of({0, 0, 10}, {10, 0, 14})
t = smoothing.targets(two, flat(12), cfg)
assert(t.at(1, 1) == 10 and t.at(11, 1) == 14)
local lo, hi = 99, -99
for x = 4, 9 do
	local v = t.at(x, 1)
	assert(v >= 10 and v <= 14, "between the pads")
	lo, hi = math.min(lo, v), math.max(hi, v)
end
assert(t.at(5, 1) <= t.at(6, 1) + 1 and t.at(8, 1) >= t.at(5, 1), "rises toward the higher pad")
-- A cliff in the natural ground is relaxed in the skirt, within the cap.
t = smoothing.targets(pads, function(x) return x < -6 and 20 or 10 end, cfg)
for z = t.z0, t.z1 do for x = t.x0, t.x1 do
	assert(math.abs(t.at(x, z) - t.was(x, z)) <= cfg.cap)
end end

-- nil heights (water) are left alone and ignored as neighbors.
t = smoothing.targets(pads, function(x, z) if x == -4 then return nil end return 12 end, cfg)
assert(t.at(-4, 1) == nil and t.was(-4, 1) == nil)
-- An overhang (second return of height_at) in the skirt or the yard (x=-1) is not a column
-- (#209): no target, no pad. In the footprint it is set like any other.
t = smoothing.targets(pads, function(x, z) return 30, x == -6 or x == -1 or x == 1 end, cfg)
assert(t.at(-6, 1) == nil and t.was(-6, 1) == nil and t.pad(-6, 1) == nil and t.kind(-6, 1) == nil, "skirt overhang left alone")
assert(t.at(-5, 1) ~= nil and t.at(-7, 1) ~= nil, "its neighbours are still smoothed")
assert(t.at(-1, 1) == nil and t.kind(-1, 1) == nil, "yard overhang left alone")
assert(t.at(1, 1) == 10, "footprint overhang is set")
-- Empty plan.
assert(smoothing.targets({}, flat(1), cfg).at(0, 0) == nil)

-- The slope limit (#235). The sweep it replaced clamped a skirt column to each
-- neighbor in turn, so when two neighbors were more than 2 apart the last one won
-- and the column could stay several blocks off a yard it had the range to match.
do
	-- A single pad at 10 (yard x -2..5), ground 13 under the yard. West of it, the
	-- skirt column x=-3 is 18 high except a notch at z=1 that is 12 (as in the
	-- 2002 example: a yard at 8 beside a skirt column left at 19 that 14 could have
	-- been cut to 9): its own range 7..17 reaches the yard's 10, its neighbors' 13..23 do not.
	local function notch(x, z)
		if x == -3 then return z == 1 and 12 or 18 end
		if x == -4 then return 12 end
		if x <= -5 then return 14 end
		return 13
	end
	local nt = smoothing.targets(pads, notch, cfg)
	assert(nt.at(-2, 1) == 10 and nt.kind(-2, 1) == "yard" and nt.kind(-3, 1) == "skirt")
	assert(math.abs(nt.at(-3, 1) - nt.at(-2, 1)) <= 1, "the notch is within a block of the yard, got " .. nt.at(-3, 1))
	assert(nt.at(-3, 0) == 13 and nt.at(-3, 2) == 13, "the neighbors that cannot reach it stay at their cap, got " .. nt.at(-3, 0))
	for z = nt.z0, nt.z1 do for x = nt.x0, nt.x1 do
		if nt.at(x, z) then assert(math.abs(nt.at(x, z) - nt.was(x, z)) <= cfg.cap, "cap") end
	end end

	-- No order: the same terrain mirrored across the pad (x -> 3 - x) gives the mirrored result.
	local function mirrored(x, z) return notch(3 - x, z) end
	local mt = smoothing.targets(pads, mirrored, cfg)
	for z = nt.z0, nt.z1 do for x = nt.x0, nt.x1 do
		assert(nt.at(x, z) == mt.at(3 - x, z), "mirror (" .. x .. "," .. z .. "): " .. tostring(nt.at(x, z)) .. " vs " .. tostring(mt.at(3 - x, z)))
	end end

	-- Two pads, 10 and 14, on ground 12: the yards are exact, the skirt between them
	-- rises from one to the other a block at a time, each skirt column beside a yard
	-- within a block of that yard's own height (not the other pad's).
	local two_pads = pads_of({0, 0, 10}, {14, 0, 14})
	local tw = smoothing.targets(two_pads, flat(12), cfg)
	assert(tw.at(5, 1) == 10 and tw.kind(5, 1) == "yard" and tw.at(12, 1) == 14 and tw.kind(12, 1) == "yard")
	local last = tw.at(5, 1)
	for x = 6, 11 do
		local v = tw.at(x, 1)
		assert(tw.kind(x, 1) == "skirt" and v >= last and v - last <= 1, "monotone ramp at " .. x .. ": " .. v .. " after " .. last)
		last = v
	end
	assert(tw.at(12, 1) - last <= 1, "ramp reaches the second yard")
	assert(tw.violations == 0, "walkable between two pads, " .. tw.violations)

	-- An interval that is empty: a yard column (natural 30, so 25) beside a skirt column whose
	-- ground is 40 (range 35..45) cannot be matched. It takes the closest feasible value, the
	-- lowest the cap allows, and the pair is counted as a step.
	local gap = smoothing.targets(pads, function(x) return x == -3 and 40 or 30 end, cfg)
	assert(gap.at(-2, 1) == 25 and gap.at(-3, 1) == 35, "closest feasible value, got " .. gap.at(-3, 1))
	assert(gap.violations > 0 and gap.walls > 0, "the gap is counted, got " .. gap.violations)

	-- Flat ground at the pad's height or a plain hill: nothing odd happens (checked above), and the
	-- same input gives the same output, run to run.
	local function rough(x, z) return 12 + ((x * 7 + z * 13) % 11) % 6 end
	local first = smoothing.targets(pads, rough, cfg)
	local second = smoothing.targets(pads, rough, cfg)
	for z = first.z0, first.z1 do for x = first.x0, first.x1 do
		assert(first.at(x, z) == second.at(x, z), "deterministic")
	end end
	assert(first.violations == second.violations)

	-- Over many rough grounds and two pads, no skirt column is left more than a block off a
	-- yard or footprint column that its own range could have matched.
	local seed = 17
	local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return math.floor(seed / 65536) % n end
	local left = 0
	for _ = 1, 40 do
		local rp = pads_of({0, 0, 10 + rnd(8)}, {14, 3, 10 + rnd(8)})
		local amp, scale, cells = 3 + rnd(12), 1 + rnd(4), {}
		local rt = smoothing.targets(rp, function(x, z)
			local key = math.floor(x / scale) .. "," .. math.floor(z / scale)
			if not cells[key] then cells[key] = 10 + rnd(amp * 2) - amp end
			return cells[key]
		end, cfg)
		for z = rt.z0, rt.z1 do for x = rt.x0, rt.x1 do
			local a = rt.at(x, z)
			if a and rt.kind(x, z) == "skirt" then
				for _, d in ipairs({{1, 0}, {0, 1}, {-1, 0}, {0, -1}}) do
					local b, kb = rt.at(x + d[1], z + d[2]), rt.kind(x + d[1], z + d[2])
					local w = rt.was(x, z)
					if b and (kb == "yard" or kb == "footprint") and b - 1 <= w + cfg.cap and b + 1 >= w - cfg.cap
							and math.abs(a - b) > 1 then
						left = left + 1
					end
				end
			end
		end end
	end
	assert(left == 0, left .. " skirt columns left off a yard they could match")

	-- Cost: a 400 x 400 area (radius 150 round four pads) is planned in a few seconds at most.
	local big = {}
	for k, v in pairs(cfg) do big[k] = v end
	big.radius = 150
	local bp = pads_of({0, 0, 12}, {60, 40, 18}, {120, 10, 9}, {40, -70, 15})
	local started = os.clock()
	local bt = smoothing.targets(bp, function(x, z)
		return 12 + math.floor(6 * math.sin(x / 7) + 5 * math.cos(z / 5) + 4 * math.sin((x + z) / 3))
	end, big)
	local took = os.clock() - started
	assert((bt.x1 - bt.x0 + 1) * (bt.z1 - bt.z0 + 1) >= 300 * 300, "a large area")
	assert(took < 10, "targets on a large area took " .. took .. " s")
end

-- apply: record swaps on a fake map.
local swaps, map = {}, {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local engine = {
	registered_nodes = {air = {walkable = false}, ["mcl_core:dirt"] = {walkable = true}, ["mcl_core:stone"] = {walkable = true}},
	swap_node = function(p, n) map[key(p.x, p.y, p.z)] = n.name; swaps[#swaps + 1] = n.name end,
	get_node = function(p) return {name = map[key(p.x, p.y, p.z)] or (p.y <= 0 and "mcl_core:stone" or "air")} end, -- ground at y 0
}
local small = pads_of({0, 0, 10, "mcl_core:sand"})
local tt = smoothing.targets(small, flat(14), cfg)
local stats = smoothing.apply(small, tt, function() return {y = 14} end, cfg, engine)
assert(stats.cut > 0 and stats.filled == 0 and stats.steepest == 4, "cut counts")
assert(map[key(1, 10, 1)] == "mcl_core:sand", "surface at the pad height")
assert(map[key(1, 14, 1)] == "air" and map[key(1, 17, 1)] == "air", "above removed")
assert(map[key(1, 9, 1)] == "mcl_core:sandstone", "sandstone under sand (air below filled)")

map = {}
tt = smoothing.targets(small, flat(7), cfg)
stats = smoothing.apply(small, tt, function() return {y = 7} end, cfg, engine)
assert(stats.filled > 0 and map[key(1, 10, 1)] == "mcl_core:sand" and map[key(1, 8, 1)] == "mcl_core:sandstone")

-- terraform on a fake map: flat ground at 14 and a structure block at (8,16,1).
-- The structure and its neighbors are kept.
local ids = {air = 1, ["mcl_core:dirt_with_grass"] = 2, struct = 3, ["mcl_core:dirt"] = 4,
	["mcl_core:tree"] = 5, ["mcl_core:cactus"] = 6, ["mcl_bamboo:bamboo"] = 7, ["mcl_farming:sweet_berry_bush_3"] = 8,
	["mcl_core:water_source"] = 9, ["mcl_core:leaves"] = 10}
local names = {"air", "mcl_core:dirt_with_grass", "struct", "mcl_core:dirt", "mcl_core:tree", "mcl_core:cactus",
	"mcl_bamboo:bamboo", "mcl_farming:sweet_berry_bush_3", "mcl_core:water_source", "mcl_core:leaves"}
local IGNORE = 99
local world = {}
local function at(x, y, z)
	if x < -30 then return "ignore" end
	local k = world[x .. "," .. y .. "," .. z]
	if k then return k end
	if x == 8 and y == 16 and z == 1 then return "struct" end
	-- A 5-high trunk and a 3-high cactus on the flat ground in the holes' reach.
	if x == 26 and z == 5 and y >= 15 and y <= 19 then return "mcl_core:tree" end
	if x == 26 and z == 9 and y >= 15 and y <= 17 then return "mcl_core:cactus" end
	-- Bamboo stalks (15..18) and sweet berry bushes (15) on the flat ground, in the
	-- footprints of the first pad (cut to 10) and of a third one at 20 (filled).
	if (x == 81 and z == 1 or x == 2 and z == 3) and y >= 15 and y <= 18 then return "mcl_bamboo:bamboo" end
	if (x == 82 and z == 2 or x == 2 and z == 2) and y == 15 then return "mcl_farming:sweet_berry_bush_3" end
	-- Blocks under the shaft floor are not generated yet.
	if x >= 13 and x <= 14 and z >= 0 and z <= 2 and y < -20 then return "ignore" end
	-- A shaft in the gap beyond the smoothing, down to a floor at -8.
	if x >= 13 and x <= 14 and z >= 0 and z <= 2 and y > -8 and y <= 14 then return "air" end
	return y <= 14 and "mcl_core:dirt_with_grass" or "air"
end
VoxelArea = {new = function(_, e)
	local dx, dy = e.MaxEdge.x - e.MinEdge.x + 1, e.MaxEdge.y - e.MinEdge.y + 1
	return {index = function(_, x, y, z)
		return (z - e.MinEdge.z) * dx * dy + (y - e.MinEdge.y) * dx + (x - e.MinEdge.x) + 1
	end}
end}
local fake = {
	CONTENT_IGNORE = IGNORE, CONTENT_AIR = 1,
	registered_nodes = {
		air = {walkable = false}, ["mcl_core:dirt_with_grass"] = {walkable = true},
		struct = {walkable = true, is_ground_content = false, groups = {}},
		["mcl_core:tree"] = {walkable = true, groups = {tree = 1}}, ["mcl_core:cactus"] = {walkable = true},
		["mcl_bamboo:bamboo"] = {walkable = true, groups = {plant = 1}},
		["mcl_farming:sweet_berry_bush_3"] = {walkable = false, groups = {plant = 1}},
		["mcl_core:dirt"] = {walkable = true},
		["mcl_core:water_source"] = {walkable = false, liquidtype = "source"},
		["mcl_core:leaves"] = {walkable = true, groups = {leaves = 1}},
	},
	get_name_from_content_id = function(id) return names[id] or "ignore" end,
	pos_to_string = function(p) return ("(%d,%d,%d)"):format(p.x, p.y, p.z) end,
	log = function(_, m) logs[#logs + 1] = m end,
	swap_node = function(p, n) world[p.x .. "," .. p.y .. "," .. p.z] = n.name end,
	get_node = function(p) return {name = at(p.x, p.y, p.z)} end,
	get_voxel_manip = function()
		local vm, a, b = {}
		function vm:read_from_map(x, y) a, b = x, y; return x, y end
		function vm:get_data()
			local data, va = {}, VoxelArea:new({MinEdge = a, MaxEdge = b})
			for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
				local n = at(x, y, z)
				data[va:index(x, y, z)] = n == "ignore" and IGNORE or ids[n]
			end end end
			return data
		end
		return vm
	end,
}
local fragments = dofile("village_fragments.lua")
local test = fragments.structure_test(fake)
local fell, loads = nil, 0
local env = {
	settlements = {schematic_table = schematics, surface_mat = {["mcl_core:dirt_with_grass"] = true}},
	engine = fake,
	original = function() fell = true end,
	load_node = function(pos) loads = loads + 1; return {name = at(pos.x, pos.y, pos.z)} end,
	scan = function(area) return fragments.scan_structures(area, test, fake) end,
	clear_trees = function() end,
}
-- An overhang in the skirt (#209): a 2-thick slab (y 30..31) over 4 air (26..29) above
-- the real ground at 14, at x=-6; a normal hill (top 18) at x=-6, z=2 is still cut.
for y = 15, 40 do world["-6,"..y..",1"] = "air" end
for y = 30, 31 do world["-6,"..y..",1"] = "mcl_core:dirt_with_grass" end
for y = 15, 40 do world["-6,"..y..",4"] = "air" end
for y = 30, 31 do world["-6,"..y..",4"] = "mcl_core:dirt_with_grass" end
for y = 32, 34 do world["-6,"..y..",4"] = "mcl_bamboo:bamboo" end
for y = -30, 12 do world["4," .. y .. ",5"] = "mcl_core:dirt" end
world["4,14,5"], world["4,13,5"], world["4,15,5"] = "mcl_core:water_source", "mcl_core:water_source", "mcl_core:leaves"
for y = 15, 17 do world["-6,"..y..",2"] = "mcl_core:dirt" end
world["-6,18,2"] = "mcl_core:dirt_with_grass"
assert(smoothing.terraform(plan_of({0, 0, 10, "mcl_core:dirt_with_grass"}, {40, 0, 14, "mcl_core:dirt_with_grass"}, {80, 0, 20, "mcl_core:dirt_with_grass"}), nil, env) == true and not fell,
	"smooths without waiting")
assert(loads > 0)
assert(world["8,16,1"] == nil, "structure block not removed")
assert(world["8,14,1"] == nil and world["8,15,1"] == nil, "ground beside the structure untouched")
assert(world["1,10,1"] == "mcl_core:dirt_with_grass" and world["1,14,1"] == "air", "footprint cut to the pad")
-- Growth on a column the smoothing moves (#214, #224). The clearing of trees is stubbed
-- out here, so the smoothing alone must cope. A 4-high bamboo stalk on ground 14 under a
-- pad at 20: the ground is read under the stalk, so the fill reaches 20 with no stalk left
-- inside it or over it; a berry bush on a raised column stands on the new surface.
for y = 15, 19 do assert(at(81, y, 1) == "mcl_core:dirt", "no stalk inside the fill at y=" .. y .. ": " .. at(81, y, 1)) end
assert(at(81, 20, 1) == "mcl_core:dirt_with_grass" and at(81, 21, 1) == "air", "surface at the pad, nothing over it")
assert(at(82, 20, 2) == "mcl_core:dirt_with_grass" and at(82, 21, 2) == "mcl_farming:sweet_berry_bush_3", "bush re-seated on the raised ground")
assert(at(82, 15, 2) == "mcl_core:dirt", "the old bush spot is fill")
-- Cut to 10: the stalk is gone above the surface and the bush stands on it.
for y = 11, 18 do assert(at(2, y, 3) == "air", "stalk removed from the cut column at y=" .. y) end
assert(at(2, 10, 3) == "mcl_core:dirt_with_grass")
assert(at(2, 10, 2) == "mcl_core:dirt_with_grass" and at(2, 11, 2) == "mcl_farming:sweet_berry_bush_3", "bush moved down with the cut")
assert(at(2, 15, 2) == "air", "no bush left at the old height")
-- A slab with a stalk on it (x=-6, z=4: slab 30..31 over air, bamboo 32..34) is an overhang
-- too, and a pond under leaves is water, not ground (x=4, z=5 in the yard).
for y = 15, 40 do
	local want = (y == 30 or y == 31) and "mcl_core:dirt_with_grass" or (y >= 32 and y <= 34) and "mcl_bamboo:bamboo" or "air"
	assert(world["-6," .. y .. ",4"] == want, "stalk slab column changed at y=" .. y .. ": " .. tostring(world["-6," .. y .. ",4"]))
end
assert(world["4,14,5"] == "mcl_core:water_source" and world["4,15,5"] == "mcl_core:leaves", "pond under leaves left alone")
for y = 0, 14 do assert(world["-6," .. y .. ",4"] == nil, "ground under the stalk slab written at y=" .. y) end
-- The whole overhang column is as nature made it: slab at 30..31, air 15..29 and above 31,
-- and the ground (14 and below) untouched.
for y = 15, 40 do
	local want = (y == 30 or y == 31) and "mcl_core:dirt_with_grass" or "air"
	assert(world["-6," .. y .. ",1"] == want, "overhang column changed at y=" .. y .. ": " .. tostring(world["-6," .. y .. ",1"]))
end
for y = 0, 14 do assert(world["-6," .. y .. ",1"] == nil, "ground under the overhang written at y=" .. y) end
assert(world["-6,18,2"] == "air", "a normal hill beside it is still cut")
-- The ground beside it was left at 14 (the pit is no source for the skirt, #235), so the shaft is filled from its floor to 14.
assert(world["13,14,1"] == "mcl_core:dirt_with_grass" and world["13,13,1"] == "mcl_core:dirt"
	and world["13,0,1"] == "mcl_core:dirt" and world["13,-7,1"] == "mcl_core:dirt", "shaft filled to the rim")
assert(world["13,15,1"] == nil, "nothing above the rim")
-- A tree or a cactus is not a peak: no ramp is built round it.
for key in pairs(world) do
	local x, z = key:match("^(-?%d+),%-?%d+,(-?%d+)$")
	x, z = tonumber(x), tonumber(z)
	assert(not (x >= 23 and x <= 29 and z >= 2 and z <= 12), "nothing built round a trunk or a cactus: " .. key)
end
local joined = table.concat(logs, "\n")
assert(joined:find("holes: ", 1, true), "reports the fill")
assert(joined:find("unloaded blocks skipped", 1, true), "reports skipped blocks")

-- An empty plan falls back to the original.
assert(smoothing.terraform({}, nil, env) == false and fell, "fallback on empty plan")

print("village_smoothing: ok")
