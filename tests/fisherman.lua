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
local registered_entities = {}
local spawned_bobbers = {}

local function pos_key(pos) return pos.x .. ":" .. pos.y .. ":" .. pos.z end

local function place(pos, name, owner)
	nodes[pos_key(pos)] = name
	meta_store[pos_key(pos)] = owner or ""
end

-- A real enough round trip for the plain _trades tables the fishing cycle
-- unlocks: minetest.serialize/deserialize also work through Lua's own table
-- constructor syntax under the hood.
local function serialize(value)
	local t = type(value)
	if t == "table" then
		local parts = {}
		for k, v in pairs(value) do
			local key = type(k) == "number" and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
			table.insert(parts, key .. "=" .. serialize(v))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif t == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
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
	find_nodes_in_area = function(minp, maxp)
		water_scans = water_scans + 1
		-- The real engine bounds the returned sites to minp/maxp; match that
		-- here so the vertical-band tests can rely on an out-of-range site
		-- genuinely never being offered.
		local bounded = {}
		for _, site in ipairs(water_sites) do
			if site.x >= minp.x and site.x <= maxp.x
				and site.y >= minp.y and site.y <= maxp.y
				and site.z >= minp.z and site.z <= maxp.z then
				table.insert(bounded, site)
			end
		end
		return bounded
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
	register_entity = function(name, def) registered_entities[name] = def end,
	add_entity = function(pos, name)
		local bobber
		bobber = {
			name = name, pos = {x = pos.x, y = pos.y, z = pos.z}, removed = false,
			get_pos = function(self) return (not self.removed) and self.pos or nil end,
			remove = function(self) self.removed = true end,
		}
		table.insert(spawned_bobbers, bobber)
		return bobber
	end,
	serialize = serialize,
	deserialize = function(text)
		local chunk = (loadstring or load)("return " .. text)
		return chunk and chunk()
	end,
}
vector = {
	new = function(pos) return {x = pos.x, y = pos.y, z = pos.z} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	equals = function(a, b) return a and b and a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b)
		local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
		return math.sqrt(x * x + y * y + z * z)
	end,
}
mcl_mobs = {mob_class = {set_yaw = function(self, yaw) self._yaw = yaw end}}

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
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
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

-- 8a: review fix -- a water tile fully surrounded by more water (no possible
-- cardinal approach) is skipped in favor of a farther tile that actually has
-- a shore, instead of being picked by straight-line distance alone and then
-- retrying "no safe standing space" against the same doomed tile forever.
do
	local gopath_target
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 100
	-- Coordinates well outside every other test's placements in this file
	-- (place() writes into a shared, never-cleared node table), but still
	-- within FISH_SEARCH_RADIUS (32) of the villager's position below.
	local mid_lake = {x = 25, y = 0, z = 0}
	local shore = {x = 30, y = 0, z = 0}
	water_sites = {mid_lake, shore}
	place(mid_lake, "mcl_core:water_source")
	place({x = 26, y = 0, z = 0}, "mcl_core:water_source")
	place({x = 24, y = 0, z = 0}, "mcl_core:water_source")
	place({x = 25, y = 0, z = 1}, "mcl_core:water_source")
	place({x = 25, y = 0, z = -1}, "mcl_core:water_source")
	place(shore, "mcl_core:water_source")
	local fisherman = {
		_id = "f8a", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function(self, target)
			gopath_target = target
			self.state = "gowp"
			return true
		end,
	}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_target and fisherman._villages_fish_target.x == 30,
		"a tile with no dry cardinal neighbor must be skipped for one that has one")
	assert(gopath_target and gopath_target.x == 30)
	timeofday, water_sites = 0, {}
end

