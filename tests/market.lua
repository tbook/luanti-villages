local root = debug.getinfo(1, "S").source:sub(2):match("(.*/)tests/") or "./"
local logs, day = {}, 12
local registered = {}

minetest = {
	get_modpath = function() return root end,
	get_day_count = function() return day end,
	registered_items = registered,
	log = function(_, message) logs[#logs + 1] = message end,
}

local market = dofile(root .. "market.lua")
local expected = {
	farmer = {"mcl_farming:bread", "mcl_core:apple"},
	fisherman = {"mcl_fishing:fish_cooked", "mcl_fishing:salmon_cooked"},
	fletcher = {"mcl_bows:arrow", "mcl_bows:bow"},
	shepherd = {"mcl_wool:white", "mcl_tools:shears"},
	librarian = {"mcl_books:book", "mcl_books:bookshelf"},
	cartographer = {"mcl_maps:empty_map", "mcl_itemframes:frame"},
	armorer = {"mcl_armor:helmet_iron", "mcl_armor:boots_iron"},
	leatherworker = {"mcl_armor:helmet_leather", "mcl_armor:boots_leather"},
	butcher = {"mcl_mobitems:cooked_porkchop", "mcl_mobitems:cooked_chicken"},
	weapon_smith = {"mcl_tools:axe_iron", "mcl_tools:sword_iron"},
	tool_smith = {"mcl_tools:pick_stone", "mcl_tools:shovel_stone"},
	cleric = {"mesecons:redstone", "mcl_core:lapis"},
	mason = {"mcl_core:brick", "mcl_core:stonebrick"},
}

for profession, pair in pairs(expected) do
	for _, item in ipairs(pair) do registered[item] = {} end
	local villager = {_profession = profession, _id = profession}
	local got = market.goods_for(villager, {})
	assert(got and got[1] == pair[1] and got[2] == pair[2], profession .. " goods match the supported VoxeLibre item names")
	assert(market.eligible(villager), profession .. " adult is eligible without trade initialization")
end

local farmer = {_profession = "farmer", _id = "f"}
registered["mcl_core:apple"] = nil
local pair = market.goods_for(farmer, {})
assert(pair[1] == "mcl_farming:bread" and pair[2] == pair[1], "one available item fills both frames")
registered["mcl_farming:bread"] = nil
assert(market.goods_for(farmer, {}) == nil, "no available item disables the stall")
registered["mcl_core:apple"] = {}
pair = market.goods_for(farmer, {})
assert(pair[1] == "mcl_core:apple" and pair[2] == pair[1], "available second item fills both frames")
registered["mcl_core:apple"] = nil

local unknown = {_profession = "modded_profession", _id = "u"}
local attempt = {}
assert(market.goods_for(unknown, attempt) == nil)
assert(market.goods_for(unknown, attempt) == nil)
assert(attempt.goods_fallback_logged and #logs == 2, "one missing-goods reason is logged per attempt")

local ok, reason = market.eligible({_profession = "farmer", _id = "child", child = true})
assert(not ok and reason == "child")
ok, reason = market.eligible({_profession = "farmer", _id = "keeper", _villages_keeper = true})
assert(not ok and reason == "keeper")
ok, reason = market.eligible({_profession = "unemployed", _id = "unemployed"})
assert(not ok and reason == "no_goods")
ok, reason = market.eligible({_profession = "nitwit", _id = "nitwit"})
assert(not ok and reason == "no_goods")
ok, reason = market.eligible({_profession = "modded_profession", _id = "unknown"}, {})
assert(not ok and reason == "no_goods")
ok, reason = market.eligible({_profession = "farmer", _id = "following", following = true})
assert(not ok and reason == "following")
ok, reason = market.eligible({_profession = "farmer", _id = "stocked", _villages_market_stock_day = day})
assert(not ok and reason == "already_stocked")

local fisherman = {_profession = "unemployed", _villages_fisherman = true, _id = "fisher"}
assert(market.profession(fisherman) == "fisherman", "stable fisherman flag masks vanilla transient demotion")
registered["mcl_core:apple"] = {}
registered["mcl_farming:bread"] = {}
assert(market.eligible(fisherman), "stable fisherman remains eligible after transient demotion")

local guarded = setmetatable({_profession = "farmer", _id = "guarded"}, {
	__index = function(_, key)
		assert(key ~= "_trades" and key ~= "_jobsite", "eligibility must not inspect trade or job claims")
	end,
})
assert(market.eligible(guarded), "eligibility does not depend on trades or claimed jobsites")

local function controller_fixture()
	local now, ticks = 100, 14000
	local site = {searches = 0, renewals = 0, releases = 0, valid_calls = 0}
	function site.begin_search(center, owner)
		site.searches = site.searches + 1
		site.owner = owner
		return {center = center, owner = owner}
	end
	function site.step_search(search)
		search.steps = (search.steps or 0) + 1
		if search.steps == 1 then return "pending" end
		return "found", site.reservation
	end
	function site.renew() site.renewals = site.renewals + 1; return true end
	function site.release() site.releases = site.releases + 1; return true end
	function site.valid() site.valid_calls = site.valid_calls + 1; return true end
	local reservation = {layout = {
		seller = {x = 4, y = 1, z = 5},
	}}
	site.reservation = reservation
	local cancelled = {}
	local nav = {cancel_goto = function(self, token)
		cancelled[#cancelled + 1] = token
		if self._villages_goto_route and self._villages_goto_route.market_token == token then
			self._villages_goto_route = nil
			self.state = "stand"
		end
		return true
	end}
	local target = {x = 4, y = 1, z = 5}
	local controller = market.new({site = site, props = {}, navigation = nav,
		now = function() return now end,
		ticks = function() return ticks end,
		standing_position = function() return target end,
		stage = function() return "bell" end})
	local bell = {center = {x = 0, y = 0, z = 0}, limit = 2}
	local self = {
		_id = "seller", _profession = "farmer",
		object = {get_pos = function() return target end},
		gopath = function(entity, _, callback)
			entity._villages_goto_route = {id = 17, status = "planning", market_token = entity._gopath_market_token}
			entity.arrival_callback = callback
			return true
		end,
	}
	-- Match navigation.lua's optional market route identity argument.
	local original_gopath = self.gopath
	self.gopath = function(entity, target_pos, callback, prioritised, token)
		entity._gopath_market_token = token
		return original_gopath(entity, target_pos, callback, prioritised, token)
	end
	return controller, site, nav, self, bell, cancelled, function(value) now = value end,
		function(value) ticks = value end
end

do
	local controller, site, _, seller, bell = controller_fixture()
	assert(controller.tick(seller, bell, 0) == "holding", "seller holds while bounded search is pending")
	assert(controller.tick(seller, bell, 0) == "walking", "seller begins normal goto after reservation")
	assert(site.searches == 1 and site.owner == seller._id, "search is created once for the prop owner")
	assert(controller.tick(seller, bell, 1) == "walking", "seller continues a planning route")
	assert(site.renewals == 1, "reservation renews while the seller travels")
	seller._villages_goto_route.status = "arrived"
	seller.arrival_callback(seller)
	assert(controller.tick(seller, bell, 0) == "holding", "arrival requires position and layout revalidation")
	assert(site.valid_calls == 1, "arrival validates reserved layout")
	controller.leave(seller, "test")
	assert(site.releases == 1, "leave releases the reservation")
end

do
	local controller, site, nav, seller, bell, cancelled = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session = seller._villages_market_session
	local late = seller.arrival_callback
	controller.leave(seller, "stage ended")
	late(seller)
	assert(not session.callback_arrived and seller._villages_market_session == nil,
		"pending arrival callback cannot revive a departed session")
	assert(cancelled[1] == session.id and site.releases == 1, "leave cancels only the market route and releases its claim")
	assert(controller.tick(seller, bell, 0) == "browse", "one activation never restarts an abandoned attempt")
end

do
	local controller, site, nav, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session = seller._villages_market_session
	seller._villages_goto_route = {id = 18, status = "travelling", market_token = "replacement"}
	assert(controller.tick(seller, bell, 3) == "browse", "replacement route aborts the market walk")
	assert(seller._villages_market_session == nil and site.releases == 1,
		"replaced route fallback releases the reservation")
	assert(seller._villages_goto_route.id == 18, "market cleanup preserves a replacement goto route")
	assert(session.route_id == 17, "market records the route identity it owns")
end

do
	local controller, _, _, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "travelling"
	seller._trading_players = {player = true}
	assert(controller.tick(seller, bell, 100) == "walking", "trading pauses the route deadline")
	seller._trading_players = nil
	seller._villages_job_search_route = {status = "travelling"}
	assert(controller.tick(seller, bell, 100) == "walking", "unrelated job search pauses the route deadline")
	seller._villages_job_search_route = nil
	assert(controller.tick(seller, bell, 3) == "browse", "an active market walk times out against bell's limit")
end

do
	local controller, site, _, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session = seller._villages_market_session
	seller._villages_goto_route = {id = 18, status = "planning", market_token = session.id}
	assert(controller.tick(seller, bell, 0) == "walking", "navigation replan keeps the same market session")
	assert(session.route_id == 18, "controller tracks the replacement planning route identity")
	seller._villages_goto_route.status = "arrived"
	seller.object.get_pos = function() return {x = 20, y = 1, z = 20} end
	assert(controller.tick(seller, bell, 3) == "browse", "an arrival far from its seller cell times out")
	assert(site.releases == 1, "bad arrival releases the reservation")
end

do
	local controller, site, _, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session = seller._villages_market_session
	seller._villages_goto_route = {id = 18, status = "arrived", market_token = session.id}
	seller.object.get_pos = function() return {x = 20, y = 1, z = 20} end
	seller._trading_players = {player = true}
	assert(controller.tick(seller, bell, 100) == "walking", "trading pauses late-arrival timeout")
	seller._trading_players = nil
	seller._villages_job_route = {status = "travelling"}
	assert(controller.tick(seller, bell, 100) == "walking", "another route pauses late-arrival timeout")
	seller._villages_job_route = nil
	assert(controller.tick(seller, bell, 3) == "browse", "unpaused late-arrival timeout eventually releases the stall")
	assert(site.releases == 1, "late-arrival timeout releases its reservation")
end

do
	local controller, site, _, seller, bell, _, _, set_ticks = controller_fixture()
	assert(controller.tick(seller, bell, 0) == "holding", "search begins before cutoff")
	set_ticks(14500)
	assert(controller.tick(seller, bell, 0) == "browse", "in-flight search stops at setup cutoff")
	assert(site.releases == 0, "pending search has no reservation to release")
end

do
	local controller, _, _, seller, bell = controller_fixture()
	seller._profession = "unknown"
	local before = #logs
	assert(controller.tick(seller, bell, 0) == "browse")
	assert(controller.tick(seller, bell, 0) == "browse")
	assert(#logs == before + 1, "unsupported goods fallback logs once per activation")
	assert(seller._villages_market_attempted, "unsupported seller is not rechecked during this activation")
end

do
	local controller, site, _, seller, bell, _, _, set_ticks = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	set_ticks(14500)
	assert(controller.tick(seller, bell, 0) == "browse", "late arrival skips stall setup")
	assert(site.valid_calls == 0, "late arrival does not validate or set up a stall")
end

print("market goods and eligibility tests passed")
