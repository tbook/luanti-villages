-- Natural village paths (#12): grass that villagers keep walking over wears
-- into grass paths, and paths nobody uses any more grow back.
--
-- Every grass block a villager steps onto gets a count. Counts fade by one per
-- DECAY_PERIOD, evaluated lazily from the time of the last change, so nothing
-- is touched between visits. A count of at least WEAR_UP turns the block into
-- a path; a path whose count has faded below WEAR_DOWN turns back into grass.
-- Only blocks this module converted are ever reverted, so paths from village
-- generation or players stay. State lives in mod storage and is saved
-- periodically; the counts are a few numbers per walked block.
local core = minetest

local GRASS = "mcl_core:dirt_with_grass"
local PATH = "mcl_core:grass_path"

local function setting_number(name, default)
	local value = core.settings and tonumber(core.settings:get(name))
	return value or default
end

local M = {}

-- Defaults are first guesses to be tuned on real villages. The decay period
-- is one game week at the default time_speed (a game day is 1200 s).
M.WEAR_UP = setting_number("living_villages_path_wear_up", 12)
M.WEAR_DOWN = setting_number("living_villages_path_wear_down", 4)
M.DECAY_PERIOD = setting_number("living_villages_path_decay_period", 8400)
-- Counts stop here, so a path that was walked heavily still fades in time.
M.CAP = M.WEAR_UP * 2
M.SWEEP_PERIOD = 600
M.SAVE_PERIOD = 300

-- Count, time of the last change, and whether this module made the block a
-- path, each keyed by the hashed node position.
local count, stamp, is_path = {}, {}, {}
local dirty = false
local last_cell = setmetatable({}, {__mode = "k"})

function M.reset()
	count, stamp, is_path, dirty = {}, {}, {}, false
	last_cell = setmetatable({}, {__mode = "k"})
end

local function current(hash, now)
	local faded = math.floor((now - stamp[hash]) / M.DECAY_PERIOD)
	return math.max(0, count[hash] - faded)
end

local function forget(hash)
	count[hash], stamp[hash], is_path[hash] = nil, nil, nil
	dirty = true
end

-- Add one step to a block and report what it should now be: "path" to convert
-- it, or nil. `name` is the node there.
function M.walk(hash, name, now)
	if name ~= GRASS and not (name == PATH and is_path[hash]) then return end
	-- Grass where a path of ours was: someone replaced it, so it is not ours.
	if name == GRASS then is_path[hash] = nil end
	local value = 1
	if count[hash] then
		local faded = math.floor((now - stamp[hash]) / M.DECAY_PERIOD)
		local left = count[hash] - faded
		if left > 0 then
			value = math.min(M.CAP, left + 1)
			-- Keep the part of a period that has not elapsed yet, or a block
			-- visited just under once per period would never fade.
			now = stamp[hash] + faded * M.DECAY_PERIOD
		end
	end
	count[hash], stamp[hash] = value, now
	dirty = true
	if name == GRASS and value >= M.WEAR_UP then
		is_path[hash] = true
		return "path"
	end
end

-- Revert faded paths and drop empty counts. `get` and `set` read and write the
-- node at a hash; get returns nil while the block is not loaded.
function M.sweep(now, get, set)
	for hash in pairs(stamp) do
		local value = current(hash, now)
		if is_path[hash] then
			local name = get(hash)
			if name and name ~= PATH then
				-- Replaced since we made it, so it is no longer ours.
				forget(hash)
			elseif name and value < M.WEAR_DOWN then
				set(hash, GRASS)
				forget(hash)
			end
		elseif value == 0 then
			forget(hash)
		end
	end
end

-- A player digging or placing at a tracked block ends our claim on it.
function M.changed(hash)
	if stamp[hash] then forget(hash) end
end

function M.serialize()
	local list = {}
	for hash in pairs(stamp) do
		list[#list + 1] = {hash, count[hash], stamp[hash], is_path[hash] or nil}
	end
	return list
end

function M.load(list)
	M.reset()
	for _, entry in ipairs(list or {}) do
		count[entry[1]], stamp[entry[1]], is_path[entry[1]] = entry[2], entry[3], entry[4]
	end
end

function M.size()
	local n = 0
	for _ in pairs(stamp) do n = n + 1 end
	return n
end

local function node_name(hash)
	local node = core.get_node_or_nil(core.get_position_from_hash(hash))
	return node and node.name
end

local function set_node(hash, name)
	core.swap_node(core.get_position_from_hash(hash), {name = name})
end

local STORAGE_KEY = "path_wear"

local function save(storage)
	if not dirty then return end
	storage:set_string(STORAGE_KEY, core.serialize(M.serialize()))
	dirty = false
end

local function start_timers(storage)
	M.load(core.deserialize(storage:get_string(STORAGE_KEY)))
	local sweep_timer, save_timer = 0, 0
	core.register_globalstep(function(dtime)
		sweep_timer, save_timer = sweep_timer + dtime, save_timer + dtime
		if sweep_timer >= M.SWEEP_PERIOD then
			sweep_timer = 0
			M.sweep(core.get_gametime(), node_name, set_node)
		end
		if save_timer >= M.SAVE_PERIOD then
			save_timer = 0
			save(storage)
		end
	end)
	core.register_on_shutdown(function() save(storage) end)
	local function on_change(pos) M.changed(core.hash_node_position(pos)) end
	core.register_on_dignode(on_change)
	core.register_on_placenode(on_change)
end

local timers_started = false

-- The block a standing villager rests on: feet are at pos.y, the top of the
-- block below, and the 0.1 covers paths (15/16 high) and a slight sink.
local function ground_cell(pos)
	return {x = math.floor(pos.x + 0.5), y = math.floor(pos.y + 0.1), z = math.floor(pos.z + 0.5)}
end

-- storage must come from core.get_mod_storage() called during mod load, which
-- is not when this runs (init.lua loads it from on_mods_loaded).
function M.install(def, storage)
	if core.settings and core.settings:get_bool("living_villages_natural_paths", true) == false then
		return
	end
	if not timers_started and storage and core.register_globalstep then
		timers_started = true
		start_timers(storage)
	end
	local original_step = def.on_step
	def.on_step = function(self, dtime, moveresult)
		local result = original_step(self, dtime, moveresult)
		local pos = self.object:get_pos()
		if pos then
			local cell = ground_cell(pos)
			local hash = core.hash_node_position(cell)
			-- Standing still, or pacing within one block, counts once.
			if last_cell[self] ~= hash then
				last_cell[self] = hash
				local node = core.get_node_or_nil(cell)
				if node and M.walk(hash, node.name, core.get_gametime()) == "path" then
					core.swap_node(cell, {name = PATH})
				end
			end
		end
		return result
	end
end

return M
