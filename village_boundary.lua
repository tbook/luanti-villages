-- Pure town-boundary grading plans (#296). The writer arrives separately in
-- #297; this module only validates the rectangles and returns targets and a
-- filtered write mask for it.
local core = minetest
local smoothing = dofile(core.get_modpath("living_villages") .. "/village_smoothing.lua")

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
	local radius = options.radius == nil and 20 or options.radius
	local cap = options.cap == nil and smoothing.config.cap or options.cap
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
	local targets = smoothing.targets(pads, options.height_at, config, options.protected)
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
		local kind = targets.kind(x, z)
		local target, was = targets.at(x, z), targets.was(x, z)
		return kind ~= nil and kind ~= "footprint" and target ~= nil and was ~= nil and target ~= was
	end
	return result
end

function M.volume(rectangles, ground_y, options)
	return smoothing.boundary_volume(rectangles, ground_y, options)
end

return M
