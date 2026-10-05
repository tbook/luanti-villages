-- Pure metric functions for the village probe (#144): no engine access, so
-- tests/lv_probe_metrics.lua can run them on made-up villages. init.lua feeds
-- them the ground heights it reads from the map.
--
-- A "ground map" is {[x] = {[z] = y}} holding the height of the topmost
-- walkable node in a column, ignoring trees; unknown columns are nil.
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
	local seen, columns, regions = {}, 0, 0
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
				end
			end
		end
	end
	return {columns = columns, regions = regions}
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
