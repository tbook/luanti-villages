-- Representative market goods and seller eligibility (#291).
-- This module does not initialize or inspect villager trades.
local core = minetest

local goods = {
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

local M = {}

function M.profession(villager)
	if villager._villages_fisherman then return "fisherman" end
	return villager._profession
end

local function log_fallback(reason, attempt)
	if attempt and attempt.goods_fallback_logged then return end
	if attempt then attempt.goods_fallback_logged = true end
	core.log("action", "[living_villages] market seller browsing: " .. reason)
end

-- `attempt` is the transient session object, allowing the controller to log
-- just one fallback reason even if it retries the lookup during that attempt.
function M.goods_for(villager, attempt)
	local profession = M.profession(villager)
	local pair = goods[profession]
	if not pair then
		log_fallback("unsupported profession " .. tostring(profession or "unemployed"), attempt)
		return nil, "unsupported_profession"
	end
	local first = core.registered_items[pair[1]] and pair[1]
	local second = core.registered_items[pair[2]] and pair[2]
	if first and second then return {first, second} end
	if first then return {first, first} end
	if second then return {second, second} end
	log_fallback("no registered goods for " .. profession, attempt)
	return nil, "missing_goods"
end

function M.eligible(villager, attempt)
	if villager.child or villager._is_baby then return false, "child" end
	if villager._villages_keeper then return false, "keeper" end
	if not villager._id then return false, "missing_id" end
	if villager.following then return false, "following" end
	local day = core.get_day_count and core.get_day_count()
	if day ~= nil and villager._villages_market_stock_day == day then return false, "already_stocked" end
	if not M.goods_for(villager, attempt) then return false, "no_goods" end
	return true
end

return M
