-- A building's ground layer takes the village's surface material (#151).
-- Every stock schematic starts with a slice of mcl_core:dirt at pos.y, the
-- surface row the building stands on. VoxeLibre swaps only the grass node for
-- the pad's surface material (mcl_villages/buildings.lua), so on sand or red sand
-- every footprint stayed a dirt patch. Here a sandy building is placed from a
-- variant whose ground layer is the grass node, which that same swap then turns
-- into the surface material. Grass, snow and podzol villages place the stock
-- schematic as before. The variants are in-memory copies like the furnished
-- taverns, so removing the mod leaves nothing behind.
local core = minetest

local M = {}

-- Surfaces whose ground layer should not stay dirt. Snow and podzol sit on dirt
-- anyway, and a snow layer on the ground row would float a node too high.
M.SANDY = {["mcl_core:sand"] = true, ["mcl_core:redsand"] = true}

local GRASS, DIRT = "mcl_core:dirt_with_grass", "mcl_core:dirt"

-- A copy of `mts` (a file name or schematic table) with its bottom slice of dirt
-- made grass, or nil if the schematic can't be read or has no such slice.
function M.variant(mts, engine)
	engine = engine or core
	local serialized = engine.serialize_schematic(mts, "lua", {
		lua_use_comments = false, lua_num_indent_spaces = 0,
	})
	local loader = serialized and loadstring(serialized .. " return schematic")
	local schematic = loader and loader()
	if not (schematic and schematic.size and schematic.data) then return nil end
	local changed = 0
	-- Cells run x fastest, then y, then z: the bottom slice is one run per z.
	local size = schematic.size
	for z = 0, size.z - 1 do
		for x = 0, size.x - 1 do
			local cell = schematic.data[z * size.y * size.x + x + 1]
			if cell and cell.name == DIRT then
				cell.name = GRASS
				changed = changed + 1
			end
		end
	end
	if changed == 0 then return nil end
	return schematic
end

-- Wraps settlements.place_schematics. Returns true if installed.
function M.install(settlements, engine)
	engine = engine or core
	if type(settlements) ~= "table" or type(settlements.place_schematics) ~= "function"
			or type(settlements.schematic_table) ~= "table" then
		return false
	end
	local original = settlements.place_schematics
	local cache = {} -- stock mts -> variant, so each is built once
	local function entry_of(name)
		for _, entry in ipairs(settlements.schematic_table) do
			if entry.name == name then return entry end
		end
	end
	settlements.place_schematics = function(info, ...)
		local sandy = false
		for _, building in ipairs(info) do
			if M.SANDY[building.surface_mat] then sandy = true break end
		end
		if not sandy then return original(info, ...) end
		-- One call per building, so each can take its own schematic; place_schematics
		-- keeps no state between buildings.
		local result
		for _, building in ipairs(info) do
			local entry = M.SANDY[building.surface_mat] and entry_of(building.name)
			local stock = entry and entry.mts
			local variant = stock and cache[stock]
			if stock and variant == nil then
				variant = M.variant(stock, engine) or false
				cache[stock] = variant
			end
			if variant then entry.mts = variant end
			local ok, err = pcall(function(...) result = original({building}, ...) end, ...)
			if variant then entry.mts = stock end
			if not ok then error(err, 0) end
		end
		return result
	end
	return true
end

return M
