-- A stubbed map for tests/stock_buildings.lua (#159): a stock VoxeLibre village
-- building from tests/fixtures/buildings/ standing on flat ground, with the real
-- node definitions from tests/fixtures/buildings/node_defs.lua. Installs the
-- engine stubs navigation.lua needs as globals, so a test builds one world at a
-- time. Run from the repository root.
local defs = dofile("tests/fixtures/buildings/node_defs.lua")

local stock_world = {defs = defs}

-- The village generator rewrites these names in every building it places
-- (mcl_villages/buildings.lua build_a_settlement), after the furnishing modules
-- have edited the schematic.
local VILLAGE_SWAPS = {
	["mcl_stairs:stair_wood_outer"] = "mcl_stairs:slab_wood",
	["mcl_stairs:stair_stone_rough_outer"] = "air",
	["mcl_core:stonebrickcarved"] = "mcl_villages:stonebrickcarved",
}

-- The ground's top layer is y 0, as it is in each schematic (its first layer is
-- dirt); a building's floor starts at y 1.
local GROUND_Y = 0

local function key(pos)
	return pos.x .. ":" .. pos.y .. ":" .. pos.z
end

local function round(value)
	return math.floor(value + 0.5)
end

local function group(name, wanted)
	local def = defs[name]
	return def and def.groups and def.groups[wanted] or 0
end

function stock_world.new()
	local world = {cells = {}, meta = {}, timeofday = 0.8, logged = {}, globalsteps = {}}

	function world.get(pos)
		local found = world.cells[key(pos)]
		if found then return found end
		return {name = pos.y <= GROUND_Y and "mcl_core:dirt" or "air", param2 = 0}
	end

	function world.set(pos, name, param2)
		assert(defs[name], "no node definition for " .. name .. "; add it to tools/extract_schematics")
		world.cells[key(pos)] = {name = name, param2 = param2 or 0}
	end

	-- The node-name layers of a fixture as a schematic table, the shape the
	-- furnishing modules edit.
	local function schematic_of(fixture)
		local data = {}
		for i, id in ipairs(fixture.ids) do
			data[i] = {name = fixture.names[id + 1], prob = 255, param2 = fixture.param2[i]}
		end
		return {size = fixture.size, data = data}
	end

	-- Turns a node's param2 a quarter, the way placing the schematic rotated does
	-- for the nodes whose param2 is a facing: facedir 0..3 is +z, +x, -z, -x.
	local function turn_param2(name, param2)
		local kind = defs[name].paramtype2
		if kind == "facedir" or kind == "colorfacedir" or kind == "4dir" or kind == "color4dir" then
			return param2 - param2 % 4 + (param2 % 4 + 1) % 4
		end
		return param2
	end

	-- Places a stock building with its minimum corner at ox, ground, oz, turned
	-- `rotation` quarters (what the village generator picks at random). `furnish`
	-- maps names to this mod's furnishing functions, applied first as they are in
	-- play; each returns false for a layout that is not its building's. Returns the
	-- size the building takes up. world.fixture_pos(pos) maps a cell of the
	-- placed building back to its coordinates in the fixture.
	function world.place(fixture, ox, oz, furnish, rotation)
		local schematic = schematic_of(fixture)
		for _, fn in pairs(furnish or {}) do fn(schematic) end
		local size = schematic.size
		local width, depth = size.x, size.z
		local back = {}
		for i, cell in ipairs(schematic.data) do
			local x = (i - 1) % size.x
			local y = math.floor((i - 1) / size.x) % size.y
			local z = math.floor((i - 1) / (size.x * size.y))
			local name, param2 = VILLAGE_SWAPS[cell.name] or cell.name, cell.param2
			local from_x, from_z = x, z
			local w, d = width, depth
			for _ = 1, rotation or 0 do
				x, z = z, w - 1 - x
				w, d = d, w
				param2 = turn_param2(name, param2)
			end
			local pos = {x = ox + x, y = GROUND_Y + y, z = oz + z}
			world.set(pos, name, param2)
			back[key(pos)] = {x = from_x, y = y, z = from_z}
		end
		function world.fixture_pos(pos) return back[key(pos)] end
		local w, d = width, depth
		for _ = 1, rotation or 0 do w, d = d, w end
		return {x = w, y = size.y, z = d}
	end

	-- Opens every closed wooden door the way mcl_doors does (api_doors.lua
	-- on_open_close): the _1 variants become _2 and a closed door turns a quarter
	-- forward as it opens. Villagers leave doors open behind them.
	function world.open_doors()
		for id, node in pairs(world.cells) do
			local half = node.name:match("^mcl_doors:wooden_door_([bt])_1$")
			if half then
				world.cells[id] = {name = "mcl_doors:wooden_door_" .. half .. "_2", param2 = (node.param2 + 1) % 4}
			end
		end
	end

	function world.meta_of(pos)
		local fields = world.meta[key(pos)]
		if not fields then fields = {}; world.meta[key(pos)] = fields end
		return {
			get_string = function(_, field) return fields[field] or "" end,
			set_string = function(_, field, value) fields[field] = value end,
		}
	end

	function world.claim(pos, id)
		world.meta[key(pos)] = {villager = id}
	end

	-- An outdoor bed on open ground, for a route out of a building to end at.
	function world.add_bed(x, z)
		world.set({x = x, y = GROUND_Y + 1, z = z}, "mcl_beds:bed_red_bottom")
		world.set({x = x + 1, y = GROUND_Y + 1, z = z}, "mcl_beds:bed_red_top")
		return {x = x, y = GROUND_Y + 1, z = z}
	end

	-- Open floor in the engine's own terms: air at the feet and the head over a
	-- full cube. Deliberately the plainest reading, so that a route this
	-- accepts is not one the planner's own rules had to agree to.
	function world.is_plain_floor(pos)
		local feet, head = world.get(pos), world.get({x = pos.x, y = pos.y + 1, z = pos.z})
		local below = world.get({x = pos.x, y = pos.y - 1, z = pos.z})
		return feet.name == "air" and head.name == "air"
			and defs[below.name].walkable and defs[below.name].drawtype == "normal"
	end

	world.ground_y = GROUND_Y
	return world
