-- Run with: lua tests/bell.lua
local time = 11000 / 24000
local now, day = 0, 4
local nodes = {}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local function parse(k)
	local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
	return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
end

vector = {
	distance = function(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end,
	round = function(a) return {x = math.floor(a.x + 0.5), y = math.floor(a.y + 0.5), z = math.floor(a.z + 0.5)} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return time end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_item_group = function() return 0 end,
	registered_nodes = {
		air = {walkable = false},
		["mcl_core:stone"] = {walkable = true},
		["mcl_bells:bell"] = {walkable = false},
	},
	log = function() end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	find_nodes_in_area = function(minp, maxp, names)
		local found = {}
		for k, name in pairs(nodes) do
			local p = parse(k)
			if name == names[1] and p.x >= minp.x and p.x <= maxp.x and p.y >= minp.y and p.y <= maxp.y
				and p.z >= minp.z and p.z <= maxp.z then
				table.insert(found, p)
			end
		end
		table.sort(found, function(a, b) return key(a) < key(b) end)
		return found
	end,
}

local function reset()
	nodes = {}
	for x = -30, 30 do
		for z = -30, 30 do nodes[key({x = x, y = -1, z = z})] = "mcl_core:stone" end
	end
end

local bell = dofile("bell.lua")
local gopaths, answer = {}, true
local cancelled_bell_routes = {}
local navigation_api = {
	cancel_goto = function(self, token)
		local route = self._villages_goto_route
		if not route or route.market_token ~= token then return false end
		self._villages_goto_route = nil
		cancelled_bell_routes[#cancelled_bell_routes + 1] = token
		if self.state == "gowp" and route.status == "travelling" then
			self.state = "stand"
			self._villages_follow, self._villages_follow_failed = nil, nil
		end
		return true
	end,
}
local def = {
	on_activate = function() end,
	do_custom = function() end,
	on_die = function() end,
	get_staticdata = function(self)
		local saved = {}
		for k, v in pairs(self) do if type(v) ~= "table" or k:match("^_villages") then saved[k] = v end end
		return saved
	end,
}
bell.install(def, nil, navigation_api)

local ids = 0
local function villager(x, z, extra)
	ids = ids + 1
	local pos = {x = x, y = -0.49, z = z}
	local self = {_id = "v" .. ids, state = "stand", _bed = {x = x, y = 0, z = z}}
	self.object = {
		get_pos = function() return pos end,
		set_velocity = function() end,
	}
	self.ready_to_path = function() return true end
	self.gopath = function(s, target, _callback, _prioritised, token)
		table.insert(gopaths, {self = s, target = target, token = token})
		if answer then
			s.state = "gowp"
			s._villages_goto_route = {status = "travelling", market_token = token}
		end
		return answer
	end
	self.pos = pos
	for k, v in pairs(extra or {}) do self[k] = v end
	return self
end

local function tick(self, times)
	for _ = 1, times or 1 do def.do_custom(self, 0.1) end
end

local function flat(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2) end

-- A bell hangs five nodes up, from a frame: villagers gather on the floor.
reset()
nodes[key({x = 10, y = 5, z = 0})] = "mcl_bells:bell"
local center = bell.center_of({x = 10, y = 5, z = 0})
assert(center.x == 10 and center.y == 0 and center.z == 0, "the gathering is on the floor below the bell")
nodes[key({x = 10, y = 0, z = 0})] = "mcl_core:stone"
assert(bell.center_of({x = 10, y = 1, z = 0}).y == 1, "a bell on the ground is gathered at in its own cell")
nodes[key({x = 10, y = 0, z = 0})] = nil

-- The nearest bell within reach is found; a far one is not.
nodes[key({x = -20, y = 5, z = 0})] = "mcl_bells:bell"
nodes[key({x = 10, y = 5, z = 0})] = "mcl_bells:bell"
local near_bell = bell.nearest_bell({_id = "x"}, {x = 0, y = 0, z = 0})
assert(near_bell.x == 10, "the nearest bell is chosen")
nodes[key({x = 10, y = 5, z = 0})] = nil
nodes[key({x = -20, y = 5, z = 0})] = nil
nodes[key({x = 60, y = 5, z = 0})] = "mcl_bells:bell"
assert(bell.nearest_bell({_id = "x"}, {x = 0, y = 0, z = 0}) == nil, "a bell beyond reach is not found")
nodes[key({x = 60, y = 5, z = 0})] = nil

-- In the Bell stage a villager walks to a spot of its own near the bell, and
-- villagers take different spots.
nodes[key({x = 10, y = 5, z = 0})] = "mcl_bells:bell"
math.randomseed(3)
local spots_taken = {}
for i = 1, 6 do
	local self = villager(-5, i)
	tick(self)
	local goal = gopaths[#gopaths]
	assert(goal and goal.self == self, "a villager sets off for the bell")
	local dist = flat(goal.target, center)
	assert(dist >= 1.5 - 1e-9 and dist <= bell.GATHER_RADIUS + 0.5, "its spot is near the bell")
	for _, other in ipairs(spots_taken) do
		assert(flat(other, goal.target) >= 1.5 - 1e-9, "villagers do not share a spot")
	end
	table.insert(spots_taken, goal.target)
	assert(self._villages_wander_anchor == nil, "no anchor until it arrives")
end

-- Arrived: its wander legs are kept about the bell.
local arrived = villager(11, 1)
tick(arrived)
assert(#gopaths == 6, "a villager already at the bell does not walk")
assert(arrived._villages_wander_anchor and arrived._villages_wander_anchor.radius == bell.GATHER_RADIUS
	and flat(arrived._villages_wander_anchor.pos, center) == 0, "arrival anchors its wander on the bell")
-- It is not saved with the villager.
assert(def.get_staticdata(arrived)._villages_wander_anchor == nil and arrived._villages_wander_anchor, "the gathering is not saved")

-- Pushed well out of the radius, it walks back.
arrived.pos.x = 10 + bell.GATHER_RADIUS + 3
local before = #gopaths
tick(arrived)
assert(#gopaths == before + 1 and arrived._villages_wander_anchor == nil, "a straying villager walks back")

-- The stage ends: the villager lets go.
local leaver = villager(11, -1)
tick(leaver)
assert(leaver._villages_wander_anchor)
time = 15000 / 24000
tick(leaver)
assert(leaver._villages_wander_anchor == nil and leaver._villages_bell == nil, "the Tavern stage releases the villager")
-- Stopped mid-walk, the follower's flag goes with the state (#230).
time = 11000 / 24000
local walker = villager(12, -1)
tick(walker)
walker.state, walker._villages_follow = "gowp", {final = {x = 0, y = 0, z = 0}}
walker._villages_goto_route = {status = "travelling", market_token = walker._villages_bell.walk_token}
time = 15000 / 24000
tick(walker)
assert(walker.state == "stand" and walker._villages_follow == nil, "the walk to the bell ends with its flag")
time = 11000 / 24000

-- Pushed out long after the original walk budget has run out: a fresh one.
local late = villager(11, 2)
tick(late)
assert(late._villages_wander_anchor)
now = now + 1000
late.pos.x = 10 + bell.GATHER_RADIUS + 3
before = #gopaths
tick(late)
assert(#gopaths == before + 1 and late._villages_bell, "a villager displaced late still walks back")

-- The bell taken down while it is attended: the gathering is dropped, and
-- another bell is found.
local witness = villager(11, 3)
tick(witness)
assert(witness._villages_wander_anchor)
nodes[key({x = 10, y = 5, z = 0})] = nil
nodes[key({x = -10, y = 5, z = 0})] = "mcl_bells:bell"
tick(witness)
assert(witness._villages_bell and witness._villages_bell.pos.x == -10
	and witness._villages_wander_anchor == nil, "a removed bell is replaced by another")
nodes[key({x = -10, y = 5, z = 0})] = nil
nodes[key({x = 10, y = 5, z = 0})] = "mcl_bells:bell"

-- A route another wrapper starts as the stage ends is left alone.
local handoff_def = {
	on_activate = function() end, on_die = function() end, get_staticdata = function() return {} end,
	do_custom = function(self)
		if minetest.get_timeofday() * 24000 >= 15000 and self.state ~= "gowp" then self.state = "gowp" end
	end,
}
bell.install(handoff_def, nil, navigation_api)
local guest = villager(11, 4)
tick(guest)
assert(guest._villages_wander_anchor)
time = 15000 / 24000
handoff_def.do_custom(guest, 0.1)
assert(guest.state == "gowp" and guest._villages_bell == nil, "the tavern's trip survives the stage change")
time = 11000 / 24000

-- Children and keepers have no gathering.
before = #gopaths
tick(villager(-5, 20, {child = true}))
tick(villager(-5, 21, {_villages_keeper = true}))
assert(#gopaths == before, "a child or a keeper does not go to the bell")

-- No bell in reach: it putters, and looks again later.
nodes[key({x = 10, y = 5, z = 0})] = nil
before = #gopaths
local lone = villager(-20, 0)
tick(lone, 5)
assert(#gopaths == before and lone._villages_wander_anchor == nil, "no bell leaves the villager to putter")
nodes[key({x = 10, y = 5, z = 0})] = "mcl_bells:bell"
now = now + 6
tick(lone)
assert(#gopaths == before + 1, "a bell turning up is walked to")

-- An unreachable bell is given up, and the villager putters.
local stuck = villager(-5, 25)
answer = false
tick(stuck, 3)
assert(stuck._villages_bell == nil and stuck._villages_wander_anchor == nil, "no route gives the bell up")
before = #gopaths
now = now + 6
tick(stuck, 3)
assert(#gopaths == before, "a bell passed over is not tried again at once")
answer = true

-- A villager that has arrived and is then walked off by its job search is not timed
-- against the bell walk (#246); one still on its way to the bell is, and a job search
-- that is only planning does not stop that clock.
local function seconds(self, count, step)
	for _ = 1, count do
		now = now + step
		def.do_custom(self, step)
	end
end
now = now + 1000
local hunter = villager(11, 4)
tick(hunter)
assert(hunter._villages_bell and hunter._villages_bell.arrived, "it arrives")
hunter.state = "gowp"
hunter._villages_job_search_route = {status = "travelling"}
seconds(hunter, 100, 1)
assert(hunter._villages_bell and not hunter._villages_bell.skipped, "an errand after arriving is not a late walk")
assert(hunter._villages_bell, "it still has the gathering")
hunter.state, hunter._villages_job_search_route = "stand", nil
tick(hunter)
assert(hunter._villages_bell.arrived and hunter._villages_wander_anchor, "back at the bell it gathers again")

local detour = villager(-5, 30)
tick(detour)
assert(detour._villages_bell and not detour._villages_bell.arrived)
detour._villages_job_search_route = {status = "travelling"}
seconds(detour, 100, 1)
assert(detour._villages_bell, "a job search interrupting the walk does not time it out")
detour._villages_job_search_route = nil
seconds(detour, 120, 1)
assert(detour._villages_bell == nil, "a walk of its own that goes nowhere is still given up")

-- Sellers share bell discovery but own movement while searching, walking and
-- holding a stall. Dispatch also runs during trade, and cleanup precedes the
-- inner wrapper that starts the tavern route.
local market_calls, market_leaves, renew_only_calls, inner_started = {}, {}, {}, false
local market_result = "walking"
local integration_def = {
	on_activate = function() end,
	on_deactivate = function() end,
	on_die = function() end,
	get_staticdata = function(self)
		local saved = {}
		for k, v in pairs(self) do if type(v) ~= "table" or k:match("^_villages") then saved[k] = v end end
		return saved
	end,
	do_custom = function(self)
		if self.planning_hold then return false end
		if minetest.get_timeofday() * 24000 >= 15000 and self.state ~= "gowp" then
			inner_started = true
			self.state = "gowp"
		end
	end,
}
bell.install(integration_def, {
	tick = function(self, session, dtime)
		market_calls[#market_calls + 1] = {self = self, session = session, dtime = dtime}
		return market_result
	end,
	leave = function(self, reason)
		market_leaves[#market_leaves + 1] = reason
		self._villages_market_session = nil
		self._villages_market_attempted = true
	end,
	renew_only = function(self, session)
		renew_only_calls[#renew_only_calls + 1] = {self = self, session = session}
	end,
}, navigation_api)
local seller = villager(10, 0)
seller.state = "gowp"
integration_def.do_custom(seller, 0.1)
seller._villages_market_session = {live = true}
seller.planning_hold = true
local routes_before_hold, regular_ticks_before_hold = #gopaths, #market_calls
assert(integration_def.do_custom(seller, 0.25) == false,
	"the wrapped role's planning hold remains false")
assert(#renew_only_calls == 1 and renew_only_calls[1].self == seller
	and renew_only_calls[1].session == seller._villages_bell,
	"a market seller renews its existing session during the underlying planning hold")
assert(#market_calls == regular_ticks_before_hold and #gopaths == routes_before_hold,
	"planning hold maintenance does not run the market tick or start a route")
seller._villages_market_session = nil
local renewals_before_unrelated_hold = #renew_only_calls
assert(integration_def.do_custom(seller, 0.25) == false
	and #renew_only_calls == renewals_before_unrelated_hold,
	"an unrelated false role hold without a market session has no market action")
seller.planning_hold = nil
assert(market_calls[1] and market_calls[1].session == seller._villages_bell,
	"seller controller receives the same discovered bell session")
assert(seller._villages_wander_anchor == nil and seller.state == "gowp",
	"seller route is not replaced by a browser anchor")
market_result = "holding"
seller._trading_players = {player = true}
seller.state = "stand"
integration_def.do_custom(seller, 0.5)
assert(#market_calls == 2 and market_calls[2].dtime == 0.5 and seller._villages_wander_anchor == nil,
	"seller lease is ticked during trading without browser movement")
market_result = "browse"
local trade_calls, paused_since = #gopaths, seller._villages_bell.since
integration_def.do_custom(seller, 1)
assert(#gopaths == trade_calls and seller._villages_wander_anchor == nil
	and seller._villages_bell.since == paused_since + 1,
	"a trading browser starts no route and pauses its bell walk deadline")
local browser_token = seller._villages_bell.walk_token
seller.state = "gowp"
seller._villages_goto_route = {status = "travelling", market_token = browser_token}
local browser_routes = #gopaths
integration_def.do_custom(seller, 0.1)
assert(seller.state == "stand" and seller._villages_goto_route == nil
	and cancelled_bell_routes[#cancelled_bell_routes] == browser_token,
	"a browser's own bell route is canceled when trade starts")
assert(#gopaths == browser_routes, "the browser does not replace its route during trade")
seller._trading_players = nil
seller.pos.x = 100
seller._villages_bell.spot = {x = 12, y = 0, z = 0}
seller._villages_bell.since, seller._villages_bell.limit = now, 1000
time = 11000 / 24000
seller._villages_job_search_route = {status = "planning"}
integration_def.do_custom(seller, 0.1)
assert(#gopaths == browser_routes and seller._villages_job_search_route.status == "planning",
	"resuming the bell does not replace a pending job search")
seller._villages_job_search_route = nil
seller._villages_goto_route = {status = "planning", market_token = "replacement"}
integration_def.do_custom(seller, 0.1)
assert(#gopaths == browser_routes and seller._villages_goto_route.market_token == "replacement",
	"resuming the bell does not replace a newer goto route")
seller._villages_goto_route = nil
integration_def.do_custom(seller, 0.1)
assert(#gopaths == browser_routes + 1 and gopaths[#gopaths].token == browser_token,
	"the browser route resumes after even a short trade")
seller._villages_market_session = {live = true, holding_order = true, previous_order = "roam"}
seller._villages_market_attempted = true
seller.order = "stand"
local static = integration_def.get_staticdata(seller)
assert(static._villages_market_session == nil and static._villages_market_attempted == nil
	and seller._villages_market_session.live and static.order == "roam" and seller.order == "stand",
	"market session is excluded, its prior order is saved, and the live hold is restored")
time = 15000 / 24000
integration_def.do_custom(seller, 0.1)
assert(market_leaves[1] == "bell session ended" and inner_started,
	"market cleanup runs before the tavern wrapper starts its route")
assert(seller._villages_market_attempted == nil, "departure clears the attempt for a later holiday")
seller._villages_market_session = {live = true}
integration_def.on_deactivate(seller, false)
assert(market_leaves[2] == "bell session ended", "deactivation cleans the market session")
time = 11000 / 24000
day = 8
local market_calls_before_new_holiday = #market_calls
integration_def.do_custom(seller, 0.1)
assert(#market_calls == market_calls_before_new_holiday + 1,
	"a seller gets a new market attempt at a later holiday")
local replacement = villager(10, 5)
integration_def.do_custom(replacement, 0.1)
local replacement_route = {status = "travelling", market_token = "tavern"}
replacement._villages_goto_route, replacement.state = replacement_route, "gowp"
time = 15000 / 24000
integration_def.do_custom(replacement, 0.1)
assert(replacement._villages_goto_route == replacement_route and replacement.state == "gowp",
	"bell cleanup preserves a replacement tavern route")
time = 11000 / 24000

print("ok")
