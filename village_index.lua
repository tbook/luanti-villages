-- Play-testing aid: remember where villages generate, and whether each got a
-- tavern, so /villages_goto can teleport straight to one instead of flying
-- around looking. Only villages generated while this mod is installed are
-- known; VoxeLibre keeps no record of the ones before.
local core = minetest
if not core.get_mod_storage or not core.register_chatcommand then return end
local storage = core.get_mod_storage()
local KEY = "villages"

local function load()
	return core.deserialize(storage:get_string(KEY)) or {}
end

local function record(settlement_info)
	local center = settlement_info[1] and settlement_info[1].pos
	if not center then return end
	local entry = {center = vector.new(center)}
	for _, building in ipairs(settlement_info) do
		if building.name == "tavern" then entry.tavern = vector.new(building.pos) end
	end
	local known = load()
	table.insert(known, entry)
	storage:set_string(KEY, core.serialize(known))
	core.log("action", string.format("[villages] village generated at %s%s",
		core.pos_to_string(entry.center),
		entry.tavern and (", tavern at " .. core.pos_to_string(entry.tavern)) or ", no tavern"))
end

-- place_schematics is looked up on the settlements table at the call
-- (mcl_villages/init.lua build_a_settlement), so wrapping it sees every village.
if settlements and settlements.place_schematics then
	local original = settlements.place_schematics
	settlements.place_schematics = function(settlement_info, ...)
		local result = original(settlement_info, ...)
		record(settlement_info)
		return result
	end
end

-- The nearest known village to pos; with want_tavern, only ones with a tavern.
local function nearest(known, pos, want_tavern)
	local best, best_distance
	for _, entry in ipairs(known) do
		local target
		if want_tavern then target = entry.tavern else target = entry.center end
		if target then
			local distance = vector.distance(pos, target)
			if not best or distance < best_distance then best, best_distance = entry, distance end
		end
	end
	return best, best_distance
end

core.register_chatcommand("villages_goto", {
	params = "[any]",
	description = "Teleport above the nearest tavern generated this world (\"any\": nearest village)",
	privs = {teleport = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "Not in game." end
		local want_tavern = param ~= "any"
		local known = load()
		local entry, distance = nearest(known, player:get_pos(), want_tavern)
		if not entry then
			return false, string.format("No %s recorded yet (%d village(s) known). Explore to generate more.",
				want_tavern and "village with a tavern" or "village", #known)
		end
		-- A building's pos is its schematic corner on the ground; land above
		-- the middle of the tavern's roof rather than inside a wall.
		local target = want_tavern and vector.offset(entry.tavern, 6, 12, 5)
			or vector.offset(entry.center, 0, 12, 0)
		player:set_pos(target)
		return true, string.format("Teleported to %s (%.0f nodes away). Tavern: %s",
			core.pos_to_string(target), distance,
			entry.tavern and core.pos_to_string(entry.tavern) or "none")
	end,
})

return {nearest = nearest}
