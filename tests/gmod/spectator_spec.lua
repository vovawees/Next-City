-- Spectator module: the death camera, following teammates and anyone, the camera keys,
-- retargeting on deaths, spawns, departures and vetoes, and the client HUD, with the real
-- gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local OBS = World.OBS_MODE
local IN = World.IN

local SPAWNS = {
	{ class = "info_player_rebel", pos = Vector(0, 0, 0), map = true },
	{ class = "info_player_rebel", pos = Vector(0, 500, 0), map = true },
	{ class = "info_player_combine", pos = Vector(3000, 0, 0), map = true },
	{ class = "info_player_combine", pos = Vector(3000, 500, 0), map = true },
}

-- A server with players, rounds, teams and the spectator. Mode "test" (2 players) gets
-- opts.mode over { rules = { "teams" } }; opts.settings are the spectator settings.
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = { "players", "rounds", "teams", "spectator" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.rounds = { mode = "test", shuffle = false }
			cfg.modules.settings.spectator = opts.settings
			return cfg
		end } })
	for _, point in ipairs(SPAWNS) do
		Env.Spawn(server, point)
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local def = { id = "test", name = "Test", minPlayers = 2, rules = { "teams" } }
	for key, value in pairs(opts.mode or {}) do
		def[key] = value
	end
	NC.Modules:Instance("rounds"):RegisterMode(def)
	return server, NC.Modules:Instance("spectator"), NC
end

-- Bots with entity indexes from..from + count - 1, so the order of targets is known.
local function bots(server, from, count)
	local list = {}
	for i = 1, count do
		local index = from + i - 1
		list[i] = Env.Bot(server, { name = string.char(64 + index), index = index })
	end
	server:Advance(0.1)
	return unpack(list)
end

-- Presses a key a little later than the last press (keys have a short cooldown).
local function press(server, ply, key)
	server:Advance(0.2)
	Env.Press(server, ply, key)
end

