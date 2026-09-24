-- Tavern keeper, evening visits, and paid table service.
local core = minetest
local common = dofile(core.get_modpath("villages") .. "/common.lua")
local S = core.get_translator and core.get_translator("villages") or function(message) return message end
local DINNER_END = 18500
local SERVICE_START = 14500
local VISIT_SECONDS = 12
local ORDER_SECONDS = 90
local SEAT_SECONDS = 90
local menu = {
	bread = {item = "mcl_farming:bread", price = 1, label = S("Bread")},
	fish = {item = "mcl_fishing:fish_cooked", price = 1, label = S("Cooked fish")},
	stew = {item = "mcl_mushrooms:mushroom_stew", price = 2, label = S("Mushroom stew")},
}
local orders = {}
local seats = {}

local function same(a, b)
	return a and b and a.x == b.x and a.y == b.y and a.z == b.z
end

local function copy(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function hash(pos)
	return core.hash_node_position(pos)
end

local function clock()
	return core.get_timeofday() * 24000
end

local function service_time()
	return common.is_dinner_time() or (clock() >= SERVICE_START and clock() < DINNER_END
		and not common.is_sleep_time())
end

local function valid_keeper(villager)
	if not villager or villager.child or villager._profession ~= "tavern_keeper"
		or not villager._jobsite or not villager._id then return false end
	local node = core.get_node_or_nil(villager._jobsite)
	return node and node.name == "mcl_jukebox:jukebox"
		and core.get_meta(villager._jobsite):get_string("villager") == villager._id
end

local function keeper_at(jukebox)
	if not service_time() then return nil end
	for _, object in ipairs(core.get_objects_inside_radius(jukebox, 6)) do
		local villager = object:get_luaentity()
		if villager and valid_keeper(villager) and same(villager._jobsite, jukebox)
			and object:get_pos() and vector.distance(object:get_pos(), jukebox) <= 4 then
			return villager
		end
	end
end

local function nearby_nodes(pos, radius, names)
	return core.find_nodes_in_area(
			{x = pos.x - radius, y = pos.y - radius, z = pos.z - radius},
			{x = pos.x + radius, y = pos.y + radius, z = pos.z + radius}, names)
end

local function available_seat(jukebox, villager_id)
	local now = core.get_gametime()
	local plates = nearby_nodes(jukebox, 12, {"mcl_itemframes:plate"})
	for _, plate in ipairs(plates) do
		local inventory = core.get_meta(plate):get_inventory()
		local plate_claim = seats[hash(plate)]
		if inventory:get_size("main") > 0 and inventory:is_empty("main")
			and (not plate_claim or plate_claim.until_time < now or plate_claim.id == villager_id) then
			local chairs = nearby_nodes(plate, 2, {"group:chair"})
			for _, chair in ipairs(chairs) do
				local dx, dz = math.abs(chair.x - plate.x), math.abs(chair.z - plate.z)
				local claim = seats[hash(chair)]
				local player_sitting = false
				for _, sitting in pairs(mcl_cozy.players) do
					if sitting[2] == "sit" and vector.distance(sitting[1], chair) < 0.6 then
						player_sitting = true
						break
					end
				end
				if not player_sitting and chair.y == plate.y - 1 and dx + dz == 1
					and (not claim or claim.until_time < now or claim.id == villager_id) then
					return chair, plate
				end
			end
		end
	end
end

local function release_seat(self)
	local visit = self._villages_dining
	local reserved = self._villages_tavern_reserved or visit
	if reserved then
		local key = hash(reserved.chair)
		if seats[key] and seats[key].id == self._id then seats[key] = nil end
		local plate_key = hash(reserved.plate)
		if seats[plate_key] and seats[plate_key].id == self._id then seats[plate_key] = nil end
	end
	self._villages_tavern_reserved = nil
	if visit then
		self._villages_dining = nil
		if visit.box then
			self.collisionbox = visit.box
			self.object:set_properties({collisionbox = visit.box})
		end
		self.object:set_bone_position("leg.right", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
		self.object:set_bone_position("leg.left", {x = 0, y = 0, z = 0}, {x = 0, y = 0, z = 0})
	end
	self._villages_tavern_target = nil
	self._villages_tavern_route = nil
end

local function begin_visit(self, chair, plate)
	local now = core.get_gametime()
	local claim = seats[hash(chair)]
	if not common.is_dinner_time() or not claim or claim.id ~= self._id
		or claim.until_time < now or core.get_item_group(core.get_node(chair).name, "chair") == 0
		or core.get_node(plate).name ~= "mcl_itemframes:plate" then
		release_seat(self)
		return
	end
	if not keeper_at(self._villages_tavern_jukebox) then
		release_seat(self)
		return
	end
	self._villages_dining = {
		chair = copy(chair), plate = copy(plate), until_time = now + VISIT_SECONDS,
		box = table.copy(self.collisionbox),
	}
	self._villages_tavern_reserved = nil
	self._villages_tavern_target = nil
	self._villages_tavern_route = nil
	self.state = "stand"
	self.object:set_velocity(vector.zero())
	self.object:set_pos({x = chair.x, y = chair.y + 0.12, z = chair.z})
	self.collisionbox = {-0.2, 0, -0.2, 0.2, 1.3, 0.2}
	self.object:set_properties({collisionbox = self.collisionbox})
	self.object:set_bone_position("leg.right", {x = 0, y = 0, z = 0}, {x = 80, y = 0, z = 0})
	self.object:set_bone_position("leg.left", {x = 0, y = 0, z = 0}, {x = 80, y = 0, z = 0})
	core.add_particle({pos = {x = plate.x, y = plate.y + 0.3, z = plate.z},
		velocity = {x = 0, y = 0.2, z = 0}, expirationtime = 1.2,
		size = 2, texture = "farming_bread.png"})
end

local function try_dinner(self)
	if not self._id then return end
	local now, day = core.get_gametime(), core.get_day_count()
	if self._villages_last_dinner_day == day or (self._villages_dinner_retry or 0) > now then return end
	if self._villages_tavern_target or self.state == "gowp" or self.following then return end
	local pos = self.object:get_pos()
	if not pos then return end
	self._villages_dinner_retry = now + 25
	local taverns = nearby_nodes(pos, 40, {"mcl_jukebox:jukebox"})
	table.sort(taverns, function(a, b) return vector.distance(pos, a) < vector.distance(pos, b) end)
	for _, jukebox in ipairs(taverns) do
		if keeper_at(jukebox) then
			local chair, plate = available_seat(jukebox, self._id)
			if chair then
				seats[hash(chair)] = {id = self._id, until_time = now + SEAT_SECONDS}
				seats[hash(plate)] = {id = self._id, until_time = now + SEAT_SECONDS}
				self._villages_tavern_reserved = {chair = copy(chair), plate = copy(plate)}
				self._villages_tavern_jukebox = copy(jukebox)
				self._villages_tavern_target = copy(chair)
				if self:gopath(chair, function(entity)
					begin_visit(entity, chair, plate)
				end, true) then
					return
				end
				release_seat(self)
			end
		end
	end
end

local function show_menu(player, keeper)
	local name = player:get_player_name()
	orders[name] = nil
	local jukebox = keeper._jobsite
	local form = "formspec_version[4]size[7,5]label[0.4,0.4;Tavern menu]" ..
		"button[0.4,1.0;6.2,0.8;bread;" .. core.formspec_escape(menu.bread.label .. " - 1 " .. S("emerald")) .. "]" ..
		"button[0.4,2.0;6.2,0.8;fish;" .. core.formspec_escape(menu.fish.label .. " - 1 " .. S("emerald")) .. "]" ..
		"button[0.4,3.0;6.2,0.8;stew;" .. core.formspec_escape(menu.stew.label .. " - 2 " .. S("emeralds")) .. "]"
	orders[name] = {choosing = true, jukebox = copy(jukebox), keeper_id = keeper._id}
	core.show_formspec(name, "villages:tavern_order", form)
end

local function seat_plate(player, jukebox)
	local name = player:get_player_name()
	local sitting = mcl_cozy.players[name]
	if not sitting or sitting[2] ~= "sit" then return end
	local chair = vector.round(sitting[1])
	if core.get_item_group(core.get_node(chair).name, "chair") == 0 then return end
	if vector.distance(chair, jukebox) > 12 then return end
	local plates = nearby_nodes(chair, 2, {"mcl_itemframes:plate"})
	for _, plate in ipairs(plates) do
		local plate_claim = seats[hash(plate)]
		local chair_claim = seats[hash(chair)]
		if plate.y == chair.y + 1 and math.abs(plate.x - chair.x) + math.abs(plate.z - chair.z) == 1
			and not core.is_protected(plate, name)
			and (not plate_claim or plate_claim.until_time < core.get_gametime())
			and (not chair_claim or chair_claim.until_time < core.get_gametime()) then
			local inventory = core.get_meta(plate):get_inventory()
			if inventory:get_size("main") > 0 and inventory:is_empty("main") then
				return plate, inventory
			end
		end
	end
end

local function install(def)
	if not mobs_mc or not mobs_mc.register_villager_profession
		or not mobs_mc.register_villager_activity_modifier then
		core.log("warning", "[villages] VoxeLibre villager extension API is unavailable; tavern service disabled")
		return
	end
	local emerald = {"mcl_core:emerald", 1, 1}
	mobs_mc.register_villager_profession("tavern_keeper", {
		name = S("Tavern Keeper"),
		texture = "mobs_mc_villager_butcher.png^[colorize:#6b3520:35",
		jobsite = "mcl_jukebox:jukebox",
		trades = {{
			{emerald, {"mcl_farming:bread", 3, 3}},
			{emerald, {"mcl_fishing:fish_cooked", 2, 2}},
			{{"mcl_core:emerald", 2, 2}, {"mcl_mushrooms:mushroom_stew", 1, 1}},
		}},
	})
	mobs_mc.register_villager_activity_modifier(function(tod)
		if tod >= 15000 and tod < DINNER_END then return "villages:dinner" end
	end)

	local original_click = def.on_rightclick
	def.on_rightclick = function(self, clicker)
		if clicker and clicker:is_player() and clicker:get_player_control().sneak
			and valid_keeper(self) and service_time() and self.object:get_pos()
			and vector.distance(self.object:get_pos(), self._jobsite) < 4 then
			show_menu(clicker, self)
			return
		end
		return original_click(self, clicker)
	end

	local original_activate = def.on_activate
	def.on_activate = function(self, staticdata, dtime)
		local result = original_activate(self, staticdata, dtime)
		release_seat(self)
		self._villages_dinner_retry = nil
		return result
	end

	local original_custom = def.do_custom
	def.do_custom = function(self, dtime)
		if self._villages_dining then
			local visit = self._villages_dining
			if not common.is_dinner_time() or core.get_gametime() >= visit.until_time
				or core.get_item_group(core.get_node(visit.chair).name, "chair") == 0
				or not keeper_at(self._villages_tavern_jukebox) then
				self._villages_last_dinner_day = core.get_day_count()
				release_seat(self)
			else
				self.object:set_velocity(vector.zero())
				return false
			end
		end
		local result = original_custom(self, dtime)
		if result == false then return result end
		if self._villages_tavern_target and not common.is_dinner_time() then
			release_seat(self)
		elseif self._villages_tavern_reserved then
			local claim = seats[hash(self._villages_tavern_reserved.chair)]
			if not claim or claim.id ~= self._id or claim.until_time < core.get_gametime() then
				release_seat(self)
			end
		end
		if common.is_dinner_time() then
			if valid_keeper(self) then
				if not self._villages_tavern_target and self.state ~= "gowp"
					and self.object:get_pos() and vector.distance(self.object:get_pos(), self._jobsite) >= 3 then
					self._villages_tavern_target = copy(self._jobsite)
					self:gopath(self._jobsite, nil, true)
				end
			elseif self._id then
				try_dinner(self)
			end
		end
		return result
	end

	core.register_on_player_receive_fields(function(player, formname, fields)
		if formname ~= "villages:tavern_order" then return end
		local name = player:get_player_name()
		local order = orders[name]
		if not order or not order.choosing then return true end
		local choice
		for key in pairs(menu) do if fields[key] then choice = key; break end end
		if not choice then
			if fields.quit then orders[name] = nil end
			return true
		end
		if not keeper_at(order.jukebox) or vector.distance(player:get_pos(), order.jukebox) > 8 then
			orders[name] = nil
			return true
		end
		order.choosing = nil
		order.item = menu[choice].item
		order.price = menu[choice].price
		order.until_time = core.get_gametime() + ORDER_SECONDS
		core.chat_send_player(name, S("Sit at an empty tavern table to receive your meal."))
		return true
	end)

	core.register_on_leaveplayer(function(player) orders[player:get_player_name()] = nil end)
	local timer = 0
	core.register_globalstep(function(dtime)
		timer = timer + dtime
		if timer < 1 then return end
		timer = 0
		for name, order in pairs(orders) do
			if not order.choosing then
				local player = core.get_player_by_name(name)
				if not player or order.until_time < core.get_gametime()
					or not keeper_at(order.jukebox) then
					orders[name] = nil
				elseif player:get_pos() then
					local plate, plate_inventory = seat_plate(player, order.jukebox)
					local inventory = player:get_inventory()
					local payment = "mcl_core:emerald " .. order.price
					if plate and inventory:contains_item("main", payment) then
						inventory:remove_item("main", payment)
						plate_inventory:set_stack("main", 1, order.item)
						mcl_itemframes.update_entity(plate)
						orders[name] = nil
						core.chat_send_player(name, S("Your meal is served."))
					end
				end
			end
		end
	end)
end

return install
