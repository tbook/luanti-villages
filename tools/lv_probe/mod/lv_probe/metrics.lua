-- Pure metric functions for the village probe (#144): no engine access, so
-- tests/lv_probe_metrics.lua can run them on made-up villages. init.lua feeds
-- them the ground heights it reads from the map.
--
-- A "ground map" is {[x] = {[z] = y}} holding the height of the topmost
-- walkable node in a column, ignoring trees; unknown columns are nil. Where
-- that node is only the top of an overhang slab, init.lua keeps two maps: the
-- raw one (the slab top) and the corrected one (the ground under the slab,
-- see levels and resolve, #219). Every function here takes either.
local M = {}

-- Two buildings count as neighbors when their positions are this close in x/z.
-- The largest hsize in the schematic table is 15, so every pair the plan
-- placed next to each other (check_distance keeps them hsize apart) is inside.
M.NEIGHBOR_DISTANCE = 30

-- The footprint a building covers, as terraform.lua sizes it: pos is the
-- corner, and a quarter turn swaps width and depth.
function M.footprint(building, schematic_table)
	local schem
	for _, entry in ipairs(schematic_table) do
		if entry.name == building.name then schem = entry break end
	end
	if not schem then return nil end
	local width, depth = schem.hwidth, schem.hdepth
	if building.rotat == "90" or building.rotat == "270" then width, depth = depth, width end
	return {x1 = building.pos.x, z1 = building.pos.z,
		x2 = building.pos.x + width - 1, z2 = building.pos.z + depth - 1}
end

function M.building_counts(info)
	local counts = {}
	for _, building in ipairs(info) do counts[building.name] = (counts[building.name] or 0) + 1 end
	return counts
end

-- Spread of the floor heights, and the biggest height difference between two
-- buildings that stand next to each other.
function M.floor_heights(info)
	local low, high, neighbor_diff = math.huge, -math.huge, 0
	for i, a in ipairs(info) do
		low, high = math.min(low, a.pos.y), math.max(high, a.pos.y)
		for j = i + 1, #info do
			local b = info[j]
			if math.sqrt((a.pos.x - b.pos.x) ^ 2 + (a.pos.z - b.pos.z) ^ 2) <= M.NEIGHBOR_DISTANCE then
				neighbor_diff = math.max(neighbor_diff, math.abs(a.pos.y - b.pos.y))
			end
		end
	end
	if #info == 0 then return nil end
	return {min = low, max = high, range = high - low, neighbor_diff = neighbor_diff}
end

-- Probe node kinds (init.lua kind_of) that count as solid when judging an
-- overhang, as village_terrain.heights does: any solid or liquid node.
local SOLID = {ground = true, leaves = true, trunk = true, water = true, ignore = true}

-- The heights a column might be walked at, top first: its topmost walkable
-- node at `top`, then, while the node above is the top of an overhang slab
-- (`is_overhang`, the mod's village_terrain.is_overhang: a solid run of at most
-- 6 over at least 4 air), the topmost walkable node under that slab, and so on
-- for a slab on a slab. `kind(y)` is the probe's node kind at y; `ymin` the
-- lowest y scanned. A slab with no ground under it inside the scan contributes
-- nothing, so a column that is only such a slab has no levels. A column with
-- one level is not under a slab.
function M.levels(top, ymin, kind, is_overhang)
	local function class(y)
		local k = kind(y)
		return SOLID[k] and "solid" or k == "air" and "air" or "other"
	end
	local levels, y = {}, top
	while true do
		if not is_overhang(y, class, ymin) then
			levels[#levels + 1] = y
			return levels
		end
		local under = y
		while under >= ymin and class(under) == "solid" do under = under - 1 end
		local wet = false
		while under >= ymin and kind(under) ~= "ground" do
			wet = wet or kind(under) == "water"
			under = under - 1
		end
		if under < ymin then return levels end
		-- A bed under water is not somewhere to walk: the slab stays the ground.
		if wet then
			levels[#levels + 1] = y
			return levels
		end
		levels[#levels + 1] = y
		y = under
	end
end

-- Which level of each column is its ground (#219). The mod's overhang rule alone
-- also matches the roof of a cave or ledge that villagers do walk on, and
-- skipping that makes a hollow of the ground around it. So a column with
-- several levels takes the one nearest the ground of the columns around it
-- (columns with one level, within RESOLVE_RADII in turn, at least 3 of them),
-- else nearest `ref`, the village's floor height; a tie keeps the higher.
-- `levels` is {[x] = {[z] = list from M.levels}}. Returns the ground map and the
-- number of columns that took a level other than the top, and a table of how the
-- ambiguous columns (several levels) were decided: `by_radius[r]` decided by the
-- ground within r, `by_ref` by `ref` because fewer than 3 columns without a slab
-- lay within the widest radius, `undecided` with no ref either (the top is kept).
M.RESOLVE_RADII = {2, 4, 6, 10}
function M.resolve(levels, ref)
	local ground, lowered = {}, 0
	local how = {by_radius = {}, by_ref = 0, undecided = 0}
	for _, r in ipairs(M.RESOLVE_RADII) do how.by_radius["r" .. r] = 0 end
	local function certain(x, z)
		local column = levels[x] and levels[x][z]
		return column and #column == 1 and column[1] or nil
	end
	for x, column in pairs(levels) do
		ground[x] = {}
		for z, list in pairs(column) do
			local choice = list[1]
			if #list > 1 then
				local target = ref
				local radius
				for _, r in ipairs(M.RESOLVE_RADII) do
					local around = {}
					for dx = -r, r do
						for dz = -r, r do
							local y = certain(x + dx, z + dz)
							if y then around[#around + 1] = y end
						end
					end
					if #around >= 3 then
						table.sort(around)
						target, radius = around[math.ceil(#around / 2)], r
						break
					end
				end
				if radius then how.by_radius["r" .. radius] = how.by_radius["r" .. radius] + 1
				elseif target then how.by_ref = how.by_ref + 1
				else how.undecided = how.undecided + 1 end
				if target then
					for _, y in ipairs(list) do
						if math.abs(y - target) < math.abs(choice - target) then choice = y end
					end
				end
			end
			ground[x][z] = choice -- nil for a column that is only a slab over the void
			if choice and choice ~= list[1] then lowered = lowered + 1 end
		end
	end
	return ground, lowered, how
end

-- The mod's rule applied alone: every column takes its lowest level. Kept as
-- `*_literal` fields to show how much of a correction is the rule and how much
-- is `resolve`'s choice.
function M.lowest(levels)
	local ground = {}
	for x, column in pairs(levels) do
		ground[x] = {}
		for z, list in pairs(column) do ground[x][z] = list[#list] end
	end
	return ground
end

-- The village's reference floor: the median building floor height.
function M.median_floor(info)
	local ys = {}
	for _, building in ipairs(info) do ys[#ys + 1] = building.pos.y end
	table.sort(ys)
	return ys[math.ceil(#ys / 2)]
end

local DIRECTIONS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

local function inside(footprints, x, z)
	for _, f in ipairs(footprints) do
		if x >= f.x1 and x <= f.x2 and z >= f.z1 and z <= f.z2 then return true end
	end
	return false
end
M.inside = inside

local function get(map, x, z)
	local column = map[x]
	return column and column[z]
end

-- Largest height difference between adjacent columns, and how many pairs differ
-- by more than one block (a villager's jump), ignoring pairs that touch a
-- building footprint: the building's own steps and floor are not terrain.
function M.steps(ground, footprints)
	local largest, over_one, at = 0, 0, nil
	for x, column in pairs(ground) do
		for z, y in pairs(column) do
			if not inside(footprints, x, z) then
				for d = 1, 2 do -- +x and +z only, so each pair counts once
					local dir = DIRECTIONS[d == 1 and 1 or 3]
					local nx, nz = x + dir[1], z + dir[2]
					local other = get(ground, nx, nz)
					if other and not inside(footprints, nx, nz) then
						local step = math.abs(other - y)
						if step > largest then largest, at = step, {x = x, z = z} end
						if step > 1 then over_one = over_one + 1 end
					end
				end
			end
		end
	end
	return {largest = largest, over_one = over_one, largest_at = at}
end

-- Deepest pit: how far a column lies below the lowest of the four columns
-- RING away. A ravine or cave mouth shows as a deep pit, a plain slope does not.
M.PIT_RING = 4
function M.pit_depth(ground)
	local deepest, at = 0, nil
	local ring = M.PIT_RING
	for x, column in pairs(ground) do
		for z, y in pairs(column) do
			local low = math.huge
			for _, dir in ipairs(DIRECTIONS) do
				local other = get(ground, x + dir[1] * ring, z + dir[2] * ring)
				if not other then low = nil break end
				low = math.min(low, other)
			end
			if low and low - y > deepest then deepest, at = low - y, {x = x, z = z} end
		end
	end
	return deepest, at
end

-- Columns a villager cannot leave: those from which no walk reaches the
-- anchor, walking up at most one block per step and down any distance.
-- Footprint columns are passable at the building's floor height. Wet columns
-- (water over the ground) are skipped. Returns the number of trapped columns
-- that lie in a basin, meaning their unreachable region does not touch the
-- edge of the mapped area, and the number of such regions.
function M.traps(ground, wet, footprints, floors, anchor)
	local function height(x, z)
		if wet[x .. "," .. z] then return nil end
		if inside(footprints, x, z) then return floors[x .. "," .. z] end
		return get(ground, x, z)
	end
	-- Walk backwards from the anchor: u reaches v when height(v) <= height(u) + 1.
	local reaches = {[anchor.x .. "," .. anchor.z] = true}
	local queue, head = {{anchor.x, anchor.z}}, 1
	while head <= #queue do
		local v = queue[head]
		head = head + 1
		local hv = height(v[1], v[2])
		for _, dir in ipairs(DIRECTIONS) do
			local ux, uz = v[1] + dir[1], v[2] + dir[2]
			local key = ux .. "," .. uz
			local hu = not reaches[key] and height(ux, uz)
			if hu and hv <= hu + 1 then
				reaches[key] = true
				queue[#queue + 1] = {ux, uz}
			end
		end
	end
	-- Group the unreachable columns into regions.
	local seen, columns, regions, samples = {}, 0, 0, {}
	for x, column in pairs(ground) do
		for z in pairs(column) do
			local key = x .. "," .. z
			if not reaches[key] and not seen[key] and height(x, z) then
				local region, border = {{x, z}}, false
				seen[key] = true
				local i = 1
				while i <= #region do
					local cx, cz = region[i][1], region[i][2]
					i = i + 1
					for _, dir in ipairs(DIRECTIONS) do
						local nx, nz = cx + dir[1], cz + dir[2]
						local nkey = nx .. "," .. nz
						if get(ground, nx, nz) == nil then
							border = true
						elseif not reaches[nkey] and not seen[nkey] and height(nx, nz) then
							seen[nkey] = true
							region[#region + 1] = {nx, nz}
						end
					end
				end
				if not border then
					columns, regions = columns + #region, regions + 1
					if #samples < 8 then samples[#samples + 1] = {x = x, z = z, size = #region} end
				end
			end
		end
	end
	return {columns = columns, regions = regions, samples = samples}
end

-- How far each footprint's floor sits above (fill) or below (cut) the natural
-- ground under it, over all columns of all buildings: the tallest fill is a
-- village on a tower, the deepest cut a house dug into a hillside.
function M.fill_and_cut(info, footprints, natural)
	local fill, cut = 0, 0
	for i, building in ipairs(info) do
		local f = footprints[i]
		if f then
			for x = f.x1, f.x2 do
				for z = f.z1, f.z2 do
					local y = get(natural, x, z)
					if y then
						fill = math.max(fill, building.pos.y - y)
						cut = math.max(cut, y - building.pos.y)
					end
				end
			end
		end
	end
	return {fill = fill, cut = cut}
end

-- Ground height spread over the area.
function M.height_range(ground)
	local low, high = math.huge, -math.huge
	for _, column in pairs(ground) do
		for _, y in pairs(column) do low, high = math.min(low, y), math.max(high, y) end
	end
	if low == math.huge then return nil end
	return {min = low, max = high, range = high - low}
end

return M
