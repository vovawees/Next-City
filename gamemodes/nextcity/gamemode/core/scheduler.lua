-- Next-City core: periodic jobs and one-shot timers driven by a single update call.
--
-- Pure Lua (LuaJIT 2.x), no GMod API.
--
--   local sched = Scheduler.New({ now = CurTime(), clock = SysTime })
--   sched:Every("organism.tick", 0.1, function(now, dt) ... end, { phase = 0.5 })
--   local timer = sched:After(3, function(now) ... end)
--   timer:Cancel()
--   sched:Update(CurTime()) -- called from one engine hook
--
-- Jobs:
--   * the first run happens after one interval, or after `interval * phase` (phase 0..1)
--     or after `delay` seconds; phases spread jobs with equal intervals across ticks;
--   * the cadence does not drift, and after a hitch a job runs once instead of bursting;
--   * `fn(now, dt)` gets the time since its previous run;
--   * registering a job with an existing id replaces it, keeping its place in the order;
--   * a job that fails `maxErrors` times in a row is disabled (circuit breaker) instead of
--     spamming errors every tick; registering it again re-enables it.
-- Timers:
--   * ordered by due time in a min-heap, ties run in creation order;
--   * a timer created during an update runs on a later update, so timers cannot starve
--     the loop.
-- With `clock` (a high-resolution time function) every job and timer tag is profiled.

local Scheduler = {}

local type = type
local tostring = tostring
local xpcall = xpcall
local pcall = pcall
local print = print
local setmetatable = setmetatable
local floor = math.floor
local traceback = debug.traceback

local DEFAULT_MAX_ERRORS = 5

local function onJobError(err)
	return traceback(tostring(err), 2)
end

local function defaultOnError(err, id)
	print("[scheduler] '" .. tostring(id) .. "' failed: " .. tostring(err))
end

local function report(sched, id, err)
	local ok, handlerErr = pcall(sched.onError, err, id)
	if not ok then
		print("[scheduler] onError failed: " .. tostring(handlerErr) .. "\n" .. tostring(err))
	end
end

local function isTime(v)
	return type(v) == "number" and v == v and v >= 0 and v < math.huge
end

-- Min-heap of timers ordered by (at, seq); every timer knows its index for O(log n) removal.

local function before(a, b)
	return a.at < b.at or (a.at == b.at and a.seq < b.seq)
end

local function siftUp(heap, i)
	local item = heap[i]
	while i > 1 do
		local parentIndex = floor(i / 2)
		local parent = heap[parentIndex]
		if not before(item, parent) then
			break
		end
		heap[i] = parent
		parent.index = i
		i = parentIndex
	end
	heap[i] = item
	item.index = i
end

local function siftDown(heap, size, i)
	local item = heap[i]
	while true do
		local child = i * 2
		if child > size then
			break
		end
		if child < size and before(heap[child + 1], heap[child]) then
			child = child + 1
		end
		if not before(heap[child], item) then
			break
		end
		heap[i] = heap[child]
		heap[i].index = i
		i = child
	end
	heap[i] = item
	item.index = i
end

local function heapRemove(sched, i)
	local heap = sched.heap
	local size = sched.size
	local removed = heap[i]
	local last = heap[size]
	heap[size] = nil
	sched.size = size - 1
	removed.index = nil
	if i < size then
		heap[i] = last
		last.index = i
		if i > 1 and before(last, heap[floor(i / 2)]) then
			siftUp(heap, i)
		else
			siftDown(heap, size - 1, i)
		end
	end
	return removed
end

local Timer = {}
Timer.__index = Timer

-- Cancels the timer. Returns true if it was still pending.
function Timer:Cancel()
	if self.index == nil then
		return false
	end
	heapRemove(self.scheduler, self.index)
	return true
end

function Timer:IsPending()
	return self.index ~= nil
end

local Job = {}
Job.__index = Job

-- Removes the job. Returns true if it was registered.
function Job:Remove()
	return self.scheduler:Remove(self)
end

function Job:IsActive()
	return self.active and not self.disabled
end

local Instance = {}
Instance.__index = Instance

