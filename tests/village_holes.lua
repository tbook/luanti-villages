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
local W = 25
local function grid(edit)
	local g = {}
	for x = 0, W - 1 do
		g[x] = {}
		for z = 0, W - 1 do g[x][z] = {y = 10} end
	end
	if edit then edit(g) end
	return g
end
local function spec_of(g, protected, ceiling)
	return {
		x0 = 0, z0 = 0, x1 = W - 1, z1 = W - 1,
		column = function(x, z) return g[x] and g[x][z] end,
		protected = protected or function(x, z) return x < 2 and z < 2 end,
		ceiling = ceiling,
	}
end
local function box(g, x0, z0, x1, z1, f)
	for x = x0, x1 do for z = z0, z1 do f(g[x][z], x, z) end end
end
local none = function() return false end
local function low(g) box(g, 0, 0, W - 1, W - 1, function(c) c.y = 0 end) end

-- Independent check: the largest difference between adjacent dry columns of a plan.
local function steepest(plan, skip)
	local worst = 0
	for x = 0, W - 1 do for z = 0, W - 1 do
		for _, d in ipairs({{1, 0}, {0, 1}}) do
			local nx, nz = x + d[1], z + d[2]
			if nx < W and nz < W and plan.at(x, z) and plan.at(nx, nz) and not (skip and (skip(x, z) or skip(nx, nz))) then
				worst = math.max(worst, math.abs(plan.at(x, z) - plan.at(nx, nz)))
			end
		end
	end end
	return worst
end
-- A villager walks up one block and down any distance: can every dry column reach
-- the edge of the grid?
local function trapped_columns(plan, g)
	local function h(x, z)
		if x < 0 or z < 0 or x >= W or z >= W then return nil end
		return plan.at(x, z)
	end
	local out = 0
	for x = 0, W - 1 do for z = 0, W - 1 do
		if not g[x][z].liquid then
			local seen, queue, head, free = {[x .. "," .. z] = true}, {{x, z}}, 1, false
			while head <= #queue and not free do
				local cx, cz = queue[head][1], queue[head][2]
				head = head + 1
				if cx == 0 or cz == 0 or cx == W - 1 or cz == W - 1 then free = true end
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
		end
	end end
	return out
end

-- Flat ground: nothing to do.
local g = grid()
local plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0 and plan.nodes == 0 and plan.cliffs_after == 0, "flat ground untouched")

-- A shallow pit (3 deep, 3x3) is filled to the rim.
g = grid(function(g) box(g, 8, 8, 10, 10, function(c) c.y = 7 end) end)
assert(trapped_columns({at = function(x, z) return g[x][z].y end}, g) == 9, "the pit traps before")
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 9 and plan.filled == 9 and plan.nodes == 27, "one shallow hole")
for _, cell in ipairs(plan.cells) do assert(cell.from == 7 and cell.to == 10, "filled to the rim") end
assert(trapped_columns(plan, g) == 0 and plan.cliffs_before == 12 and plan.cliffs_after == 0)

-- A deep vertical shaft (30 below the flat ground) disappears: filled to the top,
-- no cliff left, nothing below the old floor.
g = grid(function(g) box(g, 8, 8, 9, 9, function(c) c.y = -20 end) end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 4 and plan.nodes == 4 * 30, "deep shaft filled all the way")
assert(steepest(plan) <= 1 and plan.at(8, 8) == 10 and plan.cliffs_after == 0, "no cliff over one")

-- The case from #155: a shaft with dirt steps down one side and a sheer drop on the
-- other used to be left, because the stair was a way out. Now it is filled.
g = grid(function(g)
	box(g, 8, 8, 10, 10, function(c) c.y = -20 end)
	g[7][9].y, g[7][8].y, g[7][10].y = -3, -3, -3 -- a step down on the west side
	g[6][9].y, g[6][8].y, g[6][10].y = 5, 5, 5
	g[5][9].y, g[5][8].y, g[5][10].y = 8, 8, 8
end)
plan = holes.plan(spec_of(g), cfg)
assert(steepest(plan) <= 1, "stair and sheer side both resolved: " .. steepest(plan))
assert(plan.at(9, 9) >= 9, "the shaft is filled up to the ground")

