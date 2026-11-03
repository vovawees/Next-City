local FSM = T.load("core/fsm.lua")

local function recorder()
	local log = {}
	local function add(text)
		log[#log + 1] = text
	end
	return log, add
end

describe("fsm", function()
	it("enters the initial state and follows whitelisted transitions", function()
		local log, add = recorder()
		local owner = {}
		local fsm = FSM.New({
			initial = "idle",
			states = {
				idle = {
					to = { "run" },
					enter = function(m, from) add("enter idle from " .. tostring(from)) end,
					exit = function(m, to) add("exit idle to " .. to) end,
				},
				run = {
					to = { "idle" },
					enter = function(m, from, speed) add("enter run from " .. from .. " at " .. speed) end,
				},
			},
			onChange = function(m, from, to) add("change " .. from .. ">" .. to) end,
		}, owner)
		expect(fsm.owner):toBe(owner)
		expect(fsm:Get()):toBe("idle")
		local ok = fsm:Go("run", 5)
		expect(ok):toBe(true)
		expect(fsm:Is("run")):toBe(true)
		expect(fsm:Previous()):toBe("idle")
		expect(log):toEqual({
			"enter idle from nil",
			"exit idle to run",
			"enter run from idle at 5",
			"change idle>run",
		})
	end)

	it("rejects transitions that are not whitelisted", function()
		local fsm = FSM.New({
			initial = "a",
			states = { a = { to = { "b" } }, b = {}, c = {} },
		})
		local ok, reason = fsm:Go("c")
		expect(ok):toBe(false)
		expect(reason):toContain("'a' -> 'c' is not allowed")
		expect(fsm:CanGo("b")):toBe(true)
		expect(fsm:CanGo("a")):toBe(false)
		expect(fsm:CanGo("missing")):toBe(false)
		expect(fsm:Get()):toBe("a")
	end)

	it("allows 'any' targets from every other state", function()
		local fsm = FSM.New({
			initial = "a",
			states = { a = { to = { "b" } }, b = {}, aborted = { to = { "a" } } },
			any = { "aborted" },
		})
		expect(fsm:Go("b")):toBe(true)
		expect(fsm:Go("aborted")):toBe(true)
		expect(fsm:CanGo("aborted")):toBe(false)
		expect(fsm:Go("a")):toBe(true)
	end)

	it("queues transitions requested from callbacks (run-to-completion)", function()
		local log, add = recorder()
		local fsm
		fsm = FSM.New({
			initial = "a",
			states = {
				a = { to = { "b" } },
				b = {
					to = { "c" },
					enter = function(m)
						local ok, status = m:Go("c")
						add("requested c: " .. tostring(ok) .. " " .. tostring(status))
						add("still in " .. m:Get())
					end,
				},
				c = { enter = function(m, from) add("entered c from " .. from) end },
			},
		})
		fsm:Go("b")
		expect(fsm:Get()):toBe("c")
		expect(log):toEqual({ "requested c: true queued", "still in b", "entered c from b" })
	end)

	it("stops transition loops after MAX_CHAIN", function()
		local errors = {}
		local fsm = FSM.New({
			initial = "a",
			states = {
				a = { to = { "b" }, enter = function(m) m:Go("b") end },
				b = { to = { "a" }, enter = function(m) m:Go("a") end },
			},
			onError = function(err) errors[#errors + 1] = err end,
		})
		expect(#errors):toBe(1)
		expect(errors[1]):toContain("chained transitions")
		expect(fsm:Is("a") or fsm:Is("b")):toBe(true)
		expect(#fsm.queue):toBe(0)
	end)

	it("reports callback errors and still completes the transition", function()
		local errors = {}
		local fsm = FSM.New({
			initial = "a",
			states = {
				a = { to = { "b" }, exit = function() error("exit broke") end },
				b = { enter = function() error("enter broke") end },
			},
			onError = function(err, m) errors[#errors + 1] = { err = err, state = m:Get() } end,
		})
		expect(fsm:Go("b")):toBe(true)
		expect(fsm:Get()):toBe("b")
		expect(#errors):toBe(2)
		expect(errors[1].err):toContain("exit broke")
		expect(errors[2].err):toContain("enter broke")
	end)

	it("reports rejected queued transitions", function()
		local errors = {}
		FSM.New({
			initial = "a",
			states = { a = { enter = function(m) m:Go("nowhere") end } },
			onError = function(err) errors[#errors + 1] = err end,
		})
		expect(errors[1]):toContain("'a' -> 'nowhere' is not allowed")
	end)

	it("updates the current state and drains its transitions", function()
		local ticks = 0
		local fsm = FSM.New({
			initial = "count",
			states = {
				count = {
					to = { "done" },
					update = function(m, dt)
						ticks = ticks + dt
						if ticks >= 3 then
							m:Go("done")
						end
					end,
				},
				done = {},
			},
		})
		fsm:Update(1)
		fsm:Update(1)
		expect(fsm:Get()):toBe("count")
		fsm:Update(1)
		expect(fsm:Get()):toBe("done")
		expect(fsm:Update(1)):toBe(true)
		expect(ticks):toBe(3)
	end)

	it("validates the definition", function()
		expect(function() FSM.New({ initial = "x", states = { a = {} } }) end):toFail("unknown initial state")
		expect(function() FSM.New({ initial = "a", states = { a = { to = { "b" } } } }) end)
			:toFail("unknown state 'b'")
		expect(function() FSM.New({ initial = "a", states = { a = { enter = 1 } } }) end):toFail("must be a function")
		expect(function() FSM.New({ initial = "a", states = { a = {} }, any = { "zzz" } }) end):toFail("unknown state")
	end)
end)
