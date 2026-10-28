-- Run with: lua tests/bed_start.lua
-- A villager standing on a bed top walks out of the room (#191). The adjusted
-- collision box (#311) fits under the large house's top-half slab ceiling, so
-- it can walk off the bed without being set down. The small house still works.
local scene = dofile("tests/support/stock_scene.lua")

local BED_TOP = 0.0625

-- Plans a route to the outdoor bed from a villager standing on the bed at `bed`
-- and returns the positions the villager was set at.
local function leave(name, rotation, doors_open, offset, mutate)
	local built = scene.build(name, rotation, doors_open)
	local world, size = built.world, built.size
	if mutate then mutate(built.world) end
	local def = {on_activate = function() end, do_custom = function() end, gopath = function() return false end}
	dofile("navigation.lua")(def)
	local results = {}
	for x = scene.ORIGIN, scene.ORIGIN + size.x - 1 do
		for y = 1, size.y - 1 do
			for z = scene.ORIGIN, scene.ORIGIN + size.z - 1 do
				local pos = {x = x, y = y, z = z}
				for _, half in ipairs({"bottom", "top"}) do
					if world.get(pos).name == "mcl_beds:bed_red_" .. half then
						local at = {x = x + (offset or 0), y = y + BED_TOP + 0.01, z = z}
						local placed = {}
						local entity = {
							_id = "v1", state = "stand",
							object = {
								get_pos = function() return {x = at.x, y = at.y, z = at.z} end,
								set_pos = function(_, p) table.insert(placed, p); at = p end,
								set_velocity = function() end,
							},
						}
						local target = built.beds.south
						entity._bed = target
						world.claim(target, "v1")
						world.timeofday = 0.8
						assert(def.gopath(entity, target, nil, true), "gopath refused")
						for _ = 1, 100000 do
							if (entity._villages_bed_route or {}).status ~= "planning" then break end
							for _, step in ipairs(world.globalsteps) do step(0.1) end
						end
						table.insert(results, {
							bed = pos, half = half, placed = placed, entity = entity, at = at,
						})
					end
				end
			end
		end
	end
	return results, world
end

-- Large house: the adjusted collision box clears the slab ceiling.
for rotation = 0, 3 do
	local results = leave("large_house", rotation, true)
	assert(#results == 4, "the large house has two beds, one above the other")
	for _, r in ipairs(results) do
		assert(#r.placed == 0, ("large house r%d bed %s: a villager that clears the ceiling is not moved")
			:format(rotation * 90, r.half))
		assert(r.entity.current_target and r.entity.waypoints, "a walk follows from the bed")
	end
end

-- Small house: a villager on the bed fits and walks off by itself.
for rotation = 0, 3 do
	for _, r in ipairs(leave("small_house", rotation, true)) do
		assert(#r.placed == 0, "a villager that fits on its bed is not moved")
	end
end

-- Near the edge of the bed top, the reduced collision height can clear the
-- slab from one side; if the body still reaches a neighboring ceiling, any
-- set-down must remain safe.
for rotation = 0, 3 do
	for _, offset in ipairs({-0.25, 0.25}) do
		local results, world = leave("large_house", rotation, false, offset)
		for _, r in ipairs(results) do
			if r.bed.y <= 3 then
				if #r.placed == 0 then
					assert(r.entity.current_target and r.entity.waypoints, "a walk follows from the bed edge")
				else
					assert(#r.placed == 1, "a cramped villager is set down only once")
					local p = r.placed[1]
					local cx, cz = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
					assert(not world.get({x = cx, y = r.bed.y, z = cz}).name:find("bed"), "set down on a bed")
					assert(p.y < r.bed.y, "set down at floor height")
				end
			end
		end
	end
end

-- Only a diagonal cell is open, across a corner: the villager is not carried
-- through the wall corner but left where it is.
local function wall_in(world)
	local roofed = false
	for x = 30, 42 do for y = 1, 3 do for z = 30, 42 do
		if not roofed and world.get({x = x, y = y, z = z}).name == "mcl_beds:bed_red_bottom" then
			world.set({x = x, y = y + 2, z = z}, "mcl_core:stone")
			roofed = true
		end
	end end end
	assert(roofed, "the lower bed has a low full-block ceiling")
	for x = 37, 38 do
		for z = 37, 38 do
			if not (x == 37 and z == 37) and world.get({x = x, y = 2, z = z}).name:find("carpet") then
				world.set({x = x, y = 2, z = z}, "mcl_core:cobble")
			end
		end
	end
end
local walled = leave("large_house", 0, true, 0, wall_in)
local cramped = 0
for _, r in ipairs(walled) do
	if r.bed.y <= 3 and r.half == "bottom" then
		cramped = cramped + 1
		assert(#r.placed == 0, "a villager is not set down through a wall corner")
		assert(r.entity.current_target, "a route from the diagonal cell exists, so the guard is what refused")
	end
end
assert(cramped == 1, "the walled-in bed was tested")

print("bed start tests passed")