-- 8b: the vertical search is asymmetric, matching navigation.lua's
-- promotion search: a lake below the villager's own standing height is
-- common, water above is rare, so downward reach (6) is wider than upward
-- reach (2).
do
	local gopath_target
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 100
	local below = {x = 3, y = -6, z = 0}
	water_sites = {below}
	place(below, "mcl_core:water_source")
	local fisherman = {
		_id = "f8b", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function(self, target) gopath_target = target; self.state = "gowp"; return true end,
	}
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_target and fisherman._villages_fish_target.y == -6,
		"a qualifying tile 6 below must be found")
	assert(gopath_target and gopath_target.y == -6)
	water_sites = {}

	local too_deep = {x = 3, y = -7, z = 0}
	water_sites = {too_deep}
	place(too_deep, "mcl_core:water_source")
	local deep_fisherman = {
		_id = "f8c", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function() error("must not travel: no water within the downward reach") end,
	}
	def.do_custom(deep_fisherman, 0.1)
	assert(not deep_fisherman._villages_fish_target, "a tile 7 below must be outside the downward reach")
	water_sites = {}

	local above = {x = 3, y = 2, z = 0}
	water_sites = {above}
	place(above, "mcl_core:water_source")
	local above_fisherman = {
		_id = "f8d", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function(self, target) gopath_target = target; self.state = "gowp"; return true end,
	}
	def.do_custom(above_fisherman, 0.1)
	assert(above_fisherman._villages_fish_target and above_fisherman._villages_fish_target.y == 2,
		"a qualifying tile 2 above must be found")
	water_sites = {}

	local too_high = {x = 3, y = 3, z = 0}
	water_sites = {too_high}
	place(too_high, "mcl_core:water_source")
	local high_fisherman = {
		_id = "f8e", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function() error("must not travel: no water within the narrower upward reach") end,
	}
	def.do_custom(high_fisherman, 0.1)
	assert(not high_fisherman._villages_fish_target, "a tile 3 above must be outside the narrower upward reach")
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
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
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
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
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
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
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
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function() gopath_called = true; return true end,
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_target)
	assert(not gopath_called)
	timeofday, water_sites = 0, {}
end

-- 13. Review fix: a fish target must survive a failed gopath start so the
-- route's own retry backoff throttles re-attempts, instead of rescanning and
-- retrying every tick (a stand-occupied failure is common by design).
do
	local gopath_calls = 0
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 600
	water_sites = {{x = 3, y = 0, z = 0}}
	place({x = 3, y = 0, z = 0}, "mcl_core:water_source")
	local fisherman = {
		_id = "f13", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function(self)
			gopath_calls = gopath_calls + 1
			-- Mirrors navigation.lua's fail(): a rejected start always leaves a
			-- retry route with its own backoff.
			self._villages_fish_route = {status = "retry", retry_at = now + 30}
			return false
		end,
	}
	def.do_custom(fisherman, 0.1)
	assert(gopath_calls == 1)
	assert(fisherman._villages_fish_target and fisherman._villages_fish_target.x == 3,
		"a failed route must not drop its target immediately")

	def.do_custom(fisherman, 0.1)
	assert(gopath_calls == 1, "a pending retry must throttle re-attempts instead of firing every tick")

	now = now + 31
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_target)
	assert(not fisherman._villages_fish_route)
	timeofday, water_sites = 0, {}
end

-- #73: arrival at the stand faces the water and starts a fishing session in
-- its "cast" phase.
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 700
	local water = {x = 5, y = 0, z = 0}
	local fisherman = {
		_id = "f14", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		object = {get_pos = function() return {x = 0, y = 0, z = 0} end, set_velocity = function() end},
		gopath = function(self, target, callback) return callback(self, {x = 4, y = 0, z = 0}) end,
	}
	-- Go through the travel-trigger branch itself, so the target comes from
	-- nearest_water() just as it would on a real trip.
	water_sites = {water}
	place(water, "mcl_core:water_source")
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_session and fisherman._villages_fish_session.phase == "cast")
	assert(fisherman._villages_fish_session.phase_ends_at == now + 2)
	assert(fisherman._yaw, "arrival must face the water via the mob's own set_yaw")
	timeofday, water_sites = 0, {}
end

