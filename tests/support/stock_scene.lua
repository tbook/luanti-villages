-- A stock building placed in the stub world for tests/stock_buildings.lua and
-- tests/stock_church.lua (#159): furnished as this mod furnishes it, on flat
-- ground that can be a road of grass path or have a one-block step all round,
-- with an outdoor bed beyond each side to route to.
local stock_world = dofile("tests/support/stock_world.lua")

local M = {
	DIRECTIONS = {"north", "south", "west", "east"},
	-- Where the building goes, and how far beyond each side the outdoor beds are.
	ORIGIN = 30,
	MARGIN = 7,
}
local ORIGIN, MARGIN = M.ORIGIN, M.MARGIN

-- Furnishing this mod gives newly generated buildings (#20, #21, #152), loaded
-- once the engine stubs are in. Each module returns its furnish function when
-- the village generator is absent. Not every branch has all of them.
local FURNISHERS = {
	tavern = "tavern_schematic.lua", church = "church_schematic.lua", library = "library_schematic.lua",
	belltower = "belltower_schematic.lua",
}

-- Returns {world, size, rise, prefix, beds, outdoors}. slope is 1 for a basin,
-- -1 for a plateau, nil for flat.
function M.build(name, rotation, doors_open, roads, slope)
	-- "small_house_loomless" is the small house furnished without its loom (#223).
	local fixture = dofile("tests/fixtures/buildings/" .. name:gsub("_loomless$", "") .. ".lua")
	local world = stock_world.new()
	stock_world.install(world)
	local furnish = {}
	for module, file in pairs(FURNISHERS) do
		local handle = io.open(file, "r")
		if handle then
			handle:close()
			furnish[module] = dofile(file)
		end
	end
	if name:find("_loomless$") then furnish.loomless = dofile("loomless_house.lua").remove_loom end
	local size = world.place(fixture, ORIGIN, ORIGIN, furnish, rotation)
	if doors_open then world.open_doors() end
	if roads then
		-- Village roads are grass path, a sixteenth lower than a full block: the
		-- ground all round the building, as a generated village lays it (#156).
		for x = ORIGIN - MARGIN - 4, ORIGIN + size.x + MARGIN + 4 do
			for z = ORIGIN - MARGIN - 4, ORIGIN + size.z + MARGIN + 4 do
				local inside = x >= ORIGIN and x < ORIGIN + size.x and z >= ORIGIN and z < ORIGIN + size.z
				if not inside then world.set({x = x, y = world.ground_y, z = z}, "mcl_core:grass_path") end
			end
		end
	end
	-- The ground beyond two cells of the building a block higher (+1: the building
	-- in a basin, the way in climbs a step) or lower (-1: on a plateau, the way
	-- in drops one). Every approach from outdoors crosses it.
	local rise = slope or 0
	if rise ~= 0 then
		for x = ORIGIN - MARGIN - 4, ORIGIN + size.x + MARGIN + 4 do
			for z = ORIGIN - MARGIN - 4, ORIGIN + size.z + MARGIN + 4 do
				local gap_x = math.max(ORIGIN - x, x - (ORIGIN + size.x - 1), 0)
				local gap_z = math.max(ORIGIN - z, z - (ORIGIN + size.z - 1), 0)
				if math.max(gap_x, gap_z) > 2 then
					if rise > 0 then
						world.set({x = x, y = world.ground_y + 1, z = z}, "mcl_core:dirt")
					else
						world.set({x = x, y = world.ground_y, z = z}, "air")
					end
				end
			end
		end
	end
	-- The step is there: the ground three cells out is not the building's.
	local ring_up = world.get({x = ORIGIN - 3, y = world.ground_y + 1, z = ORIGIN}).name == "mcl_core:dirt"
	local ring_down = world.get({x = ORIGIN - 3, y = world.ground_y, z = ORIGIN}).name == "air"
	assert(ring_up == (rise > 0) and ring_down == (rise < 0), "the ground step is missing or unwanted")
	local prefix = ("%s r%d%s%s%s"):format(name, rotation * 90, doors_open and "o" or "", roads and " roads" or "",
		rise > 0 and " slope up" or rise < 0 and " slope down" or "")

	-- Outdoor beds, one beyond each side, for a route out to end at; a villager
	-- stands two cells from each, as it would after walking up.
	local mid_x, mid_z = ORIGIN + math.floor(size.x / 2), ORIGIN + math.floor(size.z / 2)
	local beds = {
		north = world.add_bed(mid_x, ORIGIN - MARGIN, rise),
		south = world.add_bed(mid_x, ORIGIN + size.z + MARGIN, rise),
		west = world.add_bed(ORIGIN - MARGIN - 1, mid_z, rise),
		east = world.add_bed(ORIGIN + size.x + MARGIN, mid_z, rise),
	}
	local function outdoors(direction)
		local bed = beds[direction]
		return {x = bed.x, y = bed.y - 0.49, z = bed.z + 2}
	end
	return {world = world, size = size, rise = rise, prefix = prefix, beds = beds, outdoors = outdoors}
end

return M
