-- Run with: lua tests/child_jobs.lua
-- Children stay generic villagers until they are adults (#262). Drives the
-- real wrapped do_custom from init.lua with a stand-in for vanilla's job
-- search (mobs_mc/villager.lua: validate_jobsite / get_a_job / employ).
table.copy = table.copy or function(value)
	local result = {}
	for key, item in pairs(value) do result[key] = item end
	return result
end

local nodes, metadata = {}, {}
local function key(pos)
	return ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
end
local function claimed_by(pos)
	return (metadata[key(pos)] or {}).villager or ""
end

local composter = {x = 1, y = 0, z = 0}
local barrel = {x = 5, y = 0, z = 0}
local pulpit = {x = 2, y = 0, z = 0}
nodes[key(composter)] = {name = "mcl_composters:composter"}
nodes[key(barrel)] = {name = "mcl_barrels:barrel_closed"}
nodes[key(pulpit)] = {name = "living_villages:pulpit"}
local jobsite_profession = {
	["mcl_composters:composter"] = "farmer",
	["mcl_barrels:barrel_closed"] = "fisherman",
}
local jobsite_of = {farmer = "mcl_composters:composter", fisherman = "mcl_barrels:barrel_closed"}

vector = {
	new = function(x, y, z) return {x = x, y = y, z = z} end,
	zero = function() return {x = 0, y = 0, z = 0} end,
	offset = function(pos, x, y, z) return {x = pos.x + x, y = pos.y + y, z = pos.z + z} end,
	equals = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
	distance = function(a, b) return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2) end,
}

-- Vanilla paths, trimmed to what #262 runs through.
local function has_traded(self)
	local trades = self._trades and minetest.deserialize(self._trades)
	if type(trades) ~= "table" then return false end
	for _, trade in pairs(trades) do
		if trade.traded_once then return true end
	end
	return false
end

local function employ(self, pos)
	local profession = jobsite_profession[nodes[key(pos)].name]
	local meta = metadata[key(pos)] or {}
	if profession and (meta.villager or "") == "" then
		metadata[key(pos)] = {villager = self._id}
		self._jobsite = pos
		if not has_traded(self) then self._profession = profession end
		return true
	end
end

local function remove_job(self)
	self._jobsite = nil
	if not has_traded(self) then
		self._profession = "unemployed"
		self._trades = nil
	end
end

local function validate_jobsite(self)
	if self._profession == "unemployed" then return false end
	if not self._jobsite or claimed_by(self._jobsite) ~= self._id then
		remove_job(self)
		return false
	end
	return true
end

local searches = 0
local function vanilla_custom(self)
	if not validate_jobsite(self) and (self._profession == "unemployed" or has_traded(self)) then
		searches = searches + 1
		-- Standing beside every workstation: take the first it asks for.
		local wanted = {"mcl_composters:composter", "mcl_barrels:barrel_closed"}
		if has_traded(self) then wanted = {jobsite_of[self._profession]} end
		for _, name in ipairs(wanted) do
			for _, pos in ipairs({composter, barrel}) do
				if nodes[key(pos)].name == name and employ(self, pos) then return end
			end
		end
	end
end

local entity_def = {
	initial_properties = {collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}, mesh = "old.b3d"},
	animation = {stand_start = 1},
	_child_animations = {stand_start = 71},
	head_swivel = "head.control",
	head_bone_position = {x = 0, y = 6.3, z = 0},
	do_custom = vanilla_custom,
	on_activate = function() end,
}
minetest = {
	get_mod_storage = function() return {} end,
	registered_entities = {["mobs_mc:villager"] = entity_def},
	registered_nodes = {
		air = {walkable = false},
		["living_villages:pulpit"] = {},
		["mcl_jukebox:jukebox"] = {},
	},
	register_on_mods_loaded = function(callback) callback() end,
	get_modpath = function() return "." end,
	get_day_count = function() return 0 end,
	find_nodes_in_area = function() return {} end,
	get_gametime = function() return 0 end,
	get_timeofday = function() return 0.9 end,
	get_node_or_nil = function(pos) return nodes[key(pos)] end,
	get_item_group = function() return 0 end,
	deserialize = function(text)
		local chunk = (loadstring or load)(text)
		return chunk and chunk()
	end,
	get_meta = function(pos)
		return {
			get_string = function(_, field) return (metadata[key(pos)] or {})[field] or "" end,
			set_string = function(_, field, value)
				metadata[key(pos)] = metadata[key(pos)] or {}
				metadata[key(pos)][field] = value
			end,
		}
	end,
	get_objects_inside_radius = function() return {} end,
	get_translator = function() return function(message) return message end end,
	get_color_escape_sequence = function() return "" end,
	formspec_escape = function(text) return text end,
	facedir_to_dir = function() return {x = 0, y = 0, z = 1} end,
	log = function() end,
	register_entity = function() end,
}
mcl_beds = {get_bed_top = function() return {x = 0, y = 0, z = 1} end}
mcl_mobs = {mob_class = {
	set_animation = function() end,
	get_staticdata = function() return {} end,
	set_yaw = function() end,
}}

dofile("init.lua")

-- The public candidate query is wired through init.lua and needs no map read,
-- emerge, or private module access.
local public_volume, public_volume_reason = living_villages.terrain.volume({
	{name = "candidate", pos = {x = 0, z = 0}, rotat = "90"},
}, {{name = "candidate", hwidth = 5, hdepth = 7, hheight = 6}}, {
	surface_y = {min = 10, max = 12},
})
assert(public_volume and not public_volume_reason and public_volume.minp.x < 0
	and public_volume.maxp.y > 12, "public API returns a candidate volume without loaded-world services")

