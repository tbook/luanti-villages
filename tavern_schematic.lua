-- Furnish only newly generated taverns. Re-derive the furnished layout from
-- the stock schematic every time rather than swapping in a checked-in .mts:
-- the placement code accepts an in-memory schematic table just as well as a
-- filename (mcl_structures.place_schematic re-serializes either the same
-- way), so there is no stale copy to fall out of sync if VoxeLibre changes
-- the stock tavern layout in some other cell.
local core = minetest
local unpack = table.unpack or unpack

local function index(size, x, y, z)
	return z * size.y * size.x + y * size.x + x + 1
end

-- The facedir param2 that seats someone facing the given direction. The
-- chair's backrest sits on its +z side at param2 0 (mcl_decor
-- chairs_tables.lua tpl_chair), so the sitter faces -z; each param2 step
-- turns it a quarter clockwise seen from above (+z -> +x -> -z -> -x).
local CHAIR_FACING = {["-z"] = 0, ["-x"] = 1, ["+z"] = 2, ["+x"] = 3}

local function furnish(schematic)
	local size = schematic.size
	if size.x ~= 12 or size.y ~= 13 or size.z ~= 10 then return false end
	local function replace(x, y, z, expected, name, param2)
		local cell = schematic.data[index(size, x, y, z)]
		if not cell or cell.name ~= expected then return false end
		schematic.data[index(size, x, y, z)] = {name = name, prob = 255, param2 = param2 or 0}
		return true
	end
	-- The stock tavern has two fence-and-pressure-plate tables. Replace them
	-- with furniture so the plates have solid support and players can sit.
	local changes = {
		{4, 2, 3, "mcl_fences:fence", "mcl_decor:table_wooden", 0},
		{5, 2, 7, "mcl_fences:fence", "mcl_decor:table_wooden", 0},
		{4, 3, 3, "mesecons_pressureplates:pressure_plate_wood_off", "mcl_itemframes:plate", 1},
		{5, 3, 7, "mesecons_pressureplates:pressure_plate_wood_off", "mcl_itemframes:plate", 1},
		{4, 2, 2, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["+z"]},
		{4, 2, 4, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["-z"]},
		{4, 2, 7, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["+x"]},
		{6, 2, 7, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["-x"]},
	}
	for _, change in ipairs(changes) do
		local cell = schematic.data[index(size, change[1], change[2], change[3])]
		if not cell or cell.name ~= change[4] then return false end
	end
	for _, change in ipairs(changes) do
		replace(unpack(change))
	end
	return true
end

if not settlements or not settlements.schematic_table then return furnish end

for _, building in ipairs(settlements.schematic_table) do
	if building.name == "tavern" then
		local serialized = core.serialize_schematic(building.mts, "lua", {
			lua_use_comments = false, lua_num_indent_spaces = 0,
		})
		local schematic = serialized and loadstring(serialized .. " return schematic")()
		if schematic and furnish(schematic) then
			building.mts = schematic
		else
			core.log("warning", "[villages] stock tavern layout changed; furniture was not added")
		end
		break
	end
end

-- Schematic placement does not call the plate's on_construct callback.
core.register_lbm({
	name = "villages:initialize_tavern_plates",
	nodenames = {"mcl_itemframes:plate"},
	run_at_every_load = false,
	action = function(pos)
		local inventory = core.get_meta(pos):get_inventory()
		if inventory:get_size("main") ~= 0 then return end
		local definition = core.registered_nodes["mcl_itemframes:plate"]
		definition.on_construct(pos)
		mcl_itemframes.update_entity(pos)
	end,
})

return furnish
