-- Players eat in taverns (#19): a player who sits on a tavern chair at a table
-- with a plate, while the keeper of that tavern is on duty, is served a meal by
-- the same loop the villagers use (meal.lua: the wait, the display on the plate,
-- bites, sounds, particles). The player is a diner table standing in for the
-- villager. Each bite feeds a little through mcl_hunger, so a player who gets up
-- early has only what the bites gave. One meal per player per tavern per game
-- day, kept in memory (a restart may reset it).
--
-- Sitting is found by watching mcl_cozy.players, not by wrapping mcl_cozy.sit:
-- mcl_decor's chairs took mcl_cozy.sit by value as their on_rightclick, so a
-- wrapper would never be called. seat.lua already makes a villager give up a
-- chair a player sits in (#99).
local core = minetest
local JUKEBOX = "mcl_jukebox:jukebox"
-- Where a seated player's mouth is. mcl_playerplus gives the standing eye height 1.6,
-- and mcl_cozy's SIT_EYE_OFFSET (0, -7, 2) in tenth-nodes moves the eyes 0.7 down and
-- 0.2 forward to match the sitting pose; the mouth is about 0.1 below the eyes. mcl_cozy
-- moves the player to the chair node's centre, so heights count from there.
local MOUTH_HEIGHT = 1.6 - 0.7 - 0.1
local MOUTH_FORWARD = 0.2
-- A seated player is at the chair; further than this, they were moved (teleport,
-- respawn): mcl_cozy never clears its entry then.
local CHAIR_REACH = 1.5
-- A full meal: 3 hunger points and 1.5 saturation over the bites.
local HUNGER = 3
local SATURATION = 1.5
-- A meal has 15 bites at the best (EAT_SECONDS / BITE_SECONDS in meal.lua), fewer
-- when a long server step stretches the interval. A bite is worth a tenth, and the
-- meal never gives more than HUNGER, so a slow server still feeds in full.
local BITES = 10

local meal
local M = {}
local diners = {}
local eaten = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function tavern_of(seat, chair)
	local table_pos = seat.focus(chair, "table")
	if not table_pos then return end
	local r, h = seat.SEARCH_RADIUS, seat.SEARCH_HEIGHT
	local best, best_distance
	for _, site in ipairs(core.find_nodes_in_area(
		{x = chair.x - r, y = chair.y - h, z = chair.z - r},
		{x = chair.x + r, y = chair.y + h, z = chair.z + r}, {JUKEBOX})) do
		local distance = vector.distance(chair, site)
		if not best or distance < best_distance then best, best_distance = site, distance end
	end
	return table_pos, best
end

-- One bite's share of the meal, in whole hunger points: the running total rounded up,
-- so any eating gives at least a point. A full player gets nothing.
local function feed(diner)
	local player = core.get_player_by_name(diner.name)
	if not player or not mcl_hunger then return end
	local hunger = mcl_hunger.get_hunger(player)
	if hunger >= 20 then return end
	diner.bites = diner.bites + 1
	local points = math.min(HUNGER, math.ceil(diner.bites * HUNGER / BITES - 1e-6)) - diner.given
	if points > 0 then
		diner.given = diner.given + points
		mcl_hunger.set_hunger(player, math.min(20, hunger + points))
	end
	local share = math.min(SATURATION / BITES, SATURATION - diner.saturated)
	diner.saturated = diner.saturated + share
	if share > 0 then mcl_hunger.saturate(diner.name, share) end
end

local function stop(name)
	local diner = diners[name]
	diners[name] = nil
	if diner and diner.table then meal.stand(diner.table) end
end

local function start(name, chair, seat)
	local table_pos, jukebox = tavern_of(seat, chair)
	local diner = {name = name, chair = key(chair), bites = 0, given = 0, saturated = 0}
	diners[name] = diner
	if not table_pos or not jukebox then return end
	diner.jukebox = jukebox
	diner.eaten_key = name .. "@" .. key(jukebox)
	diner.table = {
		_id = "player:" .. name,
		_villages_seat = {table = table_pos},
		_villages_mouth_at = function()
			local player = core.get_player_by_name(name)
			local pos = player and player:get_pos()
			if not pos then return end
			local yaw = player.get_look_horizontal and player:get_look_horizontal() or 0
			return {x = pos.x - math.sin(yaw) * MOUTH_FORWARD, y = pos.y + MOUTH_HEIGHT,
				z = pos.z + math.cos(yaw) * MOUTH_FORWARD}
		end,
		_villages_meal_day = eaten[diner.eaten_key],
		_villages_on_bite = function() feed(diner) end,
		object = core.get_player_by_name(name),
	}
end

function M.step(dtime, seat)
	local sitting = mcl_cozy and mcl_cozy.players or {}
	for name, diner in pairs(diners) do
		local entry = sitting[name]
		local player = core.get_player_by_name(name)
		if not player or not entry or entry[2] ~= "sit" or key(vector.round(entry[1])) ~= diner.chair
			or player:get_hp() <= 0 or vector.distance(player:get_pos(), entry[1]) > CHAIR_REACH then
			stop(name)
		end
	end
	for name, entry in pairs(sitting) do
		local player = core.get_player_by_name(name)
		if not diners[name] and entry[2] == "sit" and entry[1] and player and player:get_hp() > 0
			and vector.distance(player:get_pos(), entry[1]) <= CHAIR_REACH then
			start(name, vector.round(entry[1]), seat)
		end
		local diner = diners[name]
		if diner and diner.table then
			diner.table.object = core.get_player_by_name(name)
			meal.tick(diner.table, dtime, diner.jukebox)
			if diner.table._villages_meal_day then eaten[diner.eaten_key] = diner.table._villages_meal_day end
		end
	end
	for k, day in pairs(eaten) do
		if day < core.get_day_count() then eaten[k] = nil end
	end
end

function M.install(shared_meal, seat)
	meal = shared_meal
	if core.settings and not core.settings:get_bool("living_villages_player_meals", true) then return end
	if not core.register_globalstep then return end
	core.register_globalstep(function(dtime) M.step(dtime, seat) end)
	core.register_on_leaveplayer(function(player) stop(player:get_player_name()) end)
end

M.diners, M.eaten = diners, eaten
return M
