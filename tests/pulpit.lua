minetest = {}
-- Luanti's builtin deep copy.
function table.copy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for k, v in pairs(value) do copy[table.copy(k)] = table.copy(v) end
	return copy
end
local nodes, crafts = {}, {}
minetest.registered_nodes = {["mcl_lectern:lectern"] = {
	name = "mcl_lectern:lectern", mod_origin = "mcl_lectern", type = "node",
	description = "Lectern", mesh = "mcl_lectern_lectern.obj", drawtype = "mesh",
	tiles = {"mcl_lectern_lectern.png"}, drops = "mcl_lectern:lectern",
	groups = {handy = 1, axey = 1},
	collision_box = {type = "fixed", fixed = {{-0.32, 0.46, -0.32, 0.32, 0.175, 0.32}}},
	on_place = function() end,
}}
minetest.log = function() end
minetest.register_node = function(name, def) nodes[name] = def end
minetest.register_craft = function(def) crafts[#crafts + 1] = def end
dofile("pulpit.lua")

local lectern, pulpit = minetest.registered_nodes["mcl_lectern:lectern"], nodes["living_villages:pulpit"]
assert(pulpit, "pulpit not registered")
assert(pulpit.mesh == lectern.mesh and pulpit.drawtype == "mesh")
assert(pulpit.collision_box.fixed[1][2] == lectern.collision_box.fixed[1][2], "collision box differs")
assert(pulpit.on_place == lectern.on_place)
assert(pulpit.tiles[1] == "living_villages_pulpit.png" and pulpit.tiles[1] ~= lectern.tiles[1])
assert(pulpit.drops == "living_villages:pulpit")
assert(pulpit.name == nil and pulpit.mod_origin == nil and pulpit.type == nil)
assert(lectern.name == "mcl_lectern:lectern" and lectern.drops == "mcl_lectern:lectern", "lectern must be untouched")
pulpit.groups.handy = nil
assert(lectern.groups.handy == 1, "groups table must not be shared with the lectern")
local craft = crafts[1]
assert(craft.output == "living_villages:pulpit" and craft.type == "shapeless")
assert(craft.recipe[1] == "mcl_lectern:lectern" and craft.recipe[2] == "mcl_wool:purple_carpet")

-- Without a lectern the mod still loads.
nodes = {}
minetest.registered_nodes = {}
dofile("pulpit.lua")
assert(next(nodes) == nil)
print("pulpit tests passed")
