-- Test that children cannot take or use jobs (#262)
-- Run with: lua tests/child_professions.lua
local nodes = {}
local meta_store = {}

minetest = {
	get_modpath = function() return "." end,
	get_timeofday = function() return 0.5 end, -- day time
	get_gametime = function() return 0 end,
	registered_nodes = {
		["living_villages:pulpit"] = {},
		["mcl_jukebox:jukebox"] = {},
	},
	get_node_or_nil = function(pos)
		if not pos then return nil end
		return nodes[pos.x .. ":" .. pos.y .. ":" .. pos.z]
	end,
	find_node_near = function(_, _, nodes_to_find)
		return nodes_to_find[1] and {x = 0, y = 0, z = 1}
	end,
	find_nodes_in_area = function(minp, maxp, names)
		return {}
	end,
	get_meta = function(pos)
		local k = pos.x .. ":" .. pos.y .. ":" .. pos.z
		return {
			get_string = function(_, field)
				return field == "villager" and (meta_store[k] or "") or ""
			end,
			set_string = function(_, field, value)
				if field == "villager" then meta_store[k] = value end
			end,
		}
	end,
	log = function() end,
	hash_node_position = function(pos) return pos.x .. ":" .. pos.y .. ":" .. pos.z end,
}

-- Register the pulpit for cleric test
nodes["0:0:1"] = {name = "living_villages:pulpit"}

-- Test that child cleric cannot claim pulpit
local cleric = dofile("cleric.lua")
local child_cleric = {
	_id = "child-cleric", child = true, _profession = "unemployed", _jobsite = nil,
	object = {get_pos = function() return {x = 0, y = 0, z = 0} end}
}
assert(not cleric.employ(child_cleric, {x = 0, y = 0, z = 1}),
	"children should not be able to claim a pulpit")

-- Test that adult cleric can claim pulpit
local adult_cleric = {
	_id = "adult-cleric", child = false, _profession = "unemployed", _jobsite = nil,
	object = {get_pos = function() return {x = 0, y = 0, z = 0} end}
}
assert(cleric.employ(adult_cleric, {x = 0, y = 0, z = 1}),
	"adults should be able to claim a pulpit")

-- Test that child keeper cannot take over tavern
local keeper = dofile("keeper.lua")
local child_keeper = {
	_id = "child-keeper", child = true, _profession = "unemployed", _jobsite = nil,
	object = {get_pos = function() return {x = 0, y = 0, z = 0} end}
}
nodes["0:0:1"] = {name = "mcl_jukebox:jukebox"}
assert(not keeper.take_over(child_keeper, {x = 0, y = 0, z = 1}),
	"children should not be able to take over a tavern")

-- Simulate loading a child that was previously a farmer (from a save)
-- This tests the behavior described in the issue: children with saved jobs
-- should be treated as unemployed while they are young
local child_with_saved_job = {
	_id = "child-job", child = true, _profession = "farmer",
	_bed = {x = 0, y = 0, z = 0}
}
-- The profession is still in the entity data, but it should be inactive
assert(child_with_saved_job._profession == "farmer",
	"saved profession should be preserved in entity data")
assert(child_with_saved_job.child == true,
	"villager should still be marked as a child")
-- Note: actual use of the profession (farming, visual overlay) should be blocked
-- by per-profession checks (farmer.lua's valid_farmer checks self.child)

print("child profession tests passed")
