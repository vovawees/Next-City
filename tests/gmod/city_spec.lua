-- City (the official package): an endless round, the jobs with their limits, cooldown and
-- gear (it stays with its owner and goes with the job), respawns, salaries into the bank
-- accounts, the characters of citizens (identity) instead of nicks, the local chat and the
-- shop of the jobs, with the real gamemode and package files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

-- opts: params of the city, data (DATA of an earlier server). Newcomers keep their nicks
-- until they choose a character (no random names of identity).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ data = opts.data, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "city", shuffle = false, params = { city = opts.params or {} } }
		cfg.modules.settings.identity = { random = false }
		return cfg
	end } })
	for i = 0, 5 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC }
	for _, id in ipairs({ "rounds", "roles", "players", "inventory", "economy", "law", "identity", "appearance",
		"mode_city" }) do
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

-- The panels of a client with `field` (equal to `value` when given).
local function panels(client, field, value)
	return World.FindPanels(client, function(panel)
		return rawget(panel, field) ~= nil and (value == nil or rawget(panel, field) == value)
	end)
end

-- Clicks the first panel of a client with `field` (= `value`), then lets the server answer
-- and the client learn what changed.
local function click(server, client, field, value)
	local button = panels(client, field, value)[1]
	assert(button ~= nil, "no panel with " .. field .. " = " .. tostring(value))
	button.DoClick(button)
	hud(server, client)
	return hud(server, client)
end

-- The values of `field` of the panels of a client that have it.
local function fields(client, field)
	local out = {}
	for i, panel in ipairs(panels(client, field)) do
		out[i] = rawget(panel, field)
	end
	return out
end

