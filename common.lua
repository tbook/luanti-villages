-- Shared, side-effect-free helpers used by villager behavior and diagnostics.
local core = minetest
local workstation_nodes = {
	["mcl_composters:composter"] = true,
	["mcl_barrels:barrel_closed"] = true,
	["mcl_fletching_table:fletching_table"] = true,
	["mcl_loom:loom"] = true,
	["mcl_lectern:lectern"] = true,
	["mcl_cartography_table:cartography_table"] = true,
	["mcl_blast_furnace:blast_furnace"] = true,
	["mcl_smoker:smoker"] = true,
	["mcl_grindstone:grindstone"] = true,
	["mcl_smithing_table:table"] = true,
	["mcl_brewing:stand_000"] = true,
	["mcl_stonecutter:stonecutter"] = true,
}
local farm_replant_nodes = {
	["mcl_farming:wheat"] = "mcl_farming:wheat_1",
	["mcl_farming:potato"] = "mcl_farming:potato_1",
	["mcl_farming:carrot"] = "mcl_farming:carrot_1",
	["mcl_farming:beetroot"] = "mcl_farming:beetroot_0",
}

-- Used when a villager who has already traded loses a jobsite: it may seek
-- only a replacement for its existing profession.
local workstation_professions = {
	["mcl_composters:composter"] = "farmer",
	["mcl_barrels:barrel_closed"] = "fisherman",
	["mcl_fletching_table:fletching_table"] = "fletcher",
	["mcl_loom:loom"] = "shepherd",
	["mcl_lectern:lectern"] = "librarian",
	["mcl_cartography_table:cartography_table"] = "cartographer",
	["mcl_blast_furnace:blast_furnace"] = "armorer",
	["mcl_smoker:smoker"] = "butcher",
	["mcl_grindstone:grindstone"] = "weapon_smith",
	["mcl_smithing_table:table"] = "tool_smith",
	["mcl_brewing:stand_000"] = "cleric",
	["mcl_stonecutter:stonecutter"] = "mason",
}
local workstation_search_node_names = {"group:cauldron"}
for name in pairs(workstation_nodes) do table.insert(workstation_search_node_names, name) end

local function collision_box_top(def)
	local box = def and def.collision_box
	if not box or box.type ~= "fixed" then return 0.5 end
	local fixed = box.fixed
	if type(fixed) ~= "table" then return -0.5 end
	if type(fixed[1]) == "number" then return fixed[5] or -0.5 end
	local top = -0.5
	for _, part in ipairs(fixed) do
		if type(part) == "table" and type(part[5]) == "number" then top = math.max(top, part[5]) end
	end
	return top
end

local function is_open(pos)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	if not def then return false end
	return not def.walkable and (not def.collision_box or def.collision_box.type == "none")
		and (def.liquidtype == nil or def.liquidtype == "none")
end

local function is_supported(pos)
	local node = core.get_node_or_nil({x = pos.x, y = pos.y - 1, z = pos.z})
	local def = node and core.registered_nodes[node.name]
	if not def or not def.walkable then return false end
	-- A villager's feet rest on the top of the supporting node. Low slabs do not
	-- reach that height; fences and trapdoors are not walkable floor surfaces.
	if collision_box_top(def) < 0.49 then return false end
	if core.get_item_group(node.name, "fence") > 0 or core.get_item_group(node.name, "trapdoor") > 0 then
		return false
	end
	if (def.damage_per_second or 0) > 0 then return false end
	return core.get_item_group(node.name, "fire") == 0
		and core.get_item_group(node.name, "cactus") == 0
		and core.get_item_group(node.name, "dangerous") == 0
end

return {
	is_sleep_time = function()
		local tod = core.get_timeofday() * 24000
		return tod > 17500 or tod < 6500
			or (mcl_weather and mcl_weather.get_weather
				and mcl_weather.get_weather() == "thunder")
	end,
	is_work_time = function()
		if mcl_weather and mcl_weather.get_weather and mcl_weather.get_weather() == "thunder" then
			return false
		end
		local tod = core.get_timeofday() * 24000
		return (tod > 7500 and tod < 11000) or (tod > 13500 and tod < 16000)
	end,
	is_workstation_node = function(name)
		return workstation_nodes[name] or core.get_item_group(name, "cauldron") > 0
	end,
	farm_replant_node = function(name) return farm_replant_nodes[name] end,
	-- Whether a villager's full standing box fits at pos: two open nodes over a
	-- solid, non-hazardous floor. Checked before returning a villager to a
	-- position recorded earlier, since the world can change in between and a
	-- villager left inside an opaque node suffocates to death within seconds
	-- (mcl_mobs/physics.lua's do_env_damage).
	is_standing_space = function(pos)
		return is_open(pos) and is_open({x = pos.x, y = pos.y + 1, z = pos.z})
			and is_supported(pos)
	end,
	is_surface_water = function(pos)
		local node = core.get_node_or_nil(pos)
		local def = node and core.registered_nodes[node.name]
		if not def or def.liquidtype ~= "source" then return false end
		local above = core.get_node_or_nil({x = pos.x, y = pos.y + 1, z = pos.z})
		return above ~= nil and above.name == "air"
	end,
	workstation_profession = function(name)
		return workstation_professions[name]
			or (core.get_item_group(name, "cauldron") > 0 and "leatherworker")
	end,
	workstation_search_nodes = function() return workstation_search_node_names end,
}
