-- Places and tags the ordinary nodes used by market stalls (#288).
local core = minetest

local props = {}
local VERSION = 1
local TABLE = "mcl_decor:table_wooden"
local FRAME = "mcl_itemframes:invisible_frame"
local PREFIX = "living_villages:market_"
local COUNTER_KEY = "market_props_token_counter"
local TOUCH_KEY = "player_touched"
local RUNTIME_KEY = "_living_villages_market_props_runtime"

local function runtime_for(world)
	local state = world[RUNTIME_KEY]
	if not state then
		state = {records = {}, callbacks_registered = false}
		world[RUNTIME_KEY] = state
	end
	return state
end

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
	local runtime = runtime_for(world)
	local runtime_records = runtime.records
	local site = assert(options.site, "market_props.new requires the shared market_site service")
	local storage = options.storage or world.get_mod_storage()
	local itemframes = options.itemframes or mcl_itemframes
	local make_stack = options.itemstack or ItemStack

	local api = {}
	local now = options.now or function()
		if world.get_us_time then return world.get_us_time() / 1000000 end
		return os.time()
	end
	local current_day = options.day_count or world.get_day_count or function() return nil end
	local is_holiday = options.is_holiday or (options.common and options.common.is_holiday)
		or function()
			if mcl_moon and mcl_moon.get_moon_phase then
				local phase = mcl_moon.get_moon_phase()
				if world.get_timeofday() <= 0.5 then phase = phase + 1 end
				return phase % 4 == 0
			end
			return world.get_day_count and world.get_day_count() % 4 == 0 or false
		end
	local is_thunder = options.is_thunder or function()
		return mcl_weather and mcl_weather.get_weather
			and mcl_weather.get_weather() == "thunder" or false
	end
	local validate_session = options.validate_session or function(record)
		if record.owner_ref and record.owner_ref.get_luaentity then
			local entity = record.owner_ref:get_luaentity()
			return entity ~= nil and entity._villages_market_session == record.session
		end
		return false
	end

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
			local preserved = make_stack(stack)
			local cleared = pcall(inv.set_stack, inv, "main", 1, make_stack(""))
			local remaining = inv:get_stack("main", 1)
			if remaining and not remaining:is_empty() then return false end
			if not cleared and not (remaining and remaining:is_empty()) then return false end
			local ok, object = pcall(world.add_item, pos, make_stack(preserved))
			if not ok or not object then
				pcall(inv.set_stack, inv, "main", 1, make_stack(preserved))
				return false
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

	local function cleanup_pair(token, owner, day, index, table_pos, frame_pos)
		local frame_ok = remove_frame(frame_pos, token, owner, day, index, table_pos)
		local table_ok = remove_table(table_pos, token, owner, day, index, frame_pos)
		return frame_ok and table_ok
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
		cleanup({layout = created.intended, token = token, owner = owner, day = day})
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

	local function parse_pair(value)
		local x, y, z = value:match("^(-?%d+),(-?%d+),(-?%d+)$")
		if not x then return nil end
		return {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
	end

	local function current_window()
		local ticks = (world.get_timeofday() * 24000) % 24000
		return ticks >= 15000 and ticks < 17500
	end

	local function same_pos(a, b)
		return a and b and a.x == b.x and a.y == b.y and a.z == b.z
	end

	local function runtime_valid(record)
		local clock = now()
		if type(clock) ~= "number" or clock < record.last_now then return false end
		record.last_now = clock
		if clock > record.deadline + 1 or clock >= record.lease_expires then return false end
		if current_day() ~= record.day or not is_holiday() or not current_window() or is_thunder() then
			return false
		end
		local valid, reason = validate_session(record)
		if valid == nil then return nil, reason end
		return valid == true
	end

	-- A controller registers only after arrival and renews while its session remains active.
	function api.activate(stall, owner_ref, session, deadline, context)
		if not valid_stall(stall) or owner_ref == nil or session == nil or type(deadline) ~= "number" then
			return false
		end
		local clock = now()
		runtime_records[stall.token] = {
			stall = stall,
			owner = tostring(stall.owner),
			owner_ref = owner_ref,
			session = session,
			context = context,
			day = stall.day,
			deadline = deadline,
			last_now = clock,
			lease_expires = clock + 10,
		}
		return true
	end

	function api.renew(token, owner_ref, session)
		local record = runtime_records[token]
		if not record or record.owner_ref ~= owner_ref or record.session ~= session then return false end
		local clock = now()
		if runtime_valid(record) ~= true then
			runtime_records[token] = nil
			return false
		end
		record.lease_expires = clock + 10
		return true
	end

	function api.release(token, owner_ref, session)
		local record = runtime_records[token]
		if not record or (owner_ref and record.owner_ref ~= owner_ref)
			or (session and record.session ~= session) then return false end
		runtime_records[token] = nil
		return true
	end

	-- validate_session may also check the bell; nil means a needed node is unloaded.
	-- Shared by both callbacks. Pair-local work avoids loading or scanning a mapblock.
	function api.check_prop(pos)
		local node = world.get_node_or_nil(pos)
		if not node or (node.name ~= TABLE and node.name ~= FRAME) then return false end
		local meta = world.get_meta(pos)
		if not has_market_tag(meta) then return false end
		local role = meta:get_string(key("role"))
		local token = meta:get_string(key("token"))
		local owner = meta:get_string(key("owner"))
		local day = meta:get_int(key("day"))
		local pair = parse_pair(meta:get_string(key("pair")))
		local role_kind, role_index = role:match("^(table)_(%d+)$")
		if not role_kind then role_kind, role_index = role:match("^(frame)_(%d+)$") end
		local index = tonumber(role_index)
		if meta:get_int(key("version")) ~= VERSION or token == "" or owner == ""
			or not index or index < 1 or index > 2 or not pair then return false end
		local table_pos, frame_pos
		if node.name == TABLE and role == "table_" .. index then
			table_pos, frame_pos = copy_pos(pos), pair
		elseif node.name == FRAME and role == "frame_" .. index then
			table_pos, frame_pos = pair, copy_pos(pos)
		else
			return false
		end
		local record = runtime_records[token]
		if record and record.owner == owner and record.day == day
			and record.stall.token == token and record.stall.owner == owner
			and record.stall.day == day
			and same_pos(record.stall.layout.tables[index], table_pos)
			and same_pos(record.stall.layout.frames[index], frame_pos) then
			local valid = runtime_valid(record)
			if valid == true then return true end
			if valid == nil then return nil end
		end
		if record then runtime_records[token] = nil end
		local complete = cleanup_pair(token, owner, day, index, table_pos, frame_pos)
		if complete then return false end
		return nil
	end

	if not runtime.callbacks_registered and world.register_lbm and world.register_abm then
		world.register_lbm({
			name = "living_villages:market_orphan_props",
			nodenames = {TABLE, FRAME},
			run_at_every_load = true,
			action = function(pos) api.check_prop(pos) end,
		})
		world.register_abm({
			label = "living_villages:market_orphan_props",
			nodenames = {TABLE, FRAME},
			interval = 5,
			chance = 1,
			catch_up = false,
			action = function(pos) api.check_prop(pos) end,
		})
		runtime.callbacks_registered = true
	end

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
		local intended = {tables = {}, frames = {}}
		for index = 1, 2 do
			intended.tables[index] = copy_pos(layout.tables[index])
			intended.frames[index] = copy_pos(layout.frames[index])
		end
		local created = {tables = {}, frames = {}, intended = intended}

		local function place(pos, node_name, param2, kind, index, role, pair)
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
			local is_owned = node and node.name == node_name
				and owned(pos, token, owner, day, role, node_name, pair)
			if is_owned then created[kind][index] = copy_pos(pos) end
			if not ok or not is_owned then
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
