-- Two-high doorway with carpet immediately inside (#311). Run against TownsPlaytest:
-- tools/lv_trips/run.sh TownsPlaytest -56,13,-7 doorway_carpet --stages work \
--   --spot -51,12.51,45:-48,13,45 --goto -43,13,45 --radius 128 \
--   --build tools/lv_trips/builds/doorway_carpet.lua
-- The fixture pins one villager to a short, real planner/follower route through
-- the carpet tile while leaving entity collision and engine movement enabled.
local core = minetest
local x0, z0, floor = -52, 45, 12
local owner
for _, object in ipairs(core.get_objects_inside_radius({x = -56, y = 13, z = -7}, 128)) do
	local entity = object:get_luaentity()
	if entity and entity.name == "mobs_mc:villager" and entity._bed
		and entity._bed.x == -48 and entity._bed.y == 13 and entity._bed.z == 45 then owner = entity end
end
if not owner then error("#311 fixture villager not found") end
-- Keep the schedule from replacing the explicit probe route after teleport.
owner.do_custom = function() end
local low, high = {x = x0 - 4, y = floor - 2, z = z0 - 3}, {x = -40, y = floor + 7, z = z0 + 3}
core.load_area(low, high)
for x = x0 - 4, -40 do
	for z = z0 - 3, z0 + 3 do
		for y = floor - 2, floor + 7 do
			local name = y == floor and "mcl_core:stone" or "air"
			core.set_node({x = x, y = y, z = z}, {name = name})
		end
	end
end
-- A narrow 2-high passage with a wooden door at x=-48. The carpet tile just
-- inside it and the roof at y=15 reproduce the 1/80-node head overlap.
for x = -51, -45 do
	for _, z in ipairs({z0 - 1, z0 + 1}) do
		core.set_node({x = x, y = floor + 1, z = z}, {name = "mcl_core:stone"})
		core.set_node({x = x, y = floor + 2, z = z}, {name = "mcl_core:stone"})
	end
	for z = z0 - 1, z0 + 1 do
		core.set_node({x = x, y = floor + 3, z = z}, {name = "mcl_core:stone"})
	end
end
core.set_node({x = -48, y = floor + 1, z = z0}, {name = "mcl_doors:wooden_door_b_1", param2 = 0})
core.set_node({x = -48, y = floor + 2, z = z0}, {name = "mcl_doors:wooden_door_t_1", param2 = 0})
core.set_node({x = -47, y = floor + 1, z = z0}, {name = "mcl_wool:red_carpet"})
core.log("action", "[lv_trips] #311 doorway fixture built")
