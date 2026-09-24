-- Shared, side-effect-free helpers used by villager behavior and diagnostics.
local core = minetest

return {
	is_sleep_time = function()
		local tod = core.get_timeofday() * 24000
		return tod > 17500 or tod < 6500
			or (mcl_weather and mcl_weather.get_weather
				and mcl_weather.get_weather() == "thunder")
	end,
}
