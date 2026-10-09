-- Keep VoxeLibre's villager AI, trades, and bed ownership. Add a sleeping pose
-- adapted from Mineclonia and bed-limited village births.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
local is_sleep_time = common.is_sleep_time
local is_standing_space = common.is_standing_space
local is_suffocating = common.is_suffocating
local far_trips = dofile(core.get_modpath("living_villages") .. "/far_trips.lua")
-- core.register_entity requires the loading mod's own name-prefix context
-- (register.lua's check_modname_prefix reads core.get_current_modname()),
-- which is only valid during a mod's own normal load -- not from inside the
-- core.register_on_mods_loaded callback below, where every mod has already
-- finished loading and get_current_modname() no longer resolves to
-- "living_villages". fisherman.lua's own living_villages:bobber registration must
-- therefore run from here, at ordinary top-level load time, rather than
-- from a dofile inside that callback like the other behavior modules.
local install_fisherman = dofile(core.get_modpath("living_villages") .. "/fisherman.lua")
local keeper = dofile(core.get_modpath("living_villages") .. "/keeper.lua")
local cleric = dofile(core.get_modpath("living_villages") .. "/cleric.lua")
-- Registers living_villages:meal, so it loads here for the same reason.
local path_storage = core.get_mod_storage()
local meal = dofile(core.get_modpath("living_villages") .. "/meal.lua")
-- Registers living_villages:pulpit, likewise.
dofile(core.get_modpath("living_villages") .. "/pulpit.lua")
local MODEL = "living_villages_villager.b3d"
local BASE = "living_villages_villager_base.png^living_villages_villager_plains.png"
local SLEEP_BOX = {-0.25, 0, -0.25, 0.25, 0.3, 0.25}
-- A bed exit is the square a villager stepped into its bed from, so it is
-- always adjacent to the bed. Anything further is a record left over from
-- some other bed and must never be teleported back to (#84).
local BED_EXIT_RADIUS = 3
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function pos_string(pos)
	if not pos then return "?" end
	return string.format("(%.1f,%.1f,%.1f)", pos.x, pos.y, pos.z)
end

local profession_overlay = {
	farmer = "farmer",
	fisherman = "fisherman",
	fletcher = "fletcher",
	shepherd = "shepherd",
	librarian = "librarian",
	cartographer = "cartographer",
	armorer = "armorer",
	leatherworker = "leatherworker",
	butcher = "butcher",
	weapon_smith = "weaponsmith",
	tool_smith = "toolsmith",
	cleric = "cleric",
	mason = "mason",
	nitwit = "nitwit",
}
local badges = {"stone", "iron", "gold", "emerald", "diamond"}
local animation = {
	stand_start = 0, stand_end = 0,
	walk_start = 0, walk_end = 40, walk_speed = 35,
	run_start = 0, run_end = 40, run_speed = 35,
	sleep_start = 82, sleep_end = 82, sleep_speed = 0,
}

local function skin(self)
	local texture = BASE
	-- A keeper is a butcher underneath (keeper.lua), so it needs its own look
	-- ahead of the profession lookup rather than the butcher's apron.
	if self._villages_keeper and not self.child then
		local tier = math.max(1, math.min(5, self._max_trade_tier or 1))
		return texture .. "^" .. keeper.OVERLAY .. "^living_villages_villager_badge_" .. badges[tier] .. ".png"
	end
	-- _villages_fisherman is never transiently cleared, unlike _profession:
	-- fisherman.lua's guard (#70) restores a jobsite-less fisherman's
	-- _profession only after vanilla's own do_custom (which this file's
	-- do_custom wraps innermost, calling tick_visual right after it) has
	-- already reset it to "unemployed" for that tick. Reading _profession
	-- straight would paint the plain, no-profession skin for that tick.
	local profession = self._villages_fisherman and "fisherman" or self._profession
	local overlay = profession_overlay[profession]
	if overlay then
		texture = texture .. "^living_villages_villager_profession_" .. overlay .. ".png"
		if overlay ~= "nitwit" then
			local tier = math.max(1, math.min(5, self._max_trade_tier or 1))
			texture = texture .. "^living_villages_villager_badge_" .. badges[tier] .. ".png"
		end
	end
	return texture
end

-- mcl_mobs/api.lua aliases (not copies) self.base_size when computing a
-- child's rendered scale: `local vis_size = self.base_size; vis_size.x =
-- vis_size.x * .5`. That mutates self.base_size in place, so every
-- reactivation while still a child halves it again; it decays toward zero
-- over enough mapblock unload/reload cycles. Growing up then copies that
-- decayed self.base_size straight into visual_size, rendering the villager
-- invisible. Not something this mod can fix upstream, so re-assert the
-- correct scale here the same way mesh/texture drift is already corrected.
local child_growth = dofile(core.get_modpath("living_villages") .. "/child_growth.lua")

local function expected_visual_size(self)
	if self.child then
		local scale = child_growth.scale(self)
		return {x = scale, y = scale}
	end
	return {x = 1, y = 1}
end

local function refresh_visual(self)
	local texture = skin(self)
	local props = self.object:get_properties()
	if not props then return end
	local size = expected_visual_size(self)
	local current = props.visual_size
	-- The engine stores visual_size as float32, so a scale such as 0.57 reads
	-- back as 0.56999999; compare with a tolerance or a growing child is
	-- re-sent its properties on every step (#177).
	local size_ok = current and math.abs(current.x - size.x) < 1e-4
		and math.abs(current.y - size.y) < 1e-4
	if props.mesh ~= MODEL or not props.textures or props.textures[1] ~= texture or not size_ok then
		self.object:set_properties({mesh = MODEL, textures = {texture}, visual_size = size})
	end
	self.base_mesh = MODEL
	self.base_texture = {texture}
	self.base_size = {x = 1, y = 1}
end

-- Vanilla's own set_textures (mobs_mc/villager.lua:734, called directly from
-- remove_job/employ on every ~5s activity poll, not throttled or gated by
-- this mod at all) overwrites the object's textures with VoxeLibre's own
-- profession skin outright, bypassing refresh_visual entirely. A throttled
-- correction here used to leave that visible for up to its own interval
-- after every one of those calls -- a general flicker back to the plain
-- villager look, not specific to any one profession. refresh_visual already
-- compares before it ever calls set_properties, so checking every tick
-- costs a few field reads in the common case, not a property set; do that
-- instead of waiting out a timer.
local function tick_visual(self)
	refresh_visual(self)
end

local function normal_box(self, original_box)
	local box = table.copy(original_box)
	if self.child then
		for i, value in ipairs(box) do box[i] = value * 0.5 end
	end
	return box
end

local function claimed_bed(self)
	local pos = self._bed
	if not pos then return end
	local node = core.get_node_or_nil(pos)
	if not node or core.get_item_group(node.name, "bed") ~= 1 then return end
	local meta = core.get_meta(pos)
	if meta:get_string("villager") ~= self._id then return end
	if meta:get_string("player") ~= "" then return end
	local top = mcl_beds.get_bed_top(pos)
	if core.get_meta(top):get_string("player") ~= "" then return end
	return pos, node
end

local function occupied_by_other(self, bed)
	for _, object in ipairs(core.get_objects_inside_radius(bed, 0.6)) do
		if object ~= self.object then
			local other = object:get_luaentity()
			if other and other.name == "mobs_mc:villager"
				and other._villages_sleeping and other._bed
				and vector.equals(other._bed, bed) then
				return true
			end
		end
	end
	return false
end

-- Luanti/Minetest can duplicate an entity across a mapblock save/reload if
-- the server stops (or crashes) between the block being written with the
-- entity still in its static list and the entity's own removal from the
-- active object set completing. VoxeLibre's villager only assigns _id once,
-- in on_spawn, and copies it forward through get_staticdata/on_activate like
-- any other field, so a duplicated mapblock reload produces two live
-- entities sharing the same _id. This mod cannot fix that upstream race, but
-- it can notice the collision here (both bed and jobsite claims already key
-- off _id, so a collision otherwise silently corrupts both) and drop one.
-- Comparing keys, rather than simply removing whichever side is doing the
-- noticing, guarantees the same survivor regardless of which of the two
-- copies happens to activate first: each side independently reaches the
-- same conclusion about who stays. Position alone is not a safe key: the
-- engine can duplicate an entity at its exact position, and a tie there
-- would send both copies down the "remove the other" branch, so if removal
-- does not invalidate the object synchronously both could end up removed.
-- ObjectRef has no get_id()/equivalent stable handle in this API, but two
-- distinct Lua objects always tostring() to distinct addresses within a
-- single server run, which is all the tie-break needs: it only has to be
-- consistent for the two objects being compared right now, not stable
-- across restarts.
local function duplicate_key(pos, object)
	return string.format("%.3f:%.3f:%.3f:%s", pos.x, pos.y, pos.z, tostring(object))
end

local function find_duplicate(self, pos)
	local id = self._id
	if not id or not pos then return end
	for _, object in ipairs(core.get_objects_inside_radius(pos, 64)) do
		if object ~= self.object then
			local other = object:get_luaentity()
			if other and other.name == "mobs_mc:villager" and other._id == id then
				return other
			end
		end
	end
end

-- object:remove() bypasses on_die, so VoxeLibre never clears the removed
-- copy's bed and jobsite claims and they stay owned by an _id that no longer
-- has a live villager standing anywhere near them (#84). Release them here
-- instead -- but only the ones the survivor does not hold itself: both copies
-- share an _id, so a claim the survivor still uses would otherwise be freed
-- out from under it.
local function release_claims(loser, survivor)
	for _, field in ipairs({"_bed", "_jobsite"}) do
		local pos = loser[field]
		local kept = survivor[field]
		if pos and not (kept and vector.equals(kept, pos)) then
			local meta = core.get_meta(pos)
			if meta:get_string("villager") == loser._id then
				meta:set_string("villager", "")
				core.log("action", string.format(
					"[living_villages] released %s %s held by removed duplicate villager %s",
					field, pos_string(pos), tostring(loser._id)))
			end
		end
	end
end

local function remove_duplicate(loser, survivor, loser_pos, survivor_pos)
	core.log("warning", string.format(
		"[living_villages] removing duplicate villager %s at %s, keeping the copy at %s",
		tostring(loser._id), pos_string(loser_pos), pos_string(survivor_pos)))
	release_claims(loser, survivor)
	loser.object:remove()
end

local function resolve_duplicate(self)
	local pos = self.object:get_pos()
	local dup = find_duplicate(self, pos)
	if not dup then return false end
	local dup_pos = dup.object:get_pos()
	if not dup_pos then return false end
	if duplicate_key(pos, self.object) > duplicate_key(dup_pos, dup.object) then
		remove_duplicate(self, dup, pos, dup_pos)
		return true
	end
	remove_duplicate(dup, self, dup_pos, pos)
	return false
end

local function sleep_position(bed, node)
	local dir = core.facedir_to_dir(node.param2)
	local pos = vector.offset(bed, dir.x * 0.35, 0.06, dir.z * 0.35)
	local yaw = atan2(dir.z, dir.x) + math.pi / 2
	return pos, yaw
end

core.register_on_mods_loaded(function()
	local def = core.registered_entities["mobs_mc:villager"]
	if not def then
		core.log("warning", "[living_villages] mobs_mc:villager is unavailable")
		return
	end

	-- Wraps vanilla's do_custom alone, before anything below captures it, so
	-- only vanilla ever sees the stand-in trade list it gives a nitwit.
	dofile(core.get_modpath("living_villages") .. "/nitwit.lua")(def)

	local original_box = table.copy(def.initial_properties.collisionbox)
	local original_anim = table.copy(def.animation)
	local original_child_anim = table.copy(def._child_animations)
	local original_head_swivel = def.head_swivel
	local original_head_bone_position = def.head_bone_position
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_die = def.on_die
	local original_animation = def.set_animation or mcl_mobs.mob_class.set_animation
	local original_staticdata = def.get_staticdata or mcl_mobs.mob_class.get_staticdata
	-- mob_class:set_yaw(yaw, delay) does not rotate the model itself; it only
	-- records self.target_yaw/self.delay. A separate check_smooth_rotation(),
	-- which runs every tick regardless of do_custom's return value, is what
	-- actually calls object:set_yaw() each tick, smoothly turning toward
	-- target_yaw. Calling the raw object:set_yaw() directly (as this file
	-- used to) never updates target_yaw, so check_smooth_rotation keeps
	-- chasing whatever heading the villager's own AI last wanted before it
	-- fell asleep, fighting our forced yaw and spinning the villager. Route
	-- through the mob's own set_yaw instead, like set_animation above.
	local mob_set_yaw = def.set_yaw or mcl_mobs.mob_class.set_yaw

	def.initial_properties.mesh = MODEL
	def.animation = table.copy(animation)
	def._child_animations = table.copy(animation)
	def.head_swivel = "Head_Control"
	def.head_bone_position = vector.new(0, 6.48, 0)

	-- An exit is only good for the bed it was recorded beside, and only while
	-- the square it names is still somewhere a villager can stand: the player
	-- may have built over it while the villager slept, and a villager set down
	-- inside an opaque node suffocates within seconds (#84).
	local function usable_bed_exit(self)
		local exit, bed = self._villages_bed_exit, self._villages_bed_exit_bed
		if not exit then return end
		if not bed or vector.distance(exit, bed) > BED_EXIT_RADIUS then return end
		-- Carpet in the exit's own cell is fine: the large house lays it all
		-- round the bed, and refusing it left the sleeper where it lay, on a
		-- bed it could not walk from (#191).
		if not is_standing_space(exit, true) then return end
		return exit
	end

	local function wake(self)
		local exit = usable_bed_exit(self)
		if self._villages_bed_exit and not exit then
			core.log("action", string.format(
				"[living_villages] villager %s woke with no usable bed exit (%s); leaving it where it lies",
				tostring(self._id), pos_string(self._villages_bed_exit)))
		end
		self._villages_sleeping = nil
		self._villages_bed_exit = nil
		self._villages_bed_exit_bed = nil
		self.collisionbox = normal_box(self, original_box)
		self.object:set_properties({collisionbox = self.collisionbox})
		-- Return to the position from which this villager entered the bed. That
		-- position was already safe for its full standing collision box, unlike
		-- the sleeping position within the bed itself. Record the move: this is
		-- the only place this mod relocates a villager on its own, so a burial
		-- that follows one of these lines is this mod's doing, and a burial with
		-- no such line is not (#84).
		if exit then
			core.log("action", string.format(
				"[living_villages] villager %s left its bed for %s",
				tostring(self._id), pos_string(exit)))
			self.object:set_pos(exit)
		end
		self._current_animation = nil
		original_animation(self, "stand")
	end

	local function begin_sleep(self, bed, node)
		local pos, yaw = sleep_position(bed, node)
		-- Record the square this villager is stepping into bed from, replacing
		-- any exit left over from an earlier night: a villager can claim a
		-- different bed between two sleeps, and returning it to the old bed's
		-- exit teleports it across the village, often into a wall (#84). The
		-- one position that is never an exit is the sleeping position itself,
		-- which is where a villager reactivating in its bed already stands --
		-- keep the exit it entered from in that case.
		local standing = self.object:get_pos()
		if standing and vector.distance(standing, pos) >= 0.5 then
			self._villages_bed_exit = {x = standing.x, y = standing.y, z = standing.z}
			self._villages_bed_exit_bed = {x = bed.x, y = bed.y, z = bed.z}
		end
		self._villages_sleeping = true
		self.state = "stand"
		self.object:set_pos(pos)
		self.object:set_velocity(vector.zero())
		self.object:set_acceleration(vector.zero())
		-- self.acc is the mob's own Lua-side steering vector: on_step adds it
		-- to velocity every tick (mcl_mobs/api.lua), so it must be cleared
		-- too, not just the object's own velocity/acceleration.
		self.acc = vector.zero()
		mob_set_yaw(self, yaw)
		self.collisionbox = table.copy(SLEEP_BOX)
		if self.child then
			for i, value in ipairs(self.collisionbox) do
				self.collisionbox[i] = value * 0.5
			end
		end
		self.object:set_properties({collisionbox = self.collisionbox})
		self._current_animation = nil
		original_animation(self, "sleep")
	end

	def.set_animation = function(self, name, fixed_frame)
		if self._villages_sleeping and name ~= "die" then name = "sleep" end
		return original_animation(self, name, fixed_frame)
	end

	-- Save only VoxeLibre-compatible entity fields. This also makes uninstalling
	-- the mod safe while villagers are asleep. mcl_mobs serializes every field
	-- of self (api.lua's get_staticdata), so a bed exit left in place would
	-- survive a mapblock unload and outlive the night it belongs to; the
	-- villager that reloads can claim another bed entirely, and waking would
	-- then teleport it back to the old one (#84). A position to step back into
	-- is only meaningful for as long as the villager is lying in that bed, so
	-- drop it from the save rather than reasoning about its age later.
	def.get_staticdata = function(self)
		local sleeping, box = self._villages_sleeping, self.collisionbox
		local anim, child_anim = self.animation, self._child_animations
		local swivel, bone = self.head_swivel, self.head_bone_position
		local exit, exit_bed = self._villages_bed_exit, self._villages_bed_exit_bed
		local activated_at = self._villages_activated_at
		self._villages_sleeping = nil
		self._villages_bed_exit = nil
		self._villages_bed_exit_bed = nil
		self._villages_activated_at = nil
		self.collisionbox = normal_box(self, original_box)
		self.animation = original_anim
		self._child_animations = original_child_anim
		self.head_swivel = original_head_swivel
		self.head_bone_position = original_head_bone_position
		local saved = original_staticdata(self)
		self._villages_sleeping, self.collisionbox = sleeping, box
		self._villages_bed_exit, self._villages_bed_exit_bed = exit, exit_bed
		self._villages_activated_at = activated_at
		self.animation, self._child_animations = anim, child_anim
		self.head_swivel, self.head_bone_position = swivel, bone
		return saved
	end

	-- Villagers leave no corpse and drop nothing, so a death looks exactly like
	-- a disappearance in game. Record what killed each one, with the state that
	-- distinguishes the known causes from each other: suffocation inside a node
	-- after a bad teleport reports an environment cause and an opaque
	-- standing_in node, while a fall, a mob, or the void each name themselves
	-- (#84).
	def.on_die = function(self, pos, cmi_cause)
		local cause = cmi_cause and cmi_cause.type or "unknown"
		local node = cmi_cause and cmi_cause.node
		local detail = type(node) == "string" and (" node " .. node) or ""
		local puncher = cmi_cause and cmi_cause.puncher
		if puncher then
			local entity = puncher.get_luaentity and puncher:get_luaentity()
			detail = detail .. " by " .. (puncher.is_player and puncher:is_player()
				and puncher:get_player_name() or entity and tostring(entity.name) or "?")
		end
		local died_at = pos or self.object:get_pos()
		local loaded = self._villages_activated_at
		local since_load = ""
		if loaded and died_at then
			since_load = string.format(", activated at %s (%.1f below)",
				pos_string(loaded), loaded.y - died_at.y)
		end
		core.log("action", string.format(
			"[living_villages] villager %s died at %s: %s%s (standing in %s, order %s%s%s)",
			tostring(self._id), pos_string(died_at), tostring(cause),
			detail, tostring(self.standing_in), tostring(self.order),
			self._villages_sleeping and ", asleep" or "", since_load))
		if original_die then return original_die(self, pos, cmi_cause) end
	end

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if not self.object:get_pos() then return result end
		if resolve_duplicate(self) then return result end
		self._villages_sleeping = nil
		self.animation = self.child and table.copy(def._child_animations)
			or table.copy(def.animation)
		self.head_swivel = def.head_swivel
		self.head_bone_position = def.head_bone_position
		self.collisionbox = normal_box(self, original_box)
		self.object:set_properties({collisionbox = self.collisionbox})
		refresh_visual(self)
		-- A villager that arrives already sealed inside a node was buried before
		-- this session began, and will suffocate in a few seconds no matter what
		-- happens now. Say so at the moment it loads, so its death can be told
		-- apart from one that starts here, among the living (#84). No rescue:
		-- a villager buried by the world dying is the world working.
		-- Where a villager loaded, kept only in memory. A villager that dies
		-- well below where it activated fell there; one that dies where it
		-- loaded was already there. Nothing else in the game reports that
		-- difference, and it is the difference between this mod burying a
		-- villager and the world handing one over already buried (#84).
		local activated_at = self.object:get_pos()
		self._villages_activated_at =
			{x = activated_at.x, y = activated_at.y, z = activated_at.z}
		local suffocating, node_name = is_suffocating(activated_at)
		if suffocating then
			core.log("warning", string.format(
				"[living_villages] villager %s activated already buried in %s at %s; it will suffocate",
				tostring(self._id), tostring(node_name), pos_string(self.object:get_pos())))
		end
		local bed, node = claimed_bed(self)
		if self.order == "sleep" and is_sleep_time(self) and bed
			and vector.distance(self.object:get_pos(), bed) < 2
			and not occupied_by_other(self, bed) then
			begin_sleep(self, bed, node)
		end
		return result
	end

	def.do_custom = function(self, dtime)
		if self._villages_sleeping then
			local bed, node = claimed_bed(self)
			if self.order ~= "sleep" or not is_sleep_time(self) or not bed
				or vector.distance(self.object:get_pos(), bed) >= 1 then
				wake(self)
			else
				-- Do not call the vanilla villager do_custom (original_custom)
				-- while asleep: its periodic do_activity() re-checks the bed
				-- every ~5s and, given any excuse (the villager's position has
				-- drifted even slightly), issues its own turn_in_direction()/
				-- gopath() calls. Those queue a fresh target_yaw the same way
				-- ours does, and since check_smooth_rotation() runs every tick
				-- regardless of do_custom's return value, it would chase that
				-- competing target and fight our fixed sleep pose. Re-pin
				-- position/velocity/yaw every tick instead, since the earlier
				-- physics/motion steps in on_step run before do_custom either
				-- way and can still nudge the villager.
				tick_visual(self)
				local pos, yaw = sleep_position(bed, node)
				self.object:set_pos(pos)
				self.object:set_velocity(vector.zero())
				self.object:set_acceleration(vector.zero())
				self.acc = vector.zero()
				mob_set_yaw(self, yaw)
				return false
			end
		end

		-- Vanilla's get_activity() takes no villager, so name this one for it:
		-- a keeper keeps different hours from everyone else (#22).
		local result = far_trips.call(self, common.as_villager, self, original_custom, self, dtime)
		if result == false then return false end
		tick_visual(self)

		local bed, node = claimed_bed(self)
		if self.order == "sleep" and is_sleep_time(self) and bed
			and vector.distance(self.object:get_pos(), bed) < 2
			and not occupied_by_other(self, bed) then
			begin_sleep(self, bed, node)
			return false
		end
		return result
	end

	-- VoxeLibre's get_activity (mobs_mc/villager.lua) is a leaked global that
	-- do_activity looks up by name on every call, so replacing it here moves
	-- vanilla villagers onto this mod's schedule (#22). If the upstream API in
	-- #35 lands, this becomes a call to it.
	if get_activity then
		get_activity = common.get_activity
	else
		core.log("warning", "[living_villages] VoxeLibre's get_activity is gone; villagers keep the vanilla schedule")
	end

	dofile(core.get_modpath("living_villages") .. "/births.lua")(def)
	child_growth.install(def)
	dofile(core.get_modpath("living_villages") .. "/navigation.lua")(def)
	dofile(core.get_modpath("living_villages") .. "/farmer.lua")(def)
	install_fisherman(def)
	keeper.install(def)
	cleric.install(def)
	-- One copy of seat.lua, so that its reservations cover both the tavern's
	-- chairs and the church's.
	local seat = dofile(core.get_modpath("living_villages") .. "/seat.lua")
	dofile(core.get_modpath("living_villages") .. "/tavern.lua")(def, meal, seat)
	-- After the tavern, so its seated-guest check sees a pew first.
	dofile(core.get_modpath("living_villages") .. "/church.lua").install(def, seat)
	dofile(core.get_modpath("living_villages") .. "/bell.lua").install(def)
	-- Outermost, so it sees "walk" after everything else has had its say.
	dofile(core.get_modpath("living_villages") .. "/wander.lua")(def)
	dofile(core.get_modpath("living_villages") .. "/diagnostic.lua")(def)
	dofile(core.get_modpath("living_villages") .. "/paths.lua").install(def, path_storage)
	dofile(core.get_modpath("living_villages") .. "/floor_guard.lua")(def)
end)

dofile(core.get_modpath("living_villages") .. "/tavern_schematic.lua")
dofile(core.get_modpath("living_villages") .. "/church_schematic.lua")
dofile(core.get_modpath("living_villages") .. "/belltower_schematic.lua")
dofile(core.get_modpath("living_villages") .. "/church_site.lua")
dofile(core.get_modpath("living_villages") .. "/library_schematic.lua")
-- Load order: after every module that edits a building's schematic (the ones above
-- and belltower_schematic.lua, once it exists): ground_layer builds its variants
-- from whatever mts holds when the first sandy building is placed.
if not dofile(core.get_modpath("living_villages") .. "/ground_layer.lua").install(rawget(_G, "settlements")) then
	core.log("warning", "[living_villages] ground layer not installed: settlements.place_schematics "
		.. "or settlements.schematic_table is missing; sand villages keep dirt under buildings")
end
dofile(core.get_modpath("living_villages") .. "/village_index.lua")

-- After church_site.lua: the planner reserves the church itself and replaces its wrapper.
do
	local planner = dofile(core.get_modpath("living_villages") .. "/site_planner.lua")
	local globals = {
		settlements = rawget(_G, "settlements"),
		mcl_vars = rawget(_G, "mcl_vars"),
		max_height_difference = rawget(_G, "max_height_difference"),
		half_map_chunk_size = rawget(_G, "half_map_chunk_size"),
	}
	if planner.install(globals) then planner.register_command(globals) end
	-- Terraform runs on the planner's levelled sites, so it goes in with it.
	dofile(core.get_modpath("living_villages") .. "/village_smoothing.lua").install(globals)
end

-- Villages start without VoxeLibre's generated paths (#12): they wobble over
-- the ground and ignore doors. paths.lua wears real ones where villagers walk.
-- build_a_settlement looks settlements.paths up at the call, so replacing it
-- here is enough.
if rawget(_G, "settlements") and settlements.paths
		and not (core.settings and core.settings:get_bool("living_villages_generated_paths", false)) then
	settlements.paths = function() end
end
