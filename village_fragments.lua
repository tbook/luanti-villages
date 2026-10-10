-- Keeps villages from leaving fragments of what was there before (#141, part of
-- #133): half trees and floating leaves, and slices of ruined portals and
-- pillager outposts. VoxeLibre places those during mapgen and records nothing,
-- and the village is built after them.
--
-- Trees are common, so clear_trees removes each one whole. Foreign structures
-- are rarer and can't be cleaned up well, so scan_structures finds them for the
-- site planner (site_planner.lua) to plan around.
--
-- Loading this has no side effects. Everything takes the engine table as an
-- optional last argument (default `minetest`) so tests can stub it.
local core = minetest
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")

local M = {}

M.config = {
	cap_nodes = 400, -- a tree fill that reaches this many nodes is a canopy linking many trees
	cap_radius = 10, -- or that strays this far sideways from the node it started at
	cap_height = 40, -- or this far up or down (a jungle tree is taller than it is wide)
}

-- Natural nodes that are not ground content, so they are not structures: trunks,
-- leaves, plants, liquids, snow and ice, and the odd natural block, by group or
-- by a substring of the name (matched as settlements.find_surface does). Not the
-- broad `deco_block` group: fences, walls and chests, which structures are
-- full of, are in it too.
local NATURAL_GROUPS = {"tree", "leaves", "leafdecay", "plant", "flora", "flower", "sapling",
	"vines", "snow", "ice", "water", "lava"}
local NATURAL_WORDS = {"bedrock", "kelp", "seagrass", "coral", "lily", "mushroom", "mangrove", "propagule", "bamboo",
	"vine", "cactus", "snow", "ice", "tree", "leaves", "obsidian"}

-- Whether a node is part of a structure: its definition says it is not ground
-- content, and it is not on the natural whitelist. The result is cached per node
-- name, so the registered-node list is walked once.
-- `extra_words` adds name substrings to the whitelist.
function M.structure_test(engine, extra_words)
	engine = engine or core
	local words = {}
	for _, w in ipairs(NATURAL_WORDS) do words[#words + 1] = w end
	for _, w in ipairs(extra_words or {}) do words[#words + 1] = w end
	local cache = {}
	return function(name)
		local known = cache[name]
		if known ~= nil then return known end
		local def = engine.registered_nodes[name]
		local structure = false
		if def and def.is_ground_content == false and (def.liquidtype or "none") == "none" then
			structure = true
			local groups = def.groups or {}
			for _, g in ipairs(NATURAL_GROUPS) do
				if (groups[g] or 0) > 0 then structure = false break end
			end
			if structure then
				for _, w in ipairs(words) do
					if name:find(w, 1, true) then structure = false break end
				end
			end
		end
		cache[name] = structure
		return structure
	end
end

-- Read the area once, with a single VoxelManip pass, and return a map of its
-- structure columns: at(x, z) -> name, y of the first structure node found in
-- the column, and find(x0, z0, x1, z1) -> name, x, y, z of one in that
-- rectangle. A column with unloaded nodes and no structure counts as a structure
-- named "unloaded" when `strict` is set, because the planner can't call it clear;
-- otherwise unloaded nodes count as no structure.
function M.scan_structures(area, test, engine, strict)
	engine = engine or core
	test = test or M.structure_test(engine)
	local vm = engine.get_voxel_manip()
	local emin, emax = vm:read_from_map(area.minp, area.maxp)
	local data = vm:get_data()
	local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local structure_of = {}
	local function is_structure(id)
		local known = structure_of[id]
		if known == nil then
			known = test(engine.get_name_from_content_id(id))
			structure_of[id] = known
		end
		return known
	end
	local columns, count = {}, 0
	for z = area.minp.z, area.maxp.z do
		for x = area.minp.x, area.maxp.x do
			local unloaded
			for y = area.maxp.y, area.minp.y, -1 do
				local id = data[va:index(x, y, z)]
				if id == engine.CONTENT_IGNORE then
					unloaded = unloaded or y
				elseif is_structure(id) then
					columns[z] = columns[z] or {}
					columns[z][x] = {name = engine.get_name_from_content_id(id), y = y}
					count = count + 1
					unloaded = nil
					break
				end
			end
			if unloaded and strict then
				columns[z] = columns[z] or {}
				columns[z][x] = {name = "unloaded", y = unloaded}
				count = count + 1
			end
		end
	end
	local scan = {count = count}
	function scan.at(x, z)
		local hit = columns[z] and columns[z][x]
		if hit then return hit.name, hit.y end
	end
	function scan.find(x0, z0, x1, z1)
		for z = z0, z1 do
			local row = columns[z]
			if row then
				for x = x0, x1 do
					if row[x] then return row[x].name, x, row[x].y, z end
				end
			end
		end
	end
	return scan
end

local function is_trunk(name, def)
	return (def and def.groups and (def.groups.tree or 0) > 0) or false
end

local function is_leaves(name, def)
	return (def and def.groups and (def.groups.leaves or 0) > 0) or name:find("leaves", 1, true) ~= nil
end

-- Remove every tree that has a trunk or leaf node inside the zone, whole.
-- `zone` is a list of boxes {minp, maxp} (the pads, yards and skirt, in world
-- coordinates). From each trunk or leaf node in a box, flood-fill through
-- connected trunk and leaf nodes (26-neighborhood) and remove them all, in or
-- outside the zone. A fill that reaches the cap clips to the zone instead, so a
-- dense canopy linking many trees isn't eaten. Reads and writes the area with a
-- single VoxelManip, so it needs the blocks loaded; see village_terrain.emerge.
-- Snow layers resting on a removed node go with it. Returns {seeds, removed,
-- clipped, snow}: fills started, nodes removed, fills that hit the cap, and
-- snow layers removed. A layer above the VoxelManip
-- region (the top of the zone plus the cap height) is not seen.
-- Known limit: like trees, stalks and their vines are removed near ruined portals and
-- outposts too, where the smoothing leaves the ground alone; clear_trees does not know
-- the structures.
-- Bamboo, cactus and sugar cane inside the zone go too (`growth`), as they would
-- otherwise be read as ground by the smoothing and buried or left under new
-- blocks (#224), and so do vines hanging on a removed node, with the vines
-- under them (`vines`, #225; a vine on a standing node stays), and so does the top half of a two-high plant left
-- on a removed leaf (`plant_tops`: its bottom half was under the leaves).
function M.clear_trees(zone, config, engine)
	engine = engine or core
	config = config or M.config
	local radius, height = config.cap_radius, config.cap_height
	local lo, hi
	for _, box in ipairs(zone) do
		lo = lo or {x = box.minp.x, y = box.minp.y, z = box.minp.z}
		hi = hi or {x = box.maxp.x, y = box.maxp.y, z = box.maxp.z}
		lo.x, lo.y, lo.z = math.min(lo.x, box.minp.x), math.min(lo.y, box.minp.y), math.min(lo.z, box.minp.z)
		hi.x, hi.y, hi.z = math.max(hi.x, box.maxp.x), math.max(hi.y, box.maxp.y), math.max(hi.z, box.maxp.z)
	end
	local stats = {seeds = 0, removed = 0, clipped = 0, snow = 0, growth = 0, vines = 0, plant_tops = 0}
	if not lo then return stats end
	local region_min = {x = lo.x - radius, y = lo.y - height, z = lo.z - radius}
	local region_max = {x = hi.x + radius, y = hi.y + height, z = hi.z + radius}

	local vm = engine.get_voxel_manip()
	local emin, emax = vm:read_from_map(region_min, region_max)
	local data = vm:get_data()
	local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local air = engine.CONTENT_AIR

	local tree_of = {}
	local function is_tree(id)
		local known = tree_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			local def = engine.registered_nodes[name]
			known = is_trunk(name, def) or is_leaves(name, def)
			tree_of[id] = known
		end
		return known
	end
	-- Snow layers rest on leaves and trunks in cold biomes. They are not part of the
	-- tree, so once it is gone they would float, and village_terrain.heights reads a
	-- floating layer (mcl_core:snow is a village surface) as the ground (#211).
	local snow_of = {}
	local function is_snow_layer(id)
		local known = snow_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			known = name:find("^mcl_core:snow") ~= nil and name ~= "mcl_core:snowblock"
			snow_of[id] = known
		end
		return known
	end
	-- The top half of a two-high plant (VoxeLibre's double_plant group is 2 on it) that
	-- stands on a removed node: a tree's leaves grew over its bottom half, and without them
	-- the top floats.
	local top_of = {}
	local function is_plant_top(id)
		local known = top_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			local def = engine.registered_nodes[name]
			known = (def and def.groups and (def.groups.double_plant or 0) == 2) or false
			top_of[id] = known
		end
		return known
	end
	-- Stalks that stand in a column, and the vines that climb on trees.
	local stalk_of, vine_of = {}, {}
	local function is_stalk(id)
		local known = stalk_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			known = terrain.is_growth(name, engine.registered_nodes[name])
			stalk_of[id] = known
		end
		return known
	end
	local function is_vine(id)
		local known = vine_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			local def = engine.registered_nodes[name]
			known = name == "mcl_core:vine" or (def and def.groups and (def.groups.vines or 0) > 0) or false
			vine_of[id] = known
		end
		return known
	end
	local function in_zone(x, y, z)
		for _, box in ipairs(zone) do
			if x >= box.minp.x and x <= box.maxp.x and y >= box.minp.y and y <= box.maxp.y
					and z >= box.minp.z and z <= box.maxp.z then
				return true
			end
		end
		return false
	end

	-- One fill from a seed. Returns the visited nodes and whether it hit the cap.
	local function fill(sx, sy, sz)
		local seen, nodes = {[va:index(sx, sy, sz)] = true}, {{sx, sy, sz}}
		local capped = false
		local head = 1
		while head <= #nodes do
			local x, y, z = nodes[head][1], nodes[head][2], nodes[head][3]
			head = head + 1
			for dz = -1, 1 do for dy = -1, 1 do for dx = -1, 1 do
				local nx, ny, nz = x + dx, y + dy, z + dz
				if (dx ~= 0 or dy ~= 0 or dz ~= 0)
						and nx >= emin.x and nx <= emax.x and ny >= emin.y and ny <= emax.y
						and nz >= emin.z and nz <= emax.z then
					local index = va:index(nx, ny, nz)
					if not seen[index] and is_tree(data[index]) then
						if math.max(math.abs(nx - sx), math.abs(nz - sz)) > radius or math.abs(ny - sy) > height then
							capped = true -- the tree runs on past the limit
						else
							seen[index] = true
							nodes[#nodes + 1] = {nx, ny, nz}
						end
					end
				end
			end end end
			if #nodes >= config.cap_nodes then capped = true break end
		end
		return nodes, capped
	end

	local gone = {} -- tree nodes removed, for the vines that hung on them
	for z = lo.z, hi.z do
		for y = lo.y, hi.y do
			for x = lo.x, hi.x do
				if x >= emin.x and x <= emax.x and y >= emin.y and y <= emax.y and z >= emin.z and z <= emax.z
						and in_zone(x, y, z) then
					local index = va:index(x, y, z)
					if is_tree(data[index]) then
						stats.seeds = stats.seeds + 1
						local nodes, capped = fill(x, y, z)
						if capped then stats.clipped = stats.clipped + 1 end
						for _, n in ipairs(nodes) do
							if not capped or in_zone(n[1], n[2], n[3]) then
								data[va:index(n[1], n[2], n[3])] = air
								stats.removed = stats.removed + 1
								gone[#gone + 1] = n
								if n[2] + 1 <= emax.y then
									local above = va:index(n[1], n[2] + 1, n[3])
									if is_snow_layer(data[above]) then
										data[above] = air
										stats.snow = stats.snow + 1
									elseif is_plant_top(data[above]) then
										data[above] = air
										stats.plant_tops = stats.plant_tops + 1
									end
								end
							end
						end
					elseif is_stalk(data[index]) then
						data[index] = air
						stats.growth = stats.growth + 1
					end
				end
			end
		end
	end

	-- A vine whose support was removed (the node its param2 points at: a trunk, a leaf, or
	-- the vine above it) would be left in the air: a vine drops only when something changes
	-- beside it, and a write like this one sends no update. A vine on a standing node (a
	-- cliff, a leaf outside the fill) stays. Without param2 data any neighbouring vine goes.
	local param2 = vm.get_param2_data and vm:get_param2_data() or nil
	local toward = {[0] = {0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}
	local queue, head = {}, 1
	for _, n in ipairs(gone) do queue[#queue + 1] = n end
	while head <= #queue do
		local n = queue[head]
		head = head + 1
		for _, d in pairs(toward) do
			local x, y, z = n[1] + d[1], n[2] + d[2], n[3] + d[3]
			if x >= emin.x and x <= emax.x and y >= emin.y and y <= emax.y and z >= emin.z and z <= emax.z then
				local index = va:index(x, y, z)
				if is_vine(data[index]) then
					local attached = true
					if param2 then
						local t = toward[param2[index] % 8]
						attached = t ~= nil and x + t[1] == n[1] and y + t[2] == n[2] and z + t[3] == n[3]
						-- VoxeLibre also lets a vine hang under a vine of the same param2 when there
						-- is nothing beside it (mcl_core.check_vines_supported).
						if not attached and t and t[2] == 0 and d[2] == -1 and n[4] ~= nil
								and param2[index] == n[4] then
							local sx, sy, sz = x + t[1], y + t[2], z + t[3]
							attached = sx < emin.x or sx > emax.x or sz < emin.z or sz > emax.z
								or data[va:index(sx, sy, sz)] == air
						end
					end
					if attached then
						data[index] = air
						stats.vines = stats.vines + 1
						queue[#queue + 1] = {x, y, z, param2 and param2[index] or nil}
					end
				end
			end
		end
	end

	if stats.removed > 0 or stats.growth > 0 or stats.vines > 0 or stats.plant_tops > 0 then
		vm:set_data(data)
		vm:write_to_map(true)
	end
	if stats.clipped > 0 then
		engine.log("action", "[living_villages] " .. stats.clipped .. " tree fill(s) hit the cap near the village and were clipped to it")
	end
	return stats
end

return M
