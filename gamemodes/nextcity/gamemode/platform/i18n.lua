-- Next-City platform: translations service (ctx.i18n), runs on both realms.
--
-- Files: lang/<code>/_language.lua (metadata) and lang/<code>/<namespace>.lua (strings)
-- of every package (platform/packages.lua), see docs/ARCHITECTURE.md, section 12: a
-- package translates its own modules and may add languages. The server sends every file
-- to clients and loads every language. A client loads the metadata of all languages but
-- the strings of its fallback chain only, and loads more when the language changes.
--
-- Client language: config i18n.force, else the nc_language convar ("auto" or a code),
-- else the game language (gmod_language). A change applies at once and emits
-- "i18n.changed" (code). The client reports the language as client info "language"
-- (platform/net.lua: it arrives with the hello, before "net.ready"). The server keeps
-- the language of each player and uses it in TFor; until a report arrives (and always
-- with i18n.force) it uses the server language: i18n.force or i18n.default.
--
--   ctx.i18n:T("rounds.win", { team = "red" })   -- client language (server: its own)
--   ctx.i18n:TFor(ply, "rounds.kicked")          -- language of a player (server)
--   ctx.i18n:SetLanguage("ru"), ctx.i18n:Choice() -- client: save the choice ("auto" or nil
--                                                    follows the game), read it back

local I18nLib = NC.Lib.I18n

local Service = {}
Service.__index = Service

local LANG_DIR = "lang/"
local META_FILE = "_language.lua"
local CONVAR = "nc_language"

local function sortedCopy(list)
	local out = {}
	for i, value in ipairs(list or {}) do
		out[i] = value
	end
	table.sort(out)
	return out
end

local function loadFile(path)
	local ok, result = pcall(include, path)
	if not ok then
		return nil, tostring(result)
	end
	if type(result) ~= "table" then
		return nil, "must return a table"
	end
	return result
end

-- opts: dirs (the lang/ folders of the packages, the core first), config (NC.Config.i18n),
-- log, events, net (the network service, optional), previous (service of the previous
-- kernel, on autorefresh).
function Service.New(opts)
	local cfg = opts.config or {}
	local log = opts.log
	local default = I18nLib.Normalize(cfg.default)
	if default == nil then
		if cfg.default ~= nil then
			log:Warn("config i18n.default %s is not a language code, using en", tostring(cfg.default))
		end
		default = "en"
	end
	local force = I18nLib.Normalize(cfg.force)
	if cfg.force ~= nil and force == nil then
		log:Warn("config i18n.force %s is not a language code, ignored", tostring(cfg.force))
	end
	local service = setmetatable({
		dirs = opts.dirs,
		log = log,
		events = opts.events,
		net = opts.net,
		default = default,
		force = force,
		catalog = I18nLib.New({ default = default, log = log }),
		files = {},
		loaded = {},
		players = {},
		listeners = {},
		code = default,
	}, Service)
	service:_Discover()
	if SERVER then
		for _, lang in ipairs(service.catalog:Languages()) do
			service:Load(lang.code)
		end
		service.translator = service.catalog:Translator(force or default)
		service.code = service.translator:Code()
		if opts.previous then
			for ply, code in pairs(opts.previous.players or {}) do
				if IsValid(ply) then
					service.players[ply] = code
				end
			end
		end
		service.listeners[1] = service.events:On("gm.PlayerDisconnected", function(ply)
			service:ForgetPlayer(ply)
		end, { id = "i18n:disconnect" })
		if service.net then
			service.net:OnInfo("language", function(ply, code)
				service:SetPlayerLanguage(ply, code)
			end)
		end
	else
		service.convar = CreateClientConVar(CONVAR, "auto", true, false,
			"Next-City language: auto (the game language) or a code such as en, ru")
		service:_Apply(true)
	end
	if service.catalog:Resolve(default) ~= default then
		log:Warn("default language '%s' has no lang/%s folder", default, default)
	end
	if force and service.catalog:Resolve(force) ~= force then
		log:Warn("forced language '%s' has no lang/%s folder", force, force)
	end
	return service
end

