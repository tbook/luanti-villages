minetest = {}
local furnish = dofile("tavern_schematic.lua")

local size = {x = 12, y = 13, z = 10}
local data = {}
for i = 1, size.x * size.y * size.z do data[i] = {name = "air"} end
local function cell(x, y, z)
	return data[z * size.y * size.x + y * size.x + x + 1]
end
local function set(x, y, z, name)
	cell(x, y, z).name = name
end
set(7, 2, 2, "mcl_jukebox:jukebox")
set(4, 2, 3, "mcl_fences:fence")
set(5, 2, 7, "mcl_fences:fence")
set(4, 3, 3, "mesecons_pressureplates:pressure_plate_wood_off")
set(5, 3, 7, "mesecons_pressureplates:pressure_plate_wood_off")
for _, seat in ipairs({{4, 2}, {4, 4}, {4, 7}, {6, 7}}) do
	set(seat[1], 2, seat[2], "mcl_stairs:stair_wood")
end

local schematic = {size = size, data = data}
assert(furnish(schematic))
assert(cell(7, 2, 2).name == "mcl_jukebox:jukebox", "existing jukebox must remain")
assert(cell(4, 2, 3).name == "mcl_decor:table_wooden")
assert(cell(5, 2, 7).name == "mcl_decor:table_wooden")
-- Two tables, each two long with a plate on every table node (#20).
for _, spot in ipairs({{4, 3}, {5, 3}, {5, 6}, {5, 7}}) do
	assert(cell(spot[1], 2, spot[2]).name == "mcl_decor:table_wooden")
	local plate = cell(spot[1], 3, spot[2])
	assert(plate.name == "mcl_itemframes:plate" and plate.param2 == 1)
end
-- The sitter faces away from the backrest, which is on +z at param2 0
-- (mcl_decor tpl_chair); every seat must face a table.
local facing = {[0] = {0, -1}, [1] = {-1, 0}, [2] = {0, 1}, [3] = {1, 0}}
local seats = {{4, 2}, {4, 4}, {5, 2}, {5, 4}, {4, 6}, {4, 7}, {6, 6}, {6, 7}}
for _, seat in ipairs(seats) do
	local chair = cell(seat[1], 2, seat[2])
	assert(chair.name == "mcl_decor:chair_wooden")
	local d = facing[chair.param2]
	assert(cell(seat[1] + d[1], 2, seat[2] + d[2]).name == "mcl_decor:table_wooden",
		("chair at %d,%d faces away from its table"):format(seat[1], seat[2]))
end
-- The door aisle and the floor before the jukebox stay walkable.
for x = 4, 7 do assert(cell(x, 2, 5).name == "air", "door aisle blocked at x " .. x) end
for _, spot in ipairs({{6, 2}, {6, 3}, {7, 3}}) do
	assert(cell(spot[1], 2, spot[2]).name == "air", "keeper floor blocked")
end
assert(not furnish(schematic), "already furnished tavern must not be transformed twice")
set(4, 2, 3, "mcl_fences:fence")
set(5, 2, 7, "mcl_fences:fence")
set(4, 3, 3, "mesecons_pressureplates:pressure_plate_wood_off")
set(5, 3, 7, "mesecons_pressureplates:pressure_plate_wood_off")
for _, seat in ipairs({{4, 2}, {4, 4}, {4, 7}, {6, 7}}) do
	set(seat[1], 2, seat[2], "mcl_stairs:stair_wood")
end
for _, spot in ipairs({{5, 2, 3}, {5, 3, 3}, {5, 2, 2}, {5, 2, 4}, {5, 2, 6}, {5, 3, 6}, {4, 2, 6}, {6, 2, 6}}) do
	set(spot[1], spot[2], spot[3], "air")
end
minetest.get_modpath = function() return "/test/villages" end
minetest.serialize_schematic = function() return "fixture" end
minetest.register_lbm = function() end
loadstring = function() return function() return schematic end end
settlements = {schematic_table = {{name = "tavern", mts = "stock.mts"}}}
dofile("tavern_schematic.lua")
assert(settlements.schematic_table[1].mts == schematic,
	"generator must receive the furnished in-memory schematic table, not a stale checked-in file")
assert(type(settlements.schematic_table[1].mts) == "table")
print("tavern schematic tests passed")
