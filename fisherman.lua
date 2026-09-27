-- Keeps the fisherman profession and its trades intact once VoxeLibre's own
-- activity loop sees a jobsite it cannot validate. `do_activity` (called from
-- inside the vanilla `do_custom` this file wraps) runs `validate_jobsite`
-- every ~5s; when `_jobsite` does not resolve, `remove_job`
-- (mobs_mc/villager.lua:1240) clears it and, for a villager that has never
-- traded, also resets `_profession` to "unemployed" and wipes `_trades`.
-- Barrels are no longer required for this profession (#7), so a fallback
-- fisherman has no jobsite by design, and even a barrel-employed one loses
-- jobsite proximity the moment it walks to the water to fish (#72). Both
-- would otherwise be un-professioned within one activity tick.
--
-- Fisherman is for life: this guard never demotes one, so nothing here needs
-- to distinguish a barrel fisherman from a fallback one.
local function should_flag(self)
	return not self.child and self._profession == "fisherman"
end

return function(def)
	local original_activate = def.on_activate
	local original_custom = def.do_custom

	-- A villager already employed as a fisherman when its mapblock loads
	-- (existing barrel fishermen, or one #71 promoted before a save) needs
	-- the flag restored; it is not itself part of the saved fields.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if should_flag(self) then
			self._villages_fisherman = true
		end
		return result
	end

	def.do_custom = function(self, dtime)
		if not self._villages_fisherman then
			return original_custom(self, dtime)
		end
		local profession, trades, jobsite = self._profession, self._trades, self._jobsite
		local result = original_custom(self, dtime)
		-- Restore only what vanilla tore down, not what it legitimately
		-- changed: a traded fisherman standing beside a freshly placed,
		-- unclaimed barrel may claim it through vanilla's own proximity
		-- check inside get_a_job, and that claim already mutated the
		-- barrel's node meta. Clobbering `_jobsite` back to nil here would
		-- desync self from that meta and leak the claim, so a fresh,
		-- non-nil jobsite is left alone.
		if self._profession == "unemployed" then self._profession = profession end
		if trades ~= nil and self._trades == nil then self._trades = trades end
		if jobsite and not self._jobsite then self._jobsite = jobsite end
		return result
	end
end
