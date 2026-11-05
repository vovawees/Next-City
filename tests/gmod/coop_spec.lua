-- CO-OP (the official package): the hostile creatures of the map and spawned ones to clear,
-- friends of the map left out, creatures waiting at their places, the shared lives bringing
-- the fallen back, players out of lives kept out, the win when none is left, the loss when
-- everybody falls or the time is up, and nothing to clear, with the real gamemode and package.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

-- opts: params of the mode, npcs (map creatures to spawn: { class, pos }).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "coop", shuffle = false, params = { coop = opts.params or {} } }
		return cfg
	end } })
	for i = 0, 3 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 60, 0, 0), map = true })
		Env.Spawn(server, { class = "info_player_combine", pos = Vector(4000, i * 300, 0), map = true })
	end
	for _, npc in ipairs(opts.npcs or {}) do
		Env.Spawn(server, { class = npc.class, pos = npc.pos, map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC }
	for _, id in ipairs({ "rounds", "players", "inventory", "npcs", "mode_coop" }) do
		m[id] = NC.Modules:Instance(id)
	end
	m.npcs.Random = function(n)
		return n ~= nil and 1 or 0
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

local function classes(m)
	local list = {}
	for _, npc in ipairs(m.npcs:List("coop")) do
		list[#list + 1] = npc:GetClass()
	end
	table.sort(list)
	return list
end

describe("coop", function()
	it("clears the map together: creatures of the map and spawned ones, shared lives, won", function()
		local server, m = boot({ params = { perPlayer = 1, group = "metrocops", respawnDelay = 5 }, npcs = {
			{ class = "npc_combine_s", pos = Vector(2000, 0, 0) },
			{ class = "npc_citizen", pos = Vector(300, 0, 0) },
		} })
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		run(server, 5.3)
		expect(m.rounds:Phase()):toBe("active")
		-- The soldier of the map and a metrocop per player; the citizen is a friend.
		expect(classes(m)):toEqual({ "npc_combine_s", "npc_metropolice", "npc_metropolice" })
		for _, npc in ipairs(m.npcs:List("coop")) do
			expect(npc.schedule):toBeNil() -- they wait at their places
		end
		expect(m.inventory:Count(gordon, "mp7")):toBe(1)
		expect(gordon:GetActiveWeapon():GetClass()):toBe("nc_mp7")
		local shown = hud(server, client)
		expect(shown):toContain("Enemies: 3 · Lives: 4")

		-- A life of the team brings the fallen back.
		Env.Kill(alyx, m.npcs:List("coop")[1])
		expect(hud(server, client)):toContain("Enemies: 3 · Lives: 3")
		expect(client.chatLines):toContain("Alyx fell, lives left: 3")
		run(server, 5.1)
		expect(m.players:IsAlive(alyx)):toBe(true)

		local list = m.npcs:List("coop")
		Env.KillNPC(list[1], gordon)
		Env.KillNPC(list[2], alyx)
		expect(hud(server, client)):toContain("Enemies: 1 · Lives: 3")
		Env.KillNPC(list[3], gordon)
		server:Advance(0.1)
		local result = m.rounds:Round().result
		expect(result.key):toBe("mode_coop.result.won")
		expect(result.reason):toBe("mode_coop.reason.cleared")
		expect(hud(server, client)):toContain("The map is clear")
		expect({ gordon:Frags(), alyx:Frags() }):toEqual({ 2, 1 })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("is lost when the lives run out; who is out stays out; time is up; nothing to clear", function()
		local server, m = boot({ params = { lives = 1, perPlayer = 2, group = "zombies", respawnDelay = 2 } })
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		run(server, 5.3)
		expect(m.npcs:Count("coop")):toBe(2)
		Env.Kill(gordon)
		run(server, 2.1)
		expect(m.players:IsAlive(gordon)):toBe(true)
		Env.Kill(gordon)
		server:Advance(0.1)
		Env.Flush(server, client)
		expect(client.chatLines):toContain("Gordon пал(а), жизней больше нет")
		local result = m.rounds:Round().result
		expect(result.key):toBe("mode_coop.result.lost")
		expect(result.reason):toBe("mode_coop.reason.fallen")
		local shown = hud(server, client)
		expect(shown):toContain("Задание провалено")
		expect(shown):toContain("Пали все, осталось 2 врага")
		-- Out of lives, he would not come back into the round by reconnecting.
		expect(m.rounds:Round().data.out[gordon:SteamID()]):toBe(true)

		-- The next round: the time is up.
		m.rounds:SetParam("coop", "roundTime", 60)
		run(server, 9 + 5.3)
		expect(m.rounds:Phase()):toBe("active")
		run(server, 60)
		result = m.rounds:Round().result
		expect(result.reason):toBe("mode_coop.reason.time")
		expect(result.params):toEqual({ count = 2 })
		expect(server:Errors()):toEqual({})
	end)

	it("ends at once with nothing to clear and warns about an unknown group", function()
		local server, m = boot({ params = { map = true, group = "ghosts" } })
		Env.Bot(server, { name = "Alyx" })
		run(server, 5.3)
		expect(m.rounds:Round().result):toEqual({ reason = "mode_coop.reason.empty" })
		expect(server:Lines("WARN")):toContain("[NC] WARN  [mode_coop] unknown group 'ghosts': no creatures spawned")
		expect(server:Errors()):toEqual({})
	end)
end)
