-- Identity: the character of every player in his profile (a random one for newcomers in
-- their language), the rules of names and their uniqueness in any case (also offline), the
-- cooldown of changes, a given name that follows the gender, admins and modes, others see
-- the character only where a mode turns identities on, the character tab of the menu, the
-- names of the city of earlier versions.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World

local CLOCK = 1700000000
local MODULES = { "players", "storage", "profiles", "identity", "notices", "menu" }

-- opts: data (DATA of an earlier server), settings of identity. Random picks the first
-- name of every list (the first try of a name, the first gender).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = MODULES, data = opts.data, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.identity = opts.settings
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local identity = NC.Modules:Instance("identity")
	server.clock = CLOCK
	identity.Now = function() return server.clock end
	identity.Random = function() return 1 end
	return server, NC, identity
end

-- Lets the server answer and the client learn it.
local function settle(server, client)
	for _ = 1, 2 do
		server:Advance(0.5)
		client.time = server.time
		Env.Flush(server, client)
	end
end

-- The texts the client draws (the notices among them).
local function hud(server, client)
	settle(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

local function panels(client, field, value)
	return World.FindPanels(client, function(panel)
		return rawget(panel, field) ~= nil and (value == nil or rawget(panel, field) == value)
	end)
end

local function click(client, field, value)
	local button = panels(client, field, value)[1]
	assert(button ~= nil, "no panel with " .. field .. " = " .. tostring(value))
	button.DoClick(button)
end

local function labels(client)
	local out = {}
	for _, panel in ipairs(World.FindPanels(client, function(panel) return panel.class == "DLabel" end)) do
		out[#out + 1] = panel:GetText()
	end
	return out
end

describe("identity", function()
	it("gives a newcomer a random character in his language and keeps it in his profile", function()
		local server, NC, identity = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		expect(identity:Character(gordon)):toEqual({ name = "Александр Иванов", gender = "male", random = true,
			changed = 0 })
		local players = NC.Modules:Instance("players")
		expect(players:Name(gordon)):toBe("Gordon") -- no mode turns identities on

		-- A name taken: the next newcomer gets a double last name; English for other languages.
		local _, alyx = Env.Join(server, { name = "Alyx", language = "ru" })
		expect(identity:Character(alyx).name):toBe("Александр Иванов-Иванов")
		local _, eli = Env.Join(server, { name = "Eli", language = "de" })
		expect(identity:Character(eli).name):toBe("James Smith")
		local bot = Env.Bot(server, { name = "Bot01" })
		server:Advance(0.1)
		expect(identity:Character(bot).name):toBe("James Smith-Smith")
		settle(server, client)
		local mine = client:Get("NC").Modules:Instance("identity")
		expect(mine:Character()):toEqual({ name = "Александр Иванов", gender = "male", random = true, ready = 0 })
		expect(mine:Wait()):toBe(0)

		-- The profile keeps it for the next visit; the names taken stay taken, those of bots
		-- for the session only.
		local profiles = NC.Modules:Instance("profiles")
		expect(profiles:Section(gordon, "identity").name):toBe("Александр Иванов")
		Env.Leave(server, gordon)
		server:Advance(3)
		local again, _, identity2 = boot({ data = server.data })
		local _, back = Env.Join(again, { name = "Gordon", index = gordon:EntIndex(), language = "ru" })
		expect(identity2:Character(back)):toEqual({ name = "Александр Иванов", gender = "male", random = true,
			changed = 0 })
		expect(identity2:IsTaken("АЛЕКСАНДР ИВАНОВ-ИВАНОВ")):toBe(true)
		expect(identity2:IsTaken("James Smith-Smith")):toBe(false)
		expect(identity2:IsTaken("Александр Иванов", back)):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(again:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("shows characters instead of nicks only while a mode turns identities on", function()
		local server, NC, identity = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local bob = Env.Bot(server, { name = "Bob" })
		local players = NC.Modules:Instance("players")
		local on = NC.Events:On("identity.enabled", function(ply)
			if ply == gordon then
				return true
			end
		end)
		server:Advance(1)
		expect({ players:Name(gordon), players:Name(bob) }):toEqual({ "James Smith", "Bob" })
		expect({ identity:IsShown(gordon), identity:Name(gordon), identity:Gender(gordon) })
			:toEqual({ true, "James Smith", "male" })
		expect(identity:IsShown(bob)):toBe(false)
		settle(server, client)
		local mirror = client:Get("NC").Modules:Instance("players")
		expect({ mirror:Name(gordon), mirror:Name(bob) }):toEqual({ "James Smith", "Bob" })

		-- The answer of a mode (an alias) wins over the character.
		local alias = NC.Events:On("players.name", function(_, ply)
			if ply == gordon then
				return "Alpha"
			end
		end)
		expect(players:Name(gordon)):toBe("Alpha")
		alias:Off()

		-- A change shows at once; autorefresh keeps the characters (the answers come again).
		expect(identity:Change(gordon, "Gordon Freeman")):toBe(true)
		expect(players:Name(gordon)):toBe("Gordon Freeman")
		on:Off()
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		local reloaded = NC.Modules:Instance("identity")
		players = NC.Modules:Instance("players")
		expect(reloaded:Character(gordon).name):toBe("Gordon Freeman")
		on = NC.Events:On("identity.enabled", function(ply)
			if ply == gordon then
				return true
			end
		end)
		server:Advance(1)
		expect({ players:Name(gordon), reloaded:IsShown(gordon) }):toEqual({ "Gordon Freeman", true })

		-- Off again: everybody sees the nick.
		on:Off()
		server:Advance(1)
		settle(server, client)
		expect({ players:Name(gordon), mirror:Name(gordon), reloaded:IsShown(gordon) })
			:toEqual({ "Gordon", "Gordon", false })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("checks names: cleaned up, the rules, unique in any case, also offline", function()
		local server, NC, identity = boot({ settings = { random = false, minWords = 2 } })
		local _, bob = Env.Join(server, { name = "Bob", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local eli = Env.Bot(server, { name = "Eli" })
		server:Advance(0.1)
		expect(identity:Character(alyx)):toEqual({ name = "", gender = "male", random = false, changed = 0 })
		expect(NC.Modules:Instance("players"):Name(alyx)):toBe("Alyx")

		expect(identity:Change(bob, "  Jean-Luc   O'Neil ")):toBe(true)
		expect(identity:Character(bob).name):toBe("Jean-Luc O'Neil")
		expect({ identity:NameProblem("J"), identity:NameProblem(string.rep("x", 33)),
			identity:NameProblem(string.rep("ж", 16) .. " " .. string.rep("ж", 15)),
			identity:NameProblem(string.rep("ж", 16) .. " " .. string.rep("ж", 16)) })
			:toEqual({ "short", "long", nil, "long" })
		expect({ identity:NameProblem("Bob 2"), identity:NameProblem("<b>Alyx Vance"), identity:NameProblem("- Bob"),
			identity:NameProblem("Alyx"), identity:NameProblem("A b c d e"), identity:NameProblem("St. John Smith") })
			:toEqual({ "chars", "chars", "chars", "words", "words", nil })
		expect(identity.Fold("ЁЖИК Ivan Ёлкин")):toBe("ёжик ivan ёлкин")
		expect(identity.Length("Алиса Вэнс")):toBe(10)
		expect(identity.CleanName("  a \t b  ")):toBe("a b")

		expect({ identity:Change(alyx, "JEAN-LUC o'neil") }):toEqual({ false, "taken" })
		expect({ identity:Change(alyx, "Alyx") }):toEqual({ false, "words" })
		expect(identity:Change(alyx, "Алиса Вэнс", "female")):toBe(true)
		expect({ identity:Change(eli, "АЛИСА ВЭНС") }):toEqual({ false, "taken" })
		expect({ identity:Change(eli, nil, "robot") }):toEqual({ false, "gender" })
		expect({ identity:Change(alyx, "Алиса Вэнс", "female") }):toEqual({ false, "same" })
		-- Bots keep the names for the session; players in the registry of storage.
		Env.Leave(server, alyx)
		expect(identity:IsTaken("алиса вэнс")):toBe(true)
		local storage = NC.Modules:Instance("storage")
		local profiles = NC.Modules:Instance("profiles")
		expect(storage:Open("identity"):Get("jean-luc o'neil")):toBe(profiles:Key(bob))
		expect(storage:Open("identity"):Get("алиса вэнс")):toBeNil()
		Env.Leave(server, bob)
		server:Advance(3)

		local again, NC2, identity2 = boot({ data = server.data, settings = { random = false } })
		local _, kleiner = Env.Join(again, { name = "Kleiner", language = "en" })
		expect({ identity2:Change(kleiner, "Jean-Luc O'Neil") }):toEqual({ false, "taken" })
		local _, back = Env.Join(again, { name = "Bob", index = bob:EntIndex(), language = "en" })
		again.clock = CLOCK + 1800
		expect(identity2:Change(back, "Jean Luc")):toBe(true)
		expect(identity2:Change(kleiner, "Jean-Luc O'Neil")):toBe(true)
		expect(NC2.Modules:Instance("storage"):Open("identity"):Get("jean luc")):toBe(profiles:Key(bob))
		expect(server:Errors()):toEqual({})
		expect(again:Errors()):toEqual({})
	end)

	it("changes a character once in a cooldown; a given name follows the gender; admins and modes", function()
		local server, NC, identity = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		expect(identity:Request(gordon, nil, "female")):toBe(true)
		expect(identity:Character(gordon)):toEqual({ name = "Александра Иванова", gender = "female", random = true,
			changed = 0 })
		expect(hud(server, client)):toContain("Ваш персонаж: Александра Иванова, женщина")

		gordon.printed = {}
		server:Command("nc_rpname", gordon, { "Анна", "Каренина" })
		expect(gordon.printed[1]):toBe("nc_rpname: you are Анна Каренина, female (others see the nick now)")
		expect(identity:Character(gordon)):toEqual({ name = "Анна Каренина", gender = "female", random = false,
			changed = CLOCK })
		expect({ identity:Request(gordon, "Анна Павлова") }):toEqual({ false, "cooldown", 1800 })
		expect(hud(server, client)):toContain("Сменить персонажа можно через 30 минут")
		server:Command("nc_gender", gordon, { "male" })
		expect(gordon.printed[2]):toBe("nc_gender: cooldown (1800 s)")
		server:Command("nc_gender", gordon, {})
		expect(gordon.printed[3]):toBe("nc_gender: you are Анна Каренина, female (others see the nick now)")
		local mine = client:Get("NC").Modules:Instance("identity")
		expect(mine:Wait() > 1790):toBe(true)

		-- After the cooldown; the gender alone keeps an own name.
		server.clock = CLOCK + 1800
		expect(identity:Wait(gordon)):toBe(0)
		expect(identity:Request(gordon, nil, "male")):toBe(true)
		expect(identity:Character(gordon)):toEqual({ name = "Анна Каренина", gender = "male", random = false,
			changed = CLOCK + 1800 })

		-- A mode may refuse a change.
		server.clock = CLOCK + 3600
		local deny = NC.Events:On("identity.canChange", function() return false end)
		expect({ identity:Change(gordon, "Анна Павлова") }):toEqual({ false, "denied" })
		deny:Off()

		-- An admin renames anybody at once; others may not.
		local _, breen = Env.Join(server, { name = "Breen", language = "en", superadmin = true })
		breen.printed = {}
		server:Command("nc_setname", breen, { "Gordon", "Иван", "Грозный" })
		expect(breen.printed[1]):toBe("nc_setname: Gordon is Иван Грозный, male (others see the nick now)")
		expect(identity:Character(gordon).changed):toBe(CLOCK + 1800)
		expect(hud(server, client)):toContain("Администратор дал вашему персонажу имя Иван Грозный")
		server:Command("nc_setname", gordon, { "Breen", "Wallace", "Breen" })
		expect(gordon.printed[#gordon.printed]):toBe("nc_setname: no access")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("has a tab in the menu: the name typed or random, the gender, saving, the waiting", function()
		local server, NC, identity = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		settle(server, client)
		local menu = client:Get("NC").Modules:Instance("menu")
		local mine = client:Get("NC").Modules:Instance("identity")
		mine.Random = function() return 2 end
		menu:Open("character")
		expect(menu:Tab()):toBe("character")
		expect(panels(client, "ncTab", "character")[1]:GetText()):toBe("Character")
		local texts = labels(client)
		expect(texts):toContain("Your character")
		expect(texts):toContain("Others see your nick Gordon now: the character shows in modes with role names, "
			.. "such as the city")
		expect(texts):toContain("The name was given at random: the first change needs no waiting")
		expect(texts):toContain("2–32 characters: letters, spaces, ' - and .")
		expect(texts):toContain("After a change the next one is possible in 30 minutes")
		expect(panels(client, "ncEntry", "name")[1]:GetValue()):toBe("James Smith")
		expect(panels(client, "ncGender", "male")[1].ncActive):toBe(true)

		-- The gender picked, a random name for it, saved.
		click(client, "ncGender", "female")
		expect({ panels(client, "ncGender", "female")[1].ncActive, panels(client, "ncGender", "male")[1].ncActive })
			:toEqual({ true, false })
		click(client, "ncAction", "random")
		expect(panels(client, "ncEntry", "name")[1]:GetValue()):toBe("Patricia Johnson")
		click(client, "ncAction", "save")
		expect(#client:Sent("nc.identity.change")):toBe(1)
		expect(hud(server, client)):toContain("Your character: Patricia Johnson, female")
		expect(identity:Character(gordon)):toEqual({ name = "Patricia Johnson", gender = "female", random = false,
			changed = CLOCK })
		menu:Refresh(false)
		expect(panels(client, "ncWait")[1]:GetText()):toBe("You can change the character again in 30 minutes")
		expect(panels(client, "ncGender", "female")[1].ncActive):toBe(true)

		-- Where others see the character, the tab says so.
		NC.Events:On("identity.enabled", function() return true end)
		server:Advance(1)
		settle(server, client)
		menu:Refresh(false)
		expect(panels(client, "ncShown")[1]:GetText()):toBe("Others see you as Patricia Johnson")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("moves the names of the city of earlier versions into the profiles", function()
		local first = boot()
		local _, gordon = Env.Join(first, { name = "Gordon", language = "en" })
		local _, alyx = Env.Join(first, { name = "Alyx", language = "en" })
		local data = { ["nextcity/city.json"] = string.format("{\"%s\":{\"name\":\" John  Freeman \"},"
			.. "\"%s\":{\"name\":\"<b>\"}}", gordon:SteamID64(), alyx:SteamID64()) }
		local server, NC, identity = boot({ data = data })
		local _, back = Env.Join(server, { name = "Gordon", index = gordon:EntIndex(), language = "en" })
		local _, alyx2 = Env.Join(server, { name = "Alyx", index = alyx:EntIndex(), language = "en" })
		expect(identity:Character(back)):toEqual({ name = "John Freeman", gender = "male", random = false, changed = 0 })
		expect(identity:Character(alyx2)):toEqual({ name = "James Smith", gender = "male", random = true,
			changed = 0 })
		local storage = NC.Modules:Instance("storage")
		expect(storage:Open("city"):Count()):toBe(0)
		expect(storage:Open("identity"):Get("john freeman")):toBe(back:SteamID64())
		expect(server:Errors()):toEqual({})
	end)
end)
