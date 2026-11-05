-- Homicide (the official package): hidden roles and aliases, the kits of the variants,
-- quiet deaths and the mute dead, the penalty for killing an innocent, the wins of both
-- sides with the reveal, the gun-free loot, with the real gamemode and package files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local function boot(params)
	local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "homicide", shuffle = false, params = { homicide = params or {} } }
		return cfg
	end } })
	for i = 0, 4 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = {}
	for _, id in ipairs({ "rounds", "roles", "players", "inventory", "loot", "mode_homicide" }) do
		m[id] = NC.Modules:Instance(id)
	end
	-- No shuffles: the first ready players are the murderer and the sheriff, aliases in order.
	m.roles.Random = function(n) return n end
	m.mode_homicide.Random = function(n) return n end
	return server, m
end

-- Alyx, Barney and Eli (bots), then Gordon (a client); the round prepares on the next tick.
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
	return client:Get("NC").Modules:Instance("roles")
end

local function hud(client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("homicide", function()
	it("deals hidden roles, aliases and the kits of the standard variant", function()
		local server, m = boot()
		local client, alyx, barney, eli, gordon = join(server, "ru")
		expect(m.rounds:Phase()):toBe("preparing")
		local round = m.rounds:Round()
		expect(round.mode):toBe("homicide")
		expect(round.data.variant):toBe("standard")
		expect({ m.roles:Of(alyx), m.roles:Of(barney), m.roles:Of(eli), m.roles:Of(gordon) }):toEqual({
			"murderer", "sheriff", "innocent", "innocent" })
		expect({ m.players:Name(alyx), m.players:Name(barney), m.players:Name(gordon), m.players:Name(eli) }):toEqual({
			"Alpha", "Bravo", "Charlie", "Delta" })
		-- Everybody wears the look of his alias (appearance), so a face gives no name away.
		local appearance = server:Get("NC").Modules:Instance("appearance")
		for _, ply in ipairs({ alyx, barney, eli, gordon }) do
			local look = m.mode_homicide:AliasLook(ply)
			expect({ ply:GetModel(), appearance.FromVector(ply:GetPlayerColor()) }):toEqual({ look.model, look.color })
		end
		expect(m.mode_homicide:AliasLook(alyx).color):notToBe(m.mode_homicide:AliasLook(barney).color)

		-- Kits: a knife for the murderer, a revolver for the sheriff; empty hands for all.
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands", "nc_knife" })
		expect(barney:WeaponClasses()):toEqual({ "nc_hands", "nc_python" })
		expect(m.inventory:Count(barney, "ammo_357")):toBe(12)
		expect(gordon:WeaponClasses()):toEqual({ "nc_hands" })
		expect({ alyx.selected, barney.selected }):toEqual({ "nc_hands", "nc_hands" })
		expect(#server:Lines("WARN")):toBe(0)

		-- The client knows only his own role and sees aliases.
		local roles = sync(server, client)
		expect(roles:Mine()):toBe("innocent")
		expect(roles:Of(alyx)):toBeNil()
		local players = client:Get("NC").Modules:Instance("players")
		expect(players:Name(alyx)):toBe("Alpha")
		local drawn = hud(client)
		expect(drawn):toContain("Мирный")
		expect(drawn):toContain("Выживите и помогите найти убийцу")
		expect(client.chatLines):toContain("Стандарт: у убийцы нож, у шерифа револьвер")
		Env.Say(server, alyx, "hello")
		expect(client.chatLines[#client.chatLines]):toBe("Alpha: hello")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("stops the murderer quietly and reveals who was who", function()
		local server, m = boot()
		local client, alyx, barney, eli, gordon = join(server, "en")
		server:Advance(5)
		expect(m.rounds:Phase()):toBe("active")
		local notices = #(server.deathNotices or {})
		Env.Kill(eli, alyx)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("active")
		-- The dead do not talk to the living.
		local _, seen = Env.Say(server, eli, "Alyx did it")
		expect(seen):toEqual({ eli })

		Env.Kill(alyx, barney)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_homicide.reason.stopped",
			key = "mode_homicide.win.innocents" })
		expect(#(server.deathNotices or {})):toBe(notices)
		sync(server, client)
		local drawn = hud(client)
		expect(drawn):toContain("The innocents win")
		expect(drawn):toContain("The murderer is stopped")
		expect(client.chatLines):toContain("The murderer was Alpha (Alyx)")
		expect(client.chatLines):toContain("The sheriff was Bravo (Barney)")
		expect(client:Get("NC").Modules:Instance("roles"):Of(alyx)):toBe("murderer")

		-- After the round names and roles are back to normal.
		expect(m.rounds:SetNextMode("tdm")):toBe(true)
		server:Advance(8)
		expect(m.rounds:Phase()):toBe("preparing")
		expect(m.rounds:Round().mode):toBe("tdm")
		expect(m.players:Name(gordon)):toBe("Gordon")
		expect(m.roles:Of(alyx)):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("punishes killing an innocent and lets the murderer win", function()
		local server, m = boot()
		local client, alyx, barney, eli, gordon = join(server, "en")
		server:Advance(5)
		Env.Kill(eli, barney)
		server:Advance(0.1)
		expect(m.inventory:Count(barney, "python")):toBe(0)
		expect(barney:WeaponClasses()):toEqual({ "nc_hands" })
		expect(m.inventory:Count(barney, "ammo_357")):toBe(12)
		sync(server, client)

		Env.Kill(barney, alyx)
		Env.Kill(gordon, alyx)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("ended")
		local result = m.rounds:Round().result
		expect(result.key):toBe("mode_homicide.win.murderer")
		expect(result.reason):toBe("mode_homicide.reason.innocents")
		expect(result.winner):toBe(alyx)
		sync(server, client)
		expect(hud(client)):toContain("The murderer Alpha wins")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("kills the killer of an innocent with the penalty kill", function()
		local server, m = boot({ penalty = "kill" })
		local _, alyx, barney, eli = join(server, "en")
		server:Advance(5)
		Env.Kill(eli, barney)
		server:Advance(0.1)
		expect(m.players:IsAlive(barney)):toBe(false)
		expect(m.players:IsAlive(alyx)):toBe(true)
		expect(m.rounds:Phase()):toBe("active")
		expect(server:Errors()):toEqual({})
	end)

	it("keeps firearms out of the gun-free zone and arms everybody in the wild west", function()
		local server, m = boot({ variant = "gunfree" })
		local _, alyx, barney, _, gordon = join(server, "en")
		expect(barney:WeaponClasses()):toEqual({ "nc_hands", "nc_stunstick" })
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands", "nc_knife" })
		local homicide = m.mode_homicide
		local function firearms()
			local count = 0
			for _ = 1, 200 do
				for _, got in ipairs(m.loot:Roll("weapons_civil")) do
					if homicide:IsFirearm(m.inventory:Def(got.id)) then
						count = count + 1
					end
				end
			end
			return count
		end
		expect(firearms()):toBe(0)

		-- random picks a variant for each round: the third one is the wild west.
		m.rounds:SetParam("homicide", "variant", "random")
		homicide.Random = function(n) return n end
		expect(m.rounds:Restart()):toBe(true)
		expect(m.rounds:Round().data.variant):toBe("wildwest")
		expect(firearms() > 0):toBe(true)
		expect(gordon:WeaponClasses()):toEqual({ "nc_hands", "nc_python" })
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands", "nc_knife", "nc_python" })
		expect(server:Errors()):toEqual({})
	end)
end)
