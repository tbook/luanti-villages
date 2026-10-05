minetest = {log = function() end}

-- A stand-in for mcl_villages' create_site_plan: positions are offered to each
-- building type in turn, the way buildings.lua does, using the real distance
-- rule, so the wrapper is exercised through the same calls.
local function new_settlements(spots)
	local s = {schematic_table = {
		{name = "belltower", hsize = 14, max_num = 0},
		{name = "small_house", hsize = 13, max_num = 0.7},
		{name = "church", hsize = 15, max_num = 0.04},
	}}
	function s.check_distance(info, pos, size)
		for _, b in ipairs(info) do
			local d = math.sqrt((pos.x - b.pos.x) ^ 2 + (pos.z - b.pos.z) ^ 2)
			if d < size or d < b.hsize then return false end
		end
		return true
	end
	function s.create_site_plan()
		local info = {{pos = {x = 0, z = 0}, name = "belltower", hsize = 14}}
		local count = {church = 0}
		for _, pos in ipairs(spots) do
			-- house first, as the shuffle might order them
			for _, b in ipairs({s.schematic_table[2], s.schematic_table[3]}) do
				if (count[b.name] or 0) < b.max_num * 20 and s.check_distance(info, pos, b.hsize) then
					count[b.name] = (count[b.name] or 0) + 1
					info[#info + 1] = {pos = pos, name = b.name, hsize = b.hsize}
					break
				end
			end
		end
		return info
	end
	return s
end

local wrap = dofile("church_site.lua")
local function churches(info)
	local n = 0
	for _, b in ipairs(info) do if b.name == "church" then n = n + 1 end end
	return n
end

-- Unwrapped, the house wins every spot and there is no church.
local plain = new_settlements({{x = 20, z = 0}, {x = 40, z = 0}, {x = 60, z = 0}})
assert(churches(plain.create_site_plan()) == 0)

-- Wrapped, the first spot with room takes the church, and only one is built.
local s = new_settlements({{x = 20, z = 0}, {x = 40, z = 0}, {x = 60, z = 0}})
assert(wrap(s))
local info = s.create_site_plan()
assert(churches(info) == 1)
assert(info[2].name == "church", "church comes first")
assert(info[3].name == "small_house" and #info == 4, "the rest are built as usual")

-- Spots too close for a church are skipped, not filled with houses.
s = new_settlements({{x = 5, z = 0}, {x = 10, z = 0}, {x = 40, z = 0}})
wrap(s)
info = s.create_site_plan()
assert(info[2].name == "church" and info[2].pos.x == 40)

-- With no room anywhere the wrapper gives up, and the village is not left bare.
local far = {}
for i = 1, 70 do far[i] = {x = 3, z = i} end
far[71] = {x = 100, z = 0}
s = new_settlements(far)
wrap(s)
info = s.create_site_plan()
assert(churches(info) == 0 or info[2].name == "church")
assert(#info > 1, "village still gets houses after the church fails to fit")

-- Terrain that runs out before the give-up count must not leave a bare village:
-- the plan is redone unforced.
s = new_settlements({{x = 14, z = 0}, {x = -14, z = 0}, {x = 0, z = 14}})
wrap(s)
info = s.create_site_plan()
assert(#info == 4 and info[2].name == "small_house", "short plan keeps its houses, got " .. #info)

-- Plain check_distance calls outside a plan are untouched.
assert(s.check_distance({}, {x = 0, z = 0}, 13))

-- A building list without a church is left alone.
local bare = new_settlements({})
bare.schematic_table[3] = nil
assert(wrap(bare) == false)
print("church_site ok")
