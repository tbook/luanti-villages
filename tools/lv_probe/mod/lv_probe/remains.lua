-- Tree remains census (#232): what a village build leaves hanging in the air where
-- trees were. Pure over a node array, so tests/lv_probe_remains.lua runs it without
-- the engine.
--
-- `kind(id)` returns "leaves", "trunk" (group:tree), "cocoa", "vine", "support" (any
-- other node a vine may cling to: walkable, full cube) or anything else. Counts are for
-- nodes inside `area` {x1,x2,y1,y2,z1,z2}; trunks and supports are looked up in all of
-- `va`, which should reach LEAF_REACH beyond the area.
--   cocoa, cocoa_loose           cocoa pods, and those whose trunk node is gone
--   vines, vines_loose           vines, and those mcl_core.check_vines_supported would drop
--   leaves, leaves_orphan        leaf nodes, and those with no trunk within LEAF_REACH
--   orphan_clusters              connected groups of orphan leaves (26 neighbours)
--   orphan_high                  orphan leaves 4 or more above the highest support under them
--   samples                      up to 8 positions per count
local M = {}

M.LEAF_REACH = 6
local SAMPLES = 8
local WALLMOUNTED = {[0] = {0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}
local FACEDIR = {[0] = {0, 0, 1}, {1, 0, 0}, {0, 0, -1}, {-1, 0, 0}}

local function sample(out, key, x, y, z)
	local list = out.samples[key] or {}
	out.samples[key] = list
	if #list < SAMPLES then list[#list + 1] = x .. "," .. y .. "," .. z end
end

function M.count(data, va, area, kind, param2, name_at)
	local out = {cocoa = 0, cocoa_loose = 0, vines = 0, vines_loose = 0, leaves = 0, leaves_orphan = 0,
		orphan_clusters = 0, orphan_high = 0, samples = {}}
	local emin, emax = va.MinEdge, va.MaxEdge
	local function kind_at(x, y, z)
		if x < emin.x or x > emax.x or y < emin.y or y > emax.y or z < emin.z or z > emax.z then return "ignore" end
		return kind(data[va:index(x, y, z)])
	end
	local reach = M.LEAF_REACH
	local orphans, orphan_index = {}, {}
	for z = area.z1, area.z2 do
		for y = area.y1, area.y2 do
			for x = area.x1, area.x2 do
				local k = kind_at(x, y, z)
				if k == "cocoa" then
					out.cocoa = out.cocoa + 1
					local d = FACEDIR[param2[va:index(x, y, z)] % 4]
					if kind_at(x + d[1], y + d[2], z + d[3]) ~= "trunk" then
						out.cocoa_loose = out.cocoa_loose + 1
						sample(out, "cocoa_loose", x, y, z)
					end
				elseif k == "vine" then
					out.vines = out.vines + 1
					local p2 = param2[va:index(x, y, z)]
					local d = WALLMOUNTED[p2 % 8]
					local held = d == nil
					if d then
						local nk = kind_at(x + d[1], y + d[2], z + d[3])
						held = nk == "ignore" or nk == "support" or nk == "trunk" or nk == "leaves"
						if not held and d[2] == 0 and kind_at(x, y + 1, z) == "vine"
								and param2[va:index(x, y + 1, z)] == p2 then
							held = true
						end
					end
					if not held then
						out.vines_loose = out.vines_loose + 1
						sample(out, "vines_loose", x, y, z)
						if name_at and #(out.samples.vine_context or {}) < SAMPLES then
							out.samples.vine_context = out.samples.vine_context or {}
							table.insert(out.samples.vine_context, x .. "," .. y .. "," .. z .. " p2=" .. p2
								.. " support=" .. (d and name_at(x + d[1], y + d[2], z + d[3]) or "?") .. " above=" .. name_at(x, y + 1, z))
						end
					end
				elseif k == "leaves" then
					out.leaves = out.leaves + 1
					local supported = false
					for dz = -reach, reach do
						for dy = -reach, reach do
							for dx = -reach, reach do
								if kind_at(x + dx, y + dy, z + dz) == "trunk" then supported = true break end
							end
							if supported then break end
						end
						if supported then break end
					end
					if not supported then
						out.leaves_orphan = out.leaves_orphan + 1
						orphans[#orphans + 1] = {x, y, z}
						orphan_index[x .. "," .. y .. "," .. z] = true
						local under = y - 1
						while under >= emin.y and kind_at(x, under, z) ~= "support" do under = under - 1 end
						if y - under >= 4 then
							out.orphan_high = out.orphan_high + 1
							sample(out, "orphan_high", x, y, z)
						end
					end
				end
			end
		end
	end
	local seen = {}
	for _, o in ipairs(orphans) do
		local key = o[1] .. "," .. o[2] .. "," .. o[3]
		if not seen[key] then
			out.orphan_clusters = out.orphan_clusters + 1
			sample(out, "orphan_clusters", o[1], o[2], o[3])
			seen[key] = true
			local queue, head = {o}, 1
			while head <= #queue do
				local n = queue[head]
				head = head + 1
				for dz = -1, 1 do for dy = -1, 1 do for dx = -1, 1 do
					local nk = (n[1] + dx) .. "," .. (n[2] + dy) .. "," .. (n[3] + dz)
					if orphan_index[nk] and not seen[nk] then
						seen[nk] = true
						queue[#queue + 1] = {n[1] + dx, n[2] + dy, n[3] + dz}
					end
				end end end
			end
		end
	end
	return out
end

return M
