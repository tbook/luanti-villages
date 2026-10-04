minetest = {}
local furnish = dofile("church_schematic.lua")

-- The real stock church from VoxeLibre 0.92.3, not a hand-built stand-in, so
-- this fails if furnish() and the layout it assumes drift apart.
local stock = dofile("tests/fixtures/church_voxelibre_0_92_3.lua")
local size = stock.size
local function index(x, y, z)
	return z * size.y * size.x + y * size.x + x + 1
end
local data = {}
for i, id in ipairs(stock.ids) do
	data[i] = {name = stock.names[id + 1], prob = 255, param2 = stock.param2[i]}
end
assert(#data == size.x * size.y * size.z)

local before = {}
for i, cell in ipairs(data) do before[i] = {name = cell.name, prob = cell.prob, param2 = cell.param2} end

assert(furnish({size = {x = 12, y = 13, z = 10}, data = {}}) == false, "unknown size must be left alone")
local schematic = {size = size, data = data}
assert(furnish(schematic))

-- Every cell matches the stock layout apart from the pulpit, the carpet that
-- replaces the brewing stand, and the pews.
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
assert(#changed == 14, "expected the pulpit, a carpet and twelve pews, got " .. #changed)
local pulpits, chairs, carpets = 0, 0, 0
for _, cell in ipairs(changed) do
	if cell.to == "living_villages:pulpit" then
		pulpits = pulpits + 1
		-- Beside the altar (x 8, z 6 to 7), on the congregation's left: the
		-- congregation faces east (+x), so its left is +z.
		assert(cell.from == "mcl_wool:purple_carpet" and cell.x == 8 and cell.y == 3 and cell.z == 8)
		assert(before[index(8, 3, 7)].name == "mcl_core:wood" and before[index(8, 4, 7)].name == "mcl_wool:white_carpet",
			"the pulpit is not next to the altar")
		-- Facing the pews at -x: param2 3 turns the audience side (+z) to -x.
		assert(cell.param2 == 3, "pulpit must face the pews")
	elseif cell.to == "mcl_wool:purple_carpet" then
		carpets = carpets + 1
		assert(cell.from == "mcl_brewing:stand_000" and cell.x == 10 and cell.y == 3 and cell.z == 6)
		assert(cell.param2 == 0)
	else
		chairs = chairs + 1
		assert(cell.from == "mcl_stairs:stair_wood" and cell.to == "mcl_decor:chair_wooden")
		assert(cell.x == 3 or cell.x == 5)
		-- The sitter faces away from the backrest, which is on +z at param2 0
		-- (mcl_decor tpl_chair); param2 3 seats someone facing +x, the altar.
		assert(cell.param2 == 3, "pew faces away from the altar")
	end
end
assert(pulpits == 1 and carpets == 1 and chairs == 12)
for _, cell in ipairs(data) do assert(cell.name ~= "mcl_brewing:stand_000", "brewing stand remains") end
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
assert(fresh.data[index(8, 3, 8)].name == "living_villages:pulpit")
print("church schematic tests passed")
