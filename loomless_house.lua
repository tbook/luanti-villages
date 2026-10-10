-- About half the small houses are generated without their loom (#223). Every stock
-- small_house (the shepherd's hut) holds a loom beside the bed, so every one made a
-- shepherd and the other jobsites, such as the blast furnace, stayed free. A loomless
-- house is a bed and no workstation: its villager starts unemployed and looks for
-- work like any other. The loom's cell becomes air (the floor under it is cobble,
-- and its other sides a wall and the bed). Like ground_layer.lua this edits an
-- in-memory copy per building, so the stock schematic is never touched, and
-- removing the mod leaves nothing behind.
--
-- The choice is deterministic: a hash of the building's x and z (not y, which
-- terraforming can nudge) and the world seed, so a regenerated village matches.
-- The wrapper composes with ground_layer.lua in either order, since each takes the
-- entry's mts as it finds it, swaps its own variant in for one call and puts back
-- what it found.
local core = minetest

local M = {}

local LOOM, AIR = "mcl_loom:loom", "air"
M.DEFAULT_CHANCE = 0.5
M.SETTING = "living_villages_loomless_house_chance"

local MOD = 94906249 -- squares of values below this stay under 2^53

local function finite(n)
	return n and n == n and n ~= math.huge and n ~= -math.huge
end

-- The configured chance, 0..1. Anything that isn't a finite number is the default.
function M.chance(engine)
	engine = engine or core
	local raw = engine.settings and engine.settings:get(M.SETTING)
	local value = tonumber(raw)
	if not finite(value) then return M.DEFAULT_CHANCE end
	return math.max(0, math.min(1, value))
end

local function fold(n)
	return math.floor(n) % MOD
end

-- The world seed as a number (it is a string, and may be negative or not numeric).
function M.world_seed(engine)
	engine = engine or core
	local raw = engine.get_mapgen_setting and engine.get_mapgen_setting("seed")
	local n = tonumber(raw)
	if finite(n) then return fold(n) end
	local text, sum = tostring(raw or ""), 0
	for i = 1, #text do sum = (sum * 31 + text:byte(i)) % MOD end
	return sum
end

-- A number in [0, 1) fixed by the position and the seed.
function M.roll(pos, seed)
	seed = fold(seed or 0)
	local h = (seed + 12345) % MOD
	h = (h * h + fold(pos.x) * 9973 + 1) % MOD
	h = (h * h + fold(pos.z) * 7919 + 3) % MOD
	h = (h * h + seed + 7) % MOD
	h = (h * h + 11) % MOD
	h = (h * h + 13) % MOD
	return h / MOD
end

function M.is_loomless(pos, seed, chance)
	if not (pos and finite(pos.x) and finite(pos.z)) or not (chance > 0) then return false end
	if chance >= 1 then return true end
	return M.roll(pos, seed) < chance
end

-- Turns the loom cells of `schematic` into air, in place. Returns how many, or
-- false if there was none.
function M.remove_loom(schematic)
	local removed = 0
	for _, cell in ipairs(schematic.data or {}) do
		if cell.name == LOOM then
			cell.name, cell.param2 = AIR, 0
			removed = removed + 1
		end
	end
	return removed > 0 and removed
end

-- A copy of `mts` (a file name or schematic table) with no loom, or nil if it can't
-- be read or has none.
function M.variant(mts, engine)
	engine = engine or core
	local serialized = engine.serialize_schematic(mts, "lua", {
		lua_use_comments = false, lua_num_indent_spaces = 0,
	})
	local loader = serialized and loadstring(serialized .. " return schematic")
	local schematic = loader and loader()
	if not (schematic and schematic.size and schematic.data) then return nil end
	if not M.remove_loom(schematic) then return nil end
	return schematic
end

local wrappers = setmetatable({}, {__mode = "k"}) -- our wrappers, so a second install is a no-op

-- Wraps settlements.place_schematics. Returns true if installed (or already is).
-- Install it after ground_layer.lua (or before: they compose either way).
function M.install(settlements, engine)
	engine = engine or core
	if type(settlements) == "table" and wrappers[settlements.place_schematics] then return true end
	if type(settlements) ~= "table" or type(settlements.place_schematics) ~= "function"
			or type(settlements.schematic_table) ~= "table" then
		return false
	end
	local original = settlements.place_schematics
	local cache = {} -- the mts as found -> its loomless variant (or false)
	local function entry_of(name)
		for _, entry in ipairs(settlements.schematic_table) do
			if entry.name == name then return entry end
		end
	end
	local wrapper
	wrapper = function(info, ...)
		local chance = M.chance(engine)
		local seed = M.world_seed(engine)
		local function loomless(building)
			return building.name == "small_house" and M.is_loomless(building.pos, seed, chance)
		end
		local any = false
		for _, building in ipairs(info) do
			if loomless(building) then any = true break end
		end
		if not any then return original(info, ...) end
		-- One call per building, so each can take its own schematic.
		local result
		for _, building in ipairs(info) do
			local entry = loomless(building) and entry_of(building.name)
			local found = entry and entry.mts
			local variant = found and cache[found]
			if found and variant == nil then
				variant = M.variant(found, engine) or false
				cache[found] = variant
			end
			if variant then entry.mts = variant end
			local ok, err = pcall(function(...) result = original({building}, ...) end, ...)
			if variant then entry.mts = found end
			if not ok then error(err) end
		end
		return result
	end
	wrappers[wrapper] = true
	settlements.place_schematics = wrapper
	return true
end

return M
