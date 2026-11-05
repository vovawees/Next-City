-- Next-City platform: permissions (service "permissions", ctx.permissions), both realms.
--
-- A privilege is something only some players may do. A module declares its privileges
-- in the manifest; the id of a privilege is "<module>.<name>" (docs/ARCHITECTURE.md,
-- section 6):
--
--   permissions = {
--       manage = { level = "admin", desc = "Restart rounds and switch modes" },
--   },
--
--   ctx.permissions:Can(ply, "manage")                  -- an own privilege by its name
--   ctx.permissions:Can(ply, "rounds.manage", target)   -- any privilege by its id
--
-- Admin console commands are privileges as well (platform/commands.lua): by default the
-- id is the command name ("nc_round") and the level "superadmin".
--
-- The platform does not decide who has a privilege. Sources answer the bus question
-- "permissions.can" (ply, id, target, privilege) with true or false: an adapter of an
-- admin mod (ULX, SAM... through CAMI) or the server's own admin panel; the first answer
-- wins. Without an answer the level decides: the level of the privilege (config
-- permissions.levels may change it) against the rank of the player, which is
-- permissions.groups[usergroup] or superadmin, admin or user by IsSuperAdmin and
-- IsAdmin. Levels from low to high: user, admin, superadmin, nobody (only the server
-- console and the sources). The server console (ply nil) may do everything. The target
-- (the player an action is aimed at, optional) is for the sources, e.g. immunity.
--
-- A client knows the privileges of its own player: the server sends the list
-- ("nc.grants") when the player becomes ready and later only changes: when privileges
-- come and go, on Refresh and when a slow poll (every player once in
-- permissions.refresh seconds) finds them. Can on a client answers for the local player
-- and serves the UI only; the server always checks on its own.
--
-- Events: permissions.registered (privilege), permissions.unregistered (privilege),
-- permissions.changed (ply, ids): the privileges of a player became known or changed
-- (server: after a check, client: when the list arrives).

local Service = {}
Service.__index = Service

local Facade = {}
Facade.__index = Facade

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable
local pcall = pcall
local format = string.format
local concat = table.concat
local ceil = math.ceil
local min = math.min

local MESSAGE = "nc.grants"
local QUESTION = "permissions.can"
local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_NAME = 32
local MAX_ID = 64
local MAX_GRANTS = 512
local MAX_WARNED = 64
local SPEC_KEYS = { level = true, desc = true }
local RANKS = { user = 1, admin = 2, superadmin = 3, nobody = 4 }
local PLAYER_LEVELS = { user = true, admin = true, superadmin = true }
local DEFAULT_LEVEL = "superadmin"
local DEFAULT_REFRESH = 10
local POLL_INTERVAL = 1
-- Before the modules: what they send on net.ready may rely on the privileges.
local READY_PRIORITY = 100
local EMPTY = {}

Service.LEVELS = { "user", "admin", "superadmin", "nobody" }

local function sortedKeys(t)
	local keys = {}
	for key in pairs(t) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function isName(value)
	return type(value) == "string" and #value <= MAX_NAME and value:find(NAME_PATTERN) ~= nil
end

local function isLevel(value)
	return type(value) == "string" and RANKS[value] ~= nil
end

local function checkFields(level, desc)
	if level ~= nil and not isLevel(level) then
		return false, "level must be \"user\", \"admin\", \"superadmin\" or \"nobody\""
	end
	if desc ~= nil and type(desc) ~= "string" then
		return false, "desc must be a string"
	end
	return true
end

-- The spec of a privilege in a manifest: { level, desc }.
local function validateSpec(spec)
	if type(spec) ~= "table" then
		return false, "must be a table { level = ..., desc = ... }"
	end
	for key in pairs(spec) do
		if not SPEC_KEYS[key] then
			return false, format("unknown key '%s'", tostring(key))
		end
	end
	return checkFields(spec.level, spec.desc)
end

local function copyOf(privilege)
	return {
		id = privilege.id,
		module = privilege.module,
		name = privilege.name,
		level = privilege.level,
		declared = privilege.declared,
		desc = privilege.desc,
		command = privilege.command,
	}
end

-- Service -------------------------------------------------------------------------------

