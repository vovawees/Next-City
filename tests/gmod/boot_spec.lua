-- Boot smoke tests: the real gamemode files in an emulated GMod server and client.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"

-- Virtual modules used to exercise the loader, the bridge and the lifecycle.
local function probeFiles()
	return {
		[MODULES .. "probe/module.lua"] = [[
			return {
				id = "probe",
				files = { sh = { "sh_probe.lua" }, sv = { "sv_probe.lua" }, cl = { "cl_probe.lua" } },
				config = { interval = 1 },
			}
		]],
		[MODULES .. "probe/sh_probe.lua"] = [[
			local M = NC.Module("probe")
			M.trace = { "sh" }
			M.ticks = 0
			function M:Start(ctx)
				ctx:On("nc.ready", "OnReady")
				ctx:On("gm.PlayerInitialSpawn", "OnJoin")
				ctx:On("nc.shutdown", "OnShutdown")
				ctx:Every("tick", ctx.config.interval, "Tick")
			end
			function M:OnReady() self.ready = true end
			function M:OnJoin(ply) self.joined = ply end
			function M:OnShutdown() self.shutdownSeen = true end
			function M:Tick() self.ticks = self.ticks + 1 end
			function M:Stop() self.stopped = true end
		]],
		[MODULES .. "probe/sv_probe.lua"] = [[
			local M = NC.Module("probe")
			M.trace[#M.trace + 1] = "sv"
		]],
		[MODULES .. "probe/cl_probe.lua"] = [[
			local M = NC.Module("probe")
			M.trace[#M.trace + 1] = "cl"
		]],
	}
end

local function brokenFiles()
	local files = probeFiles()
	files[MODULES .. "user/module.lua"] = [[return { id = "user", requires = { "probe" }, files = { sv = { "sv_user.lua" } } }]]
	files[MODULES .. "user/sv_user.lua"] = [[
		local M = NC.Module("user")
		function M:Start(ctx) self.probe = ctx:Require("probe") end
	]]
	files[MODULES .. "broken/module.lua"] = [[return { id = "broken", files = { sv = { "sv_broken.lua" } } }]]
	files[MODULES .. "broken/sv_broken.lua"] = [[error("boom")]]
	files[MODULES .. "victim/module.lua"] = [[return { id = "victim", requires = { "broken" } }]]
	files[MODULES .. "mismatch/module.lua"] = [[return { id = "other" }]]
	files[MODULES .. "garbage/module.lua"] = [[return 42]]
	files[MODULES .. "lost/module.lua"] = [[return { id = "lost", files = { sh = { "sh_missing.lua" } } }]]
	files[MODULES .. "notes/readme.lua"] = [[error("folders without module.lua are ignored")]]
	return files
end

local function state(env, id)
	return env:Get("NC").Modules:State(id)
end

local function expectOnlyGlobalNC(env)
	expect(env.newGlobals):toEqual({ NC = true })
	for name in pairs(env.undefinedReads) do
		expect(name):toBe("NC")
	end
end

describe("boot", function()
	it("boots the server with the default config cleanly", function()
		local server = Env.Server():Boot()
		expect(server:Errors()):toEqual({})
		expect(#server:Lines("WARN")):toBe(0)
		local NC = server:Get("NC")
		expect(NC.VERSION):toBe("0.1.0")
		expect(NC.started):toBe(true)
		expect(NC.Log:GetLevel()):toBe("info")
		expect(#server:Lines("Next-City 0.1.0 started (modules: 0 running, 0 failed)")):toBe(1)
		expect(server.baseCalls):toEqual({ "Initialize" })
		expectOnlyGlobalNC(server)
	end)

	it("sends the client everything it needs and boots it from sent files only", function()
		local server = Env.Server():Boot()
		local client = Env.Client(server):Boot()
		expect(client:Errors()):toEqual({})
		expect(client:Get("NC").started):toBe(true)
		expect(server.sent["nextcity/gamemode/init.lua"]):toBeNil()
		for _, path in ipairs(client.loaded) do
			expect(server.sent[path]):toBe(true)
		end
		expectOnlyGlobalNC(client)
	end)

	it("loads module files per realm and sends only shared and client files", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client = Env.Client(server):Boot()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(server:Get("NC").Modules:Instance("probe").trace):toEqual({ "sh", "sv" })
		expect(client:Get("NC").Modules:Instance("probe").trace):toEqual({ "sh", "cl" })
		expect(server.sent[MODULES .. "probe/module.lua"]):toBe(true)
		expect(server.sent[MODULES .. "probe/sh_probe.lua"]):toBe(true)
		expect(server.sent[MODULES .. "probe/cl_probe.lua"]):toBe(true)
		expect(server.sent[MODULES .. "probe/sv_probe.lua"]):toBeNil()
		expect(state(server, "probe")):toBe("started")
		expect(state(client, "probe")):toBe("started")
		expectOnlyGlobalNC(server)
		expectOnlyGlobalNC(client)
	end)

	it("isolates broken modules and keeps the rest running", function()
		local server = Env.Server({ files = brokenFiles() }):Boot()
		local NC = server:Get("NC")
		expect(state(server, "probe")):toBe("started")
		expect(state(server, "user")):toBe("started")
		expect(NC.Modules:Instance("user").probe):toBe(NC.Modules:Instance("probe"))

		local brokenState, brokenReason = state(server, "broken")
		expect(brokenState):toBe("failed")
		expect(brokenReason):toContain("loading sv_broken.lua failed")
		expect(brokenReason):toContain("boom")
		expect(select(2, state(server, "victim"))):toBe("dependency 'broken' (broken) failed")
		local lostState, lostReason = state(server, "lost")
		expect(lostState):toBe("failed")
		expect(lostReason):toContain("file not found")
		expect(state(server, "other")):toBeNil()
		expect(state(server, "notes")):toBeNil()

		local errors = table.concat(server:Errors(), "\n")
		expect(errors):toContain("id 'other' must match its folder 'mismatch'")
		expect(errors):toContain("garbage/module.lua must return a table")
		expect(errors):toContain("module 'broken' failed")
		expect(#server:Lines("(modules: 2 running, 3 failed)")):toBe(1)
	end)

	it("drives modules through bridge events and the scheduler", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local NC = server:Get("NC")
		local probe = NC.Modules:Instance("probe")
		expect(probe.ready):toBe(true)

		local ply = Env.FakePlayer()
		server:Call("PlayerInitialSpawn", ply, false)
		expect(probe.joined):toBe(ply)
		expect(server.baseCalls[#server.baseCalls]):toBe("PlayerInitialSpawn")

		server:Advance(0.5)
		server:Advance(0.5)
		server:Advance(1)
		expect(probe.ticks):toBe(2)

		server:Call("ShutDown")
		expect(probe.shutdownSeen):toBe(true)
		expect(probe.stopped):toBe(true)
		expect(state(server, "probe")):toBe("stopped")
		expect(NC.Events:Count()):toBe(0)
		expect(NC.Scheduler:Has("probe:tick")):toBe(false)
	end)

	it("rebuilds the kernel on autorefresh without leaking listeners", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local NC = server:Get("NC")
		local oldModules, oldEvents = NC.Modules, NC.Events
		local oldProbe = oldModules:Instance("probe")
		local listeners = oldEvents:Count()

		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")

		expect(oldProbe.stopped):toBe(true)
		expect(oldEvents:Count()):toBe(0)
		expect(NC.Modules):notToBe(oldModules)
		local probe = NC.Modules:Instance("probe")
		expect(probe):notToBe(oldProbe)
		expect(state(server, "probe")):toBe("started")
		expect(probe.ready):toBe(true)
		expect(NC.Events:Count()):toBe(listeners)
		server:Advance(1)
		expect(probe.ticks):toBe(1)
		expect(oldProbe.ticks):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("provides console commands with permission checks", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		server:Advance(1)

		server:Command("nc_modules")
		expect(#server:Lines("probe")):toBe(1)
		expect(server:Lines("probe")[1]):toContain("started")

		local guest = Env.FakePlayer()
		server:Command("nc_perf", guest)
		expect(guest.printed):toEqual({ "nc_perf: superadmin only" })

		local admin = Env.FakePlayer({ superadmin = true })
		server:Command("nc_perf", admin)
		expect(table.concat(admin.printed, "\n")):toContain("probe:tick")
		server:Command("nc_perf_reset", admin)
		expect(admin.printed[#admin.printed]):toBe("Scheduler profile reset")

		local client = Env.Client(server):Boot()
		expect(client.commands.nc_modules):toBeNil()
		client:Command("nc_modules_cl")
		expect(#client:Lines("(client)")):toBe(1)
	end)

	it("keeps every gamemode file in standard Lua syntax", function()
		local count = 0
		for path in pairs(Env.RepoFiles()) do
			if path:find("%.lua$") then
				local fn, err = loadfile(T.root .. "gamemodes/" .. path)
				expect(err):toBeNil()
				expect(type(fn)):toBe("function")
				count = count + 1
			end
		end
		expect(count > 0):toBe(true)
	end)
end)
