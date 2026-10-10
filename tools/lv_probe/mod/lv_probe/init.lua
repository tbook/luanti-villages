-- Village probe (#144). Generates the villages VoxeLibre would try on this
-- world and logs one line of terrain metrics per attempt, so a change to the
-- village generator can be compared with vanilla on the same seed.
--
-- It does not change what generates. It wraps the four steps of mcl_villages'
-- build_a_settlement (create_site_plan, terraform, paths, place_schematics) to
-- time them and to measure the terrain before the first edit and after the
-- last, and wraps mcl_structures.place_structure to learn which ruined portals
-- and outposts stand near a village. Run it through tools/lv_probe/run.sh.
--
-- Settings (read from the server config):
--   lv_probe_sites   how many predicted sites to visit, nearest the origin first
--   lv_probe_radius  ignore sites farther than this from the origin
--   lv_probe_chunk   "x,z" of one chunk's minp: visit only that site, wherever it is
local core = minetest
local modpath = core.get_modpath("lv_probe")
local metrics = dofile(modpath .. "/metrics.lua")
local index = dofile(modpath .. "/village_index.lua")
local census = dofile(modpath .. "/census.lua")
local plants = dofile(modpath .. "/plants.lua")
local remains = dofile(modpath .. "/remains.lua")

local MARGIN = 8 -- columns mapped beyond the outermost building
local BELOW, ABOVE = 64, 96 -- vertical reach around the buildings' floors
local LEAF_REACH = 6 -- mcl_core leaf decay checks trunks this far away
local SITE_TIMEOUT = 90 -- seconds to wait for a site to build or be rejected
local RESULT_FILE = core.get_worldpath() .. "/lv_probe.jsonl"

local sites_wanted = tonumber(core.settings:get("lv_probe_sites")) or 8
local radius = tonumber(core.settings:get("lv_probe_radius")) or 1200
local only_chunk = core.settings:get("lv_probe_chunk") -- "x,z" of one chunk's minp
if only_chunk == "" then only_chunk = nil end
local seed = core.get_mapgen_setting("seed")

local current -- the site being visited, with the village built so far
local placed_structures = {}
local rejected_reason

local function log(message) core.log("action", "[lv_probe] " .. message) end
-- Which checkout of the mod this run measures (run.sh --mod-dir); nil without --with-mod.
log("living_villages loaded from " .. tostring(core.get_modpath("living_villages")))

-- Which nodes the ground scan skips or counts. Ids are cached on first sight.
local kinds = {}
local function kind_of(id)
	local kind = kinds[id]
	if kind then return kind end
	local name = core.get_name_from_content_id(id)
	local def = core.registered_nodes[name]
	if name == "air" or name == "ignore" then kind = name
	elseif core.get_item_group(name, "leaves") ~= 0 then kind = "leaves"
	elseif core.get_item_group(name, "tree") ~= 0 then kind = "trunk"
	elseif core.get_item_group(name, "water") ~= 0 then kind = "water"
	elseif def and def.walkable then kind = "ground"
	else kind = "passable" end
	kinds[id] = kind
	return kind
end

local function area_of(info)
	local x1, z1, x2, z2, y1, y2 = math.huge, math.huge, -math.huge, -math.huge, math.huge, -math.huge
	local footprints = {}
	for i, building in ipairs(info) do
		local f = metrics.footprint(building, settlements.schematic_table)
		footprints[i] = f
		if f then
			x1, z1 = math.min(x1, f.x1), math.min(z1, f.z1)
			x2, z2 = math.max(x2, f.x2), math.max(z2, f.z2)
		end
		y1, y2 = math.min(y1, building.pos.y), math.max(y2, building.pos.y)
	end
	return {x1 = x1 - MARGIN, z1 = z1 - MARGIN, x2 = x2 + MARGIN, z2 = z2 + MARGIN,
		y1 = y1 - BELOW, y2 = y2 + ABOVE}, footprints
end

-- Node classes for the plant census (plants.lua, #214).
local plant_kinds = {}
local function plant_kind(id)
	local kind = plant_kinds[id]
	if kind then return kind end
	local name = core.get_name_from_content_id(id)
	local def = core.registered_nodes[name]
	local groups = def and def.groups or {}
	if name == "air" then kind = "air"
	elseif name == "ignore" then kind = "ignore"
	elseif def and (def.liquidtype or "none") ~= "none" then kind = "liquid"
	elseif name:find("leaves", 1, true) then kind = "leaves"
	elseif name == "mcl_core:vine" then kind = "vine"
	elseif name == "mcl_core:cactus" or name == "mcl_core:reeds"
		or (name:find("^mcl_bamboo:bamboo") and groups.plant) then kind = "growth"
	elseif def and not def.walkable and (groups.plant or groups.flower or groups.flora or groups.sapling
		or name:find("tallgrass", 1, true) or name:find("fern", 1, true)) then kind = "plant"
	elseif name:find("^mcl_core:dirt") or name == "mcl_core:podzol" or name == "mcl_core:coarse_dirt"
		or name == "mcl_core:mycelium" then kind = "soil"
	elseif def and def.walkable then kind = "solid"
	else kind = "other" end
	plant_kinds[id] = kind
	return kind
end

-- Node classes for the tree remains census (remains.lua, #232).
local remains_kinds = {}
local function remains_kind(id)
	local kind = remains_kinds[id]
	if kind then return kind end
	local name = core.get_name_from_content_id(id)
	local def = core.registered_nodes[name]
	if name == "ignore" then kind = "ignore"
	elseif name:find("^mcl_cocoas:cocoa_%d") then kind = "cocoa"
	elseif name == "mcl_core:vine" then kind = "vine"
	elseif core.get_item_group(name, "leaves") ~= 0 or name:find("leaves", 1, true) then kind = "leaves"
	elseif core.get_item_group(name, "tree") ~= 0 then kind = "trunk"
	elseif def and def.walkable and (def.node_box == nil or def.node_box.type == "regular")
		and (def.collision_box == nil or def.collision_box.type == "regular") then kind = "support"
	else kind = "other" end
	remains_kinds[id] = kind
	return kind
end

-- Cocoa pods without a trunk, vines without a support and leaves without a trunk (#232).
local function read_remains(area)
	local reach = remains.LEAF_REACH
	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({x = area.x1 - reach, y = area.y1 - reach, z = area.z1 - reach},
		{x = area.x2 + reach, y = area.y2 + reach, z = area.z2 + reach})
	local data = vm:get_data()
	local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	return remains.count(data, va, area, remains_kind, vm:get_param2_data(),
		function(x, y, z) return core.get_name_from_content_id(data[va:index(x, y, z)]) end)
end

-- Reads the map once and returns the ground map, the columns with water over
-- them, tree counts, and the data needed to find leaves without a trunk.
local CENSUS_DEPTH = 6
local function scan_terrain(area)
	local vm = core.get_voxel_manip()
	local emin, emax = vm:read_from_map({x = area.x1, y = area.y1, z = area.z1},
		{x = area.x2, y = area.y2, z = area.z2})
	local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local data = vm:get_data()
	local ground, wet = {}, {}
	local leaves, trunks, canopy_columns, unknown = {}, {}, 0, 0
	local columns, clipped = 0, 0
	-- What the ground is made of (#151): node names in the top CENSUS_DEPTH
	-- nodes of every ground column.
	local census, census_dirt = {}, {} -- dirt by depth below the ground top
	local dirt_tops = {}
	for x = area.x1, area.x2 do
		ground[x] = {}
		for z = area.z1, area.z2 do
			columns = columns + 1
			local top = kind_of(data[va:index(x, area.y2, z)])
			if top ~= "air" and top ~= "ignore" and top ~= "passable" then clipped = clipped + 1 end
			local covered, sees_water = false, false
			local found
			for y = area.y2, area.y1, -1 do
				local kind = kind_of(data[va:index(x, y, z)])
				if kind == "ground" then found = y break
				elseif kind == "leaves" then covered = true; leaves[#leaves + 1] = {x, y, z}
				elseif kind == "trunk" then trunks[#trunks + 1] = {x, y, z}
				elseif kind == "water" then sees_water = true end
			end
			if found then
				for y = found, math.max(found - CENSUS_DEPTH + 1, area.y1), -1 do
					local name = core.get_name_from_content_id(data[va:index(x, y, z)])
					census[name] = (census[name] or 0) + 1
					if name == "mcl_core:dirt" then
						local d = tostring(found - y)
						census_dirt[d] = (census_dirt[d] or 0) + 1
						if d == "0" and #dirt_tops < 400 then dirt_tops[#dirt_tops + 1] = x .. "," .. found .. "," .. z end
					end
				end
				ground[x][z] = found
				if sees_water then wet[x .. "," .. z] = true end
			else
				unknown = unknown + 1
			end
			if covered then canopy_columns = canopy_columns + 1 end
		end
	end
	local plant_counts = plants.count(data, va, {x1 = area.x1, x2 = area.x2, z1 = area.z1, z2 = area.z2, y1 = emin.y, y2 = emax.y}, plant_kind,
		function(x, y, z) return core.get_name_from_content_id(data[va:index(x, y, z)]) end, vm:get_param2_data())
	return {plants = plant_counts, dirt_tops = dirt_tops, census = census, census_dirt = census_dirt, ground = ground, wet = wet, leaves = leaves, trunks = trunks,
		columns = columns, unknown = unknown, canopy_columns = canopy_columns, clipped = clipped}
end

-- A column whose topmost scanned node is already solid may continue above the
-- scan, so raise the ceiling until none does. The area keeps the raised ceiling
-- for the later read.
local EXTEND_BY, MAX_EXTENSIONS = 64, 8
local function read_terrain(area)
	local terrain = scan_terrain(area)
	local extensions = 0
	while terrain.clipped > 0 and extensions < MAX_EXTENSIONS do
		area.y2 = area.y2 + EXTEND_BY
		extensions = extensions + 1
		terrain = scan_terrain(area)
	end
	if terrain.clipped > 0 then log("warning: terrain still clipped at y=" .. area.y2) end
	return terrain
end

-- Leaves with no trunk within reach: what is left when a building clears a
-- tree's trunk but not its crown.
local function orphan_leaves(terrain)
	local trunk_at = {}
	for _, t in ipairs(terrain.trunks) do trunk_at[t[1] .. "," .. t[2] .. "," .. t[3]] = true end
	local orphans = 0
	for _, l in ipairs(terrain.leaves) do
		local supported = false
		for dx = -LEAF_REACH, LEAF_REACH do
			for dy = -LEAF_REACH, LEAF_REACH do
				for dz = -LEAF_REACH, LEAF_REACH do
					if trunk_at[(l[1] + dx) .. "," .. (l[2] + dy) .. "," .. (l[3] + dz)] then
						supported = true
						break
					end
				end
				if supported then break end
			end
			if supported then break end
		end
		if not supported then orphans = orphans + 1 end
	end
	return orphans
end

local function floors_of(info, footprints)
	local floors = {}
	for i, f in ipairs(footprints) do
		for x = f.x1, f.x2 do
			for z = f.z1, f.z2 do floors[x .. "," .. z] = info[i].pos.y end
		end
	end
	return floors
end

-- The anchor is the middle of the first building (the belltower).
local function anchor_of(info, footprints)
	local f = footprints[1]
	return {x = math.floor((f.x1 + f.x2) / 2), z = math.floor((f.z1 + f.z2) / 2)}
end

local function terrain_report(terrain, info, footprints, area)
	local report = {
		heights = metrics.height_range(terrain.ground),
		steps = metrics.steps(terrain.ground, footprints),
		dirt_tops = terrain.dirt_tops, census = terrain.census, census_dirt = terrain.census_dirt,
		unknown_columns = terrain.unknown,
		plants = terrain.plants,
		remains = read_remains(area),
		clipped_columns = terrain.clipped,
		canopy_cover = terrain.columns > 0 and math.floor(100 * terrain.canopy_columns / terrain.columns) / 100 or 0,
		trunk_nodes = #terrain.trunks,
		leaf_nodes = #terrain.leaves,
	}
	report.pit_depth, report.pit_at = metrics.pit_depth(terrain.ground)
	return report
end

local function now_ms() return core.get_us_time() / 1000 end

-- Structures placed near the village area, each with its distance in x/z from
-- the nearest building footprint (0 when its center is inside one).
local function structures_near(area, footprints)
	local near = {}
	for _, s in ipairs(placed_structures) do
		if s.pos.x >= area.x1 - 15 and s.pos.x <= area.x2 + 15
			and s.pos.z >= area.z1 - 15 and s.pos.z <= area.z2 + 15 then
			local nearest = math.huge
			for _, f in ipairs(footprints) do
				local dx = math.max(f.x1 - s.pos.x, 0, s.pos.x - f.x2)
				local dz = math.max(f.z1 - s.pos.z, 0, s.pos.z - f.z2)
				nearest = math.min(nearest, math.sqrt(dx * dx + dz * dz))
			end
			near[#near + 1] = {name = s.name, pos = {x = s.pos.x, y = s.pos.y, z = s.pos.z},
				distance = math.floor(nearest)}
		end
	end
	table.sort(near, function(a, b)
		if a.name ~= b.name then return a.name < b.name end
		if a.pos.x ~= b.pos.x then return a.pos.x < b.pos.x end
		return a.pos.z < b.pos.z
	end)
	return near
end

local function finish_site(site, outcome)
	if site.done then return end
	site.done = true
	local result = {seed = seed, chunk = {x = site.minp.x, y = site.minp.y, z = site.minp.z},
		outcome = outcome, reason = rejected_reason, timing_ms = site.timing}
	if outcome == "built" and site.info then
		local info, footprints = site.info, site.footprints
		local after = read_terrain(site.area)
		local floors = floors_of(info, footprints)
		result.center = {x = info[1].pos.x, y = info[1].pos.y, z = info[1].pos.z}
		result.biome = core.get_biome_name(core.get_biome_data(info[1].pos).biome)
		result.surface = info[1].surface_mat
		result.surfaces = {}
		for _, b in ipairs(info) do
			local m = tostring(b.surface_mat)
			result.surfaces[m] = (result.surfaces[m] or 0) + 1
		end
		result.buildings = metrics.building_counts(info)
		result.total_buildings = #info
		result.church = (result.buildings.church or 0) > 0
		result.tavern = (result.buildings.tavern or 0) > 0
		result.floors = metrics.floor_heights(info)
		result.natural = site.natural
		result.natural.fill_cut = metrics.fill_and_cut(info, footprints, site.natural_ground)
		result.after = terrain_report(after, info, footprints, site.area)
		result.terraformed_plants = site.terraformed
		result.after.traps = metrics.traps(after.ground, after.wet, footprints, floors,
			anchor_of(info, footprints))
		result.after.orphan_leaves = orphan_leaves(after)
		result.structures = structures_near(site.area, footprints)
		result.footprints = footprints
		result.pending_timeout = site.timed_out or nil
	end
	local line = core.write_json(result)
	local file = io.open(RESULT_FILE, "a")
	if file then file:write(line, "\n") file:close() end
	if outcome == "built" then
		log(string.format("RESULT chunk %s: built %d buildings, church=%s tavern=%s, floors %s..%s (neighbor diff %s), max step %s, traps %s, %s",
			core.pos_to_string(site.minp), result.total_buildings, tostring(result.church),
			tostring(result.tavern), result.floors.min, result.floors.max, result.floors.neighbor_diff,
			result.after.steps.largest, result.after.traps.columns, result.biome))
	else
		log(string.format("RESULT chunk %s: %s%s", core.pos_to_string(site.minp), outcome,
			rejected_reason and (" (" .. rejected_reason .. ")") or ""))
	end
	local function finish()
		for _, block in ipairs(site.blocks or {}) do core.forceload_free_block(block, true) end
		site.on_done()
	end
	if outcome == "built" and site.info and census.enabled() then
		return census.run(site.area, function(record)
			record.seed, record.chunk = seed, result.chunk
			local f = io.open(RESULT_FILE, "a")
			if f then f:write(core.write_json(record), "\n") f:close() end
		end, finish)
	end
	finish()
end

-- Times a step and adds the milliseconds to the current site's record.
local function timed(name, original)
	return function(...)
		local site = current
		local start = now_ms()
		local result = original(...)
		if site then site.timing[name] = (site.timing[name] or 0) + (now_ms() - start) end
		return result
	end
end

local function wrap_pipeline()
	local plan = timed("plan", settlements.create_site_plan)
	settlements.create_site_plan = function(...)
		local info = plan(...)
		local site = current
		if not site then return info end
		if not info then
			rejected_reason = "no surface at the chunk center"
			core.after(0, finish_site, site, "plan_failed")
			return info
		end
		site.info = info
		site.area, site.footprints = area_of(info)
		local natural = read_terrain(site.area)
		site.natural_ground = natural.ground
		site.natural = terrain_report(natural, info, site.footprints, site.area)
		return info
	end
	local terraform = timed("terraform", settlements.terraform)
	-- The plant census again straight after the terraform, before the buildings are
	-- placed, to tell what the terrain steps leave from what the schematics do (#214).
	settlements.terraform = function(...)
		local result = terraform(...)
		local site = current
		if site and site.area then site.terraformed = read_terrain(site.area).plants end
		return result
	end
	settlements.paths = timed("paths", settlements.paths)

	-- Schematics go in through emerge callbacks after place_schematics returns,
	-- so the village is only done when the last callback has run.
	local place = timed("place_call", settlements.place_schematics)
	local original_place_schematic = mcl_structures.place_schematic
	settlements.place_schematics = function(...)
		local site = current
		if not site or not site.info then return place(...) end
		site.pending, site.placing_started = 0, now_ms()
		mcl_structures.place_schematic = function(pos, schematic, rotation, replacements, force, flags, callback, pr, param)
			site.pending = site.pending + 1
			local function wrapped(...)
				if callback then callback(...) end
				site.pending = site.pending - 1
				if site.placing_returned and site.pending == 0 then
					site.timing.place_total = now_ms() - site.placing_started
					core.after(0, finish_site, site, "built")
				end
			end
			return original_place_schematic(pos, schematic, rotation, replacements, force, flags, wrapped, pr, param)
		end
		local result = place(...)
		mcl_structures.place_schematic = original_place_schematic
		site.placing_returned = true
		if site.pending == 0 then
			site.timing.place_total = now_ms() - site.placing_started
			core.after(0, finish_site, site, "built")
		end
		return result
	end
end

local function wrap_structures()
	local original = mcl_structures.place_structure
	mcl_structures.place_structure = function(pos, def, pr, blockseed, rot)
		local result = original(pos, def, pr, blockseed, rot)
		if result and def and def.name then
			placed_structures[#placed_structures + 1] = {name = def.name, pos = vector.new(pos)}
		end
		return result
	end
end

local function wrap_log()
	local original = core.log
	core.log = function(level, message)
		if type(message) == "string" and current and message:find("heightmap not good", 1, true) then
			rejected_reason = "heightmap too uneven"
		end
		return original(level, message)
	end
end

wrap_pipeline()
wrap_structures()
wrap_log()

local function visit(site, on_done)
	current = {minp = site.minp, timing = {}, on_done = on_done}
	rejected_reason = nil
	local size = 16 * (tonumber(core.get_mapgen_setting("chunksize")) or 5)
	local maxp = {x = site.minp.x + size - 1, y = site.minp.y + size - 1, z = site.minp.z + size - 1}
	log(string.format("visiting chunk %s (%.0f nodes from origin)", core.pos_to_string(site.minp), site.distance))
	local site_state = current
	-- A player standing in the village would have the surroundings generated.
	-- Without them mcl_vars.get_node busy-waits 10 s for each ungenerated chunk
	-- the plan reaches, which the emerge thread cannot finish while the server
	-- thread holds the lock, and the plan comes out smaller than in play.
	-- The 27 chunks around the site are generated one at a time in a fixed
	-- order: trees that cross a chunk border depend on which neighbor came
	-- first, so a free-for-all emerge gives a slightly different village each run.
	local origins = {}
	for dz = -1, 1 do
		for dx = -1, 1 do
			for dy = -1, 1 do
				origins[#origins + 1] = {x = site.minp.x + dx * size, y = site.minp.y + dy * size,
					z = site.minp.z + dz * size}
			end
		end
	end
	-- Generation code that draws on math.random (mcl_init seeds it from the clock)
	-- would also differ from run to run.
	math.randomseed(1)
	local emerged = 0
	local function emerge_next()
		emerged = emerged + 1
		local origin = origins[emerged]
		if not origin then return site_state.on_emerged() end
		core.emerge_area(origin, vector.offset(origin, size - 1, size - 1, size - 1), function(_, _, remaining)
			if remaining == 0 then core.after(0, emerge_next) end
		end)
	end
	site_state.on_emerged = function()
		if site_state.started then return end
		site_state.started = true
		site_state.blocks = {}
		-- An active block runs the structblock LBM, which builds the village.
		for bx = math.floor(site.minp.x / 16), math.floor(maxp.x / 16) do
			for by = math.floor(site.minp.y / 16), math.floor(maxp.y / 16) do
				for bz = math.floor(site.minp.z / 16), math.floor(maxp.z / 16) do
					local block = {x = bx * 16, y = by * 16, z = bz * 16}
					core.forceload_block(block, true)
					site_state.blocks[#site_state.blocks + 1] = block
				end
			end
		end
		-- No plan within the timeout means the site was never tried, or was rejected.
		core.after(SITE_TIMEOUT, function()
			if site_state.done then return end
			if site_state.info then
				site_state.timed_out = true
				finish_site(site_state, "built")
			else
				finish_site(site_state, "not_built")
			end
		end)
	end
	emerge_next()
end

core.after(2, function()
	local created = io.open(RESULT_FILE, "a") -- a seed with no sites still leaves a file
	if created then created:close() end
	local sites = index.predicted_sites({x = 0, y = 0, z = 0}, index.low32(seed), {}, nil)
	local within, queue = {}, {}
	for _, site in ipairs(sites) do
		if only_chunk then
			if site.minp.x .. "," .. site.minp.z == only_chunk then queue[1] = site end
		elseif site.distance <= radius then
			within[#within + 1] = site
			if #queue < sites_wanted then queue[#queue + 1] = site end
		end
	end
	log(string.format("seed %s: %d predicted sites, %d within %d nodes of the origin, visiting %d",
		seed, #sites, #within, radius, #queue))
	local i = 0
	local function next_site()
		i = i + 1
		if not queue[i] then
			log("DONE")
			local file = io.open(core.get_worldpath() .. "/lv_probe.done", "w")
			if file then file:write("done\n") file:close() end
			core.request_shutdown("lv_probe finished", false, 0)
			return
		end
		visit(queue[i], function()
			current = nil
			core.after(1, next_site)
		end)
	end
	next_site()
end)