-- opts: config (NC.Config.permissions), log, events, scheduler, net (services of the
-- kernel), previous (service of the previous kernel, on autorefresh).
function Service.New(opts)
	local service = setmetatable({
		log = opts.log,
		events = opts.events,
		scheduler = opts.scheduler,
		net = opts.net,
		privileges = {},
		sorted = nil,
		levels = {},
		groups = {},
		refresh = DEFAULT_REFRESH,
		listeners = {},
		warned = {},
		warnedCount = 0,
		-- server: the ids each player had at the last check, joined
		signatures = {},
		cursor = 0,
		dirty = false,
		-- client: the privileges of the local player
		known = false,
		granted = {},
		grantedList = {},
	}, Service)
	service:_Configure(opts.config or EMPTY)
	service.message = service.net:Define(MESSAGE, {
		from = "server",
		desc = "the privileges of the player",
		fields = { { "ids", "array", max = MAX_GRANTS, of = { "string", max = MAX_ID } } },
	})
	if SERVER then
		service:_Listen("net.ready", function(ply)
			service:_Check(ply, true)
		end, { priority = READY_PRIORITY })
		service:_Listen("gm.PlayerDisconnected", function(ply)
			service.signatures[ply] = nil
		end)
		service:_Listen("nc.ready", function()
			service:_CheckConfig()
		end, { once = true })
		service.job = service.scheduler:Every("permissions:poll", POLL_INTERVAL, function()
			service:_Poll()
		end)
	else
		local previous = opts.previous
		if previous ~= nil and previous.known then
			service:_Mirror(previous.grantedList)
		end
		service.net:Handle(service.message, function(data)
			service:_Receive(data.ids)
		end)
	end
	return service
end

