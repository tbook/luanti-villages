-- Clerics at the pulpit (#125). VoxeLibre's professions table is file-local,
-- so the pulpit (#21) cannot be registered as the cleric's jobsite until #35
-- lands. Until then a free pulpit is claimed through the same `villager` node
-- meta vanilla uses, as keeper.lua does for the jukebox:
--
-- - Vanilla's validate_jobsite checks only that meta, never which node it is
--   on, so a cleric with a claimed pulpit is neither demoted nor sent to a
--   brewing stand: get_a_job and remove_job run only once the claim is gone.
--   Vanilla commutes to the pulpit and works there like at any jobsite.
-- - A villager who claims one becomes a plain vanilla cleric, with vanilla's
--   trades and trade window, so there is no flag to save: a pulpit cleric is
--   a cleric whose claimed jobsite is a pulpit. Death releases the claim in
--   vanilla's on_die, and the claim survives unloading in the node meta.
-- - Brewing stands keep working for vanilla clerics.
--
-- If #35 lands, the pulpit becomes a registered jobsite and this file is
-- deleted.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local PULPIT = "living_villages:pulpit"
local PROFESSION = "cleric"
local CLAIM_RADIUS = 48
local CLAIM_INTERVAL = 10
local UNREACHABLE_SECONDS = 60

local function pos_string(pos)
	if not pos then return "?" end
	return string.format("(%d,%d,%d)", pos.x, pos.y, pos.z)
end

local function is_pulpit(pos)
	local node = pos and core.get_node_or_nil(pos)
	return node ~= nil and node.name == PULPIT
end

local function claimed_pulpit(self)
	local pos = self._jobsite
	return is_pulpit(pos) and core.get_meta(pos):get_string("villager") == self._id and pos or nil
end

local function unclaimed(pos)
	return core.get_meta(pos):get_string("villager") == ""
end

-- Who may take up a free pulpit: an unemployed adult, or a cleric with no
-- jobsite, which can only be one a player has traded with (vanilla demotes an
-- untraded one). Never a librarian or any other profession.
local function wants_pulpit(self)
	if self.child or not self._id or self._jobsite then return false end
	return self._profession == "unemployed" or self._profession == PROFESSION
end

local function employ(self, pos)
	if not is_pulpit(pos) or not unclaimed(pos) or not wants_pulpit(self) then return false end
	core.get_meta(pos):set_string("villager", self._id)
	self._jobsite = {x = pos.x, y = pos.y, z = pos.z}
	self._profession = PROFESSION
	core.log("action", string.format("[living_villages] villager %s became cleric of the pulpit at %s",
		tostring(self._id), pos_string(pos)))
	return true
end

-- Free pulpits within reach, nearest first.
local function free_pulpits(pos)
	local found = {}
	local sites = core.find_nodes_in_area(
		vector.subtract(pos, CLAIM_RADIUS), vector.add(pos, CLAIM_RADIUS), {PULPIT})
	for _, site in ipairs(sites) do
		if unclaimed(site) then table.insert(found, {site = site, distance = vector.distance(pos, site)}) end
	end
	table.sort(found, function(a, b) return a.distance < b.distance end)
	return found
end

-- Pulpits a villager could not path to, so a sealed-off nearest one does not
-- starve a reachable one. Kept here, not on the villager, so nothing extra is
-- saved with it.
local unreachable = {}

local function seek_pulpit(self)
	local now = core.get_gametime()
	if now < (self._villages_pulpit_check or 0) then return end
	self._villages_pulpit_check = now + CLAIM_INTERVAL
	local pos = self.object:get_pos()
	if not pos then return end
	local adjacent = core.find_node_near(pos, 1, {PULPIT})
	if adjacent and employ(self, adjacent) then return end
	local skipped = unreachable[self._id] or {}
	unreachable[self._id] = skipped
	for _, candidate in ipairs(free_pulpits(pos)) do
		local site = candidate.site
		local key = core.hash_node_position and core.hash_node_position(site) or pos_string(site)
		if (skipped[key] or 0) <= now then
			local started = self:gopath(site, function(entity)
				local here = entity.object:get_pos()
				local near = here and core.find_node_near(here, 1, {PULPIT})
				if near then employ(entity, near) end
			end, true)
			if started ~= false then return end
			skipped[key] = now + UNREACHABLE_SECONDS
			-- navigation.lua's failure backoff is per trip kind, not per
			-- target, and would refuse the next pulpit too.
			self._villages_job_search_route = nil
		end
	end
end

local function install(def)
	if not core.registered_nodes[PULPIT] then
		core.log("warning", "[living_villages] " .. PULPIT .. " is unavailable; no pulpit clerics")
		return
	end
	local original_custom = def.do_custom

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		-- Another role's trip (keeper.lua's jukebox, vanilla's job search) is
		-- already under way; one trip at a time.
		if result == false or self.following or self.state == "gowp"
			or self._villages_keeper or self._villages_keeper_target then return result end
		if wants_pulpit(self) and (common.is_work_time(self) or common.schedule_stage(nil, self) == "free") then
			seek_pulpit(self)
		end
		return result
	end
end

return {
	install = install,
	-- Exposed for tests and diagnostics.
	employ = employ,
	claimed_pulpit = claimed_pulpit,
	status = function(self)
		if self._profession ~= PROFESSION then return "not a cleric" end
		local pulpit = claimed_pulpit(self)
		return pulpit and ("works at the pulpit at " .. pos_string(pulpit)) or "no pulpit"
	end,
}
