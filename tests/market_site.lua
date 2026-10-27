local root = debug.getinfo(1, "S").source:sub(2):match("(.*/)tests/") or "./"
local world, groups, unloaded, nearby_objects, last_query_radius
local forbidden_calls = {writes = 0, emerges = 0, paths = 0}

local function key(p)
	return p.x .. ":" .. p.y .. ":" .. p.z
end

local air = {walkable = false}
local stone = {walkable = true}
local grass_path = {
	walkable = true,
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0.4375, 0.5}},
}
local slab = {
	walkable = true,
	drawtype = "nodebox",
	node_box = {type = "fixed", fixed = {-0.5, -0.5, -0.5, 0.5, 0, 0.5}},
}

minetest = {
	registered_nodes = {
		air = air,
		["test:stone"] = stone,
		["test:slab"] = slab,
		["mcl_core:grass_path"] = grass_path,
	},
	get_modpath = function() return root end,
	get_node_or_nil = function(p)
		if unloaded and key(p) == unloaded then return nil end
		local name = world[key(p)] or "air"
		return {name = name}
	end,
	get_item_group = function(name, group)
		if name == "test:slab" and group == "slab" then return 1 end
		return ((groups[name] or {})[group]) or 0
	end,
	dir_to_wallmounted = function(dir)
		assert(dir.x == 0 and dir.y == -1 and dir.z == 0, "frames mount against the tabletop")
		return 1
	end,
	is_protected = function() return false end,
	set_node = function() forbidden_calls.writes = forbidden_calls.writes + 1 end,
	emerge_area = function() forbidden_calls.emerges = forbidden_calls.emerges + 1 end,
	find_path = function() forbidden_calls.paths = forbidden_calls.paths + 1 end,
	get_objects_inside_radius = function(center, radius)
		last_query_radius = radius
		local result = {}
		for _, object in ipairs(nearby_objects) do
			local object_pos = object:get_pos()
			local dx, dy, dz = object_pos.x - center.x, object_pos.y - center.y, object_pos.z - center.z
			if dx * dx + dy * dy + dz * dz <= radius * radius then
				result[#result + 1] = object
			end
		end
		return result
	end,
}

local function reset()
	world, groups, unloaded, nearby_objects, last_query_radius = {}, {}, nil, {}, nil
	for x = -5, 25 do
		for z = -5, 25 do world[key({x = x, y = 0, z = z})] = "test:stone" end
	end
end

local site = dofile(root .. "market_site.lua")
local first = {x = 10, y = 1, z = 10}
local cases = {
	{
		out = {x = 1, z = 0}, right = {x = 0, z = 1}, bell = {x = 0, z = 11},
		second = {x = 10, z = 11}, seller = {x = 9, z = 10},
		expected_clearance = {
			"8:1:9", "9:1:9", "10:1:9", "11:1:9", "8:1:10", "9:1:10", "10:1:10", "11:1:10",
			"8:1:11", "9:1:11", "10:1:11", "11:1:11", "8:1:12", "9:1:12", "10:1:12", "11:1:12",
		},
	},
	{
		out = {x = -1, z = 0}, right = {x = 0, z = -1}, bell = {x = 20, z = 11},
		second = {x = 10, z = 9}, seller = {x = 11, z = 10},
		expected_clearance = {
			"12:1:11", "11:1:11", "10:1:11", "9:1:11", "12:1:10", "11:1:10", "10:1:10", "9:1:10",
			"12:1:9", "11:1:9", "10:1:9", "9:1:9", "12:1:8", "11:1:8", "10:1:8", "9:1:8",
		},
	},
	{
		out = {x = 0, z = 1}, right = {x = -1, z = 0}, bell = {x = 10, z = 0},
		second = {x = 9, z = 10}, seller = {x = 10, z = 9},
		expected_clearance = {
			"11:1:8", "11:1:9", "11:1:10", "11:1:11", "10:1:8", "10:1:9", "10:1:10", "10:1:11",
			"9:1:8", "9:1:9", "9:1:10", "9:1:11", "8:1:8", "8:1:9", "8:1:10", "8:1:11",
		},
	},
	{
		out = {x = 0, z = -1}, right = {x = 1, z = 0}, bell = {x = 10, z = 20},
		second = {x = 11, z = 10}, seller = {x = 10, z = 11},
		expected_clearance = {
			"9:1:12", "9:1:11", "9:1:10", "9:1:9", "10:1:12", "10:1:11", "10:1:10", "10:1:9",
			"11:1:12", "11:1:11", "11:1:10", "11:1:9", "12:1:12", "12:1:11", "12:1:10", "12:1:9",
		},
	},
}

local function assert_pos(actual, x, y, z, message)
	assert(actual.x == x and actual.y == y and actual.z == z,
		(message or "position") .. ": " .. actual.x .. "," .. actual.y .. "," .. actual.z)
end

local function install_air_destinations(layout)
	for _, p in ipairs(layout.tables) do world[key(p)] = "air" end
	for _, p in ipairs(layout.frames) do world[key(p)] = "air" end
end

local function layout_for(case)
	return site.describe({x = case.bell.x, y = 1, z = case.bell.z}, first)
end

local function expect_invalid(layout, options, reason)
	local valid, got = site.valid(layout, options)
	assert(not valid and got == reason, "expected " .. reason .. ", got " .. tostring(got))
end

for _, case in ipairs(cases) do
	reset()
	local layout = layout_for(case)
	assert(layout, "layout found for cardinal direction")
	assert_pos(layout.tables[1], 10, 1, 10, "first table")
	assert_pos(layout.tables[2], case.second.x, 1, case.second.z, "second table")
	assert_pos(layout.frames[1], 10, 2, 10, "first frame")
	assert_pos(layout.frames[2], case.second.x, 2, case.second.z, "second frame")
	assert(layout.frame_param2 == 1, "frame is floor-mounted")
	assert_pos(layout.seller, case.seller.x, 1, case.seller.z, "seller")
	assert(layout.outward.x == case.out.x and layout.outward.z == case.out.z, "outward direction")
	assert(layout.right.x == case.right.x and layout.right.z == case.right.z, "right-hand direction")
	assert(#layout.clearance == 16 and #layout.exclusive == 3, "clearance and exclusives have exact sizes")
	local actual = {}
	for _, p in ipairs(layout.clearance) do actual[#actual + 1] = key(p) end
	table.sort(actual)
	table.sort(case.expected_clearance)
	assert(table.concat(case.expected_clearance, ",") == table.concat(actual, ","), "exact 4x4 clearance coordinate set")
	local function has_clearance(p)
		for _, cell in ipairs(layout.clearance) do if key(cell) == key(p) then return true end end
		return false
	end
	assert(has_clearance({x = 10 + case.out.x, y = 1, z = 10 + case.out.z}), "front edge is one outward cell")
	assert(has_clearance({x = 10 - 2 * case.out.x, y = 1, z = 10 - 2 * case.out.z}), "rear edge is two cells behind")
	install_air_destinations(layout)
	local valid, reason = site.valid(layout)
	assert(valid, "flat supported site valid: " .. tostring(reason))
end

-- X wins a diagonal tie using the completed pair midpoint.
reset()
local tied = site.describe({x = 7.5, y = 1, z = 8}, {x = 10, y = 1, z = 10})
assert(tied and tied.outward.x == 1 and tied.outward.z == 0, "diagonal tie favors X")

local layout
for _, obstruction in ipairs({"test:grass", "mcl_wool:carpet", "mcl_itemframes:invisible_frame", "mcl_decor:table_oak"}) do
	reset()
	layout = layout_for(cases[1])
	install_air_destinations(layout)
	world[key(layout.tables[1])] = obstruction
	expect_invalid(layout, nil, "destination_not_air")
end

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
world[key(layout.frames[2])] = "mcl_decor:path_cobble"
expect_invalid(layout, nil, "destination_not_air")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
expect_invalid(layout, {is_protected = function(p) return key(p) == key(layout.frames[1]) end}, "protected")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
expect_invalid(layout, {is_occupied = function(p) return key(p) == key(layout.tables[2]) end}, "occupied")
assert(last_query_radius == nil, "injected occupancy reader bypasses engine query")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
nearby_objects = {{
	is_player = function() return true end,
	get_pos = function() return {x = layout.tables[1].x, y = 0.51, z = layout.tables[1].z} end,
	get_properties = function() return {collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}} end,
}}
expect_invalid(layout, nil, "occupied")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
nearby_objects = {{
	is_player = function() return false end,
	get_luaentity = function() return {name = "mobs_mc:villager"} end,
	get_pos = function()
		return {x = layout.tables[1].x + 0.75, y = layout.tables[1].y - 0.49, z = layout.tables[1].z + 0.75}
	end,
	get_properties = function() return {collisionbox = {-0.3, -0.01, -0.3, 0.3, 1.94, 0.3}} end,
}}
expect_invalid(layout, nil, "occupied")
assert(last_query_radius > math.sqrt(0.75 ^ 2 + 0.49 ^ 2 + 0.75 ^ 2),
	"radius query includes diagonal villager whose box overlaps the table")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
world[key({x = layout.clearance[1].x, y = 0, z = layout.clearance[1].z})] = "air"
expect_invalid(layout, nil, "unsafe_floor")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
world[key({x = layout.clearance[1].x, y = 0, z = layout.clearance[1].z})] = "test:stone"
world[key({x = layout.clearance[1].x, y = 1, z = layout.clearance[1].z})] = "test:stone"
expect_invalid(layout, nil, "blocked_body")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
world[key({x = layout.clearance[1].x, y = 2, z = layout.clearance[1].z})] = "test:stone"
expect_invalid(layout, nil, "blocked_body")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
world[key({x = layout.clearance[1].x, y = 0, z = layout.clearance[1].z})] = "mcl_core:grass_path"
local path_valid, path_reason = site.valid(layout)
assert(path_valid, "grass path support is valid: " .. tostring(path_reason))
world[key({x = layout.clearance[1].x, y = 0, z = layout.clearance[1].z})] = "test:slab"
expect_invalid(layout, nil, "uneven_floor")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
unloaded = key(layout.frames[1])
expect_invalid(layout, nil, "destination_not_air")

reset()
layout = layout_for(cases[1])
install_air_destinations(layout)
unloaded = key({x = layout.seller.x, y = layout.seller.y, z = layout.seller.z})
expect_invalid(layout, nil, "blocked_body")

-- Search randomness and expiry are injected so the lease tests are repeatable.
local function options(angle, radius, clock, calls)
	return {
		random = function(low, high)
			if calls then calls.count = calls.count + 1 end
			if high == 35999 then return angle end
			if high == 1200 then return radius end
			error("unexpected random range")
		end,
		now = function() return clock.value end,
	}
end

local clock = {value = 0}
reset()
local first_search = site.begin_search({x = 10, y = 1, z = 10}, "seller-a", options(0, 600, clock))
local status, first_reservation = site.step_search(first_search)
assert(status == "found" and first_reservation.owner == "seller-a", "first valid candidate is reserved")
local repeated_status, repeated_reservation = site.step_search(first_search)
assert(repeated_status == "found" and repeated_reservation == first_reservation,
	"repeated search call returns the same active reservation")
assert(site.valid(first_reservation.layout, first_reservation), "active reservation revalidates")

-- This trader approaches the same pair from the opposite side. The layouts
-- have reversed outward directions and identical exclusive/clearance columns.
local random_calls = {count = 0}
local opposite = site.begin_search({x = 22, y = 1, z = 10}, "seller-b", options(18000, 600, clock, random_calls))
for step = 1, 12 do
	local calls_before = random_calls.count
	local result = site.step_search(opposite)
	assert(opposite.sampled <= step * 4, "no step examines more than four horizontal candidates")
	assert(random_calls.count - calls_before <= 8, "a step generates no more than four horizontal candidates")
	if step < 12 then assert(result == "pending", "conflicting search remains pending") end
end
assert(site.step_search(opposite) == "exhausted", "conflicting opposite-facing stall exhausts at 48")
assert(opposite.sampled == 48, "search samples no more than 48 horizontal candidates")
assert(site.release(first_reservation), "release frees the first reservation")
local after_release = site.begin_search({x = 22, y = 1, z = 10}, "seller-b", options(18000, 600, clock))
local released_status, released_reservation = site.step_search(after_release)
assert(released_status == "found", "released space is available")
assert(site.release(released_reservation), "new reservation releases cleanly")
assert(site.step_search(after_release) == "exhausted", "released search cannot report an inactive reservation")

-- Neighboring stalls share clearance cells, provided no table/seller column
-- from either stall occupies the other's clearance.
local shared = site.begin_search({x = 10, y = 1, z = 10}, "seller-shared", options(2665, 670, clock))
local shared_status, shared_reservation = site.step_search(shared)
assert(shared_status == "found", "empty overlapping aisles are allowed")
assert(site.release(shared_reservation), "shared-aisle reservation releases")

-- The same X/Z layout is independent on another floor, including head space.
reset()
for x = 0, 25 do
	for z = 0, 25 do world[key({x = x, y = 2, z = z})] = "test:stone" end
end
local upper = site.begin_search({x = 10, y = 3, z = 10}, "upper", options(0, 600, clock))
local upper_status, upper_reservation = site.step_search(upper)
assert(upper_status == "found", "separate-floor stall does not conflict")
assert(site.release(upper_reservation), "upper reservation releases")

-- Stale reservation objects cannot extend or release a replacement lease.
reset()
local stale_search = site.begin_search({x = 10, y = 1, z = 10}, "seller", options(0, 600, clock))
local _, stale = site.step_search(stale_search)
assert(site.release(stale), "initial lease releases")
local replacement_search = site.begin_search({x = 10, y = 1, z = 10}, "seller", options(0, 600, clock))
local _, replacement = site.step_search(replacement_search)
assert(replacement and replacement ~= stale, "replacement lease has fresh identity")
assert(not site.release(stale) and not site.renew(stale), "stale token cannot release or renew replacement")
assert(site.valid(stale.layout, stale) == false, "stale reservation fails arrival validation")
assert(site.valid(replacement.layout, replacement), "stale operations leave replacement active")
local wrong_owner = {}
for key_name, value in pairs(stale) do wrong_owner[key_name] = value end
wrong_owner.owner, wrong_owner.token = "another-seller", replacement.token
assert(not site.release(wrong_owner) and not site.renew(wrong_owner),
	"matching a replacement token with the wrong owner cannot mutate its lease")
clock.value = 10
assert(site.step_search(replacement_search) == "exhausted", "expired search cannot report an inactive reservation")
assert(not site.renew(replacement), "lease expires after ten real seconds")
local expiry_search = site.begin_search({x = 10, y = 1, z = 10}, "after-expiry", options(0, 600, clock))
local expiry_status, expiry_reservation = site.step_search(expiry_search)
assert(expiry_status == "found", "expired reservation frees its layout")

-- Arrival performs the same read-only validation against the changed world.
assert(site.valid(expiry_reservation.layout, expiry_reservation), "arrival is valid before world change")
world[key(expiry_reservation.layout.frames[1])] = "test:stone"
expect_invalid(expiry_reservation.layout, expiry_reservation, "destination_not_air")
assert(site.release(expiry_reservation), "arrival failure can release its lease")

-- The rounded, completed table-pair midpoint must still fit the 4–12 range.
local edge = site.begin_search({x = 10, y = 1, z = 10}, "edge", options(0, 1200, clock))
assert(site.step_search(edge) == "pending", "out-of-range rounded midpoint is rejected")
for _ = 1, 10 do assert(site.step_search(edge) == "pending", "edge samples remain bounded") end
assert(site.step_search(edge) == "exhausted" and edge.sampled == 48,
	"rounded midpoint outside twelve nodes never reserves")

-- The site module must only read the map; it never edits, emerges, or routes.
assert(forbidden_calls.writes == 0 and forbidden_calls.emerges == 0 and forbidden_calls.paths == 0,
	"search and reservations perform no map writes, emerges, or pathfinding")

print("market site layout and reservation tests passed")
