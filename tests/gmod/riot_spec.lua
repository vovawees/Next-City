-- Riot (the official package): the deal of the police, the kits of both sides, guns kept
-- out of the loot, tying up and freeing by sides, the wins of both teams, the time-out and
-- the draw, with the real gamemode and package files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN

-- A shot-mask line of a player in `aims` hits the entity he aims at.
local function aim(realm, aims)
	local shot = realm:Get("MASK_SHOT")
	realm.traceLine = function(trace)
		local ent = aims[trace.filter]
		if ent ~= nil and trace.mask == shot then
			return { Hit = true, Entity = ent, HitPos = ent:GetPos(), Fraction = 0.5, StartSolid = false }
		end
		return { Hit = false, Entity = World.NULL, Fraction = 1, StartSolid = false, HitPos = Vector(trace.endpos) }
	end
end

local function boot(params)
	local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "riot", shuffle = false, params = { riot = params or {} } }
		return cfg
	end } })
	for i = 0, 5 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC, aims = {} }
	for _, id in ipairs({ "rounds", "teams", "players", "inventory", "actions", "restraints", "mode_riot" }) do
		m[id] = NC.Modules:Instance(id)
	end
	aim(server, m.aims)
	-- No shuffle: the first ready players are the police.
	m.mode_riot.Random = function(n) return n end
	return server, m
end

-- The round prepares as soon as two players are ready: the bots Alyx, Barney and Eli are
-- dealt, Gordon (the client) joins it while it prepares.
local function join(server, language)
	local alyx = Env.Bot(server, { name = "Alyx" })
	local barney = Env.Bot(server, { name = "Barney" })
	local eli = Env.Bot(server, { name = "Eli" })
	local client, gordon = Env.Join(server, { name = "Gordon", language = language })
	server:Advance(0.1)
	return client, alyx, barney, eli, gordon
end

-- Everybody close to each other, looking along x.
local function gather(list)
	for i, ply in ipairs(list) do
		ply:SetPos(Vector((i - 1) * 40, 0, 0))
		ply:SetEyeAngles(Angle(0, 0, 0))
	end
end

local function run(server, seconds)
	for _ = 1, math.floor(seconds / 0.1 + 0.5) do
		server:Advance(0.1)
	end
end

