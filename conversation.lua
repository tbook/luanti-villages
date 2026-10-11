-- Villagers converse (#242): two or three idle adults standing within a few nodes
-- of each other, as they do at the well (#11) and about the bell (#127), in
-- the putter and bell stages, now and then stop and face one another for
-- 8-25 s, then go on. Atmosphere only: they talk where they stand and walk to
-- nowhere, there is no animation for it (the model has stand, walk and sleep),
-- and nothing is saved or placed.
--
-- A villager that is standing, free of every other system's errand, rolls
-- CHANCE every few seconds; on a win it looks for idle neighbours within
-- RADIUS who can see it (line of sight) and, with one or two, starts a group
-- (at most MAX_GROUP). Tavern guests are never free (tavern.lua owns them for
-- the whole stage), so there is no tavern chatter. A member
-- holds like the church's (church.lua): order "stand" every tick (vanilla
-- clears it every few seconds), no do_states (which would turn it at random and
-- start it walking), and its yaw toward the others' mean position. The moment
-- another system takes a member (a route, a trade, a seat, the stage ending)
-- or the setting goes off, that member leaves; a group left with one ends.
-- Whoever leaves waits COOLDOWN before talking again. Well, bell and wander
-- anchors are left as they are: the group only stops the legs.
local core = minetest
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")

local STAGES = {putter = true, bell = true}
local SCAN_MIN, SCAN_MAX = 4, 8
local CHANCE = 0.1
local RADIUS = 5
local MAX_DY = 1.5
local EYE = 1.5
local MAX_GROUP = 3
local TRIO_CHANCE = 0.5
local HOLD_MIN, HOLD_MAX = 8, 25
local COOLDOWN_MIN, COOLDOWN_MAX = 60, 150
local TURN_DELAY = 6
-- A member pushed farther than this from the others leaves.
local STRAY = 2 * RADIUS
-- Saved with the villager by default; a conversation is this session's.
local FIELDS = {"_villages_talk", "_villages_talk_next", "_villages_talk_scan"}
-- Other systems' errands and holds, which a conversation never takes over. A new
-- hold that is not a route or a field below (e.g. a shepherd's herd, #243) must be added.
-- (_villages_door_entry is not one: navigation.lua leaves it set after a walk that ended at a door, and it
-- blocked every roll of such a villager for good, #242. A walk in progress is state "gowp" anyway.)
local BUSY = {
	"_villages_church", "_villages_seat", "_villages_seated_at", "_villages_meal", "_villages_tavern_target",
	"_villages_fish_session", "_villages_fish_target", "_villages_farm_target", "_villages_keeper_target",
	"_villages_follow", "_villages_keeper", "_villages_sleeping",
}
local ROUTES = {
	"_villages_bed_route", "_villages_job_route", "_villages_farm_route", "_villages_fish_route",
	"_villages_job_search_route", "_villages_tavern_route", "_villages_goto_route",
}
local ORDERS = {[""] = true, roam = true, stand = true}

local function now()
	return core.get_gametime()
end

-- Why rolls did not start a conversation, reported every REPORT_SECONDS (the
-- living_villages_conversation_report setting overrides it), so that a
-- playtest where nothing happened can be explained from debug.txt.
local REPORT_SECONDS = 600
local stats, next_report = {}, nil

local function count(what)
	stats[what] = (stats[what] or 0) + 1
end

local function report()
	local every = core.settings and tonumber(core.settings:get("living_villages_conversation_report")) or REPORT_SECONDS
	next_report = next_report or now() + every
	if now() < next_report then return end
	next_report = now() + every
	local names = {}
	for name in pairs(stats) do names[#names + 1] = name end
	table.sort(names)
	local parts = {}
	for _, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. stats[name] end
	core.log("action", string.format("[living_villages] conversation report (%d s): %s", every,
		#parts > 0 and table.concat(parts, " ") or "no rolls"))
	stats = {}
end

local function enabled()
	return not core.settings or core.settings:get_bool("living_villages_conversation", true)
end

local function trading(self)
	return self._trading_players and next(self._trading_players) ~= nil
end

local function alive(self)
	return self.object ~= nil and self.object:get_pos() ~= nil
end

-- Standing and free: an adult in a stage that idles, with no trip, route, seat,
-- trade or visit still on its way. Used to start a conversation and to keep one.
local function idle(self)
	if self.child or not self._id then return false, "child" end
	if self.following then return false, "following" end
	-- Standing, or between short legs about the well or bell (anchored wander legs, wander.lua),
	-- which are a villager's idling there and are stopped when it joins. Any other walk is an errand.
	if self.state ~= "stand" and not (self.state == "walk" and self._villages_wander_anchor) then
		return false, "walking"
	end
	if trading(self) then return false, "trading" end
	if not STAGES[common.schedule_stage(nil, self)] then return false, "stage" end
	if not ORDERS[self.order or ""] then return false, "order:" .. tostring(self.order) end
	for _, field in ipairs(BUSY) do
		if self[field] then return false, field end
	end
	for _, field in ipairs(ROUTES) do
		local route = self[field]
		if route and (route.status == "planning" or route.status == "travelling") then return false, field end
	end
	-- Heading for the well or bell, not yet about it.
	local well, bell = self._villages_well, self._villages_bell
	if (well and not well.arrived) or (bell and not bell.arrived) then return false, "not arrived" end
	return true
end

local function others_of(self, talk)
	local list = {}
	for _, member in ipairs(talk.group.members) do
		if member ~= self and alive(member) then list[#list + 1] = member end
	end
	return list
end

-- Leave the conversation; whoever is left with nobody to talk to leaves on its
-- next tick.
local function leave(self, reason)
	local talk = self._villages_talk
	if not talk then return end
	self._villages_talk = nil
	self._villages_talk_next = now() + COOLDOWN_MIN + math.random() * (COOLDOWN_MAX - COOLDOWN_MIN)
	-- The order the conversation set; one another wrapper set to "stand" this tick
	-- (the church's, the tavern's) is cleared for a tick and set again by it.
	if self.order == "stand" and not talk.was_standing then self.order = nil end
	local members = talk.group.members
	for i = #members, 1, -1 do
		if members[i] == self then table.remove(members, i) end
	end
	if #members < 2 then talk.group.over = true end
	count("ended:" .. reason)
	core.log("action", string.format("[living_villages] villager %s left a conversation of %d after %d s (%s)",
		tostring(self._id):sub(1, 6), talk.group.size, now() - talk.since, reason))
end

local function start(self, partners)
	local group = {members = {self}, size = #partners + 1, until_time = now() + HOLD_MIN + math.random() * (HOLD_MAX - HOLD_MIN)}
	for _, partner in ipairs(partners) do group.members[#group.members + 1] = partner end
	for _, member in ipairs(group.members) do
		member._villages_talk = {group = group, since = now(), was_standing = member.order == "stand"}
		-- Stop a wander leg: the state is what wander.lua and vanilla's states go by.
		member.order, member.state, member._villages_wander = "stand", "stand", nil
		member:set_velocity(0)
		member:set_animation("stand")
	end
	count("groups")
	local ids = {}
	for _, member in ipairs(group.members) do ids[#ids + 1] = tostring(member._id):sub(1, 6) end
	core.log("action", string.format("[living_villages] %d villagers (%s) began a conversation, for %d s",
		group.size, table.concat(ids, " "), group.until_time - now()))
end

-- Whether two villagers at a and b can see each other, eye to eye: not through a wall.
local function sees(a, b)
	if not core.line_of_sight then return true end
	return core.line_of_sight({x = a.x, y = a.y + EYE, z = a.z}, {x = b.x, y = b.y + EYE, z = b.z}) ~= false
end

-- Idle neighbours of self to talk with: nearest first, none more than RADIUS
-- from self (nor the second from the first).
local function find_partners(self, pos)
	local found, seen = {}, 0
	for _, object in ipairs(core.get_objects_inside_radius(pos, RADIUS)) do
		local other = object:get_luaentity()
		local other_pos = other and other ~= self and other.name == self.name and object:get_pos()
		if other_pos then
			seen = seen + 1
			local ok, why = true, nil
			if math.abs(other_pos.y - pos.y) > MAX_DY then ok, why = false, "height"
			elseif other._villages_talk then ok, why = false, "talking"
			elseif now() < (other._villages_talk_next or 0) then ok, why = false, "cooldown"
			else
				ok, why = idle(other)
				if ok and not sees(pos, other_pos) then ok, why = false, "sight" end
			end
			if ok then
				found[#found + 1] = {other = other, pos = other_pos, distance = vector.distance(pos, other_pos)}
			else
				count("near-not-free:" .. why)
			end
		end
	end
	table.sort(found, function(a, b) return a.distance < b.distance end)
	if #found == 0 then
		count(seen > 0 and "none-free" or "alone")
		return nil
	end
	local partners = {found[1].other}
	local second = found[2]
	if second and #partners + 1 < MAX_GROUP and math.random() < TRIO_CHANCE
		and vector.distance(found[1].pos, second.pos) <= RADIUS and sees(found[1].pos, second.pos) then
		partners[2] = second.other
	end
	return partners
end

-- Turn toward the others and stand. Returns false for do_custom to skip
-- vanilla's states, or nil when the conversation is over.
local function hold(self, talk, pos)
	local group = talk.group
	local others = others_of(self, talk)
	if group.over or #others == 0 or now() >= group.until_time then return nil end
	local x, z = 0, 0
	for _, other in ipairs(others) do
		local p = other.object:get_pos()
		x, z = x + p.x, z + p.z
		-- One that has climbed or dropped away can no longer see the others.
		if math.abs(p.y - pos.y) > MAX_DY then return nil end
	end
	x, z = x / #others - pos.x, z / #others - pos.z
	if x * x + z * z > STRAY * STRAY then return nil end
	-- Standing between the other two: face one of them.
	if x * x + z * z < 0.01 then
		local first = others[1].object:get_pos()
		x, z = first.x - pos.x, first.z - pos.z
	end
	self.order = "stand"
	self._villages_wander = nil
	self:set_velocity(0)
	self:set_animation("stand")
	-- A mob's forward is (-sin yaw, cos yaw) (church.lua).
	if x ~= 0 or z ~= 0 then self:set_yaw(atan2(-x, z), TURN_DELAY) end
	return false
end

local function install(def)
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_staticdata = def.get_staticdata
	local original_die = def.on_die

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		for _, field in ipairs(FIELDS) do self[field] = nil end
		return result
	end

	def.get_staticdata = function(self)
		local kept = {}
		for _, field in ipairs(FIELDS) do kept[field], self[field] = self[field], nil end
		local saved = original_staticdata(self)
		for _, field in ipairs(FIELDS) do self[field] = kept[field] end
		return saved
	end

	def.on_die = function(self, pos, cmi_cause)
		leave(self, "died")
		return original_die(self, pos, cmi_cause)
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		local talk = self._villages_talk
		if result == false then
			if talk then leave(self, "taken over") end
			return result
		end
		if talk then
			local pos = self.object:get_pos()
			if not enabled() then
				leave(self, "setting off")
			elseif pos and idle(self) then
				if hold(self, talk, pos) == false then return false end
				leave(self, "finished")
			else
				leave(self, "taken over")
			end
			return result
		end
		local scan = (self._villages_talk_scan or math.random() * SCAN_MAX) - dtime
		self._villages_talk_scan = scan
		if scan > 0 then return result end
		report()
		if now() < (self._villages_talk_next or 0) then return result end
		self._villages_talk_scan = SCAN_MIN + math.random() * (SCAN_MAX - SCAN_MIN)
		if not enabled() then return result end
		local free, why = idle(self)
		if not free then
			count("rolls-not-free:" .. why)
			return result
		end
		count("rolls-free")
		if math.random() >= CHANCE then return result end
		local pos = self.object:get_pos()
		local partners = pos and find_partners(self, pos)
		if partners then start(self, partners) else count("won-no-partner") end
		return result
	end
end

return {
	install = install,
	-- Exposed for tests.
	idle = idle,
	RADIUS = RADIUS,
	MAX_GROUP = MAX_GROUP,
	HOLD_MIN = HOLD_MIN,
	HOLD_MAX = HOLD_MAX,
	COOLDOWN_MIN = COOLDOWN_MIN,
	CHANCE = CHANCE,
	SCAN_MAX = SCAN_MAX,
}