describe("spectator", function()
	it("shows the death, then follows living teammates and anyone after them", function()
		local server, spectator = boot()
		local a, b, c, d = bots(server, 1, 4) -- teams 1, 2, 1, 2
		server:Advance(5)
		Env.Kill(a, b)
		server:Advance(0.1)
		expect(spectator:IsObserving(a)):toBe(false)
		expect(a:GetObserverMode()):toBe(OBS.NONE)

		server:Advance(3)
		expect(spectator:IsObserving(a)):toBe(true)
		expect(spectator:Camera(a)):toBe("in_eye")
		expect(a:GetObserverMode()):toBe(OBS.IN_EYE)
		expect(a:GetObserverTarget()):toBe(c)
		expect(spectator:Viewers(c)):toEqual({ a })
		expect(spectator:CanObserve(a, b)):toBe(false)
		press(server, a, IN.ATTACK)
		expect(spectator:Target(a)):toBe(c)

		-- The last teammate dies: now anyone living, from the next index on.
		Env.Kill(c, d)
		server:Advance(0.1)
		expect(spectator:Target(a)):toBe(d)
		expect(spectator:CanObserve(a, b)):toBe(true)
		press(server, a, IN.ATTACK2)
		expect(spectator:Target(a)):toBe(b)
		Env.Press(server, a, IN.ATTACK) -- too soon after the last key
		expect(spectator:Target(a)):toBe(b)
		expect(server:Errors()):toEqual({})
	end)

	it("switches cameras with jump and keeps the choice over a respawn", function()
		local server, spectator, NC = boot()
		local a, b = bots(server, 1, 2)
		server:Advance(5)
		Env.Kill(a, b)
		server:Advance(3.1)
		expect(spectator:Target(a)):toBe(b)

		press(server, a, IN.JUMP)
		expect(spectator:Camera(a)):toBe("chase")
		expect(a:GetObserverMode()):toBe(OBS.CHASE)
		expect(a:GetObserverTarget()):toBe(b)
		press(server, a, IN.JUMP)
		expect(spectator:Camera(a)):toBe("roaming")
		expect(a:GetObserverMode()):toBe(OBS.ROAMING)
		expect(a:GetObserverTarget()):toBe(World.NULL)
		expect(spectator:Target(a)):toBeNil()
		expect(a:GetPos()):toEqual(b:EyePos()) -- the free camera starts at the eyes of b
		press(server, a, IN.ATTACK)            -- back to the last follow camera and target
		expect(spectator:Camera(a)):toBe("chase")
		expect(spectator:Target(a)):toBe(b)
		press(server, a, IN.JUMP)
		press(server, a, IN.JUMP)
		expect(spectator:Camera(a)):toBe("in_eye")
		expect(spectator:Target(a)):toBe(b)
		press(server, a, IN.JUMP)

		local rounds = NC.Modules:Instance("rounds")
		rounds:Restart()
		expect(spectator:IsObserving(a)):toBe(false)
		expect(a:GetObserverMode()):toBe(OBS.NONE)
		server:Advance(5)
		Env.Kill(a, b)
		server:Advance(3.1)
		expect(spectator:Camera(a)):toBe("chase")
		expect(a:GetObserverMode()):toBe(OBS.CHASE)
		expect(server:Errors()):toEqual({})
	end)

	it("lets spectators follow anyone and waits for someone to follow", function()
		local server, spectator, NC = boot({ mode = { rules = { "respawn" }, LateJoin = function() return false end } })
		local players = NC.Modules:Instance("players")
		local a, b = bots(server, 1, 2)
		server:Advance(5)
		local e = bots(server, 5, 1)
		expect(players:State(e)):toBe("spectator")
		expect(spectator:Target(e)):toBe(a)

		Env.Kill(a, b)
		server:Advance(0.1)
		expect(spectator:Target(e)):toBe(b)
		Env.Kill(b)
		server:Advance(0.1)
		expect(spectator:Target(e)):toBeNil()
		expect(spectator:Camera(e)):toBe("in_eye")
		expect(e:GetObserverMode()):toBe(OBS.ROAMING)
		press(server, e, IN.ATTACK) -- nobody to follow
		expect(e:GetObserverMode()):toBe(OBS.ROAMING)

		-- Both come back: the last followed player is picked up again on the next tick.
		server:Advance(5)
		server:Advance(0.1)
		expect(players:IsAlive(b)):toBe(true)
		expect(spectator:Target(e)):toBe(b)
		expect(e:GetObserverMode()):toBe(OBS.IN_EYE)

		Env.Leave(server, b)
		server:Advance(0.1)
		expect(spectator:Target(e)):toBe(a)
		expect(server:Errors()):toEqual({})
	end)

	it("asks spectator.canObserve and corrects cameras changed behind its back", function()
		local server, spectator, NC = boot({ mode = { rules = {} } })
		local a, b, c = bots(server, 1, 3)
		server:Advance(5)
		Env.Kill(a, b)
		server:Advance(3.1)
		expect(spectator:Target(a)):toBe(b)

		NC.Events:On("spectator.canObserve", function(_, target)
			if target == b then
				return false
			end
		end)
		server:Advance(0.5)
		expect(spectator:Target(a)):toBe(c)
		expect(spectator:Follow(a, b)):toBe(false)

		a:SpectateEntity(b) -- like spec_next in the engine
		a:Spectate(OBS.CHASE)
		server:Advance(0.5)
		expect(a:GetObserverTarget()):toBe(c)
		expect(a:GetObserverMode()):toBe(OBS.IN_EYE)

		local seen = {}
		NC.Events:On("spectator.target", function(viewer, target, old)
			seen[#seen + 1] = { viewer, target, old }
		end)
		Env.Kill(c, c)
		server:Advance(0.1)
		expect(seen):toEqual({ { a, nil, c } })
		expect(a:GetObserverMode()):toBe(OBS.ROAMING)
		expect(server:Errors()):toEqual({})
	end)

	it("follows the settings and warns about wrong ones", function()
		local server, spectator = boot({ settings = { deathCam = 0, camera = "chase" } })
		local a, b = bots(server, 1, 2)
		server:Advance(5)
		Env.Kill(a, b)
		expect(spectator:Camera(a)):toBe("chase")
		expect(a:GetObserverMode()):toBe(OBS.CHASE)

		local other, view = boot({ settings = { deathCam = -1, camera = "sideways" } })
		expect(#other:Lines("setting 'deathCam' = -1 is outside 0..60; using 3")):toBe(1)
		expect(#other:Lines("setting 'camera' = sideways is not in_eye, chase or roaming; using in_eye")):toBe(1)
		expect(view.deathCam):toBe(3)
	end)

	it("shows the target, the respawn countdown and the keys to the client", function()
		local server = boot({ mode = { rules = { "teams", "respawn" } } })
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru", index = 1 })
		local barney, carl = bots(server, 2, 2) -- teams: Gordon 1, Barney 2, Carl 1
		carl.name = "Carl"
		server:Advance(5)
		Env.Kill(gordon, barney)
		server:Advance(0.1)

		local function hud()
			client.time = server.time
			Env.Flush(server, client)
			client.drawn = {}
			client:Call("HUDPaint")
			return client.drawn
		end
		local drawn = hud()
		expect(drawn):toContain("Возрождение через 5 с")
		expect(drawn):notToContain("Наблюдение")

		server:Advance(3)
		drawn = hud()
		expect(drawn):toContain("Наблюдение")
		expect(drawn):toContain("Carl")
		expect(drawn):toContain("Возрождение через 2 с")
		expect(drawn):toContain("ЛКМ / ПКМ — следующий / предыдущий игрок · Прыжок — камера")

		client:SetConVar("nc_language", "en")
		drawn = hud()
		expect(drawn):toContain("Following")
		expect(drawn):toContain("Respawn in 2 s")

		server:Advance(2)
		drawn = hud()
		expect(drawn):notToContain("Following")
		expect(client:Errors()):toEqual({})
	end)
end)
