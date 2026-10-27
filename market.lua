-- Representative market goods, eligibility and seller travel sessions (#291, #292).
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
	if day ~= nil and villager._villages_market_stock_day == day then return false, "already_stocked" end
	if not M.goods_for(villager, attempt) then return false, "no_goods" end
	return true
end

local serial = 0
local SETUP_CUTOFF = 14500

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

function M.new(options)
	options = options or {}
	local site = assert(options.site, "market.new requires the shared market_site service")
	assert(options.props, "market.new requires the shared market_props service")
	local navigation = options.navigation or {}
	local get_stage = options.stage or function(self) return common.schedule_stage(nil, self) end
	local get_ticks = options.ticks or function() return time_ticks(options.core or core) end
	local standing_position = options.standing_position or cells.standing_position
	local api = {}

	local function fallback(self, session, reason)
		if not session.fallback_logged then
			session.fallback_logged = true
			core.log("action", "[living_villages] market seller browsing: " .. reason)
		end
		self._villages_market_attempted = true
		if session.reservation then site.release(session.reservation) end
		if session.id and navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
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

	function api.leave(self, reason)
		local session = self._villages_market_session
		if not session then return false end
		if session.reservation then site.release(session.reservation) end
		if session.id and navigation.cancel_goto then navigation.cancel_goto(self, session.id) end
		self._villages_market_session = nil
		self._villages_market_attempted = true
		return true
	end

	function api.tick(self, bell_session, dtime)
		-- Integration calls this before bell.lua's trading early return. Trading is
		-- passed through here so it can pause the distance-based walk deadline.
		local session = self._villages_market_session
		if not session then
			if self._villages_market_attempted or not bell_session
				or get_stage(self) ~= "bell" or get_ticks() >= SETUP_CUTOFF then return "browse" end
			self._villages_market_attempted = true
			local eligible = M.eligible(self, {})
			if not eligible then return "browse" end
			local center = bell_session.center
			if not center then return "browse" end
			serial = serial + 1
			session = {
				id = tostring(self._id) .. ":" .. tostring(serial),
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
		if session.reservation and not site.renew(session.reservation) then
			return fallback(self, session, "stall reservation expired")
		end

		if not session.reservation then
			if get_ticks() >= SETUP_CUTOFF then return fallback(self, session, "search reached setup cutoff") end
			local status, reservation = site.step_search(session.search)
			if status == "pending" then return "holding" end
			if status == "exhausted" then return fallback(self, session, "no stall site found") end
			session.reservation = reservation
			session.layout = reservation.layout
			local target = standing_position(session.layout.seller)
			local started = self:gopath(target, function(entity)
				if entity._villages_market_session == session then session.callback_arrived = true end
			end, true, session.id)
			local route = self._villages_goto_route
			if not started or not route or route.market_token ~= session.id then
				return fallback(self, session, "no route to stall")
			end
			session.route_id = route.id
			return "walking"
		end

		local route = self._villages_goto_route
		if not route or route.market_token ~= session.id then
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
			session.arrived = true
			-- #293 begins selling after this confirmed transition.
			return "holding"
		end
		return "walking"
	end

	return api
end

return M
