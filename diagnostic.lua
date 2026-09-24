-- A read-only, privileged inspector for the existing VoxeLibre Lookup Tool.
-- This intentionally reflects state only; it does not claim, release, or alter
-- beds, jobs, paths, or villager AI.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local is_sleep_time = common.is_sleep_time
local BIRTH_RADIUS = 24
local BIRTH_HEIGHT = 12
local BIRTH_INTERVAL_DAYS = 2
local LAST_BIRTH = "villages_last_birth"

local function pos_string(pos)
	if not pos then return "none" end
	return string.format("(%.1f, %.1f, %.1f)", pos.x, pos.y, pos.z)
end

local function distance(a, b)
	if not a or not b then return nil end
	local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(x * x + y * y + z * z)
end

local function node_name(pos)
	local node = pos and core.get_node_or_nil(pos)
	return node and node.name or "unloaded"
end

local function loaded_villager(id, near)
	if not id or id == "" or not core.get_objects_inside_radius then return nil end
	for _, object in ipairs(core.get_objects_inside_radius(near, 64)) do
		local entity = object:get_luaentity()
		if entity and entity.name == "mobs_mc:villager" and entity._id == id then
			return entity
		end
	end
end

local function claim_owner(pos, villager, kind)
	if not pos then return "none (no assigned " .. kind .. ")" end
	if not core.get_node_or_nil(pos) then return "unknown (position is unloaded)" end
	local meta = core.get_meta(pos)
	local player = kind == "bed" and meta:get_string("player") or ""
	if player ~= "" then return "player " .. player end
	local owner = meta:get_string("villager")
	if owner == "" then return "unclaimed" end
	if villager and owner == villager._id then return "this villager" end
	local other = loaded_villager(owner, pos)
	if other then
		return "villager " .. owner .. " (loaded " .. (other._profession or "unemployed") .. ")"
	end
	return "villager " .. owner .. " (not loaded nearby)"
end

local function status_of_claim(pos, id, kind)
	if not pos then return "none assigned" end
	local node = core.get_node_or_nil(pos)
	if not node then return "assigned position is unloaded" end
	local meta = core.get_meta(pos)
	if meta:get_string("villager") ~= id then
		return "assigned " .. kind .. " is not claimed by this villager"
	end
	return "valid claim"
end

local function bed_status(villager)
	local bed = villager._bed
	if not bed then return "none assigned" end
	local node = core.get_node_or_nil(bed)
	if not node then return "assigned position is unloaded" end
	if core.get_item_group(node.name, "bed") ~= 1 then
		return "assigned node is not a bed bottom (" .. node.name .. ")"
	end
	local meta = core.get_meta(bed)
	if meta:get_string("villager") ~= villager._id then
		return "bed is not claimed by this villager"
	end
	if meta:get_string("player") ~= "" then return "bed is player-owned" end
	local top = mcl_beds.get_bed_top(bed)
	if core.get_meta(top):get_string("player") ~= "" then
		return "bed top is player-owned"
	end
	return "valid claim"
end

local function sleep_status(villager, bed_ok)
	if villager._villages_sleeping then return "sleeping" end
	local route = villager._villages_bed_route
	if route and route.status == "travelling" then return "travelling to bed" end
	if route and route.status == "retry" then return "waiting to retry bed route" end
	if not bed_ok then return "no valid claimed bed" end
	if not is_sleep_time() then return "waiting for night" end
	if villager.order ~= "sleep" then return "nighttime, but no sleep order" end
	local pos = villager.object and villager.object:get_pos()
	local d = distance(pos, villager._bed)
	if d and d >= 2 then return string.format("travelling to bed (%.1f nodes away)", d) end
	return "waiting to enter bed"
end

local function bed_route_status(villager)
	local route = villager._villages_bed_route
	if not route then return "none" end
	if route.status == "travelling" then
		return "travelling to " .. pos_string(route.target)
	end
	if route.status == "retry" then
		local remaining = math.max((route.retry_at or core.get_gametime()) - core.get_gametime(), 0)
		local target = route.target and " to " .. pos_string(route.target) or ""
		return string.format("retry in %.0fs%s: %s", remaining, target, route.reason or "unknown failure")
	end
	return route.status
end

local function target_string(target)
	if type(target) == "table" and target.x then return pos_string(target) end
	return target and tostring(target) or "none"
end

local function last_local_birth(pos)
	if not pos or not core.find_nodes_in_area then return nil end
	local minp = {x = pos.x - BIRTH_RADIUS, y = pos.y - BIRTH_HEIGHT, z = pos.z - BIRTH_RADIUS}
	local maxp = {x = pos.x + BIRTH_RADIUS, y = pos.y + BIRTH_HEIGHT, z = pos.z + BIRTH_RADIUS}
	local latest
	for _, bed in ipairs(core.find_nodes_in_area(minp, maxp, {"group:bed"})) do
		local node = core.get_node_or_nil(bed)
		if node and core.get_item_group(node.name, "bed") == 1 then
			local top = mcl_beds.get_bed_top(bed)
			if core.get_node_or_nil(top) and core.get_meta(bed):get_string("player") == ""
				and core.get_meta(top):get_string("player") == "" then
				local last = tonumber(core.get_meta(bed):get_string(LAST_BIRTH))
				if last and (not latest or last > latest) then latest = last end
			end
		end
	end
	return latest
