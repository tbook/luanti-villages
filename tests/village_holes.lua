-- Run with: lua tests/village_holes.lua
local logs = {}
minetest = {
	get_modpath = function() return "." end,
	log = function(level, m) table.insert(logs, level .. ": " .. m) end,
}
local holes = dofile("village_holes.lua")
local cfg = holes.config

-- A grid of columns 0..W-1 by 0..W-1, flat at 10; `edit` changes it. The pad is a
-- 2x2 protected block at the origin corner.
local W = 20
local function grid(edit)
	local g = {}
	for x = 0, W - 1 do
		g[x] = {}
		for z = 0, W - 1 do g[x][z] = {y = 10} end
	end
	if edit then edit(g) end
	return g
end
local function spec_of(g, protected)
	return {
		x0 = 0, z0 = 0, x1 = W - 1, z1 = W - 1,
		column = function(x, z) return g[x] and g[x][z] end,
		protected = protected or function(x, z) return x < 2 and z < 2 end,
	}
end
local function box(g, x0, z0, x1, z1, f)
	for x = x0, x1 do for z = z0, z1 do f(g[x][z], x, z) end end
end

-- Independent check: from every dry column, can a villager (up one block per
-- step, down any distance) reach the edge or the pad?
local function trapped_columns(plan, g)
	local function h(x, z)
		if x < 0 or z < 0 or x >= W or z >= W then return nil end
		return plan.at(x, z)
	end
	local out = 0
	for x = 0, W - 1 do for z = 0, W - 1 do
		if g[x][z].liquid then goto continue end
		local seen, queue, head, free = {[x .. "," .. z] = true}, {{x, z}}, 1, false
		while head <= #queue and not free do
			local cx, cz = queue[head][1], queue[head][2]
			head = head + 1
			if cx == 0 or cz == 0 or cx == W - 1 or cz == W - 1 or (cx < 2 and cz < 2) then free = true end
			for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				local nx, nz = cx + d[1], cz + d[2]
				local nh = h(nx, nz)
				if nh and not seen[nx .. "," .. nz] and not g[nx][nz].liquid and nh <= h(cx, cz) + 1 then
					seen[nx .. "," .. nz] = true
					queue[#queue + 1] = {nx, nz}
				end
			end
		end
		if not free then out = out + 1 end
		::continue::
	end end
	return out
end

-- Flat ground: nothing to do.
local g = grid()
local plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0 and plan.regions == 0 and plan.left == 0, "flat ground untouched")

-- A shallow pit (3 deep, 3x3) is filled to the rim and the walk-out check passes.
g = grid(function(g) box(g, 8, 8, 10, 10, function(c) c.y = 7 end) end)
assert(trapped_columns({at = function(x, z) return g[x][z].y end}, g) == 9, "the pit traps before")
plan = holes.plan(spec_of(g), cfg)
assert(plan.filled == 1 and plan.capped == 0 and #plan.cells == 9, "one shallow hole")
for _, cell in ipairs(plan.cells) do assert(cell.from == 7 and cell.to == 10 and not cell.cap, "filled to the rim") end
assert(plan.at(9, 9) == 10 and plan.left == 0 and trapped_columns(plan, g) == 0, "walkable after the fill")

-- A deep shaft (30 below the rim): capped with a lid three thick, nothing below it.
g = grid(function(g) box(g, 8, 8, 9, 9, function(c) c.y = -20 end) end)
plan = holes.plan(spec_of(g), cfg)
assert(plan.capped == 1 and plan.filled == 0 and #plan.cells == 4, "one deep hole")
local writes = {}
holes.apply(plan, function() return "grass", "dirt" end, cfg, {
	swap_node = function(p, n) writes[#writes + 1] = {y = p.y, name = n.name, x = p.x, z = p.z} end,
})
local lowest, highest, top_name = math.huge, -math.huge
for _, w in ipairs(writes) do
	if w.x == 8 and w.z == 8 then
		lowest, highest = math.min(lowest, w.y), math.max(highest, w.y)
		if w.y == 10 then top_name = w.name end
	end
end
assert(lowest == 8 and highest == 10 and top_name == "grass", "a lid of 3 with the surface on top")
assert(plan.at(8, 8) == 10 and trapped_columns(plan, g) == 0, "walkable over the lid")

-- A slope, even a steep walkable one (each step 1), is not a hole.
g = grid(function(g) for x = 0, W - 1 do for z = 0, W - 1 do g[x][z].y = 10 - math.min(x, 12) end end end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0, "a slope is untouched")
-- A cave mouth that can be walked out of by 1-block steps (a stair-shaped bowl) too.
g = grid(function(g)
	g[9][9].y, g[8][9].y, g[10][9].y, g[9][8].y, g[9][10].y = 8, 9, 9, 9, 9
end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0, "a gentle sinkhole is untouched")

-- A pond: water stays. A pit with water in it is left alone as a whole.
g = grid(function(g) box(g, 8, 8, 11, 11, function(c) c.y, c.liquid = 9, true end) end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0, "a pond is untouched")
g = grid(function(g)
	box(g, 6, 6, 12, 12, function(c) c.y = 2 end)
	box(g, 8, 8, 10, 10, function(c) c.y, c.liquid = 1, true end)
end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0 and plan.skipped == 1, "a hole with water is left alone")

-- Surface lava is replaced like a hole, down through the lava.
g = grid(function(g) box(g, 8, 8, 9, 9, function(c) c.y, c.liquid, c.lava = 9, true, true end) end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 4 and plan.cells[1].lava and plan.cells[1].to == 10, "lava becomes ground at the rim")
assert(plan.at(8, 8) == 10)

-- Protected columns never change, and are ways out: a pit beside the pad that is
-- a drop of 3 from the pad still fills, and the pad stays at 10.
g = grid(function(g) box(g, 3, 0, 5, 3, function(c) c.y = 6 end) end)
plan = holes.plan(spec_of(g), cfg)
for _, cell in ipairs(plan.cells) do assert(cell.x >= 3, "pad columns untouched") end
assert(trapped_columns(plan, g) == 0)
-- A pit that touches only the edge of the area is a way out, not a hole.
g = grid(function(g) box(g, 0, 8, 3, 10, function(c) c.y = 3 end) end)
assert(#holes.plan(spec_of(g, function() return false end), cfg).cells == 0, "edge columns are ways out")
-- Columns next to unknown ground are left alone.
g = grid(function(g) g[8][8].y = 3 end)
g[9][8] = nil
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0, "unknown neighbors count as ways out")

-- A pit with a pillar left inside it is still solved, in more than one pass.
g = grid(function(g)
	box(g, 6, 6, 12, 12, function(c) c.y = 5 end)
	g[9][9].y = 9
end)
plan = holes.plan(spec_of(g), cfg)
assert(plan.left == 0 and trapped_columns(plan, g) == 0, "pillar in a pit")

-- area: bounding box of pads plus margin, `below` under the lowest pad.
local area = holes.area({
	{yx0 = 0, yz0 = 0, yx1 = 5, yz1 = 5, y = 10}, {yx0 = 20, yz0 = 4, yx1 = 25, yz1 = 9, y = 14},
})
assert(area.minp.x == -12 and area.maxp.x == 37 and area.minp.y == 10 - cfg.below and area.maxp.y == 14 + cfg.above)

print("village_holes: ok")
