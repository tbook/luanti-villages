-- Smooths the ground around village buildings (#140, part of #133). VoxeLibre's
-- settlements.terraform (mcl_villages/foundation.lua) fills straight down under
-- each footprint and clears straight up, which leaves dirt towers and deep
-- shafts. This replaces it, and runs the terraform steps in order: load the
-- area, clear whole trees (village_fragments.clear_trees, #141), smooth, then fill
-- the holes and cliffs the smoothing leaves (village_holes.lua, #142, #155).
--
-- Each building gets a pad, its footprint plus a flat yard at the site's height.
-- Every column within `radius` of a pad (the skirt) keeps its height unless the
-- slope limit moves it, as little as it must, to leave no step over one block
-- against a yard or the untouched ground, so villagers can walk it (#235). The
-- planning half (targets) is a pure function, so it is tested without the engine.
--
-- Loading this has no side effects. The engine functions come in through `env`.
local core = minetest
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")
local fragments = dofile(core.get_modpath("living_villages") .. "/village_fragments.lua")
local holes = dofile(core.get_modpath("living_villages") .. "/village_holes.lua")

local M = {}

local DEFAULT_INSPECTION_Y = 48 -- boundary grading reads the ground across this full range

M.config = {
	margin = 2, -- the flat yard around a footprint
	radius = 8, -- how far from a pad the ground is changed
	cap = 5, -- no column moves more than this
	wall = 6, -- a step this tall beside a footprint or yard counts as a wall in the log
	below = 20, above = 24, -- the area reaches this far under the lowest pad and over the highest
	cut_clear = 3, -- a cut removes this much above the old surface, for whatever stands on it
	structure_margin = 1, -- ground this close to a structure is left alone
	block = 16,
}

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

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

-- Like `spread` but only from sources within `maxd` steps, by layers: a bucket
-- queue gives a column to the highest source, and would lose a nearer, lower one
-- when the higher one is too far to carry on.
local function window(seeds, free, width, maxd)
	local best, from, frontier = {}, {}, {}
	for k = 1, #seeds, 3 do
		local i, v = seeds[k], seeds[k + 1]
		if not best[i] then frontier[#frontier + 1] = i end
		if not best[i] or v > best[i] then best[i], from[i] = v, seeds[k + 2] end
	end
	for layer = 2, maxd do
		local update, count = {}, 0
		for _, i in ipairs(frontier) do
			local v = best[i] - 1
			local col = (i - 1) % width
			for _, j in ipairs({col > 0 and i - 1 or 0, col < width - 1 and i + 1 or 0, i - width, i + width}) do
				if free[j] and (not best[j] or v > best[j]) and (not update[j] or v > update[j]) then
					if not update[j] then count = count + 1 end
					update[j] = v
				end
			end
		end
		if count == 0 then break end
		frontier = {}
		for j, v in pairs(update) do
			best[j], from[j] = v, layer
			frontier[#frontier + 1] = j
		end
		table.sort(frontier)
	end
	return best, from
end

-- Bucket-queue Dijkstra with unit steps over the free columns (see limit_slope),
-- from all sources, or only those within `maxd` steps.
local function spread(seeds, floor_v, free, width, maxd)
	if maxd then return window(seeds, free, width, maxd) end
	-- seeds: flat list of {index, value, d}. Returns, for each free column, the
	-- highest value of seed value - steps, and the steps of the first such seed.
	local best, from, buckets, top_v = {}, {}, {}, -math.huge
	for k = 1, #seeds, 3 do
		local v = seeds[k + 1]
		local bucket = buckets[v]
		if not bucket then
			bucket = {}
			buckets[v] = bucket
			top_v = math.max(top_v, v)
		end
		local m = #bucket
		bucket[m + 1], bucket[m + 2] = seeds[k], seeds[k + 2]
	end
	local function push(i, v, d)
		local bucket = buckets[v]
		if not bucket then
			bucket = {}
			buckets[v] = bucket
		end
		local m = #bucket
		bucket[m + 1], bucket[m + 2] = i, d
	end
	for v = top_v, floor_v, -1 do
		local bucket = buckets[v]
		if bucket then
			local k = 1
			while k <= #bucket do
				local i, d = bucket[k], bucket[k + 1]
				k = k + 2
				if not best[i] then
					best[i], from[i] = v, d
					if v > floor_v then
						local col = (i - 1) % width
						if col > 0 and free[i - 1] and not best[i - 1] then push(i - 1, v - 1, d + 1) end
						if col < width - 1 and free[i + 1] and not best[i + 1] then push(i + 1, v - 1, d + 1) end
						if free[i - width] and not best[i - width] then push(i - width, v - 1, d + 1) end
						if free[i + width] and not best[i + width] then push(i + width, v - 1, d + 1) end
					end
				end
			end
			buckets[v] = nil
		end
	end
	return best, from
end

-- Seeds for the bounds (sign 1: lower, -1: upper) or the smoothing: each free
-- column's own value (`own[i]`, at 0 steps) and each reachable fixed neighbor's
-- (at 1 step). Own values go first so a bucket stays sorted by steps.
local function seeds_of(sign, own, fixed, hard, low, high, free, width, n)
	local seeds, floor_v = {}, math.huge
	local function add(i, v, d)
		seeds[#seeds + 1], seeds[#seeds + 2], seeds[#seeds + 3] = i, v, d
		if v < floor_v then floor_v = v end
	end
	for i = 1, n do
		if free[i] then
			if own then
				add(i, sign * own[i], 0)
			else
				-- A bound below what the column's cap range allows is no bound.
				floor_v = math.min(floor_v, sign > 0 and low[i] or -high[i])
			end
		end
	end
	for i = 1, n do
		if free[i] then
			local col = (i - 1) % width
			local lo, hi = low[i] - 1, high[i] + 1
			local g
			g = col > 0 and fixed[i - 1]
			if g and (hard[i - 1] or g >= lo and g <= hi) then add(i, sign * g - 1, 1) end
			g = col < width - 1 and fixed[i + 1]
			if g and (hard[i + 1] or g >= lo and g <= hi) then add(i, sign * g - 1, 1) end
			g = fixed[i - width]
			if g and (hard[i - width] or g >= lo and g <= hi) then add(i, sign * g - 1, 1) end
			g = fixed[i + width]
			if g and (hard[i + width] or g >= lo and g <= hi) then add(i, sign * g - 1, 1) end
		end
	end
	return seeds, floor_v
end

-- Limits the slope (#235) of the free (skirt) columns of a grid `width` wide,
-- indexed row by row: `goal` is every column's target (a free column's is its
-- own height), `low`/`high` a free column's cap range, `free` marks the columns that
-- may move. The rest (footprints, yards, untouched ground) never do. Each free
-- column ends within one block of every neighbor wherever its cap range allows
-- it, in three steps:
--   1. Bounds. A fixed column of height g, d steps away through free columns,
--      allows [g - d, g + d]. Two bucket-queue passes (Dijkstra with unit steps,
--      `spread`) give each free column the highest lower and lowest upper bound
--      over all fixed columns, cut down by its own cap range. A neighbor of the
--      untouched ground that the cap range cannot come within one block of is no
--      source (a pit beside the skirt would only drag it to the cap); a pad's
--      column always is, and pulls as far as the cap lets it.
--   2. Conflicts. Where the bounds cross, the sources cannot all be met (a yard
--      and a cliff past the cap, two pads at odds). The nearest ones win: the
--      column takes the bounds from the fixed columns within 16, 8, 4, 2, 1
--      steps, the most that leave it a range, so the break falls away from the
--      yard. If even the adjacent ones disagree the nearer takes the column's
--      single value (the cap range counts as nearest, then a tie takes the middle).
--   3. Smoothing. The goals held in the bounds are made 1-Lipschitz by the mean
--      of the largest such field below them and the smallest above them (min of
--      v + d and max of v - d over the free columns, with the fixed neighbors),
--      which takes off mounds and fills dips, whatever order the neighbors come
--      in. The mean stays in the bounds.

local function limit_slope(goal, low, high, free, hard, width, depth)
	local n = width * depth
	local fixed, open = {}, {}
	for i = 1, n do
		if goal[i] then
			if free[i] then open[i] = true else fixed[i] = goal[i] end
		end
	end
	-- Each free column's cap range cut down by the fixed columns within `maxd`
	-- steps, and the steps to whatever set each end (0 for its own cap).
	local function bounds(maxd)
		local seeds, floor_v = seeds_of(1, nil, fixed, hard, low, high, open, width, n)
		local fl, fl_d = spread(seeds, floor_v, open, width, maxd)
		seeds, floor_v = seeds_of(-1, nil, fixed, hard, low, high, open, width, n)
		local fu, fu_d = spread(seeds, floor_v, open, width, maxd)
		local lower, upper, lower_d, upper_d = {}, {}, {}, {}
		for i = 1, n do
			if open[i] then
				if fl[i] and fl[i] > low[i] then lower[i], lower_d[i] = fl[i], fl_d[i] else lower[i], lower_d[i] = low[i], 0 end
				if fu[i] and -fu[i] < high[i] then upper[i], upper_d[i] = -fu[i], fu_d[i] else upper[i], upper_d[i] = high[i], 0 end
			end
		end
		return lower, upper, lower_d, upper_d
	end
	local lower, upper, lower_d, upper_d = bounds()
	local crossed = {}
	for i = 1, n do
		if open[i] and lower[i] > upper[i] then crossed[#crossed + 1] = i end
	end
	-- Sources that cannot all be met: keep the nearest ones. A crossed column takes
	-- its bounds from the fixed columns within the most steps that still leave it a
	-- range, and where even the adjacent ones disagree (or its cap misses them) the
	-- nearer wins and the value is fixed.
	for _, reach_d in ipairs({16, 8, 4, 2, 1}) do
		if #crossed == 0 then break end
		local l, u, ld, ud = bounds(reach_d)
		local rest = {}
		for _, i in ipairs(crossed) do
			if l[i] <= u[i] then
				lower[i], upper[i], lower_d[i], upper_d[i] = l[i], u[i], ld[i], ud[i]
			elseif reach_d == 1 then
				local v
				if ld[i] < ud[i] then v = l[i]
				elseif ud[i] < ld[i] then v = u[i]
				else v = math.floor((l[i] + u[i]) / 2) end
				v = clamp(v, low[i], high[i])
				lower[i], upper[i] = v, v
			else
				rest[#rest + 1] = i
			end
		end
		crossed = rest
	end
	-- Smoothing: the goals held in their bounds are made 1-Lipschitz by the mean
	-- of the largest field below them and the smallest above them.
	local hold = {}
	for i = 1, n do
		if open[i] then hold[i] = clamp(goal[i], lower[i], upper[i]) end
	end
	local seeds, floor_v = seeds_of(-1, hold, fixed, hard, low, high, open, width, n)
	local under = spread(seeds, floor_v, open, width)
	seeds, floor_v = seeds_of(1, hold, fixed, hard, low, high, open, width, n)
	local over = spread(seeds, floor_v, open, width)
	for i = 1, n do
		if open[i] then
			goal[i] = clamp(math.floor((over[i] - under[i]) / 2), lower[i], upper[i])
		end
	end
end

M.spread = spread -- for the tests

-- The pure planning half. `height_at(x, z)` gives a column's current terrain
-- height, or nil to leave it alone (water, or outside what was read), and as a
-- second value whether that height is only an overhang's slab over air (#209):
-- a column like that, outside every footprint, is left as nature made it, because
-- cutting it by the cap and filling under it builds a dirt wall under the slab
-- (in a yard too: the cap keeps the yard far above its pad). A footprint column
-- is set as ever. Returns
--   {x0, z0, x1, z1 = the box of columns considered,
--    at(x, z) = target height or nil, was(x, z) = terrain height or nil,
--    pad(x, z) = index of the pad it belongs to, kind(x, z) = "footprint",
--    "yard", "skirt" or nil, violations = adjacent pairs, at least one of them
--    changed, that still differ by more than 1, walls = those pairs that differ
--    by `config.wall` or more with a footprint or yard column on at least one
--    side (each pair once), wall_max = the tallest (#220)}
function M.targets(pads, height_at, config, protected)
	config = config or M.config
	local radius, reach = config.radius, config.radius + config.margin
	local bx0, bz0, bx1, bz1
	for _, p in ipairs(pads) do
		bx0, bz0 = math.min(bx0 or p.x0, p.x0 - reach), math.min(bz0 or p.z0, p.z0 - reach)
		bx1, bz1 = math.max(bx1 or p.x1, p.x1 + reach), math.max(bz1 or p.z1, p.z1 + reach)
	end
	local result = {violations = 0, walls = 0, wall_max = 0}
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
			local t, overhang = height_at(x, z)
			local is_protected = false
			for _, rect in ipairs(protected or {}) do
				local margin = rect.margin or 0
				if x >= rect.x0 - margin and x <= rect.x1 + margin
						and z >= rect.z0 - margin and z <= rect.z1 + margin then
						is_protected = true
						break
				end
			end
			if t then
				local i = index(x, z)
				was[i] = t
				if is_protected then
					-- Protected terrain is a fixed slope constraint, just like untouched ground.
					goal[i], free[i] = t, false
				else
				-- The pad whose footprint holds the column or is nearest, within the
				-- radius of its yard.
				local near, near_d, yard_hit = nil, math.huge, nil
				for n, p in ipairs(pads) do
					local d = distance(x, z, p.yx0, p.yz0, p.yx1, p.yz1)
					if d < radius then
						local fd = distance(x, z, p.x0, p.z0, p.x1, p.z1)
						if fd < near_d then near, near_d = n, fd end
						if d == 0 then yard_hit = true end
					end
				end
				if near then
					owner[i] = near
					local p = pads[near]
					if near_d == 0 then
						kind[i], goal[i], free[i] = "footprint", p.y, false
					elseif overhang then
						-- Not a column at all: no height, no pad, no change.
						was[i], owner[i] = nil, nil
					elseif yard_hit then
						kind[i], free[i] = "yard", false
						goal[i] = clamp(p.y, t - config.cap, t + config.cap)
					else
						-- Wants to stay as it is; the slope limit moves it as little as it must.
						kind[i], goal[i], free[i] = "skirt", t, true
					end
					low[i], high[i] = t - config.cap, t + config.cap
				else
					goal[i], free[i] = t, false
				end
				end
			end
		end
	end

	-- Limit the slope (limit_slope): a skirt column ends within one block of each
	-- neighbor where its cap range allows. The pads and the untouched ground around
	-- them hold still, so the slope bends only in the skirt.
	local hard = {}
	for i, k in pairs(kind) do hard[i] = k ~= "skirt" end
	limit_slope(goal, low, high, free, hard, width, bz1 - bz0 + 1)

	for z = bz0, bz1 do
		for x = bx0, bx1 do
			local i = index(x, z)
			if goal[i] then
				for _, other in ipairs({{x + 1, z, i + 1}, {x, z + 1, i + width}}) do
					local ox, oz, oi = other[1], other[2], other[3]
					if ox <= bx1 and oz <= bz1 and goal[oi]
							and (goal[i] ~= was[i] or goal[oi] ~= was[oi]) and math.abs(goal[i] - goal[oi]) > 1 then
						result.violations = result.violations + 1
						local jump = math.abs(goal[i] - goal[oi])
						if jump >= config.wall and (kind[i] ~= "skirt" and kind[i] or kind[oi] ~= "skirt" and kind[oi]) then
							result.walls, result.wall_max = result.walls + 1, math.max(result.wall_max, jump)
						end
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

local function merge_box(area, box)
	if not box then return area end
	if not area then
		return {minp = {x = box.minp.x, y = box.minp.y, z = box.minp.z},
			maxp = {x = box.maxp.x, y = box.maxp.y, z = box.maxp.z}}
	end
	for _, axis in ipairs({"x", "y", "z"}) do
		area.minp[axis] = math.min(area.minp[axis], box.minp[axis])
		area.maxp[axis] = math.max(area.maxp[axis], box.maxp[axis])
	end
	return area
end

-- Shared bounds for the actual stages and the public pre-emerge query. Keep the
-- boxes that each stage uses separate for loading and work, then take their union
-- plus direct column reads/writes that can leave those stage boxes.
local function bounds_for_pads(pads, config, hole_config)
	local area, zones
	local reach = config.margin + config.radius
	for _, p in ipairs(pads) do
		local box = {minp = {x = p.x0 - reach, y = p.y - config.below, z = p.z0 - reach},
			maxp = {x = p.x1 + reach, y = p.y + config.above, z = p.z1 + reach}}
		area = merge_box(area, box)
		zones = zones or {}
		zones[#zones + 1] = {minp = {x = p.x0 - reach, y = 0, z = p.z0 - reach},
			maxp = {x = p.x1 + reach, y = 0, z = p.z1 + reach}}
	end
	if not area then return nil, "empty plan" end
	local hole_area = holes.area(pads, hole_config)
	for _, zone in ipairs(zones) do
		zone.minp.y, zone.maxp.y = area.minp.y, area.maxp.y
	end
	local tree_margin = math.max(fragments.config.cap_radius,
		(fragments.config.orphan_margin or 0) + (fragments.config.leaf_reach or 0))
	local tree_area = {
		minp = {x = area.minp.x - tree_margin, y = area.minp.y - fragments.config.cap_height,
			z = area.minp.z - tree_margin},
		maxp = {x = area.maxp.x + tree_margin, y = area.maxp.y + fragments.config.cap_height,
			z = area.maxp.z + tree_margin},
	}
	local whole = merge_box(nil, tree_area)
	whole = merge_box(whole, hole_area)
	-- Smoothing can fill twenty nodes below its target. Hole filling treats a
	-- bottomless shaft as area.minp.y - 1, then its lava fill reaches twenty lower.
	local max_target = -math.huge
	for _, p in ipairs(pads) do
		max_target = math.max(max_target, p.y)
	end
	whole.minp.y = math.min(whole.minp.y, area.minp.y - config.cap - 20,
		hole_area.minp.y - 21)
	-- put_decor probes/clears growth up to 32 nodes above the new surface. A
	-- cliff ramp may raise a hole column by cliff_rise beyond its spill height.
	whole.maxp.y = math.max(whole.maxp.y, area.maxp.y + config.cut_clear,
		max_target + config.cap + 32,
		hole_area.maxp.y + (hole_config.cliff_rise or 0) + 32)
	return {smoothing = area, tree = tree_area, holes = hole_area, zones = zones, union = whole}
end

local function integer(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
		and value % 1 == 0
end

local function validate_config(config, hole_config)
	if type(config) ~= "table" then return nil, "config must be a table" end
	if type(hole_config) ~= "table" then return nil, "hole config is unavailable" end
	for _, key in ipairs({"margin", "radius", "cap", "below", "above", "structure_margin", "cut_clear"}) do
		if not integer(config[key]) or config[key] < 0 then return nil, "invalid config." .. key end
	end
	if not integer(config.wall) or config.wall < 1 then return nil, "invalid config.wall" end
	if not integer(config.block) or config.block < 1 then return nil, "invalid config.block" end
	for _, key in ipairs({"margin", "below", "above", "cliff_rise"}) do
		if not integer(hole_config[key]) or hole_config[key] < 0 then return nil, "invalid hole_config." .. key end
	end
	return true
end

local function validate_protected(protected)
	if protected == nil then return true end
	if type(protected) ~= "table" then return nil, "protected must be a list" end
	local count, max_key = 0, 0
	for key, rect in pairs(protected) do
		if not integer(key) or key < 1 or type(rect) ~= "table" then
			return nil, "protected must be a dense list of rectangles"
		end
		count, max_key = count + 1, math.max(max_key, key)
		for _, field in ipairs({"x0", "z0", "x1", "z1"}) do
			if not integer(rect[field]) then return nil, "invalid protected rectangle " .. key .. ": " .. field end
		end
		if rect.x0 > rect.x1 or rect.z0 > rect.z1 then
			return nil, "invalid protected rectangle " .. key .. ": bounds are reversed"
		end
		if rect.margin ~= nil and (not integer(rect.margin) or rect.margin < 0) then
			return nil, "invalid protected rectangle " .. key .. ": margin"
		end
	end
	if count ~= max_key then return nil, "protected must be a dense list of rectangles" end
	return true
end

local function prepare_plan(plan, schematics, surface_y)
	if type(plan) ~= "table" or #plan == 0 then return nil, "empty plan" end
	if type(schematics) ~= "table" then return nil, "schematic table is required" end
	local length, count = 0, 0
	for key in pairs(plan) do
		if not integer(key) or key < 1 then return nil, "plan must be a dense list" end
		length, count = math.max(length, key), count + 1
	end
	if count ~= length or length ~= #plan then return nil, "plan must be a dense list" end
	if surface_y ~= nil then
		if type(surface_y) ~= "table" or not integer(surface_y.min) or not integer(surface_y.max)
				or surface_y.min > surface_y.max then
			return nil, "surface_y must contain inclusive integer min and max"
		end
	end
	local copied = {}
	for index, entry in ipairs(plan) do
		if type(entry) ~= "table" or type(entry.name) ~= "string" or type(entry.pos) ~= "table"
				or not integer(entry.pos.x) or not integer(entry.pos.z) then
			return nil, "invalid plan entry " .. index
		end
		if entry.rotat ~= nil and entry.rotat ~= "0" and entry.rotat ~= "90"
				and entry.rotat ~= "180" and entry.rotat ~= "270" then
			return nil, "invalid rotation for " .. entry.name
		end
		local found
		for _, schematic in ipairs(schematics) do
			if type(schematic) == "table" and schematic.name == entry.name then
				found = schematic
				break
			end
		end
		if not found then return nil, "unknown building " .. entry.name end
		for _, key in ipairs({"hwidth", "hdepth", "hheight"}) do
			if not integer(found[key]) or found[key] < 1 then
				return nil, "invalid schematic " .. entry.name .. ": " .. key
			end
		end
		local low, high = entry.pos.y, entry.pos.y
		if entry.pos.y == nil then
			if not surface_y then return nil, "plan entry " .. entry.name .. " needs pos.y or surface_y" end
			low, high = surface_y.min, surface_y.max
		elseif not integer(entry.pos.y) then
			return nil, "invalid surface y for " .. entry.name
		end
		for _, y in ipairs({low, high}) do
			local copy = {name = entry.name, rotat = entry.rotat,
				pos = {x = entry.pos.x, y = y, z = entry.pos.z}, surface_mat = entry.surface_mat}
			copied[#copied + 1] = copy
		end
	end
	return copied
end

local function mapblock_bounds(box)
	local function down(value) return math.floor(value / 16) * 16 end
	local function up(value) return math.floor(value / 16) * 16 + 15 end
	return {minp = {x = down(box.minp.x), y = down(box.minp.y), z = down(box.minp.z)},
		maxp = {x = up(box.maxp.x), y = up(box.maxp.y), z = up(box.maxp.z)}}
end

-- Bounds for the follow-up town-boundary pass (#296/#297). Its ground scan
-- covers +/-48 around ground_y; tree cleanup and column helpers can read or
-- write beyond that scan, so include their full configured reaches as well.
function M.boundary_volume(rectangles, ground_y, options)
	if options == nil then options = {} end
	if type(options) ~= "table" then return nil, "options must be a table" end
	local radius = options.radius == nil and 20 or options.radius
	local cap = options.cap == nil and M.config.cap or options.cap
	if not integer(ground_y) then return nil, "ground_y must be an integer" end
	if not integer(radius) or radius < 0 then return nil, "radius must be a nonnegative integer" end
	if not integer(cap) or cap < 0 then return nil, "cap must be a nonnegative integer" end
	if type(rectangles) ~= "table" then return nil, "boundary must be a list of rectangles" end
	local count, max_key = 0, 0
	local minx, minz, maxx, maxz
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
		minx, minz = math.min(minx or rect.x0, rect.x0), math.min(minz or rect.z0, rect.z0)
		maxx, maxz = math.max(maxx or rect.x1, rect.x1), math.max(maxz or rect.z1, rect.z1)
	end
	if count == 0 then return nil, "empty boundary" end
	if count ~= max_key then return nil, "boundary must be a dense list of rectangles" end
	local tree_margin = math.max(fragments.config.cap_radius,
		(fragments.config.orphan_margin or 0) + (fragments.config.leaf_reach or 0))
	local box = {
		minp = {x = minx - radius - tree_margin,
			y = math.min(ground_y - DEFAULT_INSPECTION_Y - fragments.config.cap_height,
				ground_y - cap - 20),
			z = minz - radius - tree_margin},
		maxp = {x = maxx + radius + tree_margin,
			y = math.max(ground_y + DEFAULT_INSPECTION_Y + 3,
				ground_y + cap + 32) + fragments.config.cap_height,
			z = maxz + radius + tree_margin},
	}
	box = mapblock_bounds(box)
	local map_limit = 31000
	for _, axis in ipairs({"x", "y", "z"}) do
		if box.minp[axis] < -map_limit or box.maxp[axis] > map_limit then
			return nil, "boundary volume exceeds the world map limit"
		end
	end
	return box
end

-- The read-only, deterministic query used before a caller emerges its area.
function M.volume(plan, schematic_table, options, engine)
	if options == nil then options = {} end
	if type(options) ~= "table" then return nil, "options must be a table" end
	if options.env ~= nil and type(options.env) ~= "table" then return nil, "options.env must be a table" end
	engine = engine or (options.env and options.env.engine) or core
	if type(engine) ~= "table" then return nil, "engine must be a table" end
	local config = options.config or M.config
	local hole_config = holes.configured(engine)
	local valid, reason = validate_config(config, hole_config)
	if not valid then return nil, reason end
	valid, reason = validate_protected(options.protected)
	if not valid then return nil, reason end
	local prepared
	prepared, reason = prepare_plan(plan, schematic_table, options.surface_y)
	if not prepared then return nil, reason end
	local pads
	pads, reason = M.pads(prepared, schematic_table, config)
	if not pads then return nil, reason end
	local bounds = bounds_for_pads(pads, config, hole_config)
	return mapblock_bounds(bounds.union)
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
				local surface, fill = terrain.materials(pads[pad].surface)
				if target ~= was then
					local column = lookup(x, z)
					local top = math.max(column.y or was, was)
					if target < was then top = math.max(top, was + config.cut_clear) end
					-- What grew on the old surface goes onto the new one (#214); a stalk
					-- (bamboo, cactus, cane) is cleared, never left under a block (#224).
					local decor, decor_top = terrain.take_decor(x, z, was, engine)
					terrain.set_column(x, z, top, target, surface, fill, engine)
					terrain.put_decor(x, z, target, decor, decor_top, surface, engine)
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
function M.terraform(plan, pr, env, config, options)
	config = config or M.config
	local engine = env.engine
	options = options or {}
	local settlements = env.settlements or {}
	local schematic_table = options.schematic_table or settlements.schematic_table
	local surface_mat = options.surface_mat or settlements.surface_mat
	local terrain_env = setmetatable({
		settlements = {surface_mat = surface_mat},
	}, {__index = env})
	local pads, why = M.pads(plan, schematic_table, config)
	local function fall_back(reason)
		if options.no_fallback then return false, reason end
		engine.log("warning", "[living_villages] ground not smoothed, using VoxeLibre's terraform: " .. reason)
		env.original(plan, pr)
		return false
	end
	if not pads or #pads == 0 then return fall_back(why or "empty plan") end
	if type(surface_mat) ~= "table" then return fall_back("surface material table is unavailable") end
	if type(env.load_node) ~= "function" then return fall_back("node loading service is unavailable") end
	local hole_config = holes.configured(engine)
	local valid
	valid, why = validate_config(config, hole_config)
	if not valid then return fall_back(why) end
	local bounds
	bounds, why = bounds_for_pads(pads, config, hole_config)
	if not bounds then return fall_back(why) end
	local area = bounds.smoothing

	local started = engine.get_us_time and engine.get_us_time()
	local written = {minp = {x = math.huge, y = math.huge, z = math.huge},
		maxp = {x = -math.huge, y = -math.huge, z = -math.huge}}
	local function mark(x, y, z)
		written.minp.x, written.minp.y, written.minp.z = math.min(written.minp.x, x), math.min(written.minp.y, y), math.min(written.minp.z, z)
		written.maxp.x, written.maxp.y, written.maxp.z = math.max(written.maxp.x, x), math.max(written.maxp.y, y), math.max(written.maxp.z, z)
	end
	local writer = setmetatable({swap_node = function(pos, node)
		mark(pos.x, pos.y, pos.z)
		return engine.swap_node(pos, node)
	end}, {__index = engine})
	-- Trees are cleared out to the same reach as the smoothing, and the tree fill
	-- may run on sideways past it, so load a bit further than the area.
	local missing = M.load_area(bounds.tree, config, env)
	local hole_area = bounds.holes
	local hole_missing = M.load_area(hole_area, config, env)
	if options.no_fallback and (missing > 0 or hole_missing > 0) then
		return false, ("unloaded terrain: %d tree/smoothing blocks and %d hole blocks unavailable"):format(missing, hole_missing)
	end

	local tree_stats = env.clear_trees(bounds.zones, options.protected)
	local function include_box(box)
		if not box then return end
		for _, axis in ipairs({"x", "y", "z"}) do
			written.minp[axis] = math.min(written.minp[axis], box.minp[axis])
			written.maxp[axis] = math.max(written.maxp[axis], box.maxp[axis])
		end
	end
	include_box(tree_stats and tree_stats.written)

	local lookup, reason = terrain.heights(area, surface_mat, engine, true)
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
		if not column or near_structure(x, z) then return nil end
		-- The ground, not the top of what grows out of it (a stalk, #224), and wet or
		-- dry by that node, not by the leaves over it.
		if column.surface_y then
			if column.liquid then return nil end
			return column.surface_y, column.overhang
		elseif column.base_y then
			if column.base_liquid then return nil end
			return column.base_y, column.overhang
		end
		if column.liquid then return nil end
		return column.y, column.overhang
	end, config, options.protected)
	local stats = M.apply(pads, targets, lookup, config, writer)
	engine.log("action", ("[living_villages] smoothed %d columns (%d cut, %d filled, steepest %d), %d steps still over 1 block (%d walls of %d+, tallest %d), %d unloaded blocks skipped%s")
		:format(stats.changed, stats.cut, stats.filled, stats.steepest, targets.violations, targets.walls, config.wall, targets.wall_max, missing,
			started and (", " .. math.floor((engine.get_us_time() - started) / 1000) .. " ms") or ""))

	-- Then the holes the smoothing leaves: the gaps between buildings and where paths go.
	local hole_started = engine.get_us_time and engine.get_us_time()
	local hole_env = setmetatable({engine = writer, settlements = terrain_env.settlements}, {__index = env})
	local plan, hole_reason = holes.run(pads, hole_area, hole_env, hole_config, options.protected)
	if plan then
		engine.log("action", ("[living_villages] holes: %d columns filled, %d ramped (%d nodes), %d dropped over a limit, steps over 1 block %d -> %d, %d unloaded blocks skipped%s")
			:format(#plan.cells - plan.ramped, plan.ramped, plan.nodes, plan.dropped, plan.cliffs_before, plan.cliffs_after, hole_missing,
				hole_started and (", " .. math.floor((engine.get_us_time() - hole_started) / 1000) .. " ms") or ""))
	else
		engine.log("warning", "[living_villages] holes not filled: " .. tostring(hole_reason))
		if options.no_fallback then return false, "hole filling failed: " .. tostring(hole_reason) end
	end
	if written.minp.x == math.huge then written = nil end
	local stats = {changed = stats.changed, cut = stats.cut, filled = stats.filled, steepest = stats.steepest,
		steps_over_one = targets.violations, walls = targets.walls, wall_max = targets.wall_max,
		unloaded_blocks = missing + hole_missing, written = written,
		tree_removed = tree_stats and tree_stats.removed or 0,
		hole_filled = plan and plan.filled or 0, hole_ramped = plan and plan.ramped or 0,
		hole_nodes = plan and plan.nodes or 0}
	if options.no_fallback then return true, stats end
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
					clear_trees = function(zone, protected) return fragments.clear_trees(zone, nil, engine, protected) end,
				})
			end
		end,
	}}, engine)
end

return M
