-- Defense (the official package): pauses with a countdown, waves sized by the living players
-- and the growth, creatures of the groups of hostiles far from the players, beaten waves
-- bringing the dead back with a resupply, players joining in the pauses, the rest of a big
-- wave coming as the first die, the headcrabs of zombies taken over, defenders not hurting
-- each other, the win after the last wave and the loss, with the real gamemode and package.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

-- opts: params of the mode, npcs (settings of the npcs module).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "defense", shuffle = false, params = { defense = opts.params or {} } }
		cfg.modules.settings.npcs = opts.npcs
		return cfg
	end } })
	-- The defenders at the origin, the creatures come from far away.
	for i = 0, 3 do
		Env.Spawn(server, { class = "info_player_rebel", pos = Vector(i * 60, 0, 0), map = true })
		Env.Spawn(server, { class = "info_player_combine", pos = Vector(4000, i * 300, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC }
	for _, id in ipairs({ "rounds", "players", "inventory", "npcs", "mode_defense" }) do
		m[id] = NC.Modules:Instance(id)
	end
	m.npcs.Random = function(n)
		return n ~= nil and 1 or 0 -- the first kind of a group, the first weapon
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

local function killAll(m, attacker)
	for _, npc in ipairs(m.npcs:List("defense")) do
		Env.KillNPC(npc, attacker)
	end
end

describe("defense", function()
	it("holds waves with pauses: countdown, size by the living and the growth, the dead back, won", function()
		local server, m = boot({ params = { waves = 2, pause = 5, perPlayer = 2, growth = 0.5 } })
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		run(server, 5.2)
		expect(m.rounds:Phase()):toBe("active")
		expect(m.rounds:Round().mode):toBe("defense")
		-- Both defenders on side a, with the kit and its rifle in the hands.
		expect(gordon:GetPos().x < 1000):toBe(true)
		expect(m.inventory:Count(gordon, "ar2")):toBe(1)
		expect(m.inventory:Count(gordon, "ammo_556")):toBe(120)
		expect(gordon:GetActiveWeapon():GetClass()):toBe("nc_ar2")
		expect(hud(server, client)):toContain("Wave 1 of 2 in 0:05")

		-- The first wave: 2 per living player, from the far side, hunting.
		run(server, 5.3)
		expect(m.npcs:Count("defense")):toBe(4)
		for _, npc in ipairs(m.npcs:List("defense")) do
			expect(npc:GetClass()):toBe("npc_zombie")
			expect(npc:GetPos().x > 3000):toBe(true)
			expect(npc.schedule):toBe(World.SCHED_FORCED_GO_RUN or 72)
		end
		expect(hud(server, client)):toContain("Wave 1 of 2: 4 enemies left")

		-- A dead defender waits for the end of the wave; kills count down and give frags.
		Env.Kill(alyx)
		run(server, 3)
		expect(m.players:IsAlive(alyx)):toBe(false)
		local list = m.npcs:List("defense")
		Env.KillNPC(list[1], gordon)
		Env.KillNPC(list[2], gordon)
		Env.KillNPC(list[3], gordon)
		expect(hud(server, client)):toContain("Wave 1 of 2: 1 enemy left")
		expect(m.rounds:Round().result):toBeNil()
		Env.KillNPC(list[4], gordon)
		server:Advance(0.1)
		expect(gordon:Frags()):toBe(4)

		-- Beaten: the dead are back, the living get more ammunition, the next pause.
		expect(m.players:IsAlive(alyx)):toBe(true)
		expect(m.inventory:Count(gordon, "ammo_556")):toBe(180)
		expect(hud(server, client)):toContain("Wave 2 of 2 in 0:05")
		expect(client.chatLines):toContain("Wave 1 of 2 is beaten: the fallen are back")

		-- The second wave is bigger by half of the first: 2 * 2 * 1.5.
		run(server, 5.3)
		expect(m.npcs:Count("defense")):toBe(6)
		killAll(m, gordon)
		server:Advance(0.1)
		local result = m.rounds:Round().result
		expect(result.key):toBe("mode_defense.result.won")
		expect(result.reason):toBe("mode_defense.reason.held")
		local shown = hud(server, client)
		expect(shown):toContain("The defense held")
		expect(shown):toContain("All 2 waves beaten")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("brings the rest of a big wave as the first die, lets players join in the pauses, is lost", function()
		local server, m = boot({ params = { waves = 3, pause = 5, perPlayer = 5, growth = 0.5 },
			npcs = { maxAlive = 3 } })
		local alyx = Env.Bot(server, { name = "Alyx" })
		run(server, 5.2)
		expect(m.rounds:Phase()):toBe("active")
		run(server, 5.3)
		-- Five creatures, three at once.
		expect(m.npcs:Count("defense")):toBe(3)
		expect(m.mode_defense:Left(m.rounds:Round())):toBe(5)
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		server:Advance(0.1)
		expect(m.rounds:Round():IsParticipant(gordon)):toBe(false) -- not during a wave
		Env.KillNPC(m.npcs:List("defense")[1], alyx)
		expect(m.mode_defense:Left(m.rounds:Round())):toBe(4)
		run(server, 1.1)
		expect(m.npcs:Count("defense")):toBe(3)
		expect(hud(server, client)):toContain("Волна 1 из 3: осталось 4 врага")
		killAll(m, alyx)
		run(server, 1.1)
		killAll(m, alyx)
		server:Advance(0.1)
		-- The pause: Gordon comes in.
		expect(m.rounds:Round():IsParticipant(gordon)):toBe(true)
		expect(m.players:IsAlive(gordon)):toBe(true)
		expect(hud(server, client)):toContain("Волна 2 из 3 через 0:05")
		run(server, 5.3)
		expect(m.mode_defense:Left(m.rounds:Round())):toBe(15) -- 5 * 2 * 1.5

		-- Everybody falls: lost on wave 2; the creatures go with the round.
		Env.Kill(alyx)
		Env.Kill(gordon)
		server:Advance(0.1)
		local result = m.rounds:Round().result
		expect(result.key):toBe("mode_defense.result.lost")
		expect(result.reason):toBe("mode_defense.reason.fallen")
		local shown = hud(server, client)
		expect(shown):toContain("Оборона пала")
		expect(shown):toContain("Все пали на волне 2 из 3")
		run(server, 9)
		expect(m.rounds:Phase()):toBe("preparing")
		expect(m.npcs:Count("defense")):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("takes over the headcrabs of zombies, falls back from unknown groups, no friendly fire", function()
		local server, m = boot({ params = { waves = 1, pause = 3, perPlayer = 1, groups = { "ghosts" } } })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		run(server, 5.2)
		-- Defenders do not hurt each other.
		local health = alyx:Health()
		Env.Hurt(alyx, { damage = 30, attacker = barney })
		expect(alyx:Health()):toBe(health)
		run(server, 3.3)
		expect(server:Lines("WARN")):toContain("[NC] WARN  [mode_defense] unknown group 'ghosts': zombies instead")
		expect(m.npcs:Count("defense")):toBe(2)
		-- A killed zombie leaves a headcrab: it is part of the wave.
		local zombie = m.npcs:List("defense")[1]
		local at = zombie:GetPos()
		Env.KillNPC(zombie, alyx)
		Env.Spawn(server, { class = "npc_headcrab", pos = at })
		run(server, 0.6)
		expect(m.npcs:Count("defense")):toBe(2)
		local classes = {}
		for _, npc in ipairs(m.npcs:List("defense")) do
			classes[#classes + 1] = npc:GetClass()
		end
		table.sort(classes)
		expect(classes):toEqual({ "npc_headcrab", "npc_zombie" })
		killAll(m, barney)
		server:Advance(0.1)
		expect(m.rounds:Round().result.key):toBe("mode_defense.result.won")
		expect(m.rounds:Round().result.params):toEqual({ count = 1 })
		expect(server:Errors()):toEqual({})
	end)

	it("ends the round when the creatures have nowhere to appear", function()
		local server, m = boot({ params = { pause = 3 } })
		Env.Bot(server, { name = "Alyx" })
		run(server, 5.2)
		m.npcs.Spots = function()
			return {}
		end
		run(server, 3.3)
		expect(m.rounds:Round().result):toEqual({ reason = "mode_defense.reason.nowhere" })
		expect(server:Errors()):toEqual({})
	end)
end)
