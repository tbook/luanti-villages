-- Seats for dinner guests (#99) and church pews (#126): a guest reserves a
-- chair that faces a table (at the tavern) or a pulpit (at the church), walks
-- beside it and sits. Chairs are found by what is next to them, not by the
-- generated layout, so a player-built tavern or church seats guests too. Load
-- this once (init.lua passes the copy on): the reservations are this file's
-- own in-memory table.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
-- How far from the jukebox a chair still belongs to its tavern: the whole
-- stock tavern (12 x 10) from anywhere in it, and a player-built room of a
-- similar size.
local SEARCH_RADIUS = 8
local SEARCH_HEIGHT = 2
-- How far a pew may be from its pulpit: the stock church is 13 x 15 with the
-- pulpit at one end. The pulpit stands on a dais, a step above the pews.
local PEW_RADIUS = 12
local PEW_HEIGHT = 2
local PULPIT = "living_villages:pulpit"
-- A reservation lapses unless its guest renews it, so one left by a villager
-- that unloaded or was removed frees itself. A seated or approaching guest
-- renews it every tick.
local HOLD_SECONDS = 10
-- A guest that cannot reach its chair in this long gives it up.
local WALK_SECONDS = 20
-- How long a guest passes over a chair it could not reach: the rest of the
-- evening's dinner (the Tavern stage runs 15:30 to 17:30, 100 s of game time
-- per in-game hour at the default speed).
local UNREACHABLE_SECONDS = 200
-- How often a guest with no seat looks for one again.
local SEARCH_SECONDS = 5
-- Close enough to the chair to sit down from.
local REACH = 1.5
-- Sitting pose, from living_villages_villager.b3d: the leg bones pivot 5.85 units
-- (0.585 nodes) above the feet and are 2.16 units thick, and the chair's
-- seat top is level with the chair node's center (mcl_decor tpl_chair). With
-- the thighs level, the villager's origin sits this far below the seat for
-- the thighs to rest on it.
local SEAT_DROP = 0.585 - 0.108
-- The thighs swing forward a quarter turn. The leg bones point down at rest,
-- and a negative X rotation brings a bone's down toward the model's +z, its
-- facing: the same sense mcl_mobs uses to tilt a head up (effects.lua
-- check_head_swivel, negative pitch looks up).
local LEGS = {"leg.right", "leg.left"}
local LEG_ROTATION = {x = -math.pi / 2, y = 0, z = 0}
-- Narrow enough that guests on neighbouring chairs do not push each other.
local SEATED_BOX = {-0.2, 0, -0.2, 0.2, 1.4, 0.2}
local SIDES = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}

local reservations = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function now()
	return core.get_gametime()
end

