-- Run from the mod directory: lua5.1 tests/ground_layer.lua
minetest = {}
local ground = dofile("ground_layer.lua")

-- A 2x2x2 schematic (cells run x fastest, then y, then z): dirt in the bottom
-- slice (y 0) of both z rows, one dirt cell in the layer above, air elsewhere.
local function index(size, x, y, z) return z * size.y * size.x + y * size.x + x + 1 end
local function schematic()
	local size = {x = 2, y = 2, z = 2}
	local data = {}
	for i = 1, 8 do data[i] = {name = "air", prob = 255, param2 = 0} end
	for z = 0, 1 do
		for x = 0, 1 do data[index(size, x, 0, z)].name = "mcl_core:dirt" end
	end
	data[index(size, 0, 1, 0)].name = "mcl_core:dirt"
	return {size = size, data = data}
end

-- serialize_schematic + loadstring stand in for a round trip that copies the table.
local copied
local engine = {serialize_schematic = function(mts)
	copied = {size = mts.size, data = {}}
	for i, c in ipairs(mts.data) do copied.data[i] = {name = c.name, prob = c.prob, param2 = c.param2} end
	return "serialized"
end}
loadstring = function() return function() return copied end end

local stock = schematic()
local v = ground.variant(stock, engine)
for z = 0, 1 do
	for x = 0, 1 do
		assert(v.data[index(v.size, x, 0, z)].name == "mcl_core:dirt_with_grass", "ground slice becomes the swappable node")
	end
end
assert(v.data[index(v.size, 0, 1, 0)].name == "mcl_core:dirt", "only the bottom slice")
assert(stock.data[1].name == "mcl_core:dirt", "the stock schematic is untouched")
local none = {size = {x = 1, y = 1, z = 1}, data = {{name = "air"}}}
assert(ground.variant(none, engine) == nil, "no dirt, no variant")

-- The wrapper: what each placement call sees as the building's schematic.
local calls
local settlements = {
	schematic_table = {{name = "house", mts = stock}, {name = "well", mts = none}},
}
settlements.place_schematics = function(info, pr)
	for _, b in ipairs(info) do
		local mts
		for _, e in ipairs(settlements.schematic_table) do if e.name == b.name then mts = e.mts end end
		calls[#calls + 1] = {name = b.name, ground = mts.data[1].name, pr = pr}
	end
	return "done"
end
assert(ground.install(settlements, engine))

local function place(surface)
	calls = {}
	assert(settlements.place_schematics({
		{name = "house", surface_mat = surface}, {name = "well", surface_mat = surface},
	}, "pr") == "done")
	return calls
end

local c = place("mcl_core:sand")
assert(#c == 2 and c[1].ground == "mcl_core:dirt_with_grass" and c[1].pr == "pr", "sand: the house gets the variant")
assert(c[2].ground == "air", "a building without a dirt slice keeps its schematic")
assert(settlements.schematic_table[1].mts == stock, "stock schematic restored")
c = place("mcl_core:redsand")
assert(c[1].ground == "mcl_core:dirt_with_grass", "red sand too")
c = place("mcl_core:dirt_with_grass")
assert(#c == 2 and c[1].ground == "mcl_core:dirt", "grass villages place the stock schematic")
c = place("mcl_core:snow")
assert(c[1].ground == "mcl_core:dirt", "snow villages too")

-- A failing placement still restores the schematic.
settlements = {schematic_table = {{name = "house", mts = stock}}}
settlements.place_schematics = function() error("boom") end
assert(ground.install(settlements, engine))
assert(not pcall(settlements.place_schematics, {{name = "house", surface_mat = "mcl_core:sand"}}))
assert(settlements.schematic_table[1].mts == stock, "restored after an error")

assert(not ground.install(nil) and not ground.install({}), "nothing to wrap, nothing installed")
print("ground layer tests passed")
