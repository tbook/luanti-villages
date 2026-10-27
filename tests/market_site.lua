local root = debug.getinfo(1, "S").source:sub(2):match("(.*/)tests/") or "./"
local world, groups, unloaded, nearby_objects, last_query_radius

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

print("market site layout tests passed")
