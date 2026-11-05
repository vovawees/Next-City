-- Law (the core module with the city of the official package): the wanted and warrants of
-- the police and the mayor, arrests with handcuffs, the jail with a timer across deaths
-- and reconnects, searches of the tied up and the rams of the police with a warrant.

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

local function boot()
	local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "city", shuffle = false }
		return cfg
	end } })
	for i = 0, 5 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	Env.Spawn(server, { class = "prop_door_rotating", pos = Vector(40, 0, 60), map = true, mapId = 1001 })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC, aims = {} }
	aim(server, m.aims)
	for _, id in ipairs({ "rounds", "players", "inventory", "economy", "restraints", "doors", "law", "mode_city" }) do
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
	server:Advance(0.3)
	client.time = server.time
	Env.Flush(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

local function notice(server, client)
	Env.Flush(server, client)
	local list = client:Get("NC").Modules:Instance("notices"):Active()
	return list[#list] and list[#list].text
end

local function at(ply, x, y)
	ply:SetPos(Vector(x, y, 0))
	ply:SetEyeAngles(Angle(0, 0, 0))
end

local function spot(ply)
	local pos = ply:GetPos()
	return { pos.x, pos.y }
end

describe("law", function()
	it("wants players for a reason, issues warrants and calls them off; they run out", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		local kleiner = Env.Bot(server, { name = "Kleiner" })
		run(server, 5.3)
		local law, city = m.law, m.mode_city

		-- Only the police want players, for a reason everybody learns.
		expect({ law:Want(gordon, kleiner, "Theft") }):toEqual({ false, "officer" })
		city:SetJob(barney, "police", true)
		expect({ law:IsOfficer(barney), law:IsOfficer(gordon), law:IsEnabled() }):toEqual({ true, false, true })
		expect({ law:Want(barney, kleiner, "  ") }):toEqual({ false, "reason" })
		expect({ law:Want(barney, kleiner, string.rep("x", 97)) }):toEqual({ false, "long" })
		expect({ law:Want(barney, kleiner, "<b>Theft") }):toEqual({ false, "chars" })
		expect({ law:Want(barney, barney, "Theft") }):toEqual({ false, "target" })
		expect(law:Want(barney, kleiner, " Theft  of a car ")):toBe(true)
		expect({ law:IsWanted(kleiner), law:Wanted(kleiner).reason }):toEqual({ true, "Theft of a car" })
		expect({ law:Want(barney, kleiner, "Again") }):toEqual({ false, "wanted" })
		hud(server, client)
		expect(client.chatLines):toContain("Kleiner is wanted: Theft of a car")
		local cl = client:Get("NC").Modules:Instance("law")
		expect({ cl:IsWanted(kleiner), cl:IsOfficer(barney) }):toEqual({ true, true })
		expect(client:Get("NC").Events:Reduce("players.targetLines", {}, kleiner)):toContain("Wanted")

		-- Warrants: the police issue them while there is no mayor, then only the mayor does.
		expect(law:IssueWarrant(barney, kleiner, "Stolen goods")):toBe(true)
		expect({ law:IssueWarrant(barney, kleiner, "Again") }):toEqual({ false, "warrant" })
		city:SetJob(alyx, "mayor", true)
		expect({ law:Authority(), law:IsAuthority(alyx) }):toEqual({ alyx, true })
		expect({ law:IssueWarrant(barney, gordon, "Noise") }):toEqual({ false, "authority" })
		expect({ law:IssueWarrant(gordon, alyx, "Noise") }):toEqual({ false, "officer" })
		expect(law:IssueWarrant(alyx, gordon, "Noise")):toBe(true)
		hud(server, client)
		expect(client.chatLines):toContain("A warrant for Gordon: Noise")
		expect(law:HasWarrant(gordon)):toBe(true)

		-- The menu over the net; a wrong order tells why.
		city:SetJob(gordon, "police", true)
		cl:Ask("unwant", kleiner)
		hud(server, client)
		expect(law:IsWanted(kleiner)):toBe(false)
		expect(client.chatLines):toContain("Kleiner is no longer wanted")
		cl:Ask("want", kleiner, "Murder")
		hud(server, client)
		expect(law:Wanted(kleiner).reason):toBe("Murder")
		cl:Ask("want", kleiner, "Murder")
		expect(notice(server, client)):toBe("He is wanted already")

		-- The console: the orders and the list.
		gordon.printed = {}
		server:Command("nc_unwant", gordon, { "Kleiner" })
		server:Command("nc_want", gordon, { "Kleiner", "Arson", "at", "night" })
		server:Command("nc_want", gordon, { "Nobody", "Arson" })
		expect(gordon.printed):toEqual({ "nc_unwant: Kleiner is no longer wanted", "nc_want: Kleiner is wanted",
			"nc_want: no player matches 'Nobody'" })
		gordon.printed = {}
		server:Command("nc_wanted", gordon, {})
		table.sort(gordon.printed)
		expect(gordon.printed):toEqual({ "wanted   Kleiner          5:00  Arson at night",
			"warrant  Gordon           5:00  Noise", "warrant  Kleiner          5:00  Stolen goods" })

		-- Everything runs out.
		run(server, 301.2)
		expect({ law:IsWanted(kleiner), law:HasWarrant(gordon), law:HasWarrant(kleiner) })
			:toEqual({ false, false, false })
		hud(server, client)
		expect(client.chatLines[#client.chatLines]):toBe("Kleiner is no longer wanted")

		-- The end of the city is an amnesty; without a mode that keeps it there is no law.
		law:Want(gordon, kleiner, "Theft")
		m.rounds:Round():End({ reason = "test" })
		run(server, 8.2)
		expect(law:IsWanted(kleiner)):toBe(false)
		local shut = m.NC.Events:On("law.enabled", function() return false end, { priority = 100 })
		expect({ law:IsEnabled(), law:Want(nil, kleiner, "Theft") }):toEqual({ false, false, "closed" })
		shut:Off()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("arrests the wanted with handcuffs: the jail with a timer across deaths and reconnects", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en", superadmin = true })
		local barney = Env.Bot(server, { name = "Barney" })
		local kleiner = Env.Bot(server, { name = "Kleiner" })
		run(server, 5.3)
		local law, city, inventory, restraints = m.law, m.mode_city, m.inventory, m.restraints

		-- The admin sets the jail of the map.
		gordon.printed = {}
		gordon:SetPos(Vector(2000, 2000, 0))
		gordon:SetEyeAngles(Angle(0, 90, 0))
		server:Command("nc_jails", gordon, { "add" })
		gordon:SetPos(Vector(2200, 2000, 0))
		server:Command("nc_jails", gordon, { "add" })
		server:Command("nc_jails", gordon, {})
		expect(gordon.printed):toEqual({ "nc_jails: point 1 at 2000 2000 0", "nc_jails: point 2 at 2200 2000 0",
			"nc_jails: 2 points on gm_test", "1: 2000 2000 0, yaw 90", "2: 2200 2000 0, yaw 90" })

		-- The police officer cuffs the wanted one: he goes to jail at once.
		city:SetJob(barney, "police", true)
		expect(inventory:Count(barney, "handcuffs")):toBe(1)
		expect(law:Want(barney, kleiner, "Robbery")):toBe(true)
		local jailed = {}
		m.NC.Events:On("law.jailed", function(ply, by, seconds)
			jailed[#jailed + 1] = { ply, by, seconds }
		end)
		at(kleiner, 0, 0)
		at(barney, 40, 0)
		m.aims[barney] = kleiner
		Env.Press(server, barney, IN.USE)
		run(server, 2.2)
		expect({ law:IsJailed(kleiner), law:IsWanted(kleiner), restraints:IsTied(kleiner) })
			:toEqual({ true, false, false })
		expect({ spot(kleiner), jailed[1] }):toEqual({ { 2000, 2000 }, { kleiner, barney, 120 } })
		expect(law:JailLeft(kleiner)):toBeCloseTo(119.8, 0.15)
		hud(server, client)
		expect(client.chatLines):toContain("Kleiner goes to jail for 2:00")
		expect(client:Get("NC").Events:Reduce("players.targetLines", {}, kleiner)):toContain("In jail")

		-- In jail: empty hands, no attacks or use, no inventory, no job, no shop, no salary.
		kleiner:Give("weapon_crowbar")
		kleiner:SelectWeapon("weapon_crowbar")
		expect(kleiner.selected):toBe("nc_hands")
		local cmd = Env.RunCommand(server, kleiner, IN.ATTACK + IN.ATTACK2 + IN.USE + IN.RELOAD + IN.FORWARD)
		expect(cmd:GetButtons()):toBe(IN.FORWARD)
		inventory:Give(kleiner, "pouch", 1)
		local pouch
		for _, item in ipairs(inventory:ItemsOf(kleiner)) do
			if item.id == "pouch" then
				pouch = item
			end
		end
		expect({ inventory:Act(kleiner, pouch.container.id, pouch.slot, "drop", 0) }):toEqual({ false, "denied" })
		expect({ city:SetJob(kleiner, "medic") }):toEqual({ false, "jailed" })
		expect({ city:Buy(kleiner, "bandage") }):toEqual({ false, "jailed" })
		local balance = m.economy:Balance(kleiner)
		city:Payday(m.rounds:Round())
		expect(m.economy:Balance(kleiner)):toBe(balance)
		expect({ law:Want(barney, kleiner, "Again") }):toEqual({ false, "jailed" })
		expect({ law:Arrest(barney, kleiner) }):toEqual({ false, "jailed" })

		-- A death brings him back into the jail (the next point of it).
		Env.Kill(kleiner)
		server:Advance(0.1)
		run(server, 10.2)
		expect({ m.players:IsAlive(kleiner), law:IsJailed(kleiner), spot(kleiner) })
			:toEqual({ true, true, { 2200, 2000 } })

		-- Leaving keeps the rest of the time for his return.
		local left = law:JailLeft(kleiner)
		Env.Leave(server, kleiner)
		server:Advance(1)
		local again = Env.Bot(server, { name = "Kleiner" })
		run(server, 11)
		expect({ m.players:IsAlive(again), law:IsJailed(again) }):toEqual({ true, true })
		expect(law:JailLeft(again) <= math.ceil(left) and law:JailLeft(again) > left - 12):toBe(true)
		expect(spot(again)[2]):toBe(2000)

		-- The time is up: out at a spawn point.
		run(server, 100)
		expect({ law:IsJailed(again), spot(again)[2] }):toEqual({ false, 0 })
		hud(server, client)
		expect(client.chatLines[#client.chatLines]):toBe("Kleiner is out of jail")

		-- The admin jails at once; the police or the mayor let him go.
		gordon.printed = {}
		server:Command("nc_jail", gordon, { "Kleiner", "60" })
		expect(gordon.printed[1]):toBe("nc_jail: Kleiner is in jail for 1:00")
		expect({ law:Release(gordon, again) }):toEqual({ false, "officer" })
		expect(law:Release(barney, again)):toBe(true)
		expect({ law:Release(barney, again) }):toEqual({ false, "free" })
		expect(law:IsJailed(again)):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("keeps the arrested tied without a jail; the tied are searched; a warrant lets the ram in", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		local kleiner = Env.Bot(server, { name = "Kleiner" })
		run(server, 5.3)
		local law, city, inventory, restraints, doors = m.law, m.mode_city, m.inventory, m.restraints, m.doors
		city:SetJob(barney, "police", true)

		-- No jail on the map: the arrested one stays tied up where he is, barely moving.
		local walk = gordon:GetWalkSpeed()
		law:Want(barney, gordon, "Fraud")
		expect(hud(server, client)):toContain("You are wanted: Fraud")
		at(gordon, 0, 0)
		at(alyx, 40, 0)
		restraints:Tie(gordon, barney)
		expect({ law:IsJailed(gordon), restraints:IsTied(gordon), spot(gordon) }):toEqual({ true, true, { 0, 0 } })
		expect(gordon:GetWalkSpeed() < walk * 0.1):toBe(true)
		local drawn = hud(server, client)
		expect(drawn):toContain("In jail: 2:00")
		expect(drawn):toContain("Your hands are tied")
		expect({ restraints:BeginUntie(alyx, gordon) }):toEqual({ false, "denied" })

		-- Anybody within reach searches a tied up player; he learns who.
		expect({ law:Search(alyx, barney) }):toEqual({ false, "loose" })
		expect(law:Search(alyx, gordon)):toBe(true)
		expect(inventory:Watching(alyx, inventory:Pockets(gordon))):toBe("open")
		expect(notice(server, client)):toBe("Alyx searches you")
		at(alyx, 1000, 0)
		expect({ law:Search(alyx, gordon) }):toEqual({ false, "far" })

		-- Out of jail he is untied and walks again.
		expect(law:Release(barney, gordon)):toBe(true)
		expect({ restraints:IsTied(gordon), gordon:GetWalkSpeed() }):toEqual({ false, walk })

		-- One a citizen tied up is arrested by the police with the command.
		law:Want(barney, kleiner, "Theft")
		at(kleiner, 0, 0)
		at(barney, 40, 0)
		restraints:Tie(kleiner, alyx)
		expect(law:IsJailed(kleiner)):toBe(false)
		m.aims[barney] = kleiner
		barney.printed = {}
		server:Command("nc_arrest", barney, {})
		expect({ barney.printed[1], law:IsJailed(kleiner) }):toEqual({ "nc_arrest: Kleiner is in jail", true })

		-- The ram of the police breaks only into the doors of the wanted and those with a warrant.
		local door = doors:All()[1]
		expect(doors:Buy(alyx, door)):toBe(true)
		doors:Lock(alyx, door, true)
		m.aims[barney] = door
		expect({ doors:BeginRam(barney, door) }):toEqual({ false, "denied" })
		expect(law:IssueWarrant(barney, alyx, "Stolen goods")):toBe(true)
		expect(doors:BeginRam(barney, door)):toBe(true)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
