-- Command service: console commands declared by modules, permissions, replies, errors
-- and cleanup, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"

local function probeFiles(extra)
	local files = {
		[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sh = { 'sh_probe.lua' } } }",
		[MODULES .. "probe/sh_probe.lua"] = [[
			local M = NC.Module("probe")
			M.calls = {}
			function M:Init(ctx)
				if SERVER then
					ctx.commands:Add("nc_probe", { help = "probe: echo" }, "OnProbe")
					ctx.commands:Add("nc_hello", { admin = false }, function(ply, args)
						return "hello " .. (IsValid(ply) and ply:Nick() or "console") .. " " .. table.concat(args, ",")
					end)
					ctx.commands:Add("nc_boom", nil, function() error("kaboom") end)
				else
					ctx.commands:Add("nc_probe_view", nil, function() return { "client side" } end)
				end
			end
			function M:OnProbe(ply, args)
				self.calls[#self.calls + 1] = args[1] or "-"
				return { "probe 1", "probe 2" }
			end
		]],
	}
	for path, source in pairs(extra or {}) do
		files[path] = source
	end
	return files
end

describe("command service", function()
	it("runs module commands for the console and superadmins only", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		expect(server:Errors()):toEqual({})
		local probe = server:Get("NC").Modules:Instance("probe")

		server:Command("nc_probe", nil, { "x" })
		expect(probe.calls):toEqual({ "x" })
		expect(#server:Lines("probe 1")):toBe(1)
		expect(#server:Lines("probe 2")):toBe(1)

		local guest = Env.FakePlayer({ name = "Guest" })
		server:Command("nc_probe", guest, { "y" })
		expect(guest.printed):toEqual({ "nc_probe: no access" })
		expect(probe.calls):toEqual({ "x" })

		local admin = Env.FakePlayer({ name = "Admin", superadmin = true })
		server:Command("nc_probe", admin, { "z" })
		expect(admin.printed):toEqual({ "probe 1", "probe 2" })
		expect(probe.calls):toEqual({ "x", "z" })

		server:Command("nc_hello", guest, { "a", "b" })
		expect(guest.printed[#guest.printed]):toBe("hello Guest a,b")
	end)

	it("catches handler errors and tells the caller", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local admin = Env.FakePlayer({ superadmin = true })
		server:Command("nc_boom", admin)
		expect(admin.printed):toEqual({ "nc_boom: failed, see the server log" })
		local errors = table.concat(server:Errors(), "\n")
		expect(errors):toContain("command 'nc_boom' of module 'probe' failed")
		expect(errors):toContain("kaboom")
	end)

	it("registers client commands on the client without checks", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local client = Env.Client(server):Boot()
		expect(client.commands.nc_probe):toBeNil()
		client:Command("nc_probe_view")
		expect(#client:Lines("client side")):toBe(1)
	end)

	it("lists commands and removes them when the module stops", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local NC = server:Get("NC")
		local list = NC.Commands:List()
		expect(#list):toBe(3)
		expect(list[1]):toEqual({ name = "nc_boom", module = "probe", admin = true, privilege = "nc_boom" })
		expect(list[2].admin):toBe(false)
		expect(list[3].help):toBe("probe: echo")

		NC.Modules:Fail("probe", "test")
		expect(server.commands.nc_probe):toBeNil()
		expect(server.commands.nc_hello):toBeNil()
		expect(#NC.Commands:List()):toBe(0)
	end)

	it("keeps commands working across autorefresh", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		expect(server:Errors()):toEqual({})
		local probe = server:Get("NC").Modules:Instance("probe")
		server:Command("nc_probe", nil, { "again" })
		expect(probe.calls):toEqual({ "again" })
	end)

	it("rejects bad names, unknown spec keys and taken names", function()
		local extra = {
			[MODULES .. "thief/module.lua"] = "return { id = 'thief', files = { sv = { 'sv_thief.lua' } } }",
			[MODULES .. "thief/sv_thief.lua"] = [[
				local M = NC.Module("thief")
				function M:Init(ctx)
					local function try(...)
						local ok, err = pcall(ctx.commands.Add, ctx.commands, ...)
						M.errors = M.errors or {}
						M.errors[#M.errors + 1] = ok and "ok" or err
					end
					try("Bad Name", nil, function() end)
					try("nc_x", { helpp = "typo" }, function() end)
					try("nc_probe", nil, function() end)
					try("nc_x", { help = "fine" }, function() end)
					try("+nc_hold", nil, function() end) -- a key command: its pair -nc_hold runs on release
					try("+-nc_x", nil, function() end)
				end
			]],
		}
		local server = Env.Kernel({ files = probeFiles(extra) }):Boot()
		local errors = server:Get("NC").Modules:Instance("thief").errors
		expect(errors[1]):toContain("command name must match")
		expect(errors[2]):toContain("unknown spec key 'helpp'")
		expect(errors[3]):toContain("command 'nc_probe' already belongs to module 'probe'")
		expect(errors[4]):toBe("ok")
		expect(errors[5]):toBe("ok")
		expect(errors[6]):toContain("command name must match")
	end)
end)
