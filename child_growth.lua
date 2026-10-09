-- Slow child growth (#177). VoxeLibre grows a child up in 60 one-second ticks
-- of `hornytimer` (mcl_mobs/breeding.lua, CHILD_GROW_TIME); this stretches
-- that to living_villages_child_grow_days game days, and grows the child's
-- rendered size with it instead of in one pop at the end.
--
-- Time is real seconds of the entity's own steps, like VoxeLibre's: a child
-- grows only while its block is active, so growth freezes with the rest of
-- village life while players are away (no catch-up on activation, by
-- decision). A game day lasts 86400 / time_speed seconds; the setting is read
-- rather than measured from get_timeofday so that /time, sleeping through the
-- night and time_speed 0 cannot skip or stall a childhood. Feeding adds to
-- hornytimer in VoxeLibre's own code, which this leaves alone, and the grown-up
-- switch and hitbox push-out stay VoxeLibre's: this only chooses how far
-- hornytimer moves per tick. hornytimer is saved with the entity already.
local core = minetest

local M = {}

-- VoxeLibre's CHILD_GROW_TIME; hornytimer counts up to it.
M.VOXELIBRE_GROW_TIME = 60
M.DEFAULT_DAYS = 12
local DEFAULT_TIME_SPEED = 72
-- The model has no separate baby mesh: a child is the adult model at half
-- size (mcl_mobs spawn_child), so growth runs from 0.5 to 1.
M.BABY_SCALE = 0.5
M.ADULT_SCALE = 1
-- Rendered size moves in steps of this, so a property update is sent about
-- once every few minutes of growth rather than every second.
local SCALE_STEP = 0.01

local function setting(name)
	return core.settings and tonumber(core.settings:get(name))
end

function M.grow_days()
	local days = setting("living_villages_child_grow_days")
	if not days or days <= 0 then return M.DEFAULT_DAYS end
	return days
end

function M.day_seconds()
	local speed = setting("time_speed")
	if not speed or speed <= 0 then speed = DEFAULT_TIME_SPEED end
	return 86400 / speed
end

-- How far hornytimer moves per one-second tick.
function M.rate()
	return M.VOXELIBRE_GROW_TIME / (M.grow_days() * M.day_seconds())
end

function M.progress(self)
	local p = (tonumber(self.hornytimer) or 0) / M.VOXELIBRE_GROW_TIME
	return math.max(0, math.min(1, p))
end

function M.scale(self)
	local s = M.BABY_SCALE + (M.ADULT_SCALE - M.BABY_SCALE) * M.progress(self)
	return math.floor(s / SCALE_STEP + 1e-9) * SCALE_STEP
end

function M.install(def)
	local original = def.check_breeding or mcl_mobs.mob_class.check_breeding
	def.check_breeding = function(self, ...)
		if not self.child then return original(self, ...) end
		local timer = tonumber(self.hornytimer) or 0
		local rate = M.rate()
		-- VoxeLibre adds 1 to hornytimer and grows the child up at the limit;
		-- hand it the timer one short of where it should land.
		self.hornytimer = timer + rate - 1
		return original(self, ...)
	end
end

return M
