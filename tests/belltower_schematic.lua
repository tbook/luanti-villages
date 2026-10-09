minetest = {}
local furnish = dofile("belltower_schematic.lua")

-- The real stock belltower from VoxeLibre 0.92.3, so this fails if furnish()
-- and the layout it assumes drift apart.
local stock = dofile("tests/fixtures/buildings/belltower.lua")
local size = stock.size
local function index(s, x, y, z)
	return z * s.y * s.x + y * s.x + x + 1
end
local function fresh()
	local data = {}
	for i, id in ipairs(stock.ids) do
		data[i] = {name = stock.names[id + 1], prob = 255, param2 = stock.param2[i]}
	end
	return {size = {x = size.x, y = size.y, z = size.z}, data = data}
end

assert(furnish({size = {x = 12, y = 13, z = 10}, data = {}}) == false, "unknown size must be left alone")

-- Stock: the bottom layer is the surface block's own, so the interior is a pit
-- and the bell sits three over the pit floor but two over the village's ground.
local before = fresh()
assert(before.data[index(size, 2, 3, 2)].name == "mcl_bells:bell")
assert(before.data[index(size, 2, 0, 2)].name == "air", "stock layout changed: the pit is gone")

local schematic = fresh()
assert(furnish(schematic))
local raised = schematic.size
assert(raised.x == 5 and raised.y == 7 and raised.z == 5)
assert(#schematic.data == raised.x * raised.y * raised.z)

-- The bell is a block higher, and nothing else is lost: every stock layer is
-- there a block up.
assert(schematic.data[index(raised, 2, 4, 2)].name == "mcl_bells:bell")
for z = 0, size.z - 1 do
	for y = 0, size.y - 1 do
		for x = 0, size.x - 1 do
			local old, new = before.data[index(size, x, y, z)], schematic.data[index(raised, x, y + 1, z)]
			assert(old.name == new.name and old.param2 == new.param2, "layer " .. y .. " changed")
		end
	end
end

-- The new bottom layer is the surface block itself: grass (swapped for the
-- site's own material by the generator) everywhere but under the four posts.
for z = 0, raised.z - 1 do
	for x = 0, raised.x - 1 do
		local cell = schematic.data[index(raised, x, 0, z)]
		local corner = (x == 0 or x == 4) and (z == 0 or z == 4)
		assert(cell.name == (corner and "mcl_core:stonebrick" or "mcl_core:dirt_with_grass"), x .. "," .. z)
		assert(cell.prob == 255)
	end
end

-- The lowest interior cell the tower stands on is solid now, and the bell has
-- the same two free cells over a villager's feet as before, one block up.
assert(schematic.data[index(raised, 2, 1, 2)].name == "air")
assert(schematic.data[index(raised, 2, 2, 2)].name == "air")
assert(schematic.data[index(raised, 2, 3, 2)].name == "air")

assert(not furnish(schematic), "already raised belltower must not be raised twice")

-- The generator receives the raised in-memory table.
minetest.get_modpath = function() return "/test/villages" end
minetest.serialize_schematic = function() return "fixture" end
local stock_copy = fresh()
loadstring = function() return function() return stock_copy end end
settlements = {schematic_table = {{name = "belltower", mts = "stock.mts"}}}
dofile("belltower_schematic.lua")
assert(settlements.schematic_table[1].mts == stock_copy)
assert(stock_copy.size.y == 7)
print("belltower schematic tests passed")
