local root = debug.getinfo(1, "S").source:sub(2):match("(.*/)tests/") or "./"
local logs, day = {}, 12
local registered = {}
ItemStack = function(name)
	local resolved = name == "mesecons:redstone" and "mesecons:wire_00000000_off" or name
	return {
		is_empty = function() return false end,
		get_name = function() return resolved end,
	}
end

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
	cleric = {"mesecons:wire_00000000_off", "mcl_core:lapis"},
	mason = {"mcl_core:brick", "mcl_core:stonebrick"},
}
registered["mesecons:redstone"] = {}

for profession, pair in pairs(expected) do
	for _, item in ipairs(pair) do registered[item] = {} end
	local villager = {_profession = profession, _id = profession}
	local got = market.goods_for(villager, {})
	assert(got and got[1] == pair[1] and got[2] == pair[2], profession .. " goods match the supported VoxeLibre item names")
	assert(market.eligible(villager), profession .. " adult is eligible without trade initialization")
end
local cleric_goods = market.goods_for({_profession = "cleric", _id = "cleric-alias"}, {})
assert(cleric_goods[1] == "mesecons:wire_00000000_off",
	"item aliases are stored using the canonical ItemStack name")
local itemstack_constructor = ItemStack
ItemStack = nil
local fallback_goods = market.goods_for({_profession = "farmer", _id = "farmer-no-itemstack"}, {})
assert(fallback_goods[1] == "mcl_farming:bread",
	"registered goods retain their name when ItemStack is unavailable")
ItemStack = itemstack_constructor

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

registered["mcl_core:apple"] = {}
registered["mcl_farming:bread"] = {}
assert(market.saved_fields[1] == "_villages_market_stock_day",
	"the stock-day guard is the only market field integration saves")
assert(#market.transient_fields == 2
	and market.transient_fields[1] == "_villages_market_session"
	and market.transient_fields[2] == "_villages_market_attempted",
	"session and attempt fields are reset on activation")