-- Every language folder of every package: the namespaces of a language come from all of
-- them in package order (a later file overrides keys of an earlier one), the metadata
-- from the first package that has it.
function Service:_Discover()
	local codes = {}
	for _, base in ipairs(self.dirs) do
		local _, folders = file.Find(base .. "*", "LUA")
		for _, folder in ipairs(sortedCopy(folders)) do
			local code = I18nLib.Normalize(folder)
			if code ~= folder then
				self.log:Warn("%s%s skipped: the folder name must be a lowercase language code (en, ru, pt-br)",
					self:_Short(base), folder)
			else
				local dir = base .. folder .. "/"
				local entry = self.files[code]
				if entry == nil then
					entry = { namespaces = {} }
					self.files[code] = entry
					codes[#codes + 1] = code
				end
				for _, name in ipairs(sortedCopy(file.Find(dir .. "*.lua", "LUA"))) do
					local path = dir .. name
					if SERVER then
						AddCSLuaFile(path)
					end
					if name == META_FILE then
						entry.meta = entry.meta or path
					else
						entry.namespaces[#entry.namespaces + 1] = { name = name:sub(1, -5), path = path }
					end
				end
			end
		end
	end
	for _, code in ipairs(codes) do
		self:_LoadMeta(code, self.files[code].meta)
	end
end

-- "lang/" for the folder of the core, the full path for the ones of other packages.
function Service:_Short(base)
	return base == self.dirs[1] and LANG_DIR or base
end

function Service:_LoadMeta(code, path)
	local meta, err = {}, nil
	if path ~= nil then
		meta, err = loadFile(path)
	end
	local ok, addErr = self.catalog:AddLanguage(code, meta or {})
	if err ~= nil or not ok then
		self.log:Error("lang/%s/%s: %s", code, META_FILE, err or addErr)
		if meta ~= nil then
			self.catalog:AddLanguage(code, {})
		end
	end
end

-- Includes the strings of a language once. Bad files are logged and skipped.
function Service:Load(code)
	local entry = self.files[code]
	if entry == nil or self.loaded[code] then
		return
	end
	self.loaded[code] = true
	for _, item in ipairs(entry.namespaces) do
		local strings, err = loadFile(item.path)
		if strings ~= nil then
			local ok, addErr = self.catalog:Add(code, item.name, strings)
			err = not ok and addErr or nil
		end
		if err ~= nil then
			self.log:Error("lang/%s/%s.lua: %s", code, item.name, err)
		end
	end
end

-- Client: the language the player asks for (before falling back).
function Service:Requested()
	if self.force then
		return self.force
	end
	local choice = self.convar and self.convar:GetString() or "auto"
	if choice ~= "auto" and choice ~= "" then
		local code = I18nLib.Normalize(choice)
		if code then
			return code
		end
		if self.badChoice ~= choice then
			self.badChoice = choice
			self.log:Warn("%s %q is not a language code, using the game language", CONVAR, choice)
		end
	end
	local game = GetConVar("gmod_language")
	return I18nLib.Normalize(game and game:GetString()) or self.default
end

-- Client: picks the language, loads its chain and emits i18n.changed if it changed.
function Service:_Apply(silent)
	local requested = self:Requested()
	for _, code in ipairs(self.catalog:Chain(requested)) do
		self:Load(code)
	end
	self.translator = self.catalog:Translator(requested)
	if self.net then
		self.net:SetInfo("language", requested)
	end
	local code = self.translator:Code()
	local changed = code ~= self.code
	self.code = code
	if changed and not silent then
		self.log:Info("language: %s", code)
		self.events:Emit("i18n.changed", code)
	end
	return code
end

-- Translates a key in the client language (on the server: the server language).
function Service:T(key, params)
	return self.translator:T(key, params)
end

-- Translates a key in the language of a player (on the client: the client language).
function Service:TFor(ply, key, params)
	local code = self.players[ply]
	if code == nil or self.force or CLIENT then
		return self.translator:T(key, params)
	end
	return self.catalog:Translator(code):T(key, params)
end

function Service:Has(key)
	return self.translator:Has(key)
end

-- The language in use: the client language, or the server language on the server.
function Service:Language()
	return self.code
end

-- Server: the language texts for a player are built in.
function Service:LanguageOf(ply)
	if self.force then
		return self.code
	end
	return self.players[ply] or self.code
end

-- Server: records the language a player reported. Returns the language actually used.
function Service:SetPlayerLanguage(ply, code)
	local resolved = self.catalog:Resolve(I18nLib.Normalize(code) or self.default) or self.default
	if self.players[ply] ~= resolved then
		self.players[ply] = resolved
		self.events:Emit("i18n.playerLanguage", ply, resolved)
	end
	return resolved
end

function Service:ForgetPlayer(ply)
	self.players[ply] = nil
end

-- Unsubscribes from the bus (kernel shutdown or autorefresh); the data stays for the
-- service that takes over.
function Service:Shutdown()
	for _, listener in ipairs(self.listeners) do
		listener:Off()
	end
	self.listeners = {}
end

-- Client: saves the player's choice ("auto" or nil follows the game language) and
-- applies it. Returns the language in use, or nil and a message for a bad code.
function Service:SetLanguage(code)
	local value = "auto"
	if code ~= nil and code ~= "auto" then
		value = I18nLib.Normalize(code)
		if value == nil then
			return nil, string.format("%s is not a language code", tostring(code))
		end
	end
	self.convar:SetString(value)
	return self:_Apply()
end

-- Client: the saved choice of the player, "auto" (the game language) or a code.
function Service:Choice()
	local choice = self.convar and self.convar:GetString() or "auto"
	return I18nLib.Normalize(choice) or "auto"
end

-- The language the server shows to everybody (config i18n.force), or nil.
function Service:Forced()
	return self.force
end

-- Languages with metadata: { code, name, english, plural, fallback, keys, loaded }.
function Service:Languages()
	local out = self.catalog:Languages()
	for _, lang in ipairs(out) do
		lang.loaded = self.loaded[lang.code] == true
	end
	return out
end

-- Problems of the loaded languages against the default one (see I18n Catalog:Check).
function Service:Check()
	local out = {}
	for _, problem in ipairs(self.catalog:Check(self.default)) do
		if self.loaded[problem.code] or problem.code == self.default then
			out[#out + 1] = problem
		end
	end
	return out
end

function Service:Catalog()
	return self.catalog
end

-- The convar callbacks look the service up on every call, so a rebuilt kernel
-- (autorefresh) takes over; the identifier replaces the callback of the previous one.
if CLIENT then
	local function onLanguageConVar()
		if NC.I18n then
			NC.I18n:_Apply()
		end
	end
	cvars.AddChangeCallback(CONVAR, onLanguageConVar, "nc.i18n")
	cvars.AddChangeCallback("gmod_language", onLanguageConVar, "nc.i18n")
end

return Service
