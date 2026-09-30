-- Shared, side-effect-free helpers used by villager behavior and diagnostics.
local core = minetest
local workstation_nodes = {
	["mcl_composters:composter"] = true,
	["mcl_barrels:barrel_closed"] = true,
	["mcl_fletching_table:fletching_table"] = true,
	["mcl_loom:loom"] = true,
	["mcl_lectern:lectern"] = true,
	["mcl_cartography_table:cartography_table"] = true,
	["mcl_blast_furnace:blast_furnace"] = true,
	["mcl_smoker:smoker"] = true,
	["mcl_grindstone:grindstone"] = true,
	["mcl_smithing_table:table"] = true,
	["mcl_brewing:stand_000"] = true,
	["mcl_stonecutter:stonecutter"] = true,
}
local farm_replant_nodes = {
	["mcl_farming:wheat"] = "mcl_farming:wheat_1",
	["mcl_farming:potato"] = "mcl_farming:potato_1",
	["mcl_farming:carrot"] = "mcl_farming:carrot_1",
	["mcl_farming:beetroot"] = "mcl_farming:beetroot_0",
}

-- Used when a villager who has already traded loses a jobsite: it may seek
-- only a replacement for its existing profession.
local workstation_professions = {
	["mcl_composters:composter"] = "farmer",
	["mcl_barrels:barrel_closed"] = "fisherman",
	["mcl_fletching_table:fletching_table"] = "fletcher",
	["mcl_loom:loom"] = "shepherd",
	["mcl_lectern:lectern"] = "librarian",
	["mcl_cartography_table:cartography_table"] = "cartographer",
	["mcl_blast_furnace:blast_furnace"] = "armorer",
	["mcl_smoker:smoker"] = "butcher",
	["mcl_grindstone:grindstone"] = "weapon_smith",
	["mcl_smithing_table:table"] = "tool_smith",
	["mcl_brewing:stand_000"] = "cleric",
	["mcl_stonecutter:stonecutter"] = "mason",
}
local workstation_search_node_names = {"group:cauldron"}
for name in pairs(workstation_nodes) do table.insert(workstation_search_node_names, name) end

local function collision_box_top(def)
	local box = def and def.collision_box
	if not box or box.type ~= "fixed" then return 0.5 end
	local fixed = box.fixed
	if type(fixed) ~= "table" then return -0.5 end
	if type(fixed[1]) == "number" then return fixed[5] or -0.5 end
	local top = -0.5
	for _, part in ipairs(fixed) do
		if type(part) == "table" and type(part[5]) == "number" then top = math.max(top, part[5]) end
	end
	return top
end

-- mobs_mc/villager.lua's collisionbox: {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}.
local HALF_WIDTH = 0.3
local HEIGHT_NODES = 2
-- mcl_mobs/physics.lua: feet_pos = pos + (-collisionbox[2]) + 0.25.
local FEET_OFFSET = 0.01 + 0.25
local EDGE = 0.001

local function round(value)
	return math.floor(value + 0.5)
end

local function is_hazard(name, def)
	if (def.damage_per_second or 0) > 0 then return true end
	return core.get_item_group(name, "fire") > 0
		or core.get_item_group(name, "cactus") > 0
		or core.get_item_group(name, "dangerous") > 0
end

-- A node the villager's body may pass through: not something it collides with,
-- and not something that hurts it. Openness alone is not enough -- fire is not
-- walkable, carries no collision box and is not a liquid, so a check that only
-- asks whether a villager fits would happily place one in a fire.
local function is_clear(pos)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	if not def then return false end
	if def.walkable or (def.collision_box and def.collision_box.type ~= "none") then return false end
	if def.liquidtype and def.liquidtype ~= "none" then return false end
	return not is_hazard(node.name, def)
end

local function is_supported(pos)
	local node = core.get_node_or_nil({x = pos.x, y = pos.y - 1, z = pos.z})
	local def = node and core.registered_nodes[node.name]
	if not def or not def.walkable then return false end
	-- A villager's feet rest on the top of the supporting node. Low slabs do not
	-- reach that height; fences and trapdoors are not walkable floor surfaces.
	if collision_box_top(def) < 0.49 then return false end
	if core.get_item_group(node.name, "fence") > 0 or core.get_item_group(node.name, "trapdoor") > 0 then
		return false
	end
	return not is_hazard(node.name, def)
end

