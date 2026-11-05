-- Deathmatch: frags and deaths from zero, every kill a frag and a suicide a lost one,
-- respawns after the delay, the status line with the leader, a tie and the limit, the win at
-- the frag limit, the leader or a draw when the time is up, the kit of the package and the
-- loadout of engine weapons without the inventory, with the real gamemode files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

-- opts: params of the mode, modules (a list instead of every module of the repository).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = opts.modules, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "dm", shuffle = false, params = { dm = opts.params or {} } }
		return cfg
	end } })
	for i = 0, 3 do
		Env.Spawn(server, { class = "info_player_deathmatch", pos = Vector(i * 600, 0, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC }
	for _, id in ipairs({ "rounds", "players", "inventory", "mode_dm" }) do
		m[id] = NC.Modules:Instance(id)
	end
	return server, m
end

local function run(server, seconds)
	for _ = 1, math.floor(seconds / 0.1 + 0.5) do
		server:Advance(0.1)
	end
end

local function hud(server, client)
	server:Advance(0.05)
	client.time = server.time
	Env.Flush(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("dm", function()
	it("every player for himself: frags from zero, respawns, the leader and the limit, the win", function()
		local server, m = boot({ params = { fragLimit = 3, respawnDelay = 1 } })
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		gordon:SetFrags(7) -- from the warmup
		run(server, 5.3)
		expect(m.rounds:Phase()):toBe("active")
		expect({ gordon:Frags(), gordon:Deaths() }):toEqual({ 0, 0 })
		-- The kit of the package, its MP7 in the hands.
		expect(m.inventory:Count(gordon, "mp7")):toBe(1)
		expect(gordon:GetActiveWeapon():GetClass()):toBe("nc_mp7")
		expect(hud(server, client)):toContain("Frags to win: 3")

		Env.Kill(alyx, gordon)
		expect(hud(server, client)):toContain("Leader: Gordon, 1 of 3")
		run(server, 1.1)
		expect(m.players:IsAlive(alyx)):toBe(true)
		Env.Kill(gordon, barney)
		expect(hud(server, client)):toContain("Tied for the lead: 1 of 3")
		Env.Kill(barney) -- a suicide costs a frag
		expect(barney:Frags()):toBe(0)
		expect(hud(server, client)):toContain("Leader: Gordon, 1 of 3")
		run(server, 1.1)
		Env.Kill(alyx, gordon)
		run(server, 1.1)
		expect(m.rounds:Round().result):toBeNil()
		Env.Kill(alyx, gordon)
		server:Advance(0.1)
		local result = m.rounds:Round().result
		expect(result.reason):toBe("score")
		expect(result.winner):toBe(gordon)
		local shown = hud(server, client)
		expect(shown):toContain("Gordon wins")
		expect(shown):toContain("Score limit reached")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("time is up: the one leader wins, a tie or no frags is a draw; no limit", function()
		local server, m = boot({ params = { roundTime = 60, fragLimit = 0 } })
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		run(server, 5.3)
		expect(hud(server, client)):notToContain("Фрагов до победы: 0")
		Env.Kill(alyx, gordon)
		expect(hud(server, client)):toContain("Лидер: Gordon, 1")
		run(server, 60)
		expect(m.rounds:Round().result):toEqual({ reason = "time", winner = gordon })

		-- The next round: a tie.
		run(server, 9 + 5.3)
		expect(m.rounds:Phase()):toBe("active")
		run(server, 4)
		Env.Kill(alyx, gordon)
		run(server, 4)
		Env.Kill(gordon, alyx)
		expect(hud(server, client)):toContain("Делят лидерство: 1")
		run(server, 53)
		expect(m.rounds:Round().result):toEqual({ reason = "time" })
		expect(server:Errors()):toEqual({})
	end)

	it("without the inventory gives the engine weapons of the loadout with spare magazines", function()
		local server = boot({ modules = { "players", "rounds", "mode_dm" },
			params = { loadout = { "weapon_crowbar", "weapon_smg1" }, spareMags = 2 } })
		local alyx = Env.Bot(server, { name = "Alyx" })
		Env.Bot(server, { name = "Barney" })
		run(server, 5.3)
		expect(alyx:HasWeapon("weapon_crowbar")):toBe(true)
		expect(alyx:HasWeapon("weapon_smg1")):toBe(true)
		expect(alyx:GetActiveWeapon():GetClass()):toBe("weapon_smg1")
		expect(alyx:GetAmmoCount(alyx:GetWeapon("weapon_smg1"):GetPrimaryAmmoType())):toBe(90)
		expect(server:Errors()):toEqual({})
	end)
end)
