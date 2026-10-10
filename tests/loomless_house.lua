-- Run from the mod directory: lua5.1 tests/loomless_house.lua
local setting
minetest = {
	settings = {get = function() return setting end},
	get_mapgen_setting = function() return "12345" end,
}
local loomless = dofile("loomless_house.lua")
local ground = dofile("ground_layer.lua")

-- The stock small_house fixture as a schematic table.
local fixture = dofile("tests/fixtures/buildings/small_house.lua")
local function stock_schematic()
	local s = {size = fixture.size, data = {}}
	for i, id in ipairs(fixture.ids) do
		s.data[i] = {name = fixture.names[id + 1], prob = 255, param2 = fixture.param2 and fixture.param2[i] or 0}
	end
	return s
end
local function count(s, name)
	local n = 0
	for _, c in ipairs(s.data) do if c.name == name then n = n + 1 end end
	return n
end

local copied
local engine = {
	settings = minetest.settings, get_mapgen_setting = minetest.get_mapgen_setting,
	log = function() end,
	serialize_schematic = function(mts)
		copied = {size = mts.size, data = {}}
		for i, c in ipairs(mts.data) do copied.data[i] = {name = c.name, prob = c.prob, param2 = c.param2} end
		return "serialized"
	end,
}
loadstring = function() return function() return copied end end

-- The variant: no loom, every other cell identical.
local stock = stock_schematic()
assert(count(stock, "mcl_loom:loom") == 1)
local v = loomless.variant(stock, engine)
assert(count(v, "mcl_loom:loom") == 0, "no loom")
assert(count(stock, "mcl_loom:loom") == 1, "the stock schematic is untouched")
local changed = 0
for i, c in ipairs(stock.data) do
	if v.data[i].name ~= c.name then
		changed = changed + 1
		assert(c.name == "mcl_loom:loom" and v.data[i].name == "air")
	else
		assert(v.data[i].param2 == c.param2 and v.data[i].prob == c.prob)
	end