-- The villager day (#22), in game ticks (1000 ticks = 1 game hour). Every
-- stage runs from its start until the next stage's start, wrapping at
-- midnight. These tables drive both this mod's own time checks and the
-- get_activity wrapper handed to VoxeLibre below. Tavern keepers (#15) open
-- before dinner and close up after the last guest, so they sleep last.
local SCHEDULE = {
	{start = 5500, stage = "putter"},
	{start = 7000, stage = "work"},
	{start = 15500, stage = "tavern"},
	{start = 17500, stage = "home"},
	{start = 18500, stage = "sleep"},
}
local KEEPER_SCHEDULE = {
	{start = 7000, stage = "putter"},
	{start = 8000, stage = "free"},
	{start = 14000, stage = "staff"},
	{start = 18500, stage = "home"},
	{start = 19000, stage = "sleep"},
}

local function is_thunder()
	return mcl_weather and mcl_weather.get_weather
		and mcl_weather.get_weather() == "thunder" or false
end

-- tod is core.get_timeofday()'s 0..1 fraction; omit it for the current time.
-- villager picks that villager's own timetable; omit it for the common one.
-- A thunderstorm sends everyone to bed at any hour.
local function stage_at(tod, villager)
	if is_thunder() then return "sleep" end
	local schedule = villager and villager._villages_keeper and KEEPER_SCHEDULE or SCHEDULE
	local ticks = ((tod or core.get_timeofday()) * 24000) % 24000
	local stage = schedule[#schedule].stage
	for _, entry in ipairs(schedule) do
		if ticks < entry.start then break end
		stage = entry.stage
	end
	return stage
end

-- What VoxeLibre's do_activity (mobs_mc/villager.lua) should do in each
-- stage. It understands only "work", "sleep" and "gathering"; anything else
-- makes it clear self.order and leave the villager to this mod. "sleep"
-- during Home walks the villager to its bed, where is_sleep_time keeps it
-- standing until the Sleep stage lets it lie down. A keeper's "free" hours
-- are vanilla's own aimless wander, and staffing is its work at the jukebox.
local vanilla_activity = {
	putter = "putter",
	work = "work",
	tavern = "tavern",
	home = "sleep",
	sleep = "sleep",
	free = "free",
	staff = "work",
}

-- Vanilla calls get_activity() with no villager at all, so init.lua names
-- the villager whose do_activity is running around that call.
local current_villager

return {
	schedule_stage = stage_at,
	-- Replacement for VoxeLibre's get_activity(tod), which villager.lua
	-- declares without `local` and looks up as a global on every call.
	get_activity = function(tod) return vanilla_activity[stage_at(tod, current_villager)] end,
	-- Runs fn(...) with get_activity answering for villager.
	as_villager = function(villager, fn, ...)
		local previous = current_villager
		current_villager = villager
		local result = fn(...)
		current_villager = previous
		return result
	end,
	-- Lying down in bed.
	is_sleep_time = function(villager) return stage_at(nil, villager) == "sleep" end,
	-- Heading to, or staying at, the claimed bed.
	is_home_time = function(villager)
		local stage = stage_at(nil, villager)
		return stage == "home" or stage == "sleep"
	end,
	-- At the jobsite: ordinary work, or a keeper staffing the tavern.
	is_work_time = function(villager)
		local stage = stage_at(nil, villager)
		return stage == "work" or stage == "staff"
	end,
	is_workstation_node = function(name)
		return workstation_nodes[name] or core.get_item_group(name, "cauldron") > 0
	end,
	farm_replant_node = function(name) return farm_replant_nodes[name] end,
	-- Whether a villager's full standing box fits at pos, clear of obstructions
	-- and hazards, over a solid floor. Checked before returning a villager to a
	-- position recorded earlier, since the world can change in between and a
	-- villager left inside an opaque node suffocates to death within seconds
	-- (mcl_mobs/physics.lua's do_env_damage).
	--
	-- Every node the box touches is tested, not just the column pos falls in.
	-- A recorded exit is a continuous position rather than a node center, and
	-- the box is 0.6 nodes across (mobs_mc/villager.lua's collisionbox), so a
	-- villager standing at x = 0.4 reaches to x = 0.7 -- into a wall whose node
	-- begins at x = 0.5, while the column at x = 0 still reads as open. The
	-- floor is only required under the center column, since standing with part
	-- of the box over an edge is ordinary.
	is_standing_space = function(pos)
		-- Shrink the span by a hair so a box whose edge lands exactly on a node
		-- boundary is not treated as reaching into the node beyond it. Villagers
		-- stand on half-node offsets constantly, so without this the check
		-- rejects a node the villager only touches -- most often the bed it is
		-- climbing out of, since a bed is walkable.
		local min_x, max_x = round(pos.x - HALF_WIDTH + EDGE), round(pos.x + HALF_WIDTH - EDGE)
		local min_z, max_z = round(pos.z - HALF_WIDTH + EDGE), round(pos.z + HALF_WIDTH - EDGE)
		local feet = round(pos.y)
		for x = min_x, max_x do
			for z = min_z, max_z do
				for y = feet, feet + HEIGHT_NODES - 1 do
					if not is_clear({x = x, y = y, z = z}) then return false end
				end
			end
		end
		return is_supported({x = round(pos.x), y = feet, z = round(pos.z)})
	end,
	-- Whether a villager standing here is being suffocated by the node its feet
	-- are in. Mirrors the condition in mcl_mobs/physics.lua's do_env_damage,
	-- which is what actually deals the damage, so that a report from here means
	-- the villager really is dying rather than merely standing somewhere odd:
	-- a bed, a carpet or tall grass all fail this, a wall does not.
	is_suffocating = function(pos)
		-- Sample the node mcl_mobs itself samples: physics.lua takes the feet at
		-- the collision box's own base plus a quarter node, not the entity
		-- position, so rounding pos directly disagrees with it over part of
		-- every node and would report the wrong node near a boundary.
		local node = core.get_node_or_nil({
			x = round(pos.x), y = round(pos.y + FEET_OFFSET), z = round(pos.z),
		})
		local def = node and core.registered_nodes[node.name]
		if not def then return false end
		if def.walkable == false then return false end
		if def.collision_box and def.collision_box.type ~= "regular" then return false end
		if def.node_box and def.node_box.type ~= "regular" then return false end
		if core.get_item_group(node.name, "disable_suffocation") == 1 then return false end
		return core.get_item_group(node.name, "opaque") == 1, node.name
	end,
	is_surface_water = function(pos)
		local node = core.get_node_or_nil(pos)
		local def = node and core.registered_nodes[node.name]
		if not def or def.liquidtype ~= "source" then return false end
		local above = core.get_node_or_nil({x = pos.x, y = pos.y + 1, z = pos.z})
		return above ~= nil and above.name == "air"
	end,
	workstation_profession = function(name)
		return workstation_professions[name]
			or (core.get_item_group(name, "cauldron") > 0 and "leatherworker")
	end,
	workstation_search_nodes = function() return workstation_search_node_names end,
}
