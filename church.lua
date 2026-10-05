-- Church service on holidays (#126): in the Church stage (#124) every adult
-- walks to the nearest church, one with a pulpit (#21), and takes a pew, a
-- chair facing the pulpit (seat.lua), or stands at the back if the pews are
-- full. The cleric who claimed the pulpit (cleric.lua) stands beside it facing
-- the congregation during the Pulpit and Service stages. With no church within
-- reach, or none a villager can walk to, the villager putters as on any
-- morning. At the end of the stage seats are released and the bell gathering (bell.lua) follows.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local cleric = dofile(core.get_modpath("living_villages") .. "/cleric.lua")
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local PULPIT = "living_villages:pulpit"
-- How far from its bed a villager looks for a church: its own village, as for
-- the tavern (tavern.lua).
local SEARCH_RADIUS = 48
local SEARCH_HEIGHT = 16
-- How often a villager with no church, or no seat, looks again.
local SEARCH_SECONDS = 5
-- A reserved standing place lapses unless its villager renews it, as a chair
-- reservation does (seat.lua).
local HOLD_SECONDS = 10
-- A villager that cannot get to its place in this long passes the church over
-- for UNREACHABLE_SECONDS: the rest of the 3.5 hour service, at 100 s of game
-- time per in-game hour. The walk may start anywhere in the village, so the
-- allowance grows with the distance.
local WALK_BASE = 40
local WALK_PER_NODE = 2
local WALK_MAX = 300
local UNREACHABLE_SECONDS = 200
-- The cleric's extra time for the dais: the walk to its edge, the step up, and
-- along to the pulpit.
local CLIMB_SECONDS = 30
-- Close enough to a standing place to be there. gopath counts carpet as solid,
-- so for a carpeted place it aims at the node above, and check_gowp ends the
-- walk anywhere within 1.8 nodes of that (mcl_mobs/pathfinding.lua): up to a
-- node short on the place's own level.
local AT_PLACE = 1.5
local LEG_REACH = 1.1
-- check_gowp also ends a walk within 1.8 nodes of its target, so the walk along
-- the dais can stop that far from the cleric's place, on the dais's level.
local AT_PULPIT = 1.8
-- How far along the dais from the cleric's place to look for a way up.
local DAIS_REACH = 6
-- Inside the church: close enough to the pulpit to look for a pew.
local INSIDE = 9
-- The back of the church, measured from the pulpit along the way it faces: far
-- enough to leave the dais clear, and short of the far wall, where the stock
-- church has its doorway (it starts 6 from the pulpit, with a wall at 6).
local BACK_MIN = 3
local BACK_MAX = 5
local BACK_REACH = 8
local FIELDS = {"_villages_church", "_villages_church_skipped", "_villages_church_checked"}

local standing = {}
local seat

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function now()
	return core.get_gametime()
end

local function same(a, b)
	return a.x == b.x and a.y == b.y and a.z == b.z
end

local function held_by_other(pos, id)
	local hold = standing[key(pos)]
	return hold and hold.id ~= id and hold.until_time >= now()
end

-- The way the pulpit faces: toward its congregation (church_schematic.lua).
local function audience(pulpit)
	local node = core.get_node_or_nil(pulpit)
	if not node or node.name ~= PULPIT then return end
	return core.facedir_to_dir(node.param2 % 32)
end

-- Where the cleric stands: behind the pulpit, looking out at the congregation,
-- or else at either side of it. The reading slope is on the audience's side
-- (church_schematic.lua), so the reader is on the other. Returns the cell and
-- the direction the cleric faces, which is the audience's.
local function cleric_stand(pulpit, id)
	local dir = audience(pulpit)
	if not dir then return end
	local offsets = {
		{x = -dir.x, z = -dir.z}, {x = dir.z, z = -dir.x}, {x = -dir.z, z = dir.x},
	}
	for _, offset in ipairs(offsets) do
		local cell = {x = pulpit.x + offset.x, y = pulpit.y, z = pulpit.z + offset.z}
		if common.is_standing_space(cell, true) and not held_by_other(cell, id) then return cell, dir end
	end
end

local SIDES = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}

local function is_chair(pos)
	local node = core.get_node_or_nil(pos)
	return node and core.get_item_group(node.name, "chair") > 0
end

-- Whether a chair is next to the cell: someone standing there would be in the
-- way of whoever sits down.
local function beside_chair(cell)
	for _, side in ipairs(SIDES) do
		local node = core.get_node_or_nil({x = cell.x + side.x, y = cell.y, z = cell.z + side.z})
		if node and core.get_item_group(node.name, "chair") > 0 then return true end
	end
	return false
end

-- Free places to stand at the back of the church, best first: out of the way of
-- the pews, then farthest from the pulpit within the back, then nearest the
-- middle.
local function back_places(pulpit, id)
	local dir = audience(pulpit)
	if not dir then return {} end
	local found = {}
	for y = pulpit.y - 1, pulpit.y do
		for x = pulpit.x - BACK_REACH, pulpit.x + BACK_REACH do
			for z = pulpit.z - BACK_REACH, pulpit.z + BACK_REACH do
				local dx, dz = x - pulpit.x, z - pulpit.z
				local depth = dx * dir.x + dz * dir.z
				if depth >= BACK_MIN and depth <= BACK_MAX then
					local cell = {x = x, y = y, z = z}
					-- A chair is solid enough to stand on; nobody stands on the pews.
					local on_chair = is_chair({x = x, y = y - 1, z = z})
					if not on_chair and not held_by_other(cell, id) and common.is_standing_space(cell, true) then
						found[#found + 1] = {
							cell = cell, depth = depth, side = math.abs(dx * dir.z - dz * dir.x),
							crowds = beside_chair(cell) and 1 or 0,
						}
					end
				end
			end
		end
	end
	table.sort(found, function(a, b)
		if a.crowds ~= b.crowds then return a.crowds < b.crowds end
		if a.depth ~= b.depth then return a.depth > b.depth end
		if a.side ~= b.side then return a.side < b.side end
		if a.cell.x ~= b.cell.x then return a.cell.x < b.cell.x end
		return a.cell.z < b.cell.z
	end)
	return found
end

local function hold_place(self, cell)
	standing[key(cell)] = {id = self._id, until_time = now() + HOLD_SECONDS}
end

local function release_place(self)
	local church = self._villages_church
	local cell = church and church.place
	if not cell then return end
	local held = standing[key(cell)]
	if held and held.id == self._id then standing[key(cell)] = nil end
	church.place = nil
end

-- Turn to look along (dx, dz). A mob's forward is (-sin yaw, cos yaw), as in
-- seat.lua.
local function face(self, dx, dz)
	local set_yaw = self.set_yaw or mcl_mobs.mob_class.set_yaw
	set_yaw(self, atan2(-dx, dz))
end

local function stop_walking(self)
	if self.state == "gowp" then
		-- The same stop navigation.lua uses when it cancels a trip.
		self.state = "stand"
		self._target, self.current_target, self.waypoints, self.callback_arrived = nil, nil, nil, nil
		self.object:set_velocity(vector.zero())
	end
end

local function skip(self, pulpit, why)
	core.log("action", string.format("[living_villages] villager %s gave up the church at (%d,%d,%d): %s",
		tostring(self._id), pulpit.x, pulpit.y, pulpit.z, why))
	self._villages_church_skipped = self._villages_church_skipped or {}
	self._villages_church_skipped[key(pulpit)] = now() + UNREACHABLE_SECONDS
end

local function skipped(self, pulpit)
	local until_time = self._villages_church_skipped and self._villages_church_skipped[key(pulpit)]
	return until_time and until_time > now()
end

local function nearest_pulpit(self, origin)
	local sites = core.find_nodes_in_area(
		{x = origin.x - SEARCH_RADIUS, y = origin.y - SEARCH_HEIGHT, z = origin.z - SEARCH_RADIUS},
		{x = origin.x + SEARCH_RADIUS, y = origin.y + SEARCH_HEIGHT, z = origin.z + SEARCH_RADIUS},
		{PULPIT})
	local best, best_distance
	for _, site in ipairs(sites) do
		local distance = vector.distance(origin, site)
		if distance <= SEARCH_RADIUS and not skipped(self, site) and (not best or distance < best_distance) then
			best, best_distance = site, distance
		end
	end
	return best
end

-- Which part a villager plays this tick: "cleric" at its claimed pulpit during
-- the Pulpit and Service stages, "member" of the congregation otherwise during
-- the service. A cleric with no pulpit of its own sits with the rest.
local function role_now(self)
	if self.child or not self._id or self.following then return end
	local stage = common.schedule_stage(nil, self)
	local pulpit = (stage == "pulpit" or stage == "service") and cleric.claimed_pulpit(self)
	if pulpit then return "cleric", pulpit end
	if stage == "church" or stage == "service" then return "member" end
end

local function church_seat(self)
	local held = self._villages_seat
	return held and held.kind == "pulpit"
end

-- Let the service go: free the seat and the place, and stop walking to either.
local function leave(self)
	if church_seat(self) then seat.stand(self) end
	release_place(self)
	if self._villages_church then
		stop_walking(self)
		self._villages_church = nil
		if self.order == "stand" then self.order = nil end
	end
end

-- Start a walk. VoxeLibre's gopath answers nothing while it waits out an
-- earlier failure (ready_to_path, mcl_mobs/pathfinding.lua), so wait that out
-- without asking; walk() does not ask when the villager is already there. Any
-- other non-answer is a failure, and two give the church up.
local function start_walk(self, church, cell)
	if self.ready_to_path and not self:ready_to_path(true) then return true end
	if self:gopath(cell, function() end, true) then return true end
	church.failures = (church.failures or 0) + 1
	return church.failures < 2
end

local function near(pos, cell, reach)
	return math.abs(pos.x - cell.x) <= reach and math.abs(pos.z - cell.z) <= reach
end

-- Feet on the floor of cell's level: a villager standing on carpet in cell is
-- 0.43 below its center, on a full block 0.49 below. Lower than that it is
-- still climbing up into the level (at the top of a jump beside a step its feet
-- are level with the step's node, but under its surface), higher it is in the
-- air.
local function on_level(pos, cell)
	local rise = pos.y - cell.y
	return rise >= -0.52 and rise <= -0.3
end

-- Standing, not mid-jump, on the floor of cell's level.
local function standing_on_level(self, pos, cell)
	local v = self.object:get_velocity()
	return on_level(pos, cell) and not (v and math.abs(v.y) > 0.1)
end

-- Keep walking to cell. Returns false once the church is given up: out of time,
-- or no route. Nobody is moved anywhere they did not walk.
local function walk(self, church, cell, pos)
	if now() - church.since > church.limit then
		skip(self, church.pulpit, "the walk took too long")
		return false
	end
	-- A walk already under way keeps its old route, so a new place needs a new one.
	if church.goal and not same(church.goal, cell) then stop_walking(self) end
	church.goal = cell
	-- There already, and still settling from a jump: nothing to walk.
	if pos and near(pos, cell, LEG_REACH) and on_level(pos, cell) then return true end
	if self.state ~= "gowp" and not start_walk(self, church, cell) then
		skip(self, church.pulpit, "no route")
		return false
	end
	return true
end

-- Stay put, looking along (look_x, look_z). Vanilla clears the order on every
-- activity poll, so this is held each tick (tavern.lua).
local function hold_still(self, look_x, look_z)
	stop_walking(self)
	face(self, look_x, look_z)
	self.order = "stand"
end

-- How long the walk to the church may take from where the villager is now.
local function walk_limit(self, pulpit)
	local pos = self.object:get_pos()
	local distance = pos and vector.distance(pos, pulpit) or 0
	return math.min(WALK_MAX, WALK_BASE + WALK_PER_NODE * distance)
end

-- Cells joined to start on its level that pass keep(cell), each with its number
-- of steps from start, and in the order found (nearest first).
local function flood(start, reach, keep)
	local found, order = {[key(start)] = 0}, {start}
	local i = 1
	while order[i] do
		local cell = order[i]
		i = i + 1
		if found[key(cell)] < reach then
			for _, side in ipairs(SIDES) do
				local next_cell = {x = cell.x + side.x, y = cell.y, z = cell.z + side.z}
				if not found[key(next_cell)] and keep(next_cell) then
					found[key(next_cell)] = found[key(cell)] + 1
					order[#order + 1] = next_cell
				end
			end
		end
	end
	return found, order
end

-- The dais: cells level with the cleric's place, of the same kind (the stock
-- church's purple carpet), joined to it.
local function dais_cells(stand)
	local kind = core.get_node_or_nil(stand)
	return flood(stand, DAIS_REACH, function(cell)
		local node = core.get_node_or_nil(cell)
		return node and kind and node.name == kind.name and common.is_standing_space(cell, true)
	end)
end

-- The church floor at the congregation's level, joined to cell, within the
-- church: every cell a villager can stand in, but never a chair or the top of
-- one. Chairs are walkable, so the pathfinder routes over the pews (a cleric was
-- seen stuck on a seat against its backrest, legs walking).
local function floor_cells(cell, pulpit)
	return flood(cell, 2 * INSIDE, function(next_cell)
		local dx, dz = next_cell.x - pulpit.x, next_cell.z - pulpit.z
		return dx * dx + dz * dz <= INSIDE * INSIDE
			and not is_chair(next_cell) and not is_chair({x = next_cell.x, y = next_cell.y - 1, z = next_cell.z})
			and common.is_standing_space(next_cell, true)
	end)
end

-- The cell of cells a villager stands on: any one under its 0.6-wide footprint,
-- on its level, nearest first. Its center may hang over an edge (a cleric landed
-- on the dais with its center past the edge cell), so rounding is not enough.
local function cell_at(cells, pos)
	local y = common.feet_node(pos)
	local best, best_distance
	for x = math.floor(pos.x + 0.5) - 1, math.floor(pos.x + 0.5) + 1 do
		for z = math.floor(pos.z + 0.5) - 1, math.floor(pos.z + 0.5) + 1 do
			local cell = {x = x, y = y, z = z}
			local distance = math.max(math.abs(pos.x - x), math.abs(pos.z - z))
			if cells[key(cell)] and distance <= 0.8 and on_level(pos, cell)
				and (not best or distance < best_distance) then
				best, best_distance = cell, distance
			end
		end
	end
	return best
end

-- A floor cell beside a villager standing on a chair, to step down to.
local function off_chair(cells, pos)
	local under = {x = math.floor(pos.x + 0.5), y = common.feet_node(pos) - 1, z = math.floor(pos.z + 0.5)}
	if not is_chair(under) then return end
	for _, side in ipairs(SIDES) do
		local cell = {x = under.x + side.x, y = under.y, z = under.z + side.z}
		if cells[key(cell)] then return cell end
	end
end

-- The way up onto the dais: the edge cell nearest the cleric's place along the
-- dais that has church floor in front of it on the congregation's side, with
-- room overhead to jump, and that is at least 2.5 nodes from the place, so that
-- check_gowp's 1.8-node arrival around the place cannot end the walk mid-jump.
-- Returns the dais cells, the edge and the floor cell in front of it.
local function plan(pulpit, stand, dir)
	local cells, order = dais_cells(stand)
	for _, edge in ipairs(order) do
		local far = (edge.x - stand.x) ^ 2 + (edge.z - stand.z) ^ 2 >= 2.5 ^ 2
		if far then
			for _, side in ipairs(SIDES) do
				local floor = {x = edge.x + side.x, y = edge.y - 1, z = edge.z + side.z}
				local front = (floor.x - pulpit.x) * dir.x + (floor.z - pulpit.z) * dir.z > 0
				if front and not is_chair(floor) and common.is_standing_space(floor, true)
					and common.is_clear_node({x = floor.x, y = floor.y + 2, z = floor.z}) then
					return cells, edge, floor
				end
			end
		end
	end
	return cells
end

-- The cells from one to the start of a flood, one step at a time down its
-- distances; nil if from is not in it.
local function along(cells, from)
	local path, here = {}, from
	if not here or not cells[key(here)] then return end
	while cells[key(here)] > 0 do
		local next_cell
		for _, side in ipairs(SIDES) do
			local cell = {x = here.x + side.x, y = here.y, z = here.z + side.z}
			if cells[key(cell)] == cells[key(here)] - 1 then
				next_cell = cell
				break
			end
		end
		if not next_cell then return end
		path[#path + 1] = next_cell
		here = next_cell
	end
	return path
end

-- Inside the church the cleric does not use the pathfinder, which routes over
-- the pews, onto the walkable pulpit's top, and ends walks within check_gowp's
-- 1.8 nodes of their target, which at the dais edge is mid-jump (vanilla stops a
-- mob dead when a walk ends). From any church floor cell, the dais, or a chair
-- it walks one route of its own: across the floor to the cell in front of the
-- dais edge, up the step (step.lua), and along the dais to its place. The
-- waypoints are what gopath sets up (mcl_mobs/pathfinding.lua), so check_gowp
-- walks them. Returns false once the church is given up, and "outside" when the
-- cleric is not in the church to walk it.
local function walk_inside(self, church, pos)
	if now() - church.since > church.limit then
		skip(self, church.pulpit, "the walk took too long")
		return false
	end
	if self.state == "gowp" and church.goal and same(church.goal, church.stand) then return true end
	local v = self.object:get_velocity()
	if v and math.abs(v.y) > 0.1 then return true end
	local path
	local on_dais = cell_at(church.cells, pos)
	if on_dais then
		path = along(church.cells, on_dais)
	elseif church.floor_cells then
		local from = cell_at(church.floor_cells, pos)
		local down = not from and off_chair(church.floor_cells, pos)
		local across = along(church.floor_cells, from or down)
		local up = along(church.cells, church.edge)
		if across and up then
			path = {}
			if down then path[1] = down end
			for _, cell in ipairs(across) do path[#path + 1] = cell end
			path[#path + 1] = church.edge
			for _, cell in ipairs(up) do path[#path + 1] = cell end
		end
	end
	if not path then return "outside" end
	if #path == 0 then path = {church.stand} end
	stop_walking(self)
	local waypoints = {}
	for _, cell in ipairs(path) do
		waypoints[#waypoints + 1] = {pos = {x = cell.x, y = cell.y, z = cell.z}, failed_attempts = 0}
	end
	self._target = {x = church.stand.x, y = church.stand.y, z = church.stand.z}
	self.callback_arrived = function() end
	self.current_target = table.remove(waypoints, 1)
	self.waypoints = waypoints
	self.order = nil
	self.state = "gowp"
	church.goal = church.stand
	return true
end

local function conduct(self, pulpit)
	if skipped(self, pulpit) then return leave(self) end
	local cell, dir = cleric_stand(pulpit, self._id)
	if not cell then
		core.log("action", string.format("[living_villages] cleric %s has nowhere to stand at the pulpit at (%d,%d,%d)",
			tostring(self._id), pulpit.x, pulpit.y, pulpit.z))
		return leave(self)
	end
	local church = self._villages_church
	if not church or church.role ~= "cleric" or not same(church.pulpit, pulpit)
		or not church.stand or not same(church.stand, cell) then
		leave(self)
		church = {
			role = "cleric", pulpit = pulpit, stand = cell, since = now(),
			limit = walk_limit(self, pulpit) + CLIMB_SECONDS,
		}
		church.cells, church.edge, church.floor = plan(pulpit, cell, dir)
		if church.floor then church.floor_cells = floor_cells(church.floor, pulpit) end
		self._villages_church = church
	end
	local pos = self.object:get_pos()
	if not pos then return end
	if standing_on_level(self, pos, cell) then
		-- There, or within a step of it: line up exactly behind the pulpit. Only
		-- when the dais itself joins the two within a cell or two, so that a wall
		-- or a pulpit between them is walked around, not snapped through.
		local from = cell_at(church.cells, pos)
		local close = from and along(church.cells, from)
		if near(pos, cell, 0.3) or (near(pos, cell, AT_PULPIT) and close and #close <= 2) then
			if not near(pos, cell, 0.3) then self.object:set_pos({x = cell.x, y = pos.y, z = cell.z}) end
			church.failures = nil
			return hold_still(self, dir.x, dir.z)
		end
	end
	local walking = walk_inside(self, church, pos)
	if walking == false then return leave(self) end
	if walking == "outside" then
		-- Not in the church yet: the pathfinder brings it to the floor in front
		-- of the dais edge, and the walk inside takes over at the door.
		if not walk(self, church, church.floor or cell, pos) then return leave(self) end
	end
end

local function join(self, pos)
	if church_seat(self) and seat.approach_seat(self) then return end
	local church = self._villages_church
	if church and (church.role ~= "member" or skipped(self, church.pulpit) or not audience(church.pulpit)) then
		leave(self)
		church = nil
	end
	if not church then
		if now() < (self._villages_church_checked or 0) then return end
		local pulpit = nearest_pulpit(self, self._bed or vector.round(pos))
		if not pulpit then
			self._villages_church_checked = now() + SEARCH_SECONDS
			return
		end
		church = {role = "member", pulpit = pulpit, since = now(), limit = walk_limit(self, pulpit)}
		self._villages_church = church
	end
	-- Walk in to the back first, and look for a pew once inside, so that the
	-- chair's own short walk is not timed from a house across the village. If
	-- one is free the villager takes it; if not, or when the pews fill, it
	-- stays standing and keeps an eye out for one coming free.
	local at_church = (pos.x - church.pulpit.x) ^ 2 + (pos.z - church.pulpit.z) ^ 2 <= INSIDE * INSIDE
		and math.abs(pos.y - church.pulpit.y) <= 3
	if at_church and not church_seat(self) and seat.reserve(self, church.pulpit, "pulpit") then
		release_place(self)
		if seat.approach_seat(self) then return end
	end
	if not church.place then
		local places = back_places(church.pulpit, self._id)
		if not places[1] then
			-- A full church, or no room at the back: putter, and look again later.
			self._villages_church_checked = now() + SEARCH_SECONDS
			return leave(self)
		end
		church.place = places[1].cell
		church.since = now()
	end
	hold_place(self, church.place)
	local place = church.place
	if near(pos, place, AT_PLACE) and standing_on_level(self, pos, place) then
		church.failures = nil
		return hold_still(self, church.pulpit.x - place.x, church.pulpit.z - place.z)
	end
	if not walk(self, church, place, pos) then return leave(self) end
end

-- Someone has the villager's trade window open.
local function trading(self)
	return self._trading_players and next(self._trading_players) ~= nil
end

local function install(def, shared_seat)
	seat = shared_seat or dofile(core.get_modpath("living_villages") .. "/seat.lua")
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_staticdata = def.get_staticdata

	-- The visit is this session's: a reloaded villager starts the service over.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		for _, field in ipairs(FIELDS) do self[field] = nil end
		return result
	end

	def.get_staticdata = function(self)
		local kept = {}
		for _, field in ipairs(FIELDS) do kept[field], self[field] = self[field], nil end
		local saved = original_staticdata(self)
		for _, field in ipairs(FIELDS) do self[field] = kept[field] end
		return saved
	end

	def.do_custom = function(self, dtime)
		local role, pulpit = role_now(self)
		-- Seated in a pew, like at dinner (tavern.lua): skip the vanilla
		-- do_custom, whose activity poll would walk the member off, and hold
		-- the pose each tick.
		if church_seat(self) and self._villages_seated then
			if role == "member" and seat.hold_seat(self) then
				self.order = "stand"
				return false
			end
			leave(self)
		end
		local result = original_custom(self, dtime)
		if result == false then return result end
		-- Someone is trading with it: vanilla has stopped it (villager.lua
		-- on_rightclick) and it stays stopped. The visit waits, and the time
		-- spent does not count against its walk.
		if role and trading(self) then
			local church = self._villages_church
			if church then
				church.since = church.since + dtime
				if church.place then hold_place(self, church.place) end
			end
			return result
		end
		if role == "cleric" then
			conduct(self, pulpit)
		elseif role then
			local pos = self.object:get_pos()
			if pos then join(self, pos) end
		elseif self._villages_church then
			leave(self)
		end
		-- Vanilla's player scan (villager.lua stand_still) turns jumping off
		-- while a player is within four nodes, which would leave a villager
		-- someone is watching unable to climb a step on its way. Turn it back on
		-- for the walk. Random wandering (walk_chance) stays as vanilla left it.
		if self._villages_church and self.state == "gowp" and not self.following and not trading(self) then
			self.jump = true
		end
		return result
	end
end

return {
	install = install,
	-- Exposed for tests.
	cleric_stand = cleric_stand,
	back_places = back_places,
	standing = standing,
}
