local I18n = T.load("core/i18n.lua")

local function captureLog()
	local log = { warnings = {} }
	local function noop() end
	log.Trace, log.Debug, log.Info, log.Error = noop, noop, noop, noop
	function log.Warn(_, fmt, ...)
		log.warnings[#log.warnings + 1] = string.format(fmt, ...)
	end
	return log
end

-- en (default) + ru with a few strings.
local function sample(opts)
	local catalog = I18n.New(opts)
	assert(catalog:AddLanguage("en", { name = "English" }))
	assert(catalog:AddLanguage("ru", { name = "Русский", plural = "east_slavic", fallback = "en" }))
	assert(catalog:Add("en", "rounds", {
		win = "Team {team} wins",
		start = "Round started",
		players = { one = "{count} player", other = "{count} players" },
		["hud.time"] = "Time left: {time}",
		only_en = { one = "{count} item", other = "{count} items" },
	}))
	assert(catalog:Add("ru", "rounds", {
		win = "Победила команда {team}",
		start = "Раунд начался",
		players = { one = "{count} игрок", few = "{count} игрока", many = "{count} игроков" },
		["hud.time"] = "Осталось: {time}",
	}))
	return catalog
end

describe("i18n codes", function()
	it("normalizes language codes", function()
		expect(I18n.Normalize("pt_BR")):toBe("pt-br")
		expect(I18n.Normalize(" RU ")):toBe("ru")
		expect(I18n.Normalize("zh-Hant-TW")):toBe("zh-hant-tw")
		expect(I18n.Normalize("fil")):toBe("fil")
		for _, bad in ipairs({ "", "e", "english", "en-", "en--us", "-en", "en us", "abcdefgh-ijklmnopq", 5, nil }) do
			expect(I18n.Normalize(bad)):toBeNil()
		end
	end)

	it("lists parent codes", function()
		expect(I18n.Parents("zh-hant-tw")):toEqual({ "zh-hant-tw", "zh-hant", "zh" })
		expect(I18n.Parents("ru")):toEqual({ "ru" })
	end)
end)

describe("i18n plural rules", function()
	local function categories(rule, numbers)
		local out = {}
		for i, n in ipairs(numbers) do
			out[i] = I18n.Plural(rule, n)
		end
		return out
	end

	it("selects east slavic forms", function()
		expect(categories("east_slavic", { 1, 2, 4, 5, 11, 12, 14, 21, 22, 25, 101, 111, 0, 1.5 })):toEqual({
			"one", "few", "few", "many", "many", "many", "many", "one", "few", "many", "one", "many", "many", "other",
		})
		expect(I18n.Plural("east_slavic", -2)):toBe("few")
	end)

	it("selects forms of other languages", function()
		expect(categories("one_other", { 1, 0, 2, 1.5 })):toEqual({ "one", "other", "other", "other" })
		expect(categories("zero_one", { 0, 1, 1.5, 2 })):toEqual({ "one", "one", "one", "other" })
		expect(categories("polish", { 1, 2, 5, 12, 21, 22 })):toEqual({ "one", "few", "many", "many", "many", "few" })
		expect(categories("czech", { 1, 3, 5, 1.5 })):toEqual({ "one", "few", "other", "many" })
		expect(categories("lithuanian", { 1, 2, 9, 10, 11, 21 })):toEqual({ "one", "few", "few", "other", "other", "one" })
		expect(categories("latvian", { 0, 1, 2, 10, 11, 21 })):toEqual({ "zero", "one", "other", "zero", "zero", "one" })
		expect(categories("romanian", { 1, 0, 2, 19, 20, 101, 102 }))
			:toEqual({ "one", "few", "few", "few", "other", "other", "few" })
		expect(categories("arabic", { 0, 1, 2, 3, 10, 11, 99, 100, 102 }))
			:toEqual({ "zero", "one", "two", "few", "few", "many", "many", "other", "other" })
		expect(categories("hebrew", { 1, 2, 3 })):toEqual({ "one", "two", "other" })
		expect(categories("none", { 1, 2 })):toEqual({ "other", "other" })
	end)

	it("lists and validates rules", function()
		expect(I18n.PluralRules()):toContain("east_slavic")
		expect(function() I18n.Plural("klingon", 1) end):toFail("unknown rule")
		expect(function() I18n.AddPluralRule("Bad", { required = { "one" }, select = print }) end):toFail("snake_case")
		expect(function() I18n.AddPluralRule("odd", { required = { "lots" }, select = print }) end):toFail("unknown category")
	end)
end)

describe("i18n catalog", function()
	it("validates languages", function()
		local catalog = I18n.New()
		expect(select(2, catalog:AddLanguage("RU", {}))):toContain("must be normalized")
		expect(select(2, catalog:AddLanguage("ru", { title = "x" }))):toContain("unknown meta key 'title'")
		expect(select(2, catalog:AddLanguage("ru", { plural = "klingon" }))):toContain("unknown plural rule")
		expect(select(2, catalog:AddLanguage("ru", { fallback = "ru" }))):toContain("bad fallback")
		expect(select(2, catalog:AddLanguage("ru", { name = 5 }))):toContain("name must be a string")
		expect(catalog:AddLanguage("ru", { name = "Русский" })):toBe(true)
		expect(catalog:HasLanguage("ru")):toBe(true)
	end)

	it("validates strings and adds nothing from a bad file", function()
		local catalog = sample()
		local function problem(code, namespace, strings)
			local ok, err = catalog:Add(code, namespace, strings)
			expect(ok):toBe(false)
			return err
		end
		expect(problem("de", "rounds", {})):toContain("unknown language 'de'")
		expect(problem("ru", "Rounds", {})):toContain("namespace must be a snake_case id")
		expect(problem("ru", "rounds", "text")):toContain("strings must be a table")
		expect(problem("ru", "rounds", { ["a..b"] = "x" })):toContain("bad key a..b")
		expect(problem("ru", "rounds", { ["a b"] = "x" })):toContain("bad key a b")
		expect(problem("ru", "rounds", { a = 5 })):toContain("a must be a string or a table of plural forms")
		expect(problem("ru", "rounds", { a = { lots = "x" } })):toContain("unknown plural form lots")
		expect(problem("ru", "rounds", { a = { one = 1 } })):toContain("plural form 'one' must be a string")
		expect(problem("ru", "rounds", { a = {} })):toContain("plural table has no forms")
		expect(problem("ru", "late", { good = "ok", bad = 5 })):toContain("bad must be")
		expect(catalog:Translator("ru"):Has("late.good")):toBe(false)
	end)

	it("lists languages and keys", function()
		local catalog = sample()
		local languages = catalog:Languages()
		expect(#languages):toBe(2)
		expect(languages[1].code):toBe("en")
		expect(languages[1].keys):toBe(5)
		expect(languages[2].name):toBe("Русский")
		expect(languages[2].plural):toBe("east_slavic")
		expect(catalog:Keys("ru")):toEqual({ "rounds.hud.time", "rounds.players", "rounds.start", "rounds.win" })
	end)

	it("builds fallback chains", function()
		local catalog = sample()
		assert(catalog:AddLanguage("uk", { plural = "east_slavic", fallback = "ru" }))
		assert(catalog:AddLanguage("pt", { plural = "zero_one" }))
		assert(catalog:AddLanguage("aa", { fallback = "bb" }))
		assert(catalog:AddLanguage("bb", { fallback = "aa" }))
		expect(catalog:Chain("uk")):toEqual({ "uk", "ru", "en" })
		expect(catalog:Chain("pt-br")):toEqual({ "pt", "en" })
		expect(catalog:Chain("xx")):toEqual({ "en" })
		expect(catalog:Chain("aa")):toEqual({ "aa", "bb", "en" })
		expect(catalog:Resolve("pt_BR")):toBe("pt")
		expect(catalog:Resolve("de")):toBe("en")
		expect(I18n.New():Resolve("en")):toBeNil()
	end)
end)

describe("i18n translator", function()
	it("translates plain strings and placeholders", function()
		local L = sample():Translator("ru")
		expect(L:T("rounds.start")):toBe("Раунд начался")
		expect(L:T("rounds.win", { team = "красных" })):toBe("Победила команда красных")
		expect(L:T("rounds.hud.time", { time = 42 })):toBe("Осталось: 42")
		expect(L:T("rounds.win")):toBe("Победила команда {team}")
		expect(L:T("rounds.win", {})):toBe("Победила команда {team}")
		expect(L:T("rounds.win", { team = true })):toBe("Победила команда true")
		expect(L:Code()):toBe("ru")
	end)

	it("selects plural forms with the rule of the source language", function()
		local L = sample():Translator("ru")
		expect(L:T("rounds.players", { count = 1 })):toBe("1 игрок")
		expect(L:T("rounds.players", { count = 3 })):toBe("3 игрока")
		expect(L:T("rounds.players", { count = 11 })):toBe("11 игроков")
		expect(L:T("rounds.players", { count = 21 })):toBe("21 игрок")
		-- no "other" form for fractions: falls back to "many"
		expect(L:T("rounds.players", { count = 1.5 })):toBe("1.5 игроков")
		-- English value reached through the fallback: English rule, so 3 -> other
		expect(L:T("rounds.only_en", { count = 3 })):toBe("3 items")
		expect(L:T("rounds.only_en", { count = 1 })):toBe("1 item")
		expect(L:T("rounds.only_en", { count = 0 / 0 })):toBe("nan items")
		expect(L:T("rounds.only_en")):toBe("{count} items")
	end)

	it("translates nested keys in params", function()
		local catalog = sample()
		assert(catalog:Add("ru", "teams", { red = "красных", loop = "{x}" }))
		local L = catalog:Translator("ru")
		expect(L:T("rounds.win", { team = { key = "teams.red" } })):toBe("Победила команда красных")
		local loop = { key = "teams.loop" }
		loop.params = { x = loop }
		expect(L:T("teams.loop", { x = loop })):toBe("teams.loop")
	end)

	it("falls back to parents and the default language", function()
		local catalog = sample()
		assert(catalog:AddLanguage("pt", { plural = "zero_one" }))
		assert(catalog:Add("pt", "rounds", { start = "Rodada iniciada" }))
		local L = catalog:Translator("pt-BR")
		expect(L:Code()):toBe("pt")
		expect(L:T("rounds.start")):toBe("Rodada iniciada")
		expect(L:T("rounds.win", { team = "A" })):toBe("Team A wins")
		local unknown = catalog:Translator("xx")
		expect(unknown:Code()):toBe("en")
		expect(unknown:T("rounds.start")):toBe("Round started")
		expect(catalog:Translator("pt-br")):toBe(catalog:Translator("pt_BR"))
	end)

	it("returns the key for missing strings and logs it once", function()
		local log = captureLog()
		local L = sample({ log = log }):Translator("ru")
		expect(L:Has("rounds.nope")):toBe(false)
		expect(#log.warnings):toBe(0)
		expect(L:T("rounds.nope")):toBe("rounds.nope")
		expect(L:T("rounds.nope", { count = 2 })):toBe("rounds.nope")
		expect(log.warnings):toEqual({ "missing translation 'rounds.nope' (language 'ru')" })
		expect(L:Has("rounds.start")):toBe(true)
	end)

	it("sees strings added after the first lookup", function()
		local catalog = sample()
		local L = catalog:Translator("ru")
		expect(L:T("late.hello")):toBe("late.hello")
		assert(catalog:Add("ru", "late", { hello = "Привет" }))
		expect(L:T("late.hello")):toBe("Привет")
		assert(catalog:AddLanguage("ru-ua", { plural = "east_slavic", fallback = "ru" }))
		assert(catalog:Add("ru-ua", "late", { hello = "Привіт" }))
		expect(catalog:Translator("ru-UA"):T("late.hello")):toBe("Привіт")
	end)
end)

describe("i18n checks", function()
	it("reports problems against the reference language", function()
		local catalog = sample()
		assert(catalog:Add("ru", "rounds", {
			extra = "Лишний",
			only_en = "не множественное",
			["hud.time"] = "Осталось: {seconds}",
		}))
		assert(catalog:AddLanguage("de", {}))
		assert(catalog:Add("de", "rounds", { players = { one = "{count} Spieler" } }))
		local lines = {}
		for i, problem in ipairs(catalog:Check()) do
			lines[i] = problem.code .. " " .. problem.kind .. " " .. problem.key .. ": " .. problem.message
		end
		expect(lines):toEqual({
			"de missing rounds.hud.time: not translated",
			"de missing rounds.only_en: not translated",
			"de plural rounds.players: missing form 'other' (rule one_other)",
			"de missing rounds.start: not translated",
			"de missing rounds.win: not translated",
			"ru extra rounds.extra: key is not in the reference language",
			"ru placeholder rounds.hud.time: missing {time}",
			"ru placeholder rounds.hud.time: unknown {seconds}",
			"ru plural rounds.only_en: must have plural forms",
		})
		expect(catalog:Check("fr")[1].message):toBe("reference language is not loaded")
	end)
end)
