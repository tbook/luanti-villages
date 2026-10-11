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

-- Steps once a second through PHASES; emits one record when done.
function flock.run(area, emit, done)
	local minp = {x = area.x1, y = area.y1, z = area.z1}
	local maxp = {x = area.x2, y = area.y2, z = area.z2}
	local center = {x = (minp.x + maxp.x) / 2, y = (minp.y + maxp.y) / 2, z = (minp.z + maxp.z) / 2}
	local radius = math.max(maxp.x - minp.x, maxp.z - minp.z) / 2 + 40
	local common = core.get_modpath("living_villages") and dofile(core.get_modpath("living_villages") .. "/common.lua")
	local extra = tonumber(core.settings:get("lv_probe_flock_extra")) or 0
	local added = extra > 0 and add_shepherds(area, extra) or {}
	core.log("action", "[lv_flock] synthetic shepherds added: " .. #added)
	local t, phase_index, phase_t = 0, 1, 0
	local samples, frozen = {}, {}
	local peak = {}
	local hazards = {wet = 0, hurt = 0, max_hurt_sheep = 0}
	local function scan()
		local shepherds, sheep_by = {}, {}
		for _, obj in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = obj:get_luaentity()
			if e and e.name == VILLAGER and e._profession == "shepherd" and e._id then
				shepherds[#shepherds + 1] = {e = e, pos = obj:get_pos()}
			elseif e and e.name == SHEEP and e._villages_shepherd then
				local list = sheep_by[e._villages_shepherd] or {}
				sheep_by[e._villages_shepherd] = list
				list[#list + 1] = obj:get_pos()
				-- Hurt or wet sheep: the pulled flock must not walk off ledges or into water.
				local p = obj:get_pos()
				local node = core.get_node_or_nil({x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5), z = math.floor(p.z + 0.5)})
				local def = node and core.registered_nodes[node.name]
				if def and (def.liquidtype or "none") ~= "none" then hazards.wet = hazards.wet + 1 end
				if e.health and e.health < (e.initial_properties and e.initial_properties.hp_max or 8) then hazards.hurt = hazards.hurt + 1 end
				hazards.max_hurt_sheep = math.max(hazards.max_hurt_sheep, hazards.hurt)
			end
		end
		return shepherds, sheep_by
	end
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
		local shepherds, sheep_by = scan()
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
	core.after(1, step)
end

return flock
