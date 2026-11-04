-- Packages: modules, languages and config files of addons and of a gamemode that
-- derives from ours, on top of the core, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local CORE = "nextcity/gamemode/"
local ADDONS = "nextcity/"
local DERIVED = "zcity/gamemode/"

-- A module `id` under `base` (a modules/ folder) whose files record their realm and
-- keep the config.
local function probe(base, id, config)
	local dir = base .. id .. "/"
	local record = string.format([[
		local M = NC.Module(%q)
		M.trace = M.trace or {}
		M.trace[#M.trace + 1] = %%q
		function M:Start(ctx) self.config = ctx.config end
	]], id)
	return {
		[dir .. "module.lua"] = string.format("return { id = %q, files = { sh = { 'sh.lua' }, sv = { 'sv.lua' },"
			.. " cl = { 'cl.lua' } }, config = %s }", id, config or "{}"),
		[dir .. "sh.lua"] = record:format("sh"),
		[dir .. "sv.lua"] = record:format("sv"),
		[dir .. "cl.lua"] = record:format("cl"),
	}
end

local function join(...)
	local out = {}
	for _, files in ipairs({ ... }) do
		for path, source in pairs(files) do
			out[path] = source
		end
	end
	return out
end

local function boot(opts)
	local server = Env.Kernel(opts):Boot()
	local client = Env.Client(server):Boot()
	return server, client, server:Get("NC"), client:Get("NC")
end

describe("packages", function()
	it("loads the modules of addons on both realms and tells their package", function()
		local server, client, NC, NCC = boot({ files = probe(ADDONS .. "modules/", "pack_items") })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(NC.Modules:State("pack_items")):toBe("started")
		expect(NCC.Modules:State("pack_items")):toBe("started")
		expect(NC.Modules:Instance("pack_items").trace):toEqual({ "sh", "sv" })
		expect(NCC.Modules:Instance("pack_items").trace):toEqual({ "sh", "cl" })
		expect(server.sent[ADDONS .. "modules/pack_items/sv.lua"]):toBeNil()
		expect(NC.ModulePackages.pack_items):toBe("addons")
		expect(NC.ModulePackages.players):toBe("core") -- registered, though the spec turns it off
		expect(NC.Packages):toEqual({ { name = "core", path = CORE }, { name = "addons", path = ADDONS } })
		server:Command("nc_modules")
		expect(#server:Lines("pack_items")):toBe(1)
		expect(server:Lines("pack_items")[1]):toContain("[addons]")
	end)

	it("loads the modules of a gamemode that derives from ours before the ones of addons", function()
		local server, client, NC, NCC = boot({ gamemode = "zcity",
			files = join(probe(DERIVED .. "modules/", "zc_mode"), probe(ADDONS .. "modules/", "pack_items")) })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(NC.Packages[2]):toEqual({ name = "zcity", path = DERIVED })
		expect(NC.ModulePackages.zc_mode):toBe("zcity")
		expect(NCC.Modules:State("zc_mode")):toBe("started")
		expect(NCC.Modules:Instance("zc_mode").trace):toEqual({ "sh", "cl" })
	end)

	it("keeps the first package of a module id and reports the others", function()
		local core = probe(CORE .. "modules/", "shared_id", "{ from = 'core' }")
		local addon = probe(ADDONS .. "modules/", "shared_id", "{ from = 'addon' }")
		local server, _, NC = boot({ files = join(core, addon) })
		expect(NC.ModulePackages.shared_id):toBe("core")
		expect(NC.Modules:Instance("shared_id").config.from):toBe("core")
		local errors = table.concat(server:Errors(), "\n")
		expect(errors):toContain("module 'shared_id' of package addons ignored: package core already has it")
	end)

	it("applies the config files of packages over the core config, server.lua last", function()
		local files = probe(ADDONS .. "modules/", "pack_items",
			"{ count = 1, names = { 'a', 'b' }, deep = { x = 1, y = 2 } }")
		files[DERIVED .. "config/main.lua"] =
			"return { logLevel = 'debug', modules = { settings = { pack_items = { count = 2 } } } }"
		files[ADDONS .. "config/server.lua"] = "return { modules = { settings = { pack_items = { count = 4 } } } }"
		files[ADDONS .. "config/b_pack.lua"] = [[return { modules = { settings = { pack_items = { count = 3,
			names = { 'c' }, deep = { y = 5 } } } } }]]
		files[ADDONS .. "config/a_broken.lua"] = "error('oops')"
		files[ADDONS .. "config/c_number.lua"] = "return 42"
		local server, client, NC, NCC = boot({ gamemode = "zcity", files = files })
		expect(NC.Config.logLevel):toBe("debug")
		local config = NC.Modules:Instance("pack_items").config
		expect(config.count):toBe(4)
		expect(config.names):toEqual({ "c" })
		-- Module settings replace the defaults of their keys (core/modules.lua).
		expect(config.deep):toEqual({ y = 5 })
		expect(NC.Config.modules.disabled.example):toBe(true) -- the core config stays under them
		expect(NCC.Modules:Instance("pack_items").config.count):toBe(4)
		local errors = table.concat(server:Errors(), "\n")
		expect(errors):toContain("config nextcity/config/a_broken.lua failed")
		expect(errors):toContain("config nextcity/config/c_number.lua must return a table")
		expect(client:Errors()):toEqual(server:Errors())
	end)

	it("translates with the languages of packages and lets them add languages", function()
		local files = probe(ADDONS .. "modules/", "pack_items")
		files[ADDONS .. "lang/en/pack_items.lua"] =
			"return { name = 'Crate', count = { one = '{count} crate', other = '{count} crates' } }"
		files[ADDONS .. "lang/ru/pack_items.lua"] = "return { name = 'Ящик' }"
		files[ADDONS .. "lang/en/common.lua"] = "return { ['pack.extra'] = 'Extra' }"
		files[ADDONS .. "lang/de/_language.lua"] = "return { name = 'Deutsch', english = 'German', fallback = 'en' }"
		files[ADDONS .. "lang/de/pack_items.lua"] = "return { name = 'Kiste' }"
		files[ADDONS .. "lang/ru/_language.lua"] = "return { name = 'Not used' }"
		local server, client = boot({ files = files })
		expect(server:Errors()):toEqual({})
		local i18n = server:Get("NC").I18n
		expect(i18n:T("pack_items.name")):toBe("Crate")
		expect(i18n:T("pack_items.count", { count = 2 })):toBe("2 crates")
		expect(i18n:T("common.pack.extra")):toBe("Extra")
		expect(i18n.catalog:Translator("de"):T("pack_items.name")):toBe("Kiste")
		expect(i18n.catalog:Translator("ru"):T("pack_items.name")):toBe("Ящик")
		-- The metadata of a language comes from the first package that has it.
		local names = {}
		for _, lang in ipairs(i18n.catalog:Languages()) do
			names[lang.code] = lang.name
		end
		expect(names.ru):toBe("Русский")
		expect(names.de):toBe("Deutsch")
		expect(server.sent[ADDONS .. "lang/de/pack_items.lua"]):toBe(true)
		expect(client:Get("NC").I18n:T("pack_items.name")):toBe("Crate")
	end)
end)