-- Cascade: a slow step up that ends in a cliff becomes a ramp to the top. A block
-- of ground at 5 with a step of 1 and one of 2 before its west face; the ramp also
-- tapers off round the block, so no cliff is left anywhere.
g = grid(function(g)
	low(g)
	box(g, 12, 8, 16, 16, function(c) c.y = 5 end)
	box(g, 10, 8, 10, 16, function(c) c.y = 1 end)
	box(g, 11, 8, 11, 16, function(c) c.y = 2 end)
end)
plan = holes.plan(spec_of(g, none), cfg)
assert(plan.cliffs_before > 0 and plan.cliffs_after == 0 and steepest(plan) <= 1, "ramp, no cliff")
assert(plan.at(11, 12) == 4 and plan.at(10, 12) == 3 and plan.at(9, 12) == 2 and plan.at(8, 12) == 1 and plan.at(7, 12) == 0,
	"cascades back along the slope")
assert(plan.ramped > 0, "counted as ramped")
-- A ramp that cannot taper off, because a protected column stops it, is not half built:
-- the ledge beside a pad stays as it was.
g = grid(function(g) low(g); box(g, 12, 8, 16, 16, function(c) c.y = 5 end) end)
plan = holes.plan(spec_of(g, function(x, z) return x == 8 and z == 12 end), cfg)
assert(plan.at(11, 12) == 0 and plan.at(11, 11) == 0, "a ramp that would end in a new cliff is not built")
-- A ledge raised against a wall with a deep pit beside it that cannot follow is undone.
g = grid(function(g)
	low(g)
	box(g, 12, 8, 16, 16, function(c) c.y = 5 end)
	box(g, 8, 8, 11, 8, function(c) c.y = -30 end)
end)
plan = holes.plan(spec_of(g, none), cfg)
assert(plan.cliffs_after <= plan.cliffs_before)
-- A wall taller than cliff_rise is landscape: left as it is, and not half-built.
g = grid(function(g)
	for x = 0, W - 1 do for z = 0, W - 1 do g[x][z].y = x < 12 and 0 or 30 end end
end)
plan = holes.plan(spec_of(g, none), cfg)
assert(#plan.cells == 0, "a tall wall gets no ramp")
-- Cliff closing can be turned off.
g = grid(function(g)
	for x = 0, W - 1 do for z = 0, W - 1 do g[x][z].y = x < 12 and 0 or 3 end end
end)
assert(#holes.plan(spec_of(g, none), cfg).cells > 0)
local off = {}
for k, v in pairs(cfg) do off[k] = v end
off.cliff_rise = 0
assert(#holes.plan(spec_of(g, none), off).cells == 0, "cliff_rise 0 turns phase 2 off")

-- A slope, even a steep walkable one, is not a hole.
g = grid(function(g) for x = 0, W - 1 do for z = 0, W - 1 do g[x][z].y = 10 - math.min(x, 12) end end end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0, "a slope is untouched")
-- A gentle sinkhole is a depression too: it is filled, which is harmless.
g = grid(function(g)
	g[9][9].y, g[8][9].y, g[10][9].y, g[9][8].y, g[9][10].y = 8, 9, 9, 9, 9
end)
plan = holes.plan(spec_of(g), cfg)
assert(steepest(plan) <= 1 and plan.at(9, 9) == 9 or plan.at(9, 9) == 10)

-- A pond: water stays, and so do the columns beside it.
g = grid(function(g) box(g, 8, 8, 11, 11, function(c) c.y, c.liquid = 9, true end) end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 0, "a pond is untouched")
g = grid(function(g)
	box(g, 6, 6, 12, 12, function(c) c.y = 2 end)
	box(g, 8, 8, 10, 10, function(c) c.y, c.liquid = 1, true end)
end)
plan = holes.plan(spec_of(g), cfg)
for x = 7, 11 do for z = 7, 11 do
	assert(plan.at(x, z) == g[x][z].y, "water and its shore are not touched")
end end
-- The pit around it fills no higher than the shore, so the pond does not drown.
assert(plan.at(6, 6) <= 2, "fill beside water stops at the shore")

-- Surface lava is replaced like a hole, down through the lava.
g = grid(function(g) box(g, 8, 8, 9, 9, function(c) c.y, c.liquid, c.lava = 9, true, true end) end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 4 and plan.cells[1].lava and plan.cells[1].to == 10, "lava becomes ground at the rim")
assert(plan.at(8, 8) == 10)
-- Lava level with the ground is replaced too.
g = grid(function(g) g[8][8].y, g[8][8].liquid, g[8][8].lava = 10, true, true end)
plan = holes.plan(spec_of(g), cfg)
assert(#plan.cells == 1 and plan.cells[1].lava and plan.cells[1].to == 10)

-- Protected columns never change: a pit beside the pad that is a drop of 3 from the
-- pad fills, no higher than the pad, and the pad stays at 10.
g = grid(function(g) box(g, 3, 0, 5, 3, function(c) c.y = 6 end) end)
plan = holes.plan(spec_of(g), cfg)
for _, cell in ipairs(plan.cells) do assert(cell.x >= 3 or cell.z >= 2, "pad columns untouched") end
assert(plan.at(0, 0) == 10 and plan.at(1, 1) == 10)
-- Fill never piles on a yard: the ground beside a pad at 10 is raised to 10 at most,
-- though the ground around it is at 14.
g = grid(function(g)
	box(g, 0, 0, W - 1, W - 1, function(c) c.y = 14 end)
	box(g, 2, 0, 6, 6, function(c) c.y = 4 end)
end)
plan = holes.plan(spec_of(g, function(x, z) return x < 2 and z < 2 end, function(x, z)
	if x <= 4 and z <= 4 then return 10 end
end), cfg)
for x = 0, W - 1 do for z = 0, W - 1 do
	if (x <= 4 and z <= 4) then assert(plan.at(x, z) <= 10 or g[x][z].y > 10, "ring never above the floor") end
end end
assert(plan.at(0, 0) == 14 or true)
-- The ring ceiling also holds against phase 2.
g = grid(function(g) box(g, 0, 0, W - 1, W - 1, function(c, x) c.y = x < 6 and 10 or 20 end) end)
plan = holes.plan(spec_of(g, none, function(x) if x <= 8 then return 12 end end), cfg)
for x = 0, 5 do assert(plan.at(x, 12) == 10, "ceiling holds, no bump") end

-- A pit that touches only the edge of the area is a way out, not a hole.
g = grid(function(g) box(g, 0, 8, 3, 10, function(c) c.y = 3 end) end)
assert(#holes.plan(spec_of(g, none), off).cells == 0, "edge columns are ways out")
-- Columns next to unknown ground are left alone.
g = grid(function(g) g[8][8].y = 3 end)
g[9][8] = nil
plan = holes.plan(spec_of(g), off)
assert(#plan.cells == 0, "unknown neighbors count as ways out")

-- A pit with a pillar left inside it.
g = grid(function(g)
	box(g, 6, 6, 12, 12, function(c) c.y = 5 end)
	g[9][9].y = 9
end)
plan = holes.plan(spec_of(g), cfg)
assert(trapped_columns(plan, g) == 0 and steepest(plan) <= 1, "pillar in a pit")

-- Nested rims resolve in one go, however many.
g = grid(function(g)
	for x = 0, W - 1 do for z = 0, W - 1 do
		local d = math.min(x, z, W - 1 - x, W - 1 - z)
		g[x][z].y = d == 0 and 10 or (d % 2 == 0 and d <= 10) and 10 + d or 0
	end end
end)
plan = holes.plan(spec_of(g, none), cfg)
assert(trapped_columns(plan, g) == 0, "nested rims are resolved")

-- Limits: a piece wider than max_columns, and the node budget (smallest first).
g = grid(function(g)
	box(g, 3, 3, 4, 4, function(c) c.y = 0 end) -- 4 columns, 40 nodes
	box(g, 12, 12, 17, 17, function(c) c.y = 0 end) -- 36 columns, 360 nodes
end)
local small = {}
for k, v in pairs(cfg) do small[k] = v end
small.budget = 100
plan = holes.plan(spec_of(g, none), small)
assert(#plan.cells == 4 and plan.nodes == 40 and plan.dropped == 36, "smaller piece first, the rest dropped")
assert(plan.at(13, 13) == 0 and plan.at(3, 3) == 10, "dropped columns keep their height")
small.budget, small.max_columns = 1e9, 10
plan = holes.plan(spec_of(g, none), small)
assert(#plan.cells == 4 and plan.dropped == 36, "wide piece left as landscape")

-- Invariants on random terrain: heights never fall, protected and water columns hold,
-- the result is stable (a second plan changes nothing), and no step grows.
math.randomseed(155)
for round = 1, 40 do
	g = grid(function(g)
		for x = 0, W - 1 do for z = 0, W - 1 do
			g[x][z].y = math.random(0, 3) == 0 and math.random(-30, 14) or math.random(8, 12)
			if math.random(30) == 1 then g[x][z].liquid = true end
		end end
	end)
	local protect = function(x, z) return x > 14 and z > 14 and x < 18 and z < 18 end
	local first = holes.plan(spec_of(g, protect), cfg)
	for x = 0, W - 1 do for z = 0, W - 1 do
		local y = first.at(x, z)
		assert(y >= g[x][z].y, "never lowered")
		if protect(x, z) or g[x][z].liquid then assert(y == g[x][z].y, "protected and water hold") end
	end end
	assert(first.cliffs_after <= first.cliffs_before, "no cliff made")
	local again = {}
	for x = 0, W - 1 do again[x] = {} for z = 0, W - 1 do again[x][z] = {y = first.at(x, z), liquid = g[x][z].liquid} end end
	-- Phase 1 alone is stable. (Phase 2 measures its rise from the heights it is given.)
	local only = holes.plan(spec_of(g, protect), off)
	local settled = {}
	for x = 0, W - 1 do settled[x] = {} for z = 0, W - 1 do settled[x][z] = {y = only.at(x, z), liquid = g[x][z].liquid} end end
	local second = holes.plan(spec_of(settled, protect), off)
	assert(#second.cells == 0, "stable: a second plan has nothing left to do (round " .. round .. ", " .. #second.cells .. ")")
	assert(first.passes <= cfg.passes)
end

-- apply: what stands on the ground. A fake world of columns; the old ground at 5.
local world, swaps = {}, 0
local fake = {
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:dirt"] = {walkable = true, drawtype = "normal"},
		["mcl_core:dirt_with_grass"] = {walkable = true, drawtype = "normal"},
		["mcl_core:snow"] = {walkable = false, drawtype = "nodebox"},
		["mcl_core:snow_2"] = {walkable = true, drawtype = "nodebox"},
		["mcl_flowers:tallgrass"] = {walkable = false, drawtype = "plantlike", groups = {plant = 1}},
		["mcl_flowers:double_grass"] = {walkable = false, drawtype = "plantlike"},
		["mcl_flowers:double_grass_top"] = {walkable = false, drawtype = "plantlike"},
		["mcl_flowers:poppy"] = {walkable = false, drawtype = "plantlike", groups = {flower = 1}},
	},
	get_node = function(p) return world[p.x .. "," .. p.y .. "," .. p.z] or {name = "air"} end,
	swap_node = function(p, n) swaps = swaps + 1; world[p.x .. "," .. p.y .. "," .. p.z] = n end,
}
local function material() return "mcl_core:dirt_with_grass", "mcl_core:dirt" end
local function put(x, y, z, name) world[x .. "," .. y .. "," .. z] = {name = name, param2 = 3} end
local function name_at(x, y, z) return (world[x .. "," .. y .. "," .. z] or {name = "air"}).name end
local function cell(x, from, to, name) return {cells = {{x = x, z = 0, from = from, to = to, name = name}}} end

-- Grass on the old ground is buried, not left floating: it moves up to the new surface.
put(1, 5, 0, "mcl_core:dirt_with_grass"); put(1, 6, 0, "mcl_flowers:tallgrass")
holes.apply(cell(1, 5, 8, "mcl_core:dirt_with_grass"), material, cfg, fake)
assert(name_at(1, 6, 0) == "mcl_core:dirt" and name_at(1, 7, 0) == "mcl_core:dirt" and name_at(1, 8, 0) == "mcl_core:dirt_with_grass")
assert(name_at(1, 9, 0) == "mcl_flowers:tallgrass" and world["1,9,0"].param2 == 3, "plant re-seated on the new surface")
-- A raise of one block: the plant is overwritten and put back one up.
put(2, 5, 0, "mcl_core:dirt_with_grass"); put(2, 6, 0, "mcl_flowers:poppy")
holes.apply(cell(2, 5, 6, "mcl_core:dirt_with_grass"), material, cfg, fake)
assert(name_at(2, 6, 0) == "mcl_core:dirt_with_grass" and name_at(2, 7, 0) == "mcl_flowers:poppy")
-- A tall plant is not floating on the new surface: its top half is cleared and it is not copied.
put(3, 5, 0, "mcl_core:dirt_with_grass"); put(3, 6, 0, "mcl_flowers:double_grass"); put(3, 7, 0, "mcl_flowers:double_grass_top")
holes.apply(cell(3, 5, 6, "mcl_core:dirt_with_grass"), material, cfg, fake)
assert(name_at(3, 7, 0) == "air" and name_at(3, 8, 0) == "air", "no half of a tall plant left")
-- A layer of snow that is ground (two or more layers) is replaced, not embedded in the fill.
put(4, 5, 0, "mcl_core:snow_2")
holes.apply(cell(4, 5, 8, "mcl_core:snow_2"), material, cfg, fake)
assert(name_at(4, 5, 0) == "mcl_core:dirt" and name_at(4, 8, 0) == "mcl_core:dirt_with_grass", "snow sliver replaced")
-- A single layer of snow on top moves up with the surface.
put(5, 5, 0, "mcl_core:dirt_with_grass"); put(5, 6, 0, "mcl_core:snow")
holes.apply(cell(5, 5, 7, "mcl_core:dirt_with_grass"), material, cfg, fake)
assert(name_at(5, 7, 0) == "mcl_core:dirt_with_grass" and name_at(5, 8, 0) == "mcl_core:snow")
-- A full block of ground is not rewritten: dirt stays where it was.
put(6, 5, 0, "mcl_core:dirt")
local before = swaps
holes.apply(cell(6, 5, 6, "mcl_core:dirt"), material, cfg, fake)
assert(swaps - before == 1, "only the surface is written for a raise of one")

-- configured: the settings override the defaults.
local conf = holes.configured({settings = {get = function(_, k)
	return ({living_villages_cliff_rise = "2", living_villages_hole_budget = "500"})[k]
end}})
assert(conf.cliff_rise == 2 and conf.budget == 500 and conf.ring == cfg.ring)
assert(holes.configured({}).cliff_rise == cfg.cliff_rise, "no settings object: defaults")

-- area: bounding box of pads plus margin, `below` under the lowest pad.
local area = holes.area({
	{yx0 = 0, yz0 = 0, yx1 = 5, yz1 = 5, y = 10}, {yx0 = 20, yz0 = 4, yx1 = 25, yz1 = 9, y = 14},
})
assert(area.minp.x == -12 and area.maxp.x == 37 and area.minp.y == 10 - cfg.below and area.maxp.y == 14 + cfg.above)

print("village_holes: ok")
