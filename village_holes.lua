-- Fills deep holes inside a village (#142, part of #133). #139 rejects whole sites
-- and #140 smooths only around buildings, so a pit or a cave-mouth shaft in a gap
-- between buildings is left. A villager that drops in cannot climb the 2-block
-- rise out (the planner's 1-block step rule), and is stuck.
--
-- A hole is a connected group of dry columns from which no walk reaches a
-- building, the edge of the area or ground we can't see, climbing at most one block
-- per step and descending any distance. A shallow one (depth at most `shallow`
-- below its lowest rim) is filled up to the rim. A deeper one gets a lid three
-- blocks thick at rim level, and the cavity under it stays: dirt does not fall,
-- and that avoids filling a 30-block shaft. Surface lava is a hole of its own.
-- Water is never touched, and neither is a hole that holds any.
--
-- plan() is pure, so it is tested without the engine. Loading this has no side
-- effects. Run it after village_smoothing's ground work and before the paths.
local core = minetest
local terrain = dofile(core.get_modpath("living_villages") .. "/village_terrain.lua")

local M = {}

M.config = {
	margin = 12, -- the area is the plan's bounding box plus this, a little past the smoothing reach
	below = 40, above = 24, -- under the lowest pad, over the highest
	shallow = 3, -- a hole up to this deep is filled, a deeper one is capped
	lid = 3, -- thickness of a cap
	passes = 4, -- limit on plan rounds: raising ground can leave a pocket behind
	structure_margin = 1, -- structures and the ground just around them are left alone
}

local DIRECTIONS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

-- The pure half. spec:
--   x0, z0, x1, z1  the box of columns
--   column(x, z)    {y = top height, liquid = bool, lava = bool}, nil if unknown
--   protected(x, z) true for columns that must not change (pads, structures); they
--                   count as ways out
-- Returns {cells = {{x, z, from, to, cap, lava}...} (columns to raise from `from`
-- to `to`), regions, capped, filled, skipped (holes with water in them), left
-- (columns still trapped), at(x, z) = height afterward}.
function M.plan(spec, config)
	config = config or M.config
	local x0, z0, x1, z1 = spec.x0, spec.z0, spec.x1, spec.z1
	local width = x1 - x0 + 1
	local function index(x, z) return (z - z0) * width + (x - x0) + 1 end
	local function inside(x, z) return x >= x0 and x <= x1 and z >= z0 and z <= z1 end

	local h, kind, fixed = {}, {}, {}
	for z = z0, z1 do
		for x = x0, x1 do
			local c = spec.column(x, z)
			if c then
				local i = index(x, z)
				h[i] = c.y
				kind[i] = c.lava and "lava" or c.liquid and "water" or "dry"
				fixed[i] = spec.protected and spec.protected(x, z) or false
			end
		end
	end
	local was = {}
	for i, y in pairs(h) do was[i] = y end

	local changes, order = {}, {}
	local result = {regions = 0, capped = 0, filled = 0, skipped = 0, left = 0}
	for _ = 1, config.passes do
		-- Walk backwards from the ways out: u reaches v when h(v) <= h(u) + 1.
		local reached, queue, head = {}, {}, 1
		for z = z0, z1 do
			for x = x0, x1 do
				local i = index(x, z)
				if h[i] and kind[i] ~= "lava" then
					local out = fixed[i] or x == x0 or x == x1 or z == z0 or z == z1
					for _, d in ipairs(DIRECTIONS) do
						-- Next to ground we can't see: leave it to chance.
						if not out and inside(x + d[1], z + d[2]) and not h[index(x + d[1], z + d[2])] then out = true end
					end
					if out then reached[i] = true; queue[#queue + 1] = {x, z} end
				end
			end
		end
		while head <= #queue do
			local x, z = queue[head][1], queue[head][2]
			head = head + 1
			local hv = h[index(x, z)]
			for _, d in ipairs(DIRECTIONS) do
				local ux, uz = x + d[1], z + d[2]
				if inside(ux, uz) then
					local u = index(ux, uz)
					if h[u] and kind[u] ~= "lava" and not reached[u] and hv <= h[u] + 1 then
						reached[u] = true
						queue[#queue + 1] = {ux, uz}
					end
				end
			end
		end

		-- Group what is left into regions and deal with each.
		local seen, raised = {}, false
		result.left = 0
		for z = z0, z1 do
			for x = x0, x1 do
				local i = index(x, z)
				if h[i] and not reached[i] and not seen[i] then
					local members, water, rim, low = {{x, z}}, false, math.huge, math.huge
					seen[i] = true
					local n = 1
					while n <= #members do
						local cx, cz = members[n][1], members[n][2]
						n = n + 1
						local ci = index(cx, cz)
						water = water or kind[ci] == "water"
						low = math.min(low, h[ci])
						for _, d in ipairs(DIRECTIONS) do
							local nx, nz = cx + d[1], cz + d[2]
							local ni = inside(nx, nz) and index(nx, nz)
							if ni and h[ni] then
								if reached[ni] then
									rim = math.min(rim, h[ni])
								elseif not seen[ni] then
									seen[ni] = true
									members[#members + 1] = {nx, nz}
								end
							end
						end
					end
					result.regions = result.regions + 1
					if water or rim == math.huge then
						result.skipped = result.skipped + (water and 1 or 0)
						result.left = result.left + #members
					else
						local cap = rim - low > config.shallow
						result[cap and "capped" or "filled"] = result[cap and "capped" or "filled"] + 1
						for _, m in ipairs(members) do
							local mi = index(m[1], m[2])
							local lava = kind[mi] == "lava"
							local to = lava and math.max(rim, h[mi]) or rim
							if (lava or h[mi] < to) and not fixed[mi] then
								local change = changes[mi]
								if not change then
									change = {x = m[1], z = m[2], from = was[mi], lava = lava}
									changes[mi] = change
									order[#order + 1] = change
								end
								change.to = to
								change.cap = change.cap or (cap and not lava)
								h[mi] = to
								-- A lava column becomes ground; it is no longer lava.
								kind[mi] = "dry"
								raised = true
							end
						end
					end
				end
			end
		end
		if not raised then break end
	end

	result.cells = order
	result.at = function(x, z) return inside(x, z) and h[index(x, z)] or nil end
	return result
end

-- Writes the cells of a plan. `material(x, z)` gives the surface node and the fill
-- under it. A cap runs only `lid` blocks down from its top; a fill goes all the
-- way to the old ground. A lava column also has the lava under it replaced.
function M.apply(plan, material, config, engine)
	config = config or M.config
	engine = engine or core
	for _, cell in ipairs(plan.cells) do
		local surface, fill = material(cell.x, cell.z)
		local bottom = cell.lava and cell.from or cell.from + 1
		if cell.cap then bottom = math.max(bottom, cell.to - config.lid + 1) end
		for y = bottom, cell.to - 1 do
			engine.swap_node({x = cell.x, y = y, z = cell.z}, {name = fill})
		end
		engine.swap_node({x = cell.x, y = cell.to, z = cell.z}, {name = surface})
		if cell.lava then terrain.fill_below(cell.x, cell.z, bottom, fill, engine) end
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

-- Fills the holes in the area (from M.area) of a village whose pads (see
-- village_smoothing.pads) are placed. The blocks must be loaded; columns in an
-- unloaded one are skipped. `env` has settlements.surface_mat, engine and, optionally,
-- scan (village_fragments.scan_structures over an area). Returns the plan, or nil
-- and a reason.
function M.run(pads, area, env, config)
	config = config or M.config
	local engine = env.engine
	local lookup, reason = terrain.heights(area, env.settlements.surface_mat, engine, true)
	if not lookup then return nil, reason end
	local structures = env.scan and env.scan(area)
	local m = config.structure_margin
	local function pad_of(x, z)
		for n, p in ipairs(pads) do
			if x >= p.yx0 and x <= p.yx1 and z >= p.yz0 and z <= p.yz1 then return n end
		end
	end
	local plan = M.plan({
		x0 = area.minp.x, z0 = area.minp.z, x1 = area.maxp.x, z1 = area.maxp.z,
		column = function(x, z)
			local c = lookup(x, z)
			if not c then return nil end
			-- A shaft deeper than the area has no ground in it: treat the bottom as the floor.
			return {
				y = c.ground_y or area.minp.y - 1,
				liquid = c.ground_liquid or false,
				lava = c.ground_liquid and c.ground_name:find("lava", 1, true) ~= nil or false,
			}
		end,
		protected = function(x, z)
			return pad_of(x, z) ~= nil or (structures and structures.find(x - m, z - m, x + m, z + m) ~= nil) or false
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
