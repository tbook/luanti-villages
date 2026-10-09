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
-- A hop down carries the villager on past the lower waypoint; having landed
-- this near it and beyond it, along the leg, it is there (#186).
local OVERSHOOT_REACH = 0.8
-- Height above the lower waypoint's floor over which a falling villager is held.
local FALL_HOLD_HEIGHT = 0.6
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
	local pos, target = self.object:get_pos(), self._target
	local f = self._villages_follow
	-- Kept after navigation.lua consumes `_villages_follow_failed`, for the
	-- diagnostic and the log: why a villager turned back is otherwise lost.
	self._villages_last_walk_failure = {
		reason = reason, pos = pos and vector.new(pos) or nil,
		target = f and f.final or target and vector.new(target) or nil,
		day = core.get_day_count(), tod = core.get_timeofday(),
	}
	core.log("action", string.format("[living_villages] walk ended (%s) at %s heading for %s, day %d time %.0f",
		reason, pos and core.pos_to_string(pos, 1) or "?",
		self._villages_last_walk_failure.target and core.pos_to_string(self._villages_last_walk_failure.target) or "?",
		core.get_day_count(), core.get_timeofday() * 24000))
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

-- Whether the body fits along the straight line from `from` to `to` at the
-- level of `from`: open air only, since `to` may be lower than the floor here.
local function body_clear(from, to)
	local feet = common.feet_node(from)
	local dx, dz = to.x - from.x, to.z - from.z
	local length = math.sqrt(dx * dx + dz * dz)
	for step = 0, math.ceil(length / SAMPLE_STEP) do
		local t = length == 0 and 0 or math.min(1, step * SAMPLE_STEP / length)
		local at = {x = from.x + dx * t, z = from.z + dz * t}
		if not (cells.box_is_open(at, feet, feet, true) and cells.box_is_open(at, feet + 1, feet + cells.HEIGHT_NODES - 1)) then
			return false
		end
	end
	return true
end

-- The height of the top of the floor under a waypoint cell.
local function floor_top(waypoint)
	local below = core.get_node_or_nil({x = waypoint.x, y = waypoint.y - 1, z = waypoint.z})
	local def = below and core.registered_nodes[below.name]
	return waypoint.y - 1 + cells.collision_box_top(def)
end

-- How far (x, z) is to the side of the line through the leg to the waypoint.
local function off_leg(f, pos, waypoint)
	local lx, lz = waypoint.x - f.leg_start.x, waypoint.z - f.leg_start.z
	local length = math.sqrt(lx * lx + lz * lz)
	if length < 1e-6 then return 0 end
	return math.abs((pos.x - waypoint.x) * lz - (pos.z - waypoint.z) * lx) / length
end

-- Whether (x, z) is beyond the waypoint along the leg that led to it.
local function past_waypoint(f, pos, waypoint)
	return (pos.x - waypoint.x) * (waypoint.x - f.leg_start.x) + (pos.z - waypoint.z) * (waypoint.z - f.leg_start.z) > 0
end

local function follow(self, dtime)
	local f = self._villages_follow
	local pos = self.object:get_pos()
	if not pos or not self._target then return end
	-- A mob with no player within mcl_mob_active_range (48) is suspended by
	-- mcl_mobs (check_suspend; its set_velocity only moves it through the
	-- acceleration added while a player is in range): it stands wherever it is
	-- however the walk goes. That is not a stall, and ending the walk, planning
	-- again and trying the other end of the trip only churned (#201, #202).
	-- Wait for a player; the walk goes on from here. That includes the last
	-- waypoint: a villager waiting on it only arrives once a player is near.
	if self.player_in_active_range and not self:player_in_active_range() then
		f.progress_pos, f.still, f.blocked = vector.new(pos), 0, 0
		return
	end
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
	-- It leaves the ledge with its walking speed still on it and lands past the
	-- waypoint; turning back for the centre, with the next drop ahead, was the
	-- hop-turn-walk-back of #186. The final cell is still arrived on.
	-- Only near the leg, with the body clear to the next waypoint (a sharp turn
	-- beside a wall is walked from the centre), and never at a door step.
	nextwp = self.waypoints and self.waypoints[1]
	local overshot = descending and nextwp and not current.action and distance < OVERSHOOT_REACH
		and past_waypoint(f, pos, current.pos) and off_leg(f, pos, current.pos) < REACH
		and body_clear(pos, nextwp.pos)
	-- Head for the waypoint after, not back: also while still held up above the
	-- cell, so blocker_ahead and rise_step see that direction too.
	if overshot then dx, dz = nextwp.pos.x - pos.x, nextwp.pos.z - pos.z end
	local reached = (distance < REACH or overshot) and feet == current.pos.y and (not descending or landed(pos, current.pos))
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

	-- Only a drop of most of a node: a stair's half-block treads are walked down.
	if descending and distance < OVERSHOOT_REACH and pos.y - floor_top(current.pos) > FALL_HOLD_HEIGHT then
		local v = self.object:get_velocity()
		if v and v.y < -0.1 then
			-- Falling into the waypoint's cell: drop straight down, facing on,
			-- instead of carrying on past it with the walking speed still on, or
			-- swinging round to its centre.
			self:set_velocity(0)
			self.object:set_velocity({x = 0, y = v.y, z = 0})
			return
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

-- do_jump is the only thing that keeps `in_water` fresh, so ask the map.
local function in_water(self)
	local pos = self.object:get_pos()
	local node = pos and core.get_node_or_nil({
		x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.5), z = math.floor(pos.z + 0.5),
	})
	return node ~= nil and core.get_item_group(node.name, "water") > 0
end

function follower.install(def)
	local original = def.check_gowp or mcl_mobs.mob_class.check_gowp
	def.check_gowp = function(self, dtime)
		if self._villages_follow then return follow(self, dtime) end
		return original(self, dtime)
	end
	-- A followed walk jumps its own rises (rise_step). Vanilla's do_jump runs after
	-- it on every step and hops straight up whenever a solid node is ahead, from
	-- about 1.3 nodes of the node's centre at rest to 1.6 walking: while the
	-- villager stops to turn at the foot of a rise or is held there, hops that
	-- carry it nowhere. rise_step's own jump starts only within 1.1 nodes of the
	-- step's centre, so a villager just outside that hopped in place until the walk
	-- gave up (#194). In water vanilla's hop is how a villager swims out, and it
	-- keeps do_jump's bookkeeping (in_water, facing_fence) fresh, so it stays.
	local original_jump = def.do_jump or mcl_mobs.mob_class.do_jump
	def.do_jump = function(self, ...)
		if self._villages_follow and not in_water(self) then return false end
		if original_jump then return original_jump(self, ...) end
	end
end

follower.follow = follow
return follower
