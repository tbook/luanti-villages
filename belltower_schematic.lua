-- Raise newly generated belltowers one block (#150), the same way
-- tavern_schematic.lua and church_schematic.lua furnish theirs: edit the stock
-- schematic in memory so there is no checked-in copy to fall out of sync with
-- VoxeLibre.
--
-- The generator places a schematic with its bottom layer on the surface block
-- itself. The stock belltower's bottom layer is four stonebrick corner posts
-- round open air, so the tower digs a 5 by 5 pit one block deep: the bell hangs
-- three blocks over the pit floor but only two over the village's ground, and
-- looks sunk. A new bottom layer under the stock one fills the pit with the
-- surface material (the generator swaps dirt_with_grass for the site's own) and
-- raises the tower and its bell a block, so the floor is level with the ground.
local core = minetest

local SIZE = {x = 5, y = 6, z = 5}
local BELL = {x = 2, y = 3, z = 2}
local FLOOR = "mcl_core:dirt_with_grass"

local function index(size, x, y, z)
	return z * size.y * size.x + y * size.x + x + 1
end

local function furnish(schematic)
	local size = schematic.size
	if not size or size.x ~= SIZE.x or size.y ~= SIZE.y or size.z ~= SIZE.z then return false end
	local data = schematic.data
	local bell = data[index(size, BELL.x, BELL.y, BELL.z)]
	local post = data[index(size, 0, 0, 0)]
	if not bell or bell.name ~= "mcl_bells:bell" or not post or post.name ~= "mcl_core:stonebrick" then
		return false
	end
	local raised = {}
	for z = 0, size.z - 1 do
		for y = 0, size.y do
			for x = 0, size.x - 1 do
				local cell
				if y == 0 then
					-- The new bottom layer: a post under each post, floor elsewhere.
					local above = data[index(size, x, 0, z)]
					if above.name == "mcl_core:stonebrick" then
						cell = {name = above.name, prob = 255, param2 = 0}
					else
						cell = {name = FLOOR, prob = 255, param2 = 0}
					end
				else
					cell = data[index(size, x, y - 1, z)]
				end
				raised[index({x = size.x, y = size.y + 1, z = size.z}, x, y, z)] = cell
			end
		end
	end
	schematic.data = raised
	schematic.size = {x = size.x, y = size.y + 1, z = size.z}
	return true
end

if not settlements or not settlements.schematic_table then return furnish end

for _, building in ipairs(settlements.schematic_table) do
	if building.name == "belltower" then
		local serialized = core.serialize_schematic(building.mts, "lua", {
			lua_use_comments = false, lua_num_indent_spaces = 0,
		})
		local schematic = serialized and loadstring(serialized .. " return schematic")()
		if schematic and furnish(schematic) then
			building.mts = schematic
		else
			core.log("warning", "[living_villages] stock belltower layout changed; it was not raised")
		end
		break
	end
end

return furnish
