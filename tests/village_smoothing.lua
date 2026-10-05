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

-- terraform falls back to the original when the area will not load.
local fell
local env = {
	settlements = {schematic_table = schematics, surface_mat = {}},
	engine = {log = function(_, m) logs[#logs + 1] = m end},
	original = function() fell = true end,
	force_node = function() return {name = "ignore"} end,
	clear_trees = function() error("not reached") end,
}
assert(smoothing.terraform(plan_of({0, 0, 10}), nil, env) == false and fell, "fallback on unloaded area")
fell = nil
assert(smoothing.terraform({}, nil, env) == false and fell, "fallback on empty plan")

print("village_smoothing: ok")
