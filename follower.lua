-- The route follower (#164). VoxeLibre's check_gowp (mcl_mobs/pathfinding.lua)
-- cuts corners by aiming 70/30 between two waypoints with no check for what is
-- there, skips a waypoint when it thinks it moved too fast, swings wide in
-- turns, counts a villager arrived within 1.8 blocks, and walks straight at the
-- target when it runs out of waypoints. For a route this mod planned (flagged by
-- `begin`) this replaces it: walk cell centre to cell centre, turn on the spot
-- first, skip a waypoint only along a line cells.lua says the whole body fits,
-- stop to work a door, jump a rise as a step of its own, and arrive on the
-- planned final cell. A villager that is not making progress is not left to
-- wait: the follower ends the walk with a reason in `_villages_follow_failed`
-- and navigation.lua plans again from where the villager stands. Any other
-- route in state "gowp" is still vanilla's.
local core = minetest
local cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")

-- Horizontal distance from a cell's centre that counts as having reached it.
local REACH = 0.3
-- Walk only once roughly facing the way to go (wander.lua's FACING_TOLERANCE).
local FACING_TOLERANCE = 0.35
local TURN_DELAY = 4
local SAMPLE_STEP = 0.25
-- Not moving for this long ends the walk; a villager or player in the way gets
-- longer to move off before the route is planned around it.
local STALL_SECONDS = 3
local BLOCKED_SECONDS = 3
local BLOCKER_LOOKAHEAD = 0.7
local BLOCKER_RADIUS = 0.6
local STALL_DISTANCE = 0.15
-- Farther than this from the waypoint it is heading for, a villager has been
-- pushed off its route (or loaded away from it).
local OFF_ROUTE = 2.5
local TWO_PI = 2 * math.pi

local follower = {}

local function angle_between(a, b)
	return math.abs((a - b + math.pi) % TWO_PI - math.pi)
end

-- Whether the whole body can walk the straight line from `from` to `to`, two
-- positions at the same level, without leaving standing space. The check the
-- planner's cells make, sampled along the line (cells.has_standing_space).
function follower.line_is_clear(from, to)
	if from.y ~= to.y then return false end
	local dx, dz = to.x - from.x, to.z - from.z
	local length = math.sqrt(dx * dx + dz * dz)
	for step = 0, math.ceil(length / SAMPLE_STEP) do
		local fraction = length == 0 and 0 or math.min(1, step * SAMPLE_STEP / length)
		if not cells.has_standing_space({x = from.x + dx * fraction, y = from.y, z = from.z + dz * fraction}, true) then
			return false
		end
	end
	return true
end

-- Another mob or a player in the way ahead, or nil. Returns its position.
local function blocker_ahead(self, pos, dx, dz)
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-6 then return nil end
	local ahead = {
		x = pos.x + dx / length * BLOCKER_LOOKAHEAD, y = pos.y, z = pos.z + dz / length * BLOCKER_LOOKAHEAD,
	}
	for _, object in ipairs(core.get_objects_inside_radius(ahead, BLOCKER_RADIUS)) do
		if object ~= self.object then
			local entity = object:get_luaentity()
			if object:is_player() or (entity and entity.is_mob) then return object:get_pos() end
		end
	end
	return nil
end

local function clear_walk(self)
	self.waypoints = nil
	self._target = nil
	self.current_target = nil
	self._villages_follow = nil
	self._villages_blocked_door = nil
	self.object:set_velocity(vector.zero())
	self.object:set_acceleration(vector.zero())
end

-- Ends the walk without arriving: navigation.lua sees the reason and plans again.
local function give_up(self, reason, blocker)
	clear_walk(self)
	self.state = "stand"
	self._villages_follow_failed = {
		reason = reason, blocker = blocker and vector.new(blocker) or nil,
	}
end

local function arrive(self)
	local callback = self.callback_arrived
	clear_walk(self)
	self.state = "stand"
	self.order = "stand"
	if self.set_animation then self:set_animation("stand") end
	if callback then return callback(self) end
	return true
end

-- Flags the walk that `start_engine_path` has just set up, on the planner's
-- route, so check_gowp leaves it to this module.
function follower.begin(self)
	local last = self.waypoints and self.waypoints[#self.waypoints] or self.current_target
	self._villages_follow_failed = nil
	self._villages_follow = {
		final = last and last.pos and vector.new(last.pos) or nil,
		progress_pos = self.object:get_pos(), still = 0, blocked = 0,
		leg_start = self.object:get_pos() or {x = 0, z = 0},
	}
end

-- Where the walk to the current waypoint began, to tell a long straight leg
-- from being pushed off the route.
local function advance(self, from)
	local f = self._villages_follow
	f.leg_start = {x = from.x, z = from.z}
	self.current_target = table.remove(self.waypoints, 1)
end

local function distance_to_leg(f, pos, target)
	local ax, az = f.leg_start.x, f.leg_start.z
	local bx, bz = target.x, target.z
	local dx, dz = bx - ax, bz - az
	local length2 = dx * dx + dz * dz
	local t = length2 == 0 and 0 or math.max(0, math.min(1, ((pos.x - ax) * dx + (pos.z - az) * dz) / length2))
	local cx, cz = ax + dx * t, az + dz * t
	return math.sqrt((pos.x - cx) ^ 2 + (pos.z - cz) ^ 2)
end

-- The rise to the waypoint is a step of its own: face it, and jump once on the
-- ground and near enough. do_jump is vanilla's (with step.lua's carpeted step
-- on it), which only jumps when something is ahead to jump onto.
local function rise_step(self, pos, waypoint, dx, dz)
	if waypoint.y <= common.feet_node(pos) then return end
	if dx * dx + dz * dz > 1.1 * 1.1 then return end
	local v = self.object:get_velocity()
	if v and math.abs(v.y) > 0.01 then return end
	if self.do_jump then self:do_jump() end
end

local function follow(self, dtime)
	local f = self._villages_follow
	local pos = self.object:get_pos()
	if not pos or not self._target then return end
	local current = self.current_target
	if not current or not current.pos then
		-- Out of waypoints with no arrival: nothing to follow.
		return give_up(self, "route ended before the final cell")
	end
	local feet = common.feet_node(pos)
	local dx, dz = current.pos.x - pos.x, current.pos.z - pos.z
	local distance = math.sqrt(dx * dx + dz * dz)

	if distance_to_leg(f, pos, current.pos) > OFF_ROUTE or math.abs(current.pos.y - feet) > OFF_ROUTE then
		return give_up(self, "off the planned route")
	end

	-- A shortcut past this waypoint, only along a line the whole body fits.
	local nextwp = self.waypoints and self.waypoints[1]
	if nextwp and not current.action and nextwp.pos and current.pos.y == feet and nextwp.pos.y == feet
		and follower.line_is_clear({x = pos.x, y = feet, z = pos.z}, nextwp.pos) then
		advance(self, pos)
		current = self.current_target
		dx, dz = current.pos.x - pos.x, current.pos.z - pos.z
		distance = math.sqrt(dx * dx + dz * dz)
	end

	local reached = distance < REACH and feet >= current.pos.y
	if reached then
		if not self.waypoints or #self.waypoints == 0 then return arrive(self) end
		-- A door is its own step: stop, work it, then cross.
		if current.action then
			self:do_pathfind_action(current.action)
			if self._villages_blocked_door then return give_up(self, "door cannot be crossed") end
			f.still = 0
		end
		advance(self, current.pos)
		return
	end

	-- Progress monitoring.
	if vector.distance(pos, f.progress_pos) >= STALL_DISTANCE then
		f.progress_pos, f.still, f.blocked = vector.new(pos), 0, 0
	else
		f.still = f.still + dtime
		if f.still > 1 then
			local blocker = blocker_ahead(self, pos, dx, dz)
			if blocker then
				f.blocked = f.blocked + dtime
				if f.blocked > BLOCKED_SECONDS then return give_up(self, "blocked by another villager", blocker) end
			elseif f.still > STALL_SECONDS then
				return give_up(self, "no progress along the route")
			end
		end
	end

	self:turn_in_direction(dx, dz, TURN_DELAY)
	local facing = (self.object:get_yaw() or 0) + (self.rotate or 0)
	if distance > 0.05 and angle_between(facing, -math.atan2(dx, dz)) > FACING_TOLERANCE then
		self:set_velocity(0)
		self:set_animation("stand")
		return
	end
	local hurry = (self.order == "sleep" or #(self.waypoints or {}) > 15) and self.run_velocity or self.walk_velocity
	self:set_velocity(hurry)
	self:set_animation(hurry <= self.walk_velocity and "walk" or "run")
	rise_step(self, pos, current.pos, dx, dz)
end

function follower.install(def)
	local original = def.check_gowp or mcl_mobs.mob_class.check_gowp
	def.check_gowp = function(self, dtime)
		if self._villages_follow then return follow(self, dtime) end
		return original(self, dtime)
	end
end

follower.follow = follow
return follower
