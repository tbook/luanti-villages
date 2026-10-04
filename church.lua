-- Church service on holidays (#126): in the Church stage (#124) every adult
-- walks to the nearest church, one with a pulpit (#21), and takes a pew, a
-- chair facing the pulpit (seat.lua), or stands at the back if the pews are
-- full. The cleric who claimed the pulpit (cleric.lua) stands beside it facing
-- the congregation during the Pulpit and Service stages. With no church within
-- reach, or none a villager can walk to, the villager putters as on any
-- morning. At the end of the stage seats are released; the bell is #127.
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
-- Close enough to a standing place to be there. gopath aims at the node above
-- a solid target and drops the last waypoint (mcl_mobs/pathfinding.lua), and
-- carpet counts as solid, so a villager sent to a carpeted place stops a node
-- short of it.
local AT_PLACE = 1.5
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

-- Whether a chair is next to the cell, or under it (a chair is solid enough to
-- stand on): someone standing there would be in the way of whoever sits down.
local function beside_chair(cell)
	for _, side in ipairs({SIDES[1], SIDES[2], SIDES[3], SIDES[4], {x = 0, z = 0, y = -1}}) do
		local node = core.get_node_or_nil({x = cell.x + side.x, y = cell.y + (side.y or 0), z = cell.z + side.z})
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
					if not held_by_other(cell, id) and common.is_standing_space(cell, true) then
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

-- Start a walk. VoxeLibre's gopath answers nothing both when there is no route
-- and while it waits out an earlier failure (mcl_mobs/pathfinding.lua), and
-- only a real failure sets _pf_last_failed. Returns false after two real
-- failures, which gives the church up; a wait is not one.
local function start_walk(self, church, cell)
	local before = self._pf_last_failed
	if self:gopath(cell, function() end, true) then return true end
	if self.ready_to_path and self._pf_last_failed == before and not self:ready_to_path(true) then
		return true
	end
	church.failures = (church.failures or 0) + 1
	return church.failures < 2
end

-- Walk to a standing place and stay there, looking along (look_x, look_z).
-- Returns false once it has given the church up, and whether it is there.
local function go_to(self, church, cell, look_x, look_z, exact)
	local pos = self.object:get_pos()
	if not pos then return true end
	if math.abs(pos.x - cell.x) <= AT_PLACE and math.abs(pos.z - cell.z) <= AT_PLACE
		and math.abs(pos.y - (cell.y - 0.45)) < 1.5 then
		stop_walking(self)
		-- The cleric's place is exactly behind the pulpit, which the walk only
		-- gets near; take the last step. Carpet is a sixteenth of a node thick.
		if exact and (math.abs(pos.x - cell.x) > 0.3 or math.abs(pos.z - cell.z) > 0.3) then
			self.object:set_pos({x = cell.x, y = cell.y - 0.42, z = cell.z})
		end
		church.failures = nil
		face(self, look_x, look_z)
		-- Stay put. Vanilla clears the order on every activity poll, so hold it
		-- each tick (tavern.lua).
		self.order = "stand"
		return true, true
	end
	if now() - church.since > church.limit then
		skip(self, church.pulpit, "the walk took too long")
		return false
	end
	-- A walk already under way keeps its old route, so a new place needs a new one.
	if church.goal and not same(church.goal, cell) then stop_walking(self) end
	church.goal = cell
	if self.state ~= "gowp" and not start_walk(self, church, cell) then
		skip(self, church.pulpit, "no route")
		return false
	end
	return true, false
end

-- How long the walk to the church may take from where the villager is now.
local function walk_limit(self, pulpit)
	local pos = self.object:get_pos()
	local distance = pos and vector.distance(pos, pulpit) or 0
	return math.min(WALK_MAX, WALK_BASE + WALK_PER_NODE * distance)
end

-- The cell behind the pulpit is next to the pulpit, and the pathfinder will
-- happily route over the top of it, which a villager cannot climb (it did, in
-- the first playtest: the cleric stopped against the dais). So a cleric coming
-- from the congregation's side takes three legs, none of which is shorter
-- across the pulpit: the floor beside the far end of the dais row, up onto the
-- dais there, then along the row to the cell behind the pulpit.
local function dais_legs(stand, dir)
	local best, best_steps
	for _, side in ipairs({{x = -dir.z, z = dir.x}, {x = dir.z, z = -dir.x}}) do
		local steps, cell = 0, nil
		while steps < 6 do
			local next_cell = {x = stand.x + side.x * (steps + 1), y = stand.y, z = stand.z + side.z * (steps + 1)}
			-- Stay on the dais: its cells are the same as the cleric's own (carpet
			-- over wood), where the step beyond is a stair or the floor.
			local here, there = core.get_node_or_nil(next_cell), core.get_node_or_nil(stand)
			if not common.is_standing_space(next_cell, true) or not here or not there or here.name ~= there.name then break end
			steps, cell = steps + 1, next_cell
		end
		if steps >= 2 and (not best_steps or steps > best_steps) then best, best_steps = cell, steps end
	end
	if not best then return end
	-- The pulpit is raised on its dais; the congregation's floor is a step down,
	-- two cells in front of the row behind it.
	local floor = {x = best.x + dir.x * 2, y = stand.y - 1, z = best.z + dir.z * 2}
	if not common.is_standing_space(floor, true) then return end
	return {floor, best}
end

local conduct
function conduct(self, pulpit)
	local church = self._villages_church
	if not church or church.role ~= "cleric" or not same(church.pulpit, pulpit) then
		leave(self)
		church = {role = "cleric", pulpit = pulpit, since = now(), limit = walk_limit(self, pulpit)}
		self._villages_church = church
	end
	if skipped(self, pulpit) then return leave(self) end
	local cell, dir = cleric_stand(pulpit, self._id)
	if not cell then
		core.log("action", string.format("[living_villages] cleric %s has nowhere to stand at the pulpit at (%d,%d,%d)",
			tostring(self._id), pulpit.x, pulpit.y, pulpit.z))
		return leave(self)
	end
	local target, exact = cell, true
	-- From anywhere but the dais itself: the row is the way once on it, and
	-- every other way in, whichever side of the church the cleric starts on,
	-- ends at the pulpit's front.
	local pos = self.object:get_pos()
	church.leg = church.leg or 1
	local on_dais = pos and math.abs(pos.y - (cell.y - 0.45)) < 0.8
		and math.abs(pos.x - cell.x) <= 5 and math.abs(pos.z - cell.z) <= 5
	if church.leg <= 2 and pos and not on_dais then
		local legs = dais_legs(cell, dir)
		if legs then target, exact = legs[church.leg], false end
	end
	church.target = target
	local ok, there = go_to(self, church, target, dir.x, dir.z, exact)
	if not ok then return leave(self) end
	if there and not exact then
		church.leg = church.leg + 1
		church.since = now()
		return conduct(self, pulpit)
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
	local at_church = pos.x and (pos.x - church.pulpit.x) ^ 2 + (pos.z - church.pulpit.z) ^ 2 <= INSIDE * INSIDE
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
	local dx, dz = church.pulpit.x - church.place.x, church.pulpit.z - church.place.z
	if not go_to(self, church, church.place, dx, dz) then return leave(self) end
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
		if role == "cleric" then
			conduct(self, pulpit)
		elseif role then
			local pos = self.object:get_pos()
			if pos then join(self, pos) end
		elseif self._villages_church then
			leave(self)
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
