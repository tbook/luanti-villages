-- Dinner (#100): a seated guest (seat.lua, #99) is served a meal on the plate
-- in front of it by the keeper staffing its tavern, eats it, and the plate
-- empties. At most one meal per guest per evening.
--
-- The meal is a display only. It is this mod's own entity, never saved
-- (static_save = false), shown where the plate would show an item; the
-- plate's inventory is never written. There is no stack to take, a player's
-- item on a plate is never touched, and a plate a player puts something on
-- mid-meal simply clears the meal. The frame's own code looks only for its
-- mcl_itemframes:item entity, so it never mistakes the meal for its item.
--
-- Load this once, at top-level load time (init.lua): it registers the entity,
-- which Luanti allows only then, and the plate holds are its own in-memory
-- table.
local core = minetest
local keeper = dofile(core.get_modpath("villages") .. "/keeper.lua")
local ENTITY = "villages:meal"
local PLATE = "mcl_itemframes:plate"
-- A guest waits this long after sitting down before it is served.
local WAIT_SECONDS = 3
-- A keeper serves one plate at a time, this often.
local SERVE_SECONDS = 3
-- How long a meal lasts, and how often the guest takes a bite.
local EAT_SECONDS = 12
local BITE_SECONDS = 0.8
-- A plate hold lapses unless renewed, so one left by a guest that unloaded
-- frees itself.
local HOLD_SECONDS = 5
-- How far from the jukebox its keeper is looked for: keeper.lua's staffing
-- distance, with room to spare.
local KEEPER_RADIUS = 4
-- The frame item entity's size and placement (mcl_itemframes base_props and
-- set_item).
local VISUAL_SIZE = 0.3
local FRAME_OFFSET = 0.42
-- A seated guest's mouth, above its origin (seat.lua sets the origin in the
-- chair; the model's head is about 1.3 above it seated).
local MOUTH_HEIGHT = 1.3

local plates = {}
local served = {}

local function key(pos)
	return pos.x .. "," .. pos.y .. "," .. pos.z
end

local function now()
	return core.get_gametime()
end

local function menu()
	local items = {}
	for _, entry in ipairs(keeper.MENU) do
		if not core.registered_items or core.registered_items[entry.offered] then
			table.insert(items, entry.offered)
		end
	end
	return items
end

-- The plate on the guest's table, if it is free for a meal: a plate with
-- nothing of a player's on it, and no other guest's meal.
local function plate_for(self)
	local seat = self._villages_seat
	if not seat or not seat.table then return end
	local pos = {x = seat.table.x, y = seat.table.y + 1, z = seat.table.z}
	local node = core.get_node_or_nil(pos)
	if not node or node.name ~= PLATE then return end
	return pos, node
end

local function plate_empty(pos)
	local stack = core.get_meta(pos):get_inventory():get_stack("main", 1)
	return not stack or stack:is_empty()
end

local function held_by_other(pos, id)
	local hold = plates[key(pos)]
	return hold and hold.id ~= id and hold.until_time >= now()
end

local function hold(self, pos)
	plates[key(pos)] = {id = self._id, until_time = now() + HOLD_SECONDS}
end

-- The keeper on duty at the guest's tavern: the villager that claimed the
-- jukebox, close by and staffing it.
local function keeper_on_duty(jukebox)
	local id = core.get_meta(jukebox):get_string("villager")
	if id == "" then return end
	for _, object in ipairs(core.get_objects_inside_radius(jukebox, KEEPER_RADIUS)) do
		local entity = object:get_luaentity()
		if entity and entity._id == id and entity._villages_keeper
			and keeper.status(entity) == "staffing the tavern" then
			return entity
		end
	end
end

local function show(pos, node, item)
	local dir = core.wallmounted_to_dir(node.param2)
	local at = {x = pos.x + dir.x * FRAME_OFFSET, y = pos.y + dir.y * FRAME_OFFSET, z = pos.z + dir.z * FRAME_OFFSET}
	local object = core.add_entity(at, ENTITY)
	if not object then return end
	local definition = core.registered_items[item] or {}
	local scale = definition.wield_scale or {x = 1, y = 1}
	object:set_rotation(vector.dir_to_rotation(dir))
	object:set_properties({
		wield_item = item,
		visual_size = {x = VISUAL_SIZE / scale.x, y = VISUAL_SIZE / scale.y},
	})
	return object
