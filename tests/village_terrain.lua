-- Run with: lua tests/village_terrain.lua
local logs = {}
local function vec(x, y, z) return {x = x, y = y, z = z} end

-- Node ids for a few materials.
local names = {"air", "mcl_core:stone", "mcl_core:dirt", "mcl_core:dirt_with_grass", "mcl_core:water_source",
	"mcl_core:tree", "mcl_core:leaves", "mcl_core:sand", "mcl_flowers:tallgrass"}
local ids = {}
for i, n in ipairs(names) do ids[n] = i end
local ignore_id = 99
local registered = {
	["air"] = {walkable = false},
	["mcl_core:stone"] = {walkable = true}, ["mcl_core:dirt"] = {walkable = true},
	["mcl_core:dirt_with_grass"] = {walkable = true}, ["mcl_core:sand"] = {walkable = true},
	["mcl_core:tree"] = {walkable = true}, ["mcl_core:leaves"] = {walkable = true},
	["mcl_core:water_source"] = {walkable = false, liquidtype = "source"},
	["mcl_flowers:tallgrass"] = {walkable = false},
}

-- A fake map: flat grass at y=10, a hill (top 14) at x=3..4, a shaft down to a
-- cave floor at y=4 at x=6, a pond (water to y=10, bed at 7) at x=8, a tree
-- (trunk to 13, leaves at 14) at x=10, a tall-grass tuft on top of x=1,
-- and an unloaded column at x=12.
local map = {}
local function node(x, y, z)
	if x == 12 then return "ignore" end
	local key = x .. "," .. y .. "," .. z
	if map[key] then return map[key] end
	local top = 10
	if x == 3 or x == 4 then top = 14 end
	if x == 6 then
		if y > 4 then return "air" end
		if y == 4 then return "mcl_core:stone" end
	end
	if x == 8 then
		if y > 10 then return "air" end
		if y > 7 then return "mcl_core:water_source" end
		if y == 7 then return "mcl_core:sand" end
	end
	if x == 10 then
		if y >= 11 and y <= 13 then return "mcl_core:tree" end
		if y == 14 then return "mcl_core:leaves" end
		if y > 14 then return "air" end
	end
	if x == 1 and y == 11 then return "mcl_flowers:tallgrass" end
	if y > top then return "air" end
	if y == top then return "mcl_core:dirt_with_grass" end
	if y > top - 3 then return "mcl_core:dirt" end
	return "mcl_core:stone"
end

VoxelArea = {new = function(_, e)
	local a = {MinEdge = e.MinEdge, MaxEdge = e.MaxEdge}
	local dx = e.MaxEdge.x - e.MinEdge.x + 1
	local dy = e.MaxEdge.y - e.MinEdge.y + 1
	function a:index(x, y, z)
		return (z - e.MinEdge.z) * dx * dy + (y - e.MinEdge.y) * dx + (x - e.MinEdge.x) + 1
	end
	return a
end}

local reads = 0
local emerge_action, emerge_calls
local engine = {
	EMERGE_CANCELLED = "cancelled", EMERGE_ERRORED = "errored",
	CONTENT_IGNORE = ignore_id, CONTENT_AIR = ids.air,
	registered_nodes = registered,
	get_name_from_content_id = function(id) return names[id] or "ignore" end,
	pos_to_string = function(p) return ("(%d,%d,%d)"):format(p.x, p.y, p.z) end,
	log = function(_, m) table.insert(logs, m) end,
	emerge_area = function(minp, maxp, cb)
		for i = emerge_calls, 1, -1 do cb(nil, emerge_action, i - 1) end
	end,
	swap_node = function(pos, n) map[pos.x .. "," .. pos.y .. "," .. pos.z] = n.name end,
	get_node = function(pos) return {name = node(pos.x, pos.y, pos.z)} end,
}
-- get_data returns the map's ids for the area given to read_from_map.
local read_area
engine.get_voxel_manip = function()
	local vm = {}
	function vm:read_from_map(a, b) reads = reads + 1; read_area = {a, b}; return a, b end
	function vm:get_data()
		local a, b = read_area[1], read_area[2]
		local va = VoxelArea:new({MinEdge = a, MaxEdge = b})
		local data = {}
		for z = a.z, b.z do for y = a.y, b.y do for x = a.x, b.x do
			local n = node(x, y, z)
			data[va:index(x, y, z)] = n == "ignore" and ignore_id or ids[n]
		end end end
		return data
	end
	return vm
end
minetest = engine
local terrain = dofile("village_terrain.lua")

-- Area: rotated footprints and a margin.
local schematics = {
	{name = "belltower", hwidth = 5, hdepth = 5, hheight = 9},
	{name = "butcher", hwidth = 12, hdepth = 8, hheight = 10},
}
local plan = {
	{name = "belltower", pos = vec(0, 10, 0), rotat = "0"},
	{name = "butcher", pos = vec(20, 12, -3), rotat = "0"},
}
local area = terrain.area(plan, schematics, 0)
assert(area.minp.x == 0 and area.minp.z == -3, "min corner")
assert(area.maxp.x == 31 and area.maxp.z == 4, "unrotated butcher is 12 wide, 8 deep")
plan[2].rotat = "90"
area = terrain.area(plan, schematics, 0)
assert(area.maxp.x == 27 and area.maxp.z == 8, "90 degrees swaps width and depth")
plan[2].rotat = "270"
assert(terrain.area(plan, schematics, 0).maxp.x == 27, "270 swaps too")
area = terrain.area(plan, schematics, 5)
assert(area.minp.x == -5 and area.minp.z == -8 and area.maxp.x == 32 and area.maxp.z == 13, "margin on all sides")
assert(area.minp.y == 10 - 20 and area.maxp.y == 12 + 30, "vertical range")
assert(terrain.area({}, schematics, 0) == nil, "empty plan")
assert(terrain.area({{name = "mystery", pos = vec(0, 0, 0), rotat = "0"}}, schematics, 0) == nil, "unknown building")

