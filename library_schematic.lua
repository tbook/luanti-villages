-- Furnish newly generated libraries with a lectern (#152). The stock library
-- has bookshelves but no jobsite, so no villager could ever become a librarian.
-- Like tavern_schematic.lua, this edits the stock schematic in memory so there
-- is no checked-in copy to fall out of sync with VoxeLibre.
--
-- The stock library is a 12 x 9 x 12 hall whose interior floor is at y 2. Its
-- bookshelves line the z 6 and z 9 walls and the middle rows (z 7 to 8) are
-- open floor. The lectern takes the centre of that floor, clear of the doors
-- at (10, 2, 5) and (2, 2, 7) and with open floor on all four sides.
local core = minetest

local function index(size, x, y, z)
	return z * size.y * size.x + y * size.x + x + 1
end

local function furnish(schematic)
	local size = schematic.size
	if size.x ~= 12 or size.y ~= 9 or size.z ~= 12 then return false end
	local x, y, z = 6, 2, 8
	-- The cell above stays air too, so the lectern's book has room.
	for _, dy in ipairs({0, 1}) do
		local cell = schematic.data[index(size, x, y + dy, z)]
		if not cell or cell.name ~= "air" then return false end
	end
	schematic.data[index(size, x, y, z)] = {name = "mcl_lectern:lectern", prob = 255, param2 = 0}
	return true
end

if not settlements or not settlements.schematic_table then return furnish end

for _, building in ipairs(settlements.schematic_table) do
	if building.name == "library" then
		local serialized = core.serialize_schematic(building.mts, "lua", {
			lua_use_comments = false, lua_num_indent_spaces = 0,
		})
		local schematic = serialized and loadstring(serialized .. " return schematic")()
		if schematic and furnish(schematic) then
			building.mts = schematic
		else
			core.log("warning", "[living_villages] stock library layout changed; lectern was not added")
		end
		break
	end
end

return furnish
