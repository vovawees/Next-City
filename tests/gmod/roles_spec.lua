-- Roles: registry on both realms, who knows which role, the HUD of one's own role, dealing
-- roles at random, the rule roles of rounds (reveal at the end, clear after) and the
-- commands, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local MODULES = "nextcity/gamemode/modules/"

-- A module with the roles of a murder mystery and a public job.
local KIT = {
	[MODULES .. "rolekit/module.lua"] = [[
		return { id = "rolekit", requires = { "roles" }, files = { sh = { "sh_rolekit.lua" } } }
	]],
	[MODULES .. "rolekit/sh_rolekit.lua"] = [[
		local M = NC.Module("rolekit")
		function M:Init(ctx)
			local roles = ctx:Require("roles")
			roles:Register("murderer", { name = "Murderer", description = "Kill them all", visible = "side",
				color = Color(200, 40, 40) })
			roles:Register("sheriff", { name = "Sheriff", side = "innocent", description = "Find the murderer" })
			roles:Register("innocent", { name = "Innocent", intro = false })
			roles:Register("cop", { name = "Cop", visible = "all" })
		end
	]],
}

local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = opts.modules or { "players", "roles", "rolekit" }, files = KIT,
		patch = opts.patch })
	Env.Spawn(server, { class = "info_player_start", pos = Vector(0, 0, 0), map = true })
	Env.Spawn(server, { class = "info_player_start", pos = Vector(400, 0, 0), map = true })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC.Modules:Instance("roles"), NC
end

local function roleOf(client, ply)
	return client:Get("NC").Modules:Instance("roles"):Of(ply)
end

local function sync(server, ...)
	server:Advance(0.05)
	Env.Flush(server, ...)
end

