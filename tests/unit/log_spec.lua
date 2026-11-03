local Log = T.load("core/log.lua")

local function capture()
	local lines = {}
	local function sink(level, tag, message)
		lines[#lines + 1] = { level = level, tag = tag, message = message }
	end
	return lines, sink
end

describe("log", function()
	it("filters by level and passes level, tag and message to the sink", function()
		local lines, sink = capture()
		local log = Log.New("core", { sink = sink })
		log:Debug("hidden")
		log:Info("shown %d", 42)
		log:Error("bad")
		expect(lines):toEqual({
			{ level = "info", tag = "core", message = "shown 42" },
			{ level = "error", tag = "core", message = "bad" },
		})
		expect(log:GetLevel()):toBe("info")
	end)

	it("does not format messages below the level", function()
		local lines, sink = capture()
		local log = Log.New("core", { level = "warn", sink = sink })
		local rendered = false
		local value = setmetatable({}, { __tostring = function() rendered = true return "x" end })
		log:Info("%s", value)
		log:Debug(function() rendered = true return "y" end)
		expect(rendered):toBe(false)
		expect(#lines):toBe(0)
		log:Warn(function(a, b) return a .. b end, "lazy", "!")
		expect(lines[1].message):toBe("lazy!")
	end)

	it("lets children inherit level and sink until overridden", function()
		local lines, sink = capture()
		local root = Log.New("root", { level = "info", sink = sink })
		local child = root:Child("organism")
		child:Debug("hidden")
		child:SetLevel("debug")
		child:Debug("shown")
		root:Debug("still hidden")
		child:SetLevel(nil)
		child:Debug("hidden again")
		root:SetLevel("trace")
		child:Trace("inherited")
		expect(#lines):toBe(2)
		expect(lines[1]):toEqual({ level = "debug", tag = "organism", message = "shown" })
		expect(lines[2].message):toBe("inherited")

		local own = {}
		child:SetSink(function(_, _, message) own[#own + 1] = message end)
		child:Info("own sink")
		expect(own):toEqual({ "own sink" })
		expect(#lines):toBe(2)
	end)

	it("never throws on broken format strings", function()
		local lines, sink = capture()
		local log = Log.New("core", { sink = sink })
		log:Info("%d items", "many")
		log:Info("%s and %s", {}, nil)
		log:Info(function() error("oops") end)
		log:Info(nil)
		expect(lines[1].message):toContain("<bad format: many>")
		expect(lines[2].message):toContain(" and nil")
		expect(lines[3].message):toContain("log message function failed")
		expect(lines[4].message):toBe("nil")
	end)

	it("survives a failing sink", function()
		local printed = {}
		local realPrint = print
		print = function(text) printed[#printed + 1] = text end
		local ok, err = pcall(function()
			local FreshLog = T.load("core/log.lua")
			local log = FreshLog.New("core", { sink = function() error("sink down") end })
			log:Warn("message")
		end)
		print = realPrint
		expect(ok):toBe(true)
		expect(err):toBeNil()
		expect(printed[1]):toBe("[core] WARN: message")
		expect(printed[2]):toContain("log sink failed")
	end)

	it("parses and checks levels", function()
		expect(Log.ParseLevel("DEBUG")):toBe(2)
		expect(Log.ParseLevel(5)):toBe(5)
		expect(Log.ParseLevel(9)):toBeNil()
		expect(Log.ParseLevel("loud")):toBeNil()
		local log = Log.New("core", { level = "warn", sink = function() end })
		expect(log:IsEnabled("error")):toBe(true)
		expect(log:IsEnabled("info")):toBe(false)
		expect(log:IsEnabled("off")):toBe(false)
		expect(function() Log.New("core", { level = "loud" }) end):toFail("unknown level")
		expect(function() log:SetLevel("loud") end):toFail("unknown level")
	end)

	it("logs at an explicit level", function()
		local lines, sink = capture()
		local log = Log.New("core", { sink = sink })
		log:Log("warn", "a")
		log:Log("debug", "b")
		log:Log("off", "c")
		expect(#lines):toBe(1)
		expect(lines[1].level):toBe("warn")
	end)

	it("provides a null logger", function()
		local null = Log.Null
		expect(null:Child("x")):toBe(null)
		expect(null:IsEnabled("error")):toBe(false)
		expect(null:GetLevel()):toBe("off")
		null:Error("ignored %d", 1)
	end)
end)
