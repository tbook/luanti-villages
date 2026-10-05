-- Reads a never-generated area before and after village_terrain.emerge, and
-- reports whether the read is refused first and succeeds after. Run with
-- tools/lv_probe/check_terrain.sh.
local core = minetest
local terrain = dofile(core.get_modpath("lv_terrain_check") .. "/village_terrain.lua")
local area = {minp = {x = 3000, y = -10, z = 3000}, maxp = {x = 3079, y = 70, z = 3079}}
local grass = {["mcl_core:dirt_with_grass"] = true, ["mcl_core:sand"] = true, ["mcl_core:podzol"] = true}

core.after(1, function()
	local before, why = terrain.heights(area, grass)
	core.log("action", "[lv_terrain_check] before emerge: " .. (before and "READ (unexpected)" or "refused: " .. why))
	terrain.emerge(area, function(ok, err)
		core.log("action", "[lv_terrain_check] emerge: " .. tostring(ok) .. " " .. tostring(err))
		local lookup, reason = terrain.heights(area, grass)
		local column = lookup and lookup(3040, 3040)
		core.log("action", "[lv_terrain_check] after emerge: " .. (lookup
			and ("read, center column y=" .. tostring(column and column.y) .. " " .. tostring(column and column.name))
			or "refused: " .. reason))
		core.request_shutdown("done", false, 0)
	end)
end)
