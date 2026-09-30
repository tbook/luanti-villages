-- Play-testing aid: /living_villages_goto teleports to a tavern, or to where a
-- village should generate, instead of flying around looking for one.
--
-- Two sources, best first:
-- - Villages seen generating while this mod is installed, recorded with
--   their tavern (if they got one) as mcl_villages places them.
-- - Predicted sites. mcl_villages tries a village in exactly those mapchunks
--   whose engine blockseed is 17 mod 77 (mcl_villages/init.lua), and that
--   blockseed is a pure function of the world seed and the chunk's position
--   (Luanti mapgen.cpp getBlockSeed2), so the sites can be listed before any
--   of them is generated. A site is only a try: VoxeLibre still rejects
--   uneven ground, and a village that does build may lack a tavern. Going
--   there generates it, after which it is recorded like any other.
local core = minetest
if not core.get_mod_storage or not core.register_chatcommand then return end
local storage = core.get_mod_storage()
local KEY = "villages"
local VISITED_KEY = "visited_sites"
local VILLAGE_MODULUS, VILLAGE_REMAINDER = 77, 17
local SEARCH_CHUNKS = 40
local ARRIVAL_HEIGHT = 40
local TWO16, TWO32 = 65536, 4294967296

local function load(key)
	return core.deserialize(storage:get_string(key or KEY)) or {}
end

local function save(key, value)
	storage:set_string(key, core.serialize(value))
end

local function record(settlement_info)
	local center = settlement_info[1] and settlement_info[1].pos
	if not center then return end
	local entry = {center = vector.new(center)}
	for _, building in ipairs(settlement_info) do
		if building.name == "tavern" then entry.tavern = vector.new(building.pos) end
	end
	local known = load()
	table.insert(known, entry)
	save(KEY, known)
	core.log("action", string.format("[living_villages] village generated at %s%s",
		core.pos_to_string(entry.center),
		entry.tavern and (", tavern at " .. core.pos_to_string(entry.tavern)) or ", no tavern"))
end

-- place_schematics is looked up on the settlements table at the call
-- (mcl_villages/init.lua build_a_settlement), so wrapping it sees every village.
if settlements and settlements.place_schematics then
	local original = settlements.place_schematics
	settlements.place_schematics = function(settlement_info, ...)
		local result = original(settlement_info, ...)
		record(settlement_info)
		return result
	end
end

-- Unsigned 32-bit arithmetic in plain Lua numbers, which are doubles: a
-- full 32x32 product would lose bits past 2^53, so multiply in 16-bit halves.
local function u32(value) return value % TWO32 end

local function mul32(a, b)
	local a_lo, a_hi = a % TWO16, math.floor(a / TWO16)
	return (a_lo * b + ((a_hi * b) % TWO16) * TWO16) % TWO32
end

local function xor32(a, b)
	local result, bit = 0, 1
	for _ = 1, 32 do
		if a % 2 ~= b % 2 then result = result + bit end
		a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
	end
	return result
end

