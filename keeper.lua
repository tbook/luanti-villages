-- Tavern keepers (#15): a villager who claims a jukebox, keeps the tavern's
-- hours (#22), and sells prepared food through ordinary villager trades.
--
-- VoxeLibre cannot be given a new profession: its professions table is a
-- file-local in mobs_mc/villager.lua, and employ() only ever grants one of
-- those. The upstream API in #35 would fix that. Until it lands, a keeper is
-- a role layered on a vanilla butcher -- the closest vanilla trade, and one
-- whose smoker a keeper must never be handed:
--
-- - `_trades` is seeded here with the keeper's menu. Vanilla only builds a
--   trade table from its own professions when `_trades` is unset
--   (villager.lua on_rightclick), so it never looks at the butcher's.
-- - The jukebox is claimed through the same `villager` node meta vanilla
--   uses, and vanilla's validate_jobsite checks only that meta, never which
--   node it is on, so vanilla commutes to and keeps the jukebox as it would
--   any other jobsite.
-- - The trade window's title is the one place vanilla still names the
--   butcher; show_formspec is rewritten for it below.
--
-- If #35 lands, the role becomes a registered profession and each of these
-- workarounds a deletion.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local S = core.get_translator and core.get_translator("villages") or function(message) return message end
local JUKEBOX = "mcl_jukebox:jukebox"
local BASE_PROFESSION = "butcher"
local CLAIM_RADIUS = 48
local CLAIM_INTERVAL = 10
local STAFF_DISTANCE = 3
local STAFF_INTERVAL = 5
local OVERLAY = "(villages_villager_profession_butcher.png^[multiply:#8a5a3a)"

-- The fixed menu. Prepared foods only; ingredient stock and farm supply are
-- future work. Tiers unlock as players trade, as they do for any villager.
local MENU = {
	{tier = 1, wanted = "mcl_core:emerald 1", offered = "mcl_farming:bread", count = 3},
	{tier = 1, wanted = "mcl_core:emerald 1", offered = "mcl_farming:potato_item_baked", count = 4},
	{tier = 2, wanted = "mcl_core:emerald 1", offered = "mcl_fishing:fish_cooked", count = 2},
	{tier = 2, wanted = "mcl_core:emerald 2", offered = "mcl_mushrooms:mushroom_stew", count = 1},
	{tier = 3, wanted = "mcl_core:emerald 3", offered = "mcl_farming:pumpkin_pie", count = 2},
}

-- The same shape vanilla's init_trades serializes into `_trades`.
local function keeper_trades()
	local trades = {}
	for _, entry in ipairs(MENU) do
		if core.registered_items == nil or core.registered_items[entry.offered] then
			table.insert(trades, {
				wanted = {entry.wanted},
				offered = {name = entry.offered, count = entry.count, wear = 0, metadata = ""},
				tier = entry.tier,
				traded_once = false,
				trade_counter = 0,
				locked = false,
			})
		end
	end
	return core.serialize(trades)
end

local function pos_string(pos)
	if not pos then return "?" end
	return string.format("(%d,%d,%d)", pos.x, pos.y, pos.z)
end

local function is_jukebox(pos)
	local node = pos and core.get_node_or_nil(pos)
	return node ~= nil and node.name == JUKEBOX
end

local function claimed_jukebox(self)
	local pos = self._jobsite
	return is_jukebox(pos) and core.get_meta(pos):get_string("villager") == self._id and pos or nil
end

local function unclaimed(pos)
	return core.get_meta(pos):get_string("villager") == ""
end

-- Who may take up a free jukebox: an unemployed adult, or a keeper that lost
-- its jukebox after trading and so keeps the role.
local function wants_jukebox(self)
	if self.child or not self._id or self._jobsite then return false end
	return self._profession == "unemployed" or self._villages_keeper == true
end

local function employ(self, pos)
	if not is_jukebox(pos) or not unclaimed(pos) or not wants_jukebox(self) then return false end
	core.get_meta(pos):set_string("villager", self._id)
	self._jobsite = {x = pos.x, y = pos.y, z = pos.z}
	if not self._villages_keeper then
		self._profession = BASE_PROFESSION
		self._trades = keeper_trades()
		self._max_trade_tier = self._max_trade_tier or 1
		self._villages_keeper = true
	end
	self._villages_keeper_target = nil
	core.log("action", string.format("[villages] villager %s became keeper of the jukebox at %s",
		tostring(self._id), pos_string(pos)))
	return true
end

local function nearest_free_jukebox(pos)
	local sites = core.find_nodes_in_area(
		vector.subtract(pos, CLAIM_RADIUS), vector.add(pos, CLAIM_RADIUS), {JUKEBOX})
	local best, best_distance
	for _, site in ipairs(sites) do
		if unclaimed(site) then
			local distance = vector.distance(pos, site)
			if not best or distance < best_distance then best, best_distance = site, distance end
		end
	end
	return best
end

local function seek_jukebox(self)
	local now = core.get_gametime()
	if now < (self._villages_keeper_check or 0) then return end
	self._villages_keeper_check = now + CLAIM_INTERVAL
	local pos = self.object:get_pos()
	if not pos then return end
	local adjacent = core.find_node_near(pos, 1, {JUKEBOX})
	if adjacent and employ(self, adjacent) then return end
	local site = nearest_free_jukebox(pos)
	if not site then return end
	self._villages_keeper_target = site
	self:gopath(site, function(entity)
		entity._villages_keeper_target = nil
		local here = entity.object:get_pos()
		local near = here and core.find_node_near(here, 1, {JUKEBOX})
		if near then employ(entity, near) end
	end, true)
end

-- A keeper that drifted from the jukebox during service goes back to it.
-- Vanilla's do_work already does this by day, but vanilla's night begins at
-- 17500 (villager.lua is_night), while the tavern stays staffed until 18500.
local function staff(self)
	local jukebox = claimed_jukebox(self)
	local pos = self.object:get_pos()
	if not jukebox or not pos or vector.distance(pos, jukebox) < STAFF_DISTANCE then return end
	local now = core.get_gametime()
	if now < (self._villages_keeper_staff_check or 0) then return end
	self._villages_keeper_staff_check = now + STAFF_INTERVAL
	self:gopath(jukebox, nil, true)
end

-- After vanilla's own activity has run: follow its verdicts on the role, and
-- undo the one it cannot make correctly for a keeper.
local function reconcile(self, jobsite_before)
	if not self._villages_keeper then return end
	if self._profession ~= BASE_PROFESSION then
		-- An untraded keeper that lost its jukebox is unemployed again, as any
		-- villager would be (villager.lua remove_job), and may already have
		-- taken another job in the same call.
		self._villages_keeper = nil
		core.log("action", string.format("[villages] villager %s is no longer a keeper",
			tostring(self._id)))
		return
	end
	local jobsite = self._jobsite
	if jobsite and not (jobsite_before and vector.equals(jobsite, jobsite_before)) and not is_jukebox(jobsite) then
		-- A traded keeper keeps its profession when it loses its jukebox, so
		-- vanilla's get_a_job sends it after a butcher's smoker. Release that.
		if core.get_meta(jobsite):get_string("villager") == self._id then
			core.get_meta(jobsite):set_string("villager", "")
		end
		self._jobsite = nil
	end
end

local function install(def)
	if not core.registered_nodes[JUKEBOX] then
		core.log("warning", "[villages] " .. JUKEBOX .. " is unavailable; no tavern keepers")
		return
	end
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_gopath = def.gopath
	local original_rightclick = def.on_rightclick

	-- The flag is saved with the villager like any other field; recover it
	-- for a keeper saved before it existed, or by a build that lost it.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if not self.child and self._profession == BASE_PROFESSION and self._id and claimed_jukebox(self) then
			self._villages_keeper = true
		end
		self._villages_keeper_target = nil
		return result
	end

	def.do_custom = function(self, dtime)
		local jobsite_before = self._jobsite
		local result = original_custom(self, dtime)
		reconcile(self, jobsite_before)
		if result == false or self.following or self.state == "gowp" then return result end
		if self._villages_keeper and common.is_work_time(self) then
			staff(self)
		elseif wants_jukebox(self) and (common.is_work_time(self)
			or common.schedule_stage(nil, self) == "free") then
			seek_jukebox(self)
		end
		return result
	end

	-- A keeper works only at a jukebox; refuse vanilla's trips to any other
	-- workstation rather than walk there and release it on arrival.
	def.gopath = function(self, target, callback_arrived, prioritised)
		if self._villages_keeper and target then
			local node = core.get_node_or_nil(target)
			if node and common.is_workstation_node(node.name) then return false end
		end
		return original_gopath(self, target, callback_arrived, prioritised)
	end

	local trading = {}
	def.on_rightclick = function(self, clicker)
		local name = clicker and clicker.is_player and clicker:is_player() and clicker:get_player_name()
		if name then trading[name] = self._villages_keeper and self or nil end
		return original_rightclick(self, clicker)
	end
	if core.register_on_leaveplayer then
		core.register_on_leaveplayer(function(player) trading[player:get_player_name()] = nil end)
	end

	-- Vanilla titles the trade window "<profession> - <tier>" from its private
	-- professions table (villager.lua show_trade_formspec). Swap the name.
	local vanilla_S = core.get_translator("mobs_mc")
	local title_color = core.get_color_escape_sequence("#313131")
	local butcher_title = core.formspec_escape(title_color .. vanilla_S("Butcher") .. " - ")
	local keeper_title = core.formspec_escape(title_color .. S("Tavern Keeper") .. " - ")
	local original_show_formspec = core.show_formspec
	core.show_formspec = function(player_name, formname, formspec)
		local keeper = trading[player_name]
		if keeper and keeper._villages_keeper and formname == "mobs_mc:trade_" .. player_name then
			local first, last = formspec:find(butcher_title, 1, true)
			if first then
				formspec = formspec:sub(1, first - 1) .. keeper_title .. formspec:sub(last + 1)
			end
		end
		return original_show_formspec(player_name, formname, formspec)
	end
end

return {
	install = install,
	OVERLAY = OVERLAY,
	-- Exposed for tests and diagnostics.
	employ = employ,
	claimed_jukebox = claimed_jukebox,
	status = function(self)
		if not self._villages_keeper then return "not a keeper" end
		local jukebox = claimed_jukebox(self)
		if not jukebox then
			return self._villages_keeper_target and ("seeking jukebox at " .. pos_string(self._villages_keeper_target))
				or "lost its jukebox; looking for another"
		end
		local stage = common.schedule_stage(nil, self)
		local pos = self.object and self.object:get_pos()
		local distance = pos and vector.distance(pos, jukebox)
		if stage ~= "staff" then return "off duty (" .. stage .. ")" end
		if distance and distance < STAFF_DISTANCE then return "staffing the tavern" end
		return string.format("heading to the jukebox (%.1f nodes away)", distance or -1)
	end,
	trades = keeper_trades,
}
