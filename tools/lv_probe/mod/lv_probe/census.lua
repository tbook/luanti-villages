-- Jobsite census (#217): after a village is built, let the villagers live a
-- working morning, then record every villager's profession and jobsite and
-- every workstation node's claim. Only runs when lv_probe_census is set.
local core = minetest

local census = {}
local wells = dofile(core.get_modpath("lv_probe") .. "/wells.lua")

local STATIONS = {
	"mcl_composters:composter", "mcl_barrels:barrel_closed", "mcl_fletching_table:fletching_table",
	"mcl_loom:loom", "mcl_lectern:lectern", "mcl_cartography_table:cartography_table",
	"mcl_blast_furnace:blast_furnace", "mcl_blast_furnace:blast_furnace_active",
	"mcl_smoker:smoker", "mcl_smoker:smoker_active", "mcl_grindstone:grindstone",
	"mcl_smithing_table:table", "mcl_brewing:stand_000", "mcl_stonecutter:stonecutter",
	"living_villages:pulpit", "group:cauldron",
}

local function round1(v) return math.floor(v * 10 + 0.5) / 10 end
local function vec(p) return {x = round1(p.x), y = round1(p.y), z = round1(p.z)} end

function census.enabled()
	return (tonumber(core.settings:get("lv_probe_census")) or 0) > 0
end

core.register_on_mods_loaded(function()
	if not census.enabled() then return end
	local class = mcl_mobs.mob_class
	local original = class.player_in_active_range
	class.player_in_active_range = function(self, ...)
		if self.name == "mobs_mc:villager" then return true end
		return original(self, ...)
	end
end)

local cells
local function load_cells()
	if not cells and core.get_modpath("living_villages") then
		cells = dofile(core.get_modpath("living_villages") .. "/cells.lua")
	end
	return cells
end

-- Whether a position lies inside the village's area (the query below is a sphere).
local function inside(p, minp, maxp)
	return p.x >= minp.x and p.x <= maxp.x and p.y >= minp.y and p.y <= maxp.y and p.z >= minp.z and p.z <= maxp.z
end

-- Steps every 10 s (so a timeline time is a multiple of 10). Writes one record through emit after the census seconds, then calls done().
function census.run(area, emit, done)
	local seconds = tonumber(core.settings:get("lv_probe_census")) or 0
	local minp = {x = area.x1, y = area.y1, z = area.z1}
	local maxp = {x = area.x2, y = area.y2, z = area.z2}
	local center = {x = (minp.x + maxp.x) / 2, y = (minp.y + maxp.y) / 2, z = (minp.z + maxp.z) / 2}
	local radius = math.max(maxp.x - minp.x, maxp.z - minp.z, maxp.y - minp.y)
	load_cells()
	-- lv_probe_census_putter (#11): hold the morning Putter stage this many seconds, then work time.
	local putter = tonumber(core.settings:get("lv_probe_census_putter")) or 0
	local finish_watch = putter > 0 and wells.available() and wells.watch(minp, maxp) or nil
	local waited = 0
	local timeline, last = {}, {}
	local function tick()
		core.set_timeofday(waited < putter and 0.24 or 0.33)
		waited = waited + 10
		-- What each villager held at each step, so a change shows when it happened.
		for _, object in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = object:get_luaentity()
			if e and e.name == "mobs_mc:villager" and e._id and inside(object:get_pos(), minp, maxp) then
				local key = tostring(e._profession) .. "@" .. (e._jobsite and core.pos_to_string(e._jobsite) or "-")
				if last[e._id] ~= key then
					last[e._id] = key
					timeline[#timeline + 1] = {t = waited, id = e._id:sub(1, 6), what = key,
						pos = core.pos_to_string(vector.round(object:get_pos())),
						bed = e._bed and core.pos_to_string(e._bed) or "-"}
				end
			end
		end
		if waited < seconds then return core.after(10, tick) end
		local villagers, by_id = {}, {}
		for _, object in ipairs(core.get_objects_inside_radius(center, radius)) do
			local e = object:get_luaentity()
			if e and e.name == "mobs_mc:villager" and e._id and inside(object:get_pos(), minp, maxp) then
				local route = e._villages_job_search_route
				local v = {
					id = e._id, profession = e._profession, child = e.child or nil,
					jobsite = e._jobsite and vec(e._jobsite) or nil, bed = e._bed and vec(e._bed) or nil,
					pos = vec(object:get_pos()), state = e.state, order = e.order,
					job_route = route and (tostring(route.status) .. "/" .. tostring(route.reason)) or nil,
				}
				villagers[#villagers + 1] = v
				by_id[e._id] = v
			end
		end
		local stations = {}
		for _, p in ipairs(core.find_nodes_in_area(minp, maxp, STATIONS)) do
			local claim = core.get_meta(p):get_string("villager")
			-- navigation.lua's cardinal approach cells (approaches(site, true)).
			local approach, standable = 0, 0
			if cells then
				for _, o in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
					local c = {x = p.x + o[1], y = p.y, z = p.z + o[2]}
					if cells.is_open(c, {thin = true}) and cells.is_open({x = c.x, y = c.y + 1, z = c.z})
						and cells.has_floor(c) then
						approach = approach + 1
						if cells.can_stand(c) then standable = standable + 1 end
					end
				end
			end
			stations[#stations + 1] = {
				name = core.get_node(p).name, pos = vec(p), approach = approach, standable = standable, claim = claim ~= "" and claim or nil,
				claimant = claim ~= "" and by_id[claim] and by_id[claim].profession or nil,
			}
		end
		emit({type = "census", seconds = seconds, villagers = villagers, stations = stations, timeline = timeline,
			wells = finish_watch and finish_watch() or nil})
		done()
	end
	core.after(10, tick)
end

return census