end

-- A bite: food particles from the guest's mouth and the eating sound, as a
-- player eating (mcl_hunger eat_effects).
local function bite(self, item)
	local pos = self.object:get_pos()
	if not pos then return end
	local definition = core.registered_items[item] or {}
	local texture = definition.inventory_image
	if not texture or texture == "" then texture = definition.wield_image end
	local mouth = {x = pos.x, y = pos.y + MOUTH_HEIGHT, z = pos.z}
	if texture and texture ~= "" and definition._food_particles ~= false then
		for i = 0, 8 do
			core.add_particle({
				pos = mouth,
				velocity = {x = math.random(-1, 1), y = math.random(1, 2), z = math.random(-1, 1)},
				acceleration = {x = 0, y = math.random(-9, -5), z = 0},
				expirationtime = 1,
				size = math.random(1, 2),
				collisiondetection = true,
				texture = "[combine:3x3:" .. -i .. "," .. -i .. "=" .. texture,
			})
		end
	end
	core.sound_play("mcl_hunger_bite", {
		max_hear_distance = 12, gain = 0.33, pitch = 1 + math.random(-10, 10) * 0.005, object = self.object,
	}, true)
end

local M = {}

-- Clear the meal and let the plate go. Safe to call on a guest with none.
function M.finish(self)
	local meal = self._villages_meal
	self._villages_meal = nil
	if not meal then return end
	if meal.object then meal.object:remove() end
	local hold_here = plates[key(meal.plate)]
	if hold_here and hold_here.id == self._id then plates[key(meal.plate)] = nil end
end

local function serve(self, jukebox)
	local pos, node = plate_for(self)
	if not pos or not plate_empty(pos) or held_by_other(pos, self._id) then return end
	local last = served[key(jukebox)]
	if last and now() - last < SERVE_SECONDS then return end
	if not keeper_on_duty(jukebox) then return end
	local items = menu()
	if #items == 0 then return end
	local item = items[math.random(#items)]
	local object = show(pos, node, item)
	if not object then return end
	served[key(jukebox)] = now()
	hold(self, pos)
	-- Counted from the moment it is served, so a meal cut short by standing
	-- up, a reload or a player's item still spends the evening's meal.
	self._villages_meal_day = core.get_day_count()
	self._villages_meal = {plate = pos, item = item, served_at = now(), object = object, bite_in = 0}
end

-- Each tick while seated at dinner, after the seat has been held.
function M.tick(self, dtime, jukebox)
	local meal = self._villages_meal
	if not meal then
		if self._villages_meal_day == core.get_day_count() or not jukebox then return end
		self._villages_seated_at = self._villages_seated_at or now()
		if now() - self._villages_seated_at < WAIT_SECONDS then return end
		serve(self, jukebox)
		return
	end
	-- The plate went, or a player put something on it: the meal is over.
	-- The keeper leaving is no reason: a served meal is finished.
	local node = core.get_node_or_nil(meal.plate)
	if not node or node.name ~= PLATE or not plate_empty(meal.plate)
		or not meal.object:get_pos() or now() - meal.served_at >= EAT_SECONDS then
		M.finish(self)
		return
	end
	hold(self, meal.plate)
	meal.bite_in = meal.bite_in - (dtime or 0)
	if meal.bite_in <= 0 then
		meal.bite_in = BITE_SECONDS
		bite(self, meal.item)
	end
end

-- Getting up ends the meal.
function M.stand(self)
	self._villages_seated_at = nil
	M.finish(self)
end

if core.register_entity then
	core.register_entity(ENTITY, {
		initial_properties = {
			visual = "wielditem",
			visual_size = {x = VISUAL_SIZE, y = VISUAL_SIZE},
			physical = false,
			pointable = false,
			static_save = false,
			textures = {"blank.png"},
		},
		-- Never saved; one that outlives its guest's meal clears itself.
		on_step = function(entity, dtime)
			entity._age = (entity._age or 0) + dtime
			if entity._age > EAT_SECONDS + 5 then entity.object:remove() end
		end,
	})
end

M.plates = plates
M.served = served
return M
