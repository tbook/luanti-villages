-- Run with: lua tests/bed_start.lua
-- A villager standing on a bed top walks out of the room (#191). In the stock
-- large house the bed sits under a top-half slab ceiling 1.9375 above the
-- bed's top, and the villager is 1.95 tall: on the bed it does not fit, so it
-- cannot walk and every route from there ended 'no progress along the route'.
-- Such a villager is set down on the planner's start cell before the walk; one
-- that fits (the small house) walks off the bed as before.
local scene = dofile("tests/support/stock_scene.lua")

local BED_TOP = 0.0625

-- Plans a route to the outdoor bed from a villager standing on the bed at `bed`
-- and returns the positions the villager was set at.
local function leave(name, rotation, doors_open)
	local built = scene.build(name, rotation, doors_open)
	local world, size = built.world, built.size
	local def = {on_activate = function() end, do_custom = function() end, gopath = function() return false end}
	dofile("navigation.lua")(def)
	local results = {}
	for x = scene.ORIGIN, scene.ORIGIN + size.x - 1 do
		for y = 1, size.y - 1 do
			for z = scene.ORIGIN, scene.ORIGIN + size.z - 1 do
				local pos = {x = x, y = y, z = z}
				for _, half in ipairs({"bottom", "top"}) do
					if world.get(pos).name == "mcl_beds:bed_red_" .. half then
						local at = {x = x, y = y + BED_TOP + 0.01, z = z}
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

-- Large house: the slab ceiling is too low for the villager on the bed.
for rotation = 0, 3 do
	local results, world = leave("large_house", rotation, true)
	assert(#results == 4, "the large house has two beds, one above the other")
	for _, r in ipairs(results) do
		if r.bed.y > 3 then
			-- The upstairs bed has the roof well above it and needs no help.
			assert(#r.placed == 0, "a villager that fits on its bed is not moved")
		else
			assert(#r.placed == 1, ("large house r%d bed %s: villager must be set down off the bed, was set %d times")
				:format(rotation * 90, r.half, #r.placed))
			local p = r.placed[1]
			local cx, cz = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
			-- On the floor beside the bed: not on a bed, and below the bed's top.
			local node = world.get({x = cx, y = r.bed.y, z = cz}).name
			assert(not node:find("bed"), "set down on a bed: " .. node)
			assert(p.y < r.bed.y, "set down at the floor, not on the bed top: y " .. p.y)
			assert(r.entity.current_target and r.entity.waypoints, "a walk follows")
		end
	end
end

-- Small house: a villager on the bed fits and walks off by itself.
for rotation = 0, 3 do
	for _, r in ipairs(leave("small_house", rotation, true)) do
		assert(#r.placed == 0, "a villager that fits on its bed is not moved")
	end
end

print("bed start tests passed")
