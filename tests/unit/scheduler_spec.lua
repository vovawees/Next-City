local Scheduler = T.load("core/scheduler.lua")

local function newScheduler(opts)
	local errors = {}
	opts = opts or {}
	opts.onError = function(err, id)
		errors[#errors + 1] = { err = err, id = id }
	end
	return Scheduler.New(opts), errors
end

-- Deterministic pseudo-random numbers (LCG), independent of math.random.
local function lcg(seed)
	local state = seed
	return function(n)
		state = (state * 1103515245 + 12345) % 2147483648
		return state % n
	end
end

describe("scheduler jobs", function()
	it("runs after one interval and then on cadence", function()
		local sched = newScheduler()
		local runs = {}
		sched:Every("tick", 1, function(now, dt) runs[#runs + 1] = { now, dt } end)
		sched:Update(0.5)
		sched:Update(1)
		sched:Update(1.5)
		sched:Update(2.25)
		expect(runs):toEqual({ { 1, 1 }, { 2.25, 1.25 } })
	end)

	it("does not drift and does not burst after a hitch", function()
		local sched = newScheduler()
		local runs = {}
		sched:Every("tick", 1, function(now) runs[#runs + 1] = now end)
		sched:Update(1.25) -- due at 1, next due at 2
		sched:Update(2.1)  -- next due at 3, not 3.1
		sched:Update(10.5) -- hitch: one run, next due at 11.5
		sched:Update(11)
		sched:Update(11.5)
		expect(runs):toEqual({ 1.25, 2.1, 10.5, 11.5 })
	end)

	it("supports phase and delay for the first run", function()
		local sched = newScheduler()
		local runs = {}
		sched:Every("a", 1, function(now) runs[#runs + 1] = "a" .. now end, { phase = 0 })
		sched:Every("b", 1, function(now) runs[#runs + 1] = "b" .. now end, { phase = 0.5 })
		sched:Every("c", 1, function(now) runs[#runs + 1] = "c" .. now end, { delay = 3 })
		sched:Update(0)
		sched:Update(0.5)
		sched:Update(1)
		sched:Update(3)
		expect(runs):toEqual({ "a0", "b0.5", "a1", "a3", "b3", "c3" })
	end)

	it("runs zero-interval jobs on every update", function()
		local sched = newScheduler()
		local count = 0
		sched:Every("frame", 0, function() count = count + 1 end)
		sched:Update(0)
		sched:Update(0.01)
		sched:Update(0.02)
		expect(count):toBe(3)
	end)

	it("replaces jobs by id in place and ignores stale handles", function()
		local sched = newScheduler()
		local runs = {}
		local old = sched:Every("a", 1, function() runs[#runs + 1] = "old" end)
		sched:Every("b", 1, function() runs[#runs + 1] = "b" end)
		sched:Every("a", 1, function() runs[#runs + 1] = "new" end)
		sched:Update(1)
		expect(runs):toEqual({ "new", "b" })
		expect(sched:Remove(old)):toBe(false)
		expect(sched:Has("a")):toBe(true)
		expect(sched:Remove("a")):toBe(true)
		expect(sched:Has("a")):toBe(false)
		expect(sched:Remove("a")):toBe(false)
	end)

	it("skips jobs removed during an update", function()
		local sched = newScheduler()
		local runs = {}
		sched:Every("a", 1, function()
			runs[#runs + 1] = "a"
			sched:Remove("b")
			sched:Every("c", 0, function() runs[#runs + 1] = "c" end, { phase = 0 })
		end)
		sched:Every("b", 1, function() runs[#runs + 1] = "b" end)
		sched:Update(1)
		expect(runs):toEqual({ "a" })
		sched:Update(1.5)
		expect(runs):toEqual({ "a", "c" })
	end)

	it("disables a job after repeated consecutive errors", function()
		local sched, errors = newScheduler({ maxErrors = 3 })
		local fail = true
		local calls = 0
		sched:Every("flaky", 1, function()
			calls = calls + 1
			if fail then
				error("broken")
			end
		end, { phase = 0 })
		sched:Update(0)
		sched:Update(1)
		fail = false
		sched:Update(2) -- success resets the streak
		fail = true
		sched:Update(3)
		sched:Update(4)
		expect(sched:Get("flaky"):IsActive()):toBe(true)
		sched:Update(5)
		expect(sched:Get("flaky"):IsActive()):toBe(false)
		sched:Update(6)
		expect(calls):toBe(6)
		expect(errors[1].id):toBe("flaky")
		expect(errors[1].err):toContain("broken")
		expect(errors[#errors].err):toContain("disabled after 3 consecutive errors")

		sched:Every("flaky", 1, function() calls = calls + 1 end)
		sched:Update(7)
		expect(calls):toBe(7)
	end)

	it("lets errors propagate when unprotected", function()
		local sched = Scheduler.New({ protected = false })
		sched:Every("raw", 0, function() error("raw error") end)
		expect(function() sched:Update(1) end):toFail("raw error")
	end)

	it("validates arguments", function()
		local sched = newScheduler()
		expect(function() sched:Every("", 1, function() end) end):toFail("id")
		expect(function() sched:Every("x", -1, function() end) end):toFail("interval")
		expect(function() sched:Every("x", 0 / 0, function() end) end):toFail("interval")
		expect(function() sched:Every("x", 1, function() end, { phase = 2 }) end):toFail("phase")
		expect(function() sched:After(math.huge, function() end) end):toFail("delay")
	end)
end)

describe("scheduler timers", function()
	it("fires timers by due time, ties in creation order", function()
		local sched = newScheduler()
		local fired = {}
		sched:After(2, function() fired[#fired + 1] = "b" end)
		sched:After(1, function() fired[#fired + 1] = "a1" end)
		sched:After(1, function() fired[#fired + 1] = "a2" end)
		sched:After(3, function() fired[#fired + 1] = "c" end)
		expect(sched:Pending()):toBe(4)
		sched:Update(2)
		expect(fired):toEqual({ "a1", "a2", "b" })
		sched:Update(5)
		expect(fired):toEqual({ "a1", "a2", "b", "c" })
		expect(sched:Pending()):toBe(0)
	end)

	it("cancels timers", function()
		local sched = newScheduler()
		local fired = {}
		local t1 = sched:After(1, function() fired[#fired + 1] = 1 end)
		sched:After(1, function() fired[#fired + 1] = 2 end)
		expect(t1:Cancel()):toBe(true)
		expect(t1:Cancel()):toBe(false)
		expect(t1:IsPending()):toBe(false)
		sched:Update(1)
		expect(fired):toEqual({ 2 })
	end)

	it("defers timers created during an update", function()
		local sched = newScheduler()
		local fired = {}
		sched:After(0, function()
			fired[#fired + 1] = "first"
			sched:After(0, function() fired[#fired + 1] = "second" end)
		end)
		sched:Update(0)
		expect(fired):toEqual({ "first" })
		sched:Update(0)
		expect(fired):toEqual({ "first", "second" })
	end)

	it("keeps heap order under random inserts and cancels", function()
		local sched = newScheduler()
		local random = lcg(7)
		local fired = {}
		local timers = {}
		for i = 1, 300 do
			local at = random(1000) / 10
			timers[i] = sched:After(at, function(now) fired[#fired + 1] = { at = at, now = now } end)
		end
		local cancelled = 0
		for i = 1, 300, 3 do
			if timers[i]:Cancel() then
				cancelled = cancelled + 1
			end
		end
		expect(sched:Pending()):toBe(300 - cancelled)
		for step = 1, 1000 do
			sched:Update(step / 10)
		end
		expect(#fired):toBe(300 - cancelled)
		for i = 2, #fired do
			expect(fired[i - 1].at <= fired[i].at):toBe(true)
		end
		for i = 1, #fired do
			expect(fired[i].now >= fired[i].at):toBe(true)
		end
	end)

	it("reports timer errors and continues", function()
		local sched, errors = newScheduler()
		local fired = false
		sched:After(0, function() error("timer broke") end, "mod")
		sched:After(0, function() fired = true end)
		sched:Update(0)
		expect(fired):toBe(true)
		expect(errors[1].id):toBe("mod")
		expect(errors[1].err):toContain("timer broke")
	end)
end)

describe("scheduler time and stats", function()
	it("keeps relative times when the clock goes backwards", function()
		local sched = newScheduler({ now = 100 })
		local runs = {}
		sched:Every("tick", 1, function(now) runs[#runs + 1] = now end)
		local fired = false
		sched:After(2, function() fired = true end)
		sched:Update(100.5)
		sched:Update(0) -- reset: the job is due in 0.5, the timer in 1.5
		sched:Update(0.5)
		sched:Update(1.5)
		expect(runs):toEqual({ 0.5, 1.5 })
		expect(fired):toBe(true)
	end)

	it("profiles jobs and timers with the injected clock", function()
		local fake = 0
		local sched = newScheduler({ clock = function() return fake end })
		sched:Every("heavy", 1, function() fake = fake + 0.003 end)
		sched:Every("light", 1, function() fake = fake + 0.001 end)
		sched:After(1, function() fake = fake + 0.0025 end, "mod")
		sched:Update(1)
		sched:Update(2)
		local stats = sched:Stats()
		expect(stats[1].id):toBe("heavy")
		expect(stats[1].calls):toBe(2)
		expect(stats[1].total):toBeCloseTo(0.006)
		expect(stats[1].avg):toBeCloseTo(0.003)
		expect(stats[1].max):toBeCloseTo(0.003)
		expect(stats[2].id):toBe("mod")
		expect(stats[2].kind):toBe("timer")
		expect(stats[3].id):toBe("light")
		sched:ResetStats()
		stats = sched:Stats()
		expect(#stats):toBe(2)
		expect(stats[1].calls + stats[2].calls):toBe(0)
	end)
end)
