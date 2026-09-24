local shown, original_uses = nil, 0
local metadata = {}

local function key(pos)
	return string.format("%d,%d,%d", pos.x, pos.y, pos.z)
end

minetest = {
	registered_items = {
		["doc_identifier:identifier_solid"] = {
			on_use = function(stack)
				original_uses = original_uses + 1
				return stack
			end,
		},
	},
	override_item = function(name, def)
		for field, value in pairs(def) do minetest.registered_items[name][field] = value end
	end,
	check_player_privs = function(name, wanted)
		return name == "admin" and (wanted.server or wanted.debug)
	end,
	get_node_or_nil = function(pos)
		if pos.x == 1 then return {name = "mcl_beds:bed_red_bottom"} end
		if pos.x == 2 then return {name = "mcl_beds:bed_red_top"} end
		return {name = "mcl_villages:composter"}
	end,
	get_item_group = function(name, group)
		return group == "bed" and name:find("bed", 1, true) and 1 or 0
	end,
	get_objects_inside_radius = function()
		return {{get_luaentity = function()
			return {name = "mobs_mc:villager", _id = "villager-2", _profession = "cleric"}
		end}}
	end,
	get_meta = function(pos)
		local values = metadata[key(pos)] or {}
		return {get_string = function(_, name) return values[name] or "" end}
	end,
	get_timeofday = function() return 0.8 end,
	get_gametime = function() return 3600 end,
	formspec_escape = function(value) return value end,
	show_formspec = function(name, formname, form)
		shown = {name = name, formname = formname, form = form}
	end,
}
mcl_beds = {get_bed_top = function() return {x = 2, y = 0, z = 0} end}

metadata["1,0,0"] = {villager = "villager-1"}
metadata["2,0,0"] = {}
metadata["4,0,0"] = {villager = "villager-2"}

dofile("diagnostic.lua")({})
local lookup = minetest.registered_items["doc_identifier:identifier_solid"].on_use
local player = {
	is_player = function() return true end,
	get_player_name = function() return "admin" end,
}
local object = {
	get_luaentity = function()
		return {
			name = "mobs_mc:villager", _id = "villager-1", _profession = "farmer",
			_bed = {x = 1, y = 0, z = 0}, _jobsite = {x = 4, y = 0, z = 0},
			order = "sleep", state = "stand", waypoints = {{x = 1}},
			object = {get_pos = function() return {x = 10, y = 0, z = 0} end},
		}
	end,
}

lookup("stack", player, {type = "object", ref = object})
assert(shown and shown.name == "admin")
assert(shown.form:find("Villager diagnostics", 1, true))
assert(shown.form:find("Profession: farmer", 1, true))
assert(shown.form:find("Bed owner: this villager", 1, true))
assert(shown.form:find("Bed claim: valid claim", 1, true))
assert(shown.form:find("Jobsite owner: villager villager-2 (loaded cleric)", 1, true))
assert(shown.form:find("Jobsite claim: assigned jobsite is not claimed by this villager", 1, true))
assert(shown.form:find("travelling to bed", 1, true))
assert(original_uses == 0)

local visitor = {
	is_player = function() return true end,
	get_player_name = function() return "visitor" end,
}
lookup("stack", visitor, {type = "object", ref = object})
assert(original_uses == 1)

print("diagnostic.lua: ok")
