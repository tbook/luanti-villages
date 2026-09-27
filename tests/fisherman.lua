-- fisherman.lua does not touch `minetest`/`vector`, so no fakes are needed.

local function new_def(custom, activate)
	return {
		do_custom = custom or function() end,
		on_activate = activate or function(self, staticdata, dtime) return "activated" end,
	}
end

-- 1. Profession and trades survive a simulated untraded teardown (the
-- fallback-fisherman shape: no jobsite before or after).
do
	local def = new_def(function(self)
		self._jobsite = nil
		self._profession = "unemployed"
		self._trades = nil
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_villages_fisherman = true, _profession = "fisherman", _trades = "some-trades", _jobsite = nil}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._profession == "fisherman")
	assert(fisherman._trades == "some-trades")
	assert(fisherman._jobsite == nil)
end

-- 2. A barrel fisherman's jobsite is restored after a simulated traded
-- teardown (only `_jobsite` cleared; profession/trades untouched, matching
-- `remove_job`'s `has_traded` branch).
do
	local barrel = {x = 4, y = 0, z = 4}
	local def = new_def(function(self)
		self._jobsite = nil
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_villages_fisherman = true, _profession = "fisherman", _trades = "some-trades", _jobsite = barrel}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._profession == "fisherman")
	assert(fisherman._trades == "some-trades")
	assert(fisherman._jobsite == barrel)
end

-- 3. A fresh, legitimate claim (nil jobsite before, a real one after) is left
-- alone rather than reverted, since vanilla's own `employ()` already mutated
-- the claimed node's meta by the time `_jobsite` changes.
do
	local barrel = {x = 1, y = 0, z = 1}
	local def = new_def(function(self)
		self._jobsite = barrel
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_villages_fisherman = true, _profession = "fisherman", _trades = nil, _jobsite = nil}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._jobsite == barrel)
end

-- 4. Unflagged villagers are untouched: a plain villager torn down by the
-- wrapped call stays torn down.
do
	local def = new_def(function(self)
		self._profession = "unemployed"
		self._trades = nil
		self._jobsite = nil
	end)
	dofile("fisherman.lua")(def)
	local farmer = {_profession = "farmer", _trades = "some-trades", _jobsite = {x = 0, y = 0, z = 0}}
	def.do_custom(farmer, 0.1)
	assert(farmer._profession == "unemployed")
	assert(farmer._trades == nil)
	assert(farmer._jobsite == nil)
end

-- 5. Adults employed as fishermen are flagged on activate; children are not,
-- even with the same profession.
do
	local def = new_def()
	dofile("fisherman.lua")(def)
	local adult = {_profession = "fisherman"}
	def.on_activate(adult, "", 0.1)
	assert(adult._villages_fisherman == true)

	local child = {_profession = "fisherman", child = true}
	def.on_activate(child, "", 0.1)
	assert(not child._villages_fisherman)
end

-- 6. A villager of any other profession is never flagged on activate.
do
	local def = new_def()
	dofile("fisherman.lua")(def)
	local farmer = {_profession = "farmer"}
	def.on_activate(farmer, "", 0.1)
	assert(not farmer._villages_fisherman)

	local nitwit = {_profession = "nitwit"}
	def.on_activate(nitwit, "", 0.1)
	assert(not nitwit._villages_fisherman)
end

print("fisherman.lua: ok")
