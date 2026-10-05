-- Plans villages on level-enough sites (#139, part of #133). VoxeLibre's
-- settlements.create_site_plan (mcl_villages/buildings.lua) puts each building
-- wherever find_surface lands, so some end up in deep holes or on high towers.
-- This planner keeps its ring generator for where to try, but approves a site
-- only if its footprint is level, it has no water, and it is within a few
-- blocks of the height of the sites already approved beside it. It returns the
-- same settlement_info, so terraform, paths and place_schematics are unchanged.
--
-- It also reserves the church (#132) before the random pick, which replaces
-- church_site.lua's wrapper of create_site_plan, so install this after it.
--
-- The planning is plain functions of an `env` table (settlements, get_node,
-- registered_nodes, get_chunk_number, log) so tests can stub the engine.
local core = minetest
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")

local M = {}

M.config = {
	cell = 16, -- blocks per grid cell
	min_cells = 4, max_cells = 5, -- village radius in cells, drawn per village
	max_spread = 4, -- largest height difference among a site's samples
	max_step = 5, -- a site this far from an approved neighbor's floor is rejected
	neighbor_cells = 1.5, -- approved sites this close (in cells) are neighbors
	min_buildings = 8, -- including the belltower
	church_give_up = 60, -- candidates the church may miss before it is no longer reserved
	ring_points = 24,
	angle_jitter = 5, -- degrees
	radius_jitter = 2, -- blocks
	height_above = 50, -- samples start this far above the belltower's ground
	water_scan = 150, -- how far down a column is searched for its top node
}

local function shuffle(list, pr)
	local copy = {}
	for i, v in ipairs(list) do copy[i] = v end
	for i = #copy, 1, -1 do
		local j = pr:next(1, #copy)
		copy[i], copy[j] = copy[j], copy[i]
	end
	return copy
end

local function has_church(plan)
	for _, placed in ipairs(plan) do
		if placed.name == "church" then return true end
	end
	return false
end

local function sorted_counts(counts)
	local keys = {}
	for key in pairs(counts) do keys[#keys + 1] = key end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do parts[#parts + 1] = key .. "=" .. counts[key] end
	return #parts > 0 and table.concat(parts, ", ") or "none"
end

-- Plans one village. `env` has: settlements (find_surface, check_distance,
-- schematic_table), get_node, registered_nodes, get_chunk_number, log, and
-- `wait` (false to never wait for unloaded chunks, as the dry-run command does).
-- Returns the settlement_info, or false and a reason, and then a report
-- {rejects = {reason = count}, center = pos}.
function M.plan(maxp, minp, pr, env, config)
	config = config or M.config
	local settlements = env.settlements
	local schematics = settlements.schematic_table
	local wait = env.wait ~= false
	local report = {rejects = {}}
	local function reject(reason, detail)
		report.rejects[reason] = (report.rejects[reason] or 0) + 1
		env.log("verbose", "[living_villages] site rejected (" .. reason .. ")" .. (detail and (": " .. detail) or ""))
	end

	local center = {
		x = math.floor((minp.x + maxp.x) / 2),
		y = maxp.y,
		z = math.floor((minp.z + maxp.z) / 2),
	}
	local chunks = {}
	local function find_surface(pos)
		local number = env.get_chunk_number(pos)
		local first = not chunks[number]
		chunks[number] = true
		return settlements.find_surface(pos, first and wait or nil)
	end

	local center_surface, center_material = find_surface(center)
	report.center = center_surface or center
	if not center_surface then
		env.log("action", "[living_villages] no village at " .. core.pos_to_string(center) .. ": no surface at the center")
		return false, "no surface at the center", report
	end
	local start_y = center_surface.y + config.height_above

	-- One sample per column, found once: the surface y and material, or why
	-- the column is not buildable. Water is the top of the column, which
	-- find_surface walks past to the bed.
	local samples = {}
	local function top_is_liquid(x, z)
		for y = start_y, start_y - config.water_scan, -1 do
			local def = env.registered_nodes[env.get_node({x = x, y = y, z = z}).name]
			if def then
				if (def.liquidtype or "none") ~= "none" then return true end
				if def.walkable then return false end
			end
		end
		return false
	end
	-- find_surface refuses ground with leaves directly above it, so a column
	-- under a canopy has no surface; terraform clears trees, so take the
	-- ground below the leaves and trunks if it is a surface material.
	local function ground_under_trees(x, z)
		for y = start_y, start_y - config.water_scan, -1 do
			local name = env.get_node({x = x, y = y, z = z}).name
			local def = env.registered_nodes[name]
			if def and def.walkable and not name:find("leaves", 1, true) and not name:find("tree", 1, true) then
				if settlements.surface_mat[name] then return {x = x, y = y, z = z}, name end
				return nil
			end
		end
	end
	local function sample(x, z)
		local key = x .. "," .. z
		local s = samples[key]
		if s then return s end
		local surface, material = find_surface({x = x, y = start_y, z = z})
		if not surface then surface, material = ground_under_trees(x, z) end
		if top_is_liquid(x, z) then
			s = {reason = "water"}
		elseif not surface then
			s = {reason = "no_surface"}
		else
			s = {y = surface.y, material = material}
		end
		samples[key] = s
		return s
	end

	local plan, approved = {}, {}
	local neighbor_range = config.neighbor_cells * config.cell

	-- The floor and material for a building at (x, z), or nil and a reason.
	local function evaluate(schem, x, z, rotation)
		local box = terrain.footprint({pos = {x = x, z = z}, name = schem.name, rotat = rotation}, schematics)
		local xs = {box.minp.x, math.floor((box.minp.x + box.maxp.x) / 2), box.maxp.x}
		local zs = {box.minp.z, math.floor((box.minp.z + box.maxp.z) / 2), box.maxp.z}
		local low, high, sum, count, material
		for _, sz in ipairs(zs) do
			for _, sx in ipairs(xs) do
				local s = sample(sx, sz)
				if not s.y then return nil, s.reason, schem.name .. " at " .. sx .. "," .. sz end
				low = math.min(low or s.y, s.y)
				high = math.max(high or s.y, s.y)
				sum, count = (sum or 0) + s.y, (count or 0) + 1
				if sx == xs[2] and sz == zs[2] then material = s.material end
			end
		end
		if high - low > config.max_spread then
			return nil, "uneven", schem.name .. " at " .. x .. "," .. z .. " spans " .. low .. " to " .. high
		end
		local floor = math.ceil(sum / count)
		local cx, cz = (box.minp.x + box.maxp.x) / 2, (box.minp.z + box.maxp.z) / 2
		for _, other in ipairs(approved) do
			if math.sqrt((cx - other.x) ^ 2 + (cz - other.z) ^ 2) <= neighbor_range
					and math.abs(floor - other.floor) >= config.max_step then
				return nil, "neighbor_step", schem.name .. " at " .. x .. "," .. z .. " floor " .. floor
					.. " against " .. other.floor
			end
		end
		return floor, material, cx, cz
	end

	local function accept(schem, x, z, rotation)
		local floor, material, cx, cz = evaluate(schem, x, z, rotation)
		if not floor then return false, material, cx end
		plan[#plan + 1] = {
			pos = {x = x, y = floor, z = z},
			name = schem.name,
			hsize = schem.hsize,
			rotat = rotation,
			surface_mat = material,
		}
		approved[#approved + 1] = {x = cx, z = cz, floor = floor}
		return true
	end

	local rotations = {"0", "90", "180", "270"}
	local belltower = schematics[1]
	local number_of_buildings = pr:next(10, 25)
	local radius_max = pr:next(config.min_cells, config.max_cells) * config.cell
	local counts = {}
	for _, schem in ipairs(schematics) do counts[schem.name] = 0 end

	local ok, reason, detail = accept(belltower, center_surface.x, center_surface.z,
		rotations[pr:next(1, #rotations)])
	if not ok then
		reject(reason, detail)
		env.log("action", "[living_villages] no village at " .. core.pos_to_string(center_surface)
			.. ": the belltower site fails (" .. reason .. ")")
		return false, "belltower site: " .. reason, report
	end
	plan[1].surface_mat = plan[1].surface_mat or center_material
	counts[belltower.name] = 1

	local church
	for _, schem in ipairs(schematics) do
		if schem.name == "church" then church = schem end
	end
	local church_misses = 0

	local r = belltower.hsize
	while r <= radius_max and #plan < number_of_buildings do
		for step = 0, config.ring_points - 1 do
			local angle = (step * 360 / config.ring_points + pr:next(-config.angle_jitter, config.angle_jitter))
				* math.pi / 180
			local radius = r + pr:next(-config.radius_jitter, config.radius_jitter)
			local x = math.floor(center_surface.x + radius * math.cos(angle) + 0.5)
			local z = math.floor(center_surface.z + radius * math.sin(angle) + 0.5)

			local reserving = church and not has_church(plan) and church_misses < config.church_give_up
			local order = reserving and {church} or shuffle(schematics, pr)
			local placed = false
			for i = #order, 1, -1 do
				local schem = order[i]
				if reserving or counts[schem.name] < schem.max_num * number_of_buildings then
					if settlements.check_distance(plan, {x = x, z = z}, schem.hsize) then
						local accepted, why, detail2 = accept(schem, x, z, rotations[pr:next(1, #rotations)])
						if accepted then
							counts[schem.name] = counts[schem.name] + 1
							placed = true
							break
						end
						reject(why, detail2)
					elseif not reserving then
						reject("too_close")
					end
				end
			end
			if reserving and not placed then church_misses = church_misses + 1 end
			if #plan >= number_of_buildings then break end
		end
		r = r + pr:next(2, 5)
	end

	report.buildings = #plan
	if #plan < config.min_buildings then
		env.log("action", "[living_villages] no village at " .. core.pos_to_string(center_surface) .. ": only "
			.. #plan .. " of " .. config.min_buildings .. " buildings found sites (rejected: "
			.. sorted_counts(report.rejects) .. ")")
		return false, "only " .. #plan .. " buildings", report
	end
	env.log("action", "[living_villages] village planned at " .. core.pos_to_string(center_surface) .. ": "
		.. #plan .. " buildings" .. (has_church(plan) and ", church" or ", no church")
		.. " (rejected: " .. sorted_counts(report.rejects) .. ")")
	return plan, nil, report
end

local function live_env(globals, wait)
	return {
		settlements = globals.settlements,
		get_node = core.get_node,
		registered_nodes = core.registered_nodes,
		get_chunk_number = globals.mcl_vars.get_chunk_number,
		log = core.log,
		wait = wait,
	}
end

local SHAPE = {"name", "hwidth", "hdepth", "hsize", "max_num"}
local function schematics_ok(list)
	if type(list) ~= "table" or #list == 0 or list[1].name ~= "belltower" then return false end
	for _, schem in ipairs(list) do
		for _, key in ipairs(SHAPE) do
			if schem[key] == nil then return false end
		end
	end
	return true
end

-- Replaces settlements.create_site_plan (see village_terrain.install for the
-- guard). `globals` holds settlements, mcl_vars and max_height_difference.
function M.install(globals, engine)
	return terrain.install(globals, {{
		target = "create_site_plan",
		needs = {
			"settlements.find_surface", "settlements.check_distance", "settlements.terraform",
			{"settlements.schematic_table", type = "table"},
			{"max_height_difference", type = "number"},
			"mcl_vars.get_chunk_number",
		},
		make = function()
			if not schematics_ok(globals.settlements.schematic_table) then return nil end
			return function(maxp, minp, pr)
				local plan = M.plan(maxp, minp, pr, live_env(globals))
				return plan
			end
		end,
	}}, engine)
end

-- /living_villages_plan [seed]: plans a village around the player without
-- building it, and reports the plan and why candidates were rejected.
function M.register_command(globals)
	if not core.register_chatcommand then return end
	core.register_chatcommand("living_villages_plan", {
		params = "[seed]",
		description = "Plan a village around you without building it, and report the rejections",
		privs = {teleport = true},
		func = function(name, param)
			local player = core.get_player_by_name(name)
			if not player then return false, "Not in game." end
			if not (globals.settlements and globals.settlements.create_site_plan) then
				return false, "No village generator."
			end
			local pos = vector.round(player:get_pos())
			local half = globals.half_map_chunk_size or 40
			local pr = PseudoRandom(tonumber(param) or 1)
			local plan, why, report = M.plan(vector.offset(pos, half, 40, half), vector.offset(pos, -half, 40, -half),
				pr, live_env(globals, false))
			local lines = {}
			if plan then
				lines[#lines + 1] = "Planned " .. #plan .. " buildings:"
				for _, b in ipairs(plan) do
					lines[#lines + 1] = ("  %s at %s rotation %s on %s"):format(b.name, core.pos_to_string(b.pos),
						b.rotat, tostring(b.surface_mat))
				end
			else
				lines[#lines + 1] = "No village: " .. tostring(why)
			end
			lines[#lines + 1] = "Rejected candidates: " .. sorted_counts(report.rejects)
			return plan and true or false, table.concat(lines, "\n")
		end,
	})
end

return M
