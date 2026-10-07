local settings = {}
local logged = {}
local steps = {}
minetest = {
	settings = {get = function(_, name) return settings[name] end},
	register_globalstep = function(callback) table.insert(steps, callback) end,
	log = function(_, message) table.insert(logged, message) end,
}
local queue = dofile("route_queue.lua")
local planner = dofile("planner.lua")
assert(#steps == 1, "the queue steps itself")

-- A fake clock that advances only when a job "works", so budgets are exact.
local time = 0
queue.clock = function() return time end
local function work(ms) time = time + ms / 1000 end

-- Outside a job a checkpoint does nothing.
queue.checkpoint()

-- Jobs run across steps, each stepping aside after its slice: two long jobs
-- both progress, and a short one submitted later finishes before the long ones.
local order = {}
local function job(name, chunks)
	return function()
		for _ = 1, chunks do
			work(1)
			queue.checkpoint()
		end
		return name
	end
end
local function finished(name) return function(result) assert(result == name); table.insert(order, name) end end
queue.submit(job("long1", 40), finished("long1"))
queue.submit(job("long2", 40), finished("long2"))
queue.submit(job("short", 2), finished("short"))
local step_count = 0
while queue.pending() > 0 do
	local ms = queue.step()
	step_count = step_count + 1
	assert(ms <= 5, "a step stays near its budget: " .. ms)
	assert(step_count < 1000)
	time = time + 0.016
end
assert(order[1] == "short", "a short job is not held up by long ones: " .. table.concat(order, ","))
assert(#order == 3)
assert(step_count > 10, "long jobs span many steps")
assert(queue.stats.max_step_ms <= 5)

-- The budget is a setting.
settings.living_villages_route_budget_ms = "10"
local done = false
queue.submit(job("big", 100), function() done = true end)
local ms = queue.step()
assert(ms > 5 and ms <= 11, "a larger budget runs longer: " .. ms)
settings.living_villages_route_budget_ms = nil
assert(queue.drain() and done)

-- A job whose owner has moved on is dropped without running or finishing.
local ran, finished_any = false, false
local alive = true
queue.submit(function() ran = true end, function() finished_any = true end, {valid = function() return alive end})
alive = false
assert(queue.drain())
assert(not ran and not finished_any)

-- An error is logged and reported, and does not stop other jobs.
local err, other = nil, false
queue.submit(function() error("boom") end, function() end, {on_error = function(m) err = m end})
queue.submit(function() return 1 end, function() other = true end)
assert(queue.drain())
assert(err and err:find("boom") and other and logged[#logged]:find("route job failed"))

-- The planner pauses a search through the queue and gets the same answer.
local function can_stand(pos) return pos.y == 1 and pos.x >= 0 and pos.x <= 400 and pos.z == 0 end
local function search(options)
	options.range = 400
	return planner.find_path({x = 0, y = 1, z = 0}, can_stand, function(pos) return pos.x == 300 end, options)
end
local direct = search({})
local result
local before = queue.stats.jobs
queue.submit(function()
	return search({checkpoint = function() work(1); queue.checkpoint() end})
end, function(path) result = path end)
local slices = 0
while queue.pending() > 0 do queue.step(); slices = slices + 1; time = time + 0.016 end
assert(result and #result == #direct, "a paused search finds the same route")
assert(slices > 2, "and takes several steps to do it: " .. slices)
assert(queue.stats.jobs == before + 1)
print("route_queue.lua: ok")
