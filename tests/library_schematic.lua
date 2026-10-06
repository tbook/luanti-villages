minetest = {}
local furnish = dofile("library_schematic.lua")

local size = {x = 12, y = 9, z = 12}
local data = {}
for i = 1, size.x * size.y * size.z do data[i] = {name = "air"} end
local function cell(x, y, z)
	return data[z * size.y * size.x + y * size.x + x + 1]
end

cell(6, 2, 9).name = "mcl_stairs:stair_wood"
local schematic = {size = size, data = data}
assert(furnish(schematic))
local lectern = cell(6, 2, 9)
assert(lectern.name == "mcl_lectern:lectern" and lectern.prob == 255)
assert(cell(6, 3, 9).name == "air", "lectern needs the cell above clear")
assert(cell(6, 2, 8).name == "air", "lectern must keep open floor in front of it")
assert(not furnish({size = {x = 13, y = 9, z = 12}, data = data}), "unknown layout must be left alone")
cell(6, 2, 9).name = "mcl_books:bookshelf"
assert(not furnish(schematic), "changed layout must not be overwritten")

cell(6, 2, 9).name = "mcl_stairs:stair_wood"
minetest.get_modpath = function() return "/test/villages" end
minetest.serialize_schematic = function() return "fixture" end
minetest.log = function() end
loadstring = function() return function() return schematic end end
settlements = {schematic_table = {{name = "library", mts = "stock.mts"}}}
dofile("library_schematic.lua")
assert(settlements.schematic_table[1].mts == schematic)
print("library schematic tests passed")
