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

-- Runs `fn()` in a later step, then `done(...)` with what it returned. `opts`:
-- `valid()` is asked before every turn, and a job whose answer is false is
-- dropped without calling anything (its villager moved on or was removed);
-- `on_error(message)` is called if `fn` raises.
function queue.submit(fn, done, opts)
	opts = opts or {}
	local job = {
		co = coroutine.create(fn), done = done, valid = opts.valid, on_error = opts.on_error,
		queued_at = queue.clock(),
	}
	table.insert(pending, job)
	if #pending > stats.max_pending then stats.max_pending = #pending end
	return job
end

function queue.step(budget_seconds)
	local started = queue.clock()
	local deadline = started + (budget_seconds or budget())
	stats.steps = stats.steps + 1
	local ran = false
	-- Turns go round the queue until the budget is spent.
	while #pending > 0 and queue.clock() < deadline do
		local job = table.remove(pending, 1)
		if job.valid and not job.valid() then
			-- dropped
		else
			ran = true
			running, slice_end = job, math.min(deadline, queue.clock() + SLICE_SECONDS)
			local result = {coroutine.resume(job.co)}
			running = nil
			if not result[1] then
				core.log("warning", "[living_villages] route job failed: " .. tostring(result[2]))
				if job.on_error then job.on_error(result[2]) end
			elseif coroutine.status(job.co) == "dead" then
				stats.jobs = stats.jobs + 1
				stats.max_wait = math.max(stats.max_wait, queue.clock() - job.queued_at)
				job.done(unpack(result, 2))
			else
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
