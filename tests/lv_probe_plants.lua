-- Run with: lua tests/lv_probe_plants.lua
local M = dofile("tools/lv_probe/mod/lv_probe/plants.lua")

local function check(name, ok) if not ok then error("FAILED: " .. name, 2) end end

local KIND = {A = "air", S = "solid", D = "soil", B = "growth", F = "plant", V = "vine", L = "leaves"}
local area = {x1 = 0, x2 = 6, z1 = 0, z2 = 0, y1 = 0, y2 = 8}
local world
-- index() returns the coordinates; data looks them up in the current world.
local va = {index = function(_, x, y, z) return {x, y, z} end}
local data = setmetatable({}, {__index = function(_, i) return world(i[1], i[2], i[3]) end})
local function kind(c) return KIND[c] end
local function count() return M.count(data, va, area, kind) end

-- Flat ground at y = 2 (soil), nothing else.
local function flat(_, y) return y <= 2 and (y == 2 and "D" or "S") or "A" end
world = flat
local c = count()
check("clean world", c.buried_growth == 0 and c.dirt_on_growth == 0 and c.hole_any == 0 and c.floating == 0)

-- A 4-high stalk at x = 3 from y = 3 with a soil block on top: the #224 shape.
world = function(x, y, z)
	if x == 3 and y >= 3 and y <= 6 then return "B" end
	if x == 3 and y == 7 then return "D" end
	return flat(x, y)
end
c = count()
check("dirt on growth", c.dirt_on_growth == 1)
check("stalk buried under the dirt", c.buried_growth == 1)
check("stalk base is not floating", c.floating == 0)

-- A berry bush at the bottom of a one-column pit: the column's ground is y = 1 with
-- air over it, the bush sits at 2, neighbours' ground is 4.
world = function(x, y, z)
	if x == 3 then
		if y <= 1 then return "S" end
		if y == 2 then return "F" end
		return "A"
	end
	if x == 2 or x == 4 then return y <= 4 and "S" or "A" end
	return flat(x, y)
end
c = count()
check("hole plant", c.hole_all == 1 and c.hole_any == 1)
check("plant on ground does not float", c.floating == 0)

-- A plant with air under it floats; a plant under a block is buried.
world = function(x, y, z)
	if x == 3 and y == 4 then return "F" end
	if x == 3 and y == 5 then return "S" end
	return flat(x, y)
end
c = count()
check("floating plant", c.floating == 1)
check("plant under a block is buried", c.buried_plant == 1)

-- Vines: held by a wall beside, by a vine over them, by nothing.
world = function(x, y, z)
	if x == 1 and y >= 3 and y <= 5 then return "S" end
	if x == 2 and (y == 5 or y == 4) then return "V" end
	if x == 5 and y == 5 then return "V" end
	return flat(x, y)
end
c = count()
check("vines", c.vines == 3 and c.vines_unsupported == 1)
print("ok")
