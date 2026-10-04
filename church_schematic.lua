-- Furnish only newly generated churches (#21), the same way tavern_schematic.lua
-- furnishes taverns: edit the stock schematic in memory so there is no checked-in
-- copy to fall out of sync with VoxeLibre.
--
-- The stock church holds a brewing stand, the cleric's jobsite and an odd
-- centrepiece, on a purple-carpeted dais at its east end, with an altar of two
-- wood blocks and white carpet (x 8, z 6 to 7) in front of it, and wooden stairs
-- as pews. The brewing stand goes, leaving carpet. A pulpit takes the carpet
-- beside the altar, on the congregation's left, and the pews become chairs that
-- face the altar. No profession claims a pulpit.
local core = minetest
local unpack = table.unpack or unpack

local function index(size, x, y, z)
	return z * size.y * size.x + y * size.x + x + 1
end

-- The facedir param2 that seats someone facing the given direction; see
-- tavern_schematic.lua.
local CHAIR_FACING = {["-z"] = 0, ["-x"] = 1, ["+z"] = 2, ["+x"] = 3}

-- The pulpit's mesh slopes its reading surface down toward -z at param2 0, so
-- the reader stands on that side and the congregation, who see the high edge,
-- on +z. Each param2 step turns +z a quarter toward +x, so a pulpit that faces
-- the pews to the west (-x) takes param2 3.
local PULPIT_PARAM2 = 3

local function furnish(schematic)
	local size = schematic.size
	if size.x ~= 13 or size.y ~= 15 or size.z ~= 14 then return false end
	-- The congregation looks east (+x), so its left is +z: the pulpit stands
	-- at z 8, beside the altar's z 7.
	local changes = {
		{10, 3, 6, "mcl_brewing:stand_000", "mcl_wool:purple_carpet", 0},
		{8, 3, 8, "mcl_wool:purple_carpet", "living_villages:pulpit", PULPIT_PARAM2},
	}
	-- Two columns of pews either side of the central aisle, three seats each,
	-- on both sides of the doorway at z 6 to 7.
	for _, x in ipairs({3, 5}) do
		for _, z in ipairs({3, 4, 5, 8, 9, 10}) do
			changes[#changes + 1] = {x, 2, z, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["+x"]}
		end
	end
	for _, change in ipairs(changes) do
		local cell = schematic.data[index(size, change[1], change[2], change[3])]
		if not cell or cell.name ~= change[4] then return false end
	end
	for _, change in ipairs(changes) do
		local x, y, z, _, name, param2 = unpack(change)
		schematic.data[index(size, x, y, z)] = {name = name, prob = 255, param2 = param2}
	end
	return true
end

if not settlements or not settlements.schematic_table then return furnish end

for _, building in ipairs(settlements.schematic_table) do
	if building.name == "church" then
		local serialized = core.serialize_schematic(building.mts, "lua", {
			lua_use_comments = false, lua_num_indent_spaces = 0,
		})
		local schematic = serialized and loadstring(serialized .. " return schematic")()
		if schematic and furnish(schematic) then
			building.mts = schematic
		else
			core.log("warning", "[living_villages] stock church layout changed; furniture was not added")
		end
		break
	end
end

return furnish
