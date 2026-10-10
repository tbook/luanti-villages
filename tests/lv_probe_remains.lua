-- Run with: lua tests/lv_probe_remains.lua
local M = dofile("tools/lv_probe/mod/lv_probe/remains.lua")

local function check(name, ok) if not ok then error("FAILED: " .. name, 2) end end

local KIND = {A = "other", S = "support", T = "trunk", L = "leaves", C = "cocoa", V = "vine"}
local area = {x1 = 0, x2 = 30, y1 = 0, y2 = 30, z1 = 0, z2 = 3}
local va = {MinEdge = {x = -8, y = -8, z = -8}, MaxEdge = {x = 40, y = 40, z = 12},
	index = function(_, x, y, z) return x .. "," .. y .. "," .. z end}
local world, p2 = {}, {}
local data = setmetatable({}, {__index = function(_, i)
	local x, y, z = i:match("(-?%d+),(-?%d+),(-?%d+)")
	return world[x .. "," .. y .. "," .. z] or "A"
end})
local param2 = setmetatable({}, {__index = function(_, i) return p2[i] or 0 end})
local function put(x, y, z, c, q) world[x .. "," .. y .. "," .. z] = c; p2[x .. "," .. y .. "," .. z] = q end
local function count() return M.count(data, va, area, function(c) return KIND[c] end, param2) end

-- A tree with a pod, a vine and a canopy, all held.
for y = 1, 5 do put(3, y, 1, "T") end
put(3, 6, 1, "L"); put(4, 6, 1, "L")
put(3, 3, 2, "C", 2) -- faces -z onto the trunk
put(4, 5, 1, "V", 3) -- support at -x: the trunk side
local c = count()
check("held tree", c.cocoa == 1 and c.cocoa_loose == 0 and c.leaves == 2 and c.leaves_orphan == 0 and c.vines_loose == 0)

-- A floating canopy and a loose pod and vine.
for dx = 0, 2 do put(20 + dx, 20, 1, "L") end
put(10, 5, 1, "C", 0) -- faces +z onto air
put(12, 9, 1, "V", 0) -- support above: air
c = count()
check("orphan leaves", c.leaves_orphan == 3 and c.orphan_clusters == 1 and c.orphan_high == 3)
check("loose pod", c.cocoa_loose == 1)
check("loose vine", c.vines_loose == 1)

-- A sideways vine hangs under another of the same orientation, but a vine on a ceiling does not.
put(12, 9, 1, "V", 0); put(12, 10, 1, "S") -- now held by the stone over it
put(12, 8, 1, "V", 0) -- support above is a vine: loose
put(16, 12, 1, "V", 4); put(16, 11, 1, "V", 4) -- +z side is air, the top one has a stone beside it
put(16, 12, 2, "S")
c = count()
check("vines", c.vines_loose == 1)

print("lv_probe_remains: ok")
