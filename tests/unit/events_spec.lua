local Events = T.load("core/events.lua")

local function newBus()
	local errors = {}
	local bus = Events.New({
		onError = function(err, event, listener)
			errors[#errors + 1] = { err = err, event = event, id = listener.id }
		end,
	})
	return bus, errors
end

describe("events", function()
	it("emits to listeners by priority, then in subscription order", function()
		local bus = newBus()
		local calls = {}
		bus:On("e", function(x) calls[#calls + 1] = "a" .. x end)
		bus:On("e", function(x) calls[#calls + 1] = "b" .. x end, { priority = 10 })
		bus:On("e", function(x) calls[#calls + 1] = "c" .. x end)
		bus:On("e", function(x) calls[#calls + 1] = "d" .. x end, { priority = -5 })
		bus:Emit("e", 1)
		expect(calls):toEqual({ "b1", "a1", "c1", "d1" })
		bus:Emit("nobody", 1)
	end)

	it("answers a query with the first non-nil result", function()
		local bus = newBus()
		bus:On("q", function() return nil end)
		bus:On("q", function(x) return x * 2, "second" end)
		bus:On("q", function() error("must not run") end)
		local a, b = bus:Query("q", 21)
		expect(a):toBe(42)
		expect(b):toBe("second")
		expect(bus:Query("none")):toBeNil()
	end)

	it("passes a value through a reduce pipeline", function()
		local bus = newBus()
		bus:On("r", function(value, scale) return value * scale end)
		bus:On("r", function() return nil end)
		bus:On("r", function(value) return value + 1 end)
		expect(bus:Reduce("r", 10, 3)):toBe(31)
		expect(bus:Reduce("none", 7)):toBe(7)
	end)

	it("replaces a listener with the same id", function()
		local bus = newBus()
		local calls = {}
		local old = bus:On("e", function() calls[#calls + 1] = "old" end, { id = "x" })
		bus:On("e", function() calls[#calls + 1] = "new" end, { id = "x" })
		bus:Emit("e")
		expect(calls):toEqual({ "new" })
		expect(bus:Count("e")):toBe(1)
		expect(old:IsActive()):toBe(false)
		expect(old:Off()):toBe(false)
	end)

	it("unsubscribes by handle, by id and by clearing", function()
		local bus = newBus()
		local h = bus:On("e", function() end)
		bus:On("e", function() end, { id = "named" })
		bus:On("f", function() end)
		expect(bus:Count()):toBe(3)
		expect(h:Off()):toBe(true)
		expect(h:Off()):toBe(false)
		expect(bus:Off("e", "named")):toBe(true)
		expect(bus:Off("e", "named")):toBe(false)
		expect(bus:Count("e")):toBe(0)
		bus:Clear()
		expect(bus:Count()):toBe(0)
		expect(function() bus:Off("e") end):toFail("expected a listener id")
	end)

	it("keeps a dispatch stable while listeners change", function()
		local bus = newBus()
		local calls = {}
		local second
		local added = false
		bus:On("e", function()
			calls[#calls + 1] = "first"
			second:Off()
			if not added then
				added = true
				bus:On("e", function() calls[#calls + 1] = "late" end)
			end
		end)
		second = bus:On("e", function() calls[#calls + 1] = "second" end)
		bus:Emit("e")
		expect(calls):toEqual({ "first" })
		bus:Emit("e")
		expect(calls):toEqual({ "first", "first", "late" })
	end)

	it("runs once-listeners a single time, even when re-entered", function()
		local bus = newBus()
		local count = 0
		bus:On("e", function()
			count = count + 1
			bus:Emit("e")
		end, { once = true })
		bus:Emit("e")
		bus:Emit("e")
		expect(count):toBe(1)
		expect(bus:Count("e")):toBe(0)
	end)

	it("isolates failing listeners", function()
		local bus, errors = newBus()
		local calls = 0
		bus:On("e", function() error("boom") end, { id = "bad" })
		bus:On("e", function() calls = calls + 1 end)
		bus:Emit("e")
		expect(calls):toBe(1)
		expect(#errors):toBe(1)
		expect(errors[1].event):toBe("e")
		expect(errors[1].id):toBe("bad")
		expect(errors[1].err):toContain("boom")
		expect(errors[1].err):toContain("stack traceback")

		bus:On("q", function() error("broken") end)
		bus:On("q", function() return "fallback" end)
		expect(bus:Query("q")):toBe("fallback")
		bus:On("r", function() error("broken") end)
		expect(bus:Reduce("r", 5)):toBe(5)
		expect(#errors):toBe(3)
	end)

	it("lets errors propagate when unprotected", function()
		local bus = Events.New({ protected = false })
		bus:On("e", function() error("raw") end)
		expect(function() bus:Emit("e") end):toFail("raw")
	end)

	it("validates arguments", function()
		local bus = newBus()
		expect(function() bus:On("", function() end) end):toFail("non-empty string")
		expect(function() bus:On("e", "notAFunction") end):toFail("must be a function")
		expect(function() bus:On("e", function() end, { priority = "high" }) end):toFail("priority")
	end)
end)
