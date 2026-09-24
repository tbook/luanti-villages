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
		if pos.x == 4 then return {name = "mcl_composters:composter"} end
		return {name = "mcl_core:stone"}
	end,
	get_item_group = function(name, group)
		if group == "bed" and name:find("bed", 1, true) then
			return name:find("_top", 1, true) and 2 or 1
		end
		return 0
	end,
	facedir_to_dir = function() return {x = 1, y = 0, z = 0} end,
	get_objects_inside_radius = function()
		return {{get_luaentity = function()
			return {name = "mobs_mc:villager", _id = "villager-2", _profession = "cleric"}
		end}}
	end,
	get_meta = function(pos)
		local values = metadata[key(pos)] or {}
		return {get_string = function(_, name) return values[name] or "" end}
	end,
	get_timeofday = function() return 0.4 end,
	get_gametime = function() return 100 end,
	get_modpath = function() return "." end,
	get_day_count = function() return 3 end,
	find_nodes_in_area = function() return {{x = 1, y = 0, z = 0}} end,
	formspec_escape = function(value) return value end,
	show_formspec = function(name, formname, form)
		shown = {name = name, formname = formname, form = form}
	end,
}
mcl_beds = {get_bed_top = function() return {x = 2, y = 0, z = 0} end}

metadata["1,0,0"] = {villager = "villager-1", villages_last_birth = "2"}
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
			order = "work", state = "stand", waypoints = {{x = 1}}, _villages_birth_check_day = 3,
				_villages_bed_route = {
					status = "travelling", target = {x = 1, y = 0, z = 0}, id = 7, mode = "planner",
					started_at = 70, last_progress_at = 95, last_progress_pos = {x = 4, y = 0, z = 0},
				},
			_villages_job_route = {status = "retry", target = {x = 3, y = 0, z = 0}, retry_at = 120, reason = "test"},
			_villages_job_search_route = {status = "retry", target = {x = 4, y = 0, z = 0}, retry_at = 120, reason = "no route"},
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
	assert(shown.form:find("Bed route: travelling to (1.0, 0.0, 0.0)", 1, true))
	assert(shown.form:find("[id 7, mode planner, age 30s, progress 5s ago, last (4.0, 0.0, 0.0)]", 1, true))
assert(shown.form:find("Jobsite route: retry in 20s to (3.0, 0.0, 0.0): test", 1, true))
assert(shown.form:find("Job search route: retry in 20s to (4.0, 0.0, 0.0): no route", 1, true))
assert(shown.form:find("Births: checked today; local cooldown until day 4", 1, true))
assert(original_uses == 0)

lookup("stack", player, {type = "node", under = {x = 1, y = 0, z = 0}})
assert(shown.formname == "villages:bed_diagnostic")
assert(shown.form:find("Recorded owner: villager villager-1", 1, true))

lookup("stack", player, {type = "node", under = {x = 2, y = 0, z = 0}})
assert(shown.formname == "villages:bed_diagnostic")
assert(shown.form:find("Position: (1.0, 0.0, 0.0)", 1, true))

lookup("stack", player, {type = "node", under = {x = 4, y = 0, z = 0}})
assert(shown.formname == "villages:workstation_diagnostic")
assert(shown.form:find("Recorded owner: villager villager-2 (loaded cleric)", 1, true))

metadata["4,0,0"] = {villager = "villager-1"}
local far_worker = {
	get_luaentity = function()
		return {
			name = "mobs_mc:villager", _id = "villager-1", _profession = "farmer",
			_jobsite = {x = 4, y = 0, z = 0}, order = "work", state = "stand",
			object = {get_pos = function() return {x = 10, y = 0, z = 0} end},
		}
	end,
}
lookup("stack", player, {type = "object", ref = far_worker})
assert(shown.form:find("Work status: travelling to jobsite (6.0 nodes away)", 1, true), shown.form)

local visitor = {
	is_player = function() return true end,
	get_player_name = function() return "visitor" end,
}
lookup("stack", visitor, {type = "object", ref = object})
assert(original_uses == 1)

lookup("stack", player, {type = "node", under = {x = 9, y = 0, z = 0}})
assert(original_uses == 2)

print("diagnostic.lua: ok")
