-- Run with: lua tests/paths.lua
local nodes, swaps = {}, {}
minetest = {
	get_node_or_nil = function(pos) return nodes[pos.x .. "," .. pos.y .. "," .. pos.z] and {name = nodes[pos.x .. "," .. pos.y .. "," .. pos.z]} end,
	swap_node = function(pos, node) nodes[pos.x .. "," .. pos.y .. "," .. pos.z] = node.name; swaps[#swaps + 1] = node.name end,
	hash_node_position = function(p) return p.x * 1000000 + p.y * 1000 + p.z end,
}
local paths = dofile("paths.lua")
paths.WEAR_UP, paths.WEAR_DOWN, paths.DECAY_PERIOD, paths.CAP = 3, 2, 100, 6

local GRASS, PATH = "mcl_core:dirt_with_grass", "mcl_core:grass_path"
local function check(cond, msg) if not cond then error(msg, 2) end end

-- Counts up to the threshold, then converts.
check(paths.walk(1, GRASS, 0) == nil, "1")
check(paths.walk(1, GRASS, 0) == nil, "2")
check(paths.walk(1, GRASS, 0) == "path", "3 converts")
-- Other nodes are never counted; unknown paths are never tracked.
check(paths.walk(2, "mcl_core:stone", 0) == nil)
check(paths.walk(3, PATH, 0) == nil)
check(paths.size() == 1, "only the walked grass is stored")

-- Walking on a tracked path keeps it alive and respects the cap.
for _ = 1, 10 do paths.walk(1, PATH, 0) end
local data = paths.serialize()
check(data[1][2] == 6, "capped")

-- Sweep: not faded enough -> kept; faded below WEAR_DOWN -> reverted.
nodes["0,0,1"] = PATH
local function get(h) return nodes["0,0," .. h] end
local function set(h, name) nodes["0,0," .. h] = name end
paths.sweep(300, get, set)       -- 6 - 3 = 3 >= 2
check(nodes["0,0,1"] == PATH, "still a path")
paths.sweep(500, get, set)       -- 6 - 5 = 1 < 2
check(nodes["0,0,1"] == GRASS, "regrown")
check(paths.size() == 0, "forgotten")

-- Unloaded block keeps its entry; replaced block drops it.
paths.reset()
for _ = 1, 3 do paths.walk(1, GRASS, 0) end
paths.sweep(10000, function() return nil end, set)
check(paths.size() == 1, "kept while unloaded")
paths.sweep(10000, function() return "mcl_core:stone" end, set)
check(paths.size() == 0, "dropped when replaced")

-- Faded grass counts are pruned and a revisit restarts from the faded value.
paths.reset()
paths.walk(5, GRASS, 0)
paths.walk(5, GRASS, 250)  -- faded to 0, then +1
check(paths.serialize()[1][2] == 1, "fade applied once")
paths.sweep(1000, get, set)
check(paths.size() == 0, "pruned")

-- Save and load round trip.
paths.reset()
for _ = 1, 3 do paths.walk(7, GRASS, 5) end
local copy = paths.serialize()
paths.load(copy)
check(paths.size() == 1 and paths.serialize()[1][4] == true, "round trip")

-- install: a villager is counted once per block entered.
paths.reset()
local def = {on_step = function() end}
paths.install(def)
local self = {pos = {x = 0, y = 5.5, z = 0}}
self.object = {get_pos = function() return self.pos end}
minetest.get_gametime = function() return 0 end
nodes["0,5,0"], nodes["1,5,0"] = GRASS, GRASS
for _ = 1, 5 do def.on_step(self, 0.1) end
check(paths.serialize()[1][2] == 1, "standing counts once")
self.pos = {x = 1, y = 5.5, z = 0}
def.on_step(self, 0.1)
check(paths.size() == 2, "second block counted")
print("paths: ok")

-- Visits just under one period apart still fade a period each time (review).
paths.reset()
for i = 0, 10 do paths.walk(9, GRASS, i * 80) end   -- period is 100
check(paths.serialize()[1][2] < 6, "partial periods are kept")
paths.reset()
local t = 0
for _ = 1, 40 do t = t + 150; paths.walk(9, GRASS, t) end
check(#paths.serialize() == 1 and paths.serialize()[1][4] == nil, "rare visits never wear a path")

-- A replaced path is not ours any more, even before it has faded.
paths.reset()
for _ = 1, 3 do paths.walk(1, GRASS, 0) end   -- converted, owned
nodes["0,0,1"] = GRASS                         -- player dug and regrew / replaced
paths.sweep(10, get, set)
check(paths.size() == 0, "sweep drops stale ownership")
for _ = 1, 3 do paths.walk(1, GRASS, 0) end
paths.changed(1)
check(paths.size() == 0, "dig or place drops tracking")
print("paths review: ok")

-- A step on a trip is worth more than one while wandering.
paths.reset()
paths.WEAR_UP, paths.CAP = 6, 12
check(paths.walk(1, GRASS, 0, 3) == nil, "one trip step is not enough")
check(paths.walk(1, GRASS, 0, 3) == "path", "two trip steps wear 6")
paths.reset()
for _ = 1, 5 do paths.walk(1, GRASS, 0) end
check(paths.walk(1, GRASS, 0) == "path", "six wander steps wear 6")
local trip_def = {on_step = function() end}
paths.reset()
paths.install(trip_def)
local walker = {pos = {x = 0, y = 5.5, z = 0}, _villages_job_route = {status = "travelling"}}
walker.object = {get_pos = function() return walker.pos end}
nodes["0,5,0"] = GRASS
trip_def.on_step(walker, 0.1)
check(paths.serialize()[1][2] == 3, "trip step weighs 3")
print("paths trips: ok")
