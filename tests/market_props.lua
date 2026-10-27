-- Setup and rollback tests use the stock frame callback behavior from mineclone2.
local function key(pos)
	return pos.x .. ":" .. pos.y .. ":" .. pos.z
end

local world_nodes, metadata, displays, drops
local construct_count, write_count, pending
local fail_add_at, fail_inventory, fail_clear_inventory, fail_display_at, replace_first_frame
local fail_drop, protected, violations, unloaded
local remove_calls
local storage_values
local constructor_hooks, test_itemframes, test_site
local registered_lbms, registered_abms
local mods_loaded_callbacks
local clock_value, day_value, timeofday_value, thunder_value, owner_valid
local timers
local frame_name = "mcl_itemframes:invisible_frame"
local table_name = "mcl_decor:table_wooden"

local function stack(name, count, fields)
	if type(name) == "table" then fields, count, name = name.fields, name.count, name.name end
	local value = {name = name or "", count = count or (name and name ~= "" and 1 or 0), fields = fields or {}}
	function value:is_empty() return self.name == "" or self.count == 0 end
	function value:get_name() return self.name end
	function value:get_count() return self.count end
	function value:take_item(amount)
		local taken = stack(self.name, math.min(amount or 1, self.count), self.fields)
		self.count = self.count - taken.count
		if self.count <= 0 then self.name, self.count, self.fields = "", 0, {} end
		return taken
	end
	function value:peek_item(amount) return stack(self.name, math.min(amount or 1, self.count), self.fields) end
	return value
end

ItemStack = function(name, count, fields) return stack(name, count, fields) end

local frame_def = {}
local function frame_on_construct(pos)
	construct_count = construct_count + 1
	local inv = minetest.get_meta(pos):get_inventory()
	inv:set_size("main", 1)
	if replace_first_frame and key(pos) == key(replace_first_frame.trigger) then
		local replacement_pos = replace_first_frame.pos
		replace_first_frame = nil
		-- Simulate a same-name player replacement through the normal node API.
		minetest.set_node(replacement_pos, {name = frame_name})
	end
end

