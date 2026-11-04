-- Emulated GMod environment for boot smoke tests.
--
-- Every realm gets its own global table with the parts of the engine API the gamemode
-- uses, and gamemode files run inside it (setfenv), like separate Lua states. LUA paths
-- ("nextcity/gamemode/init.lua") map to repository files under gamemodes/; tests can add
-- virtual files and patch the results of files (e.g. config.lua).
--
-- The client only sees files the server sent with AddCSLuaFile, like a real client.
-- Reads of undefined globals and creation of new globals are recorded, so tests can
-- enforce that NC is the only global of the project.
--
-- Console variables: GetConVar, CreateClientConVar (client), cvars change callbacks and
-- RunConsoleCommand work synchronously; the client has gmod_language (opts.language).
--
-- Network: util.AddNetworkString and the net library over typed wires (tests/support/
-- wire.lua), so a writer and a reader that disagree fail loudly. Env.Connect links a
-- client realm to a server realm as a player; sent messages wait in the inbox of the
-- receiving realm until Pump (or Env.Flush) delivers them, like the next network frame.
--
-- Game world (tests/gmod/world.lua): players with engine methods whose actions run the
-- gamemode hooks, the base gamemode behaviour of player hooks, the player, team, ents
-- and game libraries, traces and the drawing API of clients. Env.Join spawns the player
-- like the engine, Env.Advance runs GM:PlayerDeathThink for dead players every tick.

local Wire = dofile(T.root .. "tests/support/wire.lua")
local World = dofile(T.root .. "tests/gmod/world.lua")

local Env = {}
Env.__index = Env

Env.GAMEMODE = "nextcity"
Env.ENTRY = { server = "nextcity/gamemode/init.lua", client = "nextcity/gamemode/cl_init.lua" }

local REPO_PREFIX = "gamemodes/"
-- Hooks of the base gamemode: every call is recorded in env.baseCalls; World.BASE holds
-- what the base gamemode does in some of them.
local HOOK_NAMES = {
	"Initialize", "Tick", "InitPostEntity", "OnReloaded", "ShutDown", "PlayerInitialSpawn", "PlayerDisconnected",
	"EntityRemoved", "KeyPress", "PlayerSpawn", "PlayerSelectSpawn", "PlayerLoadout", "PlayerSetModel",
	"DoPlayerDeath", "PlayerDeath", "PlayerSilentDeath", "PlayerDeathThink", "PlayerShouldTakeDamage",
	"CanPlayerSuicide", "PlayerRequestTeam", "PostCleanupMap", "HUDPaint", "StartCommand", "OnPlayerHitGround",
	"EntityTakeDamage", "GetFallDamage", "HUDShouldDraw", "RenderScreenspaceEffects", "PlayerBindPress",
}

Env.World = World
Env.FakePlayer = World.FakePlayer

local function pack(...)
	return { n = select("#", ...), ... }
end

