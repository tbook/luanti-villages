-- Well watch (#11): during a census, record what the villagers do about the village
-- well. Samples every 2 s and summarizes: wells found by living_villages' own
-- detection, which villagers set off for one, arrived, and left, the most at a well
-- at once, and any villager seen above the ground level beside a well (on its steps or
-- rim). It also watches conversations (conversation.lua, #242): groups formed with their
-- sizes and hold times, and whether anyone who left one stayed put afterwards (frozen).
-- Read-only; runs only when living_villages has well.lua.
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
	local groups, talkers = {}, {}
	-- The bell gathering (#127, #246): villagers that took a bell, that arrived at it, that gave it up,
	-- and the bell-stage samples spent walking to a workstation instead (vanilla's job search).
	local bell_ids = {}
	local bell = {samples = 0, job_walk_samples = 0, bound = 0, arrived = 0, gave_up = 0}
	-- lv_probe_gather = 1: at the first sample move the adults together onto open ground
	-- about the first one, 2 nodes apart, so conversations can form in a village whose
	-- few villagers would never stand near each other. The remaining watch is unchanged.
	local function open_ground(p)
		local function free(y) local n = core.registered_nodes[core.get_node(vector.new(p.x, y, p.z)).name]; return n and not n.walkable end
		local floor = core.registered_nodes[core.get_node(vector.new(p.x, p.y - 1, p.z)).name]
		return free(p.y) and free(p.y + 1) and floor and floor.walkable
	end
	local function gather()
		local adults = {}
		for _, object in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = object:get_luaentity()
			if e and e.name == "mobs_mc:villager" and e._id and not e.child then adults[#adults + 1] = object end
		end
		if #adults < 2 then return end
		local base = vector.round(adults[1]:get_pos())
		local cells = {}
		for dx = -6, 6, 2 do
			for dz = -6, 6, 2 do
				local c = {x = base.x + dx, y = base.y, z = base.z + dz}
				if open_ground(c) then cells[#cells + 1] = c end
			end
		end
		for i, object in ipairs(adults) do
			if cells[i] then object:set_pos(cells[i]) end
		end
		summary.gathered = math.min(#adults, #cells)
	end
	local function sample()
		if not running then return end
		if elapsed == 0 and core.settings:get("lv_probe_gather") == "1" then gather() end
		-- lv_probe_well_all = 1: every adult rolls to go to the well today (well.lua), so several
		-- visit it by their own walks and stand about it for their stay
		-- ...and again every 30 s for those who have left, so that a long watch sees many stays.
		if elapsed % 30 == 0 and core.settings:get("lv_probe_well_all") == "1" then
			for _, object in ipairs(core.get_objects_inside_radius(center, radius)) do
				local e = object:get_luaentity()
				if e and e.name == "mobs_mc:villager" and e._id and not e.child and not e._villages_well then
					e._villages_well_day, e._villages_well_going = core.get_day_count(), true
				end
			end
		end
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
				local talker = talkers[e._id]
				if not e.child then
					summary.adult_samples = (summary.adult_samples or 0) + 1
					if e.state == "stand" then summary.stand_samples = (summary.stand_samples or 0) + 1 end
				end
				if e._villages_talk then
					local group = e._villages_talk.group
					groups[group] = groups[group] or {size = group.size, first = elapsed}
					groups[group].last = elapsed
					talker = talker or {}
					-- Facing (engine yaw against the others' mean position), after 4 s of talking.
					local sum_x, sum_z, n = 0, 0, 0
					for _, m in ipairs(group.members) do
						if m ~= e and m.object:get_pos() then
							local mp = m.object:get_pos()
							sum_x, sum_z, n = sum_x + mp.x, sum_z + mp.z, n + 1
						end
					end
					if n > 0 and elapsed - groups[group].first >= 4 then
						local want = math.atan2(-(sum_x / n - pos.x), sum_z / n - pos.z)
						local err = math.abs((object:get_yaw() - want + math.pi) % (2 * math.pi) - math.pi)
						summary.yaw_error_max = math.max(summary.yaw_error_max or 0, round1(err))
						summary.yaw_samples = (summary.yaw_samples or 0) + 1
					end
					talkers[e._id] = talker
					talker.talking, talker.last_pos = true, pos
					summary.talking = (summary.talking or 0) + 1
				elseif talker and talker.talking then
					talker.talking, talker.left_at, talker.left_pos = false, elapsed, pos
				elseif talker and talker.left_pos and vector.distance(pos, talker.left_pos) > 0.5 then
					talker.moved = true
				end
				if e._villages_bell_skipped and next(e._villages_bell_skipped) then
					bell_ids[e._id] = bell_ids[e._id] or {}
					bell_ids[e._id].gave_up = true
				end
				if e._villages_bell then
					local record = bell_ids[e._id] or {}
					bell_ids[e._id] = record
					record.bound = true
					if e._villages_bell.arrived then record.arrived = record.arrived or elapsed end
					bell.samples = bell.samples + 1
					local search = e._villages_job_search_route
					if e.state == "gowp" and search and search.status == "travelling" then
						bell.job_walk_samples = bell.job_walk_samples + 1
					end
				end
				if e._villages_well then
					bound = bound + 1
					if record and record.left_at then
						summary.old = summary.old or {}
						summary.old[#summary.old + 1] = record
						record = nil
					end
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
				if e._villages_talk and record and record.arrived_at and not record.left_at then record.talked = true end
				for _, well in ipairs(list) do
					local d = math.sqrt((pos.x - well.center.x) ^ 2 + (pos.z - well.center.z) ^ 2)
					if d <= NEAR and math.abs(pos.y - well.water.y) <= 4 then
						near = near + 1
						if not e.child then
							local c = summary.at_well or {samples = 0, stand = 0, anchored = 0, partner_5 = 0, partner_5_stand = 0}
							summary.at_well = c
							c.samples = c.samples + 1
							if e.state == "stand" then c.stand = c.stand + 1 end
							if e._villages_wander_anchor then c.anchored = c.anchored + 1 end
							for _, other in ipairs(core.get_objects_inside_radius(pos, 5)) do
								local oe = other:get_luaentity()
								if oe and oe ~= e and oe.name == "mobs_mc:villager" and not oe.child then
									c.partner_5 = c.partner_5 + 1
									if oe.state == "stand" and e.state == "stand" then c.partner_5_stand = c.partner_5_stand + 1 end
									break
								end
							end
						end
					end
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
		local all = {}
		for _, record in pairs(ids) do all[#all + 1] = record end
		for _, record in ipairs(summary.old or {}) do all[#all + 1] = record end
		summary.old = nil
		for _, record in ipairs(all) do
			bound_n = bound_n + 1
			if record.arrived_at then arrived_n = arrived_n + 1 end
			if record.left_at then
				left_n = left_n + 1
				if record.talked then summary.stays_talked = (summary.stays_talked or 0) + 1 end
				stays[#stays + 1] = record.left_at - record.arrived_at
			end
		end
		local sizes, holds, left, frozen = {}, {}, 0, {}
		for _, group in pairs(groups) do
			sizes[group.size] = (sizes[group.size] or 0) + 1
			holds[#holds + 1] = group.last - group.first + SAMPLE
		end
		for id, talker in pairs(talkers) do
			if talker.left_at then
				left = left + 1
				-- Left a conversation 30 s or more before the end and never moved since.
				if not talker.moved and elapsed - talker.left_at >= 30 then frozen[#frozen + 1] = id:sub(1, 6) end
			end
		end
		summary.conversations = {groups = #holds, sizes = sizes, holds = holds, talkers = (function()
			local n = 0
			for _ in pairs(talkers) do n = n + 1 end
			return n
		end)(), left = left, still_talking = (function()
			local n = 0
			for _, talker in pairs(talkers) do if talker.talking then n = n + 1 end end
			return n
		end)(), frozen = frozen}
		for _, record in pairs(bell_ids) do
			if record.bound then bell.bound = bell.bound + 1 end
			if record.arrived then bell.arrived = bell.arrived + 1 end
			if record.gave_up then bell.gave_up = bell.gave_up + 1 end
		end
		if bell.samples > 0 or bell.gave_up > 0 then summary.bell = bell end
		summary.villagers_bound, summary.villagers_arrived, summary.villagers_left = bound_n, arrived_n, left_n
		summary.stays = stays
		return summary
	end
end

return wells
