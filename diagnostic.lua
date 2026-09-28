-- A read-only, privileged inspector for the existing VoxeLibre Lookup Tool.
-- This intentionally reflects state only; it does not claim, release, or alter
-- beds, jobs, paths, or villager AI.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local is_sleep_time = common.is_sleep_time
local is_work_time = common.is_work_time
local is_workstation_node = common.is_workstation_node
local BIRTH_RADIUS = 24
local BIRTH_HEIGHT = 12
local BIRTH_INTERVAL_DAYS = 2
local LAST_BIRTH = "villages_last_birth"
-- Mirror navigation.lua's own promotion-pond thresholds (#71) so this
-- reports the same pond a fisherman's promotion check would have seen.
-- navigation.lua exposes no public surface beyond its def-installer, and
-- this file must stay read-only, so this is its own small copy rather than
-- a shared call into it.
local WATER_SEARCH_RADIUS = 16
local WATER_VERTICAL_BAND = 2
local WATER_POND_MIN_SPAN = 3
local WATER_POND_MIN_COUNT = WATER_POND_MIN_SPAN * WATER_POND_MIN_SPAN
local WATER_POND_FILL_CAP = 32
local WATER_NEIGHBOR_OFFSETS = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

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

-- Finds the claiming villager's own entity, if it happens to be loaded near
-- its bed/workstation, so a punched-but-empty bed can point at where its
-- occupant actually is instead of just confirming that it is claimed.
local function claim_owner_entity(pos, kind)
	if not pos or not core.get_node_or_nil(pos) then return nil end
	local meta = core.get_meta(pos)
	local player = kind == "bed" and meta:get_string("player") or ""
	if player ~= "" then return nil end
	local owner = meta:get_string("villager")
	if owner == "" then return nil end
	return loaded_villager(owner, pos)
end

local function status_of_claim(pos, id, kind)
	if not pos then return "none assigned" end
	local node = core.get_node_or_nil(pos)
	if not node then return "assigned position is unloaded" end
	if kind == "jobsite" and not is_workstation_node(node.name) then
		return "assigned node is not a workstation (" .. node.name .. ")"
	end
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

local function route_status(route)
	if not route then return "none" end
	local details = {}
	if route.id then table.insert(details, "id " .. route.id) end
	if route.mode then table.insert(details, "mode " .. route.mode) end
	if route.started_at then
		table.insert(details, string.format("age %.0fs", math.max(core.get_gametime() - route.started_at, 0)))
	end
	if route.last_progress_at then
		table.insert(details, string.format("progress %.0fs ago", math.max(core.get_gametime() - route.last_progress_at, 0)))
	end
	if route.last_progress_pos then table.insert(details, "last " .. pos_string(route.last_progress_pos)) end
	local suffix = #details > 0 and " [" .. table.concat(details, ", ") .. "]" or ""
	if route.status == "travelling" then
		return "travelling to " .. pos_string(route.target) .. suffix
	end
	if route.status == "retry" then
		local remaining = math.max((route.retry_at or core.get_gametime()) - core.get_gametime(), 0)
		local target = route.target and " to " .. pos_string(route.target) or ""
		return string.format("retry in %.0fs%s: %s", remaining, target, route.reason or "unknown failure") .. suffix
	end
	if route.status == "arrived" and route.target then
		return "arrived at " .. pos_string(route.target) .. suffix
	end
	return route.status .. suffix
end

