-- Run with: lua tests/village_boundary.lua
minetest = {get_modpath = function() return "." end}
local boundary = dofile("village_boundary.lua")

local function rect(x0, z0, x1, z1)
	return {x0 = x0, z0 = z0, x1 = x1, z1 = z1}
end
local town = {rect(0, 0, 4, 4)}
local function flat(y) return function() return y end end

-- A raised town is cut toward its fixed floor. Footprint targets stay exact,
-- and only changed yard/skirt columns enter the future writer's mask.
local raised = assert(boundary.plan(town, 10, {height_at = flat(14)}))
assert(raised.at(2, 2) == 10 and raised.kind(2, 2) == "footprint")
assert(not raised.write_mask(2, 2), "footprint support is filtered from writes")
assert(raised.at(-1, 2) < 14 and raised.write_mask(-1, 2), "raised yard changes")
assert(raised.at(-20, 2) == 14 and not raised.write_mask(-20, 2), "strict radius edge is unchanged")
assert(raised.kind(-19, 2) == "skirt", "column just inside radius is eligible")

-- A cut town is filled from below. With a 30-node discrepancy, the solver
-- still respects the existing five-node cap on every changed column.
local cut = assert(boundary.plan(town, 10, {height_at = flat(-20)}))
assert(cut.at(2, 2) == 10, "footprint is a hard ground_y constraint")
assert(cut.at(-1, 2) == -15, "skirt respects the five-node cap")
for z = cut.targets.z0, cut.targets.z1 do
	for x = cut.targets.x0, cut.targets.x1 do
		local goal, was = cut.at(x, z), cut.was(x, z)
		if goal and was and cut.kind(x, z) ~= "footprint" then
			assert(math.abs(goal - was) <= 5, "cap at " .. x .. "," .. z)
		end
	end
end

-- Overlapping and irregular rectangles share their slopes, while a narrow
-- recess remains represented in the union rather than being replaced by a box.
local compound = {
	rect(-4, -2, 2, 2),
	rect(1, -2, 5, 2),
	rect(-4, 3, -2, 4),
}
local overlap = assert(boundary.plan(compound, 7, {height_at = flat(9)}))
assert(overlap.at(1, 0) == 7 and overlap.kind(1, 0) == "footprint", "overlap stays a hard interior")
assert(overlap.at(4, 1) == 7, "second rectangle is included")
assert(overlap.kind(-1, 4) == "skirt", "irregular extension is included")
assert(overlap.at(0, 4) > 7, "recess outside the rectangles is graded as skirt")

local noop = assert(boundary.plan(town, 10, {height_at = flat(10), radius = 0}))
assert(noop.at(2, 2) == 10 and noop.kind(2, 2) == nil and not noop.write_mask(2, 2), "radius zero is a no-op")

-- Bounds include the radius, the tree cleanup halo and vertical helper reach,
-- then round outward to complete mapblocks. Negative coordinates use floor.
local volume = assert(boundary.volume({rect(-1, -1, 2, 2)}, 0))
assert(volume.minp.x == -48 and volume.maxp.x == 47, "mapblock-rounded X bounds")
assert(volume.minp.z == -48 and volume.maxp.z == 47, "mapblock-rounded Z bounds")
assert(volume.minp.y <= -88 and volume.maxp.y >= 91, "tree and plant helper vertical reach")

local invalid = {
	{{x0 = 1.5, z0 = 0, x1 = 2, z1 = 2}},
	{{x0 = 0, z0 = 0, x1 = 2}},
	{{x0 = 2, z0 = 0, x1 = 1, z1 = 2}},
	{[1] = rect(0, 0, 1, 1), [3] = rect(2, 2, 3, 3)},
}
for _, input in ipairs(invalid) do
	assert(not boundary.plan(input, 0, {height_at = flat(0)}), "invalid rectangle list rejected")
	assert(not boundary.volume(input, 0), "invalid rectangle list has no volume")
end
assert(not boundary.plan(town, 0.5, {height_at = flat(0)}), "noninteger ground rejected")
assert(not boundary.plan(town, 0, {height_at = flat(0), radius = -1}), "negative radius rejected")
assert(not boundary.plan(town, 0, {height_at = flat(0), cap = -1}), "negative cap rejected")
assert(not boundary.volume({rect(31000, 0, 31000, 0)}, 0), "world-limit overflow declined")

print("village_boundary: ok")
