-- Teams module and the Team Deathmatch mode: the palette, balanced teams, spawn sides,
-- friendly fire, elimination, scores and the full TDM round, with the real gamemode
-- files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local SPAWNS = {
	{ class = "info_player_rebel", pos = Vector(0, 0, 0), map = true },
	{ class = "info_player_rebel", pos = Vector(0, 500, 0), map = true },
	{ class = "info_player_combine", pos = Vector(3000, 0, 0), map = true },
	{ class = "info_player_combine", pos = Vector(3000, 500, 0), map = true },
}

-- A server with players, rounds and teams; opts.settings go over the rounds settings,
-- opts.mode is registered as mode "test" after the boot.
local function boot(opts)
	opts = opts or {}
	local settings = { mode = "test", shuffle = false }
	for key, value in pairs(opts.settings or {}) do
		settings[key] = value
	end
	local server = Env.Server({ modules = opts.modules or { "players", "rounds", "teams" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.rounds = settings
			return cfg
		end } })
	for _, point in ipairs(SPAWNS) do
		Env.Spawn(server, point)
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local rounds = NC.Modules:Instance("rounds")
	if opts.mode ~= nil then
		local def = { id = "test", name = "Test", minPlayers = 2 }
		for key, value in pairs(opts.mode) do
			def[key] = value
		end
		rounds:RegisterMode(def)
	end
	return server, rounds, NC.Modules:Instance("teams"), NC.Modules:Instance("players")
end

local function bots(server, ...)
	local list = {}
	for i, name in ipairs({ ... }) do
		list[i] = Env.Bot(server, { name = name })
	end
	server:Advance(0.1)
	return unpack(list)
end

local function teamsOf(list)
	local out = {}
	for i, ply in ipairs(list) do
		out[i] = ply:Team()
	end
	return out
end

