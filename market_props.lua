-- Places and tags the ordinary nodes used by market stalls (#288).
local core = minetest

local props = {}
local VERSION = 1
local TABLE = "mcl_decor:table_wooden"
local FRAME = "mcl_itemframes:invisible_frame"
local PREFIX = "living_villages:market_"
local COUNTER_KEY = "market_props_token_counter"
local TOUCH_KEY = "player_touched"
local DROP_KEY = "player_stack_dropped"

local function key(name)
	return PREFIX .. name
end

local function pos_key(pos)
	return tostring(pos.x) .. "," .. tostring(pos.y) .. "," .. tostring(pos.z)
end

local function copy_pos(pos)
	return {x = pos.x, y = pos.y, z = pos.z}
end

local function position(pos)
	return type(pos) == "table" and type(pos.x) == "number"
		and type(pos.y) == "number" and type(pos.z) == "number"
end

function props.new(options)
	options = options or {}
	local world = options.core or core
	local site = assert(options.site, "market_props.new requires the shared market_site service")
	local storage = options.storage or world.get_mod_storage()
	local itemframes = options.itemframes or mcl_itemframes
	local make_stack = options.itemstack or ItemStack

	local api = {}

	local function tag(pos, node_name, token, owner, day, role, pair)
		local node = world.get_node_or_nil(pos)
		if not node or node.name ~= node_name then return false end
		local meta = world.get_meta(pos)
		meta:set_int(key("version"), VERSION)
		meta:set_string(key("token"), token)
		meta:set_string(key("owner"), tostring(owner))
		meta:set_int(key("day"), day)
		meta:set_string(key("role"), role)
		meta:set_string(key("pair"), pos_key(pair))
		return true
	end

	local function has_market_tag(meta)
		return meta:get_int(key("version")) ~= 0
			or meta:get_string(key("token")) ~= ""
			or meta:get_string(key("owner")) ~= ""
			or meta:get_int(key("day")) ~= 0
			or meta:get_string(key("role")) ~= ""
			or meta:get_string(key("pair")) ~= ""
	end

	local function owned(pos, token, owner, day, role, node_name, pair)
		if not position(pair) then return false end
		local node = world.get_node_or_nil(pos)
		if not node or node.name ~= node_name then return false end
		local meta = world.get_meta(pos)
		return meta:get_int(key("version")) == VERSION
			and meta:get_string(key("token")) == token
			and meta:get_string(key("owner")) == tostring(owner)
			and meta:get_int(key("day")) == day
			and meta:get_string(key("role")) == role
			and meta:get_string(key("pair")) == pos_key(pair)
	end

	local function clear_tags(meta)
		meta:set_int(key("version"), 0)
		meta:set_string(key("token"), "")
		meta:set_string(key("owner"), "")
		meta:set_int(key("day"), 0)
		meta:set_string(key("role"), "")
		meta:set_string(key("pair"), "")
		meta:set_string(key(TOUCH_KEY), "")
		meta:set_string(key(DROP_KEY), "")
	end

	local function tagged_frame(pos, token, owner, day, index, table_pos)
		return owned(pos, token, owner, day, "frame_" .. index, FRAME, table_pos)
	end

	local function remove_frame(pos, token, owner, day, index, table_pos)
		if not tagged_frame(pos, token, owner, day, index, table_pos) then
			return world.get_node_or_nil(pos) ~= nil
		end

		local meta = world.get_meta(pos)
		local inv = meta:get_inventory()
		local stack = inv:get_stack("main", 1)
		local touched = meta:get_string(key(TOUCH_KEY)) == "1"
		if touched and stack and not stack:is_empty() then
			if meta:get_string(key(DROP_KEY)) ~= "1" then
				local ok, object = pcall(world.add_item, pos, make_stack(stack))
				if not ok or not object then return false end
				meta:set_string(key(DROP_KEY), "1")
			end
		end

		local cleared = pcall(inv.set_stack, inv, "main", 1, make_stack(""))
		if not cleared then return false end
		local remaining = inv:get_stack("main", 1)
		if remaining and not remaining:is_empty() then return false end

		local removed_display = pcall(itemframes.remove_entity, pos)
		if not removed_display then return false end
		if not tagged_frame(pos, token, owner, day, index, table_pos) then
			return world.get_node_or_nil(pos) ~= nil
		end
		local removed = pcall(world.remove_node, pos)
		if not removed then return false end
		local node = world.get_node_or_nil(pos)
		return node ~= nil and node.name ~= FRAME
	end

	local function remove_table(pos, token, owner, day, index, frame_pos)
		if not owned(pos, token, owner, day, "table_" .. index, TABLE, frame_pos) then
			return world.get_node_or_nil(pos) ~= nil
		end
		local above = world.get_node_or_nil(frame_pos)
		if not above then return false end
		if tagged_frame(frame_pos, token, owner, day, index, pos) then return false end
		if above.name ~= "air" then
			-- A replacement above is player-owned now. Keep both it and its support.
			clear_tags(world.get_meta(pos))
			return true
		end
		if not owned(pos, token, owner, day, "table_" .. index, TABLE, frame_pos) then
			return world.get_node_or_nil(pos) ~= nil
		end
		local removed = pcall(world.remove_node, pos)
		if not removed then return false end
		local node = world.get_node_or_nil(pos)
		return node ~= nil and node.name ~= TABLE
	end

	local function valid_stall(stall)
		if type(stall) ~= "table" or type(stall.layout) ~= "table"
			or type(stall.layout.tables) ~= "table" or type(stall.layout.frames) ~= "table"
			or stall.token == nil or stall.owner == nil or stall.day == nil then
			return false
		end
		return true
	end

	local function remove_frames(stall)
		if not valid_stall(stall) then return false, "invalid_stall" end
		local layout = stall.layout
		local complete = true
		for index = 1, 2 do
			local pos = layout.frames[index]
			if not pos or not remove_frame(pos, stall.token, stall.owner, stall.day, index, layout.tables[index]) then
				complete = false
			end
		end
		return complete, complete and nil or "deferred"
	end

	local function cleanup(stall)
		if not valid_stall(stall) then return false, "invalid_stall" end
		local layout = stall.layout
		local frames_complete = remove_frames(stall)
		local complete = frames_complete
		for index = 1, 2 do
			local pos = layout.tables[index]
			if not pos or not remove_table(pos, stall.token, stall.owner, stall.day, index, layout.frames[index]) then
				complete = false
			end
		end
		return complete, complete and nil or "deferred"
	end

	local function rollback(created, token, owner, day)
		cleanup({layout = {tables = created.tables, frames = created.frames}, token = token, owner = owner, day = day})
	end

	local function player_name(player)
		if player and type(player.get_player_name) == "function" then
			return player:get_player_name()
		end
		return ""
	end

	local function permitted(pos, player)
		local name = player_name(player)
		return name ~= "" and (type(world.is_protected) ~= "function" or not world.is_protected(pos, name))
	end

	local function pack(...)
		return {n = select("#", ...), ...}
	end

	local function clear_previously_dropped(pos, meta)
		if meta:get_string(key(DROP_KEY)) ~= "1" then return true end
		local inv = meta:get_inventory()
		local cleared = pcall(inv.set_stack, inv, "main", 1, make_stack(""))
		if not cleared then return false end
		local stack = inv:get_stack("main", 1)
		if stack and not stack:is_empty() then return false end
		meta:set_string(key(DROP_KEY), "")
		pcall(itemframes.update_entity, pos)
		return true
	end

	function api.wrap_interactions()
		local def = world.registered_nodes and world.registered_nodes[FRAME]
		if not def or def._living_villages_market_interactions_wrapped
			or (not def.on_rightclick and not def.on_rotate) then return false end
		for _, callback_name in ipairs({"on_rightclick", "on_rotate"}) do
			local callback = callback_name
			local original = def[callback]
			if original then
				def[callback] = function(pos, ...)
					local node = world.get_node_or_nil(pos)
					if node and node.name == FRAME then
						local meta = world.get_meta(pos)
						local player = select(2, ...)
						local role = meta:get_string(key("role"))
						local pair = {x = pos.x, y = pos.y - 1, z = pos.z}
						local matching_tag = meta:get_int(key("version")) == VERSION
							and meta:get_string(key("token")) ~= ""
							and meta:get_string(key("owner")) ~= ""
							and (role == "frame_1" or role == "frame_2")
							and meta:get_string(key("pair")) == pos_key(pair)
						if matching_tag and permitted(pos, player) then
							if not clear_previously_dropped(pos, meta) then
								if callback == "on_rightclick" then return select(3, ...) end
								return nil
							end
							meta:set_string(key(TOUCH_KEY), "1")
						end
					end
					local args = pack(...)
					local result = pack(original(pos, unpack(args, 1, args.n)))
					return unpack(result, 1, result.n)
				end
			end
		end
		def._living_villages_market_interactions_wrapped = true
		return true
	end

	api.wrap_interactions()
	api.cleanup = cleanup
	api.remove_frames = remove_frames

	local function valid_input(layout, owner, day, items)
		if type(layout) ~= "table" or type(layout.tables) ~= "table" or type(layout.frames) ~= "table"
			or #layout.tables ~= 2 or #layout.frames ~= 2 then return false end
		if owner == nil or tostring(owner) == "" or type(day) ~= "number" or day ~= math.floor(day) then return false end
		if type(items) ~= "table" or type(items[1]) ~= "string" or items[1] == ""
			or type(items[2]) ~= "string" or items[2] == "" then return false end
		for index = 1, 2 do
			local table_pos, frame_pos = layout.tables[index], layout.frames[index]
			if not position(table_pos) or not position(frame_pos)
				or frame_pos.x ~= table_pos.x or frame_pos.y ~= table_pos.y + 1 or frame_pos.z ~= table_pos.z then
				return false
			end
		end
		return true
	end

	-- Reservation and map validation are repeated at arrival, immediately before writes.
	function api.setup(layout, owner, day, items, reservation)
		if reservation == nil then return nil, "reservation" end
		if not valid_input(layout, owner, day, items) then return nil, "invalid_setup" end
		if type(reservation) ~= "table"
			or reservation._market_site ~= site
			or reservation.owner ~= owner
			or reservation.layout ~= layout
			or reservation.token == nil then
			return nil, "reservation"
		end
		local valid, reason = site.valid(layout, reservation)
		if not valid then return nil, reason or "invalid_layout" end

		local counter = storage:get_int(COUNTER_KEY) + 1
		storage:set_int(COUNTER_KEY, counter)
		local token = "market-" .. tostring(counter)
		local created = {tables = {}, frames = {}, table_pairs = layout.frames}

		local function place(pos, node_name, param2, kind, index, role, pair)
			created[kind][index] = copy_pos(pos)
			local before = world.get_node_or_nil(pos)
			if not before or before.name ~= "air" then return false end
			local ok = pcall(world.add_node, pos, {name = node_name, param2 = param2 or 0})
			local node = world.get_node_or_nil(pos)
			if node and node.name == node_name then
				-- The supported stock table has no constructor and the stock frame
				-- constructor only sizes main; do not claim a node already tagged by
				-- an interleaving replacement.
				-- The constructor may have replaced this cell or tagged its own prop.
				-- Never claim a node that already carries market ownership metadata.
				local meta = world.get_meta(pos)
				if not has_market_tag(meta) then tag(pos, node_name, token, owner, day, role, pair) end
			end
			if not ok or not node or node.name ~= node_name
				or not owned(pos, token, owner, day, role, node_name, pair) then
				return false
			end
			return true
		end

		local ok, failure = pcall(function()
			for index, pos in ipairs(layout.tables) do
				if not place(pos, TABLE, 0, "tables", index, "table_" .. index, layout.frames[index]) then
					error("table placement failed")
				end
			end
			for index, pos in ipairs(layout.frames) do
				if not place(pos, FRAME, layout.frame_param2, "frames", index, "frame_" .. index, layout.tables[index]) then
					error("frame placement failed")
				end
			end
			for index, pos in ipairs(layout.frames) do
				local meta = world.get_meta(pos)
				if not owned(pos, token, owner, day, "frame_" .. index, FRAME, layout.tables[index]) then
					error("frame ownership changed")
				end
				local inv = meta:get_inventory()
				if inv:get_size("main") ~= 1 then error("frame inventory missing") end
				inv:set_stack("main", 1, make_stack(items[index]))
				local stack = inv:get_stack("main", 1)
				if not stack or stack:get_name() ~= items[index] or stack:get_count() ~= 1 then
					error("frame inventory write failed")
				end
				local display = itemframes.update_entity(pos)
				if not display or not owned(pos, token, owner, day, "frame_" .. index, FRAME, layout.tables[index]) then
					error("frame display failed")
				end
			end
		end)
		if not ok then
			rollback(created, token, owner, day)
			return nil, tostring(failure), token
		end
		return {token = token, owner = tostring(owner), day = day, layout = layout}
	end

	return api
end

return props
