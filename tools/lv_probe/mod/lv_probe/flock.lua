-- Flock census (#215): after a village is built, run the day of its shepherds. The time is
-- held at one hour after another (work, tavern, putter, work), a pretend player is moved
-- away and back to show the freeze, and every few seconds the record notes each
-- shepherd's stage, position and flock (count and distances). It also times the villager
-- and sheep do_custom calls so the cost of the flock logic can be read off. Only runs
-- when lv_probe_flock is set (seconds are ignored: the phases below are fixed).
-- lv_probe_flock_extra adds that many synthetic shepherds, each with a loom of its own.
local core = minetest

local flock = {}

local VILLAGER, SHEEP = "mobs_mc:villager", "mobs_mc:sheep"
local FREEZE_RANGE = 48

-- {name, time of day, seconds, pretend player: "near" or "away"}
local PHASES = {
	{"work", 0.33, 360, "near"},
	{"tavern", 0.66, 60, "near"},
	{"putter", 0.24, 60, "near"},
	{"work", 0.33, 120, "near"},
	{"frozen", 0.33, 60, "away"},
	{"work", 0.33, 60, "near"},
}

-- Other days, picked with lv_probe_flock_phases. A fifth field true makes the day a holiday.
local DAYS = {
	-- /time 20000 from the middle of the work stage, and from just before the tavern.
	night = {{"work", 0.33, 150, "near"}, {"sleep", 0.8333, 240, "near"}},
	night2 = {{"work", 0.625, 90, "near"}, {"sleep", 0.8333, 240, "near"}},
	holiday = {{"putter", 0.24, 90, "near", true}, {"church", 0.33, 150, "near", true},
		{"bell", 0.45, 90, "near", true}, {"tavern", 0.58, 60, "near", true}},
	-- Only the first work stage, to see whether a shepherd leaves its loom.
	work = {{"work", 0.33, 420, "near"}},
	-- Ten minutes out in the field (#249), then a jump to the tavern or to bed: do they get there?
	-- The sixth field "far": the phase ends once a shepherd has been 55+ from the village for 25 s.
	-- The return margin: out in the field, then the last 10 minutes of work (13200 ticks: 115 s before the end at time_speed 72), then the tavern.
	fieldreturn = {{"work", 0.33, 420, "near"}, {"work", 13200 / 24000, 110, "near"}, {"tavern", 0.66, 120, "near"}},
	-- A player in the village and the countryside not forced loaded (the #249 playtest).
	localplayer = {{"work", 0.33, 400, "centre"}},
	fieldtavern = {{"work", 0.33, 1200, "near", false, "far"}, {"tavern", 0.66, 300, "near"}},
	fieldsleep = {{"work", 0.33, 1200, "near", false, "far"}, {"sleep", 0.8333, 420, "near"}},
}
local days = DAYS[core.settings:get("lv_probe_flock_phases") or ""]
if days then PHASES = days end
local holiday_now = false

function flock.enabled()
	return (tonumber(core.settings:get("lv_probe_flock")) or 0) > 0
end

local player_pos
local costs = {shepherd = {n = 0, s = 0}, villager = {n = 0, s = 0}, sheep = {n = 0, s = 0}}

local function add_cost(kind, s)
	local c = costs[kind]
	c.n, c.s = c.n + 1, c.s + s
end

core.register_on_mods_loaded(function()
	if not flock.enabled() then return end
	local class = mcl_mobs.mob_class
	local original = class.player_in_active_range
	-- The server has no player, so mcl_mobs would freeze everything. Pretend there is one
	-- at player_pos (nil: everything is in range), and keep its real 48 node rule.
	class.player_in_active_range = function(self, ...)
		if self.name == VILLAGER or self.name == SHEEP then
			if not player_pos then return true end
			local p = self.object:get_pos()
			return p ~= nil and vector.distance(p, player_pos) <= FREEZE_RANGE
		end
		return original(self, ...)
	end
	-- No holiday: the probe moves the clock about, and the moon phase (day count and
	-- the time of day) would flip it between a working day and a holiday.
	if mcl_moon then mcl_moon.get_moon_phase = function() return holiday_now and 3 or 1 end end
	for _, name in ipairs({VILLAGER, SHEEP}) do
		local def = core.registered_entities[name]
		local custom = def.do_custom
		def.do_custom = function(self, dtime)
			if name == VILLAGER and self._profession == "shepherd" and core.settings:get_bool("lv_probe_flock_nobed", false) then
				self._bed = nil
			end
			local start = os.clock()
			local result = custom(self, dtime)
			local kind = name == SHEEP and "sheep" or (self._profession == "shepherd" and "shepherd" or "villager")
			add_cost(kind, os.clock() - start)
			return result
		end
	end
end)

local function flat(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end
local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

local function stage_of(common, e)
	return common and common.schedule_stage(nil, e) or "?"
end

-- N shepherds, each with a loom beside it, standing in the open about the centre.
local function add_shepherds(area, count)
	local added = {}
	local tries = 0
	while #added < count and tries < 4000 do
		tries = tries + 1
		local x = math.random(area.x1, area.x2)
		local z = math.random(area.z1, area.z2)
		for y = area.y2, area.y1, -1 do
			local node = core.get_node_or_nil({x = x, y = y, z = z})
			if node and node.name ~= "air" and node.name ~= "ignore" then
				local def = core.registered_nodes[node.name]
				local above = {x = x, y = y + 1, z = z}
				local loom = {x = x + 1, y = y + 1, z = z}
				if def and def.walkable and core.get_node(above).name == "air"
					and core.get_node({x = x, y = y + 2, z = z}).name == "air"
					and core.get_node(loom).name == "air" and core.get_node({x = x + 1, y = y + 2, z = z}).name == "air"
					and core.get_node({x = x + 1, y = y, z = z}).name ~= "air" then
					core.set_node(loom, {name = "mcl_loom:loom"})
					local obj = core.add_entity({x = x, y = y + 1, z = z}, VILLAGER)
					local e = obj and obj:get_luaentity()
					if e then
						e._profession = "shepherd"
						e._id = "probe-shepherd-" .. #added + 1
						e._jobsite = loom
						e._bed = {x = x, y = y + 1, z = z}
						core.get_meta(loom):set_string("villager", e._id)
						added[#added + 1] = e._id
					end
				end
				break
			end
		end
	end
	return added
end

-- lv_probe_flock_reach = true (#252): no day is run. From ground cells 15-80 nodes out of the village, in
-- sixteen directions, the planner searches for the village centre as navigation.lua does (the
-- same box, Manhattan heuristic) with a 4096 node budget (`game`), with the budget navigation.lua now
-- uses for the distance (`scaled`), and with one large enough to say whether a route exists at all
-- (`full`). One "reach" record: per start {status, nodes, steps, ms} of each.
function flock.reach(center, emit, done)
	local cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")
	local planner = dofile(core.get_modpath("living_villages") .. "/planner.lua")
	local function ground_at(x, z)
		for y = center.y + 40, center.y - 24, -1 do
			local n = core.get_node_or_nil({x = x, y = y, z = z})
			if n and n.name ~= "air" and n.name ~= "ignore" then
				local up = {x = x, y = y + 1, z = z}
				if cells.can_stand(up) then return up end
				return nil
			end
		end
	end
	-- The goal is a cell near the village's bell (the village floor; the topmost ground at the
	-- centre may be a hilltop).
	local goal
	local bells = {}
	for _, obj in ipairs(core.get_objects_inside_radius(center, 200)) do
		local e = obj:get_luaentity()
		if e and e.name == VILLAGER then bells[#bells + 1] = vector.round(obj:get_pos()) end
	end
	-- (the villagers about the village centre; the nearest one's surroundings give the goal)
	table.sort(bells, function(a, b) return flat(a, center) < flat(b, center) end)
	for _, bell in ipairs(bells) do
		for dx = -4, 4 do
			for dz = -4, 4 do
				for dy = -3, 1 do
					local c = {x = bell.x + dx, y = bell.y + dy, z = bell.z + dz}
					if not goal and cells.can_stand(c) then goal = c end
				end
			end
		end
	end
	assert(goal, "no cell to route to (" .. #(bells or {}) .. " bells)")
	-- navigation.lua's budget for a trip this far: 4096 up to 48 out, then with the square of the
	-- distance, to five times that.
	local function scaled_budget(start)
		local reach = math.abs(goal.x - start.x) + math.abs(goal.z - start.z)
		return math.floor(math.min(4096 * 5, math.max(4096, 4096 * (reach / 48) ^ 2)))
	end
	local rows = {}
	local function search(start, budget)
		local reach = math.max(math.abs(goal.x - start.x), math.abs(goal.y - start.y), math.abs(goal.z - start.z))
		local range = math.max(48, math.min(128, reach + 16))
		local began = os.clock()
		local path, visited, status = planner.find_path(start, cells.can_stand,
			function(p) return p.x == goal.x and p.y == goal.y and p.z == goal.z end,
			{range = range, max_nodes = budget, clear = cells.can_move,
				heuristic = function(p) return planner.heuristic(p, goal) end})
		return {status, visited, path and #path or nil, math.floor((os.clock() - began) * 1000)}
	end
	for _, r in ipairs({15, 30, 50, 60, 70, 80}) do
		for k = 0, 15 do
			local angle = k * math.pi / 8
			local start = ground_at(math.floor(center.x + math.cos(angle) * r + 0.5),
				math.floor(center.z + math.sin(angle) * r + 0.5))
			if start then
				rows[#rows + 1] = {r = r, k = k, start = {start.x, start.y, start.z},
					game = search(start, 4096), scaled = search(start, scaled_budget(start)),
					full = search(start, 200000)}
			end
		end
	end
	emit({type = "reach", goal = {goal.x, goal.y, goal.z}, rows = rows})
	return done()
end

-- Steps once a second through PHASES; emits one record when done.
function flock.run(area, emit, done)
	local minp = {x = area.x1, y = area.y1, z = area.z1}
	local maxp = {x = area.x2, y = area.y2, z = area.z2}
	local center = {x = (minp.x + maxp.x) / 2, y = (minp.y + maxp.y) / 2, z = (minp.z + maxp.z) / 2}
	local radius = math.max(maxp.x - minp.x, maxp.z - minp.z) / 2 + 40
	-- A stranded shepherd is 60-75 out: keep looking at it there.
	if PHASES[1][6] then radius = radius + 100 end
	local common = core.get_modpath("living_villages") and dofile(core.get_modpath("living_villages") .. "/common.lua")
	local extra = tonumber(core.settings:get("lv_probe_flock_extra")) or 0
	local added = extra > 0 and add_shepherds(area, extra) or {}
	core.log("action", "[lv_flock] synthetic shepherds added: " .. #added)
	local t, phase_index, phase_t, far_for = 0, 1, 0, 0
	local started_far = {}
	local samples, frozen = {}, {}
	local peak = {}
	local hazards = {wet = 0, hurt = 0, wet_sheep = 0, hurt_sheep = 0, events = {}}
	local sheep_seen = setmetatable({}, {__mode = "k"})
	local function round_pos(p) return {round1(p.x), round1(p.y), round1(p.z)} end
	local function add_event(event)
		if #hazards.events < 40 then hazards.events[#hazards.events + 1] = event end
	end
	local function scan()
		local shepherds, sheep_by = {}, {}
		for _, obj in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = obj:get_luaentity()
			if e and e.name == VILLAGER and e._profession == "shepherd" and e._id then
				-- Vanilla gives a bed only at night: a shepherd may have none by day.
				if nobed then e._bed = nil end
				shepherds[#shepherds + 1] = {e = e, pos = obj:get_pos()}
			elseif e and e.name == SHEEP and e._villages_shepherd then
				local list = sheep_by[e._villages_shepherd] or {}
				sheep_by[e._villages_shepherd] = list
				list[#list + 1] = obj:get_pos()
				-- Hurt or wet sheep: the pulled flock must not walk off ledges or into water (#248).
				-- hurt and wet are sheep-seconds; a sheep never heals, so one hurt sheep counts every
				-- second to the end. hurt_sheep and wet_sheep count each sheep once, and events says
				-- when and where (from is its position at the previous sample, old_y mcl_mobs' fall record).
				local p = obj:get_pos()
				local node = core.get_node_or_nil({x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), z = math.floor(p.z + 0.5)})
				local def = node and core.registered_nodes[node.name]
				local record = sheep_seen[e] or {hp = e.health, pos = p}
				sheep_seen[e] = record
				if def and (def.liquidtype or "none") ~= "none" then
					hazards.wet = hazards.wet + 1
					if not record.wet then
						record.wet, hazards.wet_sheep = true, hazards.wet_sheep + 1
						add_event({t = t, what = "wet", node = node.name, pos = round_pos(p), from = round_pos(record.pos)})
					end
				end
				if e.health and record.hp and e.health < record.hp then
					add_event({t = t, what = "hurt", hp = record.hp .. "->" .. e.health, pos = round_pos(p),
						from = round_pos(record.pos), old_y = e.old_y and round1(e.old_y)})
					if not record.hurt then record.hurt, hazards.hurt_sheep = true, hazards.hurt_sheep + 1 end
				end
				record.hp, record.pos = e.health, p
				if e.health and e.health < (e.initial_properties and e.initial_properties.hp_max or 8) then hazards.hurt = hazards.hurt + 1 end
			end
		end
		return shepherds, sheep_by
	end
	local nobed = core.settings:get_bool("lv_probe_flock_nobed", false)
	local function step()
		local phase = PHASES[phase_index]
		if not phase then
			local total = {}
			for kind, c in pairs(costs) do
				total[kind] = {calls = c.n, ms_per_call = c.n > 0 and round1(c.s / c.n * 1e4) / 10 or 0,
					total_ms = round1(c.s * 1000)}
			end
			emit({type = "flock", samples = samples, frozen = frozen, cost = total, synthetic = #added, peak = peak, hazards = hazards})
			player_pos = nil
			return done()
		end
		core.set_timeofday(phase[2])
		holiday_now = phase[5] and true or false
		player_pos = phase[4] == "away" and {x = center.x + 400, y = center.y, z = center.z} or nil
		if phase[4] == "centre" then player_pos = {x = center.x, y = center.y, z = center.z} end
		local shepherds, sheep_by = scan()
		-- The area's centre may be well above the ground; the player stands on it.
		if phase[4] == "centre" and shepherds[1] then player_pos.y = shepherds[1].pos.y end
		-- A "far" phase ends 25 s after the first shepherd has walked 55 or more from the village
		-- (or when its seconds are up): the jump then finds one really out in the field.
		if phase[6] == "far" then
			local out = false
			for _, s in ipairs(shepherds) do
				local id = s.e._id
				if started_far[id] == nil then started_far[id] = flat(s.pos, center) >= 55 end
				if not started_far[id] and flat(s.pos, center) >= 55 then out = true end
			end
			far_for = out and far_for + 1 or 0
			if far_for >= 25 then
				far_for = 0
				core.log("action", string.format("[lv_flock] t=%d a shepherd is out in the field: next phase", t))
				phase_t = phase[3]
			end
		end
		if t % 5 == 0 then
			local row = {t = t, phase = phase[1], shepherds = {}}
			local total = 0
			for _, s in ipairs(shepherds) do
				local flock_pos = sheep_by[s.e._id] or {}
				local d = {}
				for _, p in ipairs(flock_pos) do d[#d + 1] = round1(flat(p, s.pos)) end
				table.sort(d)
				total = total + #d
				row.shepherds[#row.shepherds + 1] = {
					id = s.e._id:sub(1, 22), stage = stage_of(common, s.e), pos = {round1(s.pos.x), round1(s.pos.y), round1(s.pos.z)},
					state = s.e.state, order = s.e.order, sheep = #d, d = d,
					loom = s.e._jobsite and round1(vector.distance(s.pos, s.e._jobsite)), bed = s.e._bed and round1(vector.distance(s.pos, s.e._bed)),
					sleeping = s.e._villages_sleeping or nil,
					route = s.e._villages_tavern_route and {s.e._villages_tavern_route.status, s.e._villages_tavern_route.reason,
						s.e._villages_tavern_route.planner and s.e._villages_tavern_route.planner.status,
						s.e._villages_tavern_route.planner and s.e._villages_tavern_route.planner.searched,
						-- Where the search got to (#252): how far the nearest cell it reached was from the goal,
						-- that cell, the start and the first target.
						s.e._villages_tavern_route.planner and s.e._villages_tavern_route.planner.closest_distance,
						s.e._villages_tavern_route.planner and s.e._villages_tavern_route.planner.closest and
							{round1(s.e._villages_tavern_route.planner.closest.x), round1(s.e._villages_tavern_route.planner.closest.y), round1(s.e._villages_tavern_route.planner.closest.z)},
						s.e._villages_tavern_route.planner and s.e._villages_tavern_route.planner.start and
							{round1(s.e._villages_tavern_route.planner.start.x), round1(s.e._villages_tavern_route.planner.start.y), round1(s.e._villages_tavern_route.planner.start.z)},
						s.e._villages_tavern_route.planner and s.e._villages_tavern_route.planner.candidates and s.e._villages_tavern_route.planner.candidates[1] and
							{round1(s.e._villages_tavern_route.planner.candidates[1].x), round1(s.e._villages_tavern_route.planner.candidates[1].y), round1(s.e._villages_tavern_route.planner.candidates[1].z)}} or nil,
					bedroute = s.e._villages_bed_route and {s.e._villages_bed_route.status, s.e._villages_bed_route.reason,
						s.e._villages_bed_route.planner and s.e._villages_bed_route.planner.status,
						s.e._villages_bed_route.planner and s.e._villages_bed_route.planner.searched} or nil,
				}
				peak[s.e._id] = math.max(peak[s.e._id] or 0, #d)
			end
			row.sheep = total
			samples[#samples + 1] = row
			core.log("action", string.format("[lv_flock] t=%d %s stage=%s shepherds=%d sheep=%d", t, phase[1],
				shepherds[1] and stage_of(common, shepherds[1].e) or "-", #shepherds, total))
		end
		-- The freeze: positions at the start and end of the frozen phase.
		if phase[1] == "frozen" then
			if phase_t == 1 then
				for _, s in ipairs(shepherds) do
					frozen[s.e._id] = {from = s.pos, sheep = sheep_by[s.e._id]}
				end
			elseif phase_t == phase[3] - 1 then
				for _, s in ipairs(shepherds) do
					local was = frozen[s.e._id]
					if was and was.from then
						local moved = flat(was.from, s.pos)
						local sheep_moved = 0
						for i, p in ipairs(sheep_by[s.e._id] or {}) do
							local q = was.sheep and was.sheep[i]
							if q then sheep_moved = math.max(sheep_moved, flat(p, q)) end
						end
						was.shepherd_moved, was.sheep_moved, was.from, was.sheep = round1(moved), round1(sheep_moved), nil, nil
					end
				end
			end
		end
		t, phase_t = t + 1, phase_t + 1
		if phase_t >= phase[3] then phase_index, phase_t = phase_index + 1, 0 end
		core.after(1, step)
	end
	-- A player would have the countryside about the village loaded (a shepherd walks out 60-75
	-- nodes): generate and force-load it first, or the far stops stand on unloaded ground.
	-- "centre" phases (lv_probe_flock_phases = localplayer): a player standing in the village, and
	-- the engine's find_nodes_in_area, which sees loaded blocks only, shown nothing beyond 40
	-- nodes of it, as in play, where the far corners of the village are often not loaded
	-- (unloading the blocks for real would also stop the entities in them).
	if PHASES[1][4] == "centre" then
		local real = core.find_nodes_in_area
		core.find_nodes_in_area = function(minp, maxp, names, grouped)
			local found, counts = real(minp, maxp, names, grouped)
			if grouped then return found, counts end
			local kept = {}
			for _, p in ipairs(found or {}) do
				if flat(p, center) <= 40 then kept[#kept + 1] = p end
			end
			return kept, counts
		end
		core.log("action", "[lv_flock] local player: find_nodes_in_area shows only 40 nodes about the village")
	end
	if not PHASES[1][6] then return core.after(1, step) end
	local lo = {x = center.x - 100, y = center.y - 24, z = center.z - 100}
	local hi = {x = center.x + 100, y = center.y + 40, z = center.z + 100}
	core.emerge_area(lo, hi, function(_, _, remaining)
		if remaining ~= 0 then return end
		for bx = math.floor(lo.x / 16), math.floor(hi.x / 16) do
			for by = math.floor(lo.y / 16), math.floor(hi.y / 16) do
				for bz = math.floor(lo.z / 16), math.floor(hi.z / 16) do
					core.forceload_block({x = bx * 16, y = by * 16, z = bz * 16}, true)
				end
			end
		end
		core.log("action", "[lv_flock] countryside loaded")
		if core.settings:get_bool("lv_probe_flock_reach", false) then return flock.reach(center, emit, done) end
		core.after(5, step)
	end)
end

return flock
