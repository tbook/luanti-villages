-- Fills holes and cliffs inside a village (#142, #155, part of #133). #139 rejects
-- whole sites and #140 smooths only around buildings, so a pit or a cave-mouth shaft
-- in a gap between buildings is left, and a villager that drops into one cannot
-- climb the rise out (the planner's 1-block step rule).
--
-- Two raise-only phases over a height grid, both pure (plan) and so tested without
-- the engine. Nothing is ever cut, so nothing is destroyed.
--
-- 1. Depressions. Every column that is not a way out is raised to its spill level:
--    the lowest, over the paths from it to a way out, of the highest column on the
--    path (the priority-flood algorithm). Ways out are the edge of the area, columns
--    beside ground we can't see, protected columns (pads with their yards,
--    structures), water and the columns beside water. A shaft of any depth
--    disappears, whether one side of it steps down or not, and ground never rises
--    above the yard of a building it lies against, because the yard is a way out at
--    its own height. Surface lava is raised the same way, and the lava replaced.
-- 2. Cliffs. A column with a neighbor two or more higher is raised to that
--    neighbor's height minus one, repeatedly, so a slow step up that ends in a cliff
--    becomes a ramp all the way. This runs only where the rise stays within
--    `cliff_rise` of the column's original height: a taller wall is landscape, not a
--    hole, and a ramp up it would be a mound. A column within `ring` of a yard
--    never rises above that building's floor.
--
-- Only ground within `reach` of a yard is touched: farther out it is landscape and
-- counts as a way out, so a natural basin away from the buildings stays. A column
-- is the ground under a tree or cactus, not the plant (village_terrain.heights
-- base_y), and ice over water is water. In the ring, the ceiling clamps a column
-- below its spill level, so a hole whose mouth lies in the ring can be left as a
-- partly filled bowl with a step out of the ring; that is the price of no mound
-- against a wall.
-- Both phases only raise a column, never past the highest column there was, so they
-- stop. A change in one piece wider than `max_columns` columns, or past `budget`
-- nodes for the village (smallest pieces first), is dropped.
--
-- Loading this has no side effects. Run it after village_smoothing's ground work
-- and before the paths.
local core = minetest
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")

local M = {}

M.config = {
	margin = 12, -- the area is the plan's bounding box plus this, a little past the smoothing reach
	below = 40, above = 24, -- under the lowest pad, over the highest
	cliff_rise = 4, -- phase 2 closes a cliff only if no column rises more than this; 0 turns it off
	ring = 2, -- columns around a yard that fill never raises above the building's floor
	reach = 12, -- ground farther than this from every yard is landscape: left as it is, a way out
	rounds = 50, -- limit on undo rounds of phase 2
	passes = 200, -- limit on phase 2 sweeps
	max_columns = 1500, -- a change wider than this is a landscape basin, left alone
	budget = 60000, -- nodes written for one village at most
	structure_margin = 1, -- structures and the ground just around them are left alone
}

local SETTINGS = {
	cliff_rise = "living_villages_cliff_rise",
	budget = "living_villages_hole_budget",
}

-- A copy of M.config with the settings applied.
function M.configured(engine)
	engine = engine or core
	local config = {}
	for k, v in pairs(M.config) do config[k] = v end
	local settings = engine.settings
	if settings then
		for key, name in pairs(SETTINGS) do
			local v = tonumber(settings:get(name))
			if v then config[key] = v end
		end
	end
	return config
end

local DX = {1, -1, 0, 0}
local DZ = {0, 0, 1, -1}

-- A binary min-heap of items by priority.
local function heap()
	local items, prio, n = {}, {}, 0
	local H = {}
	function H.push(item, p)
		n = n + 1
		local i = n
		while i > 1 do
			local parent = math.floor(i / 2)
			if prio[parent] <= p then break end
			items[i], prio[i] = items[parent], prio[parent]
			i = parent
		end
		items[i], prio[i] = item, p
	end
	function H.pop()
		if n == 0 then return nil end
		local top = items[1]
		local item, p = items[n], prio[n]
		items[n], prio[n] = nil, nil
		n = n - 1
		if n == 0 then return top end
		local i = 1
		while true do
			local c = i * 2
			if c > n then break end
			if c < n and prio[c + 1] < prio[c] then c = c + 1 end
			if prio[c] >= p then break end
			items[i], prio[i] = items[c], prio[c]
			i = c
		end
		items[i], prio[i] = item, p
		return top
	end
	return H
end

-- The pure half. spec:
--   x0, z0, x1, z1  the box of columns
--   column(x, z)    {y = top height, liquid = bool, lava = bool, name = node name},
--                   nil if unknown
--   protected(x, z) true for columns that must not change (pads, structures)
--   ceiling(x, z)   optional: the height a column may not be raised above
--   near(x, z)      optional: false for columns that must not change and are ways out
--                   (ground far from every building)
-- Returns {cells = {{x, z, from, to, lava, name}...} (columns to raise from `from`
-- to `to`), nodes (to write), filled and ramped (columns by phase), dropped (columns
-- left because of a limit), passes (phase 2 sweeps), cliffs_before and cliffs_after
-- (adjacent pairs of columns more than one apart), at(x, z) = height afterward}.
function M.plan(spec, config)
	config = config or M.config
	local x0, z0, x1, z1 = spec.x0, spec.z0, spec.x1, spec.z1
	local width = x1 - x0 + 1
	local function index(x, z) return (z - z0) * width + (x - x0) + 1 end
	local function inside(x, z) return x >= x0 and x <= x1 and z >= z0 and z <= z1 end

	local h, kind, names, ceil, fixed = {}, {}, {}, {}, {}
	for z = z0, z1 do
		for x = x0, x1 do
			local c = spec.column(x, z)
			if c then
				local i = index(x, z)
				h[i] = c.y
				kind[i] = c.lava and "lava" or c.liquid and "water" or "dry"
				names[i] = c.name
				ceil[i] = spec.ceiling and spec.ceiling(x, z) or nil
				fixed[i] = spec.protected and spec.protected(x, z) or false
				if spec.near and not spec.near(x, z) then fixed[i] = true end
			end
		end
	end
	local orig = {}
	for i, y in pairs(h) do orig[i] = y end

	-- Neighbors of every known column, and the columns that are ways out.
	local nbr, water_beside = {}, {}
	for z = z0, z1 do
		for x = x0, x1 do
			local i = index(x, z)
			if h[i] then
				local list = {}
				local edge = x == x0 or x == x1 or z == z0 or z == z1
				for d = 1, 4 do
					local nx, nz = x + DX[d], z + DZ[d]
					if inside(nx, nz) then
						local ni = index(nx, nz)
						if h[ni] then
							list[#list + 1] = ni
							if kind[ni] == "water" then water_beside[i] = true end
						else
							edge = true -- next to ground we can't see: leave it to chance
						end
					end
				end
				nbr[i] = list
				if edge then fixed[i] = true end
			end
		end
	end
	for i in pairs(h) do
		if kind[i] == "water" or water_beside[i] then fixed[i] = true end
	end

	-- Phase 1: raise every depression to its spill level.
	local level, queue = {}, heap()
	for i in pairs(h) do
		if fixed[i] then level[i] = h[i]; queue.push(i, h[i]) end
	end
	while true do
		local i = queue.pop()
		if not i then break end
		for _, n in ipairs(nbr[i]) do
			if not level[n] then
				level[n] = math.max(h[n], level[i])
				queue.push(n, level[n])
			end
		end
	end
	local phase = {}
	for i in pairs(h) do
		if not fixed[i] then
			local to = level[i] or h[i]
			if ceil[i] then to = math.min(to, ceil[i]) end
			if kind[i] == "lava" then to = math.max(to, h[i]) end
			if to > h[i] or kind[i] == "lava" then
				h[i] = to
				phase[i] = 1
			end
		end
	end

	-- Phase 2: close cliffs by raising toward the higher neighbor, within `cliff_rise`.
	-- A raise that deepens a drop on its other side (a ledge raised against a wall, with
	-- a pit beyond that cannot follow) is undone, and the column held at its phase 1
	-- height; the rest then settle again. Held columns only grow in number, so this stops.
	local rise, passes = config.cliff_rise or 0, 0
	if rise > 0 then
		local order, base, held = {}, {}, {}
		for i in pairs(h) do
			base[i] = h[i]
			if not fixed[i] then order[#order + 1] = i end
		end
		table.sort(order)
		for _ = 1, config.rounds or 50 do
			for _ = 1, config.passes do
				local changed = false
				for _, i in ipairs(order) do
					if not held[i] then
						local top = -math.huge
						for _, n in ipairs(nbr[i]) do
							if h[n] > top then top = h[n] end
						end
						local to = top - 1
						-- Only the whole way: a limit that stops the column short of closing
						-- the cliff leaves it alone, since a bump would be no use. Limits are
						-- the ring ceiling and, beside a protected column, one above it.
						local limit = ceil[i] or math.huge
						for _, n in ipairs(nbr[i]) do
							if fixed[n] then limit = math.min(limit, h[n] + 1) end
						end
						if to > h[i] and to <= limit and to - orig[i] <= rise then
							h[i] = to
							phase[i] = phase[i] or 2
							changed = true
						end
					end
				end
				passes = passes + 1
				if not changed then break end
			end
			local bad = {}
			for _, i in ipairs(order) do
				if h[i] > base[i] then
					for _, n in ipairs(nbr[i]) do
						local drop = h[i] - h[n]
						if drop >= 2 and drop > base[i] - base[n] then bad[#bad + 1] = i break end
					end
				end
			end
			if #bad == 0 then break end
			for _, i in ipairs(bad) do
				h[i], held[i] = base[i], true
				if phase[i] == 2 then phase[i] = nil end
			end
		end
	end

	-- Drop what is over a limit: pieces of changed columns, smallest volume first.
	local function changed_at(i) return h[i] ~= orig[i] or kind[i] == "lava" end
	local pieces, seen = {}, {}
	for z = z0, z1 do
		for x = x0, x1 do
			local i = index(x, z)
			if h[i] and not seen[i] and changed_at(i) then
				local members, volume = {i}, 0
				seen[i] = true
				local k = 1
				while k <= #members do
					local m = members[k]
					k = k + 1
					volume = volume + (h[m] - orig[m]) + (kind[m] == "lava" and 1 or 0)
					for _, n in ipairs(nbr[m]) do
						if not seen[n] and changed_at(n) then
							seen[n] = true
							members[#members + 1] = n
						end
					end
				end
				pieces[#pieces + 1] = {members = members, volume = volume}
			end
		end
	end
	table.sort(pieces, function(a, b)
		if a.volume ~= b.volume then return a.volume < b.volume end
		return a.members[1] < b.members[1]
	end)
	local nodes, dropped = 0, 0
	for _, piece in ipairs(pieces) do
		if #piece.members > config.max_columns or nodes + piece.volume > config.budget then
			for _, m in ipairs(piece.members) do
				h[m], phase[m] = orig[m], nil
				dropped = dropped + 1
			end
		else
			nodes = nodes + piece.volume
		end
	end

	local result = {nodes = nodes, filled = 0, ramped = 0, dropped = dropped, passes = passes,
		cliffs_before = 0, cliffs_after = 0}
	local cells = {}
	for z = z0, z1 do
		for x = x0, x1 do
			local i = index(x, z)
			if h[i] then
				if changed_at(i) then
					cells[#cells + 1] = {x = x, z = z, from = orig[i], to = h[i], lava = kind[i] == "lava", name = names[i]}
					local which = phase[i] == 2 and "ramped" or "filled"
					result[which] = result[which] + 1
				end
				for _, d in ipairs({1, 3}) do
					local nx, nz = x + DX[d], z + DZ[d]
					local n = inside(nx, nz) and h[index(nx, nz)] and index(nx, nz)
					if n then
						if math.abs(orig[i] - orig[n]) > 1 then result.cliffs_before = result.cliffs_before + 1 end
						if math.abs(h[i] - h[n]) > 1 then result.cliffs_after = result.cliffs_after + 1 end
					end
				end
			end
		end
	end
	result.cells = cells
	result.at = function(x, z) return inside(x, z) and h[index(x, z)] or nil end
	return result
end

-- Decorations stand on the ground and are not ground: plants, flowers, a layer of
-- snow. Groups first, then a few name words for plants that lack them.
local DECOR_WORDS = {"grass", "fern", "flower", "bush", "sapling", "mushroom"}
local function is_decor(name, engine)
	if name == "air" or name == "ignore" then return false end
	local def = engine.registered_nodes[name]
	if not def or def.walkable or (def.liquidtype or "none") ~= "none" then return false end
	if name == "mcl_core:snow" then return true end
	if def.groups and (def.groups.plant or def.groups.flower or def.groups.flora) then return true end
	for _, word in ipairs(DECOR_WORDS) do
		if name:find(word, 1, true) then return true end
	end
	return false
end

-- A two-high plant is a bottom node `name` with a `name_top` above it (VoxeLibre's
-- add_large_plant: tall grass, large fern, peony, rose bush, lilac, sunflower).
local function top_name(name, engine)
	local top = name .. "_top"
	if engine.registered_nodes[top] then return top end
end
local function is_top_half(name, engine)
	return name:sub(-4) == "_top" and engine.registered_nodes[name:sub(1, -5)] ~= nil
end

-- A walkable node that is not a full block, such as a layer of snow or a path: it
-- would stay as a sliver inside new fill.
local function partial(name, engine)
	local def = engine.registered_nodes[name]
	return def ~= nil and def.walkable ~= false and (def.drawtype or "normal") ~= "normal"
		and def.drawtype ~= "allfaces"
end

-- Writes the cells of a plan. `material(x, z)` gives the surface node and the fill
-- under it. A fill goes all the way down to the old ground. What stood on the old
-- ground (grass, a flower, a layer of snow, a two-high plant with both halves) is put
-- back on the new surface, and whatever is left over it is cleared. A sliver of ground, such as
-- a layer of snow, is replaced by the fill. A lava column also has the lava under
-- it replaced.
function M.apply(plan, material, config, engine)
	engine = engine or core
	for _, cell in ipairs(plan.cells) do
		local surface, fill = material(cell.x, cell.z)
		local decor, decor_top
		if not cell.lava then
			local above = engine.get_node({x = cell.x, y = cell.from + 1, z = cell.z})
			if is_decor(above.name, engine) and not is_top_half(above.name, engine) then
				local top = top_name(above.name, engine)
				if not top then
					decor = above
				else
					local up = engine.get_node({x = cell.x, y = cell.from + 2, z = cell.z})
					if up.name == top then decor, decor_top = above, up end
				end
			end
		end
		local bottom = cell.lava and cell.from or cell.from + 1
		if not cell.lava and cell.name and partial(cell.name, engine) then bottom = cell.from end
		for y = bottom, cell.to - 1 do
			engine.swap_node({x = cell.x, y = y, z = cell.z}, {name = fill})
		end
		engine.swap_node({x = cell.x, y = cell.to, z = cell.z}, {name = surface})
		if cell.lava then terrain.fill_below(cell.x, cell.z, bottom, fill, engine) end
		-- What may still stand over the new surface: the upper half of a tall plant.
		for y = cell.to + 1, cell.to + 3 do
			local p = {x = cell.x, y = y, z = cell.z}
			if is_decor(engine.get_node(p).name, engine) then engine.swap_node(p, {name = "air"}) end
		end
		if decor then
			engine.swap_node({x = cell.x, y = cell.to + 1, z = cell.z}, decor)
			if decor_top then engine.swap_node({x = cell.x, y = cell.to + 2, z = cell.z}, decor_top) end
		end
	end
end

-- The box read and written: the pads' bounding box and `margin` around it, from
-- `below` under the lowest pad to `above` over the highest.
function M.area(pads, config)
	config = config or M.config
	local area
	for _, p in ipairs(pads) do
		local box = {
			minp = {x = p.yx0 - config.margin, y = p.y - config.below, z = p.yz0 - config.margin},
			maxp = {x = p.yx1 + config.margin, y = p.y + config.above, z = p.yz1 + config.margin},
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

local function is_ice(name)
	return name:find(":ice$") ~= nil or name:find("_ice$") ~= nil or name:find("frosted_ice", 1, true) ~= nil
end
M.is_ice = is_ice

-- Fills the holes in the area (from M.area) of a village whose pads (see
-- village_smoothing.pads) are placed. The blocks must be loaded; columns in an
-- unloaded one are skipped. `env` has settlements.surface_mat, engine and, optionally,
-- scan (village_fragments.scan_structures over an area). Returns the plan, or nil
-- and a reason.
function M.run(pads, area, env, config)
	local engine = env.engine
	config = config or M.configured(engine)
	local lookup, reason = terrain.heights(area, env.settlements.surface_mat, engine, true)
	if not lookup then return nil, reason end
	local structures = env.scan and env.scan(area)
	local m, ring = config.structure_margin, config.ring
	local function in_yard(x, z, p, extra)
		return x >= p.yx0 - extra and x <= p.yx1 + extra and z >= p.yz0 - extra and z <= p.yz1 + extra
	end
	local plan = M.plan({
		x0 = area.minp.x, z0 = area.minp.z, x1 = area.maxp.x, z1 = area.maxp.z,
		column = function(x, z)
			-- Blocks unloaded under the ground don't matter, only ground we can't see.
			local c = lookup(x, z, true)
			if not c or c.ground_unknown or (c.unloaded and not c.ground_y) then return nil end
			-- The ground, not what grows out of it: a trunk or a cactus is no peak.
			-- A shaft deeper than the area has no ground in it: treat the bottom as the floor.
			local name = c.base_name
			return {
				y = c.base_y or area.minp.y - 1,
				-- Ice over a pond is water to us.
				liquid = c.base_liquid or (name ~= nil and is_ice(name)) or false,
				lava = c.base_liquid and name:find("lava", 1, true) ~= nil or false,
				name = name,
			}
		end,
		near = function(x, z)
			for _, p in ipairs(pads) do
				if in_yard(x, z, p, config.reach) then return true end
			end
			return false
		end,
		protected = function(x, z)
			for _, p in ipairs(pads) do
				if in_yard(x, z, p, 0) then return true end
			end
			return structures and structures.find(x - m, z - m, x + m, z + m) ~= nil or false
		end,
		-- The ring around a yard: no higher than the building's floor.
		ceiling = function(x, z)
			local top
			for _, p in ipairs(pads) do
				if in_yard(x, z, p, ring) and (not top or p.y < top) then top = p.y end
			end
			return top
		end,
	}, config)
	M.apply(plan, function(x, z)
		-- The village's material, from the pad nearest the column.
		local best, best_d = nil, math.huge
		for _, p in ipairs(pads) do
			local d = math.max(p.x0 - x, 0, x - p.x1) ^ 2 + math.max(p.z0 - z, 0, z - p.z1) ^ 2
			if d < best_d then best, best_d = p, d end
		end
		return terrain.materials(best and best.surface)
	end, config, engine)
	return plan
end

return M