describe("teams", function()
	it("registers the palette in the language of each realm", function()
		local server = boot()
		local team = server:Get("team")
		expect(team.GetName(1)):toBe("Reds")
		expect(team.GetName(4)):toBe("Yellows")
		expect(team.GetColor(2)):toEqual({ r = 52, g = 120, b = 220, a = 255 })
		expect(team.Joinable(1)):toBe(false)

		local client = Env.Join(server, { name = "Gordon", language = "ru" })
		local clientTeam = client:Get("team")
		expect(clientTeam.GetName(1)):toBe("Красные")
		client:SetConVar("nc_language", "en")
		expect(clientTeam.GetName(1)):toBe("Reds")
		expect(client:Errors()):toEqual({})
	end)

	it("balances participants, spawns teams on their sides and blocks friendly fire", function()
		local server, rounds, teams = boot({ mode = { rules = { "teams" } } })
		local a, b, c, d = bots(server, "A", "B", "C", "D")
		expect(rounds:Phase()):toBe("preparing")
		expect(teamsOf({ a, b, c, d })):toEqual({ 1, 2, 1, 2 })
		expect(teams:Members(1)):toEqual({ a, c })
		expect(teams:Count()):toBe(2)
		expect({ a:GetPos().x, c:GetPos().x, b:GetPos().x, d:GetPos().x }):toEqual({ 0, 0, 3000, 3000 })
		expect(a:GetPos()):notToBe(c:GetPos())

		server:Advance(5)
		expect(server:Call("PlayerShouldTakeDamage", a, c)):toBe(false)
		expect(server:Call("PlayerShouldTakeDamage", a, b)):toBe(true)
		expect(server:Call("PlayerShouldTakeDamage", a, a)):toBe(true)
		expect(teams:AliveCount(1)):toBe(2)

		-- A player that does not join the round is a spectator of the teams.
		local e = bots(server, "E")
		expect(e:Team()):toBe(World.TEAM_SPECTATOR)

		-- After the round nobody is in a team; friendly fire is a parameter.
		rounds:SetParam("test", "friendlyFire", true)
		rounds:Restart()
		expect(teamsOf({ a, b, c, d, e })):toEqual({ 1, 2, 1, 2, 1 })
		server:Advance(5)
		expect(server:Call("PlayerShouldTakeDamage", a, c)):toBe(true)
		rounds:Round():End({ reason = "admin" })
		server:Advance(8)
		rounds:Round():End({ reason = "admin" }) -- the next round was preparing
		rounds.modes.test.minPlayers = 9
		server:Advance(8)
		expect(rounds:Phase()):toBe("waiting")
		local unassigned = World.TEAM_UNASSIGNED
		expect(teamsOf({ a, b, c, d, e })):toEqual({ unassigned, unassigned, unassigned, unassigned, unassigned })
		expect(teams:Count()):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("lets a round name the teams in every realm", function()
		local server, rounds, teams = boot({
			settings = { params = { test = { teamNames = { "teams.blue", "teams.red" } } } },
			mode = { rules = { "teams" } },
		})
		local client = Env.Join(server, { name = "Gordon", language = "ru" })
		bots(server, "A")
		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		expect(teams:NameKey(1)):toBe("teams.blue")
		expect(server:Get("team").GetName(2)):toBe("Reds")
		Env.Flush(server, client)
		local clientTeams = client:Get("NC").Modules:Instance("teams")
		expect(clientTeams:NameKey(2)):toBe("teams.red")
		expect(client:Get("team").GetName(1)):toBe("Синие")
		expect(teams:NameKey(3)):toBe("teams.green")

		-- A round without names is back to the palette.
		rounds:SetParam("test", "teamNames", {})
		expect(rounds:Restart()):toBe(true)
		server:Advance(0.1)
		Env.Flush(server, client)
		expect(teams:NameKey(1)):toBe("teams.red")
		expect(clientTeams:NameKey(1)):toBe("teams.red")
		expect(client:Get("team").GetName(2)):toBe("Синие")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("ends the round when one team is left", function()
		local server, rounds = boot({ mode = { rules = { "teams", "team_elimination" } } })
		local a, b, c, d = bots(server, "A", "B", "C", "D")
		server:Advance(5)
		Env.Kill(b, a)
		server:Advance(0.1)
		expect(rounds:Phase()):toBe("active")
		Env.Kill(d, c)
		server:Advance(0.1)
		expect(rounds:Phase()):toBe("ended")
		expect(rounds:Round().result):toEqual({ reason = "elimination", team = 1 })
	end)

	it("scores kills of enemies up to the limit and lets the leader win on time", function()
		local server, rounds, teams = boot({
			settings = { params = { test = { scoreLimit = 2, respawnDelay = 1, roundTime = 60 } } },
			mode = { rules = { "time_limit", "teams", "team_score", "respawn" } },
		})
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local b, c, d = bots(server, "B", "C", "D")
		expect(teamsOf({ gordon, b, c, d })):toEqual({ 1, 2, 1, 2 })
		server:Advance(5)
		Env.Kill(b, gordon)
		Env.Kill(c, gordon) -- a teammate: no score
		Env.Kill(d, d)      -- suicide: no score
		server:Advance(0.1)
		expect({ teams:Score(1), teams:Score(2) }):toEqual({ 1, 0 })
		client.time = server.time
		Env.Flush(server, client)
		local view = client:Get("NC").Modules:Instance("teams")
		expect(view:Count()):toBe(2)
		client.drawn = {}
		client:Call("HUDPaint")
		expect(client.drawn):toContain("Reds 1")
		expect(client.drawn):toContain("Blues 0")

		server:Advance(1)
		Env.Kill(d, gordon)
		server:Advance(0.1)
		expect(rounds:Phase()):toBe("ended")
		expect(rounds:Round().result):toEqual({ reason = "score", team = 1 })

		-- On time: the leader wins, a tie is a draw.
		server:Advance(8)
		server:Advance(5)
		Env.Kill(c, b)
		server:Advance(60)
		expect(rounds:Round().result):toEqual({ reason = "time", team = 2 })
		server:Advance(8)
		server:Advance(5)
		server:Advance(60)
		expect(rounds:Round().result):toEqual({ reason = "time" })
		expect(server:Errors()):toEqual({})
	end)

	it("plays Team Deathmatch out of the box", function()
		local server = Env.Server()
		for _, point in ipairs(SPAWNS) do
			Env.Spawn(server, point)
		end
		server:Boot()
		server:Call("InitPostEntity")
		local NC = server:Get("NC")
		local rounds = NC.Modules:Instance("rounds")
		local teams = NC.Modules:Instance("teams")
		local players = NC.Modules:Instance("players")
		expect(rounds:IsAvailable("tdm")):toBe(true)

		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		local barney = bots(server, "Barney")
		expect(rounds:Phase()):toBe("preparing")
		local round = rounds:Round()
		expect(round.mode):toBe("tdm")
		expect(round.params.roundTime):toBe(600)
		expect(round.params.respawn):toBe("instant")
		expect(gordon:Team() + barney:Team()):toBe(3)
		-- The hands first, then the kit tdm of the official package as items: armor, weapons
		-- in the equipment (the SMG in the hands), ammunition and first aid in the pockets.
		expect(gordon:WeaponClasses()):toEqual({ "nc_hands", "nc_mp7", "nc_usp", "nc_knife", "nc_frag" })
		expect(gordon.selected):toBe("nc_mp7")
		local inventory = NC.Modules:Instance("inventory")
		expect(inventory:Count(gordon, "ammo_46x30")):toBe(120)
		expect(inventory:Count(gordon, "ammo_9x19")):toBe(30)
		expect(inventory:Count(gordon, "bandage")):toBe(2)
		expect(#NC.Modules:Instance("armor"):Worn(gordon)):toBe(2)
		expect(#server:Lines("WARN")):toBe(0)

		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		Env.Kill(barney, gordon)
		server:Advance(0.1)
		expect(teams:Score(gordon:Team())):toBe(1)
		expect(players:RespawnAt(barney)):toBeCloseTo(server.time - 0.1 + 5, 1e-6)
		server:Advance(5)
		expect(players:IsAlive(barney)):toBe(true)

		client.time = server.time
		Env.Flush(server, client)
		client.drawn = {}
		client:Call("HUDPaint")
		expect(client.drawn):toContain("Командный бой: раунд 1")
		expect(client.drawn):toContain("9:55")
		expect(client.drawn):toContain("Бронежилет 100%")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
