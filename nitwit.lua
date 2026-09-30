-- Keeps a nitwit a nitwit (#75). Nitwit is VoxeLibre's one profession with no
-- jobsite, but `validate_jobsite` (mobs_mc/villager.lua:1257) only exempts
-- "unemployed". For a nitwit it calls `remove_job`, which resets an untraded
-- villager's `_profession` to "unemployed", so every nitwit is demoted on its
-- first activity tick. Restoring the profession afterwards, as fisherman.lua's
-- guard (#70) does, is not enough here: in the same `do_activity` call the
-- demoted villager goes on to `get_a_job`, which can claim a workstation and
-- walks it toward the nearest free one, every ~5s, forever.
--
-- So stop the demotion before it happens. `remove_job` and `do_activity` both
-- spare a villager that `has_traded` (mobs_mc/villager.lua:1086), so a nitwit
-- carries a traded-looking `_trades` for the length of the vanilla call.
-- `get_a_job` then only looks for a nitwit's own jobsite type, and there are
-- none, so it claims nothing and walks nowhere. Nitwits never trade
-- (`on_rightclick` returns before any trade UI), so no real trade list is
-- hidden; whatever `_trades` held is put back afterwards, and nothing is saved
-- mid-step.
local core = minetest

-- A trade list with one traded entry, in the form core.deserialize reads.
local TRADED = "return {{traded_once = true}}"

return function(def)
	local original_custom = def.do_custom

	def.do_custom = function(self, dtime)
		if self._profession ~= "nitwit" then
			return original_custom(self, dtime)
		end
		local trades = self._trades
		self._trades = TRADED
		local result = original_custom(self, dtime)
		self._trades = trades
		return result
	end
end