local function controller_fixture()
	local now, ticks, real = 100, 14000, 1000
	local bell_node = {name = "mcl_bells:bell"}
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
	function site.renew(reservation) site.renewals = site.renewals + 1; return reservation ~= nil end
	function site.release() site.releases = site.releases + 1; return true end
	function site.valid() site.valid_calls = site.valid_calls + 1; return true end
	local reservation = {layout = {
		tables = {{x = 3, y = 0, z = 5}, {x = 3, y = 0, z = 6}},
		seller = {x = 4, y = 1, z = 5},
		outward = {x = 1, z = 0},
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
	local seller_velocity
	local props = {setups = 0, activations = 0, renewals = 0, cleanups = 0, frame_removals = 0}
	function props.setup(layout, owner, setup_day, items, reserved)
		props.setups = props.setups + 1
		props.owner, props.day, props.items = owner, setup_day, items
		if props.fail_setup then return nil, "injected failure" end
		return {token = "prop-token", owner = owner, day = setup_day, layout = layout}
	end
	function props.activate(stall, object, session, deadline, context)
		props.activations = props.activations + 1
		props.deadline = deadline
		props.context = context
		return not props.fail_activate
	end
	function props.renew(_, _, _, deadline)
		props.renewals = props.renewals + 1
		props.renewal_deadline = deadline
		return not props.fail_renew
	end
	function props.release() props.releases = (props.releases or 0) + 1 end
	function props.cleanup() props.cleanups = props.cleanups + 1; return true end
	function props.remove_frames() props.frame_removals = props.frame_removals + 1; return true end
	local controller = market.new({site = site, props = props, navigation = nav,
		now = function() return now end,
		real_now = function() return real end,
		day_count = function() return day end,
		random = function(low, high) return low end,
		ticks = function() return ticks end,
		get_node_or_nil = function() return bell_node end,
		standing_position = function() return target end,
		stage = function() return "bell" end})
	local bell = {pos = {x = 0, y = 2, z = 0}, center = {x = 0, y = 0, z = 0}, limit = 2}
	local self = {
		_id = "seller", _profession = "farmer",
		object = {get_pos = function() return target end, get_velocity = function() return {x = 1, y = 0, z = 2} end,
			set_velocity = function(_, velocity) seller_velocity = velocity end},
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
		function(value) ticks = value end, props, function(value) real = value end,
		function() return seller_velocity end, function(value) bell_node = value end
end

do
	local controller, site, _, seller, bell, _, _, _, props = controller_fixture()
	assert(controller.tick(seller, bell, 0) == "holding", "seller holds while bounded search is pending")
	assert(controller.tick(seller, bell, 0) == "walking", "seller begins normal goto after reservation")
	assert(site.searches == 1 and site.owner == tostring(seller._id), "search is created once for the string prop owner")
	local route, elapsed = seller._villages_goto_route, seller._villages_market_session.walk_elapsed
	assert(controller.renew_only(seller, bell) and site.renewals == 1,
		"maintenance-only renewal keeps a planning seller's reservation alive")
	assert(seller._villages_goto_route == route and seller._villages_market_session.walk_elapsed == elapsed,
		"maintenance-only renewal neither replaces nor advances the market route")
	assert(controller.tick(seller, bell, 1) == "walking", "seller continues a planning route")
	assert(site.renewals == 2, "reservation renews while the seller travels")
	seller._villages_goto_route.status = "arrived"
	seller.arrival_callback(seller)
	assert(controller.tick(seller, bell, 0) == "holding", "arrival requires position and layout revalidation")
	assert(site.valid_calls == 1, "arrival validates reserved layout")
	assert(seller._villages_market_stock_day == day and site.owner == tostring(seller._id),
		"arrival saves today's stock guard and reserves by string owner id")
	assert(controller.tick(seller, bell, 0) == "holding" and site.valid_calls == 1,
		"an opened seller stays selling without revalidating or restocking")
	assert(props.renewal_deadline == 1600, "seller renewals extend the prop deadline on real time")
	local selling_route = seller._villages_goto_route
	assert(controller.renew_only(seller, bell) and props.renewals == 2,
		"maintenance-only renewal also keeps an arrived seller's prop lease alive")
	assert(seller._villages_goto_route == selling_route,
		"maintenance-only renewal does not change a seller's route while the role holds")
	seller._trading_players = {player = true}
	assert(controller.tick(seller, bell, 20, true) == "holding" and props.renewals == 3,
		"a long player trade continues renewing an active stall lease")
	seller._trading_players = nil
	controller.leave(seller, "test")
	assert(site.releases == 1 and site.renewals == 6, "leave releases the reservation after renewing it while selling")
	assert(seller.order == nil, "leaving a market hold restores the previous order")
end

do
	local controller, site, _, seller, bell, _, _, set_ticks, props, set_real, get_velocity = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	assert(controller.tick(seller, bell, 0) == "holding")
	local session = seller._villages_market_session
	assert(props.setups == 1 and props.activations == 1 and props.owner == tostring(seller._id),
		"props are created and leased once after confirmed arrival")
	assert(props.context.validate_session(), "prop recovery validates the live seller session and bell")
	assert(session.pack_at == 14750 and props.deadline == 1600,
		"packing is selected once and the lease has an absolute real-time deadline")
	assert(controller.tick(seller, bell, 0) == "holding" and props.setups == 1,
		"selling holds in place and never repairs/restocks props")
	local velocity = get_velocity()
	assert(velocity and velocity.x == 0 and velocity.y == 0 and velocity.z == 0,
		"seller holds a standing pose with horizontal movement stopped")
	set_ticks(14750)
	assert(controller.tick(seller, bell, 0) == "holding" and props.frame_removals == 1,
		"chosen packing time removes frames first")
	set_real(1000.99)
	assert(controller.tick(seller, bell, 0) == "holding" and props.cleanups == 0,
		"tables remain for the one-second packing interval")
	set_real(1001.01)
	assert(controller.tick(seller, bell, 0) == "holding" and props.cleanups == 1,
		"tables are removed after the interval")
	assert(seller._villages_market_session == nil and site.releases == 1 and props.releases == 1,
		"packing releases prop lease and site reservation")
	assert(controller.tick(seller, bell, 0) == "browse" and props.setups == 1,
		"a packed seller does not reopen this activation")
end

do
	local controller, site, _, seller, bell, _, _, set_ticks, props = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	assert(controller.tick(seller, bell, 0) == "holding")
	set_ticks(15000)
	assert(controller.tick(seller, bell, 0) == "holding" and props.cleanups == 1,
		"a skipped packing deadline forces immediate full cleanup")
	assert(site.releases == 1 and seller._villages_market_session == nil,
		"forced cleanup releases all session claims")
end

do
	local controller, site, _, seller, bell, cancelled = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session = seller._villages_market_session
	seller._trading_players = {player = true}
	assert(controller.renew_only(seller, bell, 3) and session.walk_elapsed == 0,
		"a trading hold renews a planning reservation without counting its walk deadline")
	assert(seller._villages_goto_route == nil and session.route_paused
		and cancelled[#cancelled] == session.id,
		"maintenance during a false role hold cancels only the active market route under trade")
	seller._trading_players = nil
	assert(controller.tick(seller, bell, 0) == "walking" and seller._villages_goto_route
		and seller._villages_goto_route.market_token == session.id and not session.route_paused,
		"the normal market tick replans the reserved stall route after trade")
end

do
	local controller, _, _, seller, bell, cancelled = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session, route = seller._villages_market_session, seller._villages_goto_route
	assert(not controller.renew_only(seller, bell, 3) and seller._villages_market_session == nil
		and cancelled[#cancelled] == session.id,
		"a planning hold still enforces the walk deadline and cancels only its market route")
	assert(route.market_token == session.id,
		"walk deadline cleanup leaves the route ownership token attributable to the seller")
end

do
	local controller, _, _, seller, bell, _, _, set_ticks, props, set_real = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	controller.tick(seller, bell, 0)
	set_ticks(14750)
	assert(controller.renew_only(seller, bell, 0) and props.frame_removals == 1,
		"an arrived seller begins packing during a role hold")
	set_real(1001.01)
	local kept = controller.renew_only(seller, bell, 0)
	assert(not kept and props.cleanups == 1 and seller._villages_market_session == nil,
		"packing finishes and releases the stall during a continued role hold: kept=" .. tostring(kept)
			.. " cleanups=" .. tostring(props.cleanups) .. " session=" .. tostring(seller._villages_market_session))
end

do
	local controller, _, _, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	assert(seller.order == "stand", "searching pins the seller in place")
	seller.order = "sleep"
	controller.leave(seller, "stage transition")
	assert(seller.order == "sleep", "cleanup preserves a role order that replaced the market hold")
end

do
	local controller, site, _, seller, bell, _, _, _, props = controller_fixture()
	props.fail_setup = true
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	assert(controller.tick(seller, bell, 0) == "browse")
	assert(seller._villages_market_stock_day == day and props.setups == 1 and props.activations == 0,
		"a failed setup still consumes today's opportunity and never activates a lease")
	assert(site.releases == 1 and seller._villages_market_session == nil,
		"setup failure releases reservation and abandons the session")
end

do
	local controller, site, _, seller, bell, _, _, _, props, _, _, set_bell_node = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	controller.tick(seller, bell, 0)
	set_bell_node(nil)
	local bell_state, bell_reason = props.context.validate_session()
	assert(bell_state == nil and bell_reason == "bell_unloaded",
		"an unavailable bell is an unknown prop validation result")
	assert(controller.tick(seller, bell, 0) == "holding" and props.cleanups == 0,
		"an unloaded bell is unknown and leaves a live stall alone")
	seller.following = true
	assert(props.context.validate_session() == false,
		"known ineligibility overrides an unavailable bell during orphan checks")
	seller.following = nil
	seller.object.get_pos = function() return {x = 9, y = 1, z = 5} end
	assert(props.context.validate_session() == false,
		"known displacement overrides an unavailable bell during orphan checks")
	seller.object.get_pos = function() return {x = 4, y = 1, z = 5} end
	set_bell_node({name = "air"})
	assert(controller.tick(seller, bell, 0) == "browse" and props.cleanups == 1,
		"a loaded removed bell aborts the stall and cleans its props")
	assert(site.releases == 1, "bell removal releases the site reservation")
end

do
	local controller, site, _, seller, bell, _, _, _, props = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	controller.tick(seller, bell, 0)
	seller.object.get_pos = function() return {x = 9, y = 1, z = 5} end
	assert(controller.tick(seller, bell, 0) == "browse")
	assert(props.cleanups == 1 and site.releases == 1 and seller._villages_market_session == nil,
		"displacement aborts selling and cleans the stall")
end

do
	local controller, site, _, seller, bell, _, _, _, props = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._villages_goto_route.status = "arrived"
	controller.tick(seller, bell, 0)
	seller._profession = "mason"
	assert(controller.tick(seller, bell, 0) == "browse")
	assert(props.cleanups == 1 and site.releases == 1,
		"a profession change aborts the stall and releases its reservation")
end

do
	local controller, site, _, seller, bell = controller_fixture()
	seller._villages_market_stock_day = day
	assert(controller.tick(seller, bell, 0) == "browse" and site.searches == 0,
		"a reloaded seller with today's saved stock guard cannot mint another stall")
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

do
	local controller, site, _, seller, bell = controller_fixture()
	local route = {status = "travelling", market_token = "job-search"}
	seller._villages_goto_route = route
	assert(controller.tick(seller, bell, 0) == "browse" and site.searches == 0,
		"a market attempt does not replace a route already owned by another system")
	assert(seller._villages_goto_route == route and seller._villages_market_attempted,
		"the existing route survives and this activation does not retry market setup")
end

do
	local controller, site, _, seller, bell = controller_fixture()
	seller._trading_players = {player = true}
	assert(controller.tick(seller, bell, 0, true) == "browse" and site.searches == 0,
		"a trade tick renews only a seller session that already exists")
	assert(seller._villages_market_session == nil and not seller._villages_market_attempted,
		"trading does not start or consume a new market attempt")
end

do
	local controller, site, _, seller, bell = controller_fixture()
	assert(controller.tick(seller, bell, 0) == "holding", "market search starts before trade")
	local session = seller._villages_market_session
	seller._trading_players = {player = true}
	assert(controller.tick(seller, bell, 10, true) == "holding" and session.search.steps == 1,
		"trade pauses an existing search before it can reserve or start a route")
	assert(seller._villages_goto_route == nil, "search does not call gopath during trade")
	seller._trading_players = nil
	assert(controller.tick(seller, bell, 0) == "walking" and seller._villages_goto_route,
		"the pending search resumes after the trade")
	seller._trading_players = {player = true}
	assert(controller.tick(seller, bell, 10, true) == "holding" and seller._villages_goto_route == nil
		and session.route_paused,
		"a queued market route is invalidated while the player trades")
	seller._trading_players = nil
	assert(controller.tick(seller, bell, 0) == "walking" and seller._villages_goto_route
		and not session.route_paused,
		"the reserved stall route is replanned after trading ends")
end

do
	local controller, site, _, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	seller._trading_players = {player = true}
	controller.tick(seller, bell, 0, true)
	local session = seller._villages_market_session
	local replacement = {status = "travelling", market_token = "role-route"}
	seller._villages_goto_route = replacement
	seller._trading_players = nil
	assert(controller.tick(seller, bell, 0) == "browse" and site.releases == 1,
		"a replaced paused market route abandons the session instead of overwriting the new route")
	assert(seller._villages_goto_route == replacement and session.route_paused,
		"the replacement role route retains movement ownership")
end

do
	local controller, _, _, seller, bell = controller_fixture()
	controller.tick(seller, bell, 0)
	controller.tick(seller, bell, 0)
	local session = seller._villages_market_session
	seller._trading_players = {player = true}
	seller._villages_goto_route.status = "trade_paused"
	seller._trading_players = nil
	assert(controller.tick(seller, bell, 0) == "walking" and seller._villages_goto_route
		and seller._villages_goto_route.market_token == session.id,
		"a queued plan deferred during a short trade is replanned even if trade ends before a tick")
end

print("market goods and eligibility tests passed")