local function copy(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

-- The way someone in this chair faces. The backrest is on +z at param2 0
-- (mcl_decor tpl_chair), so the sitter faces away from facedir_to_dir.
local function facing(node)
	local dir = core.facedir_to_dir(node.param2 % 32)
	return {x = -dir.x, y = 0, z = -dir.z}
end

local function is_chair(node)
	return node and core.get_item_group(node.name, "chair") > 0
end

local function is_table(node)
	return node and core.get_item_group(node.name, "table") > 0
end

-- A chair is a pew seat when the pulpit is somewhere ahead of it and the chair
-- is on the pulpit's audience side. The pulpit's audience is on the side
-- facedir_to_dir names (see church_schematic.lua), so the pews need not sit in
-- line with it.
local function faces_pulpit(chair, node, pulpit)
	local target = core.get_node_or_nil(pulpit)
	if not target or target.name ~= PULPIT then return false end
	local dx, dy, dz = pulpit.x - chair.x, pulpit.y - chair.y, pulpit.z - chair.z
	if math.abs(dy) > PEW_HEIGHT or dx * dx + dz * dz > PEW_RADIUS * PEW_RADIUS then return false end
	local front = facing(node)
	if dx * front.x + dz * front.z <= 0 then return false end
	local audience = core.facedir_to_dir(target.param2 % 32)
	return dx * audience.x + dz * audience.z < 0
end

-- What a chair is a seat at: the table in front of it, so a guest sits at
-- dinner rather than on a lone chair in a corner; or, for church seats, the
-- given pulpit. Returns that position and the chair's node.
local function seat_focus(chair, kind, pulpit)
	local node = core.get_node_or_nil(chair)
	if not is_chair(node) then return end
	if kind == "pulpit" then
		if not pulpit or not faces_pulpit(chair, node, pulpit) then return end
		return {x = pulpit.x, y = pulpit.y, z = pulpit.z}, node
	end
	local front = facing(node)
	local table_pos = {x = chair.x + front.x, y = chair.y, z = chair.z + front.z}
	if not is_table(core.get_node_or_nil(table_pos)) then return end
	return table_pos, node
end

local function player_in(chair)
	if not mcl_cozy or not mcl_cozy.players then return false end
	for _, sitting in pairs(mcl_cozy.players) do
		if sitting[2] == "sit" and sitting[1] and vector.equals(vector.round(sitting[1]), chair) then
			return true
		end
	end
	return false
end

local function held_by_other(chair, id)
	local hold = reservations[key(chair)]
	return hold and hold.id ~= id and hold.until_time >= now()
end

-- Where to stand to sit down, and to get back up to: any open square beside
-- the chair other than the table.
local function approach(chair, table_pos)
	for _, side in ipairs(SIDES) do
		local pos = {x = chair.x + side.x, y = chair.y, z = chair.z + side.z}
		if not vector.equals(pos, table_pos) and common.is_standing_space(pos, true) then return pos end
	end
end

local function hold(self, chair)
	reservations[key(chair)] = {id = self._id, until_time = now() + HOLD_SECONDS}
end

local function release(self)
	local seat = self._villages_seat
	self._villages_seat = nil
	if not seat then return end
	local hold_here = reservations[key(seat.chair)]
	if hold_here and hold_here.id == self._id then reservations[key(seat.chair)] = nil end
end

-- Drop every reservation this villager holds, wherever it came from: a
-- reloaded villager has lost the record of which chair it was.
local function release_all(id)
	for chair, held in pairs(reservations) do
		if held.id == id then reservations[chair] = nil end
	end
end

local function seat_position(chair, node)
	local front = facing(node)
	local pos = {x = chair.x, y = chair.y - SEAT_DROP, z = chair.z}
	-- A mob's forward is (-sin yaw, cos yaw) (mcl_mobs has no rotate offset
	-- for villagers).
	local yaw = atan2(-front.x, front.z)
	return pos, yaw
end

local function still_valid(self)
	local seat = self._villages_seat
	if not seat then return false end
	local table_pos = seat_focus(seat.chair, seat.kind, seat.table)
	if not table_pos or not vector.equals(table_pos, seat.table) then return false end
	if held_by_other(seat.chair, self._id) then return false end
	return not player_in(seat.chair)
end

local M = {}

-- Reserve the nearest free seat around center, and set out for it. kind is
-- "table" for the tavern at a jukebox (the default) or "pulpit" for the pews of
-- the church at a pulpit.
function M.reserve(self, center, kind)
	kind = kind or "table"
	local radius, height = SEARCH_RADIUS, SEARCH_HEIGHT
	if kind == "pulpit" then radius, height = PEW_RADIUS, PEW_HEIGHT end
	if not self._id then return false end
	local last = self._villages_seat_searched_at
	if last and now() - last < SEARCH_SECONDS then return false end
	self._villages_seat_searched_at = now()
	local pos = self.object:get_pos()
	if not pos then return false end
	local chairs = core.find_nodes_in_area(
		{x = center.x - radius, y = center.y - height, z = center.z - radius},
		{x = center.x + radius, y = center.y + height, z = center.z + radius},
		{"group:chair"})
	local best, best_distance
	for _, chair in ipairs(chairs) do
		local table_pos = seat_focus(chair, kind, center)
		local skipped = self._villages_seat_unreachable and self._villages_seat_unreachable[key(chair)]
		if table_pos and not held_by_other(chair, self._id) and not player_in(chair)
			and not (skipped and skipped > now()) then
			local stand = approach(chair, table_pos)
			local distance = vector.distance(pos, chair)
			if stand and (not best or distance < best_distance) then
				best, best_distance = {chair = copy(chair), table = table_pos, approach = stand, kind = kind}, distance
			end
		end
	end
	if not best then return false end
	best.reserved_at = now()
	self._villages_seat = best
	hold(self, best.chair)
	return true
