-- Players module: life states, deploying, spectating, deaths, spawn points and
-- replication, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local World = Env.World
local Vector = World.Vector
local OBS = World.OBS_MODE

-- Records the events of the players module and can answer players.spawnPoint.
local RECORDER = {
	[MODULES .. "recorder/module.lua"] = "return { id = 'recorder', files = { sv = { 'sv_recorder.lua' } } }",
	[MODULES .. "recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.log = {}
		local EVENTS = { "players.ready", "players.stateChanged", "players.loadout", "players.spawned", "players.died",
			"players.left" }
		function M:Start(ctx)
			for _, name in ipairs(EVENTS) do
				ctx:On(name, function(ply, a, b)
					local entry = name .. " " .. ply:Nick()
					if name == "players.stateChanged" then
						entry = entry .. " " .. tostring(b) .. ">" .. a
					elseif name == "players.died" then
						entry = entry .. " by " .. (IsValid(b) and b:Nick() or "-")
					elseif name == "players.left" then
						entry = entry .. " " .. a
					end
					self.log[#self.log + 1] = entry
				end)
			end
			ctx:On("players.loadout", function(ply)
				if self.weapon then
					ply:Give(self.weapon)
				end
			end)
			ctx:On("players.spawnPoint", function(ply)
				return self.spawn
			end)
		end
		function M:Take()
			local log = self.log
			self.log = {}
			return log
		end
	]],
}

local function boot(opts)
	opts = opts or {}
	local files = RECORDER
	if opts.files ~= nil then
		files = {}
		for path, source in pairs(RECORDER) do
			files[path] = source
		end
		for path, source in pairs(opts.files) do
			files[path] = source
		end
	end
	local server = Env.Server({ files = files, modules = { "players" }, patch = opts.patch })
	for _, point in ipairs(opts.spawns or {}) do
		Env.Spawn(server, point)
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC.Modules:Instance("players"), NC.Modules:Instance("recorder")
end

local function bot(server, name)
	local ply = Env.Bot(server, { name = name })
	server:Advance(0.1)
	return ply
end

