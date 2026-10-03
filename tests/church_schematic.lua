minetest = {}
local furnish = dofile("church_schematic.lua")

local size = {x = 13, y = 15, z = 14}
local function index(x, y, z)
	return z * size.y * size.x + y * size.x + x + 1
end
local data = {}
for i = 1, size.x * size.y * size.z do data[i] = {name = "air", prob = 255, param2 = 0} end
local function set(x, y, z, name, param2)
	data[index(x, y, z)] = {name = name, prob = 255, param2 = param2 or 0}
end
-- The stock church's furnishings: pews at x 3 and 5 (carpet between them), a
-- wooden dais at the east end carrying purple carpet and the brewing stand.
for z = 2, 11 do
	for x = 2, 11 do set(x, 1, z, "mcl_core:cobble") end
end
for z = 3, 10 do
	for _, x in ipairs({4, 6}) do set(x, 2, z, "mcl_wool:brown_carpet") end
end
for _, x in ipairs({3, 5}) do
	for _, z in ipairs({3, 4, 5, 8, 9, 10}) do set(x, 2, z, "mcl_stairs:stair_wood", 3) end
	for _, z in ipairs({6, 7}) do set(x, 2, z, "mcl_wool:white_carpet") end
end
for z = 5, 8 do
	for x = 8, 10 do set(x, 2, z, "mcl_core:wood") end
end
set(9, 2, 4, "mcl_stairs:stair_wood", 0)
set(10, 2, 4, "mcl_stairs:stair_wood", 0)
for _, spot in ipairs({{8, 5}, {9, 5}, {10, 5}, {9, 6}, {9, 7}, {10, 7}, {8, 8}, {9, 8}, {10, 8}}) do
	set(spot[1], 3, spot[2], "mcl_wool:purple_carpet")
end
set(10, 3, 6, "mcl_brewing:stand_000", 1)

local before = {}
for i, cell in ipairs(data) do before[i] = {name = cell.name, prob = cell.prob, param2 = cell.param2} end

assert(furnish({size = {x = 12, y = 13, z = 10}, data = {}}) == false, "unknown size must be left alone")
local schematic = {size = size, data = data}
assert(furnish(schematic))

-- Every cell matches the stock layout apart from the pulpit and the pews.
local changed = {}
for z = 0, size.z - 1 do
	for y = 0, size.y - 1 do
		for x = 0, size.x - 1 do
			local old, new = before[index(x, y, z)], data[index(x, y, z)]
			if old.name ~= new.name or old.param2 ~= new.param2 or old.prob ~= new.prob then
				changed[#changed + 1] = {x = x, y = y, z = z, from = old.name, to = new.name, param2 = new.param2}
			end
		end
	end
end
assert(#changed == 13, "expected the pulpit and twelve pews, got " .. #changed)
local pulpits, chairs = 0, 0
for _, cell in ipairs(changed) do
	if cell.to == "living_villages:pulpit" then
		pulpits = pulpits + 1
		assert(cell.from == "mcl_brewing:stand_000" and cell.x == 10 and cell.y == 3 and cell.z == 6)
		-- Reader at the east side, congregation at -x: param2 3 turns +z to -x.
		assert(cell.param2 == 3, "pulpit must face the pews")
	else
		chairs = chairs + 1
		assert(cell.from == "mcl_stairs:stair_wood" and cell.to == "mcl_decor:chair_wooden")
		assert(cell.x == 3 or cell.x == 5)
		-- The sitter faces away from the backrest, which is on +z at param2 0
		-- (mcl_decor tpl_chair); param2 3 seats someone facing +x, the pulpit.
		assert(cell.param2 == 3, "pew faces away from the pulpit")
	end
end
assert(pulpits == 1 and chairs == 12)
for _, cell in ipairs(data) do assert(cell.name ~= "mcl_brewing:stand_000", "brewing stand remains") end
assert(data[index(10, 3, 6)].name == "living_villages:pulpit")
-- The dais carpet around the pulpit stays.
assert(data[index(9, 3, 6)].name == "mcl_wool:purple_carpet")
assert(not furnish(schematic), "already furnished church must not be transformed twice")

-- The generator receives the furnished in-memory table.
minetest.get_modpath = function() return "/test/villages" end
minetest.serialize_schematic = function() return "fixture" end
local fresh = {size = size, data = {}}
for i, cell in ipairs(before) do fresh.data[i] = cell end
loadstring = function() return function() return fresh end end
settlements = {schematic_table = {{name = "church", mts = "stock.mts"}}}
dofile("church_schematic.lua")
assert(settlements.schematic_table[1].mts == fresh)
assert(fresh.data[index(10, 3, 6)].name == "living_villages:pulpit")
print("church schematic tests passed")
