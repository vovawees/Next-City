local Modules = T.load("core/modules.lua")
local Events = T.load("core/events.lua")
local Scheduler = T.load("core/scheduler.lua")
local Log = T.load("core/log.lua")

-- A registry with real services and a log that records messages per level.
local function setup(manifests, cfg)
	local lines = {}
	local log = Log.New("test", {
		level = "trace",
		sink = function(level, tag, message)
			lines[#lines + 1] = { level = level, tag = tag, message = message }
		end,
	})
	local events = Events.New({ onError = function(err) lines[#lines + 1] = { level = "bus", message = err } end })
	local scheduler = Scheduler.New()
	local registry = Modules.New({ log = log, services = { events = events, scheduler = scheduler } })
	for _, manifest in ipairs(manifests or {}) do
		registry:Register(manifest)
	end
	if cfg ~= false then
		registry:Resolve(cfg or {})
	end
	return registry, events, scheduler, lines
end

local function states(registry)
	local out = {}
	for _, row in ipairs(registry:Report()) do
		out[row.id] = row.state
	end
	return out
end

local function hasLine(lines, level, fragment)
	for _, line in ipairs(lines) do
		if line.level == level and line.message:find(fragment, 1, true) then
			return true
		end
	end
	return false
end

describe("modules manifest validation", function()
	local function invalid(manifest, fragment)
		local ok, err = Modules.Validate(manifest)
		expect(ok):toBe(false)
		expect(err):toContain(fragment)
	end

	it("accepts a full manifest", function()
		local ok, err = Modules.Validate({
			id = "organism_realistic",
			provides = "organism",
			requires = { "damage" },
			optional = { "inventory" },
			files = { sh = { "sh_defs.lua" }, sv = { "sv/sim.lua" }, cl = { "cl_view.lua" } },
			config = { tickRate = 10 },
			description = "Realistic body model",
		})
		expect(err):toBeNil()
		expect(ok):toBe(true)
	end)

	it("rejects bad ids and unknown keys", function()
		invalid({ id = "Bad-Id" }, "snake_case")
		invalid({ id = "a", require = { "b" } }, "unknown manifest key 'require'")
		invalid({ id = "a", provides = "B" }, "provides must be")
	end)

	it("rejects bad dependency lists", function()
		invalid({ id = "a", requires = "b" }, "requires must be an array")
		invalid({ id = "a", requires = { "b", "b" } }, "lists 'b' twice")
		invalid({ id = "a", requires = { "a" } }, "its own interface")
		invalid({ id = "a", provides = "x", optional = { "x" } }, "its own interface")
		invalid({ id = "a", requires = { "b" }, optional = { "b" } }, "both required and optional")
	end)

	it("rejects bad file lists", function()
		invalid({ id = "a", files = { server = {} } }, "unknown realm 'server'")
		invalid({ id = "a", files = { sh = { "../x.lua" } } }, "relative .lua path")
		invalid({ id = "a", files = { sh = { "/abs.lua" } } }, "relative .lua path")
		invalid({ id = "a", files = { sh = { "x.txt" } } }, "relative .lua path")
		invalid({ id = "a", files = { sh = { "x.lua" }, sv = { "x.lua" } } }, "listed twice")
	end)

	it("rejects duplicates and registration after Resolve", function()
		local registry = setup({}, false)
		expect(registry:Register({ id = "a" })):toBe(true)
		local ok, err = registry:Register({ id = "a" })
		expect(ok):toBe(false)
		expect(err):toContain("duplicate module id 'a'")
		registry:Resolve({})
		ok, err = registry:Register({ id = "b" })
		expect(ok):toBe(false)
		expect(err):toContain("after Resolve")
		expect(#registry:Errors()):toBe(2)
	end)
end)

describe("modules resolution", function()
	it("orders modules topologically and deterministically", function()
		local registry = setup({
			{ id = "d" },
			{ id = "c", requires = { "b" } },
			{ id = "b", requires = { "a" } },
			{ id = "a" },
		})
		expect(registry:Order()):toEqual({ "a", "b", "c", "d" })
	end)

	it("loads optional dependencies first when present", function()
		local registry = setup({
			{ id = "alpha", optional = { "zeta" } },
			{ id = "zeta" },
			{ id = "beta", optional = { "missing" } },
		})
		expect(registry:Order()):toEqual({ "beta", "zeta", "alpha" })
	end)

	it("fails modules with missing or disabled dependencies, transitively", function()
		local registry, _, _, lines = setup({
			{ id = "a", requires = { "ghost" } },
			{ id = "b", requires = { "a" } },
			{ id = "c", requires = { "off" } },
			{ id = "off" },
			{ id = "ok" },
		}, { disabled = { off = true } })
		expect(states(registry)):toEqual({ a = "failed", b = "failed", c = "failed", off = "disabled", ok = "resolved" })
		expect(select(2, registry:State("a"))):toBe("missing dependency 'ghost'")
		expect(select(2, registry:State("b"))):toBe("dependency 'a' (a) failed")
		expect(select(2, registry:State("c"))):toBe("dependency 'off' is disabled")
		expect(registry:Order()):toEqual({ "ok" })
		expect(hasLine(lines, "error", "module 'b' disabled")):toBe(true)
	end)

	it("selects configured providers and reports ambiguity", function()
		local manifests = {
			{ id = "organism_realistic", provides = "organism" },
			{ id = "organism_arcade", provides = "organism" },
			{ id = "hud", requires = { "organism" } },
		}
		local registry = setup(manifests, { providers = { organism = "organism_arcade" } })
		expect(states(registry)):toEqual({
			organism_arcade = "resolved",
			organism_realistic = "inactive",
			hud = "resolved",
		})
		expect(registry:Get("organism")):toBe(registry:Instance("organism_arcade"))

		local ambiguous = setup(manifests)
		expect(states(ambiguous)):toEqual({
			organism_arcade = "failed",
			organism_realistic = "failed",
			hud = "failed",
		})
		expect(ambiguous:Errors()[1]):toContain("ambiguous provider for interface 'organism'")
		expect(select(2, ambiguous:State("hud"))):toBe("dependency 'organism' has no selected provider")
	end)

	it("reports misconfigured providers", function()
		local registry = setup({
			{ id = "organism_realistic", provides = "organism" },
			{ id = "damage" },
		}, { providers = { organism = "organism_nope", damage = "organism_realistic" } })
		local errors = registry:Errors()
		expect(errors[1]):toContain("provides 'organism', not 'damage'")
		expect(errors[2]):toContain("'organism_nope' for interface 'organism' is not a known module")
		expect(registry:State("organism_realistic")):toBe("inactive")
		expect(registry:State("damage")):toBe("inactive")
	end)

	it("fails dependency cycles and their dependents", function()
		local registry = setup({
			{ id = "a", requires = { "b" } },
			{ id = "b", optional = { "a" } },
			{ id = "c", requires = { "a" } },
			{ id = "free" },
		})
		expect(states(registry)):toEqual({ a = "failed", b = "failed", c = "failed", free = "resolved" })
		expect(select(2, registry:State("a"))):toContain("dependency cycle (requires/optional): a, b")
		expect(select(2, registry:State("c"))):toBe("depends on a module in a dependency cycle")
		expect(registry:Order()):toEqual({ "free" })
	end)

	it("merges settings over defaults with type checks", function()
		local registry, _, _, lines = setup({
			{ id = "a", config = { interval = 5, name = "x", nested = { 1 } } },
		}, { settings = { a = { interval = 2, name = 7, extra = true }, ghost = {} } })
		registry:InitAll()
		local ctx = registry:Instance("a").ctx
		expect(ctx.config):toEqual({ interval = 2, name = "x", nested = { 1 }, extra = true })
		expect(hasLine(lines, "warn", "setting 'name' must be a string")):toBe(true)
		expect(hasLine(lines, "warn", "unknown setting 'extra'")):toBe(true)
		expect(hasLine(lines, "warn", "settings for unknown module 'ghost'")):toBe(true)
	end)

	it("can only resolve once", function()
		local registry = setup({})
		expect(function() registry:Resolve({}) end):toFail("already resolved")
	end)
end)

describe("modules lifecycle", function()
	local function lifecycleModules(calls)
		local registry = setup({
			{ id = "base" },
			{ id = "top", requires = { "base" } },
		}, false)
		for _, id in ipairs({ "base", "top" }) do
			local M = registry:Instance(id)
			function M:Init(ctx)
				calls[#calls + 1] = "init " .. self.id .. " " .. ctx.id
			end
			function M:Start()
				calls[#calls + 1] = "start " .. self.id
			end
			function M:Stop()
				calls[#calls + 1] = "stop " .. self.id
			end
		end
		registry:Resolve({})
		return registry
	end

	it("runs Init and Start in order and Stop in reverse", function()
		local calls = {}
		local registry = lifecycleModules(calls)
		registry:InitAll()
		registry:StartAll()
		expect(states(registry)):toEqual({ base = "started", top = "started" })
		registry:StopAll()
		expect(calls):toEqual({ "init base base", "init top top", "start base", "start top", "stop top", "stop base" })
		expect(states(registry)):toEqual({ base = "stopped", top = "stopped" })
		expect(registry:Counts()):toEqual({ stopped = 2 })
	end)

	it("gives each module a context with services", function()
		local registry, events, scheduler = setup({ { id = "a", config = { x = 1 } } })
		registry:InitAll()
		local M = registry:Instance("a")
		expect(M.id):toBe("a")
		expect(M.ctx.id):toBe("a")
		expect(M.ctx.config.x):toBe(1)
		expect(M.ctx.events):toBe(events)
		expect(M.ctx.scheduler):toBe(scheduler)
		expect(M.ctx.log.tag):toBe("a")
	end)

	it("fails a module whose Init errors, together with its dependents", function()
		local registry = setup({
			{ id = "base" },
			{ id = "top", requires = { "base" } },
			{ id = "side", optional = { "base" } },
		}, false)
		registry:Instance("base").Init = function() error("init exploded") end
		local sideStarted = false
		registry:Instance("side").Start = function() sideStarted = true end
		registry:Resolve({})
		registry:InitAll()
		registry:StartAll()
		local state, reason = registry:State("base")
		expect(state):toBe("failed")
		expect(reason):toContain("Init failed")
		expect(reason):toContain("init exploded")
		expect(registry:State("top")):toBe("failed")
		expect(sideStarted):toBe(true)
		expect(registry:Get("base")):toBeNil()
	end)

	it("cleans up subscriptions of a module whose Start errors", function()
		local registry, events, scheduler = setup({ { id = "a" } }, false)
		registry:Instance("a").Start = function(self, ctx)
			ctx:On("e", function() end)
			ctx:Every("job", 1, function() end)
			ctx:After(5, function() end)
			error("start exploded")
		end
		registry:Resolve({})
		registry:InitAll()
		registry:StartAll()
		expect(registry:State("a")):toBe("failed")
		expect(events:Count()):toBe(0)
		expect(scheduler:Has("a:job")):toBe(false)
		expect(scheduler:Pending()):toBe(0)
	end)

	it("stops dependents first when a module fails at runtime", function()
		local calls = {}
		local registry = lifecycleModules(calls)
		registry:InitAll()
		registry:StartAll()
		expect(registry:Fail("base", "lost database")):toBe(true)
		expect(registry:Fail("base", "again")):toBe(false)
		expect(calls[#calls - 1]):toBe("stop top")
		expect(calls[#calls]):toBe("stop base")
		local _, reason = registry:State("top")
		expect(reason):toBe("dependency 'base' (base) failed")
		expect(select(2, registry:State("base"))):toBe("lost database")
	end)
end)

describe("modules context", function()
	it("requires only declared interfaces", function()
		local registry = setup({
			{ id = "a" },
			{ id = "b", requires = { "a" }, optional = { "maybe" } },
			{ id = "c" },
		})
		registry:InitAll()
		local ctx = registry:Instance("b").ctx
		expect(ctx:Require("a")):toBe(registry:Instance("a"))
		expect(ctx:Require("maybe")):toBeNil()
		expect(function() ctx:Require("c") end):toFail("undeclared interface 'c'")
	end)

	it("binds method handlers late and cleans everything up on stop", function()
		local registry, events, scheduler = setup({ { id = "a" } }, false)
		local M = registry:Instance("a")
		local seen = {}
		function M:OnPing(value)
			seen[#seen + 1] = "v1:" .. value
		end
		function M:Tick()
			seen[#seen + 1] = "tick"
		end
		function M:Start(ctx)
			ctx:On("ping", "OnPing")
			ctx:On("ping", "OnPing") -- replaces, does not duplicate
			ctx:Every("tick", 1, "Tick")
			ctx:After(0.5, function() seen[#seen + 1] = "after" end)
		end
		registry:Resolve({})
		registry:InitAll()
		registry:StartAll()

		events:Emit("ping", 1)
		function M:OnPing(value) -- a reloaded file replaces the method
			seen[#seen + 1] = "v2:" .. value
		end
		events:Emit("ping", 2)
		scheduler:Update(1)
		expect(seen):toEqual({ "v1:1", "v2:2", "tick", "after" })
		expect(events:Count("ping")):toBe(1)

		M.ctx:After(10, function() seen[#seen + 1] = "too late" end)
		registry:StopAll()
		expect(events:Count()):toBe(0)
		expect(scheduler:Has("a:tick")):toBe(false)
		expect(scheduler:Pending()):toBe(0)
		expect(M.ctx:IsAlive()):toBe(false)
		expect(function() M.ctx:On("ping", "OnPing") end):toFail("stopped context")
	end)

	it("reports a missing handler method when the event fires", function()
		local registry, events, _, lines = setup({ { id = "a" } })
		registry:InitAll()
		registry:Instance("a").ctx:On("e", "NoSuchMethod")
		events:Emit("e")
		expect(hasLine(lines, "bus", "module 'a' has no method 'NoSuchMethod' (event 'e')")):toBe(true)
	end)

	it("namespaces job and listener ids by module", function()
		local registry, events, scheduler = setup({ { id = "a" }, { id = "b" } })
		registry:InitAll()
		local fn = function() end
		registry:Instance("a").ctx:Every("job", 1, fn)
		registry:Instance("b").ctx:Every("job", 1, fn)
		local la = registry:Instance("a").ctx:On("e", fn, { id = "x" })
		local lb = registry:Instance("b").ctx:On("e", fn, { id = "x" })
		expect(scheduler:Has("a:job")):toBe(true)
		expect(scheduler:Has("b:job")):toBe(true)
		expect(la.id):toBe("a:x")
		expect(lb.id):toBe("b:x")
		expect(events:Count("e")):toBe(2)
	end)
end)
