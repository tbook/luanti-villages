-- Keep VoxeLibre's villager AI, trades, and bed ownership. Add a sleeping pose
-- adapted from Mineclonia and bed-limited village births.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local is_sleep_time = common.is_sleep_time
local MODEL = "villages_villager.b3d"
local BASE = "villages_villager_base.png^villages_villager_plains.png"
local SLEEP_BOX = {-0.25, 0, -0.25, 0.25, 0.3, 0.25}
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

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
	local overlay = profession_overlay[self._profession]
	if overlay then
		texture = texture .. "^villages_villager_profession_" .. overlay .. ".png"
		if overlay ~= "nitwit" then
			local tier = math.max(1, math.min(5, self._max_trade_tier or 1))
			texture = texture .. "^villages_villager_badge_" .. badges[tier] .. ".png"
		end
	end
	return texture
end

local function refresh_visual(self)
	local texture = skin(self)
	local props = self.object:get_properties()
	if not props then return end
	if props.mesh ~= MODEL or not props.textures or props.textures[1] ~= texture then
		self.object:set_properties({mesh = MODEL, textures = {texture}})
	end
	self.base_mesh = MODEL
	self.base_texture = {texture}
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

local function sleep_position(bed, node)
	local dir = core.facedir_to_dir(node.param2)
	local pos = vector.offset(bed, dir.x * 0.35, 0.06, dir.z * 0.35)
	local yaw = atan2(dir.z, dir.x) + math.pi / 2
	return pos, yaw
end

core.register_on_mods_loaded(function()
	local def = core.registered_entities["mobs_mc:villager"]
	if not def then
		core.log("warning", "[villages] mobs_mc:villager is unavailable")
		return
	end

	local original_box = table.copy(def.initial_properties.collisionbox)
	local original_anim = table.copy(def.animation)
	local original_child_anim = table.copy(def._child_animations)
	local original_head_swivel = def.head_swivel
	local original_head_bone_position = def.head_bone_position
	local original_activate = def.on_activate
	local original_custom = def.do_custom
	local original_animation = def.set_animation or mcl_mobs.mob_class.set_animation
	local original_staticdata = def.get_staticdata or mcl_mobs.mob_class.get_staticdata

	def.initial_properties.mesh = MODEL
	def.animation = table.copy(animation)
	def._child_animations = table.copy(animation)
	def.head_swivel = "Head_Control"
	def.head_bone_position = vector.new(0, 6.48, 0)

	local function wake(self)
		local exit = self._villages_bed_exit
		self._villages_sleeping = nil
		self._villages_bed_exit = nil
		self.collisionbox = normal_box(self, original_box)
		self.object:set_properties({collisionbox = self.collisionbox})
		-- Return to the position from which this villager entered the bed. That
		-- position was already safe for its full standing collision box, unlike
		-- the sleeping position within the bed itself.
		if exit then self.object:set_pos(exit) end
		self._current_animation = nil
		original_animation(self, "stand")
	end

	local function begin_sleep(self, bed, node)
		local exit = self.object:get_pos()
		if exit and not self._villages_bed_exit then
			self._villages_bed_exit = {x = exit.x, y = exit.y, z = exit.z}
		end
		local pos, yaw = sleep_position(bed, node)
		self._villages_sleeping = true
		self.state = "stand"
		self.object:set_velocity(vector.zero())
		self.object:set_acceleration(vector.zero())
		self.object:set_pos(pos)
		self.object:set_yaw(yaw)
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
	-- the mod safe while villagers are asleep.
	def.get_staticdata = function(self)
		local sleeping, box = self._villages_sleeping, self.collisionbox
		local anim, child_anim = self.animation, self._child_animations
		local swivel, bone = self.head_swivel, self.head_bone_position
		self._villages_sleeping = nil
		self.collisionbox = normal_box(self, original_box)
		self.animation = original_anim
		self._child_animations = original_child_anim
		self.head_swivel = original_head_swivel
		self.head_bone_position = original_head_bone_position
		local saved = original_staticdata(self)
		self._villages_sleeping, self.collisionbox = sleeping, box
		self.animation, self._child_animations = anim, child_anim
		self.head_swivel, self.head_bone_position = swivel, bone
		return saved
	end

	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		if not self.object:get_pos() then return result end
		self._villages_sleeping = nil
		self.animation = self.child and table.copy(def._child_animations)
			or table.copy(def.animation)
		self.head_swivel = def.head_swivel
		self.head_bone_position = def.head_bone_position
		self.collisionbox = normal_box(self, original_box)
		self.object:set_properties({collisionbox = self.collisionbox})
		refresh_visual(self)
		local bed, node = claimed_bed(self)
		if self.order == "sleep" and is_sleep_time() and bed
			and vector.distance(self.object:get_pos(), bed) < 2
			and not occupied_by_other(self, bed) then
			begin_sleep(self, bed, node)
		end
		return result
	end

	def.do_custom = function(self, dtime)
		local result = original_custom(self, dtime)
		if result == false then return false end
		self._villages_visual_timer = (self._villages_visual_timer or 0) + dtime
		if self._villages_visual_timer >= 0.5 then
			self._villages_visual_timer = 0
			refresh_visual(self)
		end

		local bed, node = claimed_bed(self)
		if self._villages_sleeping then
			if self.order ~= "sleep" or not is_sleep_time() or not bed
				or vector.distance(self.object:get_pos(), bed) >= 1 then
				wake(self)
			else
				-- navigation_step/movement_step/motion_step/ai_step already ran
				-- earlier this tick, before do_custom is called, so returning
				-- false here alone does not stop the villager from drifting.
				-- Re-pin it to the sleep pose every tick instead.
				local pos, yaw = sleep_position(bed, node)
				self.object:set_pos(pos)
				self.object:set_yaw(yaw)
				self.object:set_velocity(vector.zero())
				self.object:set_acceleration(vector.zero())
				return false
			end
		elseif self.order == "sleep" and is_sleep_time() and bed
			and vector.distance(self.object:get_pos(), bed) < 2
			and not occupied_by_other(self, bed) then
			begin_sleep(self, bed, node)
			return false
		end
		return result
	end

	dofile(core.get_modpath("villages") .. "/births.lua")(def)
	dofile(core.get_modpath("villages") .. "/navigation.lua")(def)
	dofile(core.get_modpath("villages") .. "/farmer.lua")(def)
	dofile(core.get_modpath("villages") .. "/diagnostic.lua")(def)
end)