end

-- Installs the engine stubs for `world` as globals. Every global is replaced
-- on each call, so tests can build several worlds in turn.
function stock_world.install(world)
	minetest = {
		registered_nodes = defs,
		get_timeofday = function() return world.timeofday end,
		get_gametime = function() return 100 end,
		get_modpath = function() return "." end,
		get_node_or_nil = function(pos) return world.get({x = round(pos.x), y = round(pos.y), z = round(pos.z)}) end,
		get_meta = world.meta_of,
		get_item_group = group,
		-- The engine's own route is stubbed out so that the planner is the only
		-- chooser; tests/navigation.lua covers the two together.
		find_path = function() return nil end,
		find_node_near = function(pos, radius, names)
			for dy = -radius, radius do
				for dx = -radius, radius do
					for dz = -radius, radius do
						local at = {x = round(pos.x) + dx, y = round(pos.y) + dy, z = round(pos.z) + dz}
						for _, name in ipairs(names) do
							if world.get(at).name == name then return at end
						end
					end
				end
			end
		end,
		find_nodes_in_area = function() return {} end,
		get_objects_inside_radius = function() return {} end,
		hash_node_position = key,
		register_globalstep = function(step) table.insert(world.globalsteps, step) end,
		log = function(_, message) table.insert(world.logged, message) end,
		pos_to_string = function(pos) return "(" .. pos.x .. "," .. pos.y .. "," .. pos.z .. ")" end,
		serialize_schematic = function() return nil end,
	}
	vector = {
		new = function(pos) return {x = pos.x, y = pos.y, z = pos.z} end,
		zero = function() return {x = 0, y = 0, z = 0} end,
		round = function(pos) return {x = round(pos.x), y = round(pos.y), z = round(pos.z)} end,
		distance = function(a, b)
			local x, y, z = a.x - b.x, a.y - b.y, a.z - b.z
			return math.sqrt(x * x + y * y + z * z)
		end,
	}
	-- The top half of a bed is the neighbor that is group bed 2.
	mcl_beds = {get_bed_top = function(pos)
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local at = {x = pos.x + d[1], y = pos.y, z = pos.z + d[2]}
			if group(world.get(at).name, "bed") == 2 then return at end
		end
		return pos
	end}
	mcl_mobs = {mob_class = {}}
	settlements = nil
end

return stock_world
