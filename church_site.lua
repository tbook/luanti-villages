-- Make most villages generate a church (#132). VoxeLibre's create_site_plan
-- (mcl_villages/buildings.lua) draws a random type at each position, so with
-- 10 to 25 buildings the church (max_num 0.04, at most one per village) only
-- appears if it happens to win a pick where its 15-node footprint fits.
--
-- Until a village has a church, this refuses every other building at the
-- distance check, so the first position with room for a church gets one. After
-- a few positions where the church does not fit, it gives up and lets the plan
-- carry on as usual. The church's own max_num still stops a second one.
local core = minetest

local GIVE_UP_AFTER = 8

local function wrap(settlements)
	local church
	for _, building in ipairs(settlements.schematic_table) do
		if building.name == "church" then church = building end
	end
	if not church then return false end

	local create_site_plan = settlements.create_site_plan
	local check_distance = settlements.check_distance
	local misses, planning

	function settlements.create_site_plan(...)
		misses, planning = 0, true
		local ok, plan = pcall(create_site_plan, ...)
		planning = false
		if not ok then error(plan, 0) end
		return plan
	end

	function settlements.check_distance(settlement_info, pos, hsize)
		if planning and misses < GIVE_UP_AFTER then
			for _, placed in ipairs(settlement_info) do
				if placed.name == "church" then return check_distance(settlement_info, pos, hsize) end
			end
			if hsize ~= church.hsize then return false end
			local fits = check_distance(settlement_info, pos, hsize)
			if not fits then misses = misses + 1 end
			return fits
		end
		return check_distance(settlement_info, pos, hsize)
	end
	return true
end

if settlements and settlements.schematic_table and settlements.create_site_plan
		and settlements.check_distance then
	if not wrap(settlements) then
		core.log("warning", "[living_villages] no church in the village building list; churches are not forced")
	end
end

return wrap
