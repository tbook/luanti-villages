local core = minetest

-- Time-sliced route planning (#162). A planner search can take hundreds of
-- milliseconds, and in #113 a village of unemployed villagers stalled the
-- server for seconds. Searches run here instead, as coroutines taken in turn
-- from one queue under a per-server-step budget. A job that has used its slice
-- goes to the back, so one long search cannot hold up the rest. The villager
-- that asked stands still until its job is done.
--
-- A job calls `queue.checkpoint()` at points where it can safely wait (the
-- planner does, every few nodes); outside a job that is a no-op, so the same
-- code also runs synchronously.
local queue = {}

local DEFAULT_BUDGET_MS = 4
-- The longest one job runs before it yields its turn.
local SLICE_SECONDS = 0.001

queue.clock = os.clock

local pending = {}
local running, slice_end
local stats = {steps = 0, busy_steps = 0, max_step_ms = 0, jobs = 0, max_wait = 0, max_pending = 0}
queue.stats = stats
local next_job_id = 0
local completed = {}

local function game_time()
	return core.get_gametime and core.get_gametime() or 0
end

-- One setting for the step budget, read each step so it can change live.
local function budget()
	local ms = tonumber(core.settings and core.settings:get("living_villages_route_budget_ms"))
	return (ms and ms > 0 and ms or DEFAULT_BUDGET_MS) / 1000
end

function queue.checkpoint()
	if running and queue.clock() >= slice_end then coroutine.yield() end
end

function queue.pending()
	return #pending
end

-- Read-only snapshots for the privileged lookup tool. Times are server game
-- seconds: they stop while the game is paused and persist with the world.
function queue.inspect(job)
	if not job then return nil end
	local live = job == running
	if not live then
		for _, queued in ipairs(pending) do
			if queued == job then live = true; break end
		end
	end
	if job.state == "completed" or job.state == "failed" or job.state == "canceled" then live = false end
	return {
		id = job.id, state = job.state, live = live, resumes = job.resumes,
		submitted_at = job.submitted_at, last_resume_at = job.last_resume_at,
		finished_at = job.finished_at, error = job.error,
	}
end

function queue.inspect_id(id)
	if running and running.id == id then return queue.inspect(running) end
	for _, job in ipairs(pending) do
		if job.id == id then return queue.inspect(job) end
	end
end

function queue.cancel(id)
	local job
	if running and running.id == id then job = running end
	if not job then
		for _, queued in ipairs(pending) do
			if queued.id == id then job = queued; break end
		end
	end
	if not job or job.state == "completed" or job.state == "failed" or job.state == "canceled" then return false end
	-- Keep the queue slot in place: cancellation only marks the exact job
	-- invalid and the normal round-robin step discards it when its turn comes.
	job.state, job.finished_at = "canceled", game_time()
	if job.on_state then job.on_state(job.state, job) end
	return true
end

local function state(job, value)
	job.state = value
	if job.on_state then job.on_state(value, job) end
end

function queue.diagnostics()
	local now, recent = game_time(), 0
	local second = math.floor(now)
	for offset = 0, 59 do
		local bucket = completed[(second - offset) % 60]
		if bucket and second - offset == bucket.second then recent = recent + bucket.count end
	end
	return {pending = #pending, completed_last_minute = recent}
end

-- Runs `fn()` in a later step, then `done(...)` with what it returned. `opts`:
-- `valid()` is asked before every turn, and a job whose answer is false is
-- dropped without calling anything (its villager moved on or was removed);
-- `on_error(message)` is called if `fn` raises.
function queue.submit(fn, done, opts)
	opts = opts or {}
	next_job_id = next_job_id + 1
	local job = {
		co = coroutine.create(fn), done = done, valid = opts.valid, on_error = opts.on_error,
		on_state = opts.on_state,
		id = next_job_id, state = "waiting", resumes = 0,
		submitted_at = game_time(), queued_at = queue.clock(),
	}
	if job.on_state then job.on_state(job.state, job) end
	table.insert(pending, job)
	if #pending > stats.max_pending then stats.max_pending = #pending end
	return job
end

local function pack(...)
	return {n = select("#", ...), ...}
end

function queue.step(budget_seconds)
	local started = queue.clock()
	local deadline = started + (budget_seconds or budget())
	stats.steps = stats.steps + 1
	local ran = false
	-- Turns go round the queue until the budget is spent.
	while #pending > 0 and queue.clock() < deadline do
		local job = table.remove(pending, 1)
		if job.state == "canceled" or (job.valid and not job.valid()) then
			job.finished_at = job.finished_at or game_time()
			state(job, "canceled")
			job.co, job.done, job.valid, job.on_error, job.on_state = nil, nil, nil, nil, nil
		else
			ran = true
			job.resumes = job.resumes + 1
			job.last_resume_at = game_time()
			state(job, "running")
			running, slice_end = job, math.min(deadline, queue.clock() + SLICE_SECONDS)
			-- Packed with its length: a failed search returns nil, nil, reason, so the table has
			-- holes and #result may stop before the reason and the report.
			local result = pack(coroutine.resume(job.co))
			running = nil
			if not result[1] then
				job.finished_at, job.error = game_time(), tostring(result[2])
				state(job, "failed")
				core.log("warning", "[living_villages] route job failed: " .. tostring(result[2]))
				local on_error = job.on_error
				job.co, job.done, job.valid, job.on_error, job.on_state = nil, nil, nil, nil, nil
				if on_error then on_error(result[2]) end
			elseif coroutine.status(job.co) == "dead" then
				job.finished_at = game_time()
				state(job, "completed")
				local second = math.floor(job.finished_at)
				local bucket = completed[second % 60]
				if not bucket or bucket.second ~= second then bucket = {second = second, count = 0}; completed[second % 60] = bucket end
				bucket.count = bucket.count + 1
				stats.jobs = stats.jobs + 1
				stats.max_wait = math.max(stats.max_wait, queue.clock() - job.queued_at)
				local done = job.done
				job.co, job.done, job.valid, job.on_error, job.on_state = nil, nil, nil, nil, nil
				if done then done(unpack(result, 2, result.n)) end
			else
				state(job, "yielded")
				table.insert(pending, job)
			end
		end
	end
	local ms = (queue.clock() - started) * 1000
	if ran then stats.busy_steps = stats.busy_steps + 1 end
	if ms > stats.max_step_ms then stats.max_step_ms = ms end
	return ms
end

-- Runs everything to completion; for tests and tools.
function queue.drain(limit)
	for _ = 1, limit or 10000 do
		if #pending == 0 then return true end
		queue.step(math.huge)
	end
	return #pending == 0
end

if core.register_globalstep then
	core.register_globalstep(function() queue.step() end)
end

return queue
