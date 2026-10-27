-- Places and tags the ordinary nodes used by market stalls (#288).
local core = minetest

local props = {}
local VERSION = 1
local TABLE = "mcl_decor:table_wooden"
local FRAME = "mcl_itemframes:invisible_frame"
local PREFIX = "living_villages:market_"
local COUNTER_KEY = "market_props_token_counter"

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

	local function rollback(created, token, owner, day)
		for index = 1, 2 do
			local pos = created.frames[index]
			if pos and owned(pos, token, owner, day, "frame_" .. index, FRAME, created.tables[index]) then
				local cleared = pcall(function()
					local inv = world.get_meta(pos):get_inventory()
					inv:set_stack("main", 1, make_stack(""))
				end)
				local removed_display = cleared and pcall(itemframes.remove_entity, pos)
				if removed_display then
					pcall(world.remove_node, pos)
				end
			end
		end
		for index = 1, 2 do
			local pos = created.tables[index]
			if pos and owned(pos, token, owner, day, "table_" .. index, TABLE, created.table_pairs[index]) then
				local above = world.get_node_or_nil(created.table_pairs[index])
				if above and above.name == "air" then
					pcall(world.remove_node, pos)
				end
			end
		end
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