describe("roles", function()
	it("registers roles in the same order on both realms and checks them", function()
		local server, roles = boot()
		local client = Env.Join(server, { name = "Alice" })
		local mirror = client:Get("NC").Modules:Instance("roles")
		expect(roles:All()):toEqual({ "murderer", "sheriff", "innocent", "cop" })
		expect(mirror:All()):toEqual(roles:All())
		expect(mirror:Index("cop")):toBe(4)
		expect(roles:Def("sheriff").side):toBe("innocent")
		expect(roles:Def("innocent").name):toBe("Innocent")
		expect(roles:Def("cop").intro):toBe(true)
		expect(function() roles:Register("Bad") end):toFail("lower_snake_case")
		expect(function() roles:Register("odd", { visible = "friends" }) end):toFail("self, side or all")
		expect(function() roles:Assign(client, "ghost") end):toFail("unknown role")
		expect(server:Errors()):toEqual({})
	end)

	it("tells each client only the roles he may know", function()
		local server, roles = boot()
		local ca, alice = Env.Join(server, { name = "Alice" })
		local cb, bob = Env.Join(server, { name = "Bob" })
		local cc, carol = Env.Join(server, { name = "Carol" })
		local cd, dave = Env.Join(server, { name = "Dave" })
		roles:Assign(alice, "murderer")
		roles:Assign(bob, "murderer")
		roles:Assign(carol, "sheriff")
		roles:Assign(dave, "cop")
		sync(server, ca, cb, cc, cd)
		expect(roleOf(ca, alice)):toBe("murderer")
		expect(roleOf(ca, bob)):toBe("murderer")    -- an ally of the side
		expect(roleOf(ca, carol)):toBeNil()          -- hidden
		expect(roleOf(ca, dave)):toBe("cop")         -- public
		expect(roleOf(cc, alice)):toBeNil()
		expect(roleOf(cc, carol)):toBe("sheriff")
		expect(roles:Knows(carol, alice)):toBe(false)
		expect(roles:Side(carol)):toBe("innocent")
		expect(roles:Members("murderer")):toEqual({ alice, bob })
		expect(roles:OnSide("innocent")):toEqual({ carol })
		local mirror = ca:Get("NC").Modules:Instance("roles")
		expect(mirror:Mine()):toBe("murderer")
		expect(mirror:Allies()):toEqual({ bob })

		roles:Reveal(true)
		sync(server, ca, cb, cc, cd)
		expect(roleOf(cc, alice)):toBe("murderer")
		expect(cc:Get("NC").Modules:Instance("roles"):IsRevealed()):toBe(true)
		roles:Clear()
		sync(server, ca, cb, cc, cd)
		expect(roleOf(ca, alice)):toBeNil()
		expect(roles:IsRevealed()):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(ca:Errors()):toEqual({})
	end)

	it("shows the own role, its goal and the allies, with a banner when it comes", function()
		local server, roles = boot()
		local ca, alice = Env.Join(server, { name = "Alice" })
		local cr, ivan = Env.Join(server, { name = "Ivan", language = "ru" })
		local _, bob = Env.Join(server, { name = "Bob" })
		roles:Assign(alice, "murderer")
		roles:Assign(bob, "murderer")
		roles:Assign(ivan, "innocent")
		sync(server, ca, cr)
		local function paint(client)
			client.drawn = {}
			client:Call("HUDPaint")
			return client.drawn
		end
		local drawn = paint(ca)
		expect(drawn):toContain("Murderer")
		expect(drawn):toContain("Kill them all")
		expect(drawn):toContain("Allies: Bob")
		expect(drawn):toContain("You are Murderer")
		drawn = paint(cr)
		expect(drawn):toContain("Innocent")
		expect(drawn):notToContain("Вы — Innocent") -- no banner for this role
		server:Advance(7)
		ca:Advance(7)
		Env.Flush(server, ca)
		expect(paint(ca)):notToContain("You are Murderer")
		roles:Assign(alice, nil)
		sync(server, ca)
		expect(paint(ca)):notToContain("Murderer")
		expect(ca:Errors()):toEqual({})
		expect(cr:Errors()):toEqual({})
	end)

	it("deals roles at random for the counts and gives the rest the default", function()
		local server, roles = boot()
		local list = {}
		for i = 1, 6 do
			list[i] = Env.Bot(server, { name = "Bot" .. i })
		end
		local module = server:Get("NC").Modules:Instance("roles")
		module.Random = function(n) return n end -- no shuffle
		local dealt = roles:Deal(list, { { "murderer", 2 }, { "sheriff", 1 } }, "innocent")
		expect(dealt[list[1]]):toBe("murderer")
		expect(dealt[list[2]]):toBe("murderer")
		expect(dealt[list[3]]):toBe("sheriff")
		expect(dealt[list[6]]):toBe("innocent")
		local few = roles:Deal({ list[1] }, { { "murderer", 1 }, { "sheriff", 1 } }, "innocent")
		expect(few[list[1]]):toBe("murderer")
		local counts = {}
		module.Random = math.random
		for _ = 1, 20 do
			for _, id in pairs(roles:Deal(list, { { "murderer", 1 } }, "innocent")) do
				counts[id] = (counts[id] or 0) + 1
			end
		end
		expect(counts.murderer):toBe(20)
		expect(counts.innocent):toBe(100)
	end)

	it("reveals the roles when a round ends and clears them after it with the rule roles", function()
		local server, roles, NC = boot({ modules = { "players", "rounds", "roles", "rolekit" },
			patch = { [Env.CONFIG] = function(cfg)
				cfg.modules.settings.rounds = { mode = "who", shuffle = false, prepareTime = 1, endTime = 2 }
				return cfg
			end } })
		local rounds = NC.Modules:Instance("rounds")
		rounds:RegisterMode({ id = "who", name = "Who", minPlayers = 2, rules = { "roles" },
			PlayerAdded = function(round, ply)
				local alice = ply:Nick() == "Alice"
				roles:Assign(ply, alice == (round.number % 2 == 1) and "murderer" or "innocent")
			end })
		local ca, alice = Env.Join(server, { name = "Alice" })
		local cb, bob = Env.Join(server, { name = "Bob" })
		server:Advance(0.1)
		server:Advance(1.1)
		Env.Flush(server, ca, cb)
		expect(rounds:Phase()):toBe("active")
		expect(roles:Of(alice)):toBe("murderer")
		expect(roleOf(cb, alice)):toBeNil()
		server:Command("nc_round", nil, { "end" })
		sync(server, ca, cb)
		expect(rounds:Phase()):toBe("ended")
		expect(roleOf(cb, alice)):toBe("murderer")
		server:Advance(2.1)
		sync(server, ca, cb)
		expect(roles:Of(alice)):toBe("innocent") -- a new round dealt again
		expect(roles:Of(bob)):toBe("murderer")
		expect(roles:IsRevealed()):toBe(false)
		expect(roleOf(cb, alice)):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("forgets players who leave and has console commands", function()
		local server, roles = boot()
		local _, alice = Env.Join(server, { name = "Alice" })
		local admin = Env.FakePlayer({ name = "Admin", superadmin = true })
		server:Command("nc_role", admin, { "Alice", "sheriff" })
		expect(admin.printed[#admin.printed]):toBe("Alice is sheriff now")
		expect(roles:Of(alice)):toBe("sheriff")
		server:Command("nc_role", admin, { "Alice", "ghost" })
		expect(admin.printed[#admin.printed]):toBe("unknown role ghost (nc_roles)")
		server:Command("nc_roles", admin, {})
		local found = false
		for _, line in ipairs(admin.printed) do
			if line:find("Alice", 1, true) and line:find("sheriff", 1, true) then
				found = true
			end
		end
		expect(found):toBe(true)
		local assigned = {}
		server:Get("NC").Events:On("roles.assigned", function(ply, id, old)
			assigned[#assigned + 1] = { ply = ply, id = id, old = old }
		end)
		Env.Leave(server, alice)
		expect(roles:Of(alice)):toBeNil()
		expect(assigned[1].old):toBe("sheriff")
		server:Command("nc_role", admin, { "Nobody" })
		expect(admin.printed[#admin.printed]):toContain("Nobody")
		expect(server:Errors()):toEqual({})
	end)
end)
