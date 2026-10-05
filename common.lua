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
	-- A nodebox with no collision box of its own collides as its node box
	-- (Luanti does this): a carpet is a sixteenth of a node thick, not a block.
	local box = def and (def.collision_box or (def.drawtype == "nodebox" and def.node_box))
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
--
-- With thin_ok, a carpet counts as clear: it is a walkable sliver a villager
-- stands on top of, and the church floor (#126) is laid with it.
local function is_clear(pos, thin_ok)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	if not def then return false end
	if thin_ok and core.get_item_group(node.name, "carpet") > 0 then return true end
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
	-- Nor are fence gates or walls: do_jump (mcl_mobs/movement.lua) will not
	-- jump them, so a villager never gets up onto one.
	for _, group in ipairs({"fence", "fence_gate", "wall", "trapdoor"}) do
		if core.get_item_group(node.name, group) > 0 then return false end
	end
	return not is_hazard(node.name, def)
end

-- Whether every node the standing box at pos touches, from layer bottom to
-- top, is clear.
local function box_is_clear(pos, bottom, top, thin_ok)
	-- Shrink the span by a hair so a box whose edge lands exactly on a node
	-- boundary is not treated as reaching into the node beyond it. Villagers
	-- stand on half-node offsets constantly, so without this the check
	-- rejects a node the villager only touches -- most often the bed it is
	-- climbing out of, since a bed is walkable.
	for x = round(pos.x - HALF_WIDTH + EDGE), round(pos.x + HALF_WIDTH - EDGE) do
		for z = round(pos.z - HALF_WIDTH + EDGE), round(pos.z + HALF_WIDTH - EDGE) do
			for y = bottom, top do
				if not is_clear({x = x, y = y, z = z}, thin_ok) then return false end
			end
		end
	end
	return true
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

-- Holidays (#124) fall on every full moon and new moon, every 4 days. The
-- holiday tables apply instead of the two above and share their wrap at
-- midnight. "church" is the villagers' service and "pulpit" and "service" the
-- cleric's; vanilla knows none of them, nor "bell", until their own issues
-- give them behavior (#10).
local HOLIDAY_SCHEDULE = {
	{start = 5500, stage = "putter"},
	{start = 7000, stage = "church"},
	{start = 10500, stage = "bell"},
	{start = 13500, stage = "tavern"},
	{start = 17500, stage = "home"},
	{start = 18500, stage = "sleep"},
}
local HOLIDAY_CLERIC_SCHEDULE = {
	{start = 5500, stage = "pulpit"},
	{start = 7000, stage = "service"},
	{start = 10500, stage = "bell"},
	{start = 13500, stage = "tavern"},
	{start = 17500, stage = "home"},
	{start = 18500, stage = "sleep"},
}
local HOLIDAY_KEEPER_SCHEDULE = {
	{start = 7000, stage = "putter"},
	{start = 8000, stage = "free"},
	{start = 13000, stage = "staff"},
	{start = 18500, stage = "home"},
	{start = 19000, stage = "sleep"},
}

-- mcl_moon advances the phase at midday, so a day's morning reads one phase
-- behind its evening. The evening's phase stands for the whole day, which keeps
-- the church morning and the bell afternoon on the same holiday.
local function is_holiday()
	if mcl_moon and mcl_moon.get_moon_phase then
		local phase = mcl_moon.get_moon_phase()
		if core.get_timeofday() <= 0.5 then phase = phase + 1 end
		return phase % 4 == 0
	end
	return core.get_day_count and core.get_day_count() % 4 == 0 or false
end

local function is_thunder()
	return mcl_weather and mcl_weather.get_weather
		and mcl_weather.get_weather() == "thunder" or false
end

-- tod is core.get_timeofday()'s 0..1 fraction; omit it for the current time.
-- villager picks that villager's own timetable; omit it for the common one.
-- A thunderstorm sends everyone to bed at any hour.
local function stage_at(tod, villager)
	if is_thunder() then return "sleep" end
	local schedule = SCHEDULE
	if is_holiday() then
		schedule = HOLIDAY_SCHEDULE
		if villager and villager._villages_keeper then
			schedule = HOLIDAY_KEEPER_SCHEDULE
		elseif villager and villager._profession == "cleric" then
			schedule = HOLIDAY_CLERIC_SCHEDULE
		end
	elseif villager and villager._villages_keeper then
		schedule = KEEPER_SCHEDULE
	end
	local ticks = ((tod or core.get_timeofday()) * 24000) % 24000
	local stage = schedule[#schedule].stage
	for _, entry in ipairs(schedule) do
		if ticks < entry.start then break end
		stage = entry.stage
	end
	-- A villager with no tavern tonight, or too late to reach it, goes
	-- straight Home instead (#22); tavern.lua marks the day.
	if stage == "tavern" and villager and core.get_day_count
		and villager._villages_skip_tavern == core.get_day_count() then
		return "home"
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
	church = "church",
	pulpit = "pulpit",
	service = "service",
	bell = "bell",
}

-- Vanilla calls get_activity() with no villager at all, so init.lua names
-- the villager whose do_activity is running around that call.
local current_villager

return {
	schedule_stage = stage_at,
	is_holiday = is_holiday,
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
	-- With thin_ok, carpet in the villager's own cell does not count against it.
	-- Only there: carpet at head height still blocks.
	is_standing_space = function(pos, thin_ok)
		local feet = round(pos.y)
		return box_is_clear(pos, feet, feet, thin_ok) and box_is_clear(pos, feet + 1, feet + HEIGHT_NODES - 1)
			and is_supported({x = round(pos.x), y = feet, z = round(pos.z)})
	end,
	-- The two halves of is_standing_space, for a villager partway over a step
	-- or a kerb: its box already reaches over the next floor while its center
	-- is still over the last one.
	is_body_clear = function(pos)
		local feet = round(pos.y)
		return box_is_clear(pos, feet, feet + HEIGHT_NODES - 1)
	end,
	has_floor = function(pos)
		return is_supported({x = round(pos.x), y = round(pos.y), z = round(pos.z)})
	end,
	-- Whether the single node at pos is one a villager's body may pass through.
	is_clear_node = function(pos)
		return is_clear({x = round(pos.x), y = round(pos.y), z = round(pos.z)})
	end,
	-- Whether the node layer just above a villager standing at pos is clear
	-- across its whole box. A step up is a jump that lifts the head into that
	-- layer before the villager has moved over the higher floor (#56).
	has_headroom = function(pos)
		local above = round(pos.y) + HEIGHT_NODES
		return box_is_clear(pos, above, above)
	end,
	-- The node a villager's feet are in. The entity position sits a hair
	-- above the floor, and below a node boundary on a lowered floor such as
	-- a grass path, so sample where mcl_mobs/physics.lua samples the feet.
	feet_node = function(pos) return round(pos.y + FEET_OFFSET) end,
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
