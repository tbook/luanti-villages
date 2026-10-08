-- Route checking shared by tests/stock_buildings.lua and tests/stock_church.lua
-- (#159): the rules a route is held to, none of them the planner's own, and the
-- bookkeeping for cases a known-failures list expects to fail.
local stock_world = dofile("tests/support/stock_world.lua")

local function cell_string(pos)
	return ("(%d,%d,%d)"):format(pos.x, pos.y, pos.z)
end

-- Facts about mcl_doors (api_doors.lua), verified for #121 and kept here rather
-- than taken from doors.lua so that a regression there cannot excuse itself: every
-- variant's leaf lies on one edge of its node, which for facedir p is north, west,
-- south or east for p 0..3; toggling a door turns it a quarter, forward when it is
-- closed and not mirrored or open and mirrored, back otherwise. The variants are
-- named _b_ or _t_ then 1 closed, 2 open, 3 closed mirrored, 4 open mirrored.
local LEAF_EDGE = {[0] = "n", "w", "s", "e"}

local function door_blocks(node, entry_edge, exit_edge)
	local variant = tonumber(node.name:match("_[bt]_(%d)$"))
	local open, mirrored = variant % 2 == 0, variant > 2
	local forward = open == mirrored
	local toggled = (node.param2 + (forward and 1 or -1)) % 4
	for _, leaf in ipairs({LEAF_EDGE[node.param2 % 4], LEAF_EDGE[toggled]}) do
		if leaf ~= entry_edge and leaf ~= exit_edge then return false end
	end
	return true
end

local function edge_toward(from, to)
	if to.x > from.x then return "e" elseif to.x < from.x then return "w" end
	return to.z > from.z and "s" or "n"
end

-- How high a node's collision reaches above the node's center: 0.5 for a full
-- cube, less for a slab or carpet, more for a fence.
local function collision_top(def)
	local box = def.collision_box or (def.drawtype == "nodebox" and def.node_box)
	if not box or box.type ~= "fixed" then return 0.5 end
	local fixed = box.fixed
	if type(fixed[1]) == "number" then return fixed[5] end
	local top = -0.5
	for _, part in ipairs(fixed) do top = math.max(top, part[5]) end
	return top
end

-- The rules a route is held to, none of them the planner's own: each step is to
-- a neighboring cell at most a level up or down; every cell has floor to stand on
-- (a full-height solid that is not a fence, wall or trapdoor); no feet cell is
-- inside something solid, and the head cell over each is free, carpet at the feet
-- being the one thing a villager stands in; a step up has the cell above the
-- departure head free, since the jump swings the head through it (#56); a door
-- is crossed by an entry and exit its leaf lets through in one state or the other;
-- and the route ends beside the target.
local function check_route(world, cells, target)
	local defs = stock_world.defs
	local function group(pos, name)
		local found = defs[world.get(pos).name].groups[name]
		return found and found > 0
	end
	local function solid(pos, feet)
		local def = defs[world.get(pos).name]
		if group(pos, "door") then return false end
		if feet and group(pos, "carpet") then return false end
		return def.walkable or (def.collision_box and def.collision_box.type ~= "none")
	end
	local function floor_under(cell)
		local below = {x = cell.x, y = cell.y - 1, z = cell.z}
		local def = defs[world.get(below).name]
		-- A full block, or the sixteenth or two short of one that a grass path or
		-- farmland is.
		if not def.walkable or collision_top(def) < 0.4 or (def.damage_per_second or 0) > 0 then return false end
		return not (group(below, "fence") or group(below, "fence_gate") or group(below, "wall") or group(below, "trapdoor"))
	end
	for i, cell in ipairs(cells) do
		local previous = cells[i - 1]
		if previous then
			local dx, dz, dy = math.abs(cell.x - previous.x), math.abs(cell.z - previous.z), cell.y - previous.y
			if dx + dz ~= 1 or math.abs(dy) > 1 then
				return false, "steps from " .. cell_string(previous) .. " to " .. cell_string(cell)
			end
			local over = {x = previous.x, y = previous.y + 2, z = previous.z}
			if dy == 1 and solid(over) then
				return false, ("jumps from %s into %s at %s"):format(cell_string(previous), world.get(over).name, cell_string(over))
			end
		end
		local head = {x = cell.x, y = cell.y + 1, z = cell.z}
		if not floor_under(cell) then
			return false, ("no floor under %s, which is %s"):format(cell_string(cell),
				world.get({x = cell.x, y = cell.y - 1, z = cell.z}).name)
		end
		if solid(cell, true) then
			return false, ("feet inside %s at %s"):format(world.get(cell).name, cell_string(cell))
		end
		if solid(head) then
			return false, ("head inside %s at %s"):format(world.get(head).name, cell_string(head))
		end
		if group(cell, "door") and previous and cells[i + 1] then
			if door_blocks(world.get(cell), edge_toward(cell, previous), edge_toward(cell, cells[i + 1])) then
				return false, "the leaf of the door at " .. cell_string(cell) .. " blocks the turn"
			end
		end
	end
	local last = cells[#cells]
	if math.abs(last.x - target.x) > 1 or math.abs(last.z - target.z) > 1 or last.y ~= target.y then
		return false, "ends at " .. cell_string(last) .. ", away from the target"
	end
	return true
end

-- A recorder over a known-failures list: record(id, ok, detail) per case, then
-- finish(label, only) to print the result and exit nonzero on anything unexpected.
local function recorder(known, verbose)
	local r = {passes = 0, failures = 0, unexpected = {}}
	local known_hits = {}
	local function known_rule(id)
		for index, rule in ipairs(known) do
			if id:find(rule.match) then
				known_hits[index] = true
				return rule
			end
		end
	end
	function r.record(id, ok, detail)
		if ok then
			r.passes = r.passes + 1
			if known_rule(id) then
				table.insert(r.unexpected, id .. " passes now; remove its rule from the known-failures list")
			end
			if verbose then print("ok   " .. id) end
		else
			r.failures = r.failures + 1
			if not known_rule(id) then table.insert(r.unexpected, id .. ": " .. tostring(detail)) end
			if verbose then print("FAIL " .. id .. ": " .. tostring(detail)) end
		end
	end
	function r.finish(label, only)
		for index, rule in ipairs(known) do
			if not known_hits[index] and (not only or rule.match:find("^%^" .. only)) then
				table.insert(r.unexpected, "known failure " .. rule.match .. " matched no case; remove it")
			end
		end
		if #r.unexpected > 0 then
			print(#r.unexpected .. " unexpected result(s):")
			for _, line in ipairs(r.unexpected) do print("  " .. line) end
			os.exit(1)
		end
		print(("%s: %d routes passed, %d known failures"):format(label, r.passes, r.failures))
	end
	return r
end

return {
	cell_string = cell_string, check_route = check_route, door_blocks = door_blocks,
	edge_toward = edge_toward, recorder = recorder,
}