function Service:_Listen(event, fn, opts)
	opts = opts or {}
	opts.id = "permissions:" .. event
	self.listeners[#self.listeners + 1] = self.events:On(event, fn, opts)
end

function Service:_Configure(cfg)
	local log = self.log
	if type(cfg.levels) == "table" then
		for id, level in pairs(cfg.levels) do
			if type(id) == "string" and isLevel(level) then
				self.levels[id] = level
			else
				log:Warn("config permissions.levels: %s = %s is ignored, levels are user, admin, superadmin, nobody",
					tostring(id), tostring(level))
			end
		end
	end
	if type(cfg.groups) == "table" then
		for group, level in pairs(cfg.groups) do
			if type(group) == "string" and PLAYER_LEVELS[level] then
				self.groups[group] = level
			else
				log:Warn("config permissions.groups: %s = %s is ignored, ranks are user, admin, superadmin",
					tostring(group), tostring(level))
			end
		end
	end
	local refresh = cfg.refresh
	if refresh ~= nil then
		if type(refresh) == "number" and refresh >= 0 and refresh < math.huge then
			self.refresh = refresh
		else
			log:Warn("config permissions.refresh must be a number of seconds (0 turns the poll off), got %s",
				tostring(refresh))
		end
	end
end

-- Server, once the modules have started: levels of privileges nobody declared.
function Service:_CheckConfig()
	for _, id in ipairs(sortedKeys(self.levels)) do
		if self.privileges[id] == nil then
			self.log:Warn("config permissions.levels: there is no privilege '%s' (nc_privileges lists them)", id)
		end
	end
end

-- Registers a privilege by its full id; spec: module, name, level (default "superadmin"),
-- desc, command. For the platform (commands, dev tools): modules declare privileges in the
-- manifest or use ctx.permissions:Register. Returns the privilege.
function Service:Register(id, spec)
	if type(id) ~= "string" or id == "" or #id > MAX_ID then
		error(format("privilege id must be a string of 1 to %d characters, got %s", MAX_ID, tostring(id)), 2)
	end
	spec = spec or EMPTY
	local taken = self.privileges[id]
	if taken ~= nil then
		error(format("privilege '%s' is declared twice (by '%s' and '%s')", id, tostring(taken.module),
			tostring(spec.module)), 2)
	end
	local ok, err = checkFields(spec.level, spec.desc)
	if not ok then
		error(format("privilege '%s': %s", id, err), 2)
	end
	local declared = spec.level or DEFAULT_LEVEL
	local privilege = {
		id = id,
		module = spec.module,
		name = spec.name or id,
		level = self.levels[id] or declared,
		declared = declared,
		desc = spec.desc,
		command = spec.command,
	}
	self.privileges[id] = privilege
	self.sorted = nil
	self.dirty = true
	self.events:Emit("permissions.registered", copyOf(privilege))
	return privilege
end

-- Removes a privilege; nobody has it any more. Returns whether it existed.
function Service:Unregister(id)
	local privilege = self.privileges[id]
	if privilege == nil then
		return false
	end
	self.privileges[id] = nil
	self.sorted = nil
	self.dirty = true
	self.events:Emit("permissions.unregistered", copyOf(privilege))
	return true
end

-- A privilege by its id: a copy { id, module, name, level (in effect), declared (by the
-- module), desc, command } or nil.
function Service:Get(id)
	local privilege = self.privileges[id]
	return privilege and copyOf(privilege)
end

-- The level of a privilege in effect, or nil.
function Service:Level(id)
	local privilege = self.privileges[id]
	return privilege and privilege.level
end

function Service:_Ids()
	local sorted = self.sorted
	if sorted == nil then
		sorted = sortedKeys(self.privileges)
		self.sorted = sorted
	end
	return sorted
end

-- Every privilege ordered by id (copies, see Get).
function Service:List()
	local out = {}
	for i, id in ipairs(self:_Ids()) do
		out[i] = copyOf(self.privileges[id])
	end
	return out
end

-- Server: the rank of a player when no source answers: "user", "admin" or "superadmin".
function Service:Rank(ply)
	local level = self.groups[ply:GetUserGroup()]
	if level ~= nil then
		return level
	end
	if ply:IsSuperAdmin() then
		return "superadmin"
	end
	if ply:IsAdmin() then
		return "admin"
	end
	return "user"
end

function Service:_Unknown(id)
	local key = tostring(id)
	if self.warned[key] or self.warnedCount >= MAX_WARNED then
		return
	end
	self.warned[key] = true
	self.warnedCount = self.warnedCount + 1
	self.log:Warn("unknown privilege '%s' was checked: nobody has it (declare it in module.lua)", key)
end

-- Whether a player has a privilege (see the header). Server: nil is the server console.
-- Client: nil is the local player; the privileges of other players are not known.
function Service:Can(ply, id, target)
	if CLIENT then
		if ply ~= nil and ply ~= LocalPlayer() then
			return false
		end
		return self.granted[id] == true
	end
	if ply == nil then
		return true
	end
	if not isentity(ply) or not IsValid(ply) or not ply:IsPlayer() then
		return false
	end
	local privilege = self.privileges[id]
	if privilege == nil then
		self:_Unknown(id)
		return false
	end
	local answer = self.events:Query(QUESTION, ply, id, target, privilege)
	if answer ~= nil then
		return answer ~= false
	end
	return RANKS[self:Rank(ply)] >= RANKS[privilege.level]
end

-- The ids of the privileges a player has, sorted. Client: of the local player only.
function Service:Granted(ply)
	local out = {}
	if CLIENT then
		if ply == nil or ply == LocalPlayer() then
			for i, id in ipairs(self.grantedList) do
				out[i] = id
			end
		end
		return out
	end
	for _, id in ipairs(self:_Ids()) do
		if self:Can(ply, id) then
			out[#out + 1] = id
		end
	end
	return out
end

-- Server: checks a player (nil: every ready player) right away, for sources that know
-- of a change (an admin mod moved a player to another group, an admin panel granted
-- something); the client gets the list if it changed.
function Service:Refresh(ply)
	if CLIENT then
		return
	end
	if ply ~= nil then
		self:_Check(ply, false)
		return
	end
	for _, each in ipairs(self.net:ReadyPlayers()) do
		self:_Check(each, false)
	end
end

-- Server: checks the privileges of a player and sends the list when it changed (or
-- with `force`, to a player that has just become ready).
function Service:_Check(ply, force)
	if not IsValid(ply) then
		self.signatures[ply] = nil
		return
	end
	local ids = self:Granted(ply)
	if #ids > MAX_GRANTS then
		if not self.truncated then
			self.truncated = true
			self.log:Warn("%s has %d privileges, clients learn the first %d only", tostring(ply), #ids, MAX_GRANTS)
		end
		for i = #ids, MAX_GRANTS + 1, -1 do
			ids[i] = nil
		end
	end
	local signature = concat(ids, " ")
	local changed = self.signatures[ply] ~= signature
	if changed then
		self.signatures[ply] = signature
	end
	if (changed or force) and self.net:IsReady(ply) then
		self.net:Send(self.message, ply, { ids = ids })
	end
	if changed then
		self.events:Emit("permissions.changed", ply, ids)
	end
end

-- Server, every second: everybody after privileges came or went, else the next players
-- in turn, so that each is checked once in `refresh` seconds.
function Service:_Poll()
	if self.dirty then
		self.dirty = false
		self:Refresh()
		return
	end
	if self.refresh <= 0 then
		return
	end
	local players = self.net:ReadyPlayers()
	local count = #players
	if count == 0 then
		return
	end
	for _ = 1, min(count, ceil(count * POLL_INTERVAL / self.refresh)) do
		self.cursor = self.cursor % count + 1
		self:_Check(players[self.cursor], false)
	end
end

-- Client: takes the list from the server. Returns whether it is new.
function Service:_Mirror(ids)
	local granted, list = {}, {}
	for i, id in ipairs(ids) do
		granted[id] = true
		list[i] = id
	end
	local changed = not self.known or concat(list, " ") ~= concat(self.grantedList, " ")
	self.known = true
	self.granted, self.grantedList = granted, list
	return changed
end

function Service:_Receive(ids)
	if self:_Mirror(ids) then
		self.events:Emit("permissions.changed", LocalPlayer(), self:Granted())
	end
end

-- Client: whether the server has sent the privileges of the local player yet.
function Service:IsKnown()
	return self.known
end

-- Removes the listeners, the poll and the receiver (kernel shutdown or autorefresh);
-- a client keeps its list for the service that takes over.
function Service:Shutdown()
	for _, listener in ipairs(self.listeners) do
		listener:Off()
	end
	self.listeners = {}
	if self.job ~= nil then
		self.scheduler:Remove(self.job)
		self.job = nil
	end
	if CLIENT then
		self.net:Handle(self.message, nil)
	end
end

-- Manifest section ------------------------------------------------------------------------

-- Checks the `permissions` section of a manifest: { [name] = { level, desc } }.
function Service:ValidateManifest(section)
	if type(section) ~= "table" then
		return false, "permissions must be a table of privileges"
	end
	for _, name in ipairs(sortedKeys(section)) do
		if not isName(name) then
			return false, format("privilege name %s must be a snake_case id of at most %d characters", tostring(name),
				MAX_NAME)
		end
		local ok, err = validateSpec(section[name])
		if not ok then
			return false, format("privilege '%s': %s", name, err)
		end
	end
	return true
end

-- ctx.permissions: registers the privileges of the manifest (they go away with the
-- module) and checks own privileges by name and every other one by id.
function Service:ForModule(ctx, section)
	local facade = setmetatable({ _service = self, _module = ctx.id, _names = {} }, Facade)
	local ok, err = pcall(function()
		for _, name in ipairs(sortedKeys(section or EMPTY)) do
			facade:Register(name, section[name])
		end
	end)
	if not ok then
		facade:Dispose()
		error(err, 0)
	end
	return facade
end

-- Module facade -----------------------------------------------------------------------------

-- The id of a privilege: "<module>.<name>" for an own one, else the name as it is.
function Facade:Id(name)
	return self._names[name] or name
end

function Facade:Can(ply, name, target)
	return self._service:Can(ply, self._names[name] or name, target)
end

function Facade:Get(name)
	return self._service:Get(self:Id(name))
end

function Facade:Level(name)
	return self._service:Level(self:Id(name))
end

function Facade:List()
	return self._service:List()
end

function Facade:Granted(ply)
	return self._service:Granted(ply)
end

function Facade:Rank(ply)
	return self._service:Rank(ply)
end

function Facade:Refresh(ply)
	return self._service:Refresh(ply)
end

-- Registers a privilege of the module while it runs (like the manifest: on both realms);
-- it goes away with the module. Returns the id.
function Facade:Register(name, spec)
	local module = self._module
	if not isName(name) then
		error(format("module '%s': privilege name %s must be a snake_case id of at most %d characters", module,
			tostring(name), MAX_NAME), 2)
	end
	spec = spec or EMPTY
	local ok, err = validateSpec(spec)
	if not ok then
		error(format("module '%s': privilege '%s': %s", module, name, err), 2)
	end
	local id = module .. "." .. name
	self._service:Register(id, { module = module, name = name, level = spec.level, desc = spec.desc })
	self._names[name] = id
	return id
end

function Facade:Unregister(name)
	local id = self._names[name]
	if id == nil then
		return false
	end
	self._names[name] = nil
	return self._service:Unregister(id)
end

function Facade:Dispose()
	local names = self._names
	self._names = {}
	for _, name in ipairs(sortedKeys(names)) do
		self._service:Unregister(names[name])
	end
end

return Service
