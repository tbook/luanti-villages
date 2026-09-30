-- Undoes the engine dropping a villager through the floor it stands on (#90).
-- Luanti 5.17's collisionMoveSimple (src/collision.cpp, since fa956d13) finds
-- the nearest collision using the average speed over the whole step, then
-- snaps the object to the face picked by the average speed over just the part
-- of the step before contact. A villager that jumps from the floor has
-- velocity up and gravity down. Over a step longer than 2 * vy / g (0.58 s for
-- mcl_mobs' 4.3 m/s jump), the whole-step average points down and hits the
-- floor, but the part-step average still points up, so the engine treats the
-- floor as a ceiling and puts the top of the villager's box against the
-- floor's underside: a floor and a body height below, inside the ground,
-- where do_env_damage suffocates it. Lag spikes are what produce such steps,
-- and a villager jumping against a low ceiling holds that velocity for many
-- ticks in a row.
--
-- on_step runs after the engine has moved the object, so a move that passed
-- down through a walkable node is visible here and can be taken back before
-- mcl_mobs deals any damage. Only that case is undone: the new column must
-- hold a walkable node whose underside lies between the villager's new head
-- and its old feet, which no fall, step or path can produce.
local core = minetest

-- The snap needs a step longer than 2 * vy / g, which is 0.58 s for a jump and
-- longer for anything faster. Ordinary steps are left alone, so a move another
-- mod makes with set_pos between two of them is never undone.
local MIN_STEP = 0.25

-- Only positions the engine produced are compared, and nothing here is saved:
-- a weak table forgets a villager once its entity is gone.
local last_pos = setmetatable({}, {__mode = "k"})

local function pos_string(pos)
	return string.format("(%.1f,%.1f,%.1f)", pos.x, pos.y, pos.z)
end

local function is_walkable(pos)
	local node = core.get_node_or_nil(pos)
	local def = node and core.registered_nodes[node.name]
	return def ~= nil and def.walkable ~= false, node and node.name
end

-- The walkable node the villager was carried down through, if any. A move is
-- impossible when a node in the column it now stands in starts at or above
-- its new head and below its old feet: the box would have had to pass through
-- that node. The column it came from is not checked, because walking off a
-- ledge leaves the ledge there.
local function passed_through(before, pos, box)
	local head = pos.y + box[5]
	local feet = before.y + box[2]
	if feet - (pos.y + box[2]) <= 1 then return end
	local x, z = math.floor(pos.x + 0.5), math.floor(pos.z + 0.5)
	for y = math.ceil(head - 0.05 + 0.5), math.floor(feet + 0.5) do
		if y - 0.5 < feet - 0.05 then
			local walkable, name = is_walkable({x = x, y = y, z = z})
			if walkable then return name, {x = x, y = y, z = z} end
		end
	end
end

return function(def)
	local original_step = def.on_step

	def.on_step = function(self, dtime, moveresult)
		local object = self.object
		local pos = object:get_pos()
		local before = last_pos[self]
		if pos and before and dtime >= MIN_STEP and not object:get_attach() then
			local box = self.collisionbox or object:get_properties().collisionbox
			local node, at = passed_through(before, pos, box)
			if node then
				core.log("action", string.format(
					"[living_villages] villager %s dropped through %s at %s in a %.2f s step; put back at %s",
					tostring(self._id), node, pos_string(at), dtime, pos_string(before)))
				object:set_pos(before)
				object:set_velocity(vector.zero())
				-- moveresult describes the undone move, so let mcl_mobs step
				-- without collision info rather than with the wrong info.
				moveresult = nil
			end
		end
		local result = original_step(self, dtime, moveresult)
		pos = object:get_pos()
		last_pos[self] = pos and {x = pos.x, y = pos.y, z = pos.z} or nil
		return result
	end
end
