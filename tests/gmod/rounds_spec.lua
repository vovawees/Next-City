-- Rounds module: phases, the mode and rule callbacks, parameters, respawns, time limits,
-- console commands and the client HUD, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local SPAWNS = {
	{ class = "info_player_start", pos = Vector(0, 0, 0), map = true },
	{ class = "info_player_start", pos = Vector(500, 0, 0), map = true },
	{ class = "info_player_start", pos = Vector(1000, 0, 0), map = true },
	{ class = "info_player_start", pos = Vector(1500, 0, 0), map = true },
}

local RECORDED = { "Setup", "PlayerAdded", "Start", "PlayerSpawned", "Loadout", "PlayerDied", "PlayerLeft", "End",
	"Cleanup" }

local function label(value)
	if type(value) == "table" and value.reason ~= nil then
		return " " .. value.reason
	end
	if type(value) == "table" and value.Nick ~= nil then
		return " " .. value:Nick()
	end
	return ""
end

-- Mode "test" (2 players) that records its notifications into log; def adds settings
-- and callbacks (a recorded callback runs after the record).
local function mode(log, def)
	local result = { id = "test", name = "Test", minPlayers = 2 }
	for key, value in pairs(def or {}) do
		result[key] = value
	end
	for _, name in ipairs(RECORDED) do
		local extra = result[name]
		result[name] = function(round, subject, ...)
			log[#log + 1] = name .. label(subject)
			if extra ~= nil then
				return extra(round, subject, ...)
			end
		end
	end
	return result
end

local function take(log)
	local copy = {}
	for i, entry in ipairs(log) do
		copy[i] = entry
		log[i] = nil
	end
	return copy
end

-- A server with players and rounds; opts.settings go over { mode = "test", shuffle = false },
-- opts.modes are registered after the boot (in waiting), opts.files are extra files.
local function boot(opts)
	opts = opts or {}
	local settings = { mode = "test", shuffle = false }
	for key, value in pairs(opts.settings or {}) do
		settings[key] = value
	end
	local server = Env.Server({ modules = { "players", "rounds" }, files = opts.files,
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
	for _, def in ipairs(opts.modes or {}) do
		rounds:RegisterMode(def)
	end
	return server, rounds, NC.Modules:Instance("players")
end

-- Bots join and are ready on the next tick.
local function bots(server, ...)
	local list = {}
	for i, name in ipairs({ ... }) do
		list[i] = Env.Bot(server, { name = name })
	end
	server:Advance(0.1)
	return unpack(list)
end

-- The client catches up with the server: same game time, messages delivered.
local function sync(server, client)
	client.time = server.time
	Env.Flush(server, client)
	return client:Get("NC").Modules:Instance("rounds")
end

local function hud(client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("rounds", function()
	it("waits for players with a warmup, then prepares and starts a round", function()
		local log = {}
		local server, rounds, players = boot({ modes = { mode(log) } })
		local a = bots(server, "A")
		expect(server:Errors()):toEqual({})
		expect(rounds:Phase()):toBe("waiting")
		expect(rounds:Round()):toBeNil()
		expect(players:IsAlive(a)):toBe(true)
		expect(a:IsFrozen()):toBe(false)
		expect(log):toEqual({})

		local cleanups = server.cleanups or 0
		local b = bots(server, "B")
		expect(rounds:Phase()):toBe("preparing")
		expect(server.cleanups):toBe(cleanups + 1)
		expect(take(log)):toEqual({ "Setup", "PlayerAdded A", "PlayerAdded B", "Loadout A", "PlayerSpawned A",
			"Loadout B", "PlayerSpawned B" })
		local round = rounds:Round()
		expect(round.number):toBe(1)
		expect(round.mode):toBe("test")
		expect(round:Participants()):toEqual({ a, b })
		expect(a:IsFrozen()):toBe(true)
		expect(b:IsFrozen()):toBe(true)
		expect(server:Call("PlayerShouldTakeDamage", a, b)):toBe(false)

		server:Advance(4.9)
		expect(rounds:Phase()):toBe("preparing")
		server:Advance(0.2)
		expect(rounds:Phase()):toBe("active")
		expect(take(log)):toEqual({ "Start" })
		expect(a:IsFrozen()):toBe(false)
		expect(b:IsFrozen()):toBe(false)
		expect(round:TimeLeft()):toBeNil()
		expect(server:Call("PlayerShouldTakeDamage", a, b)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("ends a round on a win, shows the result and starts the next round", function()
		local log = {}
		local died = 0
		local server, rounds, players = boot({ modes = { mode(log, {
			Setup = function(round)
				round:On("players.died", function()
					died = died + 1
				end)
			end,
			CheckWin = function(round)
				local alive = round:Alive()
				if alive[2] == nil then
					return { reason = "last", winner = alive[1], score = 3 }
				end
			end,
		}) } })
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local barney = bots(server, "Barney")
		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		take(log)

		Env.Kill(barney, gordon)
		expect(take(log)):toEqual({ "PlayerDied Barney" })
		expect(died):toBe(1)
		expect(rounds:Phase()):toBe("active")
		server:Advance(0.1)
		expect(rounds:Phase()):toBe("ended")
		expect(take(log)):toEqual({ "End last" })
		local round = rounds:Round()
		expect(round.result):toEqual({ reason = "last", winner = gordon, score = 3 })
		expect(server:Call("PlayerShouldTakeDamage", gordon, barney)):toBe(false)

		local view = sync(server, client)
		expect(client:Errors()):toEqual({})
		expect(view:Phase()):toBe("ended")
		expect(view:Result().winner):toBe(gordon)
		expect(hud(client)):toEqual({ "Test: round 1", "Next round in 0:08", "Gordon wins", "Last one standing" })

		-- The round scope ends with the round: its listener is gone.
		server:Advance(8)
		expect(take(log)):toEqual({ "Cleanup", "Setup", "PlayerAdded Gordon", "PlayerAdded Barney", "Loadout Gordon",
			"PlayerSpawned Gordon", "Loadout Barney", "PlayerSpawned Barney" })
		expect(rounds:Phase()):toBe("preparing")
		expect(rounds:Round().number):toBe(2)
		expect(players:IsAlive(barney)):toBe(true)
		server:Advance(5)
		Env.Kill(barney, gordon)
		expect(died):toBe(2)

		view = sync(server, client)
		expect(view:Result()):toBeNil()
		expect(hud(client)):toEqual({ "Test: round 2" })
		expect(server:Errors()):toEqual({})
	end)

	it("calls rules before the mode and asks the mode first", function()
		local log = {}
		local server, rounds = boot()
		rounds:RegisterRule({
			id = "first",
			Setup = function()
				log[#log + 1] = "rule Setup"
			end,
			SpawnPoint = function()
				return { pos = Vector(-300, 0, 0) }
			end,
		})
		rounds:RegisterMode({
			id = "test",
			minPlayers = 2,
			rules = { "first" },
			Setup = function()
				log[#log + 1] = "mode Setup"
			end,
			SpawnPoint = function(_, ply)
				if ply:Nick() == "A" then
					return { pos = Vector(300, 0, 0) }
				end
			end,
		})
		local a, b = bots(server, "A", "B")
		expect(log):toEqual({ "rule Setup", "mode Setup" })
		expect(a:GetPos()):toEqual(Vector(300, 0, 0))
		expect(b:GetPos()):toEqual(Vector(-300, 0, 0))
		expect(rounds:Round():RuleData("first")):toEqual({})
		expect(rounds:Round():RuleData("other")):toBeNil()
	end)

	it("resolves parameters from rules, the mode, the config and the console", function()
		local server, rounds = boot({ settings = { params = { test = { lives = 9, roundTime = 200, color = "red" } } } })
		rounds:RegisterRule({ id = "limits", params = {
			roundTime = { type = "number", default = 300, min = 10, max = 1000 },
			hard = { type = "boolean" },
		} })
		rounds:RegisterMode({ id = "test", minPlayers = 2, rules = { "limits" }, params = {
			roundTime = { type = "number", default = 120, min = 10, max = 600 },
			lives = { type = "integer", default = 1, min = 1, max = 5 },
		} })
		expect(rounds:ParamSet("test"):Names()):toEqual({ "hard", "lives", "roundTime" })
		expect(rounds:ResolveParams("test")):toEqual({ hard = false, lives = 5, roundTime = 200 })
		expect(#server:Lines("config params of mode 'test': param 'lives': 9 is above the maximum 5; using 5")):toBe(1)
		expect(#server:Lines("config params of mode 'test': unknown param 'color'")):toBe(1)

		local fixed, problem = rounds:SetParam("test", "roundTime", 5000)
		expect(fixed):toBe(600)
		expect(problem):toBe("5000 is above the maximum 600")
		expect(rounds:SetParam("test", "roundTime", 45)):toBe(45)
		expect({ rounds:SetParam("test", "speed", 1) }):toEqual({ nil, "mode 'test' has no param 'speed'" })
		expect({ rounds:SetParam("nope", "speed", 1) }):toEqual({ nil, "unknown mode 'nope'" })

		bots(server, "A", "B")
		expect(rounds:Round().params):toEqual({ hard = false, lives = 5, roundTime = 45 })
		rounds:ResetParam("test", "roundTime")
		expect(rounds:Restart()):toBe(true)
		expect(rounds:Round().number):toBe(2)
		expect(rounds:Round().params.roundTime):toBe(200)
		-- Config problems are reported once.
		expect(#server:Lines("unknown param 'color'")):toBe(1)
	end)

	it("ends the round when time is up", function()
		local log = {}
		local server, rounds = boot({
			settings = { params = { test = { roundTime = 30 } } },
			modes = { mode(log, { rules = { "time_limit" }, Timeout = function()
				return { reason = "time", team = 2 }
			end }) },
		})
		local client = Env.Join(server, { name = "Gordon" })
		bots(server, "B")
		local view = sync(server, client)
		expect(hud(client)):toEqual({ "Test: round 1", "Starts in 0:05" })

		server:Advance(5)
		local round = rounds:Round()
		expect(rounds:Phase()):toBe("active")
		expect(round:TimeLeft()):toBeCloseTo(30, 1e-6)
		view = sync(server, client)
		expect(view:TimeLeft()):toBeCloseTo(30, 1e-3)
		expect(hud(client)):toEqual({ "Test: round 1", "0:30" })
		server:Advance(0.5)
		client.time = server.time
		expect(hud(client)):toEqual({ "Test: round 1", "0:30" })
		server:Advance(0.6)
		client.time = server.time
		expect(hud(client)):toEqual({ "Test: round 1", "0:29" })

		server:Advance(28.8)
		expect(rounds:Phase()):toBe("active")
		server:Advance(0.2)
		expect(rounds:Phase()):toBe("ended")
		expect(round.result):toEqual({ reason = "time", team = 2 })
		expect(log[#log]):toBe("End time")

		-- Without a Timeout answer time is up as a draw.
		rounds:RegisterMode(mode(log, { rules = { "time_limit" } }))
		expect(rounds:Restart()):toBe(true)
		server:Advance(5)
		server:Advance(30)
		expect(rounds:Round().result):toEqual({ reason = "time" })
	end)

	it("shows the status line of the mode with its countdown, to late clients too, until the end", function()
		local server, rounds
		server, rounds = boot({
			files = { ["nextcity/lang/en/test.lua"] = "return { wave = 'Wave {wave} of {who}: {time}',"
				.. " calm = 'Calm', who = 'the dead', lost = 'Lost to {who}', fell = 'Fell on wave {wave}' }" },
			modes = { { id = "test", name = "Test", minPlayers = 2,
				Start = function(round)
					round:SetStatus("test.wave", { wave = 2, who = { key = "test.who" } }, server.time + 20)
				end,
			} },
		})
		local client = Env.Join(server, { name = "Gordon" })
		bots(server, "B")
		server:Advance(5)
		sync(server, client)
		expect(hud(client)):toEqual({ "Test: round 1", "Wave 2 of the dead: 0:20" })
		server:Advance(1.5)
		client.time = server.time
		expect(hud(client)):toEqual({ "Test: round 1", "Wave 2 of the dead: 0:19" })
		expect(client:Get("NC").Modules:Instance("rounds"):Status().key):toBe("test.wave")

		-- A late client gets it when he becomes ready; nil clears it.
		local late = Env.Join(server, { name = "Late" })
		server:Advance(1)
		sync(server, late)
		expect(hud(late)):toContain("Wave 2 of the dead: 0:18")
		rounds:Round():SetStatus("test.calm")
		sync(server, client)
		expect(hud(client)):toEqual({ "Test: round 1", "Calm" })
		rounds:Round():SetStatus(nil)
		sync(server, client)
		expect(hud(client)):toEqual({ "Test: round 1" })

		-- The end of the round clears it; the texts of a result have params too.
		rounds:Round():SetStatus("test.calm")
		rounds:Round():End({ reason = "test.fell", key = "test.lost", params = { wave = 3, who = { key = "test.who" } } })
		server:Advance(0.1)
		sync(server, client)
		expect(hud(client)):notToContain("Calm")
		expect(hud(client)):toContain("Lost to the dead")
		expect(hud(client)):toContain("Fell on wave 3")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("respawns dead participants and lets late players join", function()
		local server, rounds, players = boot({
			settings = { params = { test = { respawnDelay = 3 } } },
			modes = { { id = "test", minPlayers = 2, rules = { "respawn" } } },
		})
		local a, b = bots(server, "A", "B")
		server:Advance(5)
		local round = rounds:Round()
		Env.Kill(a, b)
		expect(players:State(a)):toBe("dead")
		expect(round:IsRespawning(a)):toBe(true)
		expect(round:RespawnCount()):toBe(1)
		expect(players:RespawnAt(a)):toBeCloseTo(server.time + 3, 1e-6)
		server:Advance(2.9)
		expect(players:State(a)):toBe("dead")
		server:Advance(0.2)
		expect(players:State(a)):toBe("alive")
		expect(round:IsRespawning(a)):toBe(false)
		expect(round:RespawnCount()):toBe(0)
		expect(players:RespawnAt(a)):toBeNil()

		-- The rule lets a player that became ready join the active round.
		local c = bots(server, "C")
		expect(round:IsParticipant(c)):toBe(true)
		expect(players:IsAlive(c)):toBe(true)

		-- A respawn is cancelled when its player leaves.
		Env.Kill(c, b)
		Env.Leave(server, c)
		expect(round:RespawnCount()):toBe(0)

		-- Waves: everybody dead at least respawnDelay comes back on the next wave.
		rounds:SetParam("test", "respawn", "wave")
		rounds:SetParam("test", "waveInterval", 10)
		expect(rounds:Restart()):toBe(true)
		server:Advance(5)
		round = rounds:Round()
		server:Advance(2)
		Env.Kill(a, b)
		expect(players:RespawnAt(a)):toBeCloseTo(round.startedAt + 10, 1e-6)
		server:Advance(7.9)
		expect(players:State(a)):toBe("dead")
		server:Advance(0.2)
		expect(players:State(a)):toBe("alive")
		expect(server:Errors()):toEqual({})
	end)

	it("keeps deaths quiet and the living away from the chat and voice of the dead", function()
		local server, rounds = boot({
			modes = { { id = "test", minPlayers = 2, rules = { "silent_deaths", "dead_mute" } } },
		})
		local GM = server:Get("GM")
		local a, b, c = bots(server, "A", "B", "C")
		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		local notices = #(server.deathNotices or {})
		Env.Kill(a, b)
		expect(#(server.deathNotices or {})):toBe(notices)
		local _, seen = Env.Say(server, a, "it was B")
		expect(seen):toEqual({ a })
		_, seen = Env.Say(server, b, "nobody saw it")
		expect(seen):toEqual({ a, b, c })
		expect({ GM:PlayerCanHearPlayersVoice(b, a) }):toEqual({ false, false })
		expect({ GM:PlayerCanHearPlayersVoice(a, b) }):toEqual({ true, false })

		-- The rules end with their round.
		rounds:RegisterMode({ id = "plain", minPlayers = 2 })
		expect(rounds:Restart("plain")):toBe(true)
		server:Advance(5)
		expect(rounds:Round().mode):toBe("plain")
		Env.Kill(c, b)
		expect(#server.deathNotices):toBe(notices + 1)
		_, seen = Env.Say(server, c, "B again")
		expect(seen):toEqual({ a, b, c })
		expect(server:Errors()):toEqual({})
	end)

	it("keeps players that do not take part as spectators", function()
		local log = {}
		local server, rounds, players = boot({ modes = { mode(log, {
			minPlayers = 3,
			Participants = function(_, ready)
				return { ready[1], ready[2] }
			end,
		}) } })
		local a, b, c = bots(server, "A", "B", "C")
		expect(rounds:Phase()):toBe("preparing")
		expect(rounds:Round():Participants()):toEqual({ a, b })
		expect(players:State(c)):toBe("spectator")
		expect(players:IsAlive(a)):toBe(true)

		-- Without a LateJoin answer nobody joins an active round.
		server:Advance(5)
		local d = bots(server, "D")
		expect(rounds:Round():IsParticipant(d)):toBe(false)
		expect(players:State(d)):toBe("spectator")
		expect(rounds:Round():AddParticipant(d)):toBe(true)
		expect(players:IsAlive(d)):toBe(true)
		expect(rounds:Round():AddParticipant(d)):toBe(false)
	end)

	it("falls back to waiting when players leave and ends abandoned rounds", function()
		local log = {}
		local server, rounds = boot({ modes = { mode(log) } })
		local a, b = bots(server, "A", "B")
		take(log)
		Env.Leave(server, b)
		expect(rounds:Phase()):toBe("waiting")
		expect(take(log)):toEqual({ "PlayerLeft B", "Cleanup" })
		expect(rounds:Round()):toBeNil()
		expect(a:IsFrozen()):toBe(false)

		-- A forced round with one player; the round ends when nobody is left.
		expect(rounds:Restart()):toBe(true)
		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		take(log)
		Env.Leave(server, a)
		expect(rounds:Phase()):toBe("ended")
		expect(take(log)):toEqual({ "PlayerLeft A", "End abandoned" })
		server:Advance(8)
		expect(rounds:Phase()):toBe("waiting")
		expect(take(log)):toEqual({ "Cleanup" })
		expect({ rounds:Restart() }):toEqual({ false, "no ready players" })
		expect(server:Errors()):toEqual({})
	end)

	it("rotates modes and follows the admin's choice", function()
		local server, rounds = boot({
			settings = { mode = "one", rotation = { "one", "two" }, roundsPerMode = 1, prepareTime = 1, endTime = 1 },
			modes = { { id = "one" }, { id = "two" } },
		})
		bots(server, "A")
		local function play()
			local id = rounds:Round().mode
			server:Advance(1)
			rounds:Round():End({ reason = "admin" })
			server:Advance(1)
			return id
		end
		expect(play()):toBe("one")
		expect(play()):toBe("two")
		expect(rounds:SetNextMode("two")):toBe(true)
		expect(play()):toBe("one")
		expect(play()):toBe("two")
		expect(play()):toBe("one")
		expect({ rounds:SetNextMode("three") }):toEqual({ false, "mode 'three' is not available: not registered" })
	end)

	it("runs a warmup while waiting for players", function()
		local server, rounds, players = boot({
			settings = { warmupLoadout = { "weapon_crowbar" }, warmupRespawn = 3 },
			modes = { { id = "test", name = "Test", minPlayers = 3 } },
		})
		local a = bots(server, "A")
		expect(rounds:Phase()):toBe("waiting")
		expect(players:IsAlive(a)):toBe(true)
		expect(a:WeaponClasses()):toEqual({ "weapon_crowbar" })
		expect(server:Call("PlayerShouldTakeDamage", a, a)):toBe(true)
		Env.Kill(a)
		expect(players:RespawnAt(a)):toBeCloseTo(server.time + 3, 1e-6)
		server:Advance(3)
		expect(players:IsAlive(a)):toBe(true)

		local client = Env.Join(server, { name = "Gordon" })
		server:Advance(0.2)
		sync(server, client)
		expect(hud(client)):toEqual({ "Test", "Waiting for players: 2/3" })
	end)

	it("lets admins restart, end and tune rounds from the console", function()
		local server, rounds = boot({ modes = { { id = "test", name = "Test", minPlayers = 2, rules = { "time_limit" },
			params = { lives = { type = "integer", default = 1, min = 1, max = 5 } } } } })
		local admin = Env.FakePlayer({ name = "Admin", superadmin = true })
		local function run(...)
			admin.printed = {}
			server:Command("nc_round", admin, { ... })
			return admin.printed
		end
		bots(server, "A")
		expect(run()):toEqual({ "Phase waiting, 1 ready players", "Next: test (needs 2 players)" })
		expect(run("restart")):toEqual({ "nc_round: a new round starts" })
		expect(rounds:Phase()):toBe("preparing")
		expect(run("param", "test", "roundTime", "45")):toEqual({ "nc_round: test.roundTime = 45 from the next round" })
		expect(run("param", "test", "lives", "9")):toEqual({
			"nc_round: test.lives = 5 from the next round (9 is above the maximum 5)" })
		expect(run("param", "test", "lives", "abc")):toEqual({ "nc_round: 'abc' is not a number" })
		expect(run("param", "test", "speed")):toEqual({ "nc_round: mode 'test' has params: lives, roundTime" })
		expect(run("param", "test", "lives")):toEqual({ "nc_round: test.lives is back to 1 from the next round" })
		expect(run("next", "nope")):toEqual({ "nc_round: mode 'nope' is not available: not registered" })
		expect(run("next", "test")):toEqual({ "nc_round: the next round plays 'test'" })
		server:Advance(5)
		expect(run()):toEqual({
			"Round 1 (test): active, 5:00 left",
			"Participants 1: alive 1, respawning 0",
			"Params: lives = 1, roundTime = 300",
			"Next: test (needs 2 players), chosen by an admin",
		})
		expect(run("end")):toEqual({ "nc_round: the round ended" })
		expect(rounds:Round().result):toEqual({ reason = "admin" })
		expect(run("end")):toEqual({ "nc_round: no round is running" })
		expect(run("bogus")[1]):toBe("nc_round: unknown action 'bogus'")

		-- Everybody may list the modes.
		local guest = Env.FakePlayer({ name = "Guest" })
		server:Command("nc_modes", guest, {})
		expect(guest.printed):toEqual({
			"test  Test  min 2 players  rules: time_limit",
			"    lives            integer 1..5 = 1",
			"    roundTime        number 0..86400 = 45  -- round length, s (0 = no limit)",
		})
		server:Command("nc_round", guest, {})
		expect(guest.printed[#guest.printed]):toBe("nc_round: superadmin only")
	end)

	it("rejects broken definitions and skips modes that cannot be played", function()
		local server, rounds = boot()
		expect(function()
			rounds:RegisterMode({ id = "x", Chekwin = function() end })
		end):toFail("mode 'x': unknown key 'Chekwin'")
		expect(function()
			rounds:RegisterMode({ id = "Bad Id" })
		end):toFail("mode id must match")
		expect(function()
			rounds:RegisterMode({ id = "x", minPlayers = 0 })
		end):toFail("mode 'x': minPlayers must be an integer 1..255")
		expect(function()
			rounds:RegisterMode({ id = "x", params = { n = { type = "number" } } })
		end):toFail("mode 'x': params: n")
		expect(function()
			rounds:RegisterMode({ id = "x", rules = { "a", "a" } })
		end):toFail("mode 'x': rule 'a' is listed twice")
		expect(function()
			rounds:RegisterRule({ id = "r", Setup = 5 })
		end):toFail("rule 'r': callback 'Setup' must be a function")
		expect(function()
			rounds:RegisterRule({ id = "r" }, {})
		end):toFail("rule 'r': the owner must be the module context (ctx)")

		local alive = true
		local owner = { id = "mode_one", IsAlive = function() return alive end }
		local other = { id = "mode_two", IsAlive = function() return true end }
		rounds:RegisterMode({ id = "taken" }, owner)
		expect(function()
			rounds:RegisterMode({ id = "taken" }, other)
		end):toFail("mode 'taken' is already registered by module 'mode_one'")

		-- The configured mode needs a missing rule: another mode is played.
		rounds:RegisterMode({ id = "test", rules = { "missing" } })
		expect({ rounds:IsAvailable("test") }):toEqual({ false, "rule 'missing' is not registered" })
		bots(server, "A")
		expect(rounds:Round().mode):toBe("taken")
		expect(#server:Lines("mode 'test' is not available (rule 'missing' is not registered); playing 'taken'"))
			:toBe(1)

		-- Its module stops: the round is aborted and nothing is left to play.
		alive = false
		expect({ rounds:IsAvailable("taken") }):toEqual({ false, "module 'mode_one' is stopped" })
		server:Advance(1)
		expect(rounds:Phase()):toBe("waiting")
		expect(rounds:Round()):toBeNil()
		expect(#server:Lines("round 1: mode 'taken' is no longer available (module 'mode_one' is stopped)")):toBe(1)
		expect(#server:Lines("no mode to play: mode 'test' is not available")):toBe(1)
		-- A stopped module's mode can be registered again.
		rounds:RegisterMode({ id = "taken" }, other)
		expect(rounds:IsAvailable("taken")):toBe(true)
	end)

	it("thinks at the rate of the mode and lets it decide about damage", function()
		local thinks = 0
		local server, rounds = boot({ modes = { { id = "test", minPlayers = 2, thinkRate = 4,
			Think = function()
				thinks = thinks + 1
			end,
			ShouldTakeDamage = function(_, ply, attacker)
				if ply:Nick() == "A" and attacker:Nick() == "B" then
					return false
				end
			end,
		} } })
		local a, b = bots(server, "A", "B")
		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		for _ = 1, 8 do
			server:Advance(0.25)
		end
		expect(thinks):toBe(8)
		expect(server:Call("PlayerShouldTakeDamage", a, b)):toBe(false)
		expect(server:Call("PlayerShouldTakeDamage", b, a)):toBe(true)

		-- No thinking once the round is over.
		rounds:Round():End({ reason = "admin" })
		server:Advance(0.25)
		expect(thinks):toBe(8)
	end)

	it("logs failing callbacks and goes on", function()
		local server, rounds = boot({ modes = { { id = "test", minPlayers = 1,
			Setup = function()
				error("setup broke")
			end,
			Start = function(round)
				round.data.started = true
			end,
		} } })
		bots(server, "A")
		local errors = server:Errors()
		expect(#errors):toBe(1)
		expect(errors[1]):toContain("round 1: mode 'test' Setup failed:")
		expect(errors[1]):toContain("setup broke")
		server:Advance(5)
		expect(rounds:Phase()):toBe("active")
		expect(rounds:Round().data.started):toBe(true)
	end)
end)
