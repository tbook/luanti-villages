-- Aimless walks that stop short of walls (#93). VoxeLibre's wander
-- (mcl_mobs/movement.lua do_states_walk) sets off along whatever heading the
-- villager happens to face, and turns only once head-height probes 45
-- degrees either side both hit something, so villagers walk into walls,
-- fences and closed doors and keep pushing. gopath's no-path fallback
-- (mcl_mobs/pathfinding.lua) beelines at its target through walls the same
-- way. Whenever a villager is put into "walk", this takes over with a leg: a
-- straight line to a spot where the villager can stand at every step of the
-- way, then a stop. A villager with no such leg stands instead.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")

-- Vanilla stops a walk with a 30% chance each second, so its walks average
-- a few nodes at the villager's walk_velocity of 1.2 (mobs_mc/villager.lua).
local LEG_MIN = 2
local LEG_MAX = 6
local SAMPLE_STEP = 0.25
local HEADINGS = 16
local ARRIVE_DISTANCE = 0.3
-- Walk only once roughly facing the target, so the villager turns on the
-- spot rather than drifting off the checked line while it swings round.
local FACING_TOLERANCE = 0.35
local TURN_DELAY = 4
-- Another mob or a player standing in the way.
local STALL_SECONDS = 2
local STALL_DISTANCE = 0.3
local TWO_PI = 2 * math.pi

local function heading(yaw)
	return -math.sin(yaw), math.cos(yaw)
end

-- How far a villager can walk from start along a heading, following the
-- floor up or down by one node at a time, before something is in the way.
-- Returns that distance and the last spot along it where the villager can
-- stand. Between standing spots, a sample may have the box over the next
-- floor and the center still over the last, partway up a step or off a
-- kerb; the villager keeps its level there until the move completes.
local function clear_run(start, yaw, max_length)
	local dx, dz = heading(yaw)
	local previous = start
	local reached, target = 0, start
	for step = 1, math.floor(max_length / SAMPLE_STEP) do
		local distance = step * SAMPLE_STEP
		local x, z = start.x + dx * distance, start.z + dz * distance
		local here = {x = x, y = previous.y, z = z}
		if not common.is_body_clear(here) then
			-- Climb anything one node high; do_jump (mcl_mobs/movement.lua)
			-- makes the jump once the villager walks into it.
			local up = {x = x, y = here.y + 1, z = z}
			if not (common.is_body_clear(up) and common.has_headroom(previous)) then break end
			here = up
		elseif not common.has_floor(here) then
			-- Off an edge: one node down onto open floor, and no further.
			local down = {x = x, y = here.y - 1, z = z}
			if not (common.has_floor(down) and common.is_clear_node(down)) then break end
			if common.is_body_clear(down) then here = down end
		end
		previous = here
		if common.is_standing_space(here) then reached, target = distance, here end
	end
	return reached, target
end

-- The villager's current heading comes first, so a leg keeps whatever
-- direction vanilla meant -- toward home, or toward an unreachable target
-- -- as far as the way is open. The rest are evenly spaced from a random
-- offset and shuffled.
local function candidate_yaws(yaw)
	local yaws = {}
	local offset = math.random() * TWO_PI / HEADINGS
	for i = 1, HEADINGS do yaws[i] = offset + (i - 1) * TWO_PI / HEADINGS end
	for i = HEADINGS, 2, -1 do
		local j = math.random(i)
		yaws[i], yaws[j] = yaws[j], yaws[i]
	end
	table.insert(yaws, 1, yaw)
	return yaws
end

-- Returns a leg, false when the villager has nowhere to go, or nil when its
-- own position is not ordinary standing space (a slab, a bed, water) and
-- this module cannot judge its surroundings.
local function plan_leg(self, pos)
	local start = {x = pos.x, y = common.feet_node(pos), z = pos.z}
	if not common.is_standing_space(start) then return nil end
	local wanted = LEG_MIN + math.random() * (LEG_MAX - LEG_MIN)
	local yaw = (self.target_yaw or self.object:get_yaw() or 0) + (self.rotate or 0)
	local best_length, best_target = 0, nil
	for _, candidate in ipairs(candidate_yaws(yaw)) do
		local length, target = clear_run(start, candidate, wanted)
		if length > best_length then best_length, best_target = length, target end
		if length >= wanted then break end
	end
	if best_length < LEG_MIN then return false end
	return {
		target = best_target, elapsed = 0,
		limit = STALL_SECONDS + 3 * best_length / (self.walk_velocity or 1),
		progress_pos = vector.new(pos), progress_elapsed = 0,
	}
end

local function finish(self)
	self._villages_wander = nil
	self:stand()
end

local function angle_between(a, b)
	return math.abs((a - b + math.pi) % TWO_PI - math.pi)
end

-- Advances the leg one step. Returns false once it is over.
local function drive(self, leg, pos, dtime)
	local dx, dz = leg.target.x - pos.x, leg.target.z - pos.z
	if dx * dx + dz * dz < ARRIVE_DISTANCE * ARRIVE_DISTANCE then return false end
	leg.elapsed = leg.elapsed + dtime
	if leg.elapsed > leg.limit then return false end
	if vector.distance(pos, leg.progress_pos) >= STALL_DISTANCE then
		leg.progress_pos, leg.progress_elapsed = vector.new(pos), 0
	else
		leg.progress_elapsed = leg.progress_elapsed + dtime
		if leg.progress_elapsed > STALL_SECONDS then return false end
	end
	self:turn_in_direction(dx, dz, TURN_DELAY)
	local facing = (self.object:get_yaw() or 0) + (self.rotate or 0)
	if angle_between(facing, -math.atan2(dx, dz)) > FACING_TOLERANCE then
		self:set_velocity(0)
		self:set_animation("stand")
	else
		self:set_velocity(self.walk_velocity)
		self:set_animation("walk")
	end
	return true
end

local function install(def)
	local original_custom = def.do_custom
	local original_staticdata = def.get_staticdata or mcl_mobs.mob_class.get_staticdata

	-- A leg is only good for the moment it was planned; do not save it.
	def.get_staticdata = function(self)
		local leg = self._villages_wander
		self._villages_wander = nil
		local data = original_staticdata(self)
		self._villages_wander = leg
		return data
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		if result == false then
			self._villages_wander = nil
			return false
		end
		-- Anything else that moved the villager out of "walk" -- a trip, a
		-- seat, a knockback, a follow -- owns it now.
		if self.state ~= "walk" or self.following or (self.pause_timer or 0) > 0 then
			self._villages_wander = nil
			return result
		end
		local pos = self.object:get_pos()
		if not pos then return result end
		-- Vanilla's player scan zeroes walk_chance to hold a villager still
		-- for a nearby player, but lets a walk already under way run on.
		if self.walk_chance == 0 then
			finish(self)
			return result
		end
		local leg = self._villages_wander
		if not leg then
			leg = plan_leg(self, pos)
			if leg == nil then return result end
			if not leg then
				finish(self)
				return result
			end
			self._villages_wander = leg
		end
		if not drive(self, leg, pos, dtime) then
			finish(self)
			return result
		end
		-- Skip do_states: its do_states_walk would turn the villager at random
		-- and stop it by chance, off the line that was checked.
		return false
	end
end

return install