-- #73: a completed cast/wait/reel cycle spawns and removes a bobber once,
-- and unlocks a locked trade at or below the current tier while leaving a
-- higher tier alone.
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 800
	local water = {x = 5, y = 0, z = 0}
	place(water, "mcl_core:water_source")
	local trades = {
		affordable = {tier = 1, locked = true, trade_counter = 5},
		expensive = {tier = 2, locked = true, trade_counter = 1},
	}
	local fisherman = {
		_id = "f15", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		_villages_fish_target = water, _max_trade_tier = 1,
		_trades = minetest.serialize(trades),
		_villages_fish_session = {phase = "cast", phase_ends_at = now + 2},
		object = {get_pos = function() return {x = 4, y = 0, z = 0} end, set_velocity = function() end},
	}
	spawned_bobbers = {}

	now = now + 2
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_session.phase == "wait")
	assert(fisherman._villages_fish_bobber, "the cast/wait transition must spawn a bobber")
	assert(#spawned_bobbers == 1)

	now = fisherman._villages_fish_session.phase_ends_at
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_session.phase == "reel")
	assert(fisherman._villages_fish_bobber, "the bobber stays out through the reel phase")

	now = fisherman._villages_fish_session.phase_ends_at
	def.do_custom(fisherman, 0.1)
	assert(fisherman._villages_fish_session.phase == "cast", "a completed cycle returns to casting")
	assert(not fisherman._villages_fish_bobber, "the bobber is removed once the cycle completes")
	assert(spawned_bobbers[1].removed)

	local restocked = minetest.deserialize(fisherman._trades)
	assert(not restocked.affordable.locked, "a trade at or below the current tier must unlock")
	assert(restocked.affordable.trade_counter == 0)
	assert(restocked.expensive.locked, "a trade above the current tier must stay locked")
	timeofday = 0
end

-- #73 review: nothing but the session re-pinning state each tick stood
-- between a fisherman and vanilla's do_states_stand, which switches a
-- standing villager to "walk" once a second unless self.order is "stand",
-- "sleep", or "work" (movement.lua:685) -- so the villager could wander off
-- mid-session while the bobber stayed behind at the water.
do
	local def = new_def(function(self)
		-- Mirrors do_states_stand's own order check: only those three orders
		-- keep a standing villager from being sent walking. This runs before
		-- this file's own fishing code gets a say, exactly like vanilla's.
		if self.order ~= "stand" and self.order ~= "sleep" and self.order ~= "work" then
			self.state = "walk"
			self.object:set_velocity({x = 1, y = 0, z = 0})
		end
	end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 1200
	local water = {x = 5, y = 0, z = 0}
	place(water, "mcl_core:water_source")
	local velocity_calls = {}
	local fisherman = {
		_id = "f21", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		order = "wander", -- some pre-existing order, to also check it is restored on exit
		_villages_fish_target = water,
		_villages_fish_session = {phase = "wait", phase_ends_at = now + 8, previous_order = "wander"},
		object = {
			get_pos = function() return {x = 4, y = 0, z = 0} end,
			set_velocity = function(_, v) table.insert(velocity_calls, v) end,
		},
	}
	def.do_custom(fisherman, 0.1)
	assert(fisherman.state == "stand", "the session must undo vanilla's own walk switch every tick")
	assert(fisherman.order == "stand")
	assert(#velocity_calls >= 1 and velocity_calls[#velocity_calls].x == 0,
		"a walk started this same tick must be zeroed back out")

	-- Ending the session must restore whatever order the villager held
	-- before the session pinned it, not leave it stuck on "stand".
	fisherman.following = true
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_session)
	assert(fisherman.order == "wander", "ending a session must restore the villager's prior order")
	timeofday = 0
end

