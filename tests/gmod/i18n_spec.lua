-- Translations service: language files, the client language and per-player texts,
-- with the real gamemode files in the emulated server and client.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local LANG = "nextcity/gamemode/lang/"
local CONFIG = "nextcity/gamemode/config.lua"

-- A third language, translated partly.
local function germanFiles()
	return {
		[LANG .. "de/_language.lua"] = [[return { name = "Deutsch", english = "German", fallback = "en" }]],
		[LANG .. "de/common.lua"] = [[return { yes = "Ja", no = "Nein" }]],
	}
end

local function loadedSet(env)
	local out = {}
	for _, path in ipairs(env.loaded) do
		out[path] = true
	end
	return out
end

local function recordChanges(env)
	local changes = {}
	env:Get("NC").Events:On("i18n.changed", function(code)
		changes[#changes + 1] = code
	end)
	return changes
end

local function configPatch(fn)
	return {
		[CONFIG] = function(cfg)
			fn(cfg)
			return cfg
		end,
	}
end

describe("i18n service", function()
	it("loads every language on the server and sends all translation files", function()
		local server = Env.Server({ files = germanFiles() }):Boot()
		expect(server:Errors()):toEqual({})
		local i18n = server:Get("NC").I18n
		local codes = {}
		for _, lang in ipairs(i18n:Languages()) do
			codes[#codes + 1] = lang.code
			expect(lang.loaded):toBe(true)
		end
		expect(codes):toEqual({ "de", "en", "ru" })
		local paths = { "en/_language.lua", "en/common.lua", "ru/_language.lua", "ru/common.lua", "de/common.lua" }
		for _, path in ipairs(paths) do
			expect(server.sent[LANG .. path]):toBe(true)
		end
		expect(i18n:Language()):toBe("en")
		expect(i18n:T("common.yes")):toBe("Yes")
		expect(i18n:T("common.players.count", { count = 1 })):toBe("1 player")
	end)

	it("builds texts in the language each player reported", function()
		local server = Env.Server():Boot()
		local NC = server:Get("NC")
		local i18n = NC.I18n
		local reports = {}
		NC.Events:On("i18n.playerLanguage", function(ply, code)
			reports[#reports + 1] = ply:Nick() .. "=" .. code
		end)
		local ivan, john = Env.FakePlayer({ name = "Ivan" }), Env.FakePlayer({ name = "John" })
		expect(i18n:TFor(ivan, "common.yes")):toBe("Yes")
		expect(i18n:LanguageOf(ivan)):toBe("en")

		expect(i18n:SetPlayerLanguage(ivan, "ru-RU")):toBe("ru")
		expect(i18n:SetPlayerLanguage(john, "pt_BR")):toBe("en")
		expect(i18n:SetPlayerLanguage(ivan, "ru")):toBe("ru")
		expect(i18n:SetPlayerLanguage(john, "not a code")):toBe("en")
		expect(reports):toEqual({ "Ivan=ru", "John=en" })

		expect(i18n:LanguageOf(ivan)):toBe("ru")
		expect(i18n:TFor(ivan, "common.yes")):toBe("Да")
		expect(i18n:TFor(ivan, "common.players.count", { count = 22 })):toBe("22 игрока")
		expect(i18n:TFor(ivan, "common.players.count", { count = 11 })):toBe("11 игроков")
		expect(i18n:TFor(john, "common.players.count", { count = 2 })):toBe("2 players")
		expect(i18n:T("common.yes")):toBe("Yes")

		server:Call("PlayerDisconnected", ivan)
		expect(i18n:LanguageOf(ivan)):toBe("en")
		expect(i18n:TFor(ivan, "common.yes")):toBe("Yes")
		expect(server:Errors()):toEqual({})
	end)

	it("picks the game language on the client and loads only the languages it needs", function()
		local server = Env.Server({ files = germanFiles() }):Boot()
		local client = Env.Client(server, { language = "ru" }):Boot()
		expect(client:Errors()):toEqual({})
		local i18n = client:Get("NC").I18n
		expect(i18n:Language()):toBe("ru")
		expect(i18n:T("common.yes")):toBe("Да")
		expect(i18n:T("common.time.minutes", { count = 5 })):toBe("5 минут")
		local loaded = loadedSet(client)
		expect(loaded[LANG .. "ru/common.lua"]):toBe(true)
		expect(loaded[LANG .. "en/common.lua"]):toBe(true)
		expect(loaded[LANG .. "de/_language.lua"]):toBe(true)
		expect(loaded[LANG .. "de/common.lua"]):toBeNil()

		local regional = Env.Client(server, { language = "de-AT" }):Boot()
		local german = regional:Get("NC").I18n
		expect(german:Language()):toBe("de")
		expect(german:T("common.yes")):toBe("Ja")
		expect(german:T("common.cancel")):toBe("Cancel")
		expect(loadedSet(regional)[LANG .. "ru/common.lua"]):toBeNil()

		local unknown = Env.Client(server, { language = "ja" }):Boot()
		expect(unknown:Get("NC").I18n:Language()):toBe("en")
		expect(#unknown:Lines("WARN")):toBe(0)
	end)

	it("uses the saved nc_language choice over the game language", function()
		local server = Env.Server():Boot()
		local client = Env.Client(server, { language = "en", convars = { nc_language = "ru" } }):Boot()
		expect(client:Get("NC").I18n:Language()):toBe("ru")
		expect(client:Get("NC").I18n:Requested()):toBe("ru")
	end)

	it("switches the language at runtime and tells modules about it", function()
		local server = Env.Server():Boot()
		local client = Env.Client(server):Boot()
		local i18n = client:Get("NC").I18n
		local changes = recordChanges(client)
		expect(i18n:Language()):toBe("en")
		expect(loadedSet(client)[LANG .. "ru/common.lua"]):toBeNil()

		client:SetConVar("nc_language", "ru")
		expect(changes):toEqual({ "ru" })
		expect(i18n:T("common.yes")):toBe("Да")
		expect(loadedSet(client)[LANG .. "ru/common.lua"]):toBe(true)

		client:SetConVar("gmod_language", "ru")
		client:SetConVar("nc_language", "auto")
		expect(changes):toEqual({ "ru" })
		client:SetConVar("gmod_language", "en")
		expect(changes):toEqual({ "ru", "en" })

		expect(i18n:SetLanguage("RU")):toBe("ru")
		expect(client.convars.nc_language:GetString()):toBe("ru")
		local code, err = i18n:SetLanguage("??")
		expect(code):toBeNil()
		expect(err):toContain("is not a language code")
		expect(client.convars.nc_language:GetString()):toBe("ru")
		expect(i18n:SetLanguage()):toBe("en")
		expect(client.convars.nc_language:GetString()):toBe("auto")
		expect(changes):toEqual({ "ru", "en", "ru", "en" })

		client:SetConVar("nc_language", "??")
		client:SetConVar("gmod_language", "ru")
		expect(i18n:Language()):toBe("ru")
		expect(#client:Lines("nc_language \"??\" is not a language code, using the game language")):toBe(1)
		expect(client:Errors()):toEqual({})
	end)

	it("logs a missing key once and shows the key itself", function()
		local server = Env.Server():Boot()
		local client = Env.Client(server, { language = "ru" }):Boot()
		local i18n = client:Get("NC").I18n
		expect(i18n:T("hud.nothing")):toBe("hud.nothing")
		expect(i18n:T("hud.nothing")):toBe("hud.nothing")
		expect(i18n:Has("hud.nothing")):toBe(false)
		expect(i18n:Has("common.yes")):toBe(true)
		expect(#client:Lines("missing translation 'hud.nothing' (language 'ru')")):toBe(1)
	end)

	it("shows the forced language to everybody", function()
		local patch = configPatch(function(cfg)
			cfg.i18n.force = "ru"
		end)
		local server = Env.Server({ patch = patch }):Boot()
		local client = Env.Client(server, { language = "en", convars = { nc_language = "en" } }):Boot()
		local changes = recordChanges(client)
		expect(client:Get("NC").I18n:Language()):toBe("ru")
		client:SetConVar("nc_language", "auto")
		expect(client:Get("NC").I18n:Language()):toBe("ru")
		expect(changes):toEqual({})

		local i18n = server:Get("NC").I18n
		local ply = Env.FakePlayer()
		i18n:SetPlayerLanguage(ply, "en")
		expect(i18n:Language()):toBe("ru")
		expect(i18n:LanguageOf(ply)):toBe("ru")
		expect(i18n:TFor(ply, "common.yes")):toBe("Да")
		expect(i18n:T("common.yes")):toBe("Да")
		expect(server:Errors()):toEqual({})
	end)

	it("warns about a bad language config and keeps working", function()
		local patch = configPatch(function(cfg)
			cfg.i18n.default = "??"
			cfg.i18n.force = 42
		end)
		local server = Env.Server({ patch = patch }):Boot()
		expect(#server:Lines("config i18n.default ?? is not a language code, using en")):toBe(1)
		expect(#server:Lines("config i18n.force 42 is not a language code, ignored")):toBe(1)
		expect(server:Get("NC").I18n:T("common.yes")):toBe("Yes")

		local missing = Env.Server({ patch = configPatch(function(cfg)
			cfg.i18n.default = "fr"
			cfg.i18n.force = "de"
		end) }):Boot()
		expect(#missing:Lines("default language 'fr' has no lang/fr folder")):toBe(1)
		expect(#missing:Lines("forced language 'de' has no lang/de folder")):toBe(1)
		expect(missing:Get("NC").started):toBe(true)
	end)

	it("reports broken translation files and keeps the rest", function()
		local files = {
			[LANG .. "de/_language.lua"] = [[return { name = "Deutsch", plural = "klingon" }]],
			[LANG .. "de/common.lua"] = [[error("boom")]],
			[LANG .. "de/hud.lua"] = [[return 42]],
			[LANG .. "de/keys.lua"] = [[return { ["bad key!"] = "x" }]],
			[LANG .. "de/Shouting.lua"] = [[return { hello = "HALLO" }]],
			[LANG .. "de/example.lua"] = [[return { greeting = "Willkommen, {name}!" }]],
			[LANG .. "fr/_language.lua"] = [[return {]],
			[LANG .. "fr/common.lua"] = [[return { yes = "Oui" }]],
			[LANG .. "Es/common.lua"] = [[return { yes = "Sí" }]],
		}
		local server = Env.Server({ files = files }):Boot()
		local NC = server:Get("NC")
		expect(NC.started):toBe(true)
		local errors = table.concat(server:Errors(), "\n")
		expect(errors):toContain("lang/de/_language.lua: language 'de': unknown plural rule 'klingon'")
		expect(errors):toContain("lang/de/common.lua: ")
		expect(errors):toContain("boom")
		expect(errors):toContain("lang/de/hud.lua: must return a table")
		expect(errors):toContain("lang/de/keys.lua: de/keys: bad key bad key!")
		expect(errors):toContain("lang/de/Shouting.lua: namespace must be a snake_case id")
		expect(errors):toContain("lang/fr/_language.lua: must return a table")
		expect(#server:Lines("lang/Es skipped: the folder name must be a lowercase language code")):toBe(1)
		expect(server.sent[LANG .. "Es/common.lua"]):toBeNil()

		local german = NC.I18n:Catalog():Translator("de")
		expect(german:Code()):toBe("de")
		expect(german:T("example.greeting", { name = "Hans" })):toBe("Willkommen, Hans!")
		expect(german:T("common.yes")):toBe("Yes")
		expect(NC.I18n:Catalog():Translator("fr"):T("common.yes")):toBe("Oui")
	end)

	it("keeps player languages and convar callbacks across autorefresh", function()
		local server = Env.Server():Boot()
		local stay, gone = Env.FakePlayer({ name = "Stay" }), Env.FakePlayer({ name = "Gone" })
		server:Get("NC").I18n:SetPlayerLanguage(stay, "ru")
		server:Get("NC").I18n:SetPlayerLanguage(gone, "ru")
		function gone:IsValid() return false end
		local oldEvents = server:Get("NC").Events
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		local i18n = server:Get("NC").I18n
		expect(oldEvents:Count()):toBe(0)
		expect(i18n:LanguageOf(stay)):toBe("ru")
		expect(i18n:LanguageOf(gone)):toBe("en")
		server:Call("PlayerDisconnected", stay)
		expect(i18n:LanguageOf(stay)):toBe("en")

		local client = Env.Client(server):Boot()
		local old = client:Get("NC").I18n
		client:Run(Env.ENTRY.client)
		client:Call("OnReloaded")
		local current = client:Get("NC").I18n
		expect(current):notToBe(old)
		expect(client:ChangeCallbacks("nc_language")):toBe(1)
		expect(client:ChangeCallbacks("gmod_language")):toBe(1)
		local changes = recordChanges(client)
		client:SetConVar("nc_language", "ru")
		expect(changes):toEqual({ "ru" })
		expect(current:Language()):toBe("ru")
		expect(old:Language()):toBe("en")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("lists languages and translation problems with nc_lang", function()
		local server = Env.Server({ files = germanFiles() }):Boot()
		server:Command("nc_lang")
		expect(#server:Lines("Languages (server): default en, in use en,")):toBe(1)
		expect(server:Lines("  ru ")[1]):toContain("100%")
		expect(server:Lines("  ru ")[1]):toContain("(Russian)")
		expect(server:Lines("  de ")[1]):toContain("Deutsch (German)")

		server:Command("nc_lang", nil, { "DE" })
		expect(#server:Lines("Translation problems of 'de' against 'en':")):toBe(1)
		expect(#server:Lines("common.cancel: not translated")):toBe(1)
		expect(#server:Lines("example.greeting: not translated")):toBe(1)
		server:Command("nc_lang", nil, { "ru" })
		expect(server.console[#server.console]):toBe("  none")
		server:Command("nc_lang", nil, { "xx" })
		expect(server.console[#server.console]):toBe("Unknown language 'xx' (no lang/xx folder)")

		local guest = Env.FakePlayer()
		server:Command("nc_lang", guest)
		expect(guest.printed):toEqual({ "nc_lang: superadmin only" })

		local client = Env.Client(server):Boot()
		client:Command("nc_lang_cl")
		expect(client:Lines("  de ")[1]):toContain("not loaded")
		client:Command("nc_lang_cl", nil, { "de" })
		expect(client.console[#client.console]):toBe("Language 'de' is not loaded on the client")
	end)

	it("ships translations without problems", function()
		local server = Env.Server():Boot()
		local i18n = server:Get("NC").I18n
		local problems = {}
		for _, problem in ipairs(i18n:Check()) do
			local allowed = problem.kind == "missing" and problem.code ~= "en" and problem.code ~= "ru"
			if not allowed then
				problems[#problems + 1] = problem.code .. " " .. problem.key .. ": " .. problem.message
			end
		end
		expect(problems):toEqual({})
		for _, lang in ipairs(i18n:Languages()) do
			expect(server.files[LANG .. lang.code .. "/_language.lua"]):toBe(true)
			expect(lang.name ~= lang.code):toBe(true)
		end
		expect(i18n:Catalog():HasLanguage("ru")):toBe(true)
	end)
end)
