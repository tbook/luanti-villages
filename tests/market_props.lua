-- Setup and rollback tests use the stock frame callback behavior from mineclone2.
local function key(pos)
	return pos.x .. ":" .. pos.y .. ":" .. pos.z
end

local world_nodes, metadata, displays, drops
local construct_count, write_count, pending
local fail_add_at, fail_inventory, fail_clear_inventory, fail_display_at, replace_first_frame
local storage_values
local constructor_hooks, test_itemframes, test_site
local frame_name = "mcl_itemframes:invisible_frame"
local table_name = "mcl_decor:table_wooden"

local function stack(name, count)
	local value = {name = name or "", count = count or (name and name ~= "" and 1 or 0)}
	function value:is_empty() return self.name == "" or self.count == 0 end
	function value:get_name() return self.name end
	function value:get_count() return self.count end
	return value
end

ItemStack = function(name) return stack(name) end

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

local function reset()
	world_nodes, metadata, displays, drops = {}, {}, {}, {}
	construct_count, write_count, pending = 0, 0, {}
	fail_add_at, fail_inventory, fail_clear_inventory, fail_display_at, replace_first_frame = nil, false, nil, nil, nil
	constructor_hooks = {}
	storage_values = storage_values or {}
	minetest = {
		get_modpath = function() return "." end,
		get_mod_storage = function()
			return {
				get_int = function(_, name) return storage_values[name] or 0 end,
				set_int = function(_, name, value) storage_values[name] = value end,
			}
		end,
		get_node_or_nil = function(pos)
			local node = world_nodes[key(pos)]
			return node and {name = node.name, param2 = node.param2} or {name = "air", param2 = 0}
		end,
		get_node = function(pos) return minetest.get_node_or_nil(pos) end,
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
				data.lists[name][index] = item
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
			local old = world_nodes[key(pos)]
			local def = old and old.name == frame_name and frame_def or {}
			if def.on_destruct then def.on_destruct(pos) end
			world_nodes[key(pos)] = {name = "air", param2 = 0}
			metadata[key(pos)] = nil
		end,
	}
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
	return dofile("market_props.lua").new({site = site, itemframes = itemframes})
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
reset()
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

print("market props setup and rollback tests passed")