local function planner_status(route)
	local report = route and route.planner
	if not report then return "none" end
	local approaches = {}
	for _, pos in ipairs(report.candidates or {}) do table.insert(approaches, pos_string(pos)) end
	local text = "start " .. pos_string(report.start)
		.. "; approaches " .. (#approaches > 0 and table.concat(approaches, ", ") or "none")
		.. "; " .. (report.status or "unknown") .. " after " .. (report.searched or 0) .. " nodes"
	if report.closest then
		text = text .. "; closest " .. pos_string(report.closest)
			.. " (" .. (report.closest_distance or 0) .. " steps from an approach"
			.. (report.closest_cost and ", route cost " .. string.format("%.2f", report.closest_cost) or "") .. ")"
	end
	return text
end

local function planner_trail(route)
	local report = route and route.planner
	if not report or not report.trail or #report.trail == 0 then return "none" end
	local positions = {}
	for _, pos in ipairs(report.trail) do table.insert(positions, pos_string(pos)) end
	return table.concat(positions, " -> ")
end

local function work_status(villager, job_ok)
	local route = villager._villages_job_route
	if route and route.status == "travelling" then return "travelling to jobsite" end
	if route and route.status == "retry" then return "waiting to retry jobsite route" end
	if not job_ok then return "no valid claimed jobsite" end
	if not is_work_time() then return "waiting for work period" end
	local pos = villager.object and villager.object:get_pos()
	local d = distance(pos, villager._jobsite)
	if d and d >= 2 then return string.format("travelling to jobsite (%.1f nodes away)", d) end
	if villager.order == "work" then return "working" end
	return "at jobsite"
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

-- Flood fill outward over contiguous surface water at a single water level,
-- capped the same way navigation.lua's own promotion check is. `visited` is
-- shared across every pond considered by one measure_water call.
local function flood_fill_pond(start, minp, maxp, visited)
	visited[start.x .. ":" .. start.y .. ":" .. start.z] = true
	local queue, head = {start}, 1
	local count = 1
	local min_x, max_x, min_z, max_z = start.x, start.x, start.z, start.z
	while queue[head] and count < WATER_POND_FILL_CAP do
		local pos = queue[head]
		head = head + 1
		for _, offset in ipairs(WATER_NEIGHBOR_OFFSETS) do
			local neighbor = {x = pos.x + offset[1], y = pos.y, z = pos.z + offset[2]}
			local key = neighbor.x .. ":" .. neighbor.y .. ":" .. neighbor.z
			local in_bounds = neighbor.x >= minp.x and neighbor.x <= maxp.x
				and neighbor.z >= minp.z and neighbor.z <= maxp.z
			if not visited[key] and in_bounds then
				visited[key] = true
				if common.is_surface_water(neighbor) then
					count = count + 1
					min_x, max_x = math.min(min_x, neighbor.x), math.max(max_x, neighbor.x)
					min_z, max_z = math.min(min_z, neighbor.z), math.max(max_z, neighbor.z)
					table.insert(queue, neighbor)
					if count >= WATER_POND_FILL_CAP then break end
				end
			end
		end
	end
	return count, max_x - min_x + 1, max_z - min_z + 1
end

-- Reports one pond within range rather than navigation.lua's own
-- short-circuit on the first qualifying one, since a single representative
-- pond is more informative for a diagnostic report. Prefers a qualifying
-- pond (the largest one, if more than one qualifies) over a merely bigger
-- non-qualifying one -- e.g. a 32-tile, one-node-wide channel -- since the
-- qualifying pond is what actually explains a promotion outcome; the
-- reported span/count and the qualifies flag always describe the same pond.
local function measure_water(anchor)
	if not anchor or not core.find_nodes_in_area then return nil end
	local minp = {x = anchor.x - WATER_SEARCH_RADIUS, y = anchor.y - WATER_VERTICAL_BAND, z = anchor.z - WATER_SEARCH_RADIUS}
	local maxp = {x = anchor.x + WATER_SEARCH_RADIUS, y = anchor.y + WATER_VERTICAL_BAND, z = anchor.z + WATER_SEARCH_RADIUS}
	local sites = core.find_nodes_in_area(minp, maxp, {"group:water"})
	local visited = {}
	local best
	for _, site in ipairs(sites) do
		local site_key = site.x .. ":" .. site.y .. ":" .. site.z
		if not visited[site_key] and common.is_surface_water(site) then
			local count, span_x, span_z = flood_fill_pond(site, minp, maxp, visited)
			local qualifies = count >= WATER_POND_MIN_COUNT and span_x >= WATER_POND_MIN_SPAN
				and span_z >= WATER_POND_MIN_SPAN
			if not best or (qualifies and not best.qualifies)
				or (qualifies == best.qualifies and count > best.count) then
				best = {count = count, span_x = span_x, span_z = span_z, qualifies = qualifies}
			end
		end
	end
	if not best then return 0, 0, 0, false end
	return best.count, best.span_x, best.span_z, best.qualifies
end

local function water_status(anchor, label)
	if not anchor then return "no " .. label end
	local count, span_x, span_z, qualifies = measure_water(anchor)
	if not count then return "unavailable" end
	if count == 0 then return "no surface water found near " .. label end
	return string.format("largest pond near %s: %d tile%s, %dx%d span (%s)",
		label, count, count == 1 and "" or "s", span_x, span_z,
		qualifies and "qualifies for promotion" or "too small to qualify")
end

local function fish_session_status(villager)
	local session = villager._villages_fish_session
	if not session then return "none" end
	local remaining = math.max((session.phase_ends_at or core.get_gametime()) - core.get_gametime(), 0)
	return string.format("%s (next phase in %.0fs)", session.phase or "unknown", remaining)
end

-- fisherman.lua eliminates these in the same order every tick (session,
-- then following/work-time/water, then route, then target, then the
-- no-water retry cooldown), so this retraces that order to explain why a
-- fisherman is or is not fishing right now -- the other Fisherman lines
-- report the same underlying fields, but none of them says which one is
-- the actual reason.
local function fisherman_status(villager)
	if not villager._villages_fisherman then return "not a fisherman" end
	if villager._villages_fish_session then return "fishing" end
	if villager.following then return "not fishing: following a player" end
	if not is_work_time() then return "not fishing: waiting for work period" end
	local route = villager._villages_fish_route
	if route and route.status == "travelling" then return "travelling to stand" end
	if route and route.status == "retry" then
		local remaining = math.max((route.retry_at or core.get_gametime()) - core.get_gametime(), 0)
		return string.format("not fishing: waiting %.0fs to retry (%s)", remaining, route.reason or "unknown failure")
	end
	if villager._villages_fish_target then return "not fishing: has a stand but no active session" end
	if villager._villages_fish_next and core.get_gametime() < villager._villages_fish_next then
		return "not fishing: no reachable water found nearby, retrying soon"
	end
	return "not fishing: no stand chosen yet"
end

-- The profession guard (#70) keeps a fisherman's profession/trades intact
-- even after vanilla's own validate_jobsite invalidates its barrel claim, so
-- vanilla's own reporting never surfaces a problem here. Report the claim's
-- real status directly instead.
local function barrel_status(villager)
	if not villager._villages_fisherman then return "n/a (not a fisherman)" end
	if not villager._jobsite then return "none assigned" end
	local node = core.get_node_or_nil(villager._jobsite)
	if node and node.name ~= "mcl_barrels:barrel_closed" then
		return "assigned node is not a barrel (" .. node.name .. ")"
	end
	return status_of_claim(villager._jobsite, villager._id, "jobsite")
end

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
	if is_workstation_node(node.name) then
		return "workstation", pos, node
	end
end

local function show_form(player, name, lines)
	local form = "formspec_version[4]size[11,8]" ..
		"textarea[0.35,0.3;10.3,6.9;report;;" .. core.formspec_escape(table.concat(lines, "\n")) .. "]" ..
		"button_exit[4,7.35;3,0.5;close;Close]"
	core.show_formspec(player:get_player_name(), name, form)
end

local function visual_status(villager)
	local props = villager.object and villager.object:get_properties()
	if not props then return "unavailable (no live properties)" end
	local textures = props.textures and table.concat(props.textures, ", ") or "none"
	local size = props.visual_size
	local size_string = size and string.format("(%.2f, %.2f, %.2f)",
		size.x or 0, size.y or 0, size.z or (size.y or 0)) or "none"
	return string.format("mesh %s, textures [%s], visual_size %s, is_visible %s",
		props.mesh or "none", textures, size_string,
		props.is_visible == nil and "true (default)" or tostring(props.is_visible))
end

local function show(player, villager)
	local bed_ok = bed_status(villager) == "valid claim"
	local job_ok = status_of_claim(villager._jobsite, villager._id, "jobsite") == "valid claim"
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
		"Visual: " .. visual_status(villager),
		"",
		"Bed: " .. pos_string(villager._bed) .. " [" .. node_name(villager._bed) .. "]",
		"Bed owner: " .. claim_owner(villager._bed, villager, "bed"),
		"Bed claim: " .. bed_status(villager),
		"Sleep status: " .. sleep_status(villager, bed_ok),
		"Bed route: " .. route_status(villager._villages_bed_route),
		"Planner: " .. planner_status(villager._villages_bed_route),
		"Planner trail: " .. planner_trail(villager._villages_bed_route),
		"",
		"Jobsite: " .. pos_string(villager._jobsite) .. " [" .. node_name(villager._jobsite) .. "]",
		"Jobsite owner: " .. claim_owner(villager._jobsite, villager, "jobsite"),
		"Jobsite claim: " .. status_of_claim(villager._jobsite, villager._id, "jobsite"),
		"Work status: " .. work_status(villager, job_ok),
		"Jobsite route: " .. route_status(villager._villages_job_route),
		"Jobsite planner: " .. planner_status(villager._villages_job_route),
		"Jobsite planner trail: " .. planner_trail(villager._villages_job_route),
		"Job search route: " .. route_status(villager._villages_job_search_route),
		"Job-search planner: " .. planner_status(villager._villages_job_search_route),
		"Job-search planner trail: " .. planner_trail(villager._villages_job_search_route),
		"",
		"Fisherman flag: " .. (villager._villages_fisherman and "yes" or "no"),
		"Fishing status: " .. fisherman_status(villager),
		"Fish target: " .. pos_string(villager._villages_fish_target),
		"Fish route: " .. route_status(villager._villages_fish_route),
		"Fish planner: " .. planner_status(villager._villages_fish_route),
		"Fish planner trail: " .. planner_trail(villager._villages_fish_route),
		"Fishing session: " .. fish_session_status(villager),
		"Water near bed: " .. water_status(villager._bed, "bed"),
		"Water at fish target: " .. water_status(villager._villages_fish_target, "fish target"),
		"Barrel claim (hidden from vanilla by the profession guard): " .. barrel_status(villager),
		"",
		"Path target: " .. target_string(villager._target) .. "    Waypoints: " .. path_count,
		"Births: " .. birth_check,
	}
	show_form(player, "villages:diagnostic", lines)
end

local function show_node(player, kind, pos, node)
	local label = kind == "bed" and "Bed" or "Workstation"
	local lines = {
		label .. " diagnostics (read-only)",
		"",
		"Position: " .. pos_string(pos),
		"Node: " .. node.name,
		"Recorded owner: " .. claim_owner(pos, nil, kind),
	}
	local owner = claim_owner_entity(pos, kind)
	if owner then
		local owner_pos = owner.object and owner.object:get_pos()
		table.insert(lines, "Owner position: " .. pos_string(owner_pos))
		if kind == "bed" then
			local bed_ok = bed_status(owner) == "valid claim"
			table.insert(lines, "Owner sleep status: " .. sleep_status(owner, bed_ok))
		else
			local job_ok = status_of_claim(owner._jobsite, owner._id, "jobsite") == "valid claim"
			table.insert(lines, "Owner work status: " .. work_status(owner, job_ok))
		end
	end
	table.insert(lines, "")
	table.insert(lines, "Owner resolution is limited to villagers loaded within 64 nodes.")
	show_form(player, "villages:" .. kind .. "_diagnostic", lines)
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
