local root = debug.getinfo(1, "S").source:sub(2):match("(.*/)tests/") or "./"
local logs, day = {}, 12
local registered = {}

minetest = {
	get_modpath = function() return root end,
	get_day_count = function() return day end,
	registered_items = registered,
	log = function(_, message) logs[#logs + 1] = message end,
}

local market = dofile(root .. "market.lua")
local expected = {
	farmer = {"mcl_farming:bread", "mcl_core:apple"},
	fisherman = {"mcl_fishing:fish_cooked", "mcl_fishing:salmon_cooked"},
	fletcher = {"mcl_bows:arrow", "mcl_bows:bow"},
	shepherd = {"mcl_wool:white", "mcl_tools:shears"},
	librarian = {"mcl_books:book", "mcl_books:bookshelf"},
	cartographer = {"mcl_maps:empty_map", "mcl_itemframes:frame"},
	armorer = {"mcl_armor:helmet_iron", "mcl_armor:boots_iron"},
	leatherworker = {"mcl_armor:helmet_leather", "mcl_armor:boots_leather"},
	butcher = {"mcl_mobitems:cooked_porkchop", "mcl_mobitems:cooked_chicken"},
	weapon_smith = {"mcl_tools:axe_iron", "mcl_tools:sword_iron"},
	tool_smith = {"mcl_tools:pick_stone", "mcl_tools:shovel_stone"},
	cleric = {"mesecons:redstone", "mcl_core:lapis"},
	mason = {"mcl_core:brick", "mcl_core:stonebrick"},
}

for profession, pair in pairs(expected) do
	for _, item in ipairs(pair) do registered[item] = {} end
	local villager = {_profession = profession, _id = profession}
	local got = market.goods_for(villager, {})
	assert(got and got[1] == pair[1] and got[2] == pair[2], profession .. " goods match the supported VoxeLibre item names")
	assert(market.eligible(villager), profession .. " adult is eligible without trade initialization")
end

local farmer = {_profession = "farmer", _id = "f"}
registered["mcl_core:apple"] = nil
local pair = market.goods_for(farmer, {})
assert(pair[1] == "mcl_farming:bread" and pair[2] == pair[1], "one available item fills both frames")
registered["mcl_farming:bread"] = nil
assert(market.goods_for(farmer, {}) == nil, "no available item disables the stall")
registered["mcl_core:apple"] = {}
pair = market.goods_for(farmer, {})
assert(pair[1] == "mcl_core:apple" and pair[2] == pair[1], "available second item fills both frames")
registered["mcl_core:apple"] = nil

local unknown = {_profession = "modded_profession", _id = "u"}
local attempt = {}
assert(market.goods_for(unknown, attempt) == nil)
assert(market.goods_for(unknown, attempt) == nil)
assert(attempt.goods_fallback_logged and #logs == 2, "one missing-goods reason is logged per attempt")

local ok, reason = market.eligible({_profession = "farmer", _id = "child", child = true})
assert(not ok and reason == "child")
ok, reason = market.eligible({_profession = "farmer", _id = "keeper", _villages_keeper = true})
assert(not ok and reason == "keeper")
ok, reason = market.eligible({_profession = "unemployed", _id = "unemployed"})
assert(not ok and reason == "no_goods")
ok, reason = market.eligible({_profession = "nitwit", _id = "nitwit"})
assert(not ok and reason == "no_goods")
ok, reason = market.eligible({_profession = "modded_profession", _id = "unknown"}, {})
assert(not ok and reason == "no_goods")
ok, reason = market.eligible({_profession = "farmer", _id = "following", following = true})
assert(not ok and reason == "following")
ok, reason = market.eligible({_profession = "farmer", _id = "stocked", _villages_market_stock_day = day})
assert(not ok and reason == "already_stocked")

local fisherman = {_profession = "unemployed", _villages_fisherman = true, _id = "fisher"}
assert(market.profession(fisherman) == "fisherman", "stable fisherman flag masks vanilla transient demotion")
registered["mcl_core:apple"] = {}
registered["mcl_farming:bread"] = {}
assert(market.eligible(fisherman), "stable fisherman remains eligible after transient demotion")

local guarded = setmetatable({_profession = "farmer", _id = "guarded"}, {
	__index = function(_, key)
		assert(key ~= "_trades" and key ~= "_jobsite", "eligibility must not inspect trade or job claims")
	end,
})
assert(market.eligible(guarded), "eligibility does not depend on trades or claimed jobsites")

print("market goods and eligibility tests passed")
