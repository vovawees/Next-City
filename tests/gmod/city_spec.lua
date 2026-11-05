-- City (the official package): an endless round, the jobs with their limits, cooldown and
-- gear (it stays with its owner and goes with the job), respawns, salaries into the bank
-- accounts, the names of citizens kept in storage and the shop of the jobs, with the real
-- gamemode and package files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

-- opts: params of the city, data (DATA of an earlier server).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ data = opts.data, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "city", shuffle = false, params = { city = opts.params or {} } }
		return cfg
	end } })
	for i = 0, 5 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC }
	for _, id in ipairs({ "rounds", "roles", "players", "inventory", "economy", "mode_city" }) do
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

-- The item `id` a player carries.
local function find(inventory, ply, id)
	for _, item in ipairs(inventory:ItemsOf(ply)) do
		if item.id == id then
			return item
		end
	end
	return nil
end

describe("city", function()
	it("runs endlessly: citizens join, change jobs within limits and cooldown, the gear goes with the job", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		server:Advance(0.1)
		expect(m.rounds:Round().mode):toBe("city")
		run(server, 5.3)
		expect(m.rounds:Phase()):toBe("active")
		local city, inventory, roles = m.mode_city, m.inventory, m.roles
		expect({ roles:Of(gordon), roles:Of(alyx) }):toEqual({ "citizen", "citizen" })
		expect(inventory:Count(gordon, "bandage")):toBe(1)
		expect(gordon:GetModel()):toBe(city:ModelFor(gordon, city:Job("citizen")))
		expect(gordon:GetModel()):toContain("models/player/group01/")

		-- A newcomer joins the running city.
		local barney = Env.Bot(server, { name = "Barney" })
		run(server, 0.3)
		expect(m.players:IsAlive(barney)):toBe(true)
		expect(roles:Of(barney)):toBe("citizen")

		-- Gordon becomes a police officer: the gear of the job, the model, everybody learns it.
		expect(city:SetJob(gordon, "police")):toBe(true)
		expect(roles:Of(gordon)):toBe("police")
		expect({ inventory:Count(gordon, "stunstick"), inventory:Count(gordon, "handcuffs"),
			inventory:Count(gordon, "usp"), inventory:Count(gordon, "ammo_9x19"), inventory:Count(gordon, "bandage") })
			:toEqual({ 1, 1, 1, 30, 1 })
		expect(gordon.selected):toBe("nc_stunstick")
		expect(gordon:GetModel()):toContain("models/player/police")
		expect(city:IsPolice(gordon)):toBe(true)
		local drawn = hud(server, client)
		expect(client.chatLines):toContain("Gordon is now: Police officer")
		expect(drawn):toContain("Police officer")

		-- The gear of the job stays with him: no dropping it, no handing it over.
		local usp = find(inventory, gordon, "usp")
		expect(usp.state.issued):toBe(true)
		expect({ inventory:Act(gordon, usp.container.id, usp.slot, "drop") }):toEqual({ false, "denied" })
		gordon:SetPos(Vector(0, 0, 0))
		local _, place = inventory:SpawnPlace(Vector(20, 0, 40), nil, { size = 4 })
		expect(inventory:Open(gordon, place)):toBe(true)
		local bandage = find(inventory, gordon, "bandage")
		expect({ inventory:Move(gordon, bandage.container.id, bandage.slot, place.id, 0, 0) })
			:toEqual({ false, "denied" })
		inventory:Give(gordon, "gauze", 1)
		local gauze = find(inventory, gordon, "gauze")
		expect(inventory:Move(gordon, gauze.container.id, gauze.slot, place.id, 0, 0)):toBe(true)

		-- The cooldown, the limit of places, unknown jobs.
		expect({ city:SetJob(gordon, "medic") }):toEqual({ false, "cooldown", 30 })
		expect({ city:SetJob(gordon, "police") }):toEqual({ false, "same" })
		expect({ city:SetJob(alyx, "janitor") }):toEqual({ false, "unknown" })
		expect(city:SetJob(alyx, "mayor")):toBe(true)
		expect({ city:SetJob(barney, "mayor") }):toEqual({ false, "limit" })
		client.chatLines = {}
		gordon.printed = {}
		server:Command("nc_job", gordon, { "gundealer" })
		expect(gordon.printed[1]):toBe("nc_job gundealer: cooldown (30 s)")
		expect(hud(server, client)):toContain("You can change your job in 30 seconds")
		gordon.printed = {}
		server:Command("nc_job", gordon, {})
		expect(gordon.printed[2]):toBe("police     1/4  salary 85  (yours)")
		expect(gordon.printed[5]):toBe("mayor      1/1  salary 130")

		-- Another module may forbid a change; the admin changes jobs at once.
		local handle = m.NC.Events:On("mode_city.canJob", function(ply)
			if ply == barney then
				return false
			end
		end)
		expect({ city:SetJob(barney, "bandit") }):toEqual({ false, "denied" })
		handle:Off()
		server:Command("nc_setjob", nil, { "Barney", "mayor" })
		expect({ roles:Of(barney), #city:Members("mayor") }):toEqual({ "mayor", 2 })

		-- After the cooldown: the gear of the police goes away, the gear of the medic comes.
		run(server, 30)
		expect(city:SetJob(gordon, "medic")):toBe(true)
		expect({ inventory:Count(gordon, "usp"), inventory:Count(gordon, "handcuffs"), inventory:Count(gordon, "gauze"),
			inventory:Count(gordon, "bandage"), inventory:Count(gordon, "morphine") }):toEqual({ 0, 0, 3, 5, 2 })
		expect(gordon:WeaponClasses()):toEqual({ "nc_hands" })

		-- The dead come back with the gear of their job; the city never ends.
		Env.Kill(gordon, alyx)
		server:Advance(0.1)
		expect(m.players:IsAlive(gordon)):toBe(false)
		run(server, 10.2)
		expect(m.players:IsAlive(gordon)):toBe(true)
		expect({ roles:Of(gordon), inventory:Count(gordon, "bandage") }):toEqual({ "medic", 5 })
		run(server, 600)
		expect(m.rounds:Phase()):toBe("active")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("pays the salaries of the jobs and keeps the names citizens choose", function()
		local server, m = boot({ params = { payday = 60 } })
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		run(server, 5.3)
		local city, economy = m.mode_city, m.economy
		city:SetJob(gordon, "police")
		local cut = m.NC.Events:On("mode_city.salary", function(salary, ply)
			if ply == alyx then
				return 0
			end
			return salary
		end)
		run(server, 60)
		expect({ economy:Balance(gordon), economy:Balance(alyx) }):toEqual({ 585, 500 })
		expect(hud(server, client)):toContain("Зарплата: $85 на счёт")
		cut:Off()
		run(server, 60)
		expect({ economy:Balance(gordon), economy:Balance(alyx) }):toEqual({ 670, 545 })

		-- Names: cleaned up, unique, shown to everybody, kept for the next visit.
		gordon.printed = {}
		server:Command("nc_rpname", gordon, { "  John", " Freeman " })
		expect(gordon.printed[1]):toBe("nc_rpname: you are John Freeman")
		expect(m.players:Name(gordon)):toBe("John Freeman")
		expect({ city:SetName(alyx, "john freeman") }):toEqual({ false, "taken" })
		expect({ city:SetName(alyx, "A") }):toEqual({ false, "short" })
		expect({ city:SetName(alyx, string.rep("x", 33)) }):toEqual({ false, "long" })
		expect({ city:SetName(alyx, "<b>Alyx") }):toEqual({ false, "chars" })
		expect(city:SetName(alyx, "Алиса Вэнс")):toBe(true)
		server:Advance(0.3)
		hud(server, client)
		local players = client:Get("NC").Modules:Instance("players")
		expect({ players:Name(gordon), players:Name(alyx) }):toEqual({ "John Freeman", "Алиса Вэнс" })
		expect(client.chatLines):toContain("Gordon теперь: Полицейский")
		local cl = client:Get("NC").Modules:Instance("mode_city")
		expect(cl:AddTargetLine({}, gordon)):toEqual({ "Полицейский" })

		server:Advance(3)
		local again, m2 = boot({ data = server.data })
		local _, back = Env.Join(again, { name = "Gordon", index = gordon:EntIndex() })
		again:Advance(0.1)
		expect(m2.players:Name(back)):toBe("John Freeman")
		expect(m2.economy:Balance(back)):toBe(670)
		expect(again:Errors()):toEqual({})
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
	it("sells each job the goods of its trade for the money of the account and then the cash", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		run(server, 5.3)
		local city, economy, inventory = m.mode_city, m.economy, m.inventory
		local cl = client:Get("NC").Modules:Instance("mode_city")
		expect(economy:Balance(gordon)):toBe(500)

		-- What a citizen may buy, and what not.
		gordon.printed = {}
		server:Command("nc_buy", gordon, {})
		expect(gordon.printed):toEqual({ "bandage        x1        $15", "pouch          x1        $40",
			"backpack       x1       $180" })
		server:Command("nc_buy", nil, {})
		expect(server:Lines("usp ")[1]):toContain("usp            x1       $250  gundealer")
		expect({ city:Buy(gordon, "usp") }):toEqual({ false, "job" })
		expect({ city:Buy(gordon, "caviar") }):toEqual({ false, "unknown" })
		expect({ city:Buy(gordon, "bandage", 0) }):toEqual({ false, "times" })
		expect({ city:Buy(gordon, "bandage", 21) }):toEqual({ false, "times" })
		expect({ city:Buy(gordon, "bandage", 1.5) }):toEqual({ false, "times" })
		expect(economy:Balance(gordon)):toBe(500)

		-- Bought things are his own: apart from the gear of the job, free to drop.
		expect({ city:Buy(gordon, "bandage", 2) }):toEqual({ true, 2 })
		expect({ economy:Balance(gordon), inventory:Count(gordon, "bandage") }):toEqual({ 470, 3 })
		local own
		for _, item in ipairs(inventory:ItemsOf(gordon)) do
			if item.id == "bandage" and not (item.state and item.state.issued) then
				own = item
			end
		end
		expect(own.count):toBe(2)
		expect(inventory:Act(gordon, own.container.id, own.slot, "drop")):toBe(true)
		expect(inventory:Count(gordon, "bandage")):toBe(1)
		gordon.printed = {}
		server:Command("nc_buy", gordon, { "bandage", "2" })
		expect(gordon.printed[1]):toBe("nc_buy bandage: bought 2 for $30")
		expect(hud(server, client)):toContain("Bought: Bandage ×2 for $30")

		-- The gun dealer buys guns: the account first, then the cash he carries.
		city:SetJob(gordon, "gundealer", true)
		expect({ inventory:Count(gordon, "bandage"), inventory:Count(gordon, "usp") }):toEqual({ 2, 1 })
		expect({ city:Buy(gordon, "usp") }):toEqual({ true, 1 })
		expect({ inventory:Count(gordon, "usp"), economy:Balance(gordon) }):toEqual({ 2, 190 })
		expect({ city:Buy(gordon, "mp7") }):toEqual({ false, "funds" })
		economy:GiveCash(gordon, 1000)
		expect(city:Buy(gordon, "mp7")):toBe(true)
		expect({ economy:Balance(gordon), economy:Cash(gordon) }):toEqual({ 0, 90 })
		expect({ city:Buy(gordon, "ammo_9x19", 3) }):toEqual({ false, "funds" })
		expect(city:Buy(gordon, "ammo_9x19", 2)):toBe(true)
		expect({ inventory:Count(gordon, "ammo_9x19"), economy:Wealth(gordon) }):toEqual({ 75, 0 })

		-- Another module may forbid a purchase.
		economy:SetBalance(gordon, 100000)
		local handle = m.NC.Events:On("mode_city.canBuy", function(_, id)
			if id == "python" then
				return false
			end
		end)
		expect({ city:Buy(gordon, "python") }):toEqual({ false, "denied" })
		handle:Off()

		-- The menu buys over the net; what does not fit falls at his feet.
		local ground = #inventory.groundList
		cl:AskBuy("backpack", 20)
		local drawn = hud(server, client)
		expect(drawn):toContain("Bought: Backpack ×20 for $3 600")
		expect(economy:Balance(gordon)):toBe(100000 - 3600)
		expect(#inventory.groundList > ground):toBe(true)
		local dropped = false
		for _, text in ipairs(drawn) do
			if text:find("did not fit and fell at your feet", 1, true) then
				dropped = true
			end
		end
		expect(dropped):toBe(true)

		-- The menu changes jobs and names over the net too.
		run(server, 30)
		cl:AskJob("medic")
		cl:AskName("Gordon Freeman")
		hud(server, client)
		expect({ m.roles:Of(gordon), m.players:Name(gordon) }):toEqual({ "medic", "Gordon Freeman" })

		-- The dead do not shop.
		Env.Kill(gordon)
		server:Advance(0.1)
		expect({ city:Buy(gordon, "bandage") }):toEqual({ false, "dead" })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
