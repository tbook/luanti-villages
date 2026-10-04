-- Carpeted steps (#126). VoxeLibre's do_jump (mcl_mobs/movement.lua) will not
-- jump a block that has a walkable node on top of it, reading the two as a stack
-- too tall to climb. Carpet is walkable but a sixteenth of a node thick, so a
-- villager refuses every carpeted step: the church dais, a carpeted stair
-- landing. This lets a villager on a planned route (state "gowp") whose next
-- waypoint is up a level jump such a step, with the same checks vanilla makes
-- for a bare one, plus room to land and room overhead.
local core = minetest
local common = dofile(core.get_modpath("living_villages") .. "/common.lua")
-- mcl_mobs/movement.lua's own constant.
local FALL_SPEED = -9.81 * 1.5

local function def_at(x, y, z)
	local node = core.get_node_or_nil({x = math.floor(x + 0.5), y = math.floor(y + 0.5), z = math.floor(z + 0.5)})
	return node and core.registered_nodes[node.name], node
end

local function group(node, name)
	return node and core.get_item_group(node.name, name) > 0
end

local function solid(def)
	return def and def.walkable
end

-- A step worth jumping: walkable, and full height. Carpet and snow layers are
-- walked over without a jump (the height check), and fences, walls and gates
-- are never jumped.
local function full_step(def, node)
	if not solid(def) or group(node, "carpet") then return false end
	for _, name in ipairs({"fence", "fence_gate", "wall"}) do
		if group(node, name) then return false end
	end
	local box = def.collision_box or (def.drawtype == "nodebox" and def.node_box)
	if box and box.type == "fixed" then
		local top = -0.5
		local fixed = type(box.fixed[1]) == "number" and {box.fixed} or box.fixed
		for _, part in ipairs(fixed) do top = math.max(top, part[5] or -0.5) end
		return top >= 0.49
	end
	return true
end

-- Whether the step ahead is one that vanilla refused only for the carpet on it.
-- The probes are vanilla's own: half a node and a node and a half above the
-- feet, cbox[4] + 0.5 ahead along the facing.
local function carpeted_step(self)
	if self.state ~= "gowp" then return false end
	if not self.jump or self.jump_height == 0 or self.fly or self.order == "stand" then return false end
	local pos = self.object:get_pos()
	local v = self.object:get_velocity()
	if not pos or not v or math.abs(v.y) > 0.01 then return false end
	-- Only where the route goes up: not every carpeted step the villager passes.
	local waypoint = self.current_target and self.current_target.pos
	if not waypoint or waypoint.y < common.feet_node(pos) + 1 then return false end
	local cbox = self.initial_properties and self.initial_properties.collisionbox or self.collisionbox
	local feet = pos.y + cbox[2]
	if not solid(def_at(pos.x, feet - 0.2, pos.z)) then return false end
	local yaw = self.object:get_yaw()
	local ax = -math.sin(yaw) * (cbox[4] + 0.5) + v.x * 0.25
	local az = math.cos(yaw) * (cbox[4] + 0.5) + v.z * 0.25
	if not full_step(def_at(pos.x + ax, feet + 0.5, pos.z + az)) then return false end
	local _, top = def_at(pos.x + ax, feet + 1.5, pos.z + az)
	if not group(top, "carpet") then return false end
	-- Room to land on the step, and to rise from here.
	return common.is_clear_node({x = pos.x + ax, y = feet + 2.5, z = pos.z + az})
		and common.is_clear_node({x = pos.x, y = feet + 2.5, z = pos.z})
end

-- vanilla do_jump's own jump, for the step it refused.
local function jump(self)
	local v = self.object:get_velocity()
	v.y = self.jump_height + 0.3
	if self.set_animation then self:set_animation("jump") end
	self.object:set_velocity(v)
	local forward = function(entity)
		if not entity.object or not entity.object:get_luaentity() or entity.state == "die" then return end
		entity.object:set_acceleration({x = v.x * 2, y = FALL_SPEED, z = v.z * 2})
	end
	core.after(0.1, forward, self)
	core.after(0.2, forward, self)
	core.after(0.3, forward, self)
	return true
end

local M = {}

function M.install(def)
	local original = def.do_jump or mcl_mobs.mob_class.do_jump
	def.do_jump = function(self, ...)
		if original(self, ...) then return true end
		if carpeted_step(self) then return jump(self) end
		return false
	end
end

M.carpeted_step = carpeted_step
return M
