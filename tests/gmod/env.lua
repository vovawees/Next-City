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
-- visible (set of LUA paths; client realms see only these).
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

	G.SysTime = os.clock

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

-- A minimal player: IsValid, IsSuperAdmin, Nick and PrintMessage (recorded in .printed).
function Env.FakePlayer(opts)
	opts = opts or {}
	local ply = { name = opts.name or "Player", admin = opts.superadmin == true, printed = {} }
	function ply:IsValid() return true end
	function ply:IsSuperAdmin() return self.admin end
	function ply:Nick() return self.name end
	function ply:PrintMessage(_, text) self.printed[#self.printed + 1] = text end
	return ply
end

return Env