-- The world seed is a 64-bit decimal string, beyond what a double holds
-- exactly; the engine only uses its low 32 bits (Mapgen's s32 seed).
local function low32(decimal)
	local value = 0
	for digit in tostring(decimal):gmatch("%d") do value = (value * 10 + tonumber(digit)) % TWO32 end
	return value
end

-- Mapgen::getBlockSeed2 of a chunk's full_node_min, which includes one block
-- of overgeneration below minp (mapgen_v7.cpp makeChunk).
local function blockseed(minp, seed)
	local p = {x = minp.x - 16, y = minp.y - 16, z = minp.z - 16}
	local n = u32(1619 * p.x + 31337 * p.y + 52591 * p.z + mul32(1013, seed))
	n = xor32(math.floor(n / 8192), n)
	return u32(mul32(n, u32(mul32(mul32(n, n), 60493) + 19990303)) + 1376312589)
end

local function chunk_size()
	return 16 * (tonumber(core.get_mapgen_setting and core.get_mapgen_setting("chunksize")) or 5)
end

-- Mapchunks are aligned so that block (0,0,0) sits in the middle of one.
local function chunk_origin(value, size)
	local offset = 16 * math.floor(size / 32)
	return math.floor((value + offset) / size) * size - offset
end

local function site_key(minp) return minp.x .. "," .. minp.z end

-- Village sites ordered by distance from pos, nearest first. The chunk must
-- contain the estimated ground level; with no estimate (a river, or ground
-- too high to guess) the column is skipped, as a village rarely builds there.
local function predicted_sites(pos, seed, tried, limit)
	local size = chunk_size()
	local cx, cz = chunk_origin(pos.x, size), chunk_origin(pos.z, size)
	local sites = {}
	for dx = -SEARCH_CHUNKS, SEARCH_CHUNKS do
		for dz = -SEARCH_CHUNKS, SEARCH_CHUNKS do
			local x, z = cx + dx * size, cz + dz * size
			local center = {x = x + size / 2, z = z + size / 2}
			local ground = core.get_spawn_level and core.get_spawn_level(center.x, center.z)
			if ground then
				local minp = {x = x, y = chunk_origin(ground, size), z = z}
				if minp.y + size - 1 >= 0 and not tried[site_key(minp)]
					and blockseed(minp, seed) % VILLAGE_MODULUS == VILLAGE_REMAINDER then
					table.insert(sites, {minp = minp, center = {x = center.x, y = ground, z = center.z},
						distance = math.sqrt((center.x - pos.x) ^ 2 + (center.z - pos.z) ^ 2)})
				end
			end
		end
	end
	table.sort(sites, function(a, b) return a.distance < b.distance end)
	while limit and #sites > limit do table.remove(sites) end
	return sites
end

local function nearest_known(known, pos, want_tavern)
	local best, best_distance
	for _, entry in ipairs(known) do
		local target
		if want_tavern then target = entry.tavern else target = entry.center end
		if target then
			local distance = vector.distance(pos, target)
			if not best or distance < best_distance then best, best_distance = entry, distance end
		end
	end
	return best, best_distance
end

-- A known village also marks its chunk as tried, so prediction moves on.
local function tried_sites(known)
	local tried = load(VISITED_KEY)
	local size = chunk_size()
	for _, entry in ipairs(known) do
		tried[chunk_origin(entry.center.x, size) .. "," .. chunk_origin(entry.center.z, size)] = true
	end
	return tried
end

core.register_chatcommand("living_villages_goto", {
	params = "[any|new]",
	description = "Teleport to the nearest known tavern, else the nearest untried village site"
		.. " (\"any\": nearest known village; \"new\": skip known taverns)",
	privs = {teleport = true},
	func = function(name, param)
		local player = core.get_player_by_name(name)
		if not player then return false, "Not in game." end
		local pos = player:get_pos()
		local known = load()
		if param ~= "new" then
			local want_tavern = param ~= "any"
			local entry, distance = nearest_known(known, pos, want_tavern)
			if entry then
				-- A building's pos is its schematic corner on the ground; land
				-- above the middle of the tavern's roof rather than in a wall.
				local target = want_tavern and vector.offset(entry.tavern, 6, 12, 5)
					or vector.offset(entry.center, 0, 12, 0)
				player:set_pos(target)
				return true, string.format("Teleported to %s (%.0f nodes away). Tavern: %s",
					core.pos_to_string(target), distance,
					entry.tavern and core.pos_to_string(entry.tavern) or "none")
			end
		end
		local seed = low32(core.get_mapgen_setting("seed"))
		local site = predicted_sites(pos, seed, tried_sites(known), 1)[1]
		if not site then return false, "No untried village site within range." end
		local visited = load(VISITED_KEY)
		visited[site_key(site.minp)] = true
		save(VISITED_KEY, visited)
		local target = vector.offset(site.center, 0, ARRIVAL_HEIGHT, 0)
		player:set_pos(target)
		return true, string.format("Teleported above a predicted village site at %s (%.0f nodes away)."
			.. " VoxeLibre may still reject the ground; run /living_villages_goto again to see whether"
			.. " a tavern generated, or to try the next site.",
			core.pos_to_string(target), site.distance)
	end,
})

return {
	nearest_known = nearest_known,
	blockseed = blockseed,
	low32 = low32,
	chunk_origin = chunk_origin,
	predicted_sites = predicted_sites,
}
