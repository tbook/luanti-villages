-- Run with: lua tests/nitwit.lua
local night = false
local claims = {}
local composter = {x = 1, y = 0, z = 0}

local function key(pos)
	return ("%d,%d,%d"):format(pos.x, pos.y, pos.z)
end

minetest = {
	deserialize = function(text)
		local chunk = (loadstring or load)(text)
		return chunk and chunk()
	end,
}

-- Only the vanilla paths #75 runs through (mobs_mc/villager.lua): an untraded
-- villager's search covers every jobsite type, a traded one's only its own
-- profession's, and a nitwit has none.
local jobsite_of = {farmer = "mcl_composters:composter", nitwit = nil}
local calls

local function has_traded(self)
	local trades = self._trades and minetest.deserialize(self._trades)
	if type(trades) ~= "table" then return false end
	for _, trade in pairs(trades) do
		if trade.traded_once then return true end
	end
	return false
end

local function set_textures(self)
	calls.textures = calls.textures + 1
end

local function remove_job(self)
	self._jobsite = nil
	if not has_traded(self) then
		self._profession = "unemployed"
		self._trades = nil
		set_textures(self)
	end
end

local function validate_jobsite(self)
	if self._profession == "unemployed" then return false end
	if not self._jobsite or claims[key(self._jobsite)] ~= self._id then
		remove_job(self)
		return false
	end
	return true
end

local function get_a_job(self)
	calls.job_search = calls.job_search + 1
	local wanted = {}
	if has_traded(self) then
		wanted[#wanted + 1] = jobsite_of[self._profession]
	else
		wanted[#wanted + 1] = jobsite_of.farmer
	end
	if #wanted == 0 then return end
	if not claims[key(composter)] then
		claims[key(composter)] = self._id
		self._jobsite = composter
		if not has_traded(self) then
			self._profession = "farmer"
			set_textures(self)
		end
		return
	end
	calls.walks = calls.walks + 1
end

local seen_trades
local function vanilla_custom(self, dtime)
	seen_trades = self._trades
	if not night then
		if not validate_jobsite(self) then
			if self._profession == "unemployed" or has_traded(self) then
				get_a_job(self)
				return
			end
		end
	else
		calls.take_bed = calls.take_bed + 1
	end
	return "vanilla-result"
end

local function reset()
	night = false
	claims = {}
	calls = {textures = 0, job_search = 0, walks = 0, take_bed = 0}
end

local def = {do_custom = vanilla_custom}
dofile("nitwit.lua")(def)

-- Sanity check on the stub: unwrapped vanilla demotes a nitwit and puts it to
-- work at the composter on its very first tick, which is the bug.
reset()
local unguarded = {_id = "u", _profession = "nitwit"}
vanilla_custom(unguarded, 0.1)
assert(unguarded._profession == "farmer")
assert(claims[key(composter)] == "u")

-- A nitwit stays a nitwit across repeated daytime activity ticks, claims no
-- jobsite and never walks off to one, even with a free workstation beside it.
reset()
local nitwit = {_id = "n1", _profession = "nitwit"}
for _ = 1, 5 do
	def.do_custom(nitwit, 0.1)
end
assert(nitwit._profession == "nitwit")
assert(nitwit._jobsite == nil)
assert(claims[key(composter)] == nil)
assert(calls.walks == 0)
-- set_textures is how vanilla swaps a villager's skin; it never ran, so the
-- nitwit overlay init.lua picks from _profession is never replaced.
assert(calls.textures == 0)
-- The stand-in trade list lives only for the vanilla call.
assert(nitwit._trades == nil)
assert(seen_trades ~= nil)

-- Also with no free workstation around: still no walk toward a claimed one.
reset()
claims[key(composter)] = "someone-else"
local crowded = {_id = "n2", _profession = "nitwit"}
def.do_custom(crowded, 0.1)
assert(crowded._profession == "nitwit")
assert(calls.walks == 0)

-- Night still runs vanilla's bed logic for a nitwit.
reset()
night = true
local sleepy = {_id = "n3", _profession = "nitwit"}
assert(def.do_custom(sleepy, 0.1) == "vanilla-result")
assert(calls.take_bed == 1)
assert(sleepy._profession == "nitwit")

-- A child nitwit is covered too, so it grows up a nitwit.
reset()
local child = {_id = "n4", _profession = "nitwit", child = true}
def.do_custom(child, 0.1)
assert(child._profession == "nitwit")

-- Whatever _trades held before is put back untouched.
reset()
local odd = {_id = "n5", _profession = "nitwit", _trades = "left-by-another-mod"}
def.do_custom(odd, 0.1)
assert(odd._trades == "left-by-another-mod")

-- Everyone else passes straight through: an unemployed villager still finds
-- the composter, and vanilla sees its real (absent) trade list.
reset()
local unemployed = {_id = "e1", _profession = "unemployed"}
def.do_custom(unemployed, 0.1)
assert(seen_trades == nil)
assert(unemployed._profession == "farmer")
assert(claims[key(composter)] == "e1")

-- A fisherman's trades reach vanilla as they are; fisherman.lua's own guard
-- (#70) handles its teardown, not this one.
reset()
local fisherman = {_id = "f1", _profession = "fisherman", _trades = "real-trades"}
def.do_custom(fisherman, 0.1)
assert(seen_trades == "real-trades")

print("nitwit tests passed")