end
assert(changed == 1 and #v.data == #stock.data and v.size.x == 9)
assert(loomless.variant(v, engine) == nil, "no loom, no variant")

-- Settings.
for raw, want in pairs({["0"] = 0, ["1"] = 1, ["0.25"] = 0.25, ["-3"] = 0, ["7"] = 1}) do
	setting = raw
	assert(loomless.chance(engine) == want, raw)
end
setting = nil
assert(loomless.chance(engine) == 0.5, "default")
for _, raw in ipairs({"abc", "", "nan", "inf", "-inf", "0x"}) do
	setting = raw
	assert(loomless.chance(engine) == 0.5, "non-finite or non-numeric: " .. raw)
end

-- Determinism and share.
local function share(chance, seed)
	local n, hits = 0, 0
	for x = -1000, 1000, 37 do
		for z = -1000, 1000, 29 do
			n = n + 1
			if loomless.is_loomless({x = x, y = 5, z = z}, seed, chance) then hits = hits + 1 end
		end
	end
	return hits / n
end
local a = loomless.is_loomless({x = 101, y = 9, z = -45}, 7, 0.5)
for _ = 1, 3 do assert(loomless.is_loomless({x = 101, y = 77, z = -45}, 7, 0.5) == a, "same x z, any y") end
assert(share(0, 1) == 0 and share(1, 1) == 1)
for _, seed in ipairs({0, 1, 99, 94906248, 123456789}) do
	local s = share(0.5, seed)
	assert(s > 0.45 and s < 0.55, "default share about half, got " .. s .. " for seed " .. seed)
end
local s3 = share(0.25, 5)
assert(s3 > 0.2 and s3 < 0.3, "quarter, got " .. s3)
local differs = false
for x = 0, 200, 10 do
	if loomless.is_loomless({x = x, y = 0, z = 3}, 1, 0.5) ~= loomless.is_loomless({x = x, y = 0, z = 3}, 2, 0.5) then differs = true end
end
assert(differs, "the seed matters")
assert(loomless.world_seed({get_mapgen_setting = function() return "-9223372036854775808" end}) >= 0)
assert(loomless.world_seed({get_mapgen_setting = function() return "banana" end}) >= 0)
assert(loomless.world_seed({}) == 0)

-- The wrapper.
local function new_settlements(extra)
	local s = {schematic_table = {{name = "small_house", mts = stock}, {name = "well", mts = {size = {x = 1, y = 1, z = 1}, data = {{name = "air"}}}}}}
	s.calls = {}
	s.place_schematics = function(info, pr)
		for _, b in ipairs(info) do
			local mts
			for _, e in ipairs(s.schematic_table) do if e.name == b.name then mts = e.mts end end
			s.calls[#s.calls + 1] = {
				name = b.name, looms = count(mts, "mcl_loom:loom"), ground = mts.data[1].name, pr = pr,
			}
		end
		return "done"
	end
	return s
end
local function place(s, surface, names)
	s.calls = {}
	local info = {}
	for i, n in ipairs(names or {"small_house"}) do
		info[i] = {name = n, pos = {x = 100 + 11 * i, y = 4, z = 50}, surface_mat = surface}
	end
	assert(s.place_schematics(info, "pr") == "done")
	return s.calls
end

setting = "1"
local s = new_settlements()
assert(loomless.install(s, engine))
local wrapped = s.place_schematics
assert(loomless.install(s, engine) and s.place_schematics == wrapped, "double install")
local c = place(s, "mcl_core:dirt_with_grass", {"small_house", "well", "small_house"})
assert(#c == 3 and c[1].looms == 0 and c[3].looms == 0 and c[1].pr == "pr", "chance 1: no looms")
assert(c[2].name == "well" and c[2].looms == 0, "other buildings are placed as ever")
assert(s.schematic_table[1].mts == stock, "stock entry restored")
setting = "0"
c = place(s, "mcl_core:dirt_with_grass")
assert(c[1].looms == 1, "chance 0: stock")
setting = "0.5"
local with, without = 0, 0
for x = 0, 400 do
	s.calls = {}
	s.place_schematics({{name = "small_house", pos = {x = x * 13, y = 4, z = x * 7 % 301}}})
	if s.calls[1].looms == 0 then without = without + 1 else with = with + 1 end
	assert(s.schematic_table[1].mts == stock)
end
assert(without > 160 and with > 160, "about half each: " .. without .. "/" .. with)
-- A building without a position keeps its loom.
s.calls = {}
s.place_schematics({{name = "small_house"}})
assert(s.calls[1].looms == 1)

-- Composition with ground_layer, in both install orders, on sand.
setting = "1"
for order = 1, 2 do
	local g = new_settlements()
	if order == 1 then
		assert(ground.install(g, engine)); assert(loomless.install(g, engine))
	else
		assert(loomless.install(g, engine)); assert(ground.install(g, engine))
	end
	local r = place(g, "mcl_core:sand")
	assert(r[1].looms == 0 and r[1].ground == "mcl_core:dirt_with_grass", "sand + loomless, order " .. order)
	r = place(g, "mcl_core:dirt_with_grass")
	assert(r[1].looms == 0 and r[1].ground == "mcl_core:dirt", "grass + loomless, order " .. order)
	assert(g.schematic_table[1].mts == stock, "stock restored, order " .. order)
	setting = "0"
	r = place(g, "mcl_core:redsand")
	assert(r[1].looms == 1 and r[1].ground == "mcl_core:dirt_with_grass", "sand, stock loom, order " .. order)
	assert(g.schematic_table[1].mts == stock)
	setting = "1"
end

-- A failing placement still restores the schematic.
local f = {schematic_table = {{name = "small_house", mts = stock}}}
f.place_schematics = function() error("boom") end
assert(loomless.install(f, engine))
local ok, err = pcall(f.place_schematics, {{name = "small_house", pos = {x = 1, y = 1, z = 1}}})
assert(not ok and tostring(err):find("boom"), "the original error comes through")
assert(f.schematic_table[1].mts == stock, "restored after an error")

-- A missing entry is placed as it comes.
local m = {schematic_table = {}}
local seen = 0
m.place_schematics = function(info) seen = seen + #info end
assert(loomless.install(m, engine))
m.place_schematics({{name = "small_house", pos = {x = 1, y = 1, z = 1}}})
assert(seen == 1)
assert(not loomless.install(nil) and not loomless.install({}), "nothing to wrap")
print("loomless house tests passed")
