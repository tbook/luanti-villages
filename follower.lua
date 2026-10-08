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
local STALL_RISE = 0.7
-- A shortcut keeps this far from a villager the route was planned around: both
-- half-widths and a margin.
local AVOID_CLEARANCE = 1.0
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
function follower.begin(self, avoid)
	local last = self.waypoints and self.waypoints[#self.waypoints] or self.current_target
	self._villages_follow_failed = nil
	self._villages_follow = {
		final = last and last.pos and vector.new(last.pos) or nil,
		avoid = avoid, progress_pos = self.object:get_pos(), still = 0, blocked = 0,
		leg_start = self.object:get_pos() or {x = 0, z = 0},
		from_y = self.object:get_pos() and common.feet_node(self.object:get_pos()) or nil,
	}
end

-- Where the walk to the current waypoint began, to tell a long straight leg
-- from being pushed off the route.
local function advance(self, from)
	local f = self._villages_follow
	f.leg_start = {x = from.x, z = from.z}
	f.from_y = self.current_target and self.current_target.pos and self.current_target.pos.y or f.from_y
	self.current_target = table.remove(self.waypoints, 1)
end

-- How far (x, z) is from the segment a-b.
local function segment_distance(ax, az, bx, bz, px, pz)
	local dx, dz = bx - ax, bz - az
	local length2 = dx * dx + dz * dz
	local t = length2 == 0 and 0 or math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / length2))
	return math.sqrt((px - ax - dx * t) ^ 2 + (pz - az - dz * t) ^ 2)
end

local function distance_to_leg(f, pos, target)
	return segment_distance(f.leg_start.x, f.leg_start.z, target.x, target.z, pos.x, pos.z)
end

-- Whether a shortcut from `pos` to `target` passes too close to a position the
-- route was planned around (follower.avoid): the map check cannot see a mob.
local function passes_avoided(f, pos, target)
	for _, spot in ipairs(f.avoid or {}) do
		if segment_distance(pos.x, pos.z, target.x, target.z, spot.x, spot.z) < AVOID_CLEARANCE then
			return true
		end
	end
	return false
end

-- The rise to the waypoint is a step of its own: once on the ground and near
-- enough, jump with forward speed. Vanilla's do_jump takes its forward push
-- from the speed the villager already has, so one that has stopped to turn or
-- work a door jumps straight up and lands where it was, again and again. This is
-- vanilla's jump (mcl_mobs/movement.lua) with the heading's speed instead, and
-- it does not refuse a step with carpet on it, as the planner has judged it.
local FALL_SPEED = -9.81 * 1.5
local JUMP_COOLDOWN = 0.6
local function rise_step(self, f, pos, waypoint, dx, dz)
	if waypoint.y <= common.feet_node(pos) then return end
	if dx * dx + dz * dz > 1.1 * 1.1 then return end
	if not self.jump or (self.jump_height or 0) == 0 then return end
	local now = core.get_us_time() / 1e6
	if f.jumped_at and now - f.jumped_at < JUMP_COOLDOWN then return end
	-- On the ground, or about to land on it this step (the speed it lands at is
	-- still on the villager when this runs, and vanilla's do_jump, which runs
	-- after, would jump from a standstill first): something walkable just under
	-- the feet, and not on the way up.
	local below = core.get_node_or_nil({x = math.floor(pos.x + 0.5), y = math.floor(pos.y - 0.35 + 0.5), z = math.floor(pos.z + 0.5)})
	local def = below and core.registered_nodes[below.name]
	if not (def and def.walkable) then return end
	local v = self.object:get_velocity()
	if v and v.y > 0.5 then return end
	f.jumped_at = now
	f.rising_until = now + 1
	local yaw = (self.object:get_yaw() or 0) + (self.rotate or 0)
	local speed = self.walk_velocity
	local velocity = {x = -math.sin(yaw) * speed, y = self.jump_height + 0.3, z = math.cos(yaw) * speed}
	if self.set_animation then self:set_animation("jump") end
	self.object:set_velocity(velocity)
	local forward = function(entity)
		-- Only for this walk: arriving, giving up or a new route ends the push.
		if not entity.object or not entity.object:get_luaentity() or entity._villages_follow ~= f then return end
		entity.object:set_acceleration({x = velocity.x * 2, y = FALL_SPEED, z = velocity.z * 2})
	end
	core.after(0.1, forward, self)
	core.after(0.2, forward, self)
	core.after(0.3, forward, self)
end

-- In the air over a rise nothing else pushes the villager at the step (the
-- mover's set_velocity does nothing unless it stands on the ground, and
-- hitting the step's face zeroes its speed), so keep it moving at the step
-- until it is up.
local function push_through_rise(self, f, dx, dz)
	local now = core.get_us_time() / 1e6
	if not f.rising_until or now > f.rising_until then return end
	local v = self.object:get_velocity()
	if not v or math.abs(v.y) < 0.01 then return end
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 1e-6 then return end
	local speed = self.walk_velocity
	self.object:set_velocity({x = dx / length * speed, y = v.y, z = dz / length * speed})
end

-- Whether the feet are down at the height the waypoint's floor puts them: the
-- floor's top (a stair tread is half a node lower than a block) plus the
-- collision box's sliver. The feet cell alone rounds up a quarter node early, so
-- it cannot say the villager has come down a step (#173).
local LANDED = 0.1
local function landed(pos, waypoint)
	local below = core.get_node_or_nil({x = waypoint.x, y = waypoint.y - 1, z = waypoint.z})
	local def = below and core.registered_nodes[below.name]
	if not (def and def.walkable) then return true end
	return pos.y <= waypoint.y - 1 + cells.collision_box_top(def) + 0.01 + LANDED
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
		and landed(pos, current.pos)
		and follower.line_is_clear({x = pos.x, y = feet, z = pos.z}, nextwp.pos)
		and not passes_avoided(f, pos, nextwp.pos) then
		advance(self, pos)
		current = self.current_target
		dx, dz = current.pos.x - pos.x, current.pos.z - pos.z
		distance = math.sqrt(dx * dx + dz * dz)
	end

	-- Level with the waypoint, not above it: on a descent the feet are higher
	-- than the waypoint until the villager is down the stair, and turning early
	-- runs its head into the floor over the lower cells (#173).
	local descending = f.from_y and current.pos.y < f.from_y
	local reached = distance < REACH and feet == current.pos.y and (not descending or landed(pos, current.pos))
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
	-- A villager bobbing up and down at a step it cannot climb is not progressing.
	local horizontal = math.sqrt((pos.x - f.progress_pos.x) ^ 2 + (pos.z - f.progress_pos.z) ^ 2)
	if horizontal >= STALL_DISTANCE or math.abs(pos.y - f.progress_pos.y) >= STALL_RISE then
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
		-- set_velocity(0) only zeroes the acceleration; stop what is moving too.
		self:set_velocity(0)
		local v = self.object:get_velocity()
		self.object:set_velocity({x = 0, y = v and v.y or 0, z = 0})
		self:set_animation("stand")
		return
	end
	local hurry = (self.order == "sleep" or #(self.waypoints or {}) > 15) and self.run_velocity or self.walk_velocity
	self:set_velocity(hurry)
	self:set_animation(hurry <= self.walk_velocity and "walk" or "run")
	rise_step(self, f, pos, current.pos, dx, dz)
	push_through_rise(self, f, dx, dz)
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
