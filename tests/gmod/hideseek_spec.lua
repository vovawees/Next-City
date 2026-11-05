-- Hide and Seek (the official package): the deal of the seekers, the hide phase with the
-- frozen blindfolded seekers and the countdown, late hiders, the hunt by kills and by tags,
-- the wins of both teams, with the real gamemode and package files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local function boot(params)
	local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "hideseek", shuffle = false, params = { hideseek = params or {} } }
		return cfg
	end } })
	for i = 0, 5 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = {}
	for _, id in ipairs({ "rounds", "teams", "players", "inventory", "mode_hideseek" }) do
		m[id] = NC.Modules:Instance(id)
	end
	-- No shuffle: the first ready players seek.
	m.mode_hideseek.Random = function(n) return n end
	return server, m
end

-- The round prepares as soon as Alyx and Barney are ready (the deal), Eli and Gordon (the
-- client) join it while it prepares.
local function join(server, language)
	local alyx = Env.Bot(server, { name = "Alyx" })
	local barney = Env.Bot(server, { name = "Barney" })
	local eli = Env.Bot(server, { name = "Eli" })
	local client, gordon = Env.Join(server, { name = "Gordon", language = language })
	server:Advance(0.1)
	return client, alyx, barney, eli, gordon
end

local function sync(server, client)
	server:Advance(0.3)
	client.time = server.time
	Env.Flush(server, client)
end

local function hud(client)
	client.drawn, client.rects = {}, {}
	client:Call("HUDPaint")
	return client.drawn
end

-- Whether the last frame had a black rectangle over the whole screen.
local function blindfolded(client)
	for _, rect in ipairs(client.rects) do
		if rect[1] == 0 and rect[2] == 0 and rect[3] == 1920 and rect[4] == 1080 and rect[8] == 255
			and rect[5] + rect[6] + rect[7] == 0 then
			return true
		end
	end
	return false
end