frame_def.on_construct = frame_on_construct
frame_def.on_destruct = function(pos)
	local inv = minetest.get_meta(pos):get_inventory()
	local item = inv:get_stack("main", 1)
	if item and not item:is_empty() then drops[#drops + 1] = {pos = key(pos), stack = item} end
	inv:set_stack("main", 1, ItemStack(""))
	displays[key(pos)] = nil
end
frame_def.on_rightclick = function(pos, _node, clicker, wield, _pointed)
	local name = clicker:get_player_name()
	if minetest.is_protected(pos, name) then
		minetest.record_protection_violation(pos, name)
		return wield, "protected"
	end
	local inv = minetest.get_meta(pos):get_inventory()
	local current = inv:get_stack("main", 1)
	local item = clicker.creative and wield:peek_item() or wield:take_item()
	if not current:is_empty() then minetest.add_item(pos, current) end
	inv:set_stack("main", 1, ItemStack(item))
	test_itemframes.update_entity(pos)
	return wield, "rightclick-result"
end
frame_def.on_rotate = function(pos, _node, user)
	local name = user:get_player_name()
	if minetest.is_protected(pos, name) then
		minetest.record_protection_violation(pos, name)
		return "protected-rotate"
	end
	local inv = minetest.get_meta(pos):get_inventory()
	local current = inv:get_stack("main", 1)
	if not current:is_empty() then minetest.add_item(pos, current); inv:set_stack("main", 1, ItemStack("")) end
	test_itemframes.update_entity(pos)
	return "rotate-result", nil, "tail"
end
local stock_on_rightclick, stock_on_rotate = frame_def.on_rightclick, frame_def.on_rotate

local function reset(options)
	frame_def.on_rightclick, frame_def.on_rotate = stock_on_rightclick, stock_on_rotate
	frame_def._living_villages_market_interactions_wrapped = nil
	world_nodes, metadata, displays, drops = {}, {}, {}, {}
	remove_calls = {}
	construct_count, write_count, pending = 0, 0, {}
	fail_add_at, fail_inventory, fail_clear_inventory, fail_display_at, replace_first_frame = nil, false, nil, nil, nil
	fail_drop, protected, violations, unloaded = false, false, {}, {}
	constructor_hooks = {}
	registered_lbms, registered_abms = {}, {}
	mods_loaded_callbacks = {}
	clock_value, day_value, timeofday_value, thunder_value, owner_valid = 100, 4, 0.5, false, true
	timers = {}
	storage_values = storage_values or {}
	minetest = {
		get_modpath = function() return "." end,
		get_us_time = function() return clock_value * 1000000 end,
		get_day_count = function() return day_value end,
		get_timeofday = function() return timeofday_value end,
		register_lbm = function(spec) registered_lbms[#registered_lbms + 1] = spec end,
		register_abm = function(spec) registered_abms[#registered_abms + 1] = spec end,
		register_on_mods_loaded = function(callback) mods_loaded_callbacks[#mods_loaded_callbacks + 1] = callback end,
		after = function(delay, callback) timers[#timers + 1] = {at = clock_value + delay, callback = callback} end,
		get_mod_storage = function()
			return {
				get_int = function(_, name) return storage_values[name] or 0 end,
				set_int = function(_, name, value) storage_values[name] = value end,
			}
		end,
		get_node_or_nil = function(pos)
			if unloaded[key(pos)] then return nil end
			local node = world_nodes[key(pos)]
			return node and {name = node.name, param2 = node.param2} or {name = "air", param2 = 0}
		end,
		get_node = function(pos) return minetest.get_node_or_nil(pos) end,
		registered_nodes = options and options.late_frame_registration and {} or {[frame_name] = frame_def},
		is_protected = function() return protected end,
		record_protection_violation = function(pos, name) violations[#violations + 1] = {pos = key(pos), name = name} end,
		add_item = function(pos, item)
			if fail_drop then return nil end
			local dropped = ItemStack(item)
			if not dropped:is_empty() then drops[#drops + 1] = {pos = key(pos), stack = dropped} end
			return {name = "__builtin:item"}
		end,
		get_meta = function(pos)
			local node_key = key(pos)
			metadata[node_key] = metadata[node_key] or {fields = {}, lists = {}, sizes = {}}
			local data = metadata[node_key]
			local inv = {}
			function inv:set_size(name, size)
				data.sizes[name] = size
				data.lists[name] = data.lists[name] or {}
			end
			function inv:get_size(name) return data.sizes[name] or 0 end
			function inv:set_stack(name, index, item)
				if fail_inventory then fail_inventory = false; error("injected inventory write failure") end
				if fail_clear_inventory == node_key and item:is_empty() then
					fail_clear_inventory = nil
					error("injected inventory clear failure")
				end
				data.lists[name] = data.lists[name] or {}
				data.lists[name][index] = ItemStack(item)
			end
			function inv:get_stack(name, index)
				return (data.lists[name] or {})[index] or ItemStack("")
			end
			local meta = {}
			function meta:get_inventory() return inv end
			function meta:set_string(name, value) data.fields[name] = tostring(value) end
			function meta:get_string(name) return data.fields[name] or "" end
			function meta:set_int(name, value) data.fields[name] = value end
			function meta:get_int(name) return data.fields[name] or 0 end
			function meta:to_table() return data end
			return meta
		end,
		add_node = function(pos, node)
			write_count = write_count + 1
			local old = world_nodes[key(pos)]
			if old and old.name ~= "air" then
				local def = old.name == frame_name and frame_def or {}
				if def.on_destruct then def.on_destruct(pos) end
			end
			world_nodes[key(pos)] = {name = node.name, param2 = node.param2 or 0}
			metadata[key(pos)] = nil
			local def = node.name == frame_name and frame_def or {}
			if def.on_construct then def.on_construct(pos) end
			if constructor_hooks[node.name] then constructor_hooks[node.name](pos) end
			if fail_add_at == write_count then error("injected node write failure") end
		end,
		set_node = function(pos, node)
			write_count = write_count + 1
			local old = world_nodes[key(pos)]
			local def = old and old.name == frame_name and frame_def or {}
			if def.on_destruct then def.on_destruct(pos) end
			world_nodes[key(pos)] = {name = node.name, param2 = node.param2 or 0}
			metadata[key(pos)] = nil
			def = node.name == frame_name and frame_def or {}
			if def.on_construct then def.on_construct(pos) end
		end,
		remove_node = function(pos)
			remove_calls[key(pos)] = (remove_calls[key(pos)] or 0) + 1
			local old = world_nodes[key(pos)]
			local def = old and old.name == frame_name and frame_def or {}
			if def.on_destruct then def.on_destruct(pos) end
			world_nodes[key(pos)] = {name = "air", param2 = 0}
			metadata[key(pos)] = nil
		end,
	}
	mcl_weather = {get_weather = function() return thunder_value and "thunder" or "clear" end}
	mcl_moon = nil
	local site = {}
	function site.valid(layout, reservation)
			if reservation and reservation.layout ~= layout then return false, "reservation" end
			for _, list in ipairs({layout.tables, layout.frames}) do
				for _, pos in ipairs(list) do
					if minetest.get_node_or_nil(pos).name ~= "air" then return false, "destination_not_air" end
				end
			end
			return true
	end
	test_site = site
	local itemframes = {
		remove_entity = function(pos) displays[key(pos)] = nil end,
		update_entity = function(pos)
			if fail_display_at == key(pos) then error("injected display failure") end
			local inv = minetest.get_meta(pos):get_inventory()
			local item = inv:get_stack("main", 1)
			if item:is_empty() then displays[key(pos)] = nil; return nil end
			local display = {name = "mcl_itemframes:item", pos = key(pos), stack = item}
			displays[key(pos)] = display
			return display
		end,
	}
	test_itemframes = itemframes
	options = options or {}
	local defer_mods_loaded = options.defer_mods_loaded
	options.site, options.itemframes = site, itemframes
	if options.validate_session == nil then
		options.validate_session = function(record) return owner_valid, owner_valid and nil or "owner" end
	end
	local api = dofile("market_props.lua").new(options)
	if not defer_mods_loaded then
		for _, callback in ipairs(mods_loaded_callbacks) do callback() end
	end
	return api
end

local function layout(x)
	return {
		tables = {{x = x, y = 0, z = 0}, {x = x + 1, y = 0, z = 0}},
		frames = {{x = x, y = 1, z = 0}, {x = x + 1, y = 1, z = 0}},
		frame_param2 = 1,
	}
end

local function fixture_reservation(layout_value, owner, site)
	site = site or test_site
	return {_market_site = site, owner = owner, layout = layout_value, token = "fixture-token"}
end

local function place_owned(api, x, owner)
	local value = layout(x)
	local result = assert(api.setup(value, owner, day_value, {"test:apple", "test:carrot"},
		fixture_reservation(value, owner)))
	return value, result
end

local function count_nodes(name)
	local count = 0
	for _, node in pairs(world_nodes) do if node.name == name then count = count + 1 end end
	return count
end

local function assert_clean(layout_value, message)
	for _, pos in ipairs(layout_value.frames) do
		assert(not displays[key(pos)], message .. ": no frame display")
	end
	assert(#drops == 0, message .. ": no generated item drops")
end

-- Preflight rejection must not allocate tokens, write nodes, or run callbacks.
reset()
local api = reset()
local blocked = layout(0)
world_nodes[key(blocked.tables[1])] = {name = "test:stone"}
local before = storage_values.market_props_token_counter or 0
local result, reason = api.setup(blocked, "villager-a", 17, {"test:apple", "test:carrot"},
	fixture_reservation(blocked, "villager-a"))
assert(not result and reason == "destination_not_air", "preflight reports changed destination")
assert(write_count == 0 and construct_count == 0, "preflight failure performs no writes")
assert((storage_values.market_props_token_counter or 0) == before, "preflight failure does not consume a token")

-- Successful setup uses node constructors, tags all props and makes both displays.
local late_registration_api = reset({late_frame_registration = true, defer_mods_loaded = true})
assert(not frame_def._living_villages_market_interactions_wrapped,
	"frame callbacks wait for the mods-loaded hook")
minetest.registered_nodes[frame_name] = frame_def
for _, callback in ipairs(mods_loaded_callbacks) do callback() end
assert(frame_def._living_villages_market_interactions_wrapped,
	"late item-frame registration is wrapped after mods load")
api = reset()
local stall = layout(2)
local success = assert(api.setup(stall, "villager-a", 17, {"test:apple", "test:carrot"},
	fixture_reservation(stall, "villager-a")))
assert(success.token == "market-" .. tostring(before + 1), "token is allocated from persistent counter")
assert(count_nodes(table_name) == 2 and count_nodes(frame_name) == 2, "success writes exactly two tables and two frames")
assert(construct_count == 2, "frame constructors ran through add_node")
local frame_meta_prefix = "living_villages:market_"
for index = 1, 2 do
	local table_pos, frame_pos = stall.tables[index], stall.frames[index]
	assert(world_nodes[key(frame_pos)].param2 == stall.frame_param2, "frame faces up toward its supporting table")
	for _, pair in ipairs({{table_pos, "table_" .. index, frame_pos}, {frame_pos, "frame_" .. index, table_pos}}) do
		local data = metadata[key(pair[1])].fields
		assert(data[frame_meta_prefix .. "version"] == 1, "tag version is present")
		assert(data[frame_meta_prefix .. "token"] == success.token, "tag token matches setup")
		assert(data[frame_meta_prefix .. "owner"] == "villager-a", "tag owner matches villager id")
		assert(data[frame_meta_prefix .. "day"] == 17, "tag creation day matches")
		assert(data[frame_meta_prefix .. "role"] == pair[2], "tag identifies role")
		assert(data[frame_meta_prefix .. "pair"] == key(pair[3]):gsub(":", ","), "tag identifies paired position")
	end
	local inventory = metadata[key(frame_pos)].lists.main[1]
	assert(inventory:get_name() == (index == 1 and "test:apple" or "test:carrot")
		and inventory:get_count() == 1, "each display holds exactly one contracted item")
	assert(displays[key(frame_pos)] and displays[key(frame_pos)].name == "mcl_itemframes:item", "frame display was updated")
end
assert(write_count == 4 and count_nodes("air") == 0, "success writes only four prop nodes")

-- A new module instance shares mod storage and cannot reuse the previous token.
local second_site = {valid = function() return true end}
local second_api = dofile("market_props.lua").new({
	site = second_site,
	itemframes = {
		remove_entity = function(pos) displays[key(pos)] = nil end,
		update_entity = function(pos)
			local display = {name = "mcl_itemframes:item", pos = key(pos)}
			displays[key(pos)] = display
			return display
		end,
	},
})
local other = layout(8)
local next_setup = assert(second_api.setup(other, "villager-b", 18, {"test:bread", "test:potato"},
	fixture_reservation(other, "villager-b", second_site)))
assert(next_setup.token ~= success.token and next_setup.token == "market-" .. tostring(before + 2),
	"persistent counter makes tokens unique across module sessions")

-- Failure after construction and after a display update clears generated stock before destructors.
reset()
api = reset()
local partially_written = layout(12)
fail_add_at = 4
local failed = api.setup(partially_written, "villager-c", 19, {"test:apple", "test:carrot"},
	fixture_reservation(partially_written, "villager-c"))
assert(not failed, "node write failure aborts setup")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0, "constructor failure rolls back matching props")
assert(construct_count == 2, "the failing frame constructor ran before rollback")
assert_clean(partially_written, "node write rollback")

reset()
api = reset()
partially_written = layout(16)
fail_display_at = key(partially_written.frames[2])
failed = api.setup(partially_written, "villager-c", 19, {"test:apple", "test:carrot"},
	fixture_reservation(partially_written, "villager-c"))
assert(not failed, "display failure aborts setup")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0, "display failure removes all owned nodes")
assert_clean(partially_written, "display rollback")

reset()
api = reset()
partially_written = layout(20)
fail_inventory = true
failed = api.setup(partially_written, "villager-c", 19, {"test:apple", "test:carrot"},
	fixture_reservation(partially_written, "villager-c"))
assert(not failed, "inventory write failure aborts setup")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0, "inventory failure removes all owned nodes")
assert_clean(partially_written, "inventory rollback")

-- Rollback is token-scoped and preserves an untagged same-name player replacement.
reset()
api = reset()
local owner_stall = layout(24)
local owner_setup = assert(api.setup(owner_stall, "villager-a", 20, {"test:apple", "test:carrot"},
	fixture_reservation(owner_stall, "villager-a")))
local failing_stall = layout(30)
replace_first_frame = {trigger = failing_stall.frames[2], pos = failing_stall.frames[1]}
fail_display_at = key(failing_stall.frames[2])
failed = api.setup(failing_stall, "villager-b", 20, {"test:bread", "test:potato"},
	fixture_reservation(failing_stall, "villager-b"))
assert(not failed, "replacement during setup invalidates the operation")
assert(world_nodes[key(failing_stall.frames[1])].name == frame_name,
	"same-name untagged replacement survives rollback")
assert(metadata[key(failing_stall.frames[1])].fields[frame_meta_prefix .. "token"] == nil,
	"replacement does not retain market ownership tags")
assert(world_nodes[key(owner_stall.tables[1])].name == table_name
	and metadata[key(owner_stall.tables[1])].fields[frame_meta_prefix .. "token"] == owner_setup.token,
	"another owner's matching props remain untouched")
assert(count_nodes(table_name) == 3 and count_nodes(frame_name) == 3,
	"replacement, its supporting table and prior owner's nodes remain")
assert(not displays[key(failing_stall.frames[1])], "replaced frame display is gone")
assert(#drops == 0, "rollback does not drop stock or table items")

-- Revalidate the reservation before consuming a token or writing any node.
reset()
api = reset()
local reserved = layout(36)
local bad_reservation = {layout = layout(40)}
before = storage_values.market_props_token_counter or 0
failed, reason = api.setup(reserved, "villager-d", 21, {"test:apple", "test:carrot"}, bad_reservation)
assert(not failed and reason == "reservation", "stale or mismatched reservation is rejected")
assert(write_count == 0 and (storage_values.market_props_token_counter or 0) == before,
	"reservation failure has no writes or token consumption")

-- A stock-style deferred map refresh after rollback cannot leave or recreate a display.
reset()
api = reset()
partially_written = layout(42)
local stock_update = {
	remove_entity = function(pos) displays[key(pos)] = nil end,
	update_entity = function(pos)
		if fail_display_at == key(pos) then error("injected display failure") end
		local inventory = minetest.get_meta(pos):get_inventory()
		local item = inventory:get_stack("main", 1)
		if item:is_empty() then displays[key(pos)] = nil; return nil end
		local entity = {name = "mcl_itemframes:item", pos = key(pos)}
		displays[key(pos)] = entity
		-- mineclone2's map entity may queue update_entity(pos) until after(0).
		pending[#pending + 1] = function()
			local current = minetest.get_meta(pos):get_inventory():get_stack("main", 1)
			if current:is_empty() then
				-- Stock update_entity creates then removes an entity for an empty stack.
				displays[key(pos)] = {name = "mcl_itemframes:item", pos = key(pos)}
				displays[key(pos)] = nil
			else
				displays[key(pos)] = entity
			end
		end
		return entity
	end,
}
local async_site = {valid = function() return true end}
local async_api = dofile("market_props.lua").new({site = async_site, itemframes = stock_update})
fail_display_at = key(partially_written.frames[2])
failed = async_api.setup(partially_written, "villager-e", 22, {"test:map", "test:apple"},
	fixture_reservation(partially_written, "villager-e", async_site))
assert(not failed, "second display failure aborts setup with a queued map refresh")
for _, callback in ipairs(pending) do callback() end
assert_clean(partially_written, "deferred map refresh rollback")

-- If generated inventory cannot be cleared, retain the owned frame and its support.
reset()
api = reset()
local stuck = layout(48)
fail_clear_inventory = key(stuck.frames[1])
fail_display_at = key(stuck.frames[2])
failed = api.setup(stuck, "villager-f", 23, {"test:apple", "test:carrot"},
	fixture_reservation(stuck, "villager-f"))
assert(not failed, "clear failure occurs while unwinding the stock frame")
assert(world_nodes[key(stuck.frames[1])].name == frame_name, "uncleared frame remains owned")
assert(metadata[key(stuck.frames[1])].fields[frame_meta_prefix .. "token"] ~= nil,
	"uncleared frame keeps ownership metadata")
assert(world_nodes[key(stuck.tables[1])].name == table_name, "table remains beneath uncleared frame")
assert(world_nodes[key(stuck.frames[2])].name == "air" and world_nodes[key(stuck.tables[2])].name == "air",
	"independent pair still rolls back")
assert(metadata[key(stuck.frames[1])].lists.main[1]:get_name() == "test:apple",
	"generated inventory remains in the retained frame")
assert(#drops == 0, "failed inventory clear never invokes a dropping destructor")

-- Rollback retains the intended pair coordinates even when a table or first frame write fails early.
reset()
api = reset()
local second_table_failure = layout(50)
fail_add_at = 2
local second_table_result = api.setup(second_table_failure, "villager-early-a", 24,
	{"test:apple", "test:carrot"}, fixture_reservation(second_table_failure, "villager-early-a"))
assert(not second_table_result, "second table failure aborts setup")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0,
	"rollback removes both matching tables although no frames were created")
for _, pos in ipairs(second_table_failure.tables) do
	assert(not metadata[key(pos)] or metadata[key(pos)].fields[frame_meta_prefix .. "token"] == nil,
		"second-table rollback leaves no market tags")
end
assert(#drops == 0, "second-table rollback produces no drops")

reset()
api = reset()
local first_frame_failure = layout(52)
fail_add_at = 3
local first_frame_result = api.setup(first_frame_failure, "villager-early-b", 24,
	{"test:apple", "test:carrot"}, fixture_reservation(first_frame_failure, "villager-early-b"))
assert(not first_frame_result, "first frame failure aborts setup")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0,
	"rollback removes the owned first frame and both tables")
assert_clean(first_frame_failure, "first-frame rollback")
for _, list in ipairs({first_frame_failure.tables, first_frame_failure.frames}) do
	for _, pos in ipairs(list) do
		assert(not metadata[key(pos)] or metadata[key(pos)].fields[frame_meta_prefix .. "token"] == nil,
			"first-frame rollback leaves no market tags")
	end
end

-- A foreign frame at the intended second position survives early rollback without a remove attempt.
reset()
api = reset()
local foreign_layout = layout(56)
constructor_hooks[frame_name] = function(pos)
	if key(pos) ~= key(foreign_layout.frames[1]) then return end
	minetest.set_node(foreign_layout.frames[2], {name = frame_name})
	local meta = minetest.get_meta(foreign_layout.frames[2])
	meta:set_int(frame_meta_prefix .. "version", 1)
	meta:set_string(frame_meta_prefix .. "token", "foreign-token")
	meta:set_string(frame_meta_prefix .. "owner", "player")
	meta:set_int(frame_meta_prefix .. "day", 3)
	meta:set_string(frame_meta_prefix .. "role", "frame_2")
	meta:set_string(frame_meta_prefix .. "pair", key(foreign_layout.tables[2]):gsub(":", ","))
	meta:get_inventory():set_stack("main", 1, ItemStack("test:foreign", 2, {owner = "player"}))
end
local foreign_failure = api.setup(foreign_layout, "villager-early-c", 24,
	{"test:apple", "test:carrot"}, fixture_reservation(foreign_layout, "villager-early-c"))
assert(not foreign_failure, "foreign frame at a later intended position aborts setup")
assert(world_nodes[key(foreign_layout.frames[2])].name == frame_name,
	"foreign same-name frame survives early rollback")
assert(remove_calls[key(foreign_layout.frames[2])] == nil,
	"rollback never invokes the destructor on the foreign frame")
assert(metadata[key(foreign_layout.frames[2])].fields[frame_meta_prefix .. "token"] == "foreign-token"
	and metadata[key(foreign_layout.frames[2])].lists.main[1]:get_count() == 2,
	"foreign frame identity and inventory remain intact")
assert(#drops == 0, "early rollback creates no generated or foreign item drops")
assert(world_nodes[key(foreign_layout.tables[2])].name == table_name
	and metadata[key(foreign_layout.tables[2])].fields[frame_meta_prefix .. "token"] == "",
	"table beneath the foreign frame is relinquished as support")

-- A constructor-supplied same-name ownership tag is foreign and must not be overwritten.
reset()
api = reset()
local tagged_foreign = layout(54)
constructor_hooks[frame_name] = function(pos)
	local meta = minetest.get_meta(pos)
	meta:set_int(frame_meta_prefix .. "version", 1)
	meta:set_string(frame_meta_prefix .. "token", "foreign-token")
	meta:set_string(frame_meta_prefix .. "owner", "player")
	meta:set_int(frame_meta_prefix .. "day", 4)
	meta:set_string(frame_meta_prefix .. "role", "frame_1")
	meta:set_string(frame_meta_prefix .. "pair", key(tagged_foreign.tables[1]):gsub(":", ","))
end
failed = api.setup(tagged_foreign, "villager-g", 24, {"test:apple", "test:carrot"},
	fixture_reservation(tagged_foreign, "villager-g"))
assert(not failed, "foreign ownership tag aborts setup")
assert(world_nodes[key(tagged_foreign.frames[1])].name == frame_name
	and metadata[key(tagged_foreign.frames[1])].fields[frame_meta_prefix .. "token"] == "foreign-token",
	"same-name foreign node and its token survive")
assert(world_nodes[key(tagged_foreign.tables[1])].name == table_name,
	"foreign frame keeps its supporting market table")
assert(#drops == 0, "foreign frame rollback creates no drops")

-- A constructor may fill a later destination after preflight; the later write must stop.
reset()
api = reset()
local occupied_later = layout(60)
constructor_hooks[table_name] = function(pos)
	if key(pos) ~= key(occupied_later.tables[1]) then return end
	constructor_hooks[table_name] = nil
	minetest.add_node(occupied_later.frames[2], {name = frame_name})
	local meta = minetest.get_meta(occupied_later.frames[2])
	meta:set_int(frame_meta_prefix .. "version", 1)
	meta:set_string(frame_meta_prefix .. "token", "foreign-later")
end
failed = api.setup(occupied_later, "villager-h", 25, {"test:apple", "test:carrot"},
	fixture_reservation(occupied_later, "villager-h"))
assert(not failed, "later destination filled by a constructor aborts setup")
assert(world_nodes[key(occupied_later.frames[2])].name == frame_name
	and metadata[key(occupied_later.frames[2])].fields[frame_meta_prefix .. "token"] == "foreign-later",
	"later foreign destination is preserved")
assert(world_nodes[key(occupied_later.tables[2])].name == table_name,
	"table beneath later foreign destination remains in place")
assert(#drops == 0, "constructor interleaving rollback creates no drops")

-- Use actual market_site instances so reservations are checked for identity, activity and owner.
local function real_market_service(owner)
	reset()
	minetest.registered_nodes = {
		air = {walkable = false},
		["test:stone"] = {walkable = true},
	}
	minetest.get_item_group = function() return 0 end
	minetest.dir_to_wallmounted = function(dir)
		assert(dir.x == 0 and dir.y == -1 and dir.z == 0)
		return 1
	end
	minetest.is_protected = function() return false end
	minetest.get_objects_inside_radius = function() return {} end
	for x = 0, 30 do
		for z = 0, 30 do world_nodes[key({x = x, y = 0, z = z})] = {name = "test:stone"} end
	end
	local real_site = dofile("market_site.lua")
	local clock = {value = 0}
	local search = real_site.begin_search({x = 10, y = 1, z = 10}, owner, {
		random = function(_, high) return high == 35999 and 0 or 600 end,
		now = function() return clock.value end,
	})
	local state, reservation = real_site.step_search(search)
	assert(state == "found" and reservation, "real market_site reserves the supported test layout")
	local real_api = dofile("market_props.lua").new({site = real_site, itemframes = test_itemframes})
	return real_api, real_site, reservation, clock
end

local real_api, real_site, reservation, real_clock = real_market_service("seller-a")
local real_result = assert(real_api.setup(reservation.layout, "seller-a", 26,
	{"test:apple", "test:carrot"}, reservation))
assert(real_result.token, "active reservation from the shared site service succeeds")

real_api, real_site, reservation = real_market_service("seller-a")
local original_valid = real_site.valid
local validation_calls = 0
real_site.valid = function(...)
	validation_calls = validation_calls + 1
	return original_valid(...)
end
before = storage_values.market_props_token_counter or 0
failed, reason = real_api.setup(reservation.layout, "seller-a", 26, {"test:apple", "test:carrot"})
assert(not failed and reason == "reservation", "nil reservation is rejected")
assert(validation_calls == 0 and write_count == 0
	and (storage_values.market_props_token_counter or 0) == before,
	"nil reservation is rejected before site map validation, token allocation, or writes")

real_api, real_site, reservation = real_market_service("seller-a")
assert(real_site.release(reservation), "reservation is released")
before = storage_values.market_props_token_counter or 0
failed, reason = real_api.setup(reservation.layout, "seller-a", 26,
	{"test:apple", "test:carrot"}, reservation)
assert(not failed and reason == "reservation", "released real reservation is rejected")
assert(write_count == 0 and (storage_values.market_props_token_counter or 0) == before,
	"released reservation causes no world or token writes")

real_api, real_site, reservation, real_clock = real_market_service("seller-a")
real_clock.value = 11
before = storage_values.market_props_token_counter or 0
failed, reason = real_api.setup(reservation.layout, "seller-a", 26,
	{"test:apple", "test:carrot"}, reservation)
assert(not failed and reason == "reservation", "expired real reservation is rejected")
assert(write_count == 0 and (storage_values.market_props_token_counter or 0) == before,
	"expired reservation causes no world or token writes")

real_api, real_site, reservation = real_market_service("seller-a")
before = storage_values.market_props_token_counter or 0
failed, reason = real_api.setup(reservation.layout, "seller-b", 26,
	{"test:apple", "test:carrot"}, reservation)
assert(not failed and reason == "reservation", "reservation owner must match the caller")
assert(write_count == 0 and (storage_values.market_props_token_counter or 0) == before,
	"foreign owner cannot place or consume a token")

real_api, real_site, reservation = real_market_service("seller-a")
local other_site = dofile("market_site.lua")
local other_api = dofile("market_props.lua").new({site = other_site, itemframes = test_itemframes})
before = storage_values.market_props_token_counter or 0
failed, reason = other_api.setup(reservation.layout, "seller-a", 26,
	{"test:apple", "test:carrot"}, reservation)
assert(not failed and reason == "reservation", "reservation from another site instance is rejected")
assert(write_count == 0 and (storage_values.market_props_token_counter or 0) == before,
	"foreign site reservation causes no world or token writes")

-- Packing removes untouched generated stock before the stock destructor can drop it.
reset()
api = reset()
local packed_layout, packed = place_owned(api, 70, "packer")
local complete = assert(api.cleanup(packed))
assert(complete, "untouched stall cleanup completes")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0, "cleanup removes owned tables and frames")
assert_clean(packed_layout, "untouched cleanup")
assert(api.cleanup(packed), "repeated cleanup is harmless")
assert_clean(packed_layout, "repeated untouched cleanup")

-- Normal packing can remove frames first, wait at the seller, then remove tables through the same cleanup.
reset()
api = reset()
local staged_layout, staged = place_owned(api, 72, "staged-packer")
assert(api.remove_frames(staged), "frame packing phase completes")
assert(count_nodes(frame_name) == 0 and count_nodes(table_name) == 2,
	"frame phase removes frames while retaining tables for the packing pause")
assert_clean(staged_layout, "frame packing phase")
assert(api.remove_frames(staged), "repeated frame packing phase is harmless")
assert(api.cleanup(staged), "table phase reuses the shared cleanup")
assert(count_nodes(table_name) == 0, "shared cleanup removes tables after the pause")

-- A permitted right-click is marked before stock behavior swaps inventory, and returns are unchanged.
reset()
api = reset()
local touched_layout, touched = place_owned(api, 74, "clicker-owner")
local clicker = {creative = false, get_player_name = function() return "alice" end}
local wield = ItemStack("test:emerald", 2, {custom = "player-data"})
local click_results = {frame_def.on_rightclick(touched_layout.frames[1],
	minetest.get_node(touched_layout.frames[1]), clicker, wield, {type = "node"})}
assert(click_results[1] == wield and click_results[2] == "rightclick-result", "right-click callback returns are preserved")
assert(wield:get_count() == 1, "stock right-click consumes one player item")
assert(metadata[key(touched_layout.frames[1])].fields[frame_meta_prefix .. "player_touched"] == "1",
	"right-click marks player touch before upstream mutation")
assert(api.cleanup(touched), "touched frame cleanup completes")
local kept_drop
for _, dropped in ipairs(drops) do
	if dropped.stack:get_name() == "test:emerald" then kept_drop = dropped.stack end
end
assert(kept_drop and kept_drop:get_count() == 1 and kept_drop.fields.custom == "player-data",
	"remaining player stack and metadata are dropped intact")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0, "touched cleanup removes the stall")
assert(api.cleanup(touched), "second touched cleanup completes")
local emerald_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack:get_name() == "test:emerald" then emerald_drops = emerald_drops + 1 end end
assert(emerald_drops == 1, "repeated cleanup never duplicates a player drop")

-- Touch state, not item identity, preserves a player item identical to generated stock.
reset()
api = reset()
local identical_layout, identical = place_owned(api, 78, "identical-owner")
local same_item = ItemStack("test:apple", 2, {engraving = "kept"})
frame_def.on_rightclick(identical_layout.frames[1], minetest.get_node(identical_layout.frames[1]), clicker,
	same_item, {type = "node"})
assert(api.cleanup(identical), "identical stock item cleanup completes")
local identical_player_drop
for _, dropped in ipairs(drops) do
	if dropped.stack:get_name() == "test:apple" and dropped.stack.fields.engraving then identical_player_drop = dropped.stack end
end
assert(identical_player_drop and identical_player_drop:get_count() == 1
	and identical_player_drop.fields.engraving == "kept", "player-inserted stock-identical item is preserved")

-- Protected interactions are delegated for stock violation reporting without marking the frame.
reset()
api = reset()
local protected_layout, protected_stall = place_owned(api, 82, "protected-owner")
protected = true
local protected_wield = ItemStack("test:diamond")
local protected_click = frame_def.on_rightclick(protected_layout.frames[1],
	minetest.get_node(protected_layout.frames[1]), clicker, protected_wield, {type = "node"})
local protected_rotate = frame_def.on_rotate(protected_layout.frames[2],
	minetest.get_node(protected_layout.frames[2]), clicker)
assert(protected_click == protected_wield and protected_rotate == "protected-rotate", "protected callback returns are preserved")
assert(#violations == 2, "upstream reports both protected interactions")
assert(metadata[key(protected_layout.frames[1])].fields[frame_meta_prefix .. "player_touched"] ~= "1"
	and metadata[key(protected_layout.frames[2])].fields[frame_meta_prefix .. "player_touched"] ~= "1",
	"protected interactions do not mark generated inventory touched")
assert(api.cleanup(protected_stall), "protected stall cleanup completes")
assert_clean(protected_layout, "protected cleanup")

-- The rotate wrapper preserves all return slots and lets stock behavior drop the displayed item.
reset()
api = reset()
local rotate_layout, rotate_stall = place_owned(api, 86, "rotator")
local rotate_result = {n = 0}
rotate_result.n = select("#", frame_def.on_rotate(rotate_layout.frames[1],
	minetest.get_node(rotate_layout.frames[1]), clicker))
rotate_result[1], rotate_result[2], rotate_result[3] = frame_def.on_rotate(rotate_layout.frames[1],
	minetest.get_node(rotate_layout.frames[1]), clicker)
assert(rotate_result.n == 3 and rotate_result[1] == "rotate-result" and rotate_result[2] == nil
	and rotate_result[3] == "tail", "rotate return values including trailing nil are preserved")
assert(metadata[key(rotate_layout.frames[1])].fields[frame_meta_prefix .. "player_touched"] == "1",
	"permitted rotation marks the inventory before stock mutation")
assert(api.cleanup(rotate_stall), "rotated stall cleanup completes")
assert(count_nodes(table_name) == 0 and count_nodes(frame_name) == 0, "rotated cleanup removes the stall")
for _, pos in ipairs(rotate_layout.frames) do assert(not displays[key(pos)], "rotated cleanup removes frame displays") end
local rotated_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack:get_name() == "test:apple" then rotated_drops = rotated_drops + 1 end end
assert(rotated_drops == 1, "rotation's normal stock drop is not duplicated by cleanup")

-- If a player-item drop cannot be created, retain the stack and its owned frame for retry.
reset()
api = reset()
local retained_layout, retained = place_owned(api, 90, "retained-owner")
frame_def.on_rightclick(retained_layout.frames[1], minetest.get_node(retained_layout.frames[1]), clicker,
	ItemStack("test:emerald", 1, {serial = "safe"}), {type = "node"})
fail_drop = true
complete = api.cleanup(retained)
assert(not complete, "failed item drop defers cleanup")
assert(world_nodes[key(retained_layout.frames[1])].name == frame_name, "failed drop keeps the frame")
assert(metadata[key(retained_layout.frames[1])].lists.main[1]:get_name() == "test:emerald"
	and metadata[key(retained_layout.frames[1])].lists.main[1]:get_count() == 1
	and metadata[key(retained_layout.frames[1])].lists.main[1].fields.serial == "safe", "failed drop restores the complete inventory stack")
local failed_attempt_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack.fields.serial == "safe" then failed_attempt_drops = failed_attempt_drops + 1 end end
assert(failed_attempt_drops == 0, "failed add_item creates no partial player drop")
assert(world_nodes[key(retained_layout.tables[1])].name == table_name, "failed frame cleanup retains table support")
fail_drop = false
assert(api.cleanup(retained), "cleanup retries successfully after item drop becomes available")
local safe_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack.fields.serial == "safe" then safe_drops = safe_drops + 1 end end
assert(safe_drops == 1, "successful retry drops retained player item once")
assert(api.cleanup(retained), "retried cleanup is idempotent")
assert(safe_drops == 1, "retry cleanup does not duplicate drops")

-- Once a player stack has been dropped, a later clear failure retains the frame and retries without duplication.
reset()
api = reset()
local clear_retry_layout, clear_retry = place_owned(api, 92, "clear-retry")
frame_def.on_rightclick(clear_retry_layout.frames[1], minetest.get_node(clear_retry_layout.frames[1]), clicker,
	ItemStack("test:emerald", 1, {serial = "clear-retry"}), {type = "node"})
fail_clear_inventory = key(clear_retry_layout.frames[1])
complete = api.cleanup(clear_retry)
assert(not complete and world_nodes[key(clear_retry_layout.frames[1])].name == frame_name,
	"inventory clear failure retains the owned frame")
local retry_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack.fields.serial == "clear-retry" then retry_drops = retry_drops + 1 end end
assert(retry_drops == 0, "clear failure happens before any player drop")
local post_failure_wield = ItemStack("test:emerald", 1, {serial = "after-clear-failure"})
frame_def.on_rightclick(clear_retry_layout.frames[1], minetest.get_node(clear_retry_layout.frames[1]), clicker,
	post_failure_wield, {type = "node"})
local old_stack_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack:get_name() == "test:apple" then old_stack_drops = old_stack_drops + 1 end end
assert(old_stack_drops == 1, "next interaction clears an already-dropped stack before stock behavior")
assert(api.cleanup(clear_retry), "cleanup retries after the inventory becomes writable")
for _, dropped in ipairs(drops) do if dropped.stack.fields.serial == "clear-retry" then retry_drops = retry_drops + 1 end end
assert(retry_drops == 1, "stock interaction drops the original stack once before retry")
local after_failure_drops = 0
for _, dropped in ipairs(drops) do if dropped.stack.fields.serial == "after-clear-failure" then after_failure_drops = after_failure_drops + 1 end end
assert(after_failure_drops == 1, "the new player stack inserted after retryable cleanup is preserved")

-- If clear fails, an ordinary frame dig lets the real destructor drop the stack exactly once.
reset()
api = reset()
local dig_layout, dig_stall = place_owned(api, 93, "dig-after-clear-failure")
frame_def.on_rightclick(dig_layout.frames[1], minetest.get_node(dig_layout.frames[1]), clicker,
	ItemStack("test:emerald", 1, {serial = "dug-once"}), {type = "node"})
fail_clear_inventory = key(dig_layout.frames[1])
complete = api.cleanup(dig_stall)
assert(not complete, "failed clear retains the item for ordinary digging")
local dug_before = #drops
minetest.set_node(dig_layout.frames[1], {name = "air"})
assert(#drops == dug_before + 1 and drops[#drops].stack.fields.serial == "dug-once",
	"stock destructor drops the retained player stack once")
assert(api.cleanup(dig_stall), "cleanup removes the remaining table after the frame is dug")
local dug_once_count = 0
for _, dropped in ipairs(drops) do if dropped.stack.fields.serial == "dug-once" then dug_once_count = dug_once_count + 1 end end
assert(dug_once_count == 1, "cleanup after ordinary digging creates no duplicate")
assert(api.cleanup(dig_stall) and dug_once_count == 1, "repeated cleanup after digging remains idempotent")

-- Replaced frame nodes are unowned and left in place; their owned table is relinquished as support.
reset()
api = reset()
local replacement_layout, replacement_stall = place_owned(api, 94, "replacement-owner")
minetest.set_node(replacement_layout.frames[1], {name = frame_name})
local replacement_meta = minetest.get_meta(replacement_layout.frames[1])
replacement_meta:get_inventory():set_stack("main", 1, ItemStack("test:book", 3, {note = "player"}))
replacement_meta:set_string("test:keep", "metadata")
local replacement_wield = ItemStack("test:gold_ingot")
local replacement_return, replacement_extra = frame_def.on_rightclick(replacement_layout.frames[1],
	minetest.get_node(replacement_layout.frames[1]), clicker, replacement_wield, {type = "node"})
assert(replacement_return == replacement_wield and replacement_extra == "rightclick-result",
	"untagged replacement keeps the stock callback and return behavior")
assert(replacement_meta:get_string(frame_meta_prefix .. "player_touched") == "",
	"untagged replacement is not marked as a market inventory")
assert(api.cleanup(replacement_stall), "replacement support cleanup completes")
assert(world_nodes[key(replacement_layout.frames[1])].name == frame_name, "untagged same-name replacement survives")
assert(metadata[key(replacement_layout.frames[1])].lists.main[1]:get_name() == "test:gold_ingot"
	and metadata[key(replacement_layout.frames[1])].fields["test:keep"] == "metadata", "replacement inventory and metadata survive")
assert(world_nodes[key(replacement_layout.tables[1])].name == table_name, "replacement's table support survives")
assert(metadata[key(replacement_layout.tables[1])].fields[frame_meta_prefix .. "token"] == "",
	"support table loses only market ownership tags")
assert(metadata[key(replacement_layout.tables[1])].fields["test:keep"] == nil, "market cleanup leaves no unrelated table fields")

-- An unloaded support cell defers cleanup without forcing it; a later pass removes the stall.
reset()
api = reset()
local unloaded_layout, unloaded_stall = place_owned(api, 98, "unloaded-owner")
unloaded[key(unloaded_layout.frames[1])] = true
complete = api.cleanup(unloaded_stall)
assert(not complete and world_nodes[key(unloaded_layout.tables[1])].name == table_name,
	"unloaded frame defers table removal")
assert(metadata[key(unloaded_layout.tables[1])].fields[frame_meta_prefix .. "token"] ~= "",
	"deferred support table remains tagged for retry")
unloaded[key(unloaded_layout.frames[1])] = nil
assert(api.cleanup(unloaded_stall), "cleanup completes after the frame block loads")
assert(world_nodes[key(unloaded_layout.tables[1])].name == "air", "deferred owned table is eventually removed")

-- A missing frame does not block cleanup of its still-owned table or paired member.
reset()
api = reset()
local missing_layout, missing_stall = place_owned(api, 100, "missing-owner")
world_nodes[key(missing_layout.frames[1])] = {name = "air"}
metadata[key(missing_layout.frames[1])] = nil
displays[key(missing_layout.frames[1])] = nil
assert(api.cleanup(missing_stall), "missing frame member is treated as already removed")
assert(world_nodes[key(missing_layout.tables[1])].name == "air"
	and world_nodes[key(missing_layout.tables[2])].name == "air", "remaining owned table members are removed")

-- Removing an owned table clears only market tags if a non-frame player node is above it.
reset()
api = reset()
local support_layout, support_stall = place_owned(api, 102, "support-owner")
minetest.set_node(support_layout.frames[2], {name = "test:player_node"})
local support_meta = minetest.get_meta(support_layout.tables[2])
support_meta:set_string("player:note", "retain")
assert(api.cleanup(support_stall), "player node support cleanup completes")
assert(world_nodes[key(support_layout.frames[2])].name == "test:player_node"
	and world_nodes[key(support_layout.tables[2])].name == table_name, "player node and its support survive")
assert(support_meta:get_string("player:note") == "retain", "relinquishing does not clear unrelated metadata")
assert(support_meta:get_string(frame_meta_prefix .. "token") == "", "relinquished table has no ownership token")

-- The module registers one always-run LBM and one non-catching five-second ABM.
reset()
api = reset()
assert(#registered_lbms == 1 and #registered_abms == 1, "one orphan LBM and ABM are registered")
local lbm, abm = registered_lbms[1], registered_abms[1]
assert(lbm.name == "living_villages:market_orphan_props" and lbm.run_at_every_load == true,
	"LBM is namespaced and runs at every block load")
assert(abm.label == "living_villages:market_orphan_props" and abm.interval == 5
	and abm.chance == 1 and abm.catch_up == false, "ABM runs every five seconds without catch-up")
assert(#lbm.nodenames == 2 and lbm.nodenames[1] == table_name and lbm.nodenames[2] == frame_name
	and #abm.nodenames == 2 and abm.nodenames[1] == table_name and abm.nodenames[2] == frame_name,
	"callbacks target exactly stock tables and invisible frames")
local fresh_module = dofile("market_props.lua")
fresh_module.new({site = test_site, itemframes = test_itemframes, core = minetest})
assert(#registered_lbms == 1 and #registered_abms == 1, "repeated API construction does not duplicate callbacks")

local function callback_action(kind)
	return kind == "lbm" and registered_lbms[1].action or registered_abms[1].action
end

local function run_due_timers()
	local index = 1
	while index <= #timers do
		if timers[index].at <= clock_value then
			local timer = table.remove(timers, index)
			timer.callback()
		else
			index = index + 1
		end
	end
end

local function invoke_pair(kind, layout_value, reverse)
	local positions = {}
	for _, pos in ipairs(layout_value.tables) do positions[#positions + 1] = pos end
	for _, pos in ipairs(layout_value.frames) do positions[#positions + 1] = pos end
	if reverse then
		local reversed = {}
		for index = #positions, 1, -1 do reversed[#reversed + 1] = positions[index] end
		positions = reversed
	end
	for _, pos in ipairs(positions) do callback_action(kind)(pos, minetest.get_node_or_nil(pos)) end
end

local function activate_runtime(api_value, stall, session)
	local owner_ref = {session = session}
	assert(api_value.activate(stall, owner_ref, session, clock_value + 40,
		{bell_pos = {x = -10, y = 0, z = 0}}), "runtime session activates")
	return owner_ref
end

-- Active props survive both callbacks; every API handle shares the same record.
reset()
api = reset({validate_session = function() return true end})
local active_layout, active_stall = place_owned(api, 110, "active-owner")
local session_ref = activate_runtime(api, active_stall, "active-session")
assert(api.renew(active_stall.token, session_ref, "active-session"),
	"a market seller can renew during the holiday bell stage")
timeofday_value = 0.624
assert(api.renew(active_stall.token, session_ref, "active-session"),
	"a market seller remains valid up to the 15:00 handoff")
timeofday_value = 0.5
local later_valid = true
local shared_api = dofile("market_props.lua").new({site = test_site, itemframes = test_itemframes,
	core = minetest, validate_session = function() return later_valid end})
assert(shared_api.activate(active_stall, session_ref, "active-session", clock_value + 40),
	"later API handle registers the active session")
invoke_pair("lbm", active_layout)
invoke_pair("abm", active_layout, true)
assert(count_nodes(frame_name) == 2 and count_nodes(table_name) == 2,
	"registered callbacks use the later handle's validator for its record")
later_valid = false
invoke_pair("lbm", active_layout)
assert(count_nodes(frame_name) == 0 and count_nodes(table_name) == 0,
	"later handle's invalid session is cleaned by the registered callback")
local reactivated_layout, reactivated = place_owned(shared_api, 114, "second-owner")
local second_ref = activate_runtime(shared_api, reactivated, "second-session")
assert(not shared_api.release(active_stall.token, session_ref, "active-session"),
	"invalid callback already removed the prior runtime token")
assert(shared_api.release(reactivated.token, second_ref, "second-session"), "later handle releases its own token")
invoke_pair("abm", reactivated_layout)
assert_clean(reactivated_layout, "orphan cleanup")

-- A stall crossing the x=16 mapblock edge survives either block activation order.
for _, reverse_blocks in ipairs({false, true}) do
	reset()
	api = reset()
	local split_layout, split_stall = place_owned(api, 15, "split-owner")
	activate_runtime(api, split_stall, "split-session")
	local first, second = reverse_blocks and 2 or 1, reverse_blocks and 1 or 2
	local function block_positions(index)
		return {split_layout.tables[index], split_layout.frames[index]}
	end
	for _, pos in ipairs(block_positions(second)) do unloaded[key(pos)] = true end
	for _, pos in ipairs(block_positions(first)) do callback_action("lbm")(pos, minetest.get_node_or_nil(pos)) end
	assert(count_nodes(frame_name) == 2 and count_nodes(table_name) == 2,
		"loaded half of active split stall survives")
	for _, pos in ipairs(block_positions(second)) do unloaded[key(pos)] = nil end
	for _, pos in ipairs(block_positions(second)) do callback_action("lbm")(pos, minetest.get_node_or_nil(pos)) end
	assert(count_nodes(frame_name) == 2 and count_nodes(table_name) == 2,
		"both split blocks survive in either activation order")
	assert(api.release(split_stall.token), "split stall can be invalidated")
	for _, pos in ipairs(block_positions(second)) do callback_action("abm")(pos, minetest.get_node_or_nil(pos)) end
	for _, pos in ipairs(block_positions(first)) do callback_action("abm")(pos, minetest.get_node_or_nil(pos)) end
	assert(count_nodes(frame_name) == 0 and count_nodes(table_name) == 0,
		"orphan cleanup completes across both mapblocks")
	assert_clean(split_layout, "split block cleanup")
end

-- An unloaded bell is unknown through the injected session validator, not removal.
reset()
local bell_loaded = false
api = reset({validate_session = function(record)
	assert(record.context.bell_pos.x == -10, "controller context reaches session validation")
	if not bell_loaded then return nil, "bell_unloaded" end
	return true
end})
local bell_layout, bell_stall = place_owned(api, 112, "bell-owner")
local bell_ref = activate_runtime(api, bell_stall, "bell-session")
clock_value = 105
assert(api.renew(bell_stall.token, bell_ref, "bell-session"),
	"unknown bell renews rather than invalidating the live session")
invoke_pair("lbm", bell_layout)
assert(count_nodes(table_name) == 2 and count_nodes(frame_name) == 2,
	"unloaded bell keeps active props during a registered load check")
bell_loaded = true
invoke_pair("abm", bell_layout)
assert(count_nodes(table_name) == 2 and count_nodes(frame_name) == 2,
	"reloaded bell validates the live stall during the ABM check")
clock_value = 110
run_due_timers()
assert(api.renew(bell_stall.token, bell_ref, "bell-session"), "reloaded session remains renewable")
clock_value = 121
run_due_timers()
invoke_pair("abm", bell_layout)
assert_clean(bell_layout, "genuine lease expiry after bell reload")

-- A restart starts with an empty registry and never reconstructs persisted stalls.
reset()
api = reset()
local restart_layout, restart_stall = place_owned(api, 116, "restart-owner")
activate_runtime(api, restart_stall, "restart-session")
registered_lbms, registered_abms = {}, {}
minetest._living_villages_market_props_runtime = nil
local restarted = dofile("market_props.lua").new({site = test_site, itemframes = test_itemframes,
	core = minetest, validate_session = function() return true end})
assert(#registered_lbms == 1 and #registered_abms == 1, "new runtime registers fresh callbacks")
invoke_pair("lbm", restart_layout)
assert(count_nodes(frame_name) == 0 and count_nodes(table_name) == 0,
	"fresh registry cleans old tagged props")
assert_clean(restart_layout, "restart cleanup")

-- The market seller window is the holiday bell stage (10:30 to 15:00), not
-- the tavern's later hours. Calendar, weather, deadline, lease and owner/session
-- changes invalidate even a live owner.
local invalidations = {
	{name = "stale day", change = function() day_value = day_value + 1 end},
	{name = "ordinary day", change = function() day_value = 5 end},
	{name = "thunder", change = function() thunder_value = true end},
	{name = "market window ended", change = function() timeofday_value = 0.625 end},
	{name = "deadline time jump", change = function() clock_value = 142 end},
	{name = "backward clock jump", change = function() clock_value = 99 end},
	{name = "missing owner session", change = function() owner_valid = false end},
	{name = "lease expiry", change = function() clock_value = 111 end},
}
for index, invalidation in ipairs(invalidations) do
	reset()
	api = reset()
	local doomed_layout, doomed = place_owned(api, 120 + index * 5, "owner-" .. index)
	activate_runtime(api, doomed, "session-" .. index)
	invalidation.change()
	invoke_pair("abm", doomed_layout)
	assert(count_nodes(frame_name) == 0 and count_nodes(table_name) == 0,
		invalidation.name .. " invalidates the runtime token")
	assert_clean(doomed_layout, invalidation.name)
end

reset()
api = reset({validate_session = function() return nil, "bell_unloaded" end})
local unknown_base_layout, unknown_base_stall = place_owned(api, 162, "unknown-base-owner")
local unknown_base_ref = {session = "unknown-base-session"}
assert(api.activate(unknown_base_stall, unknown_base_ref, "unknown-base-session", clock_value + 40,
	{validate_session = function() return false end}),
	"runtime records accept an independent session validator")
invoke_pair("lbm", unknown_base_layout)
assert_clean(unknown_base_layout, "a known invalid context overrides an unknown base validator")

reset()
api = reset()
local renewed_layout, renewed = place_owned(api, 165, "renewed-owner")
local renewed_ref = activate_runtime(api, renewed, "renewed-session")
clock_value = 109
assert(api.renew(renewed.token, renewed_ref, "renewed-session"), "live owner renews its lease before expiry")
clock_value = 118
assert(api.check_prop(renewed_layout.tables[1]) == true, "renewed lease keeps the stall alive")
clock_value = 120
assert(api.check_prop(renewed_layout.tables[1]) == false, "renewed lease expires after its ten-second window")
invoke_pair("abm", renewed_layout)
assert_clean(renewed_layout, "renewed lease expiry")

reset()
api = reset()
local slow_layout, slow_stall = place_owned(api, 167, "slow-owner")
local slow_ref = activate_runtime(api, slow_stall, "slow-session")
clock_value = 109
assert(api.renew(slow_stall.token, slow_ref, "slow-session", 1000),
	"renewal moves the real-time fallback deadline forward with a slow game clock")
clock_value = 118
assert(api.renew(slow_stall.token, slow_ref, "slow-session", 1000),
	"regular renewal keeps the lease live while the game clock is slow")
clock_value = 127
assert(api.check_prop(slow_layout.tables[1]) == true,
	"the original hard deadline cannot expire a regularly renewed seller")
timeofday_value = 0.625
assert(api.check_prop(slow_layout.tables[1]) == false,
	"the game-time market handoff still invalidates a renewed real-time deadline")

-- Packing the frames retains the live record; final cleanup invalidates it before deferring.
reset()
api = reset()
local final_layout, final_stall = place_owned(api, 166, "final-owner")
local final_ref = activate_runtime(api, final_stall, "final-session")
assert(api.remove_frames(final_stall), "staggered packing clears frames first")
assert(api.check_prop(final_layout.tables[1]) == true, "frame phase retains a valid table lease")
unloaded[key(final_layout.frames[1])] = true
assert(not api.cleanup(final_stall), "final cleanup defers on an unloaded frame support")
assert(not api.renew(final_stall.token, final_ref, "final-session"),
	"final cleanup invalidates the matching lease before node cleanup")
unloaded[key(final_layout.frames[1])] = nil
invoke_pair("lbm", final_layout)
assert_clean(final_layout, "deferred final cleanup")

-- Lease expiry prunes a token even when every tagged prop has already disappeared.
reset()
api = reset()
local vanished_layout, vanished = place_owned(api, 167, "vanished-owner")
local vanished_ref = activate_runtime(api, vanished, "vanished-session")
for _, pos in ipairs(vanished_layout.tables) do world_nodes[key(pos)] = {name = "air"}; metadata[key(pos)] = nil end
for _, pos in ipairs(vanished_layout.frames) do
	world_nodes[key(pos)] = {name = "air"}
	metadata[key(pos)], displays[key(pos)] = nil, nil
end
clock_value = 111
run_due_timers()
assert(not api.renew(vanished.token, vanished_ref, "vanished-session"),
	"bounded lease expiry removes a record with no remaining props or callbacks")

-- A surviving frame or table is cleaned alone. Unknown paired support defers safely.
for _, survivor in ipairs({"frame", "table"}) do
	for _, reverse in ipairs({false, true}) do
		reset()
		api = reset()
		local lone_layout, lone = place_owned(api, survivor == "frame" and 170 or 180, "lone-" .. survivor)
		api.release(lone.token)
		local lost = survivor == "frame" and lone_layout.tables[1] or lone_layout.frames[1]
		world_nodes[key(lost)] = {name = "air"}
		metadata[key(lost)], displays[key(lost)] = nil, nil
		local kept = survivor == "frame" and lone_layout.frames[1] or lone_layout.tables[1]
		callback_action(reverse and "abm" or "lbm")(kept, minetest.get_node_or_nil(kept))
		assert(world_nodes[key(kept)].name == "air", "lone " .. survivor .. " is cleaned")
		assert(#drops == 0, "lone cleanup creates no drops")
	end
end

reset()
api = reset()
local deferred_layout, deferred_stall = place_owned(api, 190, "deferred-owner")
api.release(deferred_stall.token)
unloaded[key(deferred_layout.frames[1])] = true
local deferred = api.check_prop(deferred_layout.tables[1])
assert(deferred == nil and world_nodes[key(deferred_layout.tables[1])].name == table_name,
	"unknown paired frame defers table removal without force-loading")
assert(metadata[key(deferred_layout.tables[1])].fields[frame_meta_prefix .. "token"] ~= "",
	"deferred support stays tagged for a later retry")
unloaded[key(deferred_layout.frames[1])] = nil
invoke_pair("lbm", deferred_layout, true)
assert(count_nodes(frame_name) == 0 and count_nodes(table_name) == 0,
	"deferred cleanup finishes once both blocks are available")

-- Untagged market furniture exits before owner validation or destructive work.
reset()
local owner_checks = 0
api = reset({validate_session = function() owner_checks = owner_checks + 1; return false end})
world_nodes["200:0:0"] = {name = table_name}
world_nodes["201:0:0"] = {name = frame_name}
callback_action("lbm")({x = 200, y = 0, z = 0})
callback_action("abm")({x = 201, y = 0, z = 0})
assert(world_nodes["200:0:0"].name == table_name and world_nodes["201:0:0"].name == frame_name
	and owner_checks == 0, "untagged furniture survives without owner validation")

print("market props setup, packing and rollback tests passed")
