-- fisherman.lua reads minetest, vector, and common.lua's workstation_profession
-- mapping, so this fakes a minimal claimable-node "world" alongside the
-- villager-field fakes tests/farmer.lua already uses.
local nodes, meta_store = {}, {}
-- Outside every is_work_time() window by default, so the shoreline-trip
-- trigger stays inert for the profession-guard tests above, which do not set
-- it themselves.
local timeofday = 0
local now = 0
local water_sites = {}
local water_scans = 0

local function pos_key(pos) return pos.x .. ":" .. pos.y .. ":" .. pos.z end

local function place(pos, name, owner)
	nodes[pos_key(pos)] = name
	meta_store[pos_key(pos)] = owner or ""
end

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return timeofday end,
	get_gametime = function() return now end,
	registered_nodes = {
		["mcl_core:water_source"] = {liquidtype = "source"},
		["air"] = {liquidtype = "none"},
	},
	get_node_or_nil = function(pos)
		local name = nodes[pos_key(pos)]
		return {name = name or "air"}
	end,
	find_nodes_in_area = function()
		water_scans = water_scans + 1
		return water_sites
	end,
	get_meta = function(pos)
		local k = pos_key(pos)
		return {
			get_string = function(_, field)
				return field == "villager" and (meta_store[k] or "") or ""
			end,
			set_string = function(_, field, value)
				if field == "villager" then meta_store[k] = value end
			end,
		}
	end,
	get_item_group = function() return 0 end,
}
vector = {
	new = function(pos) return {x = pos.x, y = pos.y, z = pos.z} end,
	equals = function(a, b) return a and b and a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b)
		local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(x * x + y * y + z * z)
	end,
}

local function new_def(custom, activate)
	return {
		do_custom = custom or function() end,
		on_activate = activate or function(self, staticdata, dtime) return "activated" end,
	}
end

-- 1. An untraded fallback fisherman with no nearby workstation is knocked to
-- "unemployed" by remove_job and never re-employed; profession and trades
-- are restored, and there is no stray jobsite to leak.
do
	local def = new_def(function(self)
		self._jobsite = nil
		self._profession = "unemployed"
		self._trades = nil
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_id = "f1", _villages_fisherman = true, _profession = "fisherman", _trades = "some-trades", _jobsite = nil}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._profession == "fisherman")
	assert(fisherman._trades == "some-trades")
	assert(fisherman._jobsite == nil)
end

-- 2. Regression: an untraded fallback fisherman standing beside an unrelated
-- workstation is employed straight into that profession by vanilla's
-- get_a_job, in the same call that first knocked it to "unemployed" (an
-- untraded villager's job search covers every profession's jobsite type,
-- not just its own). The profession must be restored, and the stray
-- claim -- which already wrote real node meta -- released rather than left
-- dangling on a fisherman who will never work it.
do
	local composter = {x = 5, y = 0, z = 5}
	place(composter, "mcl_composters:composter", "")
	local def = new_def(function(self)
		self._jobsite = nil
		self._profession = "unemployed"
		self._trades = nil
		-- vanilla's employ(): claims the node, then (untraded) sets profession.
		meta_store[pos_key(composter)] = self._id
		self._jobsite = composter
		self._profession = "farmer"
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_id = "f2", _villages_fisherman = true, _profession = "fisherman", _trades = nil, _jobsite = nil}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._profession == "fisherman")
	assert(fisherman._jobsite == nil)
	assert(meta_store[pos_key(composter)] == "", "the composter's claim must be released, not left owned by a fisherman")
end

-- 3. A fresh claim on a barrel -- a jobsite this profession would have
-- wanted anyway -- is left in place rather than released.
do
	local barrel = {x = 1, y = 0, z = 1}
	place(barrel, "mcl_barrels:barrel_closed", "")
	local def = new_def(function(self)
		meta_store[pos_key(barrel)] = self._id
		self._jobsite = barrel
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_id = "f3", _villages_fisherman = true, _profession = "fisherman", _trades = nil, _jobsite = nil}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._profession == "fisherman")
	assert(fisherman._jobsite and fisherman._jobsite.x == barrel.x)
	assert(meta_store[pos_key(barrel)] == "f3")
end

