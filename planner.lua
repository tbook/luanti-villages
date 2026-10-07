-- A small, bounded A* planner for villager walk positions.  A walk position is
-- the open node occupied by a villager's feet, with suitable support below it.
-- Keeping the graph independent of entity movement makes it usable for beds,
-- jobsites, and later door-aware routes.
local planner = {}

local CHECKPOINT_EVERY = 16

local directions = {
	{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1},
}

local function key(pos)
	return pos.x .. ":" .. pos.y .. ":" .. pos.z
end

local function copy(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function heuristic(a, b)
	return math.abs(a.x - b.x) + math.abs(a.z - b.z) + math.abs(a.y - b.y) * 1.25
end

-- Heap entries are immutable snapshots. A better route to an open position
-- pushes a new entry instead of mutating one that is already in the heap;
-- stale snapshots are discarded when popped.
local function push(heap, entry)
	table.insert(heap, entry)
	local i = #heap
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent].f <= entry.f then break end
		heap[i] = heap[parent]
		i = parent
	end
	heap[i] = entry
end

local function pop(heap)
	if #heap == 0 then return nil end
	local first = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		local i = 1
		while i * 2 <= #heap do
			local child = i * 2
			if child + 1 <= #heap and heap[child + 1].f < heap[child].f then child = child + 1 end
			if heap[child].f >= last.f then break end
			heap[i] = heap[child]
			i = child
		end
		heap[i] = last
	end
	return first
end

local function reconstruct(nodes, node, limit)
	local path = {}
	limit = limit or math.huge
	while node and #path < limit do
		table.insert(path, 1, copy(node.pos))
		node = node.parent and nodes[node.parent] or nil
	end
	return path
end

-- `can_stand(pos)` returns true for an open, head-clear walk position with
-- support beneath. Positions have integral coordinates. `goal(pos)` returns
-- true for an acceptable arrival position. `options.clear(from_pos, to_pos, dy)`
-- is an optional extra check on the edge itself, not just its endpoints; the
-- waypoint mover needs it for a rise, where jumping from `from_pos` swings a
-- villager's head through `from_pos.y + 2`, a column `can_stand(to_pos)` never
-- looks at. `options.gate(pos)` marks a position whose crossing depends on how
-- the route enters and leaves it (a door cell, #121), and `options.crossing(from,
-- gate, to)` then says whether that entry and exit are allowed together. The
-- search keeps one state per way into a gate for that reason. The third return
-- value is `found`, `unreachable`, or `search_limit`. `options.checkpoint()`, if
-- given, is called every few nodes; route_queue.lua uses it to pause a search
-- between steps (#162).
function planner.find_path(start, can_stand, goal, options)
	options = options or {}
	local range = options.range or 48
	local max_nodes = options.max_nodes or 4096
	-- A waypoint mover travels directly between consecutive positions. Limit an
	-- edge to one level so it cannot cut diagonally through floors or walls on a
	-- multi-node drop. Consider every valid height: a higher floor beside the
	-- villager must not hide the stair or descent below it.
	local vertical_offsets = {0, 1, -1}
	local open, nodes, closed = {}, {}, {}
	local gate, crossing = options.gate, options.crossing
	local function state_key(pos, from)
		if from and gate and gate(pos) then
			return key(pos) .. "<" .. (from.x - pos.x) .. ":" .. (from.z - pos.z)
		end
		return key(pos)
	end
	local start_key = key(start)
	local start_node = {pos = copy(start), g = 0, f = 0}
	nodes[start_key] = start_node
	push(open, {key = start_key, g = 0, f = 0})
	local visited = 0
	local closest, closest_distance, closest_cost, closest_path

	while #open > 0 and visited < max_nodes do
		local entry = pop(open)
		local current = nodes[entry.key]
		if current and not closed[entry.key] and current.g == entry.g then
			local current_key = entry.key
			closed[current_key] = true
			visited = visited + 1
			if options.checkpoint and visited % CHECKPOINT_EVERY == 0 then options.checkpoint() end
			local distance = options.distance and options.distance(current.pos)
			if distance and (not closest_distance or distance < closest_distance
				or (distance == closest_distance and current.g < closest_cost)) then
				closest, closest_distance, closest_cost = copy(current.pos), distance, current.g
				closest_path = reconstruct(nodes, current, 12)
			end
			if goal(current.pos) then
				return reconstruct(nodes, current), visited, "found", {
					closest = closest, closest_distance = closest_distance, closest_cost = closest_cost,
					closest_path = closest_path,
				}
			end

			local parent = current.parent and nodes[current.parent]
			local gated = parent and crossing and gate(current.pos)
			for _, direction in ipairs(directions) do
				for _, dy in ipairs(vertical_offsets) do
					local next_pos = {
						x = current.pos.x + direction.x,
						y = current.pos.y + dy,
						z = current.pos.z + direction.z,
					}
					if math.abs(next_pos.x - start.x) <= range
						and math.abs(next_pos.y - start.y) <= range
						and math.abs(next_pos.z - start.z) <= range
						and can_stand(next_pos)
						and (not options.clear or options.clear(current.pos, next_pos, dy))
						and (not gated or crossing(parent.pos, current.pos, next_pos)) then
						local next_key = state_key(next_pos, current.pos)
						if not closed[next_key] then
							local g = current.g + 1 + math.abs(dy) * 0.25
							local known = nodes[next_key]
							if not known or g < known.g then
								local node = {pos = next_pos, g = g, parent = current_key}
								node.f = g + (options.heuristic and options.heuristic(next_pos) or 0)
								nodes[next_key] = node
								push(open, {key = next_key, g = node.g, f = node.f})
							end
						end
					end
				end
			end
		end
	end
	return nil, visited, visited >= max_nodes and "search_limit" or "unreachable", {
		closest = closest, closest_distance = closest_distance, closest_cost = closest_cost,
		closest_path = closest_path,
	}
end

planner.heuristic = heuristic
return planner
