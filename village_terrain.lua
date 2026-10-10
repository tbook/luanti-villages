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
-- An overhang (#209): a surface that is only a slab over open air, not ground. v7
-- mountains leave edges like that: at the Testlandia village the slab was 2 thick
-- (y 43..44) over 4 air with the real ground under it, and a neighbouring one 6
-- thick over 15 air. Smoothing cuts a column by at most `cap` (5), so a slab of
-- cap + 1 or thinner is cut through its bottom node and the fill under the
-- new surface lands in the air below it: a dirt pillar. A thicker slab keeps a
-- ceiling under the cut, so it stays "ground". The gap must be real air: the
-- Testlandia pillars stood over gaps of 4 and 15, and a crust over a smaller pocket
-- or cave is left to the smoothing (a gap of 3 also left village edges unsmoothed).
local OVERHANG_MAX_THICKNESS = 6
local OVERHANG_MIN_GAP = 4

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

-- Growth that stands in a column and cannot move with the surface (#214, #224):
-- bamboo, cactus and sugar cane. Not the bamboo building blocks. Everything else that
-- grows out of the ground is a plant (is_decor) and is moved with the surface.
function M.is_growth(name, def)
	if name == "mcl_core:cactus" or name == "mcl_core:reeds" then return true end
	return name:find("^mcl_bamboo:bamboo") ~= nil and def ~= nil and def.groups ~= nil
		and (def.groups.plant or 0) > 0
end

-- Decorations stand on the ground and are not ground: plants, flowers, a layer of
-- snow. Groups first, then a few name words for plants that lack them.
local DECOR_WORDS = {"grass", "fern", "flower", "bush", "sapling", "mushroom"}
function M.is_decor(name, engine)
	engine = engine or core
	if name == "air" or name == "ignore" then return false end
	local def = engine.registered_nodes[name]
	if not def or def.walkable or (def.liquidtype or "none") ~= "none" then return false end
	if name == "mcl_core:snow" then return true end
	if M.is_growth(name, def) then return false end
	if def.groups and (def.groups.plant or def.groups.flower or def.groups.flora) then return true end
	for _, word in ipairs(DECOR_WORDS) do
		if name:find(word, 1, true) then return true end
	end
	return false
end

-- A two-high plant is a bottom node `name` with a `name_top` above it (VoxeLibre's
-- add_large_plant: tall grass, large fern, peony, rose bush, lilac, sunflower).
function M.top_name(name, engine)
	engine = engine or core
	local top = name .. "_top"
	if engine.registered_nodes[top] then return top end
end
function M.is_top_half(name, engine)
	engine = engine or core
	return name:sub(-4) == "_top" and engine.registered_nodes[name:sub(1, -5)] ~= nil
end

-- What stands on the surface node at y (before the column is rewritten): returns the
-- plant node, and its top half for a two-high plant, or nil.
function M.take_decor(x, z, y, engine)
	engine = engine or core
	local above = engine.get_node({x = x, y = y + 1, z = z})
	if not M.is_decor(above.name, engine) or M.is_top_half(above.name, engine) then return end
	local top = M.top_name(above.name, engine)
	if not top then return above end
	local up = engine.get_node({x = x, y = y + 2, z = z})
	if up.name == top then return above, up end
end

-- A plant that grows on grass or dirt dies on sand: only a dead bush stays on it.
-- Only sand is checked: VoxeLibre sets no per-plant soil group on its flowers and ferns.
local function valid_soil(surface, plant)
	if surface:find("sand", 1, true) then return plant:find("dead", 1, true) ~= nil end
	return true
end

-- After the surface at y is written: clear what still stands over it that must not (a
-- bamboo, cactus or cane stalk, a stray plant half), then put the plant `decor`
-- (with `decor_top`) back on it when `surface` is a soil it can stand on, else it is
-- gone. A stalk is never kept: it would stand on a block it did not grow on.
function M.put_decor(x, z, y, decor, decor_top, surface, engine)
	engine = engine or core
	for dy = 1, 32 do
		local p = {x = x, y = y + dy, z = z}
		local name = engine.get_node(p).name
		if not M.is_growth(name, engine.registered_nodes[name]) then break end
		engine.swap_node(p, {name = "air"})
	end
	for dy = 1, 3 do
		local p = {x = x, y = y + dy, z = z}
		if M.is_decor(engine.get_node(p).name, engine) then engine.swap_node(p, {name = "air"}) end
	end
	if decor and valid_soil(surface, decor.name) then
		engine.swap_node({x = x, y = y + 1, z = z}, decor)
		if decor_top then engine.swap_node({x = x, y = y + 2, z = z}, decor_top) end
	end
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
-- - base_y, base_name, base_liquid: the same again, but skipping what grows out of
--   the ground too (a trunk, a cactus, bamboo), so a tree is not a peak (#155)
-- - surface_y, material: the highest node in settlements.surface_mat that
--   find_surface would accept: air, a plant, a trunk or snow above it, and no
--   leaves below it. nil where the column has none (a shaft, a pond bed)
-- - overhang: true when surface_y (or base_y, where growth hides the surface) is only a thin slab over air (see OVERHANG_*), so
--   it is not the column's ground (#209)
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
				stalk = M.is_growth(name, def),
				leaves = name:find("leaves", 1, true) ~= nil,
				growth = (def and def.groups and def.groups.tree ~= nil) or name:find("tree", 1, true) ~= nil
					or M.is_growth(name, def),
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
				if not column.base_y and t.solid_or_liquid and not t.leaves and not t.growth then
					column.base_y, column.base_name, column.base_liquid = y, t.name, t.liquid
				end
				if not column.surface_y and surface_materials[t.name] then
					local above = y < area.maxp.y and trait(data[va:index(x, y + 1, z)]) or nil
					local below_id = y > area.minp.y and data[va:index(x, y - 1, z)] or nil
					local below = below_id and trait(below_id) or nil
					-- A snow layer with air under it floats (its tree is gone): not ground.
					local floating = t.name == "mcl_core:snow" and below_id == engine.CONTENT_AIR
					if (not above or above.open or above.stalk) and not (below and below.leaves) and not floating then
						column.surface_y, column.material = y, t.name
					end
				end
			end
			-- A column whose surface is hidden by growth (grass under bamboo or a sapling) is
			-- judged by its base, so a slab with a stalk on it is an overhang too.
			local top_y = column.surface_y or (not column.base_liquid and column.base_y) or nil
			if top_y then
				-- Walk down the solid run under the surface, then count the air under it.
				local y, thick = top_y, 0
				while y >= area.minp.y and thick <= OVERHANG_MAX_THICKNESS do
					local t = trait(data[va:index(x, y, z)])
					if not t.solid_or_liquid and data[va:index(x, y, z)] ~= ignore then break end
					thick, y = thick + 1, y - 1
				end
				if thick <= OVERHANG_MAX_THICKNESS then
					local gap = 0
					while y >= area.minp.y and data[va:index(x, y, z)] == engine.CONTENT_AIR do
						gap, y = gap + 1, y - 1
					end
					column.overhang = gap >= OVERHANG_MIN_GAP
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

-- Fill `fill` (default dirt) under y, down to the first solid node, so the fill
-- always meets ground. Covers a hole under a building or a yard. A bamboo, cactus
-- or cane stalk is not ground (#224): the fill goes through it. Liquid is filled
-- through (a pond under a raised column, lava, #142). It stops above an unloaded
-- node (`ignore`: swapping it does nothing and the ground below is unknown). If no
-- solid node lies within the foundation depth (20) it fills nothing: a dirt column
-- hanging over a cave or void is worse than a grass block with air under it (#209).
function M.fill_below(x, z, y, fill, engine)
	engine = engine or core
	fill = fill or "mcl_core:dirt"
	local last
	for fy = y - 1, y - DEFAULT_BELOW, -1 do
		local name = engine.get_node({x = x, y = fy, z = z}).name
		local def = engine.registered_nodes[name]
		if name == "ignore" or (def and def.walkable and (def.liquidtype or "none") == "none"
				and not M.is_growth(name, def)) then
			last = fy + 1
			break
		end
	end
	if not last then return end
	for fy = y - 1, last, -1 do
		engine.swap_node({x = x, y = fy, z = z}, {name = fill})
	end
end

-- Whether the surface at y is an overhang (see OVERHANG_*), for callers that read
-- nodes one at a time. `kind(fy)` returns "solid", "air" or other for the node at
-- fy; `ymin` is the lowest y to look at.
function M.is_overhang(y, kind, ymin)
	local thick = 0
	while y >= ymin and thick <= OVERHANG_MAX_THICKNESS and kind(y) == "solid" do
		thick, y = thick + 1, y - 1
	end
	if thick > OVERHANG_MAX_THICKNESS then return false end
	local gap = 0
	while y >= ymin and gap < OVERHANG_MIN_GAP and kind(y) == "air" do
		gap, y = gap + 1, y - 1
	end
	return gap >= OVERHANG_MIN_GAP
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