end

function M.sit(self)
	local seat = self._villages_seat
	if not seat or not still_valid(self) then return false end
	local node = core.get_node_or_nil(seat.chair)
	local here = self.object:get_pos()
	-- The square it sat down from is where it stands back up, if it came from
	-- beside the chair; otherwise the square the seat was reserved with.
	if here and vector.distance(here, seat.chair) <= REACH and common.is_standing_space(here, true) then
		self._villages_seat_exit = copy(here)
	else
		self._villages_seat_exit = {x = seat.approach.x, y = seat.approach.y - 0.49, z = seat.approach.z}
	end
	self._villages_seated = true
	self._villages_seat_chair = copy(seat.chair)
	self._villages_seat_box = self.collisionbox
	self.state = "stand"
	self._target, self.current_target, self.waypoints, self.callback_arrived = nil, nil, nil, nil
	self.collisionbox = table.copy(SEATED_BOX)
	if self.child then
		for i, value in ipairs(self.collisionbox) do self.collisionbox[i] = value * 0.5 end
	end
	self.object:set_properties({collisionbox = self.collisionbox})
	for _, bone in ipairs(LEGS) do
		self.object:set_bone_override(bone, {rotation = {vec = LEG_ROTATION, absolute = false, interpolation = 0.2}})
	end
	M.pin(self, node)
	self._current_animation = nil
	if self.set_animation then self:set_animation("stand") end
	return true
end

function M.pin(self, node)
	local seat = self._villages_seat
	local pos, yaw = seat_position(seat.chair, node or core.get_node_or_nil(seat.chair))
	self.object:set_pos(pos)
	self.object:set_velocity(vector.zero())
	self.object:set_acceleration(vector.zero())
	self.acc = vector.zero()
	local set_yaw = self.set_yaw or mcl_mobs.mob_class.set_yaw
	set_yaw(self, yaw)
end

-- Where a seated guest stands back up: the square it sat down from, if a
-- villager still fits there; else any open square beside the chair; else on
-- the seat itself, which is walkable, so it is never left down inside the
-- chair.
function M.exit(self)
	local exit, chair = self._villages_seat_exit, self._villages_seat_chair
	if exit and common.is_standing_space(exit, true) then return exit end
	if not chair then return self.object:get_pos() end
	for _, side in ipairs(SIDES) do
		local pos = {x = chair.x + side.x, y = chair.y, z = chair.z + side.z}
		if common.is_standing_space(pos, true) then return {x = pos.x, y = pos.y - 0.49, z = pos.z} end
	end
	return {x = chair.x, y = chair.y + 0.01, z = chair.z}
end

-- Get up and let the chair go. Safe to call on a villager that is not
-- seated: it only releases what is held.
function M.stand(self)
	if self._villages_seated then
		self._villages_seated = nil
		for _, bone in ipairs(LEGS) do self.object:set_bone_override(bone, nil) end
		if self._villages_seat_box then
			self.collisionbox = self._villages_seat_box
			self.object:set_properties({collisionbox = self.collisionbox})
		end
		self.object:set_pos(M.exit(self))
	end
	self._villages_seat_box = nil
	self._villages_seat_exit, self._villages_seat_chair = nil, nil
	release(self)