local function make_villager(id, fields)
	local props = {mesh = "old.b3d", textures = {"old.png"}}
	local self = {name = "mobs_mc:villager", _id = id, _profession = "unemployed"}
	for k, v in pairs(fields or {}) do self[k] = v end
	self.object = {
		get_pos = function() return {x = 0, y = 0, z = 0} end,
		set_pos = function() end,
		set_yaw = function() end,
		set_velocity = function() end,
		set_acceleration = function() end,
		get_properties = function() return props end,
		set_properties = function(_, values) for k, v in pairs(values) do props[k] = v end end,
		get_luaentity = function() return self end,
	}
	return self, props
end

local function reset()
	metadata = {}
	searches = 0
end

-- An adult beside a free workstation still gets the job.
reset()
local adult = make_villager("adult", {child = false})
entity_def.do_custom(adult, 1)
assert(adult._profession == "farmer", "an adult takes the free workstation")
assert(adult._jobsite and claimed_by(composter) == "adult")

-- A child does not: no profession, no jobsite, no claim, on any tick.
reset()
local kid, kid_props = make_villager("kid", {child = true})
for _ = 1, 5 do entity_def.do_custom(kid, 1) end
assert(kid._profession == "unemployed", "child profession: " .. tostring(kid._profession))
assert(kid._jobsite == nil, "child must hold no jobsite")
assert(kid._trades == nil, "the stand-in trade list must not outlive the call")
assert(claimed_by(composter) == "" and claimed_by(barrel) == "", "no node may be claimed by a child")
assert(not kid_props.textures[1]:find("profession_", 1, true), "child keeps the generic look")
assert(searches > 0, "the vanilla search still ran")

-- Grown up, the same villager takes the job.
kid.child = false
entity_def.do_custom(kid, 1)
assert(kid._profession == "farmer" and claimed_by(composter) == "kid")

-- A child saved with a job (claim, jobsite, trades) becomes generic and
-- releases the node, so an adult can have it.
reset()
metadata[key(composter)] = {villager = "old"}
local old, old_props = make_villager("old", {
	child = true, _profession = "farmer", _jobsite = composter,
	_trades = "return {{tier = 1}}", _max_trade_tier = 1,
})
entity_def.do_custom(old, 1)
assert(old._profession == "unemployed" and old._jobsite == nil and old._trades == nil)
assert(claimed_by(composter) == "", "a saved child's claim is released")
assert(not old_props.textures[1]:find("profession_", 1, true))

-- A saved child fisherman and keeper are generic too: the fisherman wrapper
-- must not restore the profession, nor the skin read the flag.
reset()
metadata[key(barrel)] = {villager = "fish"}
local fish, fish_props = make_villager("fish", {
	child = true, _profession = "fisherman", _villages_fisherman = true,
	_jobsite = barrel, _trades = "return {{tier = 1}}",
})
entity_def.do_custom(fish, 1)
assert(fish._profession == "unemployed" and not fish._villages_fisherman)
assert(fish._jobsite == nil and claimed_by(barrel) == "")
assert(not fish_props.textures[1]:find("profession_fisherman", 1, true))
metadata[key(pulpit)] = {villager = "keeper"}
local keeper = make_villager("keeper", {
	child = true, _profession = "butcher", _villages_keeper = true, _jobsite = pulpit,
})
entity_def.do_custom(keeper, 1)
assert(keeper._profession == "unemployed" and not keeper._villages_keeper)
assert(keeper._jobsite == nil and claimed_by(pulpit) == "")

-- A node claimed by someone else is not released by a saved child.
reset()
metadata[key(composter)] = {villager = "other"}
local thief = make_villager("thief", {child = true, _profession = "farmer", _jobsite = composter})
entity_def.do_custom(thief, 1)
assert(thief._jobsite == nil and claimed_by(composter) == "other")

-- A claim in an unloaded mapblock is kept, and released once it loads.
reset()
metadata[key(composter)] = {villager = "far"}
local far = make_villager("far", {
	child = true, _profession = "farmer", _jobsite = composter,
	_villages_job_route = {status = "walking"},
})
local loaded_node = nodes[key(composter)]
nodes[key(composter)] = nil
entity_def.do_custom(far, 1)
assert(far._jobsite == composter, "an unreadable jobsite must not be forgotten")
assert(claimed_by(composter) == "far", "the claim stays until it can be released")
assert(far._profession == "unemployed")
nodes[key(composter)] = loaded_node
entity_def.do_custom(far, 1)
assert(far._jobsite == nil and claimed_by(composter) == "", "released once the block loads")
assert(far._villages_job_route == nil, "a leftover job route is dropped")

-- A nitwit child stays a nitwit.
reset()
local nit = make_villager("nit", {child = true, _profession = "nitwit"})
entity_def.do_custom(nit, 1)
assert(nit._profession == "nitwit" and claimed_by(composter) == "")

-- A grown child can claim a pulpit (no stale _jobsite stops cleric.lua).
reset()
local cleric = dofile("cleric.lua")
local grown = make_villager("grown", {child = true})
for _ = 1, 3 do entity_def.do_custom(grown, 1) end
grown.child = false
assert(cleric.employ(grown, pulpit), "a grown child can become a cleric")
assert(claimed_by(pulpit) == "grown")

print("child job tests passed")
