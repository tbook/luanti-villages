-- Well watch (#11): during a census, record what the villagers do about the village
-- well. Samples every 2 s and summarizes: wells found by living_villages' own
-- detection, which villagers set off for one, arrived, and left, the most at a well
-- at once, and any villager seen above the ground level beside a well (on its steps or
-- rim). Read-only; runs only when living_villages has well.lua.
local core = minetest

local wells = {}

local SAMPLE = 2
local NEAR = 6.5
local RIM = 3.4

local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

function wells.available()
	local path = core.get_modpath("living_villages")
	local handle = path and io.open(path .. "/well.lua", "r")
	if handle then handle:close() end
	return handle ~= nil
end

-- Starts watching the area; returns finish(), which stops the watch and gives the summary.
function wells.watch(minp, maxp)
	local module = dofile(core.get_modpath("living_villages") .. "/well.lua")
	local center = {x = (minp.x + maxp.x) / 2, y = (minp.y + maxp.y) / 2, z = (minp.z + maxp.z) / 2}
	local radius = math.max(maxp.x - minp.x, maxp.z - minp.z, maxp.y - minp.y)
	local elapsed, running = 0, true
	local ids = {}
	local summary = {samples = 0, max_bound = 0, max_arrived = 0, max_near = 0, rim = {count = 0, samples = {}},
		first_arrival = nil, wells = {}}
	local function sample()
		if not running then return end
		elapsed = elapsed + SAMPLE
		summary.samples = summary.samples + 1
		for _, object in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = object:get_luaentity()
			if e and e.name == "mobs_mc:villager" and e._bed then module.scan(e._bed) end
		end
		local list = {}
		for _, well in pairs(module.wells) do list[#list + 1] = well end
		local bound, arrived, near = 0, 0, 0
		for _, object in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = object:get_luaentity()
			if e and e.name == "mobs_mc:villager" and e._id then
				local pos = object:get_pos()
				local record = ids[e._id]
				if e._villages_well then
					bound = bound + 1
					if not record then
						record = {bound_at = elapsed}
						ids[e._id] = record
					end
					if e._villages_well.arrived then
						arrived = arrived + 1
						record.arrived_at = record.arrived_at or elapsed
						summary.first_arrival = summary.first_arrival or elapsed
					end
				elseif record and record.arrived_at and not record.left_at then
					record.left_at = elapsed
				end
				for _, well in ipairs(list) do
					local d = math.sqrt((pos.x - well.center.x) ^ 2 + (pos.z - well.center.z) ^ 2)
					if d <= NEAR and math.abs(pos.y - well.water.y) <= 4 then near = near + 1 end
					local feet = math.floor(pos.y + 0.26 + 0.5)
					if d <= RIM and feet > well.stand_y then
						summary.rim.count = summary.rim.count + 1
						if #summary.rim.samples < 12 then
							summary.rim.samples[#summary.rim.samples + 1] = {
								t = elapsed, pos = {x = round1(pos.x), y = round1(pos.y), z = round1(pos.z)},
								d = round1(d), feet = feet, stand_y = well.stand_y, bound = e._villages_well ~= nil}
						end
					end
				end
			end
		end
		summary.max_bound = math.max(summary.max_bound, bound)
		summary.max_arrived = math.max(summary.max_arrived, arrived)
		summary.max_near = math.max(summary.max_near, near)
		core.after(SAMPLE, sample)
	end
	core.after(SAMPLE, sample)
	return function()
		running = false
		for _, well in pairs(module.wells) do
			summary.wells[#summary.wells + 1] = {water = well.water, stand_y = well.stand_y}
		end
		local bound_n, arrived_n, left_n, stays = 0, 0, 0, {}
		for _, record in pairs(ids) do
			bound_n = bound_n + 1
			if record.arrived_at then arrived_n = arrived_n + 1 end
			if record.left_at then
				left_n = left_n + 1
				stays[#stays + 1] = record.left_at - record.arrived_at
			end
		end
		summary.villagers_bound, summary.villagers_arrived, summary.villagers_left = bound_n, arrived_n, left_n
		summary.stays = stays
		return summary
	end
end

return wells