-- The text of the child of a panel with `field`.
local function childText(panel, field)
	for _, child in ipairs(panel.children) do
		if rawget(child, field) ~= nil then
			return child:GetText()
		end
	end
	return nil
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
		-- Citizens wear their own looks (appearance: random ones of the sets of the wardrobe).
		local look = m.appearance:Look(gordon)
		expect(gordon:GetModel()):toBe(look.model)
		expect(m.appearance:Allows(look.model)):toBe(true)

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

		-- Back among the citizens he wears his own look again.
		expect(city:SetJob(gordon, "citizen")):toBe(true)
		expect(gordon:GetModel()):toBe(look.model)
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

		-- Characters (identity): cleaned up, unique, everybody sees them in the city, kept for the
		-- next visit.
		gordon.printed = {}
		expect(m.players:Name(gordon)):toBe("Gordon")
		server:Command("nc_rpname", gordon, { "  John", " Freeman " })
		expect(gordon.printed[1]):toBe("nc_rpname: you are John Freeman, male")
		expect(m.players:Name(gordon)):toBe("John Freeman")
		local identity = m.identity
		expect({ identity:Change(alyx, "john freeman") }):toEqual({ false, "taken" })
		expect({ identity:Change(alyx, "A") }):toEqual({ false, "short" })
		expect({ identity:Change(alyx, string.rep("x", 33)) }):toEqual({ false, "long" })
		expect({ identity:Change(alyx, "<b>Alyx") }):toEqual({ false, "chars" })
		expect(identity:Change(alyx, "Алиса Вэнс", "female")):toBe(true)
		-- Her random look follows the gender of the character, the uniform of the police too.
		expect(alyx:GetModel()):toBe(m.appearance:Look(alyx).model)
		expect(alyx:GetModel()):toContain("female")
		expect(city:SetJob(alyx, "police")):toBe(true)
		expect({ gordon:GetModel(), alyx:GetModel() }):toEqual({ "models/player/police.mdl",
			"models/player/police_fem.mdl" })
		server:Advance(0.3)
		hud(server, client)
		local players = client:Get("NC").Modules:Instance("players")
		expect({ players:Name(gordon), players:Name(alyx) }):toEqual({ "John Freeman", "Алиса Вэнс" })
		expect(client.chatLines):toContain("Gordon теперь: Полицейский")
		local cl = client:Get("NC").Modules:Instance("mode_city")
		expect(cl:AddTargetLine({}, gordon)):toEqual({ "Полицейский" })

		-- The chat of the city is local and carries the characters; out of character for all.
		gordon:SetPos(Vector(0, 0, 0))
		alyx:SetPos(Vector(2000, 0, 0))
		local _, seen = Env.Say(server, gordon, "Hello, citizens")
		expect(seen):toEqual({ gordon })
		expect(client.chatLines[#client.chatLines]):toBe("John Freeman: Hello, citizens")
		_, seen = Env.Say(server, gordon, "// afk")
		expect(seen):toEqual({ gordon, alyx })
		alyx:SetPos(Vector(200, 0, 0))
		_, seen = Env.Say(server, alyx, "/me машет рукой")
		expect(seen):toEqual({ gordon, alyx })
		expect(client.chatLines[#client.chatLines]):toBe("* Алиса Вэнс машет рукой")
		Env.Say(server, gordon, "/job medic")
		expect(client.chatLines[#client.chatLines]):toBe("nc_job: you are medic")

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

		-- The menus change jobs and characters over the net too.
		run(server, 30)
		cl:AskJob("medic")
		client:Get("NC").Modules:Instance("identity"):Ask("Gordon Freeman")
		hud(server, client)
		expect({ m.roles:Of(gordon), m.players:Name(gordon) }):toEqual({ "medic", "Gordon Freeman" })

		-- The dead do not shop.
		Env.Kill(gordon)
		server:Advance(0.1)
		expect({ city:Buy(gordon, "bandage") }):toEqual({ false, "dead" })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("opens the menu on F4: jobs and the name, the shop, the bank, the police; the money on the HUD", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		run(server, 5.3)
		local city, economy, law, roles = m.mode_city, m.economy, m.law, m.roles
		local cl = client:Get("NC").Modules:Instance("mode_city")
		-- The server answers, the client learns it, the open menu looks again.
		local function settle()
			hud(server, client)
			hud(server, client)
			cl:RefreshMenu(false)
		end

		-- The HUD: the money, the salary of the job, the key of the menu.
		local drawn = hud(server, client)
		expect(drawn):toContain("$500 in the bank · $0 cash")
		expect(drawn):toContain("Salary: $45")
		expect(drawn):toContain("F4: the menu of the city")

		-- F4 opens the menu on the jobs, F4 in the menu closes it; the help of F1 tells so.
		local help = client:Get("NC").Modules:Instance("menu")
		expect(help.help["mode_city.menu"] ~= nil):toBe(true)
		local function cityKey()
			for _, key in ipairs(help:Keys()) do
				if key.id == "mode_city.menu" then
					return key.key .. " " .. key.text
				end
			end
			return nil
		end
		expect(cityKey()):toBe("F4 The menu of the city: jobs, the shop, the bank, the police")
		expect(Env.BindPress(client, "gm_showspare2")):toBe(true)
		expect({ cl:IsMenuOpen(), cl:MenuTab() }):toEqual({ true, "jobs" })
		local frame = panels(client, "ncCityMenu")[1]
		expect(frame.popup):toBe(true)
		expect(fields(client, "ncTab")):toEqual({ "jobs", "shop", "bank" })
		expect(fields(client, "ncJob")):toEqual({ "citizen", "police", "medic", "gundealer", "mayor", "bandit" })
		local citizen = panels(client, "ncJob", "citizen")[1]
		expect(citizen:GetText()):toBe("Citizen — your job")
		expect(childText(citizen, "ncInfo")):toBe("Salary $45 · places 3/∞")
		expect(childText(panels(client, "ncJob", "police")[1], "ncInfo")):toBe("Salary $85 · places 0/4")
		client.keyBinds = { [95] = "gm_showspare2" }
		frame.OnKeyCodePressed(frame, 95)
		expect({ cl:IsMenuOpen(), frame.removed }):toEqual({ false, true })

		-- A job and a name from the menu; the menu follows the change of the job.
		cl:OpenMenu()
		click(server, client, "ncJob", "police")
		expect(roles:Of(gordon)):toBe("police")
		expect(fields(client, "ncTab")):toEqual({ "jobs", "shop", "bank", "police" })
		expect(panels(client, "ncJob", "police")[1]:GetText()):toBe("Police officer — your job")
		-- The name of the character: its tab in the menu of F1 changes it.
		expect(panels(client, "ncName")[1]:GetText()):toBe("Gordon")
		click(server, client, "ncAction", "character")
		local playerMenu = client:Get("NC").Modules:Instance("menu")
		expect({ cl:IsMenuOpen(), playerMenu:IsOpen(), playerMenu:Tab() }):toEqual({ false, true, "character" })
		panels(client, "ncEntry", "name")[1]:SetValue("Gordon Freeman")
		click(server, client, "ncAction", "save")
		expect(m.players:Name(gordon)):toBe("Gordon Freeman")
		playerMenu:Close()
		cl:OpenMenu()
		city:SetJob(alyx, "mayor", true)
		settle()
		local mayor = panels(client, "ncJob", "mayor")[1]
		expect({ mayor.ncFull, childText(mayor, "ncInfo") }):toEqual({ true, "Salary $130 · places 1/1" })
		expect(panels(client, "ncName")[1]:GetText()):toBe("Gordon Freeman")

		-- The shop of the job: once or five times at once; the money above follows.
		click(server, client, "ncTab", "shop")
		expect(cl:MenuTab()):toBe("shop")
		expect(fields(client, "ncPrice")[1]):toBe(true)
		local offers = {}
		for _, button in ipairs(panels(client, "ncTimes", 1)) do
			offers[#offers + 1] = button.ncOffer
		end
		expect(offers):toEqual({ "bandage", "pouch", "backpack", "ammo_9x19", "helmet", "vest_light", "vest",
			"zipties" })
		local five
		for _, button in ipairs(panels(client, "ncTimes", 5)) do
			if button.ncOffer == "bandage" then
				five = button
			end
		end
		expect(five:GetText()):toBe("×5")
		five.DoClick(five)
		drawn = hud(server, client)
		expect(drawn):toContain("Bought: Bandage ×5 for $75")
		expect(economy:Balance(gordon)):toBe(425)
		settle()
		expect(panels(client, "ncMoney")[1]:GetText()):toBe("$425 in the bank · $0 cash")

		-- The bank: the amount as typed, what was typed stays when the tab is built again.
		click(server, client, "ncTab", "bank")
		panels(client, "ncEntry", "amount")[1]:SetValue("$1 00")
		click(server, client, "ncBank", "withdraw")
		expect({ economy:Balance(gordon), economy:Cash(gordon) }):toEqual({ 325, 100 })
		cl:RefreshMenu(false)
		expect(panels(client, "ncBalance")[1]:GetText()):toBe("Account: $325")
		expect(panels(client, "ncCash")[1]:GetText()):toBe("Cash: $100")
		expect(panels(client, "ncEntry", "amount")[1]:GetValue()):toBe("$1 00")
		panels(client, "ncEntry", "amount")[1]:SetValue("40")
		click(server, client, "ncBank", "deposit")
		expect({ economy:Balance(gordon), economy:Cash(gordon) }):toEqual({ 365, 60 })
		expect(fields(client, "ncBank")):toEqual({ "deposit", "withdraw", "give", "drop" })

		-- The police: the others, the wanted first; warrants are the mayor's while there is one.
		click(server, client, "ncTab", "police")
		local function suspects()
			local out = {}
			for _, row in ipairs(panels(client, "ncSuspect")) do
				local ops = {}
				for _, child in ipairs(row.children) do
					if rawget(child, "ncLaw") ~= nil then
						ops[#ops + 1] = child.ncLaw
					end
				end
				out[#out + 1] = { childText(row, "ncName"), childText(row, "ncRecord"), ops }
			end
			return out
		end
		expect(suspects()):toEqual({ { "Alyx · Mayor", nil, { "want" } }, { "Barney · Citizen", nil, { "want" } } })
		panels(client, "ncEntry", "reason")[1]:SetValue("Robbery")
		for _, button in ipairs(panels(client, "ncLaw", "want")) do
			if button.ncTarget == barney then
				button.DoClick(button)
			end
		end
		settle()
		expect(law:Wanted(barney).reason):toBe("Robbery")
		expect(suspects()[1]):toEqual({ "Barney · Citizen", "wanted: Robbery", { "unwant" } })
		city:SetJob(alyx, "citizen", true)
		settle()
		expect(suspects()[1]):toEqual({ "Barney · Citizen", "wanted: Robbery", { "warrant", "unwant" } })
		click(server, client, "ncLaw", "warrant")
		expect(law:WarrantOf(barney).reason):toBe("Robbery")
		law:Jail(nil, barney, 60)
		settle()
		expect(suspects()[1]):toEqual({ "Barney · Citizen", "in jail · 1:00", { "release" } })
		click(server, client, "ncLaw", "release")
		expect(law:IsJailed(barney)):toBe(false)

		-- A citizen has no police tab; the menu closes when the city ends.
		city:SetJob(gordon, "citizen", true)
		hud(server, client)
		expect({ cl:MenuTab(), fields(client, "ncTab") }):toEqual({ "jobs", { "jobs", "shop", "bank" } })
		m.rounds:Round():End({ reason = "test" })
		settle()
		expect(cl:IsMenuOpen()):toBe(false)
		expect(Env.BindPress(client, "gm_showspare2")):toBe(nil)
		expect(cityKey()):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
