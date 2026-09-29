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
assert(cell(4, 3, 3).name == "mcl_itemframes:plate" and cell(4, 3, 3).param2 == 1)
assert(cell(5, 3, 7).name == "mcl_itemframes:plate" and cell(5, 3, 7).param2 == 1)
for _, seat in ipairs({{4, 2}, {4, 4}, {4, 7}, {6, 7}}) do
	assert(cell(seat[1], 2, seat[2]).name == "mcl_decor:chair_wooden")
end
assert(not furnish(schematic), "already furnished tavern must not be transformed twice")
set(4, 2, 3, "mcl_fences:fence")
set(5, 2, 7, "mcl_fences:fence")
set(4, 3, 3, "mesecons_pressureplates:pressure_plate_wood_off")
set(5, 3, 7, "mesecons_pressureplates:pressure_plate_wood_off")
for _, seat in ipairs({{4, 2}, {4, 4}, {4, 7}, {6, 7}}) do
	set(seat[1], 2, seat[2], "mcl_stairs:stair_wood")
end
minetest.get_modpath = function() return "/test/villages" end
minetest.serialize_schematic = function() return "fixture" end
minetest.register_lbm = function() end
loadstring = function() return function() return schematic end end
settlements = {schematic_table = {{name = "tavern", mts = "stock.mts"}}}
dofile("tavern_schematic.lua")
assert(settlements.schematic_table[1].mts == "/test/villages/schematics/tavern_furnished.mts",
	"generator must receive a schematic filename")
print("tavern schematic tests passed")