end

local function birth_status(villager, pos)
	if villager.child then return "not eligible (child)" end
	local day = core.get_day_count()
	local checked = villager._villages_birth_check_day == day and "checked today" or "not checked today"
	local last = last_local_birth(pos)
	if last and day - last < BIRTH_INTERVAL_DAYS then
		return string.format("%s; local cooldown until day %d", checked, last + BIRTH_INTERVAL_DAYS)
	end
	return checked .. "; no local birth cooldown"
end

local workstations = {
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

local function inspectable_node(pos)
	local node = core.get_node_or_nil(pos)
	if not node then return nil end
	local bed_group = core.get_item_group(node.name, "bed")
	if bed_group == 2 then
		local dir = core.facedir_to_dir(node.param2)
		pos = {x = pos.x - dir.x, y = pos.y - dir.y, z = pos.z - dir.z}
		node = core.get_node_or_nil(pos)
		if not node then return nil end
		bed_group = node and core.get_item_group(node.name, "bed") or 0
	end
	if bed_group == 1 then return "bed", pos, node end
	if workstations[node.name] or core.get_item_group(node.name, "cauldron") > 0 then
		return "workstation", pos, node
	end
end

local function show_form(player, name, lines)
	local form = "formspec_version[4]size[11,8]" ..
		"textarea[0.35,0.3;10.3,6.9;report;;" .. core.formspec_escape(table.concat(lines, "\n")) .. "]" ..
		"button_exit[4,7.35;3,0.5;close;Close]"
	core.show_formspec(player:get_player_name(), name, form)
end

local function show(player, villager)
	local bed_ok = bed_status(villager) == "valid claim"
	local pos = villager.object and villager.object:get_pos()
	local path_count = type(villager.waypoints) == "table" and #villager.waypoints or 0
	local profession = villager._profession or "unemployed"
	local age = villager.child and "child" or "adult"
	local birth_check = birth_status(villager, pos)
	local lines = {
		"Villager diagnostics (read-only)",
		"",
		"ID: " .. (villager._id or "unknown"),
		"Profession: " .. profession .. "    Age: " .. age,
		"State: " .. (villager.state or "none") .. "    Order: " .. (villager.order or "none"),
		"Sleep pose: " .. (villager._villages_sleeping and "yes" or "no"),
		"Position: " .. pos_string(pos),
		"",
		"Bed: " .. pos_string(villager._bed) .. " [" .. node_name(villager._bed) .. "]",
		"Bed owner: " .. claim_owner(villager._bed, villager, "bed"),
		"Bed claim: " .. bed_status(villager),
		"Sleep status: " .. sleep_status(villager, bed_ok),
		"Bed route: " .. bed_route_status(villager),
		"",
		"Jobsite: " .. pos_string(villager._jobsite) .. " [" .. node_name(villager._jobsite) .. "]",
		"Jobsite owner: " .. claim_owner(villager._jobsite, villager, "jobsite"),
		"Jobsite claim: " .. status_of_claim(villager._jobsite, villager._id, "jobsite"),
		"Path target: " .. target_string(villager._target) .. "    Waypoints: " .. path_count,
		"Births: " .. birth_check,
	}
	show_form(player, "villages:diagnostic", lines)
end

local function show_node(player, kind, pos, node)
	local label = kind == "bed" and "Bed" or "Workstation"
	show_form(player, "villages:" .. kind .. "_diagnostic", {
		label .. " diagnostics (read-only)",
		"",
		"Position: " .. pos_string(pos),
		"Node: " .. node.name,
		"Recorded owner: " .. claim_owner(pos, nil, kind),
		"",
		"Owner resolution is limited to villagers loaded within 64 nodes.",
	})
end

local function permitted(player)
	if not player or not player:is_player() or not core.check_player_privs then return false end
	local name = player:get_player_name()
	return core.check_player_privs(name, {server = true})
		or core.check_player_privs(name, {debug = true})
end

local function install(_)
	local items = core.registered_items or {}
	for _, name in ipairs({"doc_identifier:identifier_solid", "doc_identifier:identifier_liquid"}) do
		local item = items[name]
		if item and item.on_use then
			local original = item.on_use
			local wrapped = function(stack, player, pointed_thing)
				if permitted(player) and pointed_thing then
					if pointed_thing.type == "object" then
						local object = pointed_thing.ref
						local villager = object and object:get_luaentity()
						if villager and villager.name == "mobs_mc:villager" then
							show(player, villager)
							return stack
						end
					elseif pointed_thing.type == "node" then
						local kind, pos, node = inspectable_node(pointed_thing.under)
						if kind then
							show_node(player, kind, pos, node)
							return stack
						end
					end
				end
				return original(stack, player, pointed_thing)
			end
			if core.override_item then
				core.override_item(name, {on_use = wrapped})
			else
				item.on_use = wrapped
			end
		end
	end
end

return install
