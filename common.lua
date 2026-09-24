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
	workstation_profession = function(name)
		return workstation_professions[name]
			or (core.get_item_group(name, "cauldron") > 0 and "leatherworker")
	end,
	workstation_search_nodes = function() return workstation_search_node_names end,
}
