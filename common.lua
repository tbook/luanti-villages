-- Shared, side-effect-free helpers used by villager behavior and diagnostics.
local core = minetest

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
}