-- Lists repository files under gamemodes/ as LUA paths (cached).
local repoFiles
function Env.RepoFiles()
	if repoFiles then
		return repoFiles
	end
	local base = (T.root ~= "" and T.root or "./") .. REPO_PREFIX
	local windows = package.config:sub(1, 1) == "\\"
	local command
	if windows then
		command = "dir /s /b /a-d \"" .. base:gsub("/", "\\") .. "\""
	else
		command = "find \"" .. base .. "\" -type f"
	end
	local pipe = assert(io.popen(command), "cannot list repository files")
	repoFiles = {}
	for line in pipe:lines() do
		line = line:gsub("\\", "/")
		local at = line:find(REPO_PREFIX .. Env.GAMEMODE .. "/", 1, true)
		if at then
			repoFiles[line:sub(at + #REPO_PREFIX)] = true
		end
	end
	pipe:close()
	assert(repoFiles[Env.ENTRY.server], "repository scan found no gamemode files")
	return repoFiles
end

local function copyTable(source)
	local out = {}
	for key, value in pairs(source) do
		out[key] = value
	end
	return out
end

local function globMatcher(mask)
	local escaped = mask:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
	local pattern = escaped:gsub("%*", ".*")
	return "^" .. pattern .. "$"
end

Env.CONFIG = Env.GAMEMODE .. "/gamemode/config.lua"

-- Wraps a config patch so that every repository module except `ids` is turned off
-- (virtual modules of a test stay on, modules in `ids` are turned on).
local function onlyModules(patch, ids)
	local keep = {}
	for _, id in ipairs(ids) do
		keep[id] = true
	end
	return function(...)
		local cfg = ...
		if patch ~= nil then
			cfg = patch(...)
		end
		for _, id in ipairs(Env.RepoModules()) do
			cfg.modules.disabled[id] = not keep[id] or nil
		end
		return cfg
	end
end

-- Creates a realm. opts: files ({ [luaPath] = source }), patch ({ [luaPath] = fn(...) }),
-- modules (ids of the only repository modules to keep on; nil keeps the config as it is),
-- visible (set of LUA paths; client realms see only these), language (gmod_language of
-- a client, "en"), convars ({ [name] = value }: saved values of archived convars),
-- pool (network strings, shared by a server and its clients).
function Env.New(realm, opts)
	opts = opts or {}
	local instance = setmetatable({
		realm = realm,
		time = 1,
		console = {},
		errors = {},
		loaded = {},
		sent = {},
		stack = {},
		commands = {},
		convars = {},
		saved = opts.convars or {},
		changeCallbacks = {},
		pool = opts.pool or { ids = {}, names = {} },
		receivers = {},
		inbox = {},
		netLog = {},
		unhandled = {},
		entities = {},
		links = {},
		baseCalls = {},
		undefinedReads = {},
		newGlobals = {},
		sources = opts.sources or {},
		patch = opts.patch or {},
		partial = "",
	}, Env)

	if opts.modules ~= nil then
		instance.patch = copyTable(instance.patch)
		instance.patch[Env.CONFIG] = onlyModules(instance.patch[Env.CONFIG], opts.modules)
	end

	if realm == "server" then
		instance.files = copyTable(Env.RepoFiles())
		for path, source in pairs(opts.files or {}) do
			instance.files[path] = true
			instance.sources[path] = source
		end
	else
		instance.files = copyTable(opts.visible or {})
	end

	instance.G = instance:_CreateGlobals()
	if realm == "client" then
		instance:_CreateConVar("gmod_language", opts.language or "en", "The game language")
	end
	return instance
end

-- Creates a server realm (does not run anything yet).
function Env.Server(opts)
	return Env.New("server", opts)
end

-- Ids of the modules in the repository (folders with a module.lua), sorted.
function Env.RepoModules()
	local ids = {}
	local pattern = "^" .. Env.GAMEMODE .. "/gamemode/modules/([^/]+)/module%.lua$"
	for path in pairs(Env.RepoFiles()) do
		local id = path:match(pattern)
		if id then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

-- A server realm with only the kernel and the repository modules in opts.modules
-- (default none), for specs about the platform; other options as in Env.New.
function Env.Kernel(opts)
	opts = opts or {}
	opts.modules = opts.modules or {}
	return Env.Server(opts)
end

-- Creates a client realm that sees only what `server` has sent so far.
function Env.Client(server, opts)
	opts = opts or {}
	opts.visible = server.sent
	opts.sources = server.sources
	opts.patch = opts.patch or server.patch
	opts.pool = server.pool
	return Env.New("client", opts)
end

function Env:_Print(text)
	self.partial = self.partial .. text
	while true do
		local line, rest = self.partial:match("^(.-)\n(.*)$")
		if not line then
			break
		end
		self.console[#self.console + 1] = line
		self.partial = rest
	end
end

function Env:_Error(message)
	self.errors[#self.errors + 1] = message
	self:_Print("[ERROR] " .. message .. "\n")
end

function Env:_Resolve(path)
	local current = self.stack[#self.stack]
	if current then
		local relative = (current:match("^(.*/)") or "") .. path
		if self.files[relative] then
			return relative
		end
	end
	if self.files[path] then
		return path
	end
	return nil
end

-- Runs a LUA path like the engine does: compile errors are reported and skipped,
-- runtime errors propagate to the caller (as through include in GMod).
function Env:Run(path)
	if not self.files[path] then
		self:_Error("Couldn't include file '" .. path .. "' (File not found)")
		return
	end
	local fn, err
	if self.sources[path] then
		fn, err = loadstring(self.sources[path], "@" .. path)
	else
		fn, err = loadfile(T.root .. REPO_PREFIX .. path)
	end
	if not fn then
		self:_Error(tostring(err))
		return
	end
	setfenv(fn, self.G)
	self.loaded[#self.loaded + 1] = path
	self.stack[#self.stack + 1] = path
	local results = pack(pcall(fn))
	self.stack[#self.stack] = nil
	if not results[1] then
		error(results[2], 0)
	end
	if self.patch[path] then
		results = pack(true, self.patch[path](unpack(results, 2, results.n)))
	end
	return unpack(results, 2, results.n)
end

-- Console variables ------------------------------------------------------------------

local ConVar = {}
ConVar.__index = ConVar

function ConVar:GetName() return self.name end
function ConVar:GetDefault() return self.default end
function ConVar:GetHelpText() return self.help end
function ConVar:GetString() return self.value end
function ConVar:GetFloat() return tonumber(self.value) or 0 end
function ConVar:GetInt() return math.floor(tonumber(self.value) or 0) end
function ConVar:GetBool() return self:GetFloat() ~= 0 end
function ConVar:SetString(value) self.env:SetConVar(self.name, value) end

function Env:_CreateConVar(name, default, help)
	local convar = self.convars[name]
	if convar == nil then
		local value = self.saved[name]
		if value == nil then
			value = default
		end
		convar = setmetatable({ env = self, name = name, default = tostring(default), help = help,
			value = tostring(value) }, ConVar)
		self.convars[name] = convar
	end
	return convar
end

-- Sets a console variable like the console does and runs its change callbacks.
function Env:SetConVar(name, value)
	local convar = assert(self.convars[name], "unknown console variable " .. name)
	value = tostring(value)
	local old = convar.value
	if old == value then
		return
	end
	convar.value = value
	local list = {}
	for i, entry in ipairs(self.changeCallbacks[name] or {}) do
		list[i] = entry
	end
	for _, entry in ipairs(list) do
		entry.fn(name, old, value)
	end
end

-- Number of change callbacks registered for a console variable.
function Env:ChangeCallbacks(name)
	return #(self.changeCallbacks[name] or {})
end

function Env:_CreateGlobals()
	local env = self
	local G = {
		assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs, pcall = pcall,
		xpcall = xpcall, rawequal = rawequal, rawget = rawget, rawset = rawset, select = select,
		setmetatable = setmetatable, getmetatable = getmetatable, tonumber = tonumber, tostring = tostring,
		type = type, unpack = unpack, setfenv = setfenv, getfenv = getfenv, collectgarbage = collectgarbage,
		string = copyTable(string), table = copyTable(table), math = copyTable(math), debug = debug,
		coroutine = coroutine, bit = bit, jit = jit,
		os = { time = os.time, date = os.date, clock = os.clock, difftime = os.difftime },
	}

	G.SERVER = self.realm == "server"
	G.CLIENT = self.realm == "client"
	G.HUD_PRINTCONSOLE = 2

	local baseClass = {}
	for _, name in ipairs(HOOK_NAMES) do
		local behaviour = World.BASE[name]
		baseClass[name] = function(gm, ...)
			env.baseCalls[#env.baseCalls + 1] = name
			if behaviour then
				return behaviour(env, gm, ...)
			end
		end
	end
	self.baseClass = baseClass
	G.GM = { FolderName = Env.GAMEMODE, Folder = "gamemodes/" .. Env.GAMEMODE }

	function G.print(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring(select(i, ...))
		end
		env:_Print(table.concat(parts, "\t") .. "\n")
	end

	function G.Msg(...)
		local parts = {}
		for i = 1, select("#", ...) do
			parts[i] = tostring(select(i, ...))
		end
		env:_Print(table.concat(parts))
	end

	function G.MsgN(...)
		G.Msg(...)
		env:_Print("\n")
	end

	function G.MsgC(...)
		for i = 1, select("#", ...) do
			local value = select(i, ...)
			if type(value) ~= "table" then
				env:_Print(tostring(value))
			end
		end
	end

	function G.Color(r, g, b, a)
		return { r = r, g = g, b = b, a = a or 255 }
	end

	function G.CurTime()
		return env.time
	end

	-- Real time follows game time, so rate limits refill on Advance.
	function G.SysTime()
		return env.time
	end

	function G.IsValid(value)
		if value == nil or value == false then
			return false
		end
		if type(value) == "table" and type(value.IsValid) == "function" then
			return value:IsValid() == true
		end
		return true
	end

	function G.include(path)
		local resolved = env:_Resolve(path)
		if resolved == nil then
			env:_Error("Couldn't include file '" .. tostring(path) .. "' (File not found)")
			return
		end
		return env:Run(resolved)
	end

	if self.realm == "server" then
		function G.AddCSLuaFile(path)
			local resolved = path == nil and env.stack[#env.stack] or env:_Resolve(path)
			if resolved == nil then
				env:_Error("Couldn't AddCSLuaFile file '" .. tostring(path) .. "' (File not found)")
				return
			end
			env.sent[resolved] = true
		end
	end

	G.file = {}

	function G.file.Find(pattern, pathId)
		assert(pathId == "LUA", "emulated file.Find supports only the LUA path")
		local dir, mask = pattern:match("^(.*/)([^/]*)$")
		if dir == nil then
			dir, mask = "", pattern
		end
		local matcher = globMatcher(mask)
		local files, folders, seen = {}, {}, {}
		local function add(name, slash)
			if name == nil or not name:find(matcher) or seen[name] then
				return
			end
			seen[name] = true
			local list = slash == "/" and folders or files
			list[#list + 1] = name
		end
		for path in pairs(env.files) do
			if path:sub(1, #dir) == dir then
				add(path:sub(#dir + 1):match("^([^/]+)(/?)"))
			end
		end
		-- Reverse order on purpose: callers must not rely on the engine's order.
		table.sort(files, function(a, b) return a > b end)
		table.sort(folders, function(a, b) return a > b end)
		return files, folders
	end

	function G.file.Exists(path, pathId)
		assert(pathId == "LUA", "emulated file.Exists supports only the LUA path")
		if env.files[path] then
			return true
		end
		local prefix = path .. "/"
		for known in pairs(env.files) do
			if known:sub(1, #prefix) == prefix then
				return true
			end
		end
		return false
	end

	G.concommand = {}

	function G.concommand.Add(name, fn)
		env.commands[name] = fn
	end

	function G.concommand.Remove(name)
		env.commands[name] = nil
	end

	function G.GetConVar(name)
		return env.convars[name]
	end

	if self.realm == "client" then
		function G.CreateClientConVar(name, default, _, _, help)
			return env:_CreateConVar(name, default, help)
		end
	end

	G.cvars = {}

	-- Callbacks with the same identifier replace each other, like in GMod.
	function G.cvars.AddChangeCallback(name, fn, identifier)
		local list = env.changeCallbacks[name] or {}
		env.changeCallbacks[name] = list
		if identifier ~= nil then
			for _, entry in ipairs(list) do
				if entry.id == identifier then
					entry.fn = fn
					return
				end
			end
		end
		list[#list + 1] = { id = identifier, fn = fn }
	end

	function G.cvars.RemoveChangeCallback(name, identifier)
		local list = env.changeCallbacks[name] or {}
		for i = #list, 1, -1 do
			if list[i].id == identifier then
				table.remove(list, i)
			end
		end
	end

	function G.RunConsoleCommand(name, ...)
		local value = ...
		if env.convars[name] then
			env:SetConVar(name, value)
		elseif env.commands[name] then
			env:Command(name, nil, { ... })
		else
			env:_Print("Unknown command: " .. tostring(name) .. "\n")
		end
	end

	self:_CreateEngineTypes(G)
	self:_CreateNet(G)
	World.Install(self, G)
	self:_CreateGame(G)

	return setmetatable(G, {
		__index = function(_, key)
			env.undefinedReads[key] = true
			return nil
		end,
		__newindex = function(t, key, value)
			env.newGlobals[key] = true
			rawset(t, key, value)
		end,
	})
end

-- Engine types -----------------------------------------------------------------------

local VectorMeta = World.VectorMeta
local AngleMeta = World.AngleMeta

function Env:_CreateEngineTypes(G)
	local env = self
	G.NULL = World.NULL

	function G.Entity(index)
		return env.entities[index] or G.NULL
	end

	function G.isentity(value)
		return type(value) == "table" and value.__entity == true
	end

	function G.istable(value)
		return type(value) == "table"
	end

	-- Vector(v) and Angle(a) copy, like in GMod.
	G.Vector = World.Vector
	G.Angle = World.Angle

	function G.isvector(value)
		return getmetatable(value) == VectorMeta
	end

	function G.isangle(value)
		return getmetatable(value) == AngleMeta
	end

	G.vector_origin = G.Vector(0, 0, 0)
	G.vector_up = G.Vector(0, 0, 1)
	G.angle_zero = G.Angle(0, 0, 0)

	if self.realm == "client" then
		function G.LocalPlayer()
			return env.localPlayer or G.NULL
		end
	end
end

-- Network ----------------------------------------------------------------------------

local WRITERS = {
	"WriteBool", "WriteUInt", "WriteInt", "WriteFloat", "WriteDouble", "WriteString", "WriteEntity", "WritePlayer",
	"WriteVector", "WriteAngle", "WriteNormal", "WriteColor",
}
local READERS = {
	"ReadBool", "ReadUInt", "ReadInt", "ReadFloat", "ReadDouble", "ReadString", "ReadEntity", "ReadPlayer",
	"ReadVector", "ReadAngle", "ReadNormal", "ReadColor",
}

local function isPlayerValue(value)
	return type(value) == "table" and value.__entity == true
end

function Env:_Deliver(target, message, sender)
	target.inbox[#target.inbox + 1] = { name = message.name, wire = message.wire:Copy(), bits = message.wire.bits,
		sender = sender }
end

function Env:_SendTo(message, players)
	for _, ply in ipairs(players) do
		local client = self.links[ply]
		self.netLog[#self.netLog + 1] = { name = message.name, to = ply, bits = message.wire.bits }
		if client then
			self:_Deliver(client, message)
		end
	end
end

function Env:_LinkedPlayers(except)
	local skip = {}
	if isPlayerValue(except) then
		skip[except] = true
	elseif type(except) == "table" then
		for _, ply in ipairs(except) do
			skip[ply] = true
		end
	end
	local out = {}
	for ply in pairs(self.links) do
		if not skip[ply] then
			out[#out + 1] = ply
		end
	end
	table.sort(out, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return out
end

function Env:_CreateNet(G)
	local env = self
	local pool = self.pool
	G.util = {}

	if self.realm == "server" then
		function G.util.AddNetworkString(name)
			assert(type(name) == "string", "util.AddNetworkString expects a string")
			local id = pool.ids[name]
			if id == nil then
				id = #pool.names + 1
				pool.names[id] = name
				pool.ids[name] = id
			end
			return id
		end
	end

	function G.util.NetworkStringToID(name)
		return pool.ids[name] or 0
	end

	function G.util.NetworkIDToString(id)
		return pool.names[id]
	end

	local net = { Receivers = self.receivers }
	G.net = net

	local function writing()
		local message = env.writing
		if message == nil then
			error("net: writing without net.Start", 3)
		end
		return message.wire
	end

	local function finish()
		local message = env.writing
		if message == nil then
			error("net: sending without net.Start", 3)
		end
		env.writing = nil
		return message
	end

	function net.Start(name, unreliable)
		if pool.ids[name] == nil then
			error("Calling net.Start with unpooled message name! [" .. tostring(name) .. "]", 2)
		end
		env.writing = { name = name, wire = Wire.New(), unreliable = unreliable == true }
	end

	for _, fn in ipairs(WRITERS) do
		net[fn] = function(...)
			return writing()[fn](...)
		end
	end

	for _, fn in ipairs(READERS) do
		net[fn] = function(...)
			local wire = env.reading
			if wire == nil then
				error("net: " .. fn .. " outside a message receiver", 2)
			end
			return wire[fn](...)
		end
	end

	function net.BytesWritten()
		local message = env.writing
		if message == nil then
			return nil
		end
		local bits = message.wire.bits + 16
		return math.ceil(bits / 8), bits
	end

	function net.Receive(name, fn)
		env.receivers[name:lower()] = fn
	end

	if self.realm == "server" then
		function net.Send(target)
			local message = finish()
			if isPlayerValue(target) then
				target = { target }
			end
			assert(type(target) == "table", "net.Send expects a player or a table of players")
			env:_SendTo(message, target)
		end

		function net.Broadcast()
			env:_SendTo(finish(), env:_LinkedPlayers())
		end

		function net.SendOmit(except)
			env:_SendTo(finish(), env:_LinkedPlayers(except))
		end

		-- No visibility emulation: everybody is in the PVS and PAS.
		function net.SendPVS()
			env:_SendTo(finish(), env:_LinkedPlayers())
		end

		function net.SendPAS()
			env:_SendTo(finish(), env:_LinkedPlayers())
		end
	else
		function net.SendToServer()
			local message = finish()
			env.netLog[#env.netLog + 1] = { name = message.name, to = "server", bits = message.wire.bits }
			if env.peer then
				env:_Deliver(env.peer, message, env.localPlayer)
			end
		end
	end
end

-- Delivers the messages waiting for this realm, in order. Returns how many arrived.
function Env:Pump()
	local delivered = 0
	while self.inbox[1] ~= nil do
		local message = table.remove(self.inbox, 1)
		delivered = delivered + 1
		local fn = self.receivers[message.name:lower()]
		if fn == nil then
			self.unhandled[#self.unhandled + 1] = message.name
		else
			self.reading = message.wire
			local ok, err = pcall(fn, message.bits, message.sender)
			self.reading = nil
			if not ok then
				self:_Error("net receiver " .. message.name .. ": " .. tostring(err))
			end
		end
	end
	return delivered
end

-- Pumps the realms until no message is in flight.
function Env.Flush(...)
	for _ = 1, 100 do
		local delivered = 0
		for i = 1, select("#", ...) do
			delivered = delivered + select(i, ...):Pump()
		end
		if delivered == 0 then
			return
		end
	end
	error("Env.Flush: messages are still flowing after 100 rounds")
end

-- Queues a raw message for this realm from `ply` (nil on a client): fill(wire) writes
-- the payload, so tests can send what a cheater or a broken server would.
function Env:Inject(name, ply, fill)
	local wire = Wire.New()
	if fill then
		fill(wire)
	end
	self.inbox[#self.inbox + 1] = { name = name, wire = wire, bits = wire.bits, sender = ply }
end

-- Messages this realm sent: { name, to (player or "server"), bits } in order.
function Env:Sent(name)
	local out = {}
	for _, entry in ipairs(self.netLog) do
		if name == nil or entry.name == name then
			out[#out + 1] = entry
		end
	end
	return out
end

-- Links `client` to `server` as player `ply`; the client knows every server entity.
function Env.Connect(server, client, ply)
	server.links[ply] = client
	server.entities[ply:EntIndex()] = ply
	client.peer = server
	client.localPlayer = ply
	for index, ent in pairs(server.entities) do
		client.entities[index] = ent
	end
end

-- A player joins: PlayerInitialSpawn and the first spawn on the server, a client booted
-- from the sent files and linked to it, InitPostEntity on the client, then the messages
-- are flushed. opts: name, superadmin, index, language, convars, patch.
-- Returns the client realm and the player.
function Env.Join(server, opts)
	opts = opts or {}
	local ply = Env.FakePlayer({ name = opts.name, superadmin = opts.superadmin, index = opts.index, server = server })
	server.entities[ply:EntIndex()] = ply
	for _, other in pairs(server.links) do
		other.entities[ply:EntIndex()] = ply
	end
	server:Call("PlayerInitialSpawn", ply, false)
	ply:Spawn()
	local client = Env.Client(server, { language = opts.language, convars = opts.convars, patch = opts.patch })
	client:Boot()
	Env.Connect(server, client, ply)
	client:Call("InitPostEntity")
	Env.Flush(server, client)
	return client, ply
end

-- A player leaves: PlayerDisconnected runs, the link is cut and the player entity is
-- removed (EntityRemoved on the server and the other clients).
function Env.Leave(server, ply)
	server:Call("PlayerDisconnected", ply)
	local client = server.links[ply]
	server.links[ply] = nil
	if client then
		client.peer = nil
	end
	Env.Remove(server, ply)
end

-- A bot joins: PlayerInitialSpawn and the first spawn, no client. opts: name, index.
function Env.Bot(server, opts)
	opts = opts or {}
	local ply = Env.FakePlayer({ name = opts.name or "Bot", index = opts.index, bot = true, server = server })
	server.entities[ply:EntIndex()] = ply
	for _, client in pairs(server.links) do
		client.entities[ply:EntIndex()] = ply
	end
	server:Call("PlayerInitialSpawn", ply, false)
	ply:Spawn()
	return ply
end

-- `victim` is killed by `attacker` (default: itself) with `inflictor` (default: attacker).
function Env.Kill(victim, attacker, inflictor)
	World.Die(victim, attacker, inflictor)
end

-- `ply` presses `key` (IN_* value): GM:KeyPress on the server.
function Env.Press(server, ply, key)
	server:Call("KeyPress", ply, key)
end

-- Damage --------------------------------------------------------------------------------

-- `victim` takes damage like from the engine: a damage info from opts, then
-- ply:TakeDamageInfo (GM:EntityTakeDamage, GM:PlayerShouldTakeDamage, the health).
-- opts: damage (default 10), type (DMG_*, default generic), attacker, inflictor (default
-- the attacker), pos, force (Vectors), ammo (an ammo name), hitgroup (HITGROUP_*).
-- Returns the damage info.
function Env.Hurt(victim, opts)
	opts = opts or {}
	local dmginfo = World.DamageInfo()
	dmginfo:SetDamage(opts.damage or 10)
	dmginfo:SetDamageType(opts.type or 0)
	dmginfo:SetAttacker(opts.attacker or World.WORLD)
	dmginfo:SetInflictor(opts.inflictor or opts.attacker or World.WORLD)
	if opts.pos ~= nil then
		dmginfo:SetDamagePosition(opts.pos)
		dmginfo:SetReportedPosition(opts.pos)
	end
	if opts.force ~= nil then
		dmginfo:SetDamageForce(opts.force)
	end
	if opts.ammo ~= nil then
		dmginfo:SetAmmoType(Env.AmmoID(opts.ammo))
	end
	if opts.hitgroup ~= nil then
		victim.lastHitGroup = opts.hitgroup
	end
	victim:TakeDamageInfo(dmginfo)
	return dmginfo
end

-- Id of an ammo type of Half-Life 2 (-1 if unknown), like game.GetAmmoID.
function Env.AmmoID(name)
	for id, ammo in ipairs(World.AMMO) do
		if ammo == name then
			return id
		end
	end
	return -1
end

local BONE_HITGROUPS = {
	Head1 = World.HITGROUP.HEAD, Neck1 = World.HITGROUP.HEAD, Spine2 = World.HITGROUP.CHEST,
	Spine4 = World.HITGROUP.CHEST, Spine = World.HITGROUP.STOMACH, Spine1 = World.HITGROUP.STOMACH,
	Pelvis = World.HITGROUP.STOMACH,
}

-- Hitgroup of a ValveBiped bone, like the hitboxes of a player model.
function Env.BoneHitGroup(bone)
	local short = bone:match("Bip01_(.+)$") or bone
	if BONE_HITGROUPS[short] then
		return BONE_HITGROUPS[short]
	end
	local side, part = short:match("^([LR])_(.+)$")
	if side == nil then
		return World.HITGROUP.GENERIC
	end
	local arm = part == "Clavicle" or part == "UpperArm" or part == "Forearm" or part == "Hand"
	if side == "L" then
		return arm and World.HITGROUP.LEFTARM or World.HITGROUP.LEFTLEG
	end
	return arm and World.HITGROUP.RIGHTARM or World.HITGROUP.RIGHTLEG
end

-- `shooter` (a player, or nil with opts.from) shoots `victim` at a bone like a bullet of
-- the engine: GM:ScalePlayerDamage with the hitgroup of the bone, then the bullet damage
-- at the point opts.depth units (default 8) before the aim point, with a force along the
-- shot. opts: bone ("Spine2"; short or full ValveBiped name), offset (Vector added to the
-- aim point), from (Vector, default the shooter's eyes), damage (default 12), ammo
-- (default "Pistol"), type (default DMG_BULLET), force (default 1000 along the shot),
-- pellets (a list of { bone, offset, depth, hitgroup }: a shell of shot; like the
-- engine's multi-damage, every pellet gets its GM:ScalePlayerDamage and the pellets that
-- were not blocked then hurt once with their damage added up).
-- Returns the damage info of the damage.
local function pelletInfo(shooter, victim, opts, pellet)
	local bone = pellet.bone or opts.bone or "Spine2"
	if not bone:find("ValveBiped", 1, true) then
		bone = "ValveBiped.Bip01_" .. bone
	end
	local aim = victim:GetBonePosition(victim:LookupBone(bone) or World.BONE_IDS[bone])
	local offset = pellet.offset or opts.offset
	if offset ~= nil then
		aim = aim + offset
	end
	local from = opts.from or shooter:EyePos()
	local dir = (aim - from):GetNormalized()
	local pos = aim - dir * (pellet.depth or opts.depth or 8)
	local hitgroup = pellet.hitgroup or opts.hitgroup or Env.BoneHitGroup(bone)
	local dmginfo = World.DamageInfo()
	dmginfo:SetDamage(opts.damage or 12)
	dmginfo:SetDamageType(opts.type or World.DMG.BULLET)
	dmginfo:SetAttacker(shooter or World.WORLD)
	dmginfo:SetInflictor(shooter or World.WORLD)
	dmginfo:SetDamagePosition(pos)
	dmginfo:SetReportedPosition(from)
	dmginfo:SetDamageForce(dir * (opts.force or 1000))
	dmginfo:SetAmmoType(Env.AmmoID(opts.ammo or "Pistol"))
	return dmginfo, hitgroup
end

function Env.Shoot(shooter, victim, opts)
	opts = opts or {}
	local server = victim.server
	local total
	for _, pellet in ipairs(opts.pellets or { {} }) do
		local dmginfo, hitgroup = pelletInfo(shooter, victim, opts, pellet)
		victim.lastHitGroup = hitgroup
		if server == nil or server:Call("ScalePlayerDamage", victim, hitgroup, dmginfo) ~= true then
			if total == nil then
				total = dmginfo
			else
				total:AddDamage(dmginfo:GetDamage())
				total:SetDamagePosition(dmginfo:GetDamagePosition())
				total:SetDamageForce(total:GetDamageForce() + dmginfo:GetDamageForce())
			end
		end
	end
	if total ~= nil then
		victim:TakeDamageInfo(total)
	end
	return total
end

-- `ply` lands at `speed` units/s: GM:OnPlayerHitGround; unless it answers true and if
-- the speed is above the engine's safe speed, GM:GetFallDamage and the fall damage.
function Env.Fall(ply, speed, inWater)
	local server = ply.server
	if server:Call("OnPlayerHitGround", ply, inWater == true, false, speed) == true or inWater then
		return
	end
	if speed > 526.5 then
		local amount = server:Call("GetFallDamage", ply, speed)
		if type(amount) == "number" and amount > 0 then
			Env.Hurt(ply, { damage = amount, type = World.DMG.FALL })
		end
	end
end

-- A user command of `ply` with buttons (IN_* sum) and movement runs GM:StartCommand on
-- `realm` (the server or the player's client). Returns the command as modules left it.
function Env.RunCommand(realm, ply, buttons, forward, side)
	local cmd = World.UserCmd(buttons, forward, side)
	realm:Call("StartCommand", ply, cmd)
	return cmd
end

local entityIndex = 199
local EntityMethods = {}
local EntityMeta = {
	__index = EntityMethods,
	__tostring = function(ent)
		return string.format("Entity [%d][%s]", ent.index, ent.class)
	end,
}

function EntityMethods:IsValid() return self.valid end
function EntityMethods:IsPlayer() return false end
function EntityMethods:EntIndex() return self.index end
function EntityMethods:GetClass() return self.class end
function EntityMethods:GetPos() return World.Vector(self.pos) end
function EntityMethods:SetPos(pos) self.pos = World.Vector(pos) end
function EntityMethods:GetAngles() return World.Angle(self.ang) end

-- A networked entity (index from 200 up, or opts.index) known to the server and every
-- linked client: IsValid, IsPlayer, EntIndex, GetClass, GetPos, GetAngles.
-- opts: index, class, pos, ang, map (created by the map: game.CleanUpMap recreates it
-- as a new entity instead of removing it).
function Env.Spawn(server, opts)
	opts = opts or {}
	local index = opts.index
	if index == nil then
		repeat
			entityIndex = entityIndex % 8000 + 1
			if entityIndex < 200 then
				entityIndex = 200
			end
		until server.entities[entityIndex] == nil
		index = entityIndex
	end
	local ent = setmetatable({ __entity = true, index = index, class = opts.class or "prop_physics", valid = true,
		pos = World.Vector(opts.pos), ang = World.Angle(opts.ang), map = opts.map == true }, EntityMeta)
	server.entities[index] = ent
	for _, client in pairs(server.links) do
		client.entities[index] = ent
	end
	return ent
end

-- Removes an entity: EntityRemoved on the server, then on every linked client that
-- knows it; then the entity is invalid.
function Env.Remove(server, ent)
	local index = ent:EntIndex()
	server:Call("EntityRemoved", ent, false)
	server.entities[index] = nil
	local clients = {}
	for _, client in pairs(server.links) do
		clients[#clients + 1] = client
	end
	table.sort(clients, function(a, b) return a.localPlayer:EntIndex() < b.localPlayer:EntIndex() end)
	for _, client in ipairs(clients) do
		if client.entities[index] == ent then
			client:Call("EntityRemoved", ent, false)
			client.entities[index] = nil
		end
	end
	ent.valid = false
end

-- Map cleanup (game.CleanUpMap): entities that are neither players nor map entities are
-- removed, map entities are recreated as new entities, then GM:PostCleanupMap runs on
-- the server and, unless dontSendToClients, on every linked client.
function Env:_CleanUpMap(dontSendToClients)
	local list = {}
	for _, ent in pairs(self.entities) do
		if not ent:IsPlayer() then
			list[#list + 1] = ent
		end
	end
	table.sort(list, function(a, b) return a:EntIndex() < b:EntIndex() end)
	for _, ent in ipairs(list) do
		Env.Remove(self, ent)
		if ent.map then
			Env.Spawn(self, { class = ent.class, pos = ent.pos, ang = ent.ang, map = true })
		end
	end
	self.cleanups = (self.cleanups or 0) + 1
	self:Call("PostCleanupMap")
	if not dontSendToClients then
		for _, client in pairs(self.links) do
			client:Call("PostCleanupMap")
		end
	end
end

function Env:_CreateGame(G)
	local env = self
	G.game = {}
	function G.game.GetMap() return env.map or "gm_test" end
	function G.game.SinglePlayer() return false end
	function G.game.MaxPlayers() return 128 end
	function G.game.GetWorld() return World.WORLD end
	function G.game.GetAmmoName(id) return World.AMMO[id] end
	function G.game.GetAmmoID(name) return Env.AmmoID(name) end
	if self.realm == "server" then
		function G.game.CleanUpMap(dontSendToClients)
			env:_CleanUpMap(dontSendToClients)
		end
	end
end

-- Runs the realm's entry file and GM:Initialize, like the engine at startup. The GM
-- table inherits the base gamemode, so hooks the gamemode does not define reach it.
function Env:Boot()
	self:Run(Env.ENTRY[self.realm])
	self.G.GM.BaseClass = self.baseClass
	setmetatable(self.G.GM, { __index = self.baseClass })
	self:Call("Initialize")
	return self
end

-- Calls a GM function like the engine does.
function Env:Call(name, ...)
	local fn = self.G.GM[name]
	assert(fn, "GM:" .. name .. " is not defined")
	return fn(self.G.GM, ...)
end

-- Advances game time and runs GM:Tick; on the server GM:PlayerDeathThink runs for every
-- dead player, like the engine does every tick.
function Env:Advance(seconds)
	self.time = self.time + seconds
	self:Call("Tick")
	if self.realm == "server" then
		for _, ply in ipairs(self.G.player.GetAll()) do
			if not ply:Alive() then
				self:Call("PlayerDeathThink", ply)
			end
		end
	end
end

-- Runs a console command as `ply` (nil for the server console).
function Env:Command(name, ply, args)
	local fn = assert(self.commands[name], "unknown console command " .. name)
	fn(ply, name, args or {}, table.concat(args or {}, " "))
end

function Env:Get(name)
	return rawget(self.G, name)
end

-- Engine errors plus every console line logged at ERROR level.
function Env:Errors()
	local out = {}
	for _, message in ipairs(self.errors) do
		out[#out + 1] = message
	end
	for _, line in ipairs(self.console) do
		if line:find("^%[NC%] ERROR") then
			out[#out + 1] = line
		end
	end
	return out
end

-- Console lines that contain `fragment`.
function Env:Lines(fragment)
	local out = {}
	for _, line in ipairs(self.console) do
		if line:find(fragment, 1, true) then
			out[#out + 1] = line
		end
	end
	return out
end

return Env