local function hud(server, client)
	server:Advance(0.3)
	client.time = server.time
	Env.Flush(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("riot", function()
	it("deals a third to the police, arms both sides, briefs them and keeps guns out of the loot", function()
		local server, m = boot()
		local client, alyx, barney, eli, gordon = join(server, "en")
		expect(m.rounds:Phase()):toBe("preparing")
		expect(m.rounds:Round().mode):toBe("riot")
		-- A third of the players: the deal of the bots, the late ones by the count.
		expect({ alyx:Team(), barney:Team(), eli:Team(), gordon:Team() }):toEqual({ 2, 1, 1, 1 })
		local kleiner = Env.Bot(server, { name = "Kleiner" })
		server:Advance(0.1)
		local mossman = Env.Bot(server, { name = "Mossman" })
		server:Advance(0.1)
		expect({ kleiner:Team(), mossman:Team() }):toEqual({ 2, 1 })
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands", "nc_stunstick" })
		expect(alyx.selected):toBe("nc_stunstick")
		expect(m.inventory:Count(alyx, "zipties")):toBe(6)
		expect({ m.inventory:Count(alyx, "helmet"), m.inventory:Count(alyx, "vest") }):toEqual({ 1, 1 })
		expect(gordon:WeaponClasses()):toEqual({ "nc_hands", "nc_crowbar", "nc_bottle" })
		expect(gordon.selected):toBe("nc_crowbar")
		expect(m.inventory:Count(gordon, "bottle")):toBe(2)
		expect(#server:Lines("WARN")):toBe(0)

		-- No guns and no ammunition in the loot of the round.
		local events, inventory = m.NC.Events, m.inventory
		expect(events:Query("loot.allow", "usp", inventory:Def("usp"))):toBe(false)
		expect(events:Query("loot.allow", "ammo_9x19", inventory:Def("ammo_9x19"))):toBe(false)
		expect(events:Query("loot.allow", "crowbar", inventory:Def("crowbar"))):toBeNil()

		server:Advance(5)
		expect(m.rounds:Phase()):toBe("active")
		local drawn = hud(server, client)
		expect(drawn):toContain("You riot: beat the police, free your tied comrades with the use key")
		expect(drawn):toContain("Rioters 4")
		expect(drawn):toContain("Police 2")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("deals the police by the parameter", function()
		local server, m = boot()
		local mode = m.mode_riot
		local ready = {}
		for i = 1, 8 do
			ready[i] = Env.Bot(server, { name = "Bot" .. i })
		end
		local function deal(police, count)
			local round = { params = { police = police }, data = {} }
			local list = { unpack(ready, 1, count) }
			mode:Deal(round, list)
			local teams = {}
			for i, ply in ipairs(list) do
				teams[i] = round.data.deal[ply]
			end
			return teams
		end
		expect(deal(0, 8)):toEqual({ 2, 2, 2, 1, 1, 1, 1, 1 })
		expect(deal(0, 5)):toEqual({ 2, 2, 1, 1, 1 })
		expect(deal(0, 2)):toEqual({ 2, 1 })
		expect(deal(5, 4)):toEqual({ 2, 2, 2, 1 })
		expect(server:Errors()):toEqual({})
	end)

	it("lets the police tie up rioters and only rioters free them; nobody standing ends the riot", function()
		local server, m = boot({ police = 2 })
		local client, alyx, barney, eli, gordon = join(server, "ru")
		expect({ alyx:Team(), barney:Team(), eli:Team(), gordon:Team() }):toEqual({ 2, 2, 1, 1 })
		server:Advance(5)
		expect(m.rounds:Phase()):toBe("active")
		gather({ alyx, barney, eli, gordon })
		local restraints, actions, aims = m.restraints, m.actions, m.aims

		-- Not a fellow officer.
		aims[alyx] = barney
		Env.Press(server, alyx, IN.USE)
		expect(actions:Current(alyx)):toBeNil()

		-- A rioter: the time of the zip ties, a frag, a line for everybody, one standing less.
		aims[alyx] = eli
		Env.Press(server, alyx, IN.USE)
		expect(actions:Current(alyx).id):toBe("restraints.tie")
		run(server, 3.1)
		expect(restraints:IsTied(eli)):toBe(true)
		expect(alyx:Frags()):toBe(1)
		expect(m.inventory:Count(alyx, "zipties")):toBe(5)
		expect(m.teams:Score(1)):toBe(1)
		local drawn = hud(server, client)
		expect(drawn):toContain("Alyx связал(а) Eli")
		expect(drawn):toContain("Бунтовщики 1")
		expect(client.chatLines):toContain("Alyx связал(а) Eli")

		-- The police do not untie him, a rioter does.
		aims[barney] = eli
		Env.Press(server, barney, IN.USE)
		expect(actions:Current(barney)):toBeNil()
		aims[gordon] = eli
		Env.Press(server, gordon, IN.USE)
		expect(actions:Current(gordon).id):toBe("restraints.untie")
		run(server, 4.1)
		expect(restraints:IsTied(eli)):toBe(false)
		expect(m.teams:Score(1)):toBe(2)
		expect(hud(server, client)):toContain("Gordon освободил(а) Eli")

		-- Both rioters tied up: the riot is suppressed.
		Env.Press(server, alyx, IN.USE)
		aims[barney] = gordon
		Env.Press(server, barney, IN.USE)
		run(server, 3.1)
		expect({ restraints:IsTied(eli), restraints:IsTied(gordon) }):toEqual({ true, true })
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_riot.reason.suppressed", team = 2 })
		drawn = hud(server, client)
		expect(drawn):toContain("Победа: Полиция")
		expect(drawn):toContain("Бунт подавлен")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("arms the police with firearms and gives the win to the rioters when no officer stands", function()
		local server, m = boot({ firearms = true })
		local client, alyx, barney = join(server, "en")
		expect(alyx:WeaponClasses()):toEqual({ "nc_hands", "nc_stunstick", "nc_usp" })
		expect(alyx.selected):toBe("nc_stunstick")
		expect(m.inventory:Count(alyx, "ammo_9x19")):toBe(30)
		local inventory = m.inventory
		expect(m.NC.Events:Query("loot.allow", "usp", inventory:Def("usp"))):toBeNil()

		server:Advance(5)
		-- A tied officer is out as well.
		expect(m.restraints:Tie(alyx, barney)):toBe(true)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_riot.reason.overrun", team = 1 })
		local drawn = hud(server, client)
		expect(drawn):toContain("Rioters win")
		expect(drawn):toContain("The police are overrun")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("gives the win to the side with more standing when the time is up", function()
		local server, m = boot({ roundTime = 60 })
		local client = join(server, "en")
		server:Advance(5)
		run(server, 60)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_riot.reason.time", team = 1 })
		local drawn = hud(server, client)
		expect(drawn):toContain("Rioters win")
		expect(drawn):toContain("Time is up: more of them stand")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("ends in a draw when as many stand on each side at the end", function()
		local server, m = boot({ roundTime = 60 })
		local client, alyx, barney, eli = join(server, "en")
		server:Advance(5)
		expect(m.restraints:Tie(barney, alyx)):toBe(true)
		expect(m.restraints:Tie(eli, alyx)):toBe(true)
		server:Advance(0.1)
		expect(m.rounds:Phase()):toBe("active")
		run(server, 60)
		expect(m.rounds:Phase()):toBe("ended")
		expect(m.rounds:Round().result):toEqual({ reason = "mode_riot.reason.even" })
		local drawn = hud(server, client)
		expect(drawn):toContain("Draw")
		expect(drawn):toContain("Time is up: as many stand on each side")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
