-- Representative market goods and seller sessions (#291-#293).
-- This controller is called by the bell wrapper; it does not install entity hooks.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")

local goods = {
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

local M = {}

function M.profession(villager)
	if villager._villages_fisherman then return "fisherman" end
	return villager._profession
end

local function log_fallback(reason, attempt)
	if attempt and attempt.goods_fallback_logged then return end
	if attempt then attempt.goods_fallback_logged = true end
	core.log("action", "[living_villages] market seller browsing: " .. reason)
end

-- `attempt` is the transient session object, allowing the controller to log
-- just one fallback reason even if it retries the lookup during that attempt.
function M.goods_for(villager, attempt)
	local profession = M.profession(villager)
	local pair = goods[profession]
	if not pair then
		log_fallback("unsupported profession " .. tostring(profession or "unemployed"), attempt)
		return nil, "unsupported_profession"
	end
	local first = core.registered_items[pair[1]] and pair[1]
	local second = core.registered_items[pair[2]] and pair[2]
	if first and second then return {first, second} end
	if first then return {first, first} end
	if second then return {second, second} end
	log_fallback("no registered goods for " .. profession, attempt)
	return nil, "missing_goods"
end

function M.eligible(villager, attempt)
	if villager.child or villager._is_baby then return false, "child" end
	if villager._villages_keeper then return false, "keeper" end
	if not villager._id then return false, "missing_id" end
	if villager.following then return false, "following" end
	local day = core.get_day_count and core.get_day_count()
	if not (attempt and attempt.arrived) and day ~= nil
		and villager._villages_market_stock_day == day then return false, "already_stocked" end
	if not M.goods_for(villager, attempt) then return false, "no_goods" end
	return true
end

local serial = 0
local SETUP_CUTOFF = 14500
local PACK_EARLIEST = 14750
local PACK_LATEST = 14916
local MARKET_END = 15000
local PACK_DELAY = 1

-- Entity serialization saves ordinary fields automatically. Integration must
-- retain this daily guard and discard the live session machinery on reload.
M.saved_fields = {"_villages_market_stock_day"}
M.transient_fields = {"_villages_market_session", "_villages_market_attempted"}

local function is_trading(self)
	return self._trading_players and next(self._trading_players) ~= nil
end

local function close_enough(self, layout, standing_position)
	local pos = self.object and self.object:get_pos()
	local target = standing_position(layout.seller)
	if not pos then return false end
	local dx, dy, dz = pos.x - target.x, pos.y - target.y, pos.z - target.z
	return dx * dx + dy * dy + dz * dz <= 0.65 * 0.65
end

local function time_ticks(world)
	return ((world.get_timeofday and world.get_timeofday() or 0) * 24000) % 24000
end

local function hold_seller(self, session)
	if not session.holding_order then
		session.previous_order = self.order
		session.holding_order = true
	end
	self.order = "stand"
	self.state = "stand"
	local velocity = self.object and self.object.get_velocity and self.object:get_velocity()
	if velocity and self.object.set_velocity then
		self.object:set_velocity({x = 0, y = velocity.y, z = 0})
	end
	local outward = session.layout and session.layout.outward
	if outward and self.set_yaw then self:set_yaw(math.atan2(-outward.x, outward.z)) end
	if self.set_animation then self:set_animation("stand") end
end

function M.new(options)
	options = options or {}
	local site = assert(options.site, "market.new requires the shared market_site service")
	local props = assert(options.props, "market.new requires the shared market_props service")
	local navigation = options.navigation or {}
	local get_stage = options.stage or function(self) return common.schedule_stage(nil, self) end
	local get_ticks = options.ticks or function() return time_ticks(options.core or core) end
	local get_day = options.day_count or function() return core.get_day_count and core.get_day_count() end
	local random = options.random or math.random
	local real_now = options.real_now or function()
		return core.get_us_time and core.get_us_time() / 1000000 or os.time()
	end
	local get_node_or_nil = options.get_node_or_nil or core.get_node_or_nil
	local is_thunder = options.is_thunder or function()
		return mcl_weather and mcl_weather.get_weather
			and mcl_weather.get_weather() == "thunder" or false
	end
	local standing_position = options.standing_position or cells.standing_position
	local api = {}

	local function cleanup_stall(self, session)
		if not session.stall then return end
		props.release(session.stall.token, self.object, session)
		props.cleanup(session.stall)
		session.stall = nil
	end

	local function fallback(self, session, reason)
		if not session.fallback_logged then
			session.fallback_logged = true
			core.log("action", "[living_villages] market seller browsing: " .. reason)
		end
		self._villages_market_attempted = true
		cleanup_stall(self, session)
		if session.reservation then site.release(session.reservation) end
		if session.id and navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
		if session.holding_order and self.order == "stand" then self.order = session.previous_order end
		self._villages_market_session = nil
		return "browse"
	end

	local function unrelated_route(self)
		for _, field in ipairs({"_villages_bed_route", "_villages_job_route", "_villages_farm_route",
			"_villages_fish_route", "_villages_job_search_route", "_villages_tavern_route"}) do
			local route = self[field]
			if route and (route.status == "planning" or route.status == "travelling") then return true end
		end
		return false
	end

	local function bell_valid(session)
		local bell_pos = session.bell and session.bell.pos
		if not bell_pos or not get_node_or_nil then return nil, "bell_unknown" end
		local node = get_node_or_nil(bell_pos)
		if not node then return nil, "bell_unloaded" end
		return node.name == "mcl_bells:bell"
	end

	local function start_market_walk(self, session)
		local target = standing_position(session.layout.seller)
		local started = self:gopath(target, function(entity)
			local route = entity._villages_goto_route
			if entity._villages_market_session == session and route
				and route.market_token == session.id then
				session.callback_arrived = true
			end
		end, true, session.id)
		local route = self._villages_goto_route
		if not started or not route or route.market_token ~= session.id then return false end
		session.route_id = route.id
		session.route_paused = nil
		return true
	end

	function api.leave(self, reason)
		local session = self._villages_market_session
		if not session then return false end
		cleanup_stall(self, session)
		if session.reservation then site.release(session.reservation) end
		if session.id and navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
		if session.holding_order and self.order == "stand" then self.order = session.previous_order end
		self._villages_market_session = nil
		self._villages_market_attempted = true
		return true
	end

	function api.renew_only(self, bell_session, dtime)
		-- The wrapped role can hold do_custom while the shared route queue plans.
		-- Keep an existing seller's leases alive without starting or advancing its
		-- market walk while that role still owns the tick.
		local session = self._villages_market_session
		if not session then return false end
		if bell_session ~= session.bell or get_stage(self) ~= "bell"
			or not M.eligible(self, session)
			or (session.profession and M.profession(self) ~= session.profession)
			or is_thunder() then
			api.leave(self, "market session no longer valid")
			return false
		end
		local bell_ok = bell_valid(session)
		if bell_ok == false then
			api.leave(self, "bell removed")
			return false
		end
		if session.reservation and not site.renew(session.reservation) then
			fallback(self, session, "stall reservation expired")
			return false
		end
		if session.arrived then
			local pos = self.object and self.object:get_pos()
			local target = standing_position(session.layout.seller)
			local dx, dy, dz = pos and pos.x - target.x, pos and pos.y - target.y, pos and pos.z - target.z
			if not pos or dx * dx + dy * dy + dz * dz > 1 then
				api.leave(self, "seller displaced")
				return false
			end
			if not props.renew(session.stall.token, self.object, session, real_now() + 600) then
				api.leave(self, "stall lease expired")
				return false
			end
			local ticks = get_ticks()
			if ticks >= MARKET_END then
				cleanup_stall(self, session)
				api.leave(self, "market closed")
				return false
			elseif ticks >= session.pack_at and not session.packing_at then
				session.packing_at = real_now()
				props.remove_frames(session.stall)
				core.log("action", "[living_villages] market seller began packing")
			elseif session.packing_at and real_now() - session.packing_at >= PACK_DELAY then
				cleanup_stall(self, session)
				api.leave(self, "packed")
				return false
			end
		else
			local route = self._villages_goto_route
			if route and route.market_token == session.id then
				if is_trading(self) then
					-- A false return from the wrapped role bypasses tick(existing_only).
					-- Stop this seller's active walk while it is being traded with, then
					-- let the normal market tick replan from the same reservation later.
					if route.status == "planning" or route.status == "travelling" then
						if navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
						session.route_paused = true
					end
				elseif (route.status == "planning" or route.status == "travelling")
					and not unrelated_route(self) then
					session.walk_elapsed = session.walk_elapsed + (dtime or 0)
					if session.walk_elapsed > (session.bell.limit or 40) then
						fallback(self, session, "walk to stall took too long")
						return false
					end
				end
			end
		end
		return true
	end

	function api.tick(self, bell_session, dtime, existing_only)
		-- Integration calls this before bell.lua's trading early return. Trading is
		-- passed through here so it can pause the distance-based walk deadline.
		local session = self._villages_market_session
		if not session then
			if existing_only then return "browse" end
			if self._villages_market_attempted or not bell_session
				or get_stage(self) ~= "bell" or get_ticks() >= SETUP_CUTOFF then return "browse" end
			self._villages_market_attempted = true
			-- A route already in progress belongs to the role or a system that
			-- began it before this seller session. Do not replace its goto target.
			local goto_route = self._villages_goto_route
			if unrelated_route(self) or (goto_route
				and (goto_route.status == "planning" or goto_route.status == "travelling")) then
				return "browse"
			end
			local eligible = M.eligible(self, {})
			if not eligible then return "browse" end
			local center = bell_session.center
			if not center then return "browse" end
			serial = serial + 1
			session = {
				id = tostring(self._id) .. ":" .. tostring(serial),
				profession = M.profession(self),
				bell = bell_session,
				walk_elapsed = 0,
				search = site.begin_search(center, tostring(self._id)),
			}
			self._villages_market_session = session
		end

		if self._villages_market_session ~= session or bell_session ~= session.bell
			or get_stage(self) ~= "bell" then
			api.leave(self, "session ended")
			return "browse"
		end
		if not M.eligible(self, session) then
			api.leave(self, "seller no longer eligible")
			return "browse"
		end
		if session.profession and M.profession(self) ~= session.profession then
			api.leave(self, "seller profession changed")
			return "browse"
		end
		if is_thunder() then
			api.leave(self, "thunder")
			return "browse"
		end
		local bell_ok = bell_valid(session)
		if bell_ok == false then
			api.leave(self, "bell removed")
			return "browse"
		end
		if session.reservation and not site.renew(session.reservation) then
			return fallback(self, session, "stall reservation expired")
		end
		if session.arrived then
			local pos = self.object and self.object:get_pos()
			local target = standing_position(session.layout.seller)
			local dx, dy, dz = pos and pos.x - target.x, pos and pos.y - target.y, pos and pos.z - target.z
			if not pos or dx * dx + dy * dy + dz * dz > 1 then
				api.leave(self, "seller displaced")
				return "browse"
			end
			if not props.renew(session.stall.token, self.object, session, real_now() + 600) then
				api.leave(self, "stall lease expired")
				return "browse"
			end
			local ticks = get_ticks()
			if ticks >= MARKET_END then
				cleanup_stall(self, session)
				api.leave(self, "market closed")
				return "holding"
			elseif ticks >= session.pack_at and not session.packing_at then
				session.packing_at = real_now()
				props.remove_frames(session.stall)
				core.log("action", "[living_villages] market seller began packing")
			elseif session.packing_at and real_now() - session.packing_at >= PACK_DELAY then
				cleanup_stall(self, session)
				api.leave(self, "packed")
				return "holding"
			end
			hold_seller(self, session)
			return "holding"
		end
		if existing_only then
			-- A queued planner result can start a follower after do_custom returns.
			-- Invalidate only this market route while a player trades, then plan it
			-- again from the same reservation when the trade closes.
			local route = self._villages_goto_route
			if unrelated_route(self) or (route and route.market_token ~= session.id
				and (route.status == "planning" or route.status == "travelling")) then
				return fallback(self, session, "market movement was replaced during trade")
			end
			if route and route.market_token == session.id
				and (route.status == "planning" or route.status == "travelling"
					or route.status == "trade_paused") then
				if navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
				session.route_paused = true
			end
			hold_seller(self, session)
			return "holding"
		end

		if not session.reservation then
			if get_ticks() >= SETUP_CUTOFF then return fallback(self, session, "search reached setup cutoff") end
			local status, reservation = site.step_search(session.search)
			if status == "pending" then
				hold_seller(self, session)
				return "holding"
			end
			if status == "exhausted" then return fallback(self, session, "no stall site found") end
			session.reservation = reservation
			session.layout = reservation.layout
			if not start_market_walk(self, session) then
				return fallback(self, session, "no route to stall")
			end
			return "walking"
		end

		local route = self._villages_goto_route
		if route and route.market_token == session.id and route.status == "trade_paused" then
			if navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
			session.route_paused = true
			route = nil
		end
		if not route or route.market_token ~= session.id then
			if session.route_paused and not route and session.reservation then
				if unrelated_route(self) then
					return fallback(self, session, "another route took movement ownership")
				end
				if not start_market_walk(self, session) then
					return fallback(self, session, "no route to stall after trade")
				end
				return "walking"
			end
			-- Another system took movement ownership; its route belongs to it.
			return fallback(self, session, "market walk was replaced")
		end
		session.route_id = route.id
		if route.status == "retry" then return fallback(self, session, "route to stall failed") end
		if route.status == "planning" or route.status == "travelling" then
			if not is_trading(self) and not unrelated_route(self) then
				session.walk_elapsed = session.walk_elapsed + (dtime or 0)
			end
			if session.walk_elapsed > (session.bell.limit or 40) then
				return fallback(self, session, "walk to stall took too long")
			end
			return "walking"
		end
		if route.status == "arrived" or session.callback_arrived then
			if get_ticks() >= SETUP_CUTOFF then return fallback(self, session, "arrived after setup cutoff") end
			if not close_enough(self, session.layout, standing_position) then
				if not is_trading(self) and not unrelated_route(self) then
					session.walk_elapsed = session.walk_elapsed + (dtime or 0)
				end
				if session.walk_elapsed > (session.bell.limit or 40) then
					return fallback(self, session, "arrival position did not settle")
				end
				return "walking"
			end
			local valid = site.valid(session.layout, session.reservation)
			if not valid then return fallback(self, session, "stall changed before arrival") end
			local day = get_day()
			if type(day) ~= "number" then return fallback(self, session, "world day unavailable") end
			local items = M.goods_for(self, session)
			if not items then return fallback(self, session, "seller goods unavailable") end
			-- Consume the day's setup chance before any of the first prop writes.
			self._villages_market_stock_day = day
			session.pack_at = PACK_EARLIEST + random(0, PACK_LATEST - PACK_EARLIEST)
			local stall, failure = props.setup(session.layout, tostring(self._id), day, items, session.reservation)
			if not stall then return fallback(self, session, "stall setup failed: " .. tostring(failure)) end
			session.stall = stall
			local context = {
				is_thunder = is_thunder,
				validate_session = function()
					local pos = self.object and self.object:get_pos()
					local target = standing_position(session.layout.seller)
					local dx, dy, dz = pos and pos.x - target.x, pos and pos.y - target.y, pos and pos.z - target.z
					local valid = self._villages_market_session == session and session.arrived
						and M.profession(self) == session.profession
						and M.eligible(self, session) and get_stage(self) == "bell"
						and not is_thunder() and pos ~= nil
						and dx * dx + dy * dy + dz * dz <= 1
					if not valid then return false end
					local bell_ok, reason = bell_valid(session)
					if bell_ok == nil then return nil, reason end
					return bell_ok
				end,
			}
			if not props.activate(stall, self.object, session, real_now() + 600, context) then
				return fallback(self, session, "stall lease setup failed")
			end
			session.arrived = true
			core.log("action", "[living_villages] market seller opened a stall")
			return "holding"
		end

		return "walking"
	end

	return api
end

return M
