-- Permission service: privileges declared by modules, the bus question for sources,
-- the fallback by levels and groups, admin commands, the lists of clients and the
-- poll, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local CONFIG = Env.CONFIG

local SECTION = [[{
	manage = { level = "admin", desc = "Manage the probe" },
	kick = {},
	view = { level = "user" },
	secret = { level = "nobody" },
}]]

local function probeFiles(section, extra)
	local files = {
		[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sh = { 'sh_probe.lua' } }, "
			.. "permissions = " .. (section or SECTION) .. " }",
		[MODULES .. "probe/sh_probe.lua"] = [[
			local M = NC.Module("probe")
			M.events = {}
			function M:Init(ctx)
				if SERVER then
					ctx.commands:Add("nc_probe", { help = "probe: default" }, function() return "probe ran" end)
					ctx.commands:Add("nc_probe_admin", { level = "admin" }, function() return "admin ran" end)
					ctx.commands:Add("nc_probe_manage", { privilege = "manage" }, function() return "manage ran" end)
					ctx.commands:Add("nc_probe_all", { admin = false }, function() return "all ran" end)
				end
				ctx:On("permissions.changed", function(ply, ids)
					M.events[#M.events + 1] = { "changed", ply, table.concat(ids, " ") }
				end)
				ctx:On("permissions.unregistered", function(privilege)
					M.events[#M.events + 1] = { "unregistered", privilege.id }
				end)
			end
		]],
	}
	for path, source in pairs(extra or {}) do
		files[path] = source
	end
	return files
end

-- A source of permissions: answers from M.answers[ply name][id] (true, false or nil).
local SOURCE = {
	[MODULES .. "source/module.lua"] = "return { id = 'source', files = { sv = { 'sv_source.lua' } } }",
	[MODULES .. "source/sv_source.lua"] = [[
		local M = NC.Module("source")
		M.answers = {}
		M.asked = {}
		function M:Init(ctx)
			ctx:On("permissions.can", function(ply, id, target, privilege)
				M.asked[#M.asked + 1] = { ply:Nick(), id, target, privilege.level }
				local answers = M.answers[ply:Nick()]
				if answers ~= nil then
					return answers[id]
				end
			end)
		end
	]],
}

local function withConfig(permissions)
	return {
		[CONFIG] = function(cfg)
			cfg.permissions = permissions
			return cfg
		end,
	}
end

local function nc(env)
	return env:Get("NC")
end

local function probe(env)
	return nc(env).Modules:Instance("probe")
end

local function players()
	return Env.FakePlayer({ name = "Guest" }), Env.FakePlayer({ name = "Admin", group = "admin" }),
		Env.FakePlayer({ name = "Root", superadmin = true })
end

describe("permission service", function()
	it("registers the privileges of manifests and checks them by level", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		expect(server:Errors()):toEqual({})
		local permissions = nc(server).Permissions
		local manage = permissions:Get("probe.manage")
		expect(manage):toEqual({ id = "probe.manage", module = "probe", name = "manage", level = "admin",
			declared = "admin", desc = "Manage the probe" })
		expect(permissions:Level("probe.kick")):toBe("superadmin")
		expect(permissions:Get("nc_probe").command):toBe("nc_probe")
		expect(permissions:Get("nc_probe_manage")):toBeNil()
		expect(permissions:Get("nc_probe_all")):toBeNil()
		expect(permissions:Get("nc_modules").module):toBe("platform")

		local guest, admin, root = players()
		local cases = {
			{ "probe.view", true, true, true },
			{ "probe.manage", false, true, true },
			{ "probe.kick", false, false, true },
			{ "probe.secret", false, false, false },
			{ "nc_probe_admin", false, true, true },
		}
		for _, case in ipairs(cases) do
			expect(permissions:Can(guest, case[1])):toBe(case[2])
			expect(permissions:Can(admin, case[1])):toBe(case[3])
			expect(permissions:Can(root, case[1])):toBe(case[4])
			expect(permissions:Can(nil, case[1])):toBe(true)
		end
		expect(permissions:Rank(admin)):toBe("admin")
		expect(permissions:Can(Env.NULL or server:Get("NULL"), "probe.view")):toBe(false)
		expect(permissions:Granted(admin)):toEqual({ "nc_probe_admin", "probe.manage", "probe.view" })

		-- The facade knows the module's own privileges by name.
		local ctx = probe(server).ctx
		expect(ctx.permissions:Id("manage")):toBe("probe.manage")
		expect(ctx.permissions:Id("nc_round")):toBe("nc_round")
		expect(ctx.permissions:Can(admin, "manage")):toBe(true)
		expect(ctx.permissions:Can(admin, "kick")):toBe(false)
		expect(ctx.permissions:Level("view")):toBe("user")

		-- Nobody has an unknown privilege; the log tells once.
		expect(permissions:Can(root, "probe.nope")):toBe(false)
		expect(permissions:Can(root, "probe.nope")):toBe(false)
		expect(#server:Lines("unknown privilege 'probe.nope' was checked")):toBe(1)
	end)

	it("asks the sources first and falls back to the config, groups and levels", function()
		local patch = withConfig({
			levels = { ["probe.kick"] = "admin", ["probe.ghost"] = "user", ["probe.view"] = "god" },
			groups = { moderator = "admin", vip = "nobody" },
			refresh = -1,
		})
		local server = Env.Kernel({ files = probeFiles(nil, SOURCE), patch = patch }):Boot()
		expect(server:Errors()):toEqual({})
		expect(#server:Lines("config permissions.levels: there is no privilege 'probe.ghost'")):toBe(1)
		expect(#server:Lines("config permissions.levels: probe.view = god is ignored")):toBe(1)
		expect(#server:Lines("config permissions.groups: vip = nobody is ignored")):toBe(1)
		expect(#server:Lines("config permissions.refresh must be a number of seconds")):toBe(1)

		local permissions = nc(server).Permissions
		expect(permissions:Get("probe.kick").level):toBe("admin")
		expect(permissions:Get("probe.kick").declared):toBe("superadmin")
		local guest, admin, root = players()
		local moderator = Env.FakePlayer({ name = "Moderator", group = "moderator" })
		expect(permissions:Rank(moderator)):toBe("admin")
		expect(permissions:Can(moderator, "probe.kick")):toBe(true)
		expect(permissions:Can(admin, "probe.kick")):toBe(true)

		-- The first answer wins; nil leaves it to the levels.
		local source = nc(server).Modules:Instance("source")
		source.answers.Guest = { ["probe.secret"] = true, ["nc_probe"] = true }
		source.answers.Root = { ["probe.view"] = false }
		expect(permissions:Can(guest, "probe.secret", root)):toBe(true)
		local asked = source.asked[#source.asked]
		expect(asked):toEqual({ "Guest", "probe.secret", root, "nobody" })
		expect(permissions:Can(root, "probe.view")):toBe(false)
		expect(permissions:Can(root, "probe.manage")):toBe(true)

		-- Commands follow the answers too; the server console is never asked.
		server:Command("nc_probe", guest)
		expect(guest.printed):toEqual({ "probe ran" })
		local count = #source.asked
		server:Command("nc_probe")
		expect(#source.asked):toBe(count)
		expect(#server:Lines("probe ran")):toBe(1)
	end)

	it("checks admin commands through privileges", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local guest, admin, root = players()
		local function run(name, ply)
			server:Command(name, ply)
			return ply.printed[#ply.printed]
		end
		expect(run("nc_probe", guest)):toBe("nc_probe: no access")
		expect(run("nc_probe", admin)):toBe("nc_probe: no access")
		expect(run("nc_probe", root)):toBe("probe ran")
		expect(run("nc_probe_admin", guest)):toBe("nc_probe_admin: no access")
		expect(run("nc_probe_admin", admin)):toBe("admin ran")
		expect(run("nc_probe_manage", admin)):toBe("manage ran")
		expect(run("nc_probe_manage", guest)):toBe("nc_probe_manage: no access")
		expect(run("nc_probe_all", guest)):toBe("all ran")
		expect(run("nc_modules", admin)):toBe("nc_modules: no access")

		local list = nc(server).Commands:List()
		local byName = {}
		for _, entry in ipairs(list) do
			byName[entry.name] = entry
		end
		expect(byName.nc_probe.privilege):toBe("nc_probe")
		expect(byName.nc_probe_manage.privilege):toBe("probe.manage")
		expect(byName.nc_probe_all.privilege):toBeNil()
		expect(byName.nc_probe_all.admin):toBe(false)

		-- A command's own privilege goes away with it.
		nc(server).Modules:Fail("probe", "test")
		expect(nc(server).Permissions:Get("nc_probe")):toBeNil()
		expect(nc(server).Permissions:Get("probe.manage")):toBeNil()
		expect(server.commands.nc_probe):toBeNil()
	end)

	it("rejects bad permission keys of commands", function()
		local extra = {
			[MODULES .. "thief/module.lua"] = "return { id = 'thief', files = { sv = { 'sv_thief.lua' } }, "
				.. "permissions = { steal = {} } }",
			[MODULES .. "thief/sv_thief.lua"] = [[
				local M = NC.Module("thief")
				M.errors = {}
				function M:Init(ctx)
					local function try(...)
						local ok, err = pcall(ctx.commands.Add, ctx.commands, ...)
						M.errors[#M.errors + 1] = ok and "ok" or err
					end
					local noop = function() end
					try("nc_t1", { level = "god" }, noop)
					try("nc_t2", { admin = false, level = "admin" }, noop)
					try("nc_t3", { privilege = "nope" }, noop)
					try("nc_t4", { privilege = "steal", level = "admin" }, noop)
					try("nc_t5", { admin = "yes" }, noop)
					try("nc_t6", { privilege = "steal" }, noop)
					try("nc_t7", { privilege = "probe.manage" }, noop)
					try("nc_t7", { privilege = "probe.kick" }, noop)
				end
			]],
		}
		local server = Env.Kernel({ files = probeFiles(nil, extra) }):Boot()
		local errors = nc(server).Modules:Instance("thief").errors
		expect(errors[1]):toContain("level must be \"user\", \"admin\", \"superadmin\" or \"nobody\"")
		expect(errors[2]):toContain("is for everybody (admin = false): it takes no privilege or level")
		expect(errors[3]):toContain("unknown privilege 'nope'")
		expect(errors[4]):toContain("the level belongs to the privilege 'steal'")
		expect(errors[5]):toContain("admin must be a boolean")
		expect(errors[6]):toBe("ok")
		expect(errors[7]):toBe("ok")
		expect(errors[8]):toBe("ok")
		local list = nc(server).Commands:List()
		local privileges = {}
		for _, entry in ipairs(list) do
			privileges[entry.name] = entry.privilege
		end
		expect(privileges.nc_t6):toBe("thief.steal")
		expect(privileges.nc_t7):toBe("probe.kick")
		expect(nc(server).Commands:List()[1].name):toBe("nc_probe")
	end)

	it("validates the permissions section of manifests", function()
		local cases = {
			{ "{ ['Bad Name'] = {} }", "privilege name Bad Name must be a snake_case id" },
			{ "{ x = { level = 'god' } }", "privilege 'x': level must be" },
			{ "{ x = { lvl = 'admin' } }", "privilege 'x': unknown key 'lvl'" },
			{ "{ x = 'admin' }", "privilege 'x': must be a table" },
			{ "{ x = { desc = 5 } }", "privilege 'x': desc must be a string" },
			{ "42", "permissions must be a table of privileges" },
		}
		for _, case in ipairs(cases) do
			local server = Env.Kernel({ files = probeFiles(case[1]) }):Boot()
			expect(table.concat(server:Errors(), "\n")):toContain(case[2])
			expect(nc(server).Modules:State("probe")):toBeNil()
		end
	end)

	it("registers privileges while a module runs and removes them with it", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local ctx = probe(server).ctx
		local permissions = nc(server).Permissions
		expect(ctx.permissions:Register("dynamic", { level = "admin", desc = "runtime" })):toBe("probe.dynamic")
		expect(permissions:Level("probe.dynamic")):toBe("admin")
		expect(pcall(ctx.permissions.Register, ctx.permissions, "dynamic")):toBe(false)
		local ok, err = pcall(ctx.permissions.Register, ctx.permissions, "bad", { level = "root" })
		expect(ok):toBe(false)
		expect(err):toContain("privilege 'bad': level must be")
		expect(ctx.permissions:Unregister("dynamic")):toBe(true)
		expect(ctx.permissions:Unregister("dynamic")):toBe(false)
		expect(permissions:Get("probe.dynamic")):toBeNil()
		ctx.permissions:Register("again")
		nc(server).Modules:Fail("probe", "test")
		expect(permissions:Get("probe.again")):toBeNil()
		expect(permissions:Get("probe.view")):toBeNil()
		local ids = {}
		for _, privilege in ipairs(permissions:List()) do
			ids[#ids + 1] = privilege.id
		end
		expect(table.concat(ids, " ")):toBe("nc_components nc_lang nc_modules nc_net nc_net_reset nc_perf "
			.. "nc_perf_reset nc_privileges")
	end)

	it("sends a client the privileges of its player and later only the changes", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local client, ply = Env.Join(server, { name = "Mod", group = "admin" })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		local mirror = nc(client).Permissions
		expect(mirror:IsKnown()):toBe(true)
		expect(mirror:Can(nil, "probe.manage")):toBe(true)
		expect(mirror:Can(ply, "probe.view")):toBe(true)
		expect(mirror:Can(nil, "probe.kick")):toBe(false)
		expect(mirror:Granted()):toEqual({ "nc_probe_admin", "probe.manage", "probe.view" })
		expect(probe(client).ctx.permissions:Can(nil, "manage")):toBe(true)
		local other = Env.FakePlayer({ name = "Other", superadmin = true })
		expect(mirror:Can(other, "probe.view")):toBe(false)
		expect(#server:Sent("nc.grants")):toBe(1)
		expect(probe(server).events[1]):toEqual({ "changed", ply, "nc_probe_admin probe.manage probe.view" })
		expect(probe(client).events[1]):toEqual({ "changed", ply, "nc_probe_admin probe.manage probe.view" })

		-- Nothing changes: the poll sends nothing.
		server:Advance(1)
		server:Advance(1)
		Env.Flush(server, client)
		expect(#server:Sent("nc.grants")):toBe(1)

		-- Refresh tells at once; the poll finds a change on its own.
		ply:SetUserGroup("superadmin")
		nc(server).Permissions:Refresh(ply)
		Env.Flush(server, client)
		expect(#server:Sent("nc.grants")):toBe(2)
		expect(mirror:Can(nil, "probe.kick")):toBe(true)
		expect(mirror:Can(nil, "nc_modules")):toBe(true)
		ply:SetUserGroup("user")
		server:Advance(1)
		Env.Flush(server, client)
		expect(#server:Sent("nc.grants")):toBe(3)
		expect(mirror:Granted()):toEqual({ "probe.view" })
		expect(probe(client).events[#probe(client).events]):toEqual({ "changed", ply, "probe.view" })

		-- Privileges that go away leave the list with the next poll.
		ply:SetUserGroup("admin")
		nc(server).Permissions:Refresh()
		Env.Flush(server, client)
		expect(mirror:Can(nil, "probe.manage")):toBe(true)
		nc(server).Modules:Fail("probe", "test")
		server:Advance(1)
		Env.Flush(server, client)
		expect(mirror:Granted()):toEqual({})
		expect(mirror:Can(nil, "probe.manage")):toBe(false)
		expect(client:Errors()):toEqual({})
	end)

	it("checks players in turn, each once in the refresh period", function()
		local server = Env.Kernel({ files = probeFiles(), patch = withConfig({ refresh = 4 }) }):Boot()
		local list = {}
		for i = 1, 8 do
			local client, ply = Env.Join(server, { name = "P" .. i })
			list[i] = { client = client, ply = ply }
		end
		-- The first poll checks everybody: the privileges are new.
		server:Advance(1)
		local permissions = nc(server).Permissions
		local checked = 0
		local original = permissions._Check
		permissions._Check = function(service, ply, force)
			checked = checked + 1
			return original(service, ply, force)
		end
		server:Advance(1)
		expect(checked):toBe(2)
		server:Advance(1)
		server:Advance(1)
		server:Advance(1)
		expect(checked):toBe(8)
		for _, entry in ipairs(list) do
			entry.ply:SetUserGroup("admin")
		end
		for _ = 1, 4 do
			server:Advance(1)
		end
		for _, entry in ipairs(list) do
			Env.Flush(server, entry.client)
			expect(nc(entry.client).Permissions:Can(nil, "probe.manage")):toBe(true)
		end
		permissions._Check = original
	end)

	it("keeps working across autorefresh on both realms", function()
		local server = Env.Kernel({ files = probeFiles() }):Boot()
		local client, ply = Env.Join(server, { group = "admin" })
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		Env.Flush(server, client)
		expect(server:Errors()):toEqual({})
		expect(nc(server).Permissions:Get("probe.manage")):toEqual({ id = "probe.manage", module = "probe",
			name = "manage", level = "admin", declared = "admin", desc = "Manage the probe" })
		server:Command("nc_probe_admin", ply)
		expect(ply.printed[#ply.printed]):toBe("admin ran")
		expect(nc(server).Scheduler:Has("permissions:poll")):toBe(true)

		client:Run(Env.ENTRY.client)
		expect(nc(client).Permissions:Can(nil, "probe.manage")):toBe(true)
		client:Call("OnReloaded")
		Env.Flush(server, client)
		expect(nc(client).Permissions:Granted()):toEqual({ "nc_probe_admin", "probe.manage", "probe.view" })
		expect(client:Errors()):toEqual({})
	end)

	it("lists privileges with nc_privileges", function()
		local patch = withConfig({ levels = { ["probe.kick"] = "admin" } })
		local server = Env.Kernel({ files = probeFiles(), patch = patch }):Boot()
		local client, ply = Env.Join(server, { name = "Mod", group = "admin" })
		server:Command("nc_privileges")
		expect(#server:Lines("Privileges (server): 14")):toBe(1)
		expect(server:Lines("  probe.manage ")[1]):toContain("admin       probe            Manage the probe")
		expect(server:Lines("  probe.kick ")[1]):toContain("admin*")
		expect(#server:Lines("* the level is set in config permissions.levels")):toBe(1)

		server:Command("nc_privileges", nil, { "mod" })
		expect(#server:Lines("Privileges of Mod (server, rank admin, group admin): 4 of 14")):toBe(1)
		expect(#server:Lines("  + probe.manage ")):toBe(1)
		expect(#server:Lines("  - probe.secret ")):toBe(1)
		server:Command("nc_privileges", nil, { "nobody" })
		expect(#server:Lines("no player matches 'nobody'")):toBe(1)

		server:Command("nc_privileges", ply)
		expect(ply.printed[#ply.printed]):toBe("nc_privileges: no access")

		client:Command("nc_privileges_cl")
		expect(#client:Lines("Privileges of Mod (client): 4 of 5")):toBe(1)
		expect(#client:Lines("  + nc_probe_admin                   -           -")):toBe(1)
		expect(#client:Lines("  + probe.kick ")):toBe(1)
	end)
end)
