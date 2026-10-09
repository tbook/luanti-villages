-- Run with: lua tests/child_growth.lua
local cfg = {}
minetest = {settings = {get = function(_, name) return cfg[name] end}}

-- Stand-in for VoxeLibre's mob_class:check_breeding and feeding (breeding.lua).
local GROW = 60
local grown = 0
local function vox_check(self)
	if self.child then
		self.hornytimer = self.hornytimer + 1
		if self.hornytimer >= GROW then
			self.child = false
			self.hornytimer = 0
			grown = grown + 1
		end
	end
end
local function feed(self)
	self.hornytimer = self.hornytimer + ((GROW - self.hornytimer) * 0.1)
end
mcl_mobs = {mob_class = {check_breeding = vox_check}}

local growth = dofile("child_growth.lua")
local def = {}
growth.install(def)

local function new_child() return {child = true, hornytimer = 0} end
local function ticks_to_grow(child)
	local n = 0
	while child.child do
		def.check_breeding(child)
		n = n + 1
		assert(n < 10000000, "child never grew")
	end
	return n
end

-- Default: 12 days of 1200 s.
assert(growth.grow_days() == 12 and growth.day_seconds() == 1200)
local n = ticks_to_grow(new_child())
assert(math.abs(n - 14400) <= 1, "12 game days at time_speed 72 is 14400 ticks, got " .. n)

-- Setting and time_speed.
cfg.living_villages_child_grow_days = "1"
n = ticks_to_grow(new_child())
assert(math.abs(n - 1200) <= 1, n)
cfg.time_speed = "144"
n = ticks_to_grow(new_child())
assert(math.abs(n - 600) <= 1, "faster days shorten the childhood in seconds, got " .. n)
cfg.time_speed = "0"
assert(growth.day_seconds() == 1200, "time_speed 0 falls back to the default")
cfg.time_speed = nil
cfg.living_villages_child_grow_days = "garbage"
assert(growth.grow_days() == 12)
cfg.living_villages_child_grow_days = "-3"
assert(growth.grow_days() == 12)

-- Non-finite values fall back to the defaults.
cfg.living_villages_child_grow_days = "inf"
assert(growth.grow_days() == 12)
cfg.living_villages_child_grow_days = "nan"
assert(growth.grow_days() == 12)
cfg.living_villages_child_grow_days = "1"
cfg.time_speed = "inf"
assert(growth.day_seconds() == 1200)
cfg.time_speed = "nan"
assert(growth.day_seconds() == 1200)
cfg.time_speed = nil

-- Rates above one tick per second still grow up (never stall).
cfg.living_villages_child_grow_days = "0.01"
n = ticks_to_grow(new_child())
assert(math.abs(n - 12) <= 1, n)
cfg.living_villages_child_grow_days = "1"

-- Feeding keeps VoxeLibre's speed-up: 10% of the remaining time, applied to
-- the same timer, so a fed child skips ahead by the same share of childhood.
local c = new_child()
for _ = 1, 600 do def.check_breeding(c) end
assert(math.abs(c.hornytimer - 30) < 1e-6, c.hornytimer)
feed(c)
assert(math.abs(c.hornytimer - 33) < 1e-6, c.hornytimer)
n = ticks_to_grow(c)
assert(math.abs(n - 540) <= 1, "fed child needs the remaining 27/60 of 1200 ticks, got " .. n)

-- Frozen while unloaded: no tick, no growth, and nothing is made up later.
c = new_child()
for _ = 1, 100 do def.check_breeding(c) end
local before = c.hornytimer
-- (entity unloaded for any length of time: check_breeding is not called)
def.check_breeding(c)
assert(math.abs(c.hornytimer - before - growth.rate()) < 1e-9,
	"the first tick after activation is a single tick")

-- Saved and restored: hornytimer is an ordinary entity field.
local saved = c.hornytimer
local restored = {child = true, hornytimer = saved}
def.check_breeding(restored)
assert(restored.hornytimer > saved)

-- Adults are untouched.
local adult = {child = false, hornytimer = 5}
def.check_breeding(adult)
assert(adult.hornytimer == 5)

-- Gradual scale: 0.5 at birth, 1 at the end, monotonic, quantised.
cfg.living_villages_child_grow_days = "12"
c = new_child()
assert(growth.scale(c) == 0.5)
local last, changes = 0.5, 0
while c.child do
	def.check_breeding(c)
	if c.child then
		local s = growth.scale(c)
		assert(s >= last and s <= 1, s)
		if s ~= last then changes = changes + 1 end
		last = s
	end
end
assert(last >= 0.99 and last < 1, "scale just before adulthood is near 1, got " .. last)
assert(changes <= 51, "scale changes in 0.01 steps, got " .. changes)
assert(growth.scale({child = true, hornytimer = 30}) == 0.75)
assert(growth.scale({child = true, hornytimer = -1}) == 0.5)
assert(growth.scale({child = true}) == 0.5)

print("child growth tests passed")