end

-- Each tick while seated. Returns false once the seat is gone or taken, or
-- the guest should get up for any other reason, after standing it up.
function M.hold_seat(self)
	if not still_valid(self) then
		M.stand(self)
		return false
	end
	hold(self, self._villages_seat.chair)
	M.pin(self)
	return true
end

-- Give up a chair the guest cannot get to, and pass over it when looking
-- again, which it may do at once: the next nearest chair may be reachable.
local function unreachable(self)
	local seat = self._villages_seat
	self._villages_seat_unreachable = self._villages_seat_unreachable or {}
	self._villages_seat_unreachable[key(seat.chair)] = now() + UNREACHABLE_SECONDS
	self._villages_seat_searched_at = nil
	M.stand(self)
	return false
end

-- Each tick while on the way to a reserved seat. Returns true while the
-- guest is busy with its seat (walking or just sat), false once it has
-- given the seat up.
function M.approach_seat(self)
	local seat = self._villages_seat
	if not still_valid(self) then
		M.stand(self)
		return false
	end
	if now() - seat.reserved_at > WALK_SECONDS then return unreachable(self) end
	hold(self, seat.chair)
	local pos = self.object:get_pos()
	if pos and vector.distance(pos, seat.chair) <= REACH then return M.sit(self) end
	if self.state ~= "gowp" and not self:gopath(seat.approach, function(entity)
		if entity._villages_seat and not entity._villages_seated then M.sit(entity) end
	end, true) then
		return unreachable(self)
	end
	return true
end

function M.status(self)
	local seat = self._villages_seat
	if not seat then return "none" end
	local where = string.format("(%d,%d,%d)", seat.chair.x, seat.chair.y, seat.chair.z)
	return (self._villages_seated and "seated at " or "walking to ") .. where
end

function M.install(def)
	local original_activate = def.on_activate
	local original_staticdata = def.get_staticdata or mcl_mobs.mob_class.get_staticdata
	local original_die = def.on_die
	local original_animation = def.set_animation or mcl_mobs.mob_class.set_animation

	-- A reload drops the pose (the engine forgets bone overrides) and the
	-- seat, but not the position, which is down inside the chair: stand it
	-- back up.
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if (self._villages_seat_exit or self._villages_seat_chair) and self.object:get_pos() then
			self.object:set_pos(M.exit(self))
		end
		self._villages_seated, self._villages_seat, self._villages_seat_box = nil, nil, nil
		self._villages_seat_exit, self._villages_seat_chair, self._villages_seat_searched_at = nil, nil, nil
		self._villages_seat_unreachable = nil
		if self._id then release_all(self._id) end
		return result
	end

	-- Save only where to stand back up (the exit and its chair, set only
	-- while seated). The seat and the seated box belong to this session;
	-- init.lua's own wrapper already saves the standing box.
	def.get_staticdata = function(self)
		local seated, seat, box = self._villages_seated, self._villages_seat, self._villages_seat_box
		local searched, skipped = self._villages_seat_searched_at, self._villages_seat_unreachable
		self._villages_seated, self._villages_seat, self._villages_seat_box = nil, nil, nil
		self._villages_seat_searched_at, self._villages_seat_unreachable = nil, nil
		local saved = original_staticdata(self)
		self._villages_seated, self._villages_seat, self._villages_seat_box = seated, seat, box
		self._villages_seat_searched_at, self._villages_seat_unreachable = searched, skipped
		return saved
	end

	def.on_die = function(self, pos, cmi_cause)
		release(self)
		if original_die then return original_die(self, pos, cmi_cause) end
	end

	-- Legs stay in the rest pose the rotation is relative to.
	def.set_animation = function(self, name, fixed_frame)
		if self._villages_seated and name ~= "die" then name = "stand" end
		return original_animation(self, name, fixed_frame)
	end
end

M.reservations = reservations
return M