describe("hideseek", function()
	it("freezes the seekers while the hiders hide, then lets them kill everybody", function()
		local server, m = boot({ hideTime = 30 })
		local client, alyx, barney, eli, gordon = join(server, "en")
		expect(m.rounds:Phase()):toBe("preparing")
		expect(m.rounds:Round().mode):toBe("hideseek")
		-- A quarter of four players seeks.
		expect({ alyx:Team(), barney:Team(), gordon:Team(), eli:Team() }):toEqual({ 2, 1, 1, 1 })
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands", "nc_usp", "nc_crowbar" })
		expect(alyx.selected):toBe("nc_usp")
		expect(m.inventory:Count(alyx, "ammo_9x19")):toBe(45)
		expect(barney:WeaponClasses()):toEqual({ "nc_hands" })
		expect(#server:Lines("WARN")):toBe(0)

		server:Advance(5)
		expect(m.rounds:Phase()):toBe("active")
		expect({ alyx:IsFrozen(), barney:IsFrozen(), gordon:IsFrozen() }):toEqual({ true, false, false })
		local GM = server:Get("GM")
		expect(GM:PlayerShouldTakeDamage(alyx, barney)):toBe(false)
		expect(GM:PlayerShouldTakeDamage(barney, alyx)):toBe(false)
		expect(GM:PlayerShouldTakeDamage(barney, eli)):toBe(false) -- teammates
		sync(server, client)
		local drawn = hud(client)
		expect(drawn):toContain("Hide! The seekers come out in 0:30")
		expect(drawn):toContain("You hide: the seekers come out in 30 s")
		-- The scores of the teams: how many of them are alive.
		expect(drawn):toContain("Hiders 3")
		expect(drawn):toContain("Seekers 1")
		expect(blindfolded(client)):toBe(false)

		server:Advance(30)
		expect(alyx:IsFrozen()):toBe(false)
		expect(GM:PlayerShouldTakeDamage(barney, alyx)):toBe(true)
		sync(server, client)
		drawn = hud(client)
		expect(drawn):toContain("The seekers are out!")
		expect(drawn):notToContain("Hide! The seekers come out in 0:00")

		Env.Kill(barney, alyx)
		Env.Kill(gordon, alyx)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("active")
		expect(m.teams:Score(1)):toBe(1)
		Env.Kill(eli, alyx)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_hideseek.reason.found", team = 2 })
		sync(server, client)
		drawn = hud(client)
		expect(drawn):toContain("Seekers win")
		expect(drawn):toContain("Every hider is found")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("deals the seekers by the parameter", function()
		local server, m = boot()
		local mode = m.mode_hideseek
		local ready = {}
		for i = 1, 8 do
			ready[i] = Env.Bot(server, { name = "Bot" .. i })
		end
		local function deal(seekers, count)
			local round = { params = { seekers = seekers }, data = {} }
			local list = { unpack(ready, 1, count) }
			mode:Deal(round, list)
			local teams = {}
			for i, ply in ipairs(list) do
				teams[i] = round.data.deal[ply]
			end
			return teams
		end
		expect(deal(0, 8)):toEqual({ 2, 2, 1, 1, 1, 1, 1, 1 })
		expect(deal(0, 3)):toEqual({ 2, 1, 1 })
		expect(deal(3, 4)):toEqual({ 2, 2, 2, 1 })
		expect(deal(5, 2)):toEqual({ 2, 1 })
		expect(server:Errors()):toEqual({})
	end)

	it("blindfolds a seeker until the hunt and takes late players as hiders while they hide", function()
		local server, m = boot({ hideTime = 20 })
		-- The client is ready first: he seeks.
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		server:Advance(0.1)
		expect({ gordon:Team(), alyx:Team(), barney:Team() }):toEqual({ 2, 1, 1 })
		server:Advance(5)
		sync(server, client)
		expect(gordon:IsFrozen()):toBe(true)
		local drawn = hud(client)
		expect(blindfolded(client)):toBe(true)
		expect(drawn):toContain("Глаза завязаны. Охота через 0:20")
		expect(drawn):toContain("Вы ищете: 20 с с завязанными глазами, потом найдите всех")

		-- Late players: a hider while they hide, a spectator in the hunt.
		local kleiner = Env.Bot(server, { name = "Kleiner" })
		server:Advance(0.1)
		local round = m.rounds:Round()
		expect(round:IsParticipant(kleiner)):toBe(true)
		expect(kleiner:Team()):toBe(1)
		expect(kleiner:IsFrozen()):toBe(false)

		server:Advance(20)
		local mossman = Env.Bot(server, { name = "Mossman" })
		server:Advance(0.1)
		expect(round:IsParticipant(mossman)):toBe(false)
		sync(server, client)
		expect(gordon:IsFrozen()):toBe(false)
		hud(client)
		expect(blindfolded(client)):toBe(false)

		-- The hiders win when no seeker is left.
		Env.Kill(gordon, kleiner)
		server:Advance(0.1)
		expect(m.rounds:Round().result):toEqual({ reason = "mode_hideseek.reason.seekers", team = 1 })
		sync(server, client)
		drawn = hud(client)
		expect(drawn):toContain("Победа: Прячущиеся")
		expect(drawn):toContain("Ищущих не осталось")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("turns tagged hiders into seekers", function()
		local server, m = boot({ hideTime = 10, catch = "tag" })
		local client, alyx, barney, eli, gordon = join(server, "en")
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands" })
		server:Advance(5)
		-- No tags while they hide.
		Env.Hurt(barney, { damage = 5, attacker = alyx })
		expect(barney:Team()):toBe(1)
		server:Advance(10)

		Env.Hurt(barney, { damage = 1000, attacker = alyx })
		expect(barney:Alive()):toBe(true)
		expect(barney:Team()):toBe(2)
		expect(alyx:Frags()):toBe(1)
		sync(server, client)
		expect(hud(client)):toContain("Alyx caught Barney")
		expect(client.chatLines):toContain("Alyx caught Barney")

		-- A new seeker tags as well; the last tag ends the round.
		Env.Hurt(gordon, { damage = 1000, attacker = barney })
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("active")
		Env.Hurt(eli, { damage = 1000, attacker = alyx })
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_hideseek.reason.found", team = 2 })
		expect({ gordon:Alive(), eli:Alive() }):toEqual({ true, true })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("gives the win to the hiders when the time is up", function()
		local server, m = boot({ roundTime = 60, hideTime = 10 })
		local client = join(server, "en")
		server:Advance(5)
		server:Advance(10)
		server:Advance(50)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_hideseek.reason.time", team = 1 })
		sync(server, client)
		local drawn = hud(client)
		expect(drawn):toContain("Hiders win")
		expect(drawn):toContain("The hiders held out")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
