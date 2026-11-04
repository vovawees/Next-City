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

local Wire = dofile(T.root .. "tests/support/wire.lua")

local Env = {}
Env.__index = Env

Env.GAMEMODE = "nextcity"
Env.ENTRY = { server = "nextcity/gamemode/init.lua", client = "nextcity/gamemode/cl_init.lua" }

local REPO_PREFIX = "gamemodes/"
local HOOK_NAMES = {
	"Initialize", "Tick", "InitPostEntity", "OnReloaded", "ShutDown", "PlayerInitialSpawn", "PlayerDisconnected",
}

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

-- Creates a realm. opts: files ({ [luaPath] = source }), patch ({ [luaPath] = fn(...) }),
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
		baseClass[name] = function()
			env.baseCalls[#env.baseCalls + 1] = name
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

local VectorMeta = { __tostring = function(v) return string.format("Vector(%g, %g, %g)", v.x, v.y, v.z) end }
local AngleMeta = { __tostring = function(a) return string.format("Angle(%g, %g, %g)", a.x, a.y, a.z) end }

function Env:_CreateEngineTypes(G)
	local env = self
	G.NULL = setmetatable({
		__entity = true,
		IsValid = function() return false end,
		IsPlayer = function() return false end,
		EntIndex = function() return 0 end,
	}, { __tostring = function() return "[NULL Entity]" end })

	function G.Entity(index)
		return env.entities[index] or G.NULL
	end

	function G.isentity(value)
		return type(value) == "table" and value.__entity == true
	end

	function G.istable(value)
		return type(value) == "table"
	end

	function G.Vector(x, y, z)
		return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VectorMeta)
	end

	function G.Angle(p, y, r)
		return setmetatable({ x = p or 0, y = y or 0, z = r or 0 }, AngleMeta)
	end

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

-- Links `client` to `server` as player `ply`.
function Env.Connect(server, client, ply)
	server.links[ply] = client
	server.entities[ply:EntIndex()] = ply
	client.peer = server
	client.localPlayer = ply
	client.entities[ply:EntIndex()] = ply
end

-- A player joins: PlayerInitialSpawn on the server, a client booted from the sent files
-- and linked to it, InitPostEntity on the client, then the messages are flushed.
-- opts: name, superadmin, language, convars, patch. Returns the client realm and player.
function Env.Join(server, opts)
	opts = opts or {}
	local ply = Env.FakePlayer(opts)
	server.entities[ply:EntIndex()] = ply
	server:Call("PlayerInitialSpawn", ply, false)
	local client = Env.Client(server, { language = opts.language, convars = opts.convars, patch = opts.patch })
	client:Boot()
	Env.Connect(server, client, ply)
	client:Call("InitPostEntity")
	Env.Flush(server, client)
	return client, ply
end

-- A player leaves: PlayerDisconnected runs, then the link is cut and the player is gone.
function Env.Leave(server, ply)
	server:Call("PlayerDisconnected", ply)
	local client = server.links[ply]
	server.links[ply] = nil
	if client then
		client.peer = nil
	end
	server.entities[ply:EntIndex()] = nil
	ply.valid = false
end

-- Runs the realm's entry file and GM:Initialize, like the engine at startup.
function Env:Boot()
	self:Run(Env.ENTRY[self.realm])
	self.G.GM.BaseClass = self.baseClass
	self:Call("Initialize")
	return self
end

-- Calls a GM function like the engine does.
function Env:Call(name, ...)
	local fn = self.G.GM[name]
	assert(fn, "GM:" .. name .. " is not defined")
	return fn(self.G.GM, ...)
end

-- Advances game time and runs GM:Tick.
function Env:Advance(seconds)
	self.time = self.time + seconds
	self:Call("Tick")
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

local playerIndex = 0
local PlayerMeta = {
	__tostring = function(ply)
		return string.format("Player [%d][%s]", ply.index, ply.name)
	end,
}

-- A minimal player: IsValid, IsPlayer, EntIndex (1..128), IsSuperAdmin, Nick, PrintMessage
-- (recorded in .printed) and ChatPrint (recorded in .chat). opts: name, superadmin, index.
function Env.FakePlayer(opts)
	opts = opts or {}
	playerIndex = playerIndex % 128 + 1
	local ply = setmetatable({ __entity = true, index = opts.index or playerIndex, name = opts.name or "Player",
		admin = opts.superadmin == true, valid = true, printed = {}, chat = {} }, PlayerMeta)
	function ply:IsValid() return self.valid end
	function ply:IsPlayer() return true end
	function ply:EntIndex() return self.index end
	function ply:IsSuperAdmin() return self.admin end
	function ply:Nick() return self.name end
	function ply:PrintMessage(_, text) self.printed[#self.printed + 1] = text end
	function ply:ChatPrint(text) self.chat[#self.chat + 1] = text end
	return ply
end

return Env
