-- Smooths the ground around village buildings (#140, part of #133). VoxeLibre's
-- settlements.terraform (mcl_villages/foundation.lua) fills straight down under
-- each footprint and clears straight up, which leaves dirt towers and deep
-- shafts. This replaces it, and runs the terraform steps in order: load the
-- area, clear whole trees (village_fragments.clear_trees, #141), then smooth.
--
-- Each building gets a pad, its footprint plus a flat yard at the site's height.
-- Every column within `radius` of a pad is pulled toward an inverse-distance
-- blend of the nearby pads' heights, fading to nothing at the radius, then
-- limited to one block of difference from its neighbors so villagers can walk
-- it. The planning half (targets) is a pure function, so it is tested without
-- the engine.
--
-- Loading this has no side effects. The engine functions come in through `env`.
local core = minetest
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")
local fragments = dofile(core.get_modpath("living_villages") .. "/village_fragments.lua")

local M = {}

M.config = {
	margin = 2, -- the flat yard around a footprint
	radius = 8, -- how far from a pad the ground is changed
	cap = 5, -- no column moves more than this
	relax_passes = 100, -- limit on slope-limiting sweeps
	below = 20, above = 24, -- the area reaches this far under the lowest pad and over the highest
	cut_clear = 3, -- a cut removes this much above the old surface, for whatever stands on it
	structure_margin = 1, -- ground this close to a structure is left alone
	block = 16,
}

-- Under sand VoxeLibre builds foundations of sandstone.
local FOUNDATION = {["mcl_core:sand"] = "mcl_core:sandstone"}
-- A snow layer cannot be the top of a column of dirt.
local TOP = {["mcl_core:snow"] = "mcl_core:dirt_with_grass_snow"}

local function round(v) return math.floor(v + 0.5) end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- 1 at distance 0, 0 at the radius, flat at both ends.
local function fade(d, radius)
	local s = clamp(d / radius, 0, 1)
	return 1 - s * s * (3 - 2 * s)
end

-- Pads from a plan: {x0, z0, x1, z1} the footprint, {yx0 ...} the yard, y the
-- floor (the schematic's bottom slice is the ground layer, so pos.y is the
-- surface), surface the village material and height the building's.
function M.pads(plan, schematics, config)
	config = config or M.config
	local pads = {}
	for _, entry in ipairs(plan) do
		local box = terrain.footprint(entry, schematics)
		if not box then return nil, "unknown building " .. tostring(entry.name) end
		pads[#pads + 1] = {
			x0 = box.minp.x, z0 = box.minp.z, x1 = box.maxp.x, z1 = box.maxp.z,
			yx0 = box.minp.x - config.margin, yz0 = box.minp.z - config.margin,
			yx1 = box.maxp.x + config.margin, yz1 = box.maxp.z + config.margin,
			y = entry.pos.y, surface = entry.surface_mat, height = box.height,
		}
	end
	return pads
end

local function distance(x, z, x0, z0, x1, z1)
	local dx = math.max(x0 - x, 0, x - x1)
	local dz = math.max(z0 - z, 0, z - z1)
	return math.sqrt(dx * dx + dz * dz)
end

-- The pure planning half. `height_at(x, z)` gives a column's current terrain
-- height, or nil to leave it alone (water, or outside what was read). Returns
--   {x0, z0, x1, z1 = the box of columns considered,
--    at(x, z) = target height or nil, was(x, z) = terrain height or nil,
--    pad(x, z) = index of the pad it belongs to, kind(x, z) = "footprint",
--    "yard", "skirt" or nil, violations = adjacent pairs, at least one of them
--    changed, that still differ by more than 1}
function M.targets(pads, height_at, config)
	config = config or M.config
	local radius, reach = config.radius, config.radius + config.margin
	local bx0, bz0, bx1, bz1
	for _, p in ipairs(pads) do
		bx0, bz0 = math.min(bx0 or p.x0, p.x0 - reach), math.min(bz0 or p.z0, p.z0 - reach)
		bx1, bz1 = math.max(bx1 or p.x1, p.x1 + reach), math.max(bz1 or p.z1, p.z1 + reach)
	end
	local result = {violations = 0}
	if not bx0 then
		function result.at() end
		result.was, result.pad, result.kind = result.at, result.at, result.at
		return result
	end
	result.x0, result.z0, result.x1, result.z1 = bx0, bz0, bx1, bz1
	local width = bx1 - bx0 + 1
	local function index(x, z) return (z - bz0) * width + (x - bx0) + 1 end

	local was, goal, low, high, free, owner, kind = {}, {}, {}, {}, {}, {}, {}
	for z = bz0, bz1 do
		for x = bx0, bx1 do
			local t = height_at(x, z)
			if t then
				local i = index(x, z)
				was[i] = t
				-- The pad whose footprint holds the column or is nearest, and the
				-- blend of every pad within the radius of its yard.
				local near, near_d, yard_hit, sum, weights, dmin = nil, math.huge, nil, 0, 0, math.huge
				for n, p in ipairs(pads) do
					local d = distance(x, z, p.yx0, p.yz0, p.yx1, p.yz1)
					if d < radius then
						local fd = distance(x, z, p.x0, p.z0, p.x1, p.z1)
						if fd < near_d then near, near_d = n, fd end
						if d == 0 then yard_hit = true end
						dmin = math.min(dmin, d)
						if d > 0 then
							local w = 1 / (d * d)
							sum, weights = sum + w * p.y, weights + w
						end
					end
				end
				if near then
					owner[i] = near
					local p = pads[near]
					if near_d == 0 then
						kind[i], goal[i], free[i] = "footprint", p.y, false
					elseif yard_hit then
						kind[i], free[i] = "yard", false
						goal[i] = clamp(p.y, t - config.cap, t + config.cap)
					else
						kind[i], free[i] = "skirt", true
						local blend = sum / weights
						goal[i] = clamp(round(t + fade(dmin, radius) * (blend - t)), t - config.cap, t + config.cap)
					end
					low[i], high[i] = t - config.cap, t + config.cap
				else
					goal[i], free[i] = t, false
				end
			end
		end
	end

	-- Limit the slope: a free column moves toward each neighbor until it is within
	-- one block of it, never past the cap. The pads and the untouched ground
	-- around them hold still, so the slope bends only in the skirt.
	for _ = 1, config.relax_passes do
		local changed = false
		for z = bz0, bz1 do
			for x = bx0, bx1 do
				local i = index(x, z)
				if free[i] then
					local v = goal[i]
					for _, n in ipairs({
						x > bx0 and i - 1, x < bx1 and i + 1, z > bz0 and i - width, z < bz1 and i + width,
					}) do
						local g = n and goal[n]
						if g then v = clamp(v, g - 1, g + 1) end
					end
					v = clamp(v, low[i], high[i])
					if v ~= goal[i] then goal[i], changed = v, true end
				end
			end
		end
		if not changed then break end
	end

	for z = bz0, bz1 do
		for x = bx0, bx1 do
			local i = index(x, z)
			if goal[i] then
				for _, other in ipairs({{x + 1, z, i + 1}, {x, z + 1, i + width}}) do
					local ox, oz, oi = other[1], other[2], other[3]
					if ox <= bx1 and oz <= bz1 and goal[oi]
							and (goal[i] ~= was[i] or goal[oi] ~= was[oi]) and math.abs(goal[i] - goal[oi]) > 1 then
						result.violations = result.violations + 1
					end
				end
			end
		end
	end

	local function lookup(array)
		return function(x, z)
			if x < bx0 or x > bx1 or z < bz0 or z > bz1 then return nil end
			return array[index(x, z)]
		end
	end
	result.at, result.was, result.pad, result.kind = lookup(goal), lookup(was), lookup(owner), lookup(kind)
	return result
end

-- The box read and written: the pads and the radius around them, from
-- `below` under the lowest pad to `above` over the highest.
local function area_of(pads, config)
	local area
	for _, p in ipairs(pads) do
		local reach = config.margin + config.radius
		local box = {
			minp = {x = p.x0 - reach, y = p.y - config.below, z = p.z0 - reach},
			maxp = {x = p.x1 + reach, y = p.y + config.above, z = p.z1 + reach},
		}
		if not area then
			area = box
		else
			for _, axis in ipairs({"x", "y", "z"}) do
				area.minp[axis] = math.min(area.minp[axis], box.minp[axis])
				area.maxp[axis] = math.max(area.maxp[axis], box.maxp[axis])
			end
		end
	end
	return area
end

-- Loads the mapblocks of the area that exist, one probe per block, and returns
-- how many are still missing (ungenerated). It never waits: mcl_vars.get_node
-- with `force` busy-waits on the server thread, which blocks the mapgen it waits
-- for, so ground in a missing block is simply left alone.
function M.load_area(area, config, env)
	local size, missing = config.block, 0
	for bz = math.floor(area.minp.z / size), math.floor(area.maxp.z / size) do
		for by = math.floor(area.minp.y / size), math.floor(area.maxp.y / size) do
			for bx = math.floor(area.minp.x / size), math.floor(area.maxp.x / size) do
				local pos = {
					x = clamp(bx * size, area.minp.x, area.maxp.x),
					y = clamp(by * size, area.minp.y, area.maxp.y),
					z = clamp(bz * size, area.minp.z, area.maxp.z),
				}
				if env.load_node(pos).name == "ignore" then missing = missing + 1 end
			end
		end
	end
	return missing
end

-- Writes the targets. Changed columns go through village_terrain.set_column
-- (surface material on top, a fill under, everything above a cut removed); a
-- column of a pad or yard that keeps its height still gets its holes filled.
-- Returns {changed, cut, filled, steepest}.
function M.apply(pads, targets, lookup, config, engine)
	local stats = {changed = 0, cut = 0, filled = 0, steepest = 0}
	for z = targets.z0, targets.z1 do
		for x = targets.x0, targets.x1 do
			local target, was = targets.at(x, z), targets.was(x, z)
			local pad = targets.pad(x, z)
			if target and pad then
				local surface = pads[pad].surface or "mcl_core:dirt_with_grass"
				local fill = FOUNDATION[surface] or "mcl_core:dirt"
				if target ~= was then
					local column = lookup(x, z)
					local top = math.max(column.y or was, was)
					if target < was then top = math.max(top, was + config.cut_clear) end
					terrain.set_column(x, z, top, target, TOP[surface] or surface, fill, engine)
					stats.changed = stats.changed + 1
					stats[target < was and "cut" or "filled"] = stats[target < was and "cut" or "filled"] + 1
					stats.steepest = math.max(stats.steepest, math.abs(target - was))
				elseif targets.kind(x, z) ~= "skirt" then
					terrain.fill_below(x, z, target, fill, engine)
				end
			end
		end
	end
	return stats
end

-- settlements.terraform's replacement. `env` has settlements (schematic_table),
-- load_node, scan (optional, village_fragments.scan_structures), clear_trees, engine, and `original` to fall back on when the area
-- can't be loaded. Returns true if the ground was smoothed.
function M.terraform(plan, pr, env, config)
	config = config or M.config
	local engine = env.engine
	local pads, why = M.pads(plan, env.settlements.schematic_table, config)
	local function fall_back(reason)
		engine.log("warning", "[living_villages] ground not smoothed, using VoxeLibre's terraform: " .. reason)
		env.original(plan, pr)
		return false
	end
	if not pads or #pads == 0 then return fall_back(why or "empty plan") end
	local area = area_of(pads, config)

	local started = engine.get_us_time and engine.get_us_time()
	-- Trees are cleared out to the same reach as the smoothing, and the tree fill
	-- may run on sideways past it, so load a bit further than the area.
	local margin = fragments.config.cap_radius
	local loading = {
		minp = {x = area.minp.x - margin, y = area.minp.y, z = area.minp.z - margin},
		maxp = {x = area.maxp.x + margin, y = area.maxp.y, z = area.maxp.z + margin},
	}
	local missing = M.load_area(loading, config, env)

	local zone = {}
	for _, p in ipairs(pads) do
		local reach = config.margin + config.radius
		zone[#zone + 1] = {
			minp = {x = p.x0 - reach, y = area.minp.y, z = p.z0 - reach},
			maxp = {x = p.x1 + reach, y = area.maxp.y, z = p.z1 + reach},
		}
	end
	env.clear_trees(zone)

	local lookup, reason = terrain.heights(area, env.settlements.surface_mat, engine, true)
	if not lookup then return fall_back(reason) end
	-- Structures (ruined portals, outposts) are not terrain: leave them and the
	-- ground just around them alone. The planner keeps them only a few blocks from
	-- a footprint, but the smoothing reaches further.
	local structures = env.scan and env.scan(area)
	local m = config.structure_margin
	local function near_structure(x, z)
		return structures and structures.find(x - m, z - m, x + m, z + m) ~= nil
	end
	local targets = M.targets(pads, function(x, z)
		local column = lookup(x, z)
		if not column or column.liquid or near_structure(x, z) then return nil end
		return column.surface_y or column.y
	end, config)
	local stats = M.apply(pads, targets, lookup, config, engine)
	engine.log("action", ("[living_villages] smoothed %d columns (%d cut, %d filled, steepest %d), %d steps still over 1 block, %d unloaded blocks skipped%s")
		:format(stats.changed, stats.cut, stats.filled, stats.steepest, targets.violations, missing,
			started and (", " .. math.floor((engine.get_us_time() - started) / 1000) .. " ms") or ""))
	return true
end

local structure_test
-- Replaces settlements.terraform (see village_terrain.install for the guard).
function M.install(globals, engine)
	engine = engine or core
	structure_test = fragments.structure_test(engine)
	return terrain.install(globals, {{
		target = "terraform",
		needs = {
			"mcl_vars.get_node",
			{"settlements.schematic_table", type = "table"},
			{"settlements.surface_mat", type = "table"},
		},
		make = function(original)
			return function(plan, pr)
				return M.terraform(plan, pr, {
					settlements = globals.settlements,
					engine = engine,
					original = original,
					load_node = function(pos) return globals.mcl_vars.get_node(pos) end,
					scan = function(area) return fragments.scan_structures(area, structure_test, engine) end,
					clear_trees = function(zone) return fragments.clear_trees(zone, nil, engine) end,
				})
			end
		end,
	}}, engine)
end

return M
