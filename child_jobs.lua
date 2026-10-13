-- Children stay generic villagers until they are adults (#262). VoxeLibre's
-- own job search never asks whether a villager is a child: `do_activity`
-- (mobs_mc/villager.lua:1442) runs `get_a_job` for any unemployed villager,
-- and `employ` (:1150) claims the node (meta `villager`), sets `_jobsite`
-- and, for one that has not traded, `_profession`. Undoing only the label
-- afterwards would strand the claim, and the next search would claim another
-- node: `validate_jobsite` returns false for "unemployed" without ever
-- calling `remove_job`.
--
-- So stop the search before it starts, the way nitwit.lua and fisherman.lua
-- do: a child carries a traded-looking `_trades` for the length of the
-- vanilla call, which makes `get_a_job` ask for the jobsites of its own
-- profession, and "unemployed" has none. A child that is already employed
-- (a world saved before this existed) is made generic first: its claim is
-- released, `_jobsite` and `_trades` cleared, and the profession and this
-- mod's keeper/fisherman flags reset. When it grows up, it is an ordinary
-- unemployed villager and takes a job the usual way.
--
-- Nitwits are left alone: they are born that way and have no job to take
-- (nitwit.lua already keeps them from searching).
local core = minetest

-- A trade list with one traded entry, in the form core.deserialize reads.
local TRADED = "return {{traded_once = true, tier = 0}}"

local M = {}

local function release_claim(self)
	local jobsite = self._jobsite
	if not jobsite then return end
	local meta = core.get_meta(jobsite)
	if meta and self._id and meta:get_string("villager") == self._id then
		meta:set_string("villager", "")
	end
	self._jobsite = nil
end

-- Makes `self` (a child) a generic villager again; true if anything changed.
function M.make_generic(self)
	local changed = false
	if self._jobsite then
		release_claim(self)
		changed = true
	end
	if self._profession ~= "unemployed" and self._profession ~= "nitwit" then
		self._profession = "unemployed"
		changed = true
	end
	if self._profession == "unemployed" and self._trades ~= nil then
		self._trades = nil
		changed = true
	end
	for _, flag in ipairs({"_villages_fisherman", "_villages_keeper", "_villages_keeper_target"}) do
		if self[flag] then
			self[flag] = nil
			changed = true
		end
	end
	return changed
end

function M.install(def)
	local original_custom = def.do_custom

	-- Outside fisherman.lua's wrapper, which restores `_profession` after the
	-- vanilla call, and outside keeper/cleric, which look at `_jobsite`.
	def.do_custom = function(self, dtime)
		if not self.child or self._profession == "nitwit" then
			return original_custom(self, dtime)
		end
		M.make_generic(self)
		self._trades = TRADED
		local result = original_custom(self, dtime)
		self._trades = nil
		return result
	end
end

return M