-- Heights over the fake map.
local surface = {["mcl_core:dirt_with_grass"] = true, ["mcl_core:sand"] = true}
local lookup = assert(terrain.heights({minp = vec(0, 0, 0), maxp = vec(11, 20, 1)}, surface))
assert(reads == 1, "one VoxelManip pass")
local flat = lookup(0, 0)
assert(flat.y == 10 and flat.name == "mcl_core:dirt_with_grass" and not flat.liquid, "flat ground")
assert(flat.surface_y == 10 and flat.material == "mcl_core:dirt_with_grass", "surface material")
assert(lookup(3, 1).y == 14 and lookup(4, 0).y == 14, "hill")
local shaft = lookup(6, 0)
assert(shaft.y == 4 and shaft.name == "mcl_core:stone", "shaft opens onto the cave floor")
assert(shaft.surface_y == nil and shaft.material == nil, "no surface in a shaft")
local pond = lookup(8, 0)
assert(pond.y == 10 and pond.name == "mcl_core:water_source" and pond.liquid, "pond top is water")
assert(pond.surface_y == nil, "a pond bed is no surface: water above it, as find_surface sees it")
local tree = lookup(10, 0)
assert(tree.y == 14 and tree.name == "mcl_core:leaves" and not tree.liquid, "tree top is its leaves")
assert(tree.surface_y == nil, "no surface under a trunk")
local tuft = lookup(1, 0)
assert(tuft.y == 10 and tuft.surface_y == 10, "a plant is not solid and is open space above the surface")
assert(lookup(50, 50) == nil and lookup(0, 5) == nil, "outside the area")

local failed, why = terrain.heights({minp = vec(10, 0, 0), maxp = vec(13, 20, 1)}, surface)
assert(failed == nil and why:find("unloaded"), "unloaded area refuses to read")

-- Emerge first.
local result
emerge_calls, emerge_action = 3, "generated"
terrain.emerge(area, function(ok, err) result = {ok, err} end)
assert(result[1] == true, "all blocks loaded")
result = nil
emerge_action = engine.EMERGE_ERRORED
logs = {}
terrain.emerge(area, function(ok, err) result = {ok, err} end)
assert(result[1] == false and result[2]:find("emerge"), "failure is reported")
assert(#logs == 1 and logs[1]:find("%[living_villages%]"), "and logged once")

-- Column writes: raise a pond column, lower a hill.
terrain.set_column(8, 0, 10, 10, "mcl_core:dirt_with_grass", nil, engine)
assert(node(8, 10, 0) == "mcl_core:dirt_with_grass" and node(8, 9, 0) == "mcl_core:dirt"
	and node(8, 8, 0) == "mcl_core:dirt" and node(8, 7, 0) == "mcl_core:sand", "pond filled to the surface")
terrain.set_column(3, 0, 14, 10, "mcl_core:dirt_with_grass", nil, engine)
assert(node(3, 14, 0) == "air" and node(3, 11, 0) == "air" and node(3, 10, 0) == "mcl_core:dirt_with_grass", "hill cut")
assert(node(3, 9, 0) == "mcl_core:stone", "ground left alone below")

-- Installer.
local function new_env(missing)
	local calls = {}
	local env = {settlements = {}}
	for _, n in ipairs({"create_site_plan", "terraform", "find_surface"}) do
		if n ~= missing then env.settlements[n] = function() return "vanilla " .. n end end
	end
	return env, calls
end
local function replacement(target, needs)
	return {target = target, needs = needs, make = function(original)
		return function() return "ours " .. target .. " over " .. original() end
	end}
end
local setting
engine.settings = {get_bool = function(_, key, default)
	assert(key == "living_villages_smooth_villages")
	if setting == nil then return default end
	return setting
end}

local env = new_env()
local vanilla_plan = env.settlements.create_site_plan
logs = {}
assert(terrain.install(env, {replacement("create_site_plan", {"settlements.find_surface"}), replacement("terraform")}, engine))
assert(env.settlements.terraform() == "ours terraform over vanilla terraform", "installed, wrapping the original")
assert(env.settlements.create_site_plan() == "ours create_site_plan over vanilla create_site_plan")

local function stays(env, replacements, expect)
	local before = {}
	for k, v in pairs(env.settlements or {}) do before[k] = v end
	logs = {}
	assert(terrain.install(env, replacements, engine) == false)
	for k, v in pairs(before) do assert(env.settlements[k] == v, k .. " left in place") end
	assert(#logs == 1 and logs[1]:find("%[living_villages%]") and logs[1]:find(expect, 1, true), logs[1])
end
env = new_env("terraform")
stays(env, {replacement("create_site_plan"), replacement("terraform")}, "settlements.terraform")
env = new_env("find_surface")
stays(env, {replacement("create_site_plan", {"settlements.find_surface"})}, "settlements.find_surface")
env = new_env()
stays(env, {replacement("create_site_plan", {"mcl_vars.get_node"})}, "mcl_vars.get_node")
env = new_env()
stays(env, {replacement("create_site_plan"), {target = "terraform", make = function() end}}, "declined")
stays({}, {replacement("terraform")}, "settlements table")
setting = false
env = new_env()
stays(env, {replacement("terraform")}, "is off")
setting = true
assert(terrain.install(new_env(), {replacement("terraform")}, engine))

print("village_terrain: ok")