-- 4. Regression: a barrel fisherman that wanders past RESETTLE_DISTANCE has
-- its claim released by vanilla itself -- the node's own meta is cleared
-- before `_jobsite` is (mobs_mc/villager.lua:1268). The guard must not
-- resurrect a jobsite whose claim is already gone.
do
	local barrel = {x = 2, y = 0, z = 2}
	place(barrel, "mcl_barrels:barrel_closed", "f4")
	local def = new_def(function(self)
		meta_store[pos_key(barrel)] = ""
		self._jobsite = nil
	end)
	dofile("fisherman.lua")(def)
	local fisherman = {_id = "f4", _villages_fisherman = true, _profession = "fisherman", _trades = "some-trades", _jobsite = barrel}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._profession == "fisherman")
	assert(fisherman._trades == "some-trades")
	assert(fisherman._jobsite == nil, "a released claim must not be restored")
end

-- 5. Unflagged villagers are untouched: a plain villager torn down by the
-- wrapped call stays torn down.
do
	local def = new_def(function(self)
		self._profession = "unemployed"
		self._trades = nil
		self._jobsite = nil
	end)
	dofile("fisherman.lua")(def)
	local farmer = {_id = "plain-1", _profession = "farmer", _trades = "some-trades", _jobsite = {x = 0, y = 0, z = 0}}
	def.do_custom(farmer, 0.1)
	assert(farmer._profession == "unemployed")
	assert(farmer._trades == nil)
	assert(farmer._jobsite == nil)
end

-- 6. Adults employed as fishermen are flagged on activate; children are not,
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

-- 7. A villager of any other profession is never flagged on activate.
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

-- 8. #72: a working fisherman with no route in progress and qualifying water
-- nearby is sent toward the nearest surface-water tile; navigation.lua turns
-- that anchor into an actual shoreline stand.
do
	local gopath_target
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 100
	water_sites = {{x = 12, y = 0, z = 0}, {x = 3, y = 0, z = 0}}
	place({x = 12, y = 0, z = 0}, "mcl_core:water_source")
	place({x = 3, y = 0, z = 0}, "mcl_core:water_source")
	local fisherman = {
		_id = "f8", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end},
		gopath = function(self, target)
			gopath_target = target
			self.state = "gowp"
			return true
		end,
	}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_target and fisherman._villages_fish_target.x == 3,
		"the nearest qualifying water tile must be chosen")
	assert(gopath_target and gopath_target.x == 3)
	timeofday, water_sites = 0, {}
end

-- 9. No qualifying water in range sets a retry cooldown instead of a target,
-- and the cooldown suppresses an immediate rescan.
do
	local gopath_called = false
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 200
	water_sites, water_scans = {}, 0
	local fisherman = {
		_id = "f9", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end},
		gopath = function() gopath_called = true; return true end,
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_target)
	assert(not gopath_called)
	assert(water_scans == 1)
	assert(fisherman._villages_fish_next and fisherman._villages_fish_next > now)
	def.do_custom(fisherman, 0.1)
	assert(water_scans == 1, "the retry cooldown must suppress an immediate rescan")
	timeofday = 0
end

-- 10. An already-selected fish target is left alone while its route is
-- still in progress.
do
	local gopath_called = false
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 300
	local fisherman = {
		_id = "f10", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		_villages_fish_target = {x = 9, y = 0, z = 0},
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end},
		gopath = function() gopath_called = true; return true end,
	}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_target.x == 9)
	assert(not gopath_called)
	timeofday = 0
end

-- 11. A fish route that failed and is past its retry time clears the stale
-- target so a fresh stand can be chosen on a later tick.
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 400
	local fisherman = {
		_id = "f11", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		_villages_fish_target = {x = 9, y = 0, z = 0},
		_villages_fish_route = {status = "retry", retry_at = 300},
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end},
		gopath = function(self) self.state = "gowp"; return true end,
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_target)
	assert(not fisherman._villages_fish_route)
	timeofday = 0
end

-- 12. A villager already mid-route is not redirected to a fish target.
do
	local gopath_called = false
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 500
	water_sites = {{x = 3, y = 0, z = 0}}
	place({x = 3, y = 0, z = 0}, "mcl_core:water_source")
	local fisherman = {
		_id = "f12", _villages_fisherman = true, _profession = "fisherman", state = "gowp",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end},
		gopath = function() gopath_called = true; return true end,
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_target)
	assert(not gopath_called)
	timeofday, water_sites = 0, {}
end

print("fisherman.lua: ok")
