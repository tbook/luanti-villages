table.copy = table.copy or function(value)
	local result = {}
	for key, item in pairs(value) do result[key] = item end
	return result
end

local now, tod, day = 100, 16000 / 24000, 4
local jukebox = {x = 0, y = 0, z = 0}
local chair = {x = 1, y = 0, z = 0}
local plate = {x = 2, y = 1, z = 0}
local served = ""
local emeralds = 2
local receive_fields, globalstep, shown
local nodes = {
	["0,0,0"] = "mcl_jukebox:jukebox",
	["1,0,0"] = "mcl_decor:chair_wooden",
	["2,1,0"] = "mcl_itemframes:plate",
}
local function key(pos) return pos.x .. "," .. pos.y .. "," .. pos.z end
local plate_inventory = {
	get_size = function() return 1 end,
	is_empty = function() return served == "" end,
	set_stack = function(_, _, _, stack) served = stack end,
}

vector = {
	zero = function() return {x = 0, y = 0, z = 0} end,
	round = function(pos) return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5)} end,
	distance = function(a, b)
		return math.sqrt((a.x-b.x)^2 + (a.y-b.y)^2 + (a.z-b.z)^2)
	end,
}

local keeper = {_id = "keeper", _profession = "tavern_keeper", _jobsite = jukebox,
	state = "stand", collisionbox = {-0.3, 0, -0.3, 0.3, 1.9, 0.3}}
local guest = {_id = "guest", _profession = "farmer", state = "stand",
	collisionbox = {-0.3, 0, -0.3, 0.3, 1.9, 0.3}}
local function object(entity, pos)
	return {
		get_luaentity = function() return entity end,
		get_pos = function() return pos end,
		set_pos = function(_, value) pos = value end,
		set_velocity = function() end,
		set_properties = function() end,
		set_bone_position = function() end,
	}
end
keeper.object = object(keeper, jukebox)
guest.object = object(guest, {x = -3, y = 0, z = 0})

local player = {
	is_player = function() return true end,
	get_player_name = function() return "alice" end,
	get_player_control = function() return {sneak = true} end,
	get_pos = function() return chair end,
	get_inventory = function()
		return {
			contains_item = function(_, _, item) return emeralds >= tonumber(item:match(" (%d+)$")) end,
			remove_item = function(_, _, item) emeralds = emeralds - tonumber(item:match(" (%d+)$")) end,
		}
	end,
}

minetest = {
	get_modpath = function() return "." end,
	get_translator = function() return function(message) return message end end,
	formspec_escape = function(message) return message end,
	get_gametime = function() return now end,
	get_day_count = function() return day end,
	get_timeofday = function() return tod end,
	get_node_or_nil = function(pos) return {name = nodes[key(pos)] or "air"} end,
	get_node = function(pos) return {name = nodes[key(pos)] or "air"} end,
	get_meta = function(pos)
		return {
			get_string = function(_, field)
				return key(pos) == key(jukebox) and field == "villager" and "keeper" or ""
			end,
			get_inventory = function() return plate_inventory end,
		}
	end,
	get_objects_inside_radius = function() return {keeper.object} end,
	find_nodes_in_area = function(_, _, names)
		if names[1] == "mcl_jukebox:jukebox" then return {jukebox} end
		if names[1] == "mcl_itemframes:plate" then return {plate} end
		if names[1] == "group:chair" then return {chair} end
		return {}
	end,
	hash_node_position = key,
	get_item_group = function(name, group)
		return group == "chair" and name == "mcl_decor:chair_wooden" and 1 or 0
	end,
	is_protected = function() return false end,
	register_on_player_receive_fields = function(callback) receive_fields = callback end,
	register_on_leaveplayer = function() end,
	register_globalstep = function(callback) globalstep = callback end,
	get_player_by_name = function() return player end,
	show_formspec = function(_, _, form) shown = form end,
	chat_send_player = function() end,
	add_particle = function() end,
	log = function() end,
}
mcl_cozy = {players = {}}
mcl_itemframes = {update_entity = function() end}
local registered, activity
mobs_mc = {
	register_villager_profession = function(id, definition) registered = {id = id, definition = definition} end,
	register_villager_activity_modifier = function(callback) activity = callback end,
}

local def = {
	on_activate = function() end,
	on_rightclick = function() end,
	do_custom = function() end,
}
dofile("tavern.lua")(def)
assert(registered.id == "tavern_keeper")
assert(registered.definition.jobsite == "mcl_jukebox:jukebox")
assert(activity(16000) == "villages:dinner" and activity(19000) == nil)

guest.gopath = function(self, _, callback)
	callback(self)
	return true
end
def.do_custom(guest, 0.1)
assert(guest._villages_dining, "guest should reach a seat and receive a visual meal")
assert(served == "", "villager meals must not create collectible food")
now = now + 13
def.do_custom(guest, 0.1)
assert(not guest._villages_dining and guest._villages_last_dinner_day == day)
def.do_custom(guest, 0.1)
assert(not guest._villages_dining, "guest must not dine twice in one evening")

def.on_rightclick(keeper, player)
assert(shown and shown:find("Tavern menu", 1, true))
receive_fields(player, "villages:tavern_order", {bread = true})
assert(emeralds == 2 and served == "", "ordering must not charge before delivery")
mcl_cozy.players.alice = {chair, "sit"}
globalstep(1)
assert(emeralds == 1 and served == "mcl_farming:bread")
globalstep(1)
assert(emeralds == 1, "delivery must charge once")
print("tavern service tests passed")
