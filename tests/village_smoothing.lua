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
-- Empty plan.
assert(smoothing.targets({}, flat(1), cfg).at(0, 0) == nil)

-- apply: record swaps on a fake map.
local swaps, map = {}, {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
local engine = {
	registered_nodes = {air = {walkable = false}, ["mcl_core:dirt"] = {walkable = true}},
	swap_node = function(p, n) map[key(p.x, p.y, p.z)] = n.name; swaps[#swaps + 1] = n.name end,
	get_node = function(p) return {name = map[key(p.x, p.y, p.z)] or "air"} end,
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
local ids = {air = 1, ["mcl_core:dirt_with_grass"] = 2, struct = 3, ["mcl_core:dirt"] = 4}
local names = {"air", "mcl_core:dirt_with_grass", "struct", "mcl_core:dirt"}
local IGNORE = 99
local world = {}
local function at(x, y, z)
	if x < -30 then return "ignore" end
	local k = world[x .. "," .. y .. "," .. z]
	if k then return k end
	if x == 8 and y == 16 and z == 1 then return "struct" end
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
assert(smoothing.terraform(plan_of({0, 0, 10, "mcl_core:dirt_with_grass"}), nil, env) == true and not fell,
	"smooths without waiting")
assert(loads > 0)
assert(world["8,16,1"] == nil, "structure block not removed")
assert(world["8,14,1"] == nil and world["8,15,1"] == nil, "ground beside the structure untouched")
assert(world["1,10,1"] == "mcl_core:dirt_with_grass" and world["1,14,1"] == "air", "footprint cut to the pad")
-- The ground beside it was smoothed to 13, so the shaft is filled from its floor to 13.
assert(world["13,13,1"] == "mcl_core:dirt_with_grass" and world["13,12,1"] == "mcl_core:dirt"
	and world["13,0,1"] == "mcl_core:dirt" and world["13,-7,1"] == "mcl_core:dirt", "shaft filled to the rim")
assert(world["13,14,1"] == nil, "nothing above the rim")
local joined = table.concat(logs, "\n")
assert(joined:find("holes: ", 1, true), "reports the fill")
assert(joined:find("unloaded blocks skipped", 1, true), "reports skipped blocks")

-- An empty plan falls back to the original.
assert(smoothing.terraform({}, nil, env) == false and fell, "fallback on empty plan")

print("village_smoothing: ok")
