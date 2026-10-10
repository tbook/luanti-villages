-- Plant census (#214, #224): what stands wrongly on the ground a village edit
-- moved. Pure over a node array, so tests/lv_probe_plants.lua runs it without the
-- engine.
--
-- `kind(id)` classifies a content id as one of
--   "air", "ignore", "liquid", "leaves", "soil" (dirt and grass blocks), "solid" (any
--   other walkable node), "growth" (bamboo, cactus, sugar cane: stalks that stand in a
--   column), "plant" (any other plant: a flower, a berry bush, tall grass), "vine",
--   "other" (a walkable-less node that is none of those)
-- and returns the counts:
--   buried_growth, buried_plant  a growth or plant node with soil or a solid node directly over it
--   dirt_on_growth               a soil node directly on a growth node (the #224 shape)
--   floating                     a plant or growth whose base has air under it
--   hole_all, hole_any           a plant or growth whose base is 2 or more below the ground
--                                top of all four, or of any of the four, neighbouring columns
--   vines_unsupported            a vine with no solid node beside or over it and no vine over it
local M = {}

local SAMPLES = 8
local function bump(t, k, x, y, z)
	t[k] = (t[k] or 0) + 1
	if x then
		local list = t.samples[k] or {}
		t.samples[k] = list
		if #list < SAMPLES then list[#list + 1] = x .. "," .. y .. "," .. z end
	end
end

function M.count(data, va, area, kind, name_at, param2)
	local out = {buried_growth = 0, buried_plant = 0, dirt_on_growth = 0, floating = 0,
		hole_all = 0, hole_any = 0, vines_unsupported = 0, growth = 0, plants = 0, vines = 0, samples = {}}
	-- Pass 1: the ground top of each column, skipping leaves, growth, plants and liquids.
	local top = {}
	for x = area.x1, area.x2 do
		top[x] = {}
		for z = area.z1, area.z2 do
			for y = area.y2, area.y1, -1 do
				local k = kind(data[va:index(x, y, z)])
				if k == "soil" or k == "solid" then top[x][z] = y break end
			end
		end
	end
	local function solid(x, y, z)
		if x < area.x1 or x > area.x2 or z < area.z1 or z > area.z2 or y < area.y1 or y > area.y2 then return false end
		local k = kind(data[va:index(x, y, z)])
		return k == "soil" or k == "solid" or k == "leaves"
	end
	local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	for x = area.x1, area.x2 do
		for z = area.z1, area.z2 do
			local above_kind = "air"
			for y = area.y2, area.y1, -1 do
				local k = kind(data[va:index(x, y, z)])
				local below = y > area.y1 and kind(data[va:index(x, y - 1, z)]) or "ignore"
				if k == "growth" or k == "plant" then
					bump(out, k == "growth" and "growth" or "plants")
					if above_kind == "soil" or above_kind == "solid" then
						bump(out, k == "growth" and "buried_growth" or "buried_plant", x, y, z)
					end
					if below ~= k and below ~= "growth" then
						-- The base of a stalk or the plant itself.
						if below == "air" then
							bump(out, "floating", x, y, z)
							-- What lies under the base, for working out how it got there.
							if #(out.samples.floating_below or {}) < SAMPLES then
								local under = {}
								for dy = 1, 12 do
									if y - dy >= area.y1 then under[#under + 1] = kind(data[va:index(x, y - dy, z)]):sub(1, 1) end
								end
								out.samples.floating_below = out.samples.floating_below or {}
								table.insert(out.samples.floating_below, x .. "," .. y .. "," .. z .. " " .. (name_at and name_at(x, y, z) or "") .. " " .. table.concat(under))
							end
						end
						local g = y - 1
						local lower, count = 0, 0
						for _, d in ipairs(dirs) do
							local nx, nz = x + d[1], z + d[2]
							local t = top[nx] and top[nx][nz]
							if t then
								count = count + 1
								if t >= g + 2 then lower = lower + 1 end
							end
						end
						if lower > 0 then bump(out, "hole_any") end
						if count > 0 and lower == count then bump(out, "hole_all", x, y, z) end
					end
				elseif k == "soil" and below == "growth" then
					-- soil directly on a growth node: counted from the soil's side
					bump(out, "dirt_on_growth", x, y, z)
				elseif k == "vine" then
					bump(out, "vines")
					local held = above_kind == "vine" or above_kind == "soil" or above_kind == "solid" or above_kind == "leaves"
					if not held then
						for _, d in ipairs(dirs) do
							if solid(x + d[1], y, z + d[2]) then held = true break end
						end
					end
					if not held then
							bump(out, "vines_unsupported", x, y, z)
							local ctx = out.samples.vine_context or {}
							out.samples.vine_context = ctx
							if #ctx < SAMPLES and name_at and param2 then
								local p2 = param2[va:index(x, y, z)]
								local dirs8 = {[0] = {0, 1, 0}, {0, -1, 0}, {1, 0, 0}, {-1, 0, 0}, {0, 0, 1}, {0, 0, -1}}
								local d = dirs8[p2 % 8] or {0, 0, 0}
								ctx[#ctx + 1] = x .. "," .. y .. "," .. z .. " p2=" .. p2 .. " support=" .. name_at(x + d[1], y + d[2], z + d[3])
									.. " above=" .. name_at(x, y + 1, z)
							end
						end
				end
				above_kind = k
			end
		end
	end
	return out
end

return M
