-- Shared pieces for the village terrain work (#133: #139, #140, #141, #142),
-- so each ticket doesn't write its own: the village area, a height lookup over
-- it, an emerge-first step, column writes, and one installer for the
-- replacements of VoxeLibre's generator steps (mcl_villages).
--
-- Loading this has no side effects. Everything takes the engine table as an
-- optional last argument (default `minetest`) so tests can stub it.
local core = minetest

local SETTING = "living_villages_smooth_villages"
local DEFAULT_BELOW = 20 -- foundations reach this far under a building, as settlements.ground does
local DEFAULT_ABOVE_FACTOR = 3 -- terraform clears three building heights above the base

local M = {}

-- The footprint of a plan entry on the ground: pos is its corner, and a
-- rotation of 90 or 270 swaps width and depth, as settlements.terraform does.
-- `schematics` is settlements.schematic_table (a list with a `name` each).
local function footprint(entry, schematics)
	for _, schem in ipairs(schematics) do
		if schem.name == entry.name then
			local rotated = entry.rotat == "90" or entry.rotat == "270"
			local width = rotated and schem.hdepth or schem.hwidth
			local depth = rotated and schem.hwidth or schem.hdepth
			return {
				minp = {x = entry.pos.x, z = entry.pos.z},
				maxp = {x = entry.pos.x + width - 1, z = entry.pos.z + depth - 1},
				height = schem.hheight,
			}
		end
	end
end

M.footprint = footprint

-- The box around every footprint of a plan, plus `margin` nodes on each side
-- of x and z. Vertically it runs from `below` under the lowest building base
-- to `above` over the highest (defaults: foundation depth, and what terraform
-- clears). Returns nil for an empty plan or an unknown building name.
function M.area(plan, schematics, margin, opts)
	opts = opts or {}
	local area
	for _, entry in ipairs(plan) do
		local box = footprint(entry, schematics)
		if not box then return nil, "unknown building " .. tostring(entry.name) end
		local low = entry.pos.y - (opts.below or DEFAULT_BELOW)
		local high = entry.pos.y + (opts.above or box.height * DEFAULT_ABOVE_FACTOR)
		if not area then
			area = {
				minp = {x = box.minp.x, y = low, z = box.minp.z},
				maxp = {x = box.maxp.x, y = high, z = box.maxp.z},
			}
		else
			area.minp.x, area.minp.y, area.minp.z =
				math.min(area.minp.x, box.minp.x), math.min(area.minp.y, low), math.min(area.minp.z, box.minp.z)
			area.maxp.x, area.maxp.y, area.maxp.z =
				math.max(area.maxp.x, box.maxp.x), math.max(area.maxp.y, high), math.max(area.maxp.z, box.maxp.z)
		end
	end
	if not area then return nil, "empty plan" end
	margin = margin or 0
	area.minp.x, area.minp.z = area.minp.x - margin, area.minp.z - margin
	area.maxp.x, area.maxp.z = area.maxp.x + margin, area.maxp.z + margin
	return area
end

-- Emerge the whole area, then call done(true) or done(false, reason). Waiting
-- for the callback is the only way to know the blocks exist: swap_node into
-- an unloaded block silently does nothing, and mcl_villages' own emerge_area
-- covers only the center +/- 40. Failure is logged as well as reported.
function M.emerge(area, done, engine)
	engine = engine or core
	local failed
	local function callback(_, action, remaining)
		if action == engine.EMERGE_CANCELLED or action == engine.EMERGE_ERRORED then
			failed = failed or "emerge failed or was cancelled"
		end
		if remaining > 0 then return end
		if failed then
			engine.log("warning", "[living_villages] village area "
				.. engine.pos_to_string(area.minp) .. " to " .. engine.pos_to_string(area.maxp)
				.. " could not be loaded: " .. failed)
			return done(false, failed)
		end
		return done(true)
	end
	engine.emerge_area(area.minp, area.maxp, callback)
end

-- What settlements.find_surface (mcl_villages/utils.lua) accepts above a
-- surface node, matched by substring on the node name as it does: air, a
-- plant, a tree (a trunk standing on it still counts) or snow.
local OPEN_ABOVE = {"air", "fern", "flower", "bush", "tree", "grass", "snow"}
local function open_above(name)
	for _, word in ipairs(OPEN_ABOVE) do
		if name:find(word, 1, true) then return true end
	end
	return false
end

-- Read the area once, with a single VoxelManip pass, and return
-- lookup(x, z) -> {y, name, liquid, surface_y, material} or nil outside the area.
-- - y, name: the top solid or liquid node of the column, whatever its material
--   (a tree's leaves, a cave floor under an open shaft, the water of a pond)
-- - liquid: whether that top node is liquid
-- - ground_y, ground_name, ground_liquid: the same, but skipping leaves, which
--   nobody stands on (#142 measures holes by it)
-- - surface_y, material: the highest node in settlements.surface_mat that
--   find_surface would accept: air, a plant, a trunk or snow above it, and no
--   leaves below it. nil where the column has none (a shaft, a pond bed)
-- Returns nil and a reason if any of the area is still unloaded, because the
-- column tops would then be wrong; emerge first. With `partial` set, a column with
-- an unloaded node is nil in the lookup instead, and the rest is returned.
function M.heights(area, surface_materials, engine, partial)
	engine = engine or core
	local vm = engine.get_voxel_manip()
	local emin, emax = vm:read_from_map(area.minp, area.maxp)
	local data = vm:get_data()
	local va = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local ignore = engine.CONTENT_IGNORE
	local traits = {}
	local function trait(id)
		local t = traits[id]
		if not t then
			local name = engine.get_name_from_content_id(id)
			local def = engine.registered_nodes[name]
			local liquid = def and (def.liquidtype or "none") ~= "none" or false
			t = {
				def = def,
				name = name,
				solid_or_liquid = id ~= engine.CONTENT_AIR and (liquid or (def and def.walkable) or false) or false,
				liquid = liquid,
				open = open_above(name),
				leaves = name:find("leaves", 1, true) ~= nil,
			}
			traits[id] = t
		end
		return t
	end

	local columns = {}
	for z = area.minp.z, area.maxp.z do
		columns[z] = {}
		for x = area.minp.x, area.maxp.x do
			local column = {}
			-- Every node of the requested volume is checked for ignore, so no
			-- early exit: a block below the surface may still be unloaded.
			for y = area.maxp.y, area.minp.y, -1 do
				local id = data[va:index(x, y, z)]
				if id == ignore then
					if not partial then return nil, "unloaded node at " .. engine.pos_to_string({x = x, y = y, z = z}) end
					column.unloaded = true
					-- Unknown ground above the first solid node makes the column unknown;
					-- unloaded blocks under it do not (ground_y).
					if not column.ground_y then column.ground_unknown = true end
				end
				local t = trait(id)
				if not column.y and t.solid_or_liquid then
					column.y, column.name, column.liquid = y, t.name, t.liquid
				end
				if not column.ground_y and t.solid_or_liquid and not t.leaves then
					column.ground_y, column.ground_name, column.ground_liquid = y, t.name, t.liquid
				end
				if not column.surface_y and surface_materials[t.name] then
					local above = y < area.maxp.y and trait(data[va:index(x, y + 1, z)]) or nil
					local below_id = y > area.minp.y and data[va:index(x, y - 1, z)] or nil
					local below = below_id and trait(below_id) or nil
					-- A snow layer with air under it floats (its tree is gone): not ground.
					local floating = t.name == "mcl_core:snow" and below_id == engine.CONTENT_AIR
					if (not above or above.open) and not (below and below.leaves) and not floating then
						column.surface_y, column.material = y, t.name
					end
				end
			end
			columns[z][x] = column
		end
	end
	-- With `raw`, a column that has unloaded nodes comes back too, for callers that
	-- check ground_unknown themselves.
	return function(x, z, raw)
		local column = columns[z] and columns[z][x]
		if column and (raw or not column.unloaded) then return column end
	end
end

-- What a village's ground is made of: the top node and the fill under it for a
-- site's surface material. Sand sits on sandstone, as VoxeLibre builds foundations
-- (mcl_villages/foundation.lua), red sand on red sandstone (VoxeLibre fills it
-- with dirt, #151), and a snow layer cannot top a column of dirt. These cover
-- every surface a village can have (settlements.surface_mat); the rest sit on dirt.
local FOUNDATION = {["mcl_core:sand"] = "mcl_core:sandstone", ["mcl_core:redsand"] = "mcl_core:redsandstone"}
local TOP = {["mcl_core:snow"] = "mcl_core:dirt_with_grass_snow"}
function M.materials(surface)
	surface = surface or "mcl_core:dirt_with_grass"
	return TOP[surface] or surface, FOUNDATION[surface] or "mcl_core:dirt"
end

-- Fill `fill` (default dirt) under y, down until the first solid node, at most
-- as far as foundations go (20). Covers a hole under a building or a yard.
function M.fill_below(x, z, y, fill, engine)
	engine = engine or core
	fill = fill or "mcl_core:dirt"
	for fy = y - 1, y - DEFAULT_BELOW, -1 do
		local pos = {x = x, y = fy, z = z}
		local def = engine.registered_nodes[engine.get_node(pos).name]
		if def and def.walkable and (def.liquidtype or "none") == "none" then break end
		engine.swap_node(pos, {name = fill})
	end
end

-- Set one column to `target_y` with `surface` on top, over a fill of `fill`
-- (default dirt) that runs down until it meets ground. `top_y` is the column's
-- current top (from heights). Above the target everything up to top_y becomes
-- air, which also clears a pond's water. Uses swap_node, so the blocks must
-- be loaded; see emerge.
function M.set_column(x, z, top_y, target_y, surface, fill, engine)
	engine = engine or core
	for y = top_y, target_y + 1, -1 do
		engine.swap_node({x = x, y = y, z = z}, {name = "air"})
	end
	engine.swap_node({x = x, y = target_y, z = z}, {name = surface})
	M.fill_below(x, z, target_y, fill, engine)
end

local function lookup_path(path, root)
	local value = root
	for key in path:gmatch("[^.]+") do
		if type(value) ~= "table" then return nil end
		value = value[key]
	end
	return value
end

-- The one place that replaces VoxeLibre's generator steps. `replacements` is a
-- list of {target = "terraform", needs = {...}, make = function(original) ... end}:
-- `target` names a function on the settlements table, `needs` lists what else it
-- relies on by dotted path: "settlements.find_surface" must be a function, and
-- {"settlements.surface_mat", type = "table"} (or any other Lua type) checks a
-- table or value,
-- and `make` gets the vanilla function and returns the replacement (or nil to
-- decline). Nothing is replaced unless every entry can be: with the setting
-- off, or a target or need missing or not a function, this logs and leaves the
-- vanilla generator whole. Returns true if installed.
function M.install(env, replacements, engine)
	engine = engine or core
	local settings = engine.settings
	if settings and settings:get_bool(SETTING, true) == false then
		engine.log("action", "[living_villages] " .. SETTING .. " is off, villages generate as in VoxeLibre")
		return false
	end
	local function warn(reason)
		engine.log("warning", "[living_villages] village terrain not installed, "
			.. "vanilla generation stays: " .. reason)
		return false
	end
	local settlements = env.settlements
	if type(settlements) ~= "table" then return warn("no settlements table (mcl_villages)") end
	local made = {}
	for i, entry in ipairs(replacements) do
		if type(settlements[entry.target]) ~= "function" then
			return warn("settlements." .. entry.target .. " is missing or not a function")
		end
		for _, need in ipairs(entry.needs or {}) do
			local path, want = need, "function"
			if type(need) == "table" then path, want = need[1], need.type end
			if type(lookup_path(path, env)) ~= want then
				return warn(path .. " (needed by " .. entry.target .. ") is missing or not a " .. want)
			end
		end
		made[i] = entry.make(settlements[entry.target])
		if type(made[i]) ~= "function" then
			return warn("the " .. entry.target .. " replacement declined to install")
		end
	end
	for i, entry in ipairs(replacements) do settlements[entry.target] = made[i] end
	return true
end

M.SETTING = SETTING
return M
