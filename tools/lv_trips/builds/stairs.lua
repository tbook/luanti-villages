-- Test staircases on a floating flat floor (ground node y=39, feet cell y=40).
local core = minetest
local X, Z0 = -2630, 240
local function set(x, y, z, name, p2) core.set_node({x = x, y = y, z = z}, {name = name, param2 = p2 or 0}) end
core.load_area({x = X - 12, y = 36, z = Z0 - 6}, {x = X + 14, y = 48, z = Z0 + 40})
for x = X - 12, X + 14 do for z = Z0 - 6, Z0 + 40 do
	for y = 36, 38 do set(x, y, z, "mcl_core:dirt") end
	set(x, 39, z, "mcl_core:dirt")
	for y = 40, 48 do set(x, y, z, "air") end
end end
local COBBLE, STAIR = "mcl_core:cobble", "mcl_stairs:stair_cobble"
-- Lane A (z = Z0): a two-step stair up (ascending +x) into a 2-high platform.
-- Lane B (z = Z0 + 10): the same, but the platform also flanks the top stair, flush with it,
--   so a villager leaving the top stair walks sideways onto a block.
-- Lane C (z = Z0 + 20): one stair in the open, a 1-high platform behind it.
local function lane(z, flank)
	set(X + 1, 40, z, STAIR, 1)
	set(X + 2, 40, z, COBBLE)
	set(X + 2, 41, z, STAIR, 1)
	for x = X + 3, X + 8 do for dz = -2, 2 do
		set(x, 40, z + dz, COBBLE); set(x, 41, z + dz, COBBLE)
	end end
	if flank then
		for _, dz in ipairs({-1, 1}) do set(X + 2, 40, z + dz, COBBLE); set(X + 2, 41, z + dz, COBBLE) end
	end
end
lane(Z0, false)
lane(Z0 + 10, true)
set(X + 1, 40, Z0 + 20, STAIR, 1)
for x = X + 2, X + 6 do for dz = -2, 2 do set(x, 40, Z0 + 20 + dz, COBBLE) end end
core.log("action", "[lv_trips] build64 done")
