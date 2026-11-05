-- CAMI adapter: the privileges go to admin mods through the Common Admin Mod Interface
-- and they decide; without an admin mod (or without CAMI) the levels apply. CAMI and the
-- admin mod are fakes of tests/gmod/cami.lua, the gamemode files are real.

local Env = dofile(T.root .. "tests/gmod/env.lua")
local Cami = dofile(T.root .. "tests/gmod/cami.lua")

local MODULES = "nextcity/gamemode/modules/"
local CONFIG = Env.CONFIG
local PREFIX = "nextcity."

local PROBE = {
	[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sv = { 'sv_probe.lua' } }, permissions = { "
		.. "manage = { level = 'admin', desc = 'Manage the probe' }, kick = {}, secret = { level = 'nobody' } } }",
	[MODULES .. "probe/sv_probe.lua"] = [[
		local M = NC.Module("probe")
		function M:Init(ctx)
			ctx.commands:Add("nc_probe", { privilege = "manage" }, function() return "probe ran" end)
		end
	]],
}

-- A server with the cami module and the probe. opts: cami (install CAMI before the boot),
-- mod (and an admin mod), settings (of the cami module), permissions (config section).
local function boot(opts)
	opts = opts or {}
	local patch = {
		[CONFIG] = function(cfg)
			cfg.modules.settings.cami = opts.settings
			if opts.permissions ~= nil then
				cfg.permissions = opts.permissions
			end
			return cfg
		end,
	}
	local server = Env.Kernel({ modules = { "cami" }, files = PROBE, patch = patch })
	local cami, mod
	if opts.cami ~= false then
		cami = Cami.Install(server)
		if opts.mod ~= false then
			mod = Cami.AdminMod(server, cami)
		end
	end
	server:Boot()
	return server, cami, mod
end

local function nc(env)
	return env:Get("NC")
end

local function cami(env)
	return nc(env).Modules:Instance("cami")
end

local function names(privileges)
	local out = {}
	for name in pairs(privileges) do
		out[#out + 1] = name
	end
	table.sort(out)
	return table.concat(out, " ")
end

local function hookIds(server, name)
	local out = {}
	for id in pairs(server.G.hook.GetTable()[name] or {}) do
		out[#out + 1] = id
	end
	table.sort(out)
	return table.concat(out, " ")
end

local OFFERED = "nextcity.nc_cami nextcity.nc_components nextcity.nc_lang nextcity.nc_modules nextcity.nc_net "
	.. "nextcity.nc_net_reset nextcity.nc_perf nextcity.nc_perf_reset nextcity.nc_privileges nextcity.probe.kick "
	.. "nextcity.probe.manage"

describe("CAMI adapter", function()
	it("stays out of the way without CAMI", function()
		local server = boot({ cami = false })
		expect(server:Errors()):toEqual({})
		expect(#server:Lines("WARN")):toBe(0)
		expect(#server:Lines("CAMI")):toBe(0)
		expect(server.undefinedReads.CAMI):toBeNil()
		expect(cami(server).cami):toBeNil()
		local admin = Env.FakePlayer({ name = "Admin", group = "admin" })
		expect(nc(server).Permissions:Can(admin, "probe.manage")):toBe(true)
		expect(nc(server).Permissions:Can(admin, "probe.kick")):toBe(false)
		server:Command("nc_cami")
		expect(#server:Lines("CAMI: not found, the levels of the privileges apply (nc_privileges)")):toBe(1)
		expect(hookIds(server, "CAMI.PlayerUsergroupChanged")):toBe("")
	end)

	it("offers the privileges with their levels, except those of nobody", function()
		local server, api = boot({ mod = false, permissions = { levels = { ["probe.kick"] = "admin" } } })
		expect(server:Errors()):toEqual({})
		expect(#server:Lines("WARN")):toBe(0)
		expect(names(api.privileges)):toBe(OFFERED)
		expect(api.privileges[PREFIX .. "probe.manage"]):toEqual({ Name = "nextcity.probe.manage", MinAccess = "admin",
			Description = "Manage the probe" })
		expect(api.privileges[PREFIX .. "probe.kick"].MinAccess):toBe("admin")
		expect(api.privileges[PREFIX .. "nc_modules"].MinAccess):toBe("superadmin")
		expect(api.privileges[PREFIX .. "nc_cami"].Description):toBe("state of the CAMI adapter")
		expect(#server:Lines("CAMI 20211019: admin mods decide the privileges (11 offered as nextcity.<id>)")):toBe(1)

		-- Another prefix; register = false offers nothing.
		server, api = boot({ mod = false, settings = { prefix = "nc_" } })
		expect(api.privileges.nc_probe_manage):toBeNil()
		expect(api.privileges["nc_probe.manage"].MinAccess):toBe("admin")
		server, api = boot({ settings = { register = false } })
		expect(names(api.privileges)):toBe("")
		server:Command("nc_cami")
		expect(#server:Lines("privileges offered: 0 as nextcity.<id> (register = false), problems: 0")):toBe(1)
	end)

	it("lets the admin mod decide, with its groups and allow lists", function()
		local server, _, mod = boot()
		expect(server:Errors()):toEqual({})
		local permissions = nc(server).Permissions
		mod:Group("moderator", "admin")
		local moderator = Env.FakePlayer({ name = "Moderator", group = "moderator" })
		local admin = Env.FakePlayer({ name = "Admin", group = "admin" })
		local root = Env.FakePlayer({ name = "Root", superadmin = true })

		-- The platform alone takes "moderator" for a user; the admin mod knows it inherits admin.
		expect(permissions:Rank(moderator)):toBe("user")
		expect(permissions:Can(moderator, "probe.manage")):toBe(true)
		expect(permissions:Can(moderator, "probe.kick")):toBe(false)
		expect(permissions:Can(root, "probe.kick")):toBe(true)
		mod:Allow("moderator", PREFIX .. "probe.kick", true)
		expect(permissions:Can(moderator, "probe.kick")):toBe(true)
		expect(permissions:Can(admin, "probe.kick")):toBe(false)
		expect(permissions:Granted(moderator)):toEqual({ "probe.kick", "probe.manage" })

		-- The question carries the target (players only) and the level as the fallback.
		permissions:Can(moderator, "probe.manage", admin)
		expect(mod.last):toEqual({ moderator, PREFIX .. "probe.manage", admin, { Fallback = "admin" } })
		permissions:Can(moderator, "probe.manage", "somebody")
		expect(mod.last[3]):toBeNil()

		-- Commands follow; the console and the privileges of nobody never reach CAMI.
		server:Command("nc_probe", moderator)
		expect(moderator.printed[#moderator.printed]):toBe("probe ran")
		mod:Allow("moderator", PREFIX .. "probe.manage", false)
		server:Command("nc_probe", moderator)
		expect(moderator.printed[#moderator.printed]):toBe("nc_probe: no access")
		local asked = mod.asked
		server:Command("nc_probe")
		expect(permissions:Can(root, "probe.secret")):toBe(false)
		expect(mod.asked):toBe(asked)
		expect(#server:Lines("probe ran")):toBe(1)

		server:Command("nc_cami")
		expect(#server:Lines("CAMI 20211019: ask auto -> admin mods decide; hooks of CAMI.PlayerHasAccess: fakemod"))
			:toBe(1)
		expect(#server:Lines("privileges offered: 11 as nextcity.<id>, problems: 0")):toBe(1)
	end)

	it("leaves the levels in charge while no admin mod answers, unless asked to", function()
		local groups = { groups = { moderator = "admin" } }
		local moderator = Env.FakePlayer({ name = "Moderator", group = "moderator" })
		local root = Env.FakePlayer({ name = "Root", superadmin = true })

		-- CAMI alone (auto): permissions.groups apply, CAMI would not know "moderator".
		local server = boot({ mod = false, permissions = groups })
		expect(nc(server).Permissions:Can(moderator, "probe.manage")):toBe(true)
		server:Command("nc_cami")
		expect(#server:Lines("ask auto -> the levels decide; hooks of CAMI.PlayerHasAccess: none")):toBe(1)

		-- always: the default answer of CAMI (IsAdmin / IsSuperAdmin by MinAccess).
		server = boot({ mod = false, permissions = groups, settings = { ask = "always" } })
		expect(nc(server).Permissions:Can(moderator, "probe.manage")):toBe(false)
		expect(nc(server).Permissions:Can(root, "probe.kick")):toBe(true)

		-- never: the admin mod is not asked, the privileges are still offered.
		local api, mod
		server, api, mod = boot({ permissions = groups, settings = { ask = "never" } })
		mod:Allow("superadmin", PREFIX .. "probe.kick", false)
		expect(nc(server).Permissions:Can(root, "probe.kick")):toBe(true)
		expect(nc(server).Permissions:Can(moderator, "probe.manage")):toBe(true)
		expect(mod.asked):toBe(0)
		expect(api.privileges[PREFIX .. "probe.kick"]):toBeTruthy()

		-- A bad value warns and means auto.
		server = boot({ settings = { ask = "sometimes", prefix = 5 } })
		expect(#server:Lines("setting ask must be \"auto\", \"always\" or \"never\", got sometimes: using auto")):toBe(1)
		expect(#server:Lines("module 'cami': setting 'prefix' must be a string, got number")):toBe(1)
		expect(cami(server).ask):toBe("auto")
	end)

	it("tells a client its privileges right after the admin mod moves it", function()
		local server, api, mod = boot()
		local client, ply = Env.Join(server, { name = "Mod" })
		local mirror = nc(client).Permissions
		expect(mirror:Can(nil, "probe.manage")):toBe(false)
		local sent = #server:Sent("nc.grants")

		-- The group changes and CAMI is signalled: the next tick refreshes, no poll needed.
		mod:SetGroup(ply, "admin")
		server:Advance(0)
		Env.Flush(server, client)
		expect(#server:Sent("nc.grants")):toBe(sent + 1)
		expect(mirror:Can(nil, "probe.manage")):toBe(true)

		-- The SteamID signal (an admin mod changed the group by id) works the same way.
		ply:SetUserGroup("superadmin")
		api.SignalSteamIDUserGroupChanged(ply:SteamID(), "admin", "superadmin", "fakemod")
		server:Advance(0)
		Env.Flush(server, client)
		expect(mirror:Can(nil, "probe.kick")):toBe(true)
		ply:SetUserGroup("user")
		api.SignalSteamIDUserGroupChanged(ply:SteamID64(), "superadmin", "user", "fakemod")
		api.SignalSteamIDUserGroupChanged("STEAM_0:1:404", "user", "admin", "fakemod")
		server:Advance(0)
		Env.Flush(server, client)
		expect(mirror:Can(nil, "probe.kick")):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("offers and withdraws privileges while modules come and go", function()
		local server, api, mod = boot()
		local ctx = nc(server).Modules:Instance("probe").ctx
		local admin = Env.FakePlayer({ name = "Admin", group = "admin" })
		ctx.permissions:Register("dynamic", { level = "admin", desc = "runtime" })
		expect(api.privileges[PREFIX .. "probe.dynamic"].MinAccess):toBe("admin")
		expect(nc(server).Permissions:Can(admin, "probe.dynamic")):toBe(true)
		ctx.permissions:Register("hidden", { level = "nobody" })
		expect(api.privileges[PREFIX .. "probe.hidden"]):toBeNil()
		ctx.permissions:Unregister("dynamic")
		expect(api.privileges[PREFIX .. "probe.dynamic"]):toBeNil()

		nc(server).Modules:Fail("probe", "test")
		expect(names(api.privileges)):toBe("nextcity.nc_cami nextcity.nc_components nextcity.nc_lang "
			.. "nextcity.nc_modules nextcity.nc_net nextcity.nc_net_reset nextcity.nc_perf nextcity.nc_perf_reset "
			.. "nextcity.nc_privileges")

		-- Without the module: no hooks, nothing offered, the levels decide again.
		mod:Group("moderator", "admin")
		local moderator = Env.FakePlayer({ name = "Moderator", group = "moderator" })
		expect(nc(server).Permissions:Can(moderator, "nc_modules")):toBe(false)
		nc(server).Modules:Fail("cami", "test")
		expect(names(api.privileges)):toBe("")
		expect(hookIds(server, "CAMI.PlayerUsergroupChanged")):toBe("")
		expect(hookIds(server, "CAMI.SteamIDUsergroupChanged")):toBe("")
		mod:Allow("moderator", PREFIX .. "nc_modules", true)
		expect(nc(server).Permissions:Can(moderator, "nc_modules")):toBe(false)
	end)

	it("survives an admin mod that does not answer at once or asks back", function()
		local server, api = boot({ mod = false })
		local permissions = nc(server).Permissions
		server.G.hook.Add("CAMI.PlayerHasAccess", "lazymod", function()
			return true
		end)
		local admin = Env.FakePlayer({ name = "Admin", group = "admin" })
		for _ = 1, 7 do
			expect(permissions:Can(admin, "probe.manage")):toBe(true)
		end
		expect(#server:Lines("CAMI PlayerHasAccess('nextcity.probe.manage') failed: ")):toBe(5)
		expect(server:Lines("failed: ")[1]):toContain("did not give an immediate answer")
		server:Command("nc_cami")
		expect(#server:Lines("problems: 7")):toBe(1)

		-- An admin mod that asks Next-City while it answers: the inner question gets the levels.
		server.G.hook.Remove("CAMI.PlayerHasAccess", "lazymod")
		local inner
		server.G.hook.Add("CAMI.PlayerHasAccess", "curiousmod", function(actor, _, callback)
			inner = permissions:Can(actor, "probe.kick")
			callback(true, "curiousmod")
			return true
		end)
		expect(permissions:Can(admin, "probe.kick")):toBe(true)
		expect(inner):toBe(false)
		expect(api.privileges[PREFIX .. "probe.kick"]):toBeTruthy()
		expect(server:Errors()):toEqual({})
	end)

	it("attaches to a CAMI that comes after the gamemode", function()
		local server = boot({ cami = false })
		local api = Cami.Install(server)
		local mod = Cami.AdminMod(server, api)
		mod:Group("moderator", "admin")
		local moderator = Env.FakePlayer({ name = "Moderator", group = "moderator" })
		expect(nc(server).Permissions:Can(moderator, "probe.manage")):toBe(false)
		server:Call("InitPostEntity")
		expect(names(api.privileges)):toBe(OFFERED)
		expect(nc(server).Permissions:Can(moderator, "probe.manage")):toBe(true)
		server:Call("InitPostEntity")
		expect(#server:Lines("CAMI 20211019: admin mods decide")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("keeps working across autorefresh", function()
		local server, api, mod = boot()
		local client, ply = Env.Join(server, { name = "Mod", group = "moderator" })
		mod:Group("moderator", "admin")
		mod:Allow("admin", PREFIX .. "nc_modules", true)
		mod:Allow("admin", PREFIX .. "probe.manage", false)
		mod:Allow("moderator", PREFIX .. "probe.manage", true)
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		Env.Flush(server, client)
		expect(server:Errors()):toEqual({})
		expect(names(api.privileges)):toBe(OFFERED)
		expect(hookIds(server, "CAMI.PlayerUsergroupChanged")):toBe("nextcity.cami")
		expect(hookIds(server, "CAMI.SteamIDUsergroupChanged")):toBe("nextcity.cami")

		-- The admin mod keeps its decisions: re-offered privileges do not reset them.
		local permissions = nc(server).Permissions
		expect(permissions:Can(ply, "nc_modules")):toBe(true)
		expect(permissions:Can(ply, "probe.manage")):toBe(true)
		expect(permissions:Can(Env.FakePlayer({ name = "Admin", group = "admin" }), "probe.manage")):toBe(false)
		server:Advance(1)
		Env.Flush(server, client)
		expect(nc(client).Permissions:Can(nil, "nc_modules")):toBe(true)
		mod:SetGroup(ply, "user")
		server:Advance(0)
		Env.Flush(server, client)
		expect(nc(client).Permissions:Can(nil, "nc_modules")):toBe(false)
		expect(client:Errors()):toEqual({})
	end)
end)
