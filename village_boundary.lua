-- Town-boundary planning and exterior grading (#296, #297). The city union is
-- a hard solver constraint and a separate no-write mask.
local core = minetest
local smoothing = dofile(core.get_modpath("living_villages") .. "/village_smoothing.lua")
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")
local fragments = dofile(core.get_modpath("living_villages") .. "/village_fragments.lua")
local holes = dofile(core.get_modpath("living_villages") .. "/village_holes.lua")

local M = {}

local function integer(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
		and value % 1 == 0
end

local function validate(rectangles, ground_y)
	if not integer(ground_y) then return nil, "ground_y must be an integer" end
	if type(rectangles) ~= "table" then return nil, "boundary must be a list of rectangles" end
	local count, max_key = 0, 0
	for key, rect in pairs(rectangles) do
		if not integer(key) or key < 1 or type(rect) ~= "table" then
			return nil, "boundary must be a dense list of rectangles"
		end
		count, max_key = count + 1, math.max(max_key, key)
		for _, field in ipairs({"x0", "z0", "x1", "z1"}) do
			if not integer(rect[field]) then return nil, "invalid boundary rectangle " .. key .. ": " .. field end
		end
		if rect.x0 > rect.x1 or rect.z0 > rect.z1 then
			return nil, "invalid boundary rectangle " .. key .. ": bounds are reversed"
		end
	end
	if count == 0 then return nil, "empty boundary" end
	if count ~= max_key then return nil, "boundary must be a dense list of rectangles" end
	return true
end

-- `height_at(x,z)` is supplied by the caller so planning remains independent
-- of map reads. Overlapping rectangles are retained as overlapping pads; the
-- shared target solver resolves their ownership deterministically.
function M.plan(rectangles, ground_y, options)
	options = options or {}
	if type(options) ~= "table" then return nil, "options must be a table" end
	local valid, reason = validate(rectangles, ground_y)
	if not valid then return nil, reason end
	if type(options.height_at) ~= "function" then return nil, "height_at must be a function" end
	local radius = options.radius == nil and smoothing.boundary_config.radius or options.radius
	local cap = options.cap == nil and smoothing.boundary_config.cap or options.cap
	if not integer(radius) or radius < 0 then return nil, "radius must be a nonnegative integer" end
	if not integer(cap) or cap < 0 then return nil, "cap must be a nonnegative integer" end
	local config = {}
	for key, value in pairs(smoothing.config) do config[key] = value end
	config.margin, config.radius, config.cap = 0, radius, cap
	local pads = {}
	for _, rect in ipairs(rectangles) do
		pads[#pads + 1] = {x0 = rect.x0, z0 = rect.z0, x1 = rect.x1, z1 = rect.z1,
			yx0 = rect.x0, yz0 = rect.z0, yx1 = rect.x1, yz1 = rect.z1, y = ground_y,
			surface = rect.surface}
	end
	local function interior(x, z)
		for _, rect in ipairs(rectangles) do
			if x >= rect.x0 and x <= rect.x1 and z >= rect.z0 and z <= rect.z1 then return true end
		end
		return false
	end
	local function height_at(x, z)
		if interior(x, z) then return ground_y, false end
		return options.height_at(x, z)
	end
	-- The city is a hard target constraint, not protected terrain: protected
	-- columns bypass the footprint rule in targets. Keep the solver's other
	-- behavior intact and enforce the separate no-write rule in the mask below.
	local targets = smoothing.targets(pads, height_at, config)
	local result = {
		targets = targets,
		at = targets.at, was = targets.was, kind = targets.kind,
		violations = targets.violations, walls = targets.walls, wall_max = targets.wall_max,
		pads = pads,
	}
	-- Footprints are hard constraints for the slope solve. Keep their unchanged
	-- support out of the future writer's mask; only changed yard/skirt columns
	-- are eligible for boundary grading writes.
	function result.write_mask(x, z)
		if interior(x, z) then return false end
		local kind = targets.kind(x, z)
		local target, was = targets.at(x, z), targets.was(x, z)
		return kind ~= nil and kind ~= "footprint" and target ~= nil and was ~= nil and target ~= was
	end
	return result
end

function M.volume(rectangles, ground_y, options)
	return smoothing.boundary_volume(rectangles, ground_y, options)
end

local function within(rectangles, x, z)
	for _, rect in ipairs(rectangles) do
		if x >= rect.x0 and x <= rect.x1 and z >= rect.z0 and z <= rect.z1 then return true end
	end
	return false
end

local function envelope_add(envelope, box)
	if not box then return envelope end
	if not envelope then
		return {minp = {x = box.minp.x, y = box.minp.y, z = box.minp.z},
			maxp = {x = box.maxp.x, y = box.maxp.y, z = box.maxp.z}}
	end
	for _, axis in ipairs({"x", "y", "z"}) do
		envelope.minp[axis] = math.min(envelope.minp[axis], box.minp[axis])
		envelope.maxp[axis] = math.max(envelope.maxp[axis], box.maxp[axis])
	end
	return envelope
end

-- Apply the pure #296 plan after callers have emerged `boundary_volume`.
function M.smooth(rectangles, ground_y, options, env)
	options = options or {}
	if type(options) ~= "table" then return false, "options must be a table" end
	env = env or options.env or {}
	if type(env) ~= "table" then return false, "env must be a table" end
	local engine = env.engine or core
	local volume, reason = M.volume(rectangles, ground_y, options)
	if not volume then return false, reason end
	local radius = options.radius == nil and smoothing.boundary_config.radius or options.radius
	local cap = options.cap == nil and smoothing.boundary_config.cap or options.cap
	local empty = {changed = 0, cut = 0, filled = 0, max_movement = 0, steps_over_one = 0,
		tree_removed = 0, written = nil}
	if radius == 0 then return true, empty end
	if type(env.load_node) ~= "function" then return false, "node loading service is unavailable" end

	local inspection = 48
	local area = {minp = {x = math.huge, y = ground_y - inspection, z = math.huge},
		maxp = {x = -math.huge, y = ground_y + inspection, z = -math.huge}}
	local zones = {}
	for _, rect in ipairs(rectangles) do
		area.minp.x, area.minp.z = math.min(area.minp.x, rect.x0 - radius), math.min(area.minp.z, rect.z0 - radius)
		area.maxp.x, area.maxp.z = math.max(area.maxp.x, rect.x1 + radius), math.max(area.maxp.z, rect.z1 + radius)
		zones[#zones + 1] = {minp = {x = rect.x0 - radius, y = ground_y - inspection, z = rect.z0 - radius},
			maxp = {x = rect.x1 + radius, y = ground_y + inspection, z = rect.z1 + radius}}
	end
	local missing = smoothing.load_area(volume, {block = 16}, env)
	if missing > 0 then return false, ("unloaded terrain: %d boundary blocks unavailable"):format(missing) end

	local written
	local function mark(x, y, z)
		written = envelope_add(written, {minp = {x = x, y = y, z = z}, maxp = {x = x, y = y, z = z}})
	end
	local function operation(fn, ...)
		local ok, value, extra = pcall(fn, ...)
		if not ok then return nil, "boundary smoothing failed after it may have written terrain: " .. tostring(value) end
		return value, extra
	end
	local clear = env.clear_trees or function(zone, protected)
		return fragments.clear_trees(zone, nil, engine, protected)
	end
	local tree_stats, clear_reason = operation(clear, zones, rectangles)
	if not tree_stats then return false, clear_reason end
	written = envelope_add(written, tree_stats.written)

	local material = env.surface_mat or (env.settlements and env.settlements.surface_mat)
	if type(material) ~= "table" then material = {} end
	local heights = env.heights or terrain.heights
	local lookup_fn, lookup_reason = operation(heights, area, material, engine, true)
	if not lookup_fn then return false, "boundary height scan failed after tree cleanup: " .. tostring(lookup_reason) end
	local scan = env.scan or function(scan_area)
		return fragments.scan_structures(scan_area, fragments.structure_test(engine), engine, true)
	end
	local structures, scan_reason = operation(scan, area)
	if not structures then return false, "boundary structure scan failed after tree cleanup: " .. tostring(scan_reason) end

	local columns, shoreline = {}, {}
	for z = area.minp.z, area.maxp.z do
		columns[z] = {}
		for x = area.minp.x, area.maxp.x do
			local column = lookup_fn(x, z, true)
			columns[z][x] = column
			local name = column and (column.ground_name or column.base_name)
			if column and (column.ground_liquid or column.base_liquid or (name and holes.is_ice(name))) then
				shoreline[z] = shoreline[z] or {}
				shoreline[z][x] = true
			end
		end
	end
	local structure_margin = 1
	local excluded_columns = {}
	local function excluded(x, z)
		local row = excluded_columns[z]
		if row and row[x] ~= nil then return row[x] end
		row = row or {}
		excluded_columns[z] = row
		local blocked = within(rectangles, x, z)
		for dz = -1, 1 do for dx = -1, 1 do
			if shoreline[z + dz] and shoreline[z + dz][x + dx] then blocked = true end
		end end
		if not blocked then
			blocked = structures.find(x - structure_margin, z - structure_margin,
				x + structure_margin, z + structure_margin) ~= nil
		end
		row[x] = blocked
		return blocked
	end
	local plan, plan_reason = M.plan(rectangles, ground_y, {radius = radius, cap = cap, height_at = function(x, z)
		local column = columns[z] and columns[z][x]
		if not column or column.ground_unknown or column.unloaded or column.y == area.maxp.y or excluded(x, z) then
			return nil
		end
		local y, name, liquid = column.base_y, column.base_name, column.base_liquid
		if not y then y, name, liquid = column.ground_y, column.ground_name, column.ground_liquid end
		if not y or liquid or holes.is_ice(name) then return nil end
		return y, column.overhang
	end})
	if not plan then return false, "boundary planning failed after tree cleanup: " .. tostring(plan_reason) end

	local targets = plan.targets
	local allowed = setmetatable({pad = function(x, z)
		if not plan.write_mask(x, z) or excluded(x, z) then return nil end
		local owner = plan.targets.pad(x, z)
		return owner
	end}, {__index = targets})
	local writer = setmetatable({swap_node = function(pos, node)
		if excluded(pos.x, pos.z) then return end
		local old = engine.get_node(pos)
		local param2 = node.param2 or 0
		local changed = old.name ~= node.name or (old.param2 or 0) ~= param2
		local result = engine.swap_node(pos, node)
		if changed and result ~= false then mark(pos.x, pos.y, pos.z) end
		return result
	end}, {__index = engine})
	local stats, apply_reason = operation(smoothing.apply, plan.pads, allowed, lookup_fn, {
		cut_clear = 3,
	}, writer)
	if not stats then return false, "boundary column write failed after partial work: " .. tostring(apply_reason) end
	local max_movement = 0
	for z = targets.z0, targets.z1 do for x = targets.x0, targets.x1 do
		local target, was = targets.at(x, z), targets.was(x, z)
		if plan.write_mask(x, z) and target and was and target ~= was and not excluded(x, z) then
			max_movement = math.max(max_movement, math.abs(target - was))
		end
	end end
	stats.max_movement = max_movement
	stats.steps_over_one = targets.violations
	stats.tree_removed = tree_stats.removed or 0
	stats.written = written
	return true, stats
end

return M
