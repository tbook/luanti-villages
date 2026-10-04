-- The church's pulpit (#21). A church needs a centrepiece villagers can
-- recognise, but the stock one is a brewing stand, the cleric's jobsite, and the
-- natural one, the lectern, is the librarian's. This is a lectern in everything
-- but name and jobsite, so librarians ignore it. Registered at load time, not
-- from register_on_mods_loaded: register_node checks the current mod name.
local core = minetest

local lectern = core.registered_nodes["mcl_lectern:lectern"]
if not lectern then
	core.log("warning", "[living_villages] mcl_lectern:lectern is missing; the pulpit was not registered")
	return
end

local pulpit = table.copy(lectern)
for _, field in ipairs({"name", "mod_origin", "type"}) do pulpit[field] = nil end
pulpit.description = "Pulpit"
pulpit._tt_help = "Marks a church for villagers"
pulpit._doc_items_longdesc = "A pulpit stands in a church, where villagers gather to listen. Unlike a lectern, it is not a jobsite for librarians."
pulpit._doc_items_usagehelp = nil
pulpit.tiles = {"living_villages_pulpit.png"}
pulpit.drops = "living_villages:pulpit"
core.register_node("living_villages:pulpit", pulpit)

core.register_craft({
	type = "shapeless",
	output = "living_villages:pulpit",
	recipe = {"mcl_lectern:lectern", "mcl_wool:purple_carpet"},
})

core.register_craft({
	type = "fuel",
	recipe = "living_villages:pulpit",
	burntime = 15,
})