-- #73: following ends the session, removes the bobber, and drops the target
-- and route so a fresh spot is chosen once fishing resumes.
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 900
	local water = {x = 5, y = 0, z = 0}
	place(water, "mcl_core:water_source")
	spawned_bobbers = {}
	local bobber = minetest.add_entity(water, "villages:bobber")
	local fisherman = {
		_id = "f16", _villages_fisherman = true, _profession = "fisherman", state = "stand", following = true,
		_villages_fish_target = water, _villages_fish_route = {status = "arrived"},
		_villages_fish_session = {phase = "wait", phase_ends_at = now + 8},
		_villages_fish_bobber = bobber,
		object = {get_pos = function() return {x = 4, y = 0, z = 0} end, set_velocity = function() end},
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_session)
	assert(not fisherman._villages_fish_target)
	assert(not fisherman._villages_fish_route)
	assert(bobber.removed)
	timeofday = 0
end

-- #73: the session ends when work time ends, which also covers nightfall
-- and thunder since neither is ever inside an is_work_time() window.
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	local water = {x = 5, y = 0, z = 0}
	place(water, "mcl_core:water_source")
	spawned_bobbers = {}
	local bobber = minetest.add_entity(water, "villages:bobber")
	timeofday, now = 0.8, 1000
	local fisherman = {
		_id = "f17", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		_villages_fish_target = water,
		_villages_fish_session = {phase = "wait", phase_ends_at = now + 8},
		_villages_fish_bobber = bobber,
		object = {get_pos = function() return {x = 4, y = 0, z = 0} end, set_velocity = function() end},
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_session)
	assert(bobber.removed)
	timeofday = 0
end

-- #73: the session ends when the water it anchored on stops qualifying.
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	timeofday, now = 0.4, 1100
	local water = {x = 5, y = 0, z = 0}
	place(water, "mcl_core:stone")
	spawned_bobbers = {}
	local bobber = minetest.add_entity(water, "villages:bobber")
	local fisherman = {
		_id = "f18", _villages_fisherman = true, _profession = "fisherman", state = "stand",
		_villages_fish_target = water,
		_villages_fish_session = {phase = "wait", phase_ends_at = now + 8},
		_villages_fish_bobber = bobber,
		object = {get_pos = function() return {x = 4, y = 0, z = 0} end, set_velocity = function() end},
	}
	def.do_custom(fisherman, 0.1)
	assert(not fisherman._villages_fish_session)
	assert(bobber.removed)
	timeofday = 0
end

-- #73: unloading mid-session removes the bobber even though do_custom never
-- runs again for this villager (it may sit in a different, still-loaded
-- mapblock a couple of nodes out over the water).
do
	local def = new_def(function() end)
	dofile("fisherman.lua")(def)
	spawned_bobbers = {}
	local bobber = minetest.add_entity({x = 5, y = 0, z = 0}, "villages:bobber")
	local fisherman = {
		_id = "f19", _villages_fisherman = true,
		_villages_fish_session = {phase = "wait", phase_ends_at = 9999},
		_villages_fish_bobber = bobber,
	}
	def.on_deactivate(fisherman, false)
	assert(bobber.removed)

	-- No session in progress: deactivation must not touch an unrelated object.
	local other_bobber = minetest.add_entity({x = 6, y = 0, z = 0}, "villages:bobber")
	local idle_fisherman = {_id = "f19b", _villages_fisherman = true, _villages_fish_bobber = other_bobber}
	def.on_deactivate(idle_fisherman, false)
	assert(not other_bobber.removed)
end

-- #73: a reload drops a stale session and bobber reference rather than
-- resuming a cycle with no visible bobber (the bobber itself, an ObjectRef,
-- never survives get_staticdata's copy in the first place).
do
	local def = new_def()
	dofile("fisherman.lua")(def)
	local fisherman = {
		_profession = "fisherman",
		_villages_fish_session = {phase = "wait", phase_ends_at = 9999},
		_villages_fish_bobber = {stale = true},
	}
	def.on_activate(fisherman, "", 0.1)
	assert(not fisherman._villages_fish_session)
	assert(not fisherman._villages_fish_bobber)
end

print("fisherman.lua: ok")