describe("players", function()
	it("keeps joining players out of the game until they are deployed", function()
		local server, players, recorder = boot({ spawns = { { class = "info_player_start", map = true } } })
		local client, gordon = Env.Join(server, { name = "Gordon" })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(recorder:Take()):toEqual({
			"players.stateChanged Gordon nil>connecting",
			"players.stateChanged Gordon connecting>spectator",
			"players.ready Gordon",
		})
		expect(players:State(gordon)):toBe("spectator")
		expect(gordon:Alive()):toBe(false)
		expect(gordon:GetObserverMode()):toBe(OBS.ROAMING)
		expect(gordon:WeaponClasses()):toEqual({})
		expect(gordon:GetModel()):toBeNil()

		-- A bot is ready on the next tick.
		local alyx = Env.Bot(server, { name = "Alyx" })
		expect(players:State(alyx)):toBe("connecting")
		server:Advance(0.1)
		expect(players:State(alyx)):toBe("spectator")
		expect(players:Count("spectator")):toBe(2)
		expect(players:ReadyPlayers()):toEqual({ gordon, alyx })
	end)

	it("deploys players with a spawn, the loadout event and no stock weapons", function()
		local server, players, recorder = boot({ spawns = { { class = "info_player_start", pos = Vector(10, 20, 0) } } })
		local alyx = bot(server, "Alyx")
		recorder:Take()
		recorder.weapon = "weapon_crowbar"
		alyx:Give("weapon_old")
		expect(players:Deploy(alyx)):toBe(true)
		expect(recorder:Take()):toEqual({
			"players.stateChanged Alyx spectator>alive",
			"players.loadout Alyx",
			"players.spawned Alyx",
		})
		expect(alyx:Alive()):toBe(true)
		expect(alyx:GetObserverMode()):toBe(OBS.NONE)
		expect(alyx:WeaponClasses()):toEqual({ "weapon_crowbar" })
		expect(alyx:GetPos()):toEqual(Vector(10, 20, 0))
		expect(alyx:GetModel()):toBe("models/player/kleiner.mdl")
		expect(players:List("alive")):toEqual({ alyx })

		-- Deploying an alive player respawns it.
		expect(players:Deploy(alyx)):toBe(true)
		expect(alyx.spawns):toBe(3)
		expect(recorder:Take()):toEqual({ "players.loadout Alyx", "players.spawned Alyx" })
	end)

	it("keeps the dead dead and lets nothing else respawn them", function()
		local server, players, recorder = boot()
		local alyx, barney = bot(server, "Alyx"), bot(server, "Barney")
		players:Deploy(alyx)
		players:Deploy(barney)
		recorder:Take()
		Env.Kill(alyx, barney)
		expect(recorder:Take()):toEqual({ "players.stateChanged Alyx alive>dead", "players.died Alyx by Barney" })
		expect(players:State(alyx)):toBe("dead")
		for _ = 1, 10 do
			server:Advance(1)
		end
		expect(alyx:Alive()):toBe(false)
		expect(players:State(alyx)):toBe("dead")

		-- Somebody else spawns the dead player: it becomes a spectator, not a fighter.
		alyx:Spawn()
		expect(alyx:Alive()):toBe(false)
		expect(alyx:GetObserverMode()):toBe(OBS.ROAMING)
		expect(players:State(alyx)):toBe("spectator")

		-- An alive player respawned by something else stays in the game.
		barney:Spawn()
		expect(barney:Alive()):toBe(true)
		expect(players:State(barney)):toBe("alive")
		expect(server:Errors()):toEqual({})
	end)

	it("makes spectators with a silent death", function()
		local server, players, recorder = boot()
		local alyx = bot(server, "Alyx")
		players:Deploy(alyx)
		recorder:Take()
		expect(players:MakeSpectator(alyx)):toBe(true)
		expect(recorder:Take()):toEqual({ "players.stateChanged Alyx alive>spectator" })
		expect(alyx:Alive()):toBe(false)
		expect(alyx:GetObserverMode()):toBe(OBS.ROAMING)

		-- A suicide still counts as a death.
		players:Deploy(alyx)
		recorder:Take()
		alyx:KillSilent()
		expect(recorder:Take()):toEqual({ "players.stateChanged Alyx alive>dead", "players.died Alyx by -" })
	end)

	it("kills on behalf of an attacker, whatever the rules say", function()
		local server, players, recorder = boot({ files = {
			[MODULES .. "rules/module.lua"] = "return { id = 'rules', files = { sv = { 'sv_rules.lua' } } }",
			[MODULES .. "rules/sv_rules.lua"] = [[
				local M = NC.Module("rules")
				function M:Start(ctx)
					ctx:On("gm.PlayerShouldTakeDamage", function() return false end)
					ctx:On("gm.EntityTakeDamage", function(ent)
						if not NC.Modules:Instance("players"):IsKilling(ent) then
							return true
						end
					end)
				end
			]],
		} })
		local alyx, barney = bot(server, "Alyx"), bot(server, "Barney")
		players:Deploy(alyx)
		players:Deploy(barney)
		recorder:Take()

		-- Ordinary damage is refused by the rules.
		Env.Hurt(alyx, { damage = 1000, attacker = barney })
		expect(alyx:Alive()):toBe(true)

		local weapon = barney:Give("weapon_smg1")
		expect(players:Kill(alyx, { attacker = barney, inflictor = weapon, damageType = World.DMG.BULLET,
			force = Vector(0, 0, 100) })):toBe(true)
		expect(recorder:Take()):toEqual({ "players.stateChanged Alyx alive>dead", "players.died Alyx by Barney" })
		expect(barney:Frags()):toBe(1)
		expect(alyx.deathInfo:GetInflictor()):toBe(weapon)
		expect(alyx.deathInfo:GetDamageType()):toBe(World.DMG.BULLET)
		expect(alyx.deathInfo:GetDamageForce()):toEqual(Vector(0, 0, 100))
		expect(players:IsKilling(alyx)):toBe(false)
		expect(players:Kill(alyx, { attacker = barney })):toBe(false)

		-- An attacker that left becomes the world; god mode falls back to a suicide.
		players:Deploy(alyx)
		alyx:GodEnable()
		expect(players:Kill(alyx, { attacker = World.NULL })):toBe(true)
		expect(alyx.deathInfo:GetAttacker()):toBe(alyx)
		expect(barney:Frags()):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("refuses to deploy players that are still loading", function()
		local server, players = boot()
		local alyx = Env.Bot(server, { name = "Alyx" })
		expect(players:Deploy(alyx)):toBe(false)
		expect(players:MakeSpectator(alyx)):toBe(false)
		expect(players:Deploy(Env.FakePlayer())):toBe(false)
	end)

	it("forgets players that leave", function()
		local server, players, recorder = boot()
		local alyx, barney = bot(server, "Alyx"), bot(server, "Barney")
		players:Deploy(alyx)
		recorder:Take()
		Env.Leave(server, alyx)
		expect(recorder:Take()):toEqual({ "players.left Alyx alive" })
		expect(players:State(alyx)):toBeNil()
		expect(players:Count("alive")):toBe(0)
		expect(players:ReadyPlayers()):toEqual({ barney })
		expect(server:Get("NC").Components:Store("players.life"):Has(alyx)):toBe(false)
	end)

	it("spreads spawns over free points, away from enemies", function()
		local server, players = boot({ spawns = {
			{ class = "info_player_start", pos = Vector(0, 0, 0) },
			{ class = "info_player_start", pos = Vector(1000, 0, 0) },
			{ class = "info_player_start", pos = Vector(2000, 0, 0) },
		} })
		local a, b, c = bot(server, "A"), bot(server, "B"), bot(server, "C")
		players:Deploy(a)
		players:Deploy(b)
		players:Deploy(c)
		local xs = { a:GetPos().x, b:GetPos().x, c:GetPos().x }
		table.sort(xs)
		expect(xs):toEqual({ 0, 1000, 2000 })

		-- A respawn goes to the free point farthest from hostile players.
		a:SetPos(Vector(100, 0, 0))
		b:SetPos(Vector(900, 0, 0))
		c:SetPos(Vector(5000, 0, 0))
		local d = bot(server, "D")
		players:Deploy(d)
		expect(d:GetPos()):toEqual(Vector(2000, 0, 0))

		-- Teammates are not hostile: the point next to a teammate is the farthest from the enemy.
		for _, ply in ipairs({ a, b, d }) do
			ply:SetTeam(1)
		end
		c:SetTeam(2)
		a:SetPos(Vector(1900, 0, 0))
		c:SetPos(Vector(-100, 0, 0))
		d:SetPos(Vector(-5000, 0, 0))
		players:Deploy(b)
		expect(b:GetPos()):toEqual(Vector(2000, 0, 0))
	end)

	it("finds a free spot next to taken points", function()
		local server, players = boot({ spawns = { { class = "info_player_start", pos = Vector(0, 0, 0) } } })
		server.traceLine = function(trace)
			return { Hit = true, StartSolid = false, HitPos = Vector(trace.endpos.x, trace.endpos.y, 0) }
		end
		local a, b = bot(server, "A"), bot(server, "B")
		players:Deploy(a)
		players:Deploy(b)
		expect(a:GetPos()):toEqual(Vector(0, 0, 0))
		local pos = b:GetPos()
		expect(pos.z):toBe(0)
		expect(pos:Distance(Vector(0, 0, 0))):toBeCloseTo(48, 0.01)

		-- A wall all around: no spot, the point is shared rather than nobody spawning.
		server.traceHull = function()
			return { Hit = true, StartSolid = false }
		end
		local c = bot(server, "C")
		expect(players:Deploy(c)):toBe(true)
		expect(c:GetPos()):toEqual(Vector(0, 0, 0))
	end)

	it("uses spawn sides and the answers of other modules", function()
		local server, players, recorder = boot({ spawns = {
			{ class = "info_player_start", pos = Vector(0, 0, 0) },
			{ class = "info_player_rebel", pos = Vector(100, 0, 0) },
			{ class = "info_player_combine", pos = Vector(200, 0, 0) },
		} })
		expect(#players:SpawnPoints("any")):toBe(3)
		expect(#players:SpawnPoints("a")):toBe(1)
		expect(#players:SpawnPoints("b")):toBe(1)
		expect(#players:SpawnPoints("nope")):toBe(3)

		local a = bot(server, "A")
		recorder.spawn = "b"
		players:Deploy(a)
		expect(a:GetPos()):toEqual(Vector(200, 0, 0))
		recorder.spawn = { pos = Vector(7, 8, 9), ang = World.Angle(0, 90, 0) }
		players:Deploy(a)
		expect(a:GetPos()):toEqual(Vector(7, 8, 9))
		expect(a:EyeAngles()):toEqual(World.Angle(0, 90, 0))
		recorder.spawn = players:SpawnPoints("a")[1]
		players:Deploy(a)
		expect(a:GetPos()):toEqual(Vector(100, 0, 0))
		-- An explicit spawn of Deploy wins over the answers.
		players:Deploy(a, { spawn = "b" })
		expect(a:GetPos()):toEqual(Vector(200, 0, 0))
	end)

	it("finds the spawn points again after a map cleanup", function()
		local server, players = boot({ spawns = { { class = "info_player_start", pos = Vector(5, 0, 0), map = true } } })
		local old = players:SpawnPoints("any")[1]
		server:Get("game").CleanUpMap()
		local fresh = players:SpawnPoints("any")[1]
		expect(fresh):notToBe(old)
		expect(fresh:IsValid()):toBe(true)
		local a = bot(server, "A")
		players:Deploy(a)
		expect(a.spawnPoint):toBe(fresh)
	end)

	it("replicates life states to clients", function()
		local server, players = boot()
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local alyx = bot(server, "Alyx")
		players:Deploy(alyx)
		server:Advance(0.2)
		Env.Flush(server, client)
		local clientPlayers = client:Get("NC").Modules:Instance("players")
		expect(clientPlayers:State(gordon)):toBe("spectator")
		expect(clientPlayers:State(alyx)):toBe("alive")
		expect(clientPlayers:List("alive")):toEqual({ alyx })
		expect(clientPlayers:Count("spectator")):toBe(1)

		players:SetRespawnAt(gordon, 50)
		server:Advance(0.2)
		Env.Flush(server, client)
		expect(clientPlayers:RespawnAt(gordon)):toBe(50)
		expect(client:Errors()):toEqual({})
	end)

	it("keeps states across autorefresh", function()
		local server, players = boot()
		local alyx, barney = bot(server, "Alyx"), bot(server, "Barney")
		players:Deploy(alyx)
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		local fresh = server:Get("NC").Modules:Instance("players")
		expect(fresh):notToBe(players)
		expect(fresh:State(alyx)):toBe("alive")
		expect(fresh:State(barney)):toBe("spectator")
		expect(fresh:List("alive")):toEqual({ alyx })
		Env.Kill(alyx)
		expect(fresh:State(alyx)):toBe("dead")
		expect(server:Errors()):toEqual({})
	end)

	it("lists players with nc_players", function()
		local server, players = boot()
		local alyx = bot(server, "Alyx")
		players:Deploy(alyx)
		server:Command("nc_players")
		expect(#server:Lines("Players: connecting 0, spectator 0, alive 1, dead 0")):toBe(1)
		expect(server:Lines("Alyx")[1]):toContain("alive")
	end)

	it("finds players by the argument of a console command", function()
		local server, players = boot()
		local alyx, al, barney = bot(server, "Alyx"), bot(server, "Al"), bot(server, "Barney")
		local function find(text, caller)
			return { players:Find(text, caller) }
		end
		expect(find(nil, barney)):toEqual({ barney })
		expect(find("^", barney)):toEqual({ barney })
		expect(find("")):toEqual({ nil, "no player given" })
		expect(find("#" .. alyx:EntIndex())):toEqual({ alyx })
		expect(find(tostring(al:EntIndex()))):toEqual({ al })
		expect(find("#99")):toEqual({ nil, "no player #99" })
		expect(find("Al")):toEqual({ al })
		expect(find("bar")):toEqual({ barney })
		expect(find("al")):toEqual({ nil, "2 players match 'al'" })
		expect(find("Kleiner")):toEqual({ nil, "no player matches 'Kleiner'" })
	end)
end)