-- opts: now (initial time, default 0), clock (profiling time function),
-- maxErrors (default 5), onError(err, id), protected (false lets errors propagate).
function Scheduler.New(opts)
	opts = opts or {}
	local now = opts.now or 0
	assert(type(now) == "number", "Scheduler.New: now must be a number")
	assert(opts.clock == nil or type(opts.clock) == "function", "Scheduler.New: clock must be a function")
	assert(opts.onError == nil or type(opts.onError) == "function", "Scheduler.New: onError must be a function")
	local maxErrors = opts.maxErrors or DEFAULT_MAX_ERRORS
	assert(type(maxErrors) == "number" and maxErrors >= 1, "Scheduler.New: maxErrors must be >= 1")
	return setmetatable({
		now = now,
		clock = opts.clock,
		maxErrors = maxErrors,
		onError = opts.onError or defaultOnError,
		protected = opts.protected ~= false,
		jobs = {}, -- copy-on-write array in registration order
		byId = {},
		heap = {},
		size = 0,
		seq = 0,
		timerStats = {},
	}, Instance)
end

function Instance:Now()
	return self.now
end

-- Registers a periodic job. opts: phase (0..1), delay (seconds), maxErrors.
function Instance:Every(id, interval, fn, opts)
	assert(type(id) == "string" and id ~= "", "Scheduler:Every: id must be a non-empty string")
	assert(isTime(interval), "Scheduler:Every: interval of '" .. id .. "' must be a finite number >= 0")
	assert(type(fn) == "function", "Scheduler:Every: job '" .. id .. "' must be a function")

	local firstDelay = interval
	local maxErrors = self.maxErrors
	if opts ~= nil then
		assert(type(opts) == "table", "Scheduler:Every: opts must be a table")
		if opts.delay ~= nil then
			assert(isTime(opts.delay), "Scheduler:Every: delay of '" .. id .. "' must be a finite number >= 0")
			firstDelay = opts.delay
		elseif opts.phase ~= nil then
			assert(type(opts.phase) == "number" and opts.phase >= 0 and opts.phase <= 1,
				"Scheduler:Every: phase of '" .. id .. "' must be within 0..1")
			firstDelay = interval * opts.phase
		end
		if opts.maxErrors ~= nil then
			assert(type(opts.maxErrors) == "number" and opts.maxErrors >= 1, "Scheduler:Every: maxErrors must be >= 1")
			maxErrors = opts.maxErrors
		end
	end

	local job = setmetatable({
		scheduler = self,
		id = id,
		interval = interval,
		fn = fn,
		nextAt = self.now + firstDelay,
		lastAt = self.now,
		maxErrors = maxErrors,
		active = true,
		disabled = false,
		streak = 0, -- consecutive errors
		calls = 0,
		errors = 0,
		total = 0,
		max = 0,
	}, Job)

	local jobs = self.jobs
	local out = {}
	local replaced = false
	for i = 1, #jobs do
		if jobs[i].id == id then
			jobs[i].active = false
			out[i] = job
			replaced = true
		else
			out[i] = jobs[i]
		end
	end
	if not replaced then
		out[#jobs + 1] = job
	end
	self.jobs = out
	self.byId[id] = job
	return job
end

-- Removes a job by id or handle. A stale handle (replaced job) does not remove the new one.
function Instance:Remove(target)
	local job
	if type(target) == "table" then
		job = target
		if self.byId[job.id] ~= job then
			return false
		end
	else
		job = self.byId[target]
		if job == nil then
			return false
		end
	end
	job.active = false
	self.byId[job.id] = nil
	local jobs = self.jobs
	local out = {}
	for i = 1, #jobs do
		if jobs[i] ~= job then
			out[#out + 1] = jobs[i]
		end
	end
	self.jobs = out
	return true
end

function Instance:Has(id)
	return self.byId[id] ~= nil
end

function Instance:Get(id)
	return self.byId[id]
end

-- Schedules `fn(now)` to run once after `delay` seconds. `tag` groups timers in Stats.
function Instance:After(delay, fn, tag)
	assert(isTime(delay), "Scheduler:After: delay must be a finite number >= 0")
	assert(type(fn) == "function", "Scheduler:After: callback must be a function")
	assert(tag == nil or type(tag) == "string", "Scheduler:After: tag must be a string")
	self.seq = self.seq + 1
	local timer = setmetatable({
		scheduler = self,
		at = self.now + delay,
		seq = self.seq,
		fn = fn,
		tag = tag or "timer",
	}, Timer)
	local size = self.size + 1
	self.size = size
	self.heap[size] = timer
	siftUp(self.heap, size)
	return timer
end

-- Number of pending timers.
function Instance:Pending()
	return self.size
end

local function shiftTime(sched, delta)
	local jobs = sched.jobs
	for i = 1, #jobs do
		jobs[i].nextAt = jobs[i].nextAt + delta
		jobs[i].lastAt = jobs[i].lastAt + delta
	end
	local heap = sched.heap
	for i = 1, sched.size do
		heap[i].at = heap[i].at + delta
	end
end

local function runJob(sched, job, now, dt)
	if not sched.protected then
		job.calls = job.calls + 1
		job.fn(now, dt)
		return
	end
	local clock = sched.clock
	local started = clock and clock()
	local ok, err = xpcall(job.fn, onJobError, now, dt)
	if clock then
		local spent = clock() - started
		job.total = job.total + spent
		if spent > job.max then
			job.max = spent
		end
	end
	job.calls = job.calls + 1
	if ok then
		job.streak = 0
		return
	end
	job.errors = job.errors + 1
	job.streak = job.streak + 1
	report(sched, job.id, err)
	if job.streak >= job.maxErrors then
		job.disabled = true
		report(sched, job.id, "disabled after " .. job.streak .. " consecutive errors")
	end
end

local function timerStats(sched, tag)
	local stats = sched.timerStats[tag]
	if stats == nil then
		stats = { calls = 0, errors = 0, total = 0, max = 0 }
		sched.timerStats[tag] = stats
	end
	return stats
end

local function runTimer(sched, timer, now)
	local stats = timerStats(sched, timer.tag)
	stats.calls = stats.calls + 1
	if not sched.protected then
		timer.fn(now)
		return
	end
	local clock = sched.clock
	local started = clock and clock()
	local ok, err = xpcall(timer.fn, onJobError, now)
	if clock then
		local spent = clock() - started
		stats.total = stats.total + spent
		if spent > stats.max then
			stats.max = spent
		end
	end
	if not ok then
		stats.errors = stats.errors + 1
		report(sched, timer.tag, err)
	end
end

-- Advances time to `now` and runs due jobs (in registration order), then due timers.
function Instance:Update(now)
	assert(type(now) == "number" and now == now, "Scheduler:Update: now must be a number")
	if now < self.now then
		-- The clock went backwards (e.g. a reset): keep relative times.
		shiftTime(self, now - self.now)
	end
	self.now = now

	local jobs = self.jobs
	for i = 1, #jobs do
		local job = jobs[i]
		if job.active and not job.disabled and job.nextAt <= now then
			local dt = now - job.lastAt
			local nextAt = job.nextAt + job.interval
			if nextAt <= now then
				nextAt = now + job.interval
			end
			job.nextAt = nextAt
			job.lastAt = now
			runJob(self, job, now, dt)
		end
	end

	local limit = self.seq
	local heap = self.heap
	while self.size > 0 do
		local timer = heap[1]
		if timer.at > now or timer.seq > limit then
			break
		end
		heapRemove(self, 1)
		runTimer(self, timer, now)
	end
end

-- Returns profiling rows sorted by total time (then id):
-- { id, kind = "job" | "timer", interval, calls, errors, total, max, avg, disabled }.
function Instance:Stats()
	local rows = {}
	local jobs = self.jobs
	for i = 1, #jobs do
		local job = jobs[i]
		rows[#rows + 1] = {
			id = job.id,
			kind = "job",
			interval = job.interval,
			calls = job.calls,
			errors = job.errors,
			total = job.total,
			max = job.max,
			avg = job.calls > 0 and job.total / job.calls or 0,
			disabled = job.disabled,
		}
	end
	for tag, stats in pairs(self.timerStats) do
		rows[#rows + 1] = {
			id = tag,
			kind = "timer",
			calls = stats.calls,
			errors = stats.errors,
			total = stats.total,
			max = stats.max,
			avg = stats.calls > 0 and stats.total / stats.calls or 0,
			disabled = false,
		}
	end
	table.sort(rows, function(a, b)
		if a.total ~= b.total then
			return a.total > b.total
		end
		if a.id ~= b.id then
			return a.id < b.id
		end
		return a.kind < b.kind
	end)
	return rows
end

function Instance:ResetStats()
	local jobs = self.jobs
	for i = 1, #jobs do
		local job = jobs[i]
		job.calls, job.errors, job.total, job.max = 0, 0, 0, 0
	end
	self.timerStats = {}
end

return Scheduler
