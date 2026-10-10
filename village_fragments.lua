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
	orphan_margin = 12, -- leaves with no trunk, floating trunks and loose cocoa pods go this far beyond the zone (#232)
	leaf_reach = 6, -- a leaf decays when no trunk is within this distance (mcl_core.update_leaves)
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
-- snow layers removed. A layer above the VoxelManip region (the top of the zone plus
-- the cap height) is not seen. The stats also carry `floating`, `orphans` and `cocoa`
-- (see the follow-up pass below).
-- Known limit: like trees, stalks and their vines are removed near ruined portals and
-- outposts too, where the smoothing leaves the ground alone; clear_trees does not know
-- the structures.
-- A capped fill only clips to the zone, which leaves part of a tall tree standing: a canopy
-- above the zone, a trunk cut off in the air. VoxeLibre decays orphaned leaves only when a
-- trunk next to them is dug, never after a write like this one, so a follow-up pass over the
-- zone and `orphan_margin` blocks round it removes what no longer holds together (#232):
-- trunk pieces with air under all of their bottom nodes (`floating`), leaves with no trunk
-- within `leaf_reach` (`orphans`, VoxeLibre's own decay rule), and cocoa pods whose trunk
-- is gone (`cocoa`). Leaves near a node that was not loaded are kept, and so are trunk
-- pieces and leaves that touch a structure node (a log beam in a ruined structure or an
-- outpost is natural by name but belongs to the structure); structure_test decides.
-- Known limit: leaves a player placed are kept by VoxeLibre through node metadata
-- (`player_leaves`), which a VoxelManip cannot read, so a hedge within the skirt of a village
-- built where a player has been is removed. Villages are built on freshly generated land.
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
	local stats = {seeds = 0, removed = 0, clipped = 0, snow = 0, growth = 0, vines = 0, plant_tops = 0,
		floating = 0, orphans = 0, cocoa = 0}
	if not lo then return stats end
	local margin = config.orphan_margin or M.config.orphan_margin
	local reach = config.leaf_reach or M.config.leaf_reach
	local pad = math.max(radius, margin + reach)
	local region_min = {x = lo.x - pad, y = lo.y - height, z = lo.z - pad}
	local region_max = {x = hi.x + pad, y = hi.y + height, z = hi.z + pad}

	local vm = engine.get_voxel_manip()
	local emin, emax = vm:read_from_map(region_min, region_max)
	local data = vm:get_data()
	local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local air = engine.CONTENT_AIR
	local param2 = vm.get_param2_data and vm:get_param2_data() or nil

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
	-- 1 trunk, 2 leaves, 3 cocoa pod (attached to the side of a trunk), false anything else.
	local class_of = {}
	local function class(id)
		local known = class_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			local def = name and engine.registered_nodes[name]
			known = false
			if not name then
			elseif is_trunk(name, def) then known = 1
			elseif is_leaves(name, def) then known = 2
			elseif def and def.groups and (def.groups.cocoa or 0) > 0 then known = 3
			elseif name == "mcl_core:vine" then known = 4 end
			class_of[id] = known
		end
		return known
	end
	local structure_name = M.structure_test(engine)
	local structure_of = {}
	local function is_structure(id)
		local known = structure_of[id]
		if known == nil then
			local name = engine.get_name_from_content_id(id)
			known = name ~= nil and structure_name(name)
			structure_of[id] = known
		end
		return known
	end
	-- Whether a structure or an unloaded node touches (x, y, z): returns "structure" or "ignore".
	local function touches(x, y, z)
		local found
		for dz = -1, 1 do for dy = -1, 1 do for dx = -1, 1 do
			local nx, ny, nz = x + dx, y + dy, z + dz
			if nx >= emin.x and nx <= emax.x and ny >= emin.y and ny <= emax.y and nz >= emin.z and nz <= emax.z then
				local id = data[va:index(nx, ny, nz)]
				if id == engine.CONTENT_IGNORE then return "ignore" end
				if is_structure(id) then found = "structure" end
			end
		end end end
		return found
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
	local function remove(x, y, z)
		data[va:index(x, y, z)] = air
		stats.removed = stats.removed + 1
		gone[#gone + 1] = {x, y, z}
		if y + 1 <= emax.y then
			local above = va:index(x, y + 1, z)
			if is_snow_layer(data[above]) then
				data[above] = air
				stats.snow = stats.snow + 1
			elseif is_plant_top(data[above]) then
				data[above] = air
				stats.plant_tops = stats.plant_tops + 1
			end
		end
	end
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
							if not capped or in_zone(n[1], n[2], n[3]) then remove(n[1], n[2], n[3]) end
						end
					elseif is_stalk(data[index]) then
						data[index] = air
						stats.growth = stats.growth + 1
					end
				end
			end
		end
	end

	-- What a clipped fill left (see the header). The area is the zone grown by `margin`
	-- sideways, up to the top of the region.
	local box_lo = {x = math.max(lo.x - margin, emin.x), y = math.max(lo.y, emin.y), z = math.max(lo.z - margin, emin.z)}
	local box_hi = {x = math.min(hi.x + margin, emax.x), y = emax.y, z = math.min(hi.z + margin, emax.z)}
	local function near_zone(x, y, z)
		for _, box in ipairs(zone) do
			if x >= box.minp.x - margin and x <= box.maxp.x + margin and z >= box.minp.z - margin
					and z <= box.maxp.z + margin and y >= box.minp.y then
				return true
			end
		end
		return false
	end
	local trunks, leaves, pods, vines, trunk_runs = {}, {}, {}, {}, {}
	local stride = emax.x - emin.x + 1
	for z = emin.z, emax.z do
		for x = emin.x, emax.x do
			local runs
			for y = emin.y, emax.y do
				local c = class(data[va:index(x, y, z)])
				if c == 1 then
					runs = runs or {}
					if runs[#runs] == y - 1 then runs[#runs] = y else runs[#runs + 1] = y; runs[#runs + 1] = y end
					if x >= box_lo.x and x <= box_hi.x and z >= box_lo.z and z <= box_hi.z and y >= box_lo.y then
						trunks[#trunks + 1] = {x, y, z}
					end
				elseif c and x >= box_lo.x and x <= box_hi.x and z >= box_lo.z and z <= box_hi.z and y >= box_lo.y then
					if c == 2 then leaves[#leaves + 1] = {x, y, z}
					elseif c == 3 then pods[#pods + 1] = {x, y, z}
					else vines[#vines + 1] = {x, y, z} end
				end
			end
			if runs then trunk_runs[(z - emin.z) * stride + (x - emin.x)] = runs end
		end
	end

	-- Trunk pieces hanging in the air: a connected piece (26 neighbours) whose bottom nodes
	-- all have air under them. A piece that touches the edge of the region counts as held.
	local seen, dirty = {}, {}
	for _, t in ipairs(trunks) do
		local key = va:index(t[1], t[2], t[3])
		if not seen[key] and near_zone(t[1], t[2], t[3]) then
			seen[key] = true
			local piece, held, head = {t}, touches(t[1], t[2], t[3]) ~= nil, 1
			while head <= #piece do
				local x, y, z = piece[head][1], piece[head][2], piece[head][3]
				head = head + 1
				if x == emin.x or x == emax.x or y == emin.y or y == emax.y or z == emin.z or z == emax.z then
					held = true
				else
					local below = data[va:index(x, y - 1, z)]
					if (below ~= air and class(below) ~= 1) or touches(x, y, z) then held = true end
					for dz = -1, 1 do for dy = -1, 1 do for dx = -1, 1 do
						local nx, ny, nz = x + dx, y + dy, z + dz
						if (dx ~= 0 or dy ~= 0 or dz ~= 0) and nx >= emin.x and nx <= emax.x
								and ny >= emin.y and ny <= emax.y and nz >= emin.z and nz <= emax.z then
							local ni = va:index(nx, ny, nz)
							if not seen[ni] and class(data[ni]) == 1 then
								seen[ni] = true
								piece[#piece + 1] = {nx, ny, nz}
							end
						end
					end end end
				end
			end
			if not held then
				for _, n in ipairs(piece) do
					remove(n[1], n[2], n[3])
					dirty[(n[3] - emin.z) * stride + (n[1] - emin.x)] = true
				end
				stats.floating = stats.floating + #piece
			end
		end
	end
	for ck, _ in pairs(dirty) do
		local x, z = emin.x + ck % stride, emin.z + math.floor(ck / stride)
		local runs
		for y = emin.y, emax.y do
			if class(data[va:index(x, y, z)]) == 1 then
				runs = runs or {}
				if runs[#runs] == y - 1 then runs[#runs] = y else runs[#runs + 1] = y; runs[#runs + 1] = y end
			end
		end
		trunk_runs[ck] = runs
	end

	local function unloaded(x, y, z)
		return x < emin.x or x > emax.x or y < emin.y or y > emax.y or z < emin.z or z > emax.z
			or data[va:index(x, y, z)] == engine.CONTENT_IGNORE
	end
	local function has_trunk_near(x, y, z)
		for dz = -reach, reach do
			for dx = -reach, reach do
				local nx, nz = x + dx, z + dz
				if nx >= emin.x and nx <= emax.x and nz >= emin.z and nz <= emax.z then
					local runs = trunk_runs[(nz - emin.z) * stride + (nx - emin.x)]
					if runs then
						for i = 1, #runs, 2 do
							if runs[i] <= y + reach and runs[i + 1] >= y - reach then return true end
						end
					end
				end
			end
		end
		return false
	end
	for _, l in ipairs(leaves) do
		local x, y, z = l[1], l[2], l[3]
		if near_zone(x, y, z) and not has_trunk_near(x, y, z) and not touches(x, y, z)
				and not (unloaded(x - reach, y - reach, z - reach) or unloaded(x + reach, y - reach, z - reach)
					or unloaded(x - reach, y + reach, z - reach) or unloaded(x + reach, y + reach, z - reach)
					or unloaded(x - reach, y - reach, z + reach) or unloaded(x + reach, y - reach, z + reach)
					or unloaded(x - reach, y + reach, z + reach) or unloaded(x + reach, y + reach, z + reach)) then
			remove(x, y, z)
			stats.orphans = stats.orphans + 1
		end
	end
	-- Cocoa pods hang on the side of a jungle trunk; param2 is the facedir toward it.
	local facedir = {[0] = {0, 0, 1}, {1, 0, 0}, {0, 0, -1}, {-1, 0, 0}}
	for _, p in ipairs(param2 and pods or {}) do
		local x, y, z = p[1], p[2], p[3]
		local d = facedir[param2[va:index(x, y, z)] % 4]
		local tx, ty, tz = x + d[1], y + d[2], z + d[3]
		if near_zone(x, y, z) and tx >= emin.x and tx <= emax.x and ty >= emin.y and ty <= emax.y
				and tz >= emin.z and tz <= emax.z and class(data[va:index(tx, ty, tz)]) ~= 1
				and data[va:index(tx, ty, tz)] ~= engine.CONTENT_IGNORE then
			data[va:index(x, y, z)] = air
			stats.cocoa = stats.cocoa + 1
		end
	end

	-- Vines that mcl_core.check_vines_supported would drop (a full walkable cube beside or
	-- over them, or a vine above with the same param2 when they hang): mapgen leaves some,
	-- and the removals above leave more. VoxeLibre's decay ABM removes them only near a
	-- player. Top first, so a vine hanging under a removed one goes too.
	if param2 then
		local support_of = {}
		local function supports(id)
			local known = support_of[id]
			if known == nil then
				local name = engine.get_name_from_content_id(id)
				local def = name and engine.registered_nodes[name]
				known = (def and def.walkable ~= false and name ~= "air" and name ~= "mcl_core:vine"
					and (def.node_box == nil or def.node_box.type == "regular")
					and (def.collision_box == nil or def.collision_box.type == "regular")) or false
				support_of[id] = known
			end
			return known
		end
		local wall = {[0] = {0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}
		for i = #vines, 1, -1 do
			local x, y, z = vines[i][1], vines[i][2], vines[i][3]
			local index = va:index(x, y, z)
			local live = near_zone(x, y, z) and data[index] ~= air
			-- param2 6 and 7 are no wallmounted direction: wallmounted_to_dir gives nil,
			-- check_vines_supported returns nil and the decay ABM drops the vine.
			local d = live and wall[param2[index] % 8]
			if live and not d then
				data[index] = air
				stats.vines = stats.vines + 1
			elseif d then
				local nx, ny, nz = x + d[1], y + d[2], z + d[3]
				local held = nx < emin.x or nx > emax.x or ny < emin.y or ny > emax.y or nz < emin.z or nz > emax.z
					or data[va:index(nx, ny, nz)] == engine.CONTENT_IGNORE or supports(data[va:index(nx, ny, nz)])
				if not held and d[2] == 0 and y + 1 <= emax.y then
					local up = va:index(x, y + 1, z)
					held = class(data[up]) == 4 and param2[up] == param2[index]
				end
				if not held then
					data[index] = air
					stats.vines = stats.vines + 1
				end
			end
		end
	end

	-- A vine whose support was removed (the node its param2 points at: a trunk, a leaf, or
	-- the vine above it) would be left in the air: a vine drops only when something changes
	-- beside it, and a write like this one sends no update. A vine on a standing node (a
	-- cliff, a leaf outside the fill) stays. Without param2 data any neighbouring vine goes.
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

	if stats.removed > 0 or stats.growth > 0 or stats.vines > 0 or stats.plant_tops > 0 or stats.cocoa > 0 then
		vm:set_data(data)
		vm:write_to_map(true)
	end
	if stats.clipped > 0 then
		engine.log("action", "[living_villages] " .. stats.clipped .. " tree fill(s) hit the cap near the village and were clipped to it")
	end
	return stats
end

return M
