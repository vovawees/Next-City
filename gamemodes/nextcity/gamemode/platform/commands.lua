-- Next-City platform: console commands of modules (service "commands", ctx.commands).
--
--   ctx.commands:Add("nc_round", {
--   	help = "restart | end | next <mode>",
--   	level = "admin", -- who may run it when no source of permissions answers
--   }, function(ply, args) return { "line", "line" } end) -- or a method name: "OnRoundCommand"
--
-- The handler gets the caller (nil for the server console) and the arguments and returns
-- the reply: a string or an array of lines for the caller's console. Errors are caught,
-- logged and reported to the caller. Commands go away when their module stops.
--
-- On the server a command is an admin command unless the spec says `admin = false`: the
-- caller needs a privilege (platform/permissions.lua). By default the command is a
-- privilege of its own: the id is the command name, the level `level` ("superadmin" if
-- not given). `privilege` names a privilege instead, so several commands share one: an
-- own privilege of the manifest by its name or any privilege by its id. Commands added on
-- the client run locally and are never checked.

local Service = {}
Service.__index = Service

local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local setmetatable = setmetatable
local xpcall = xpcall
local format = string.format
local traceback = debug.traceback

local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local SPEC_KEYS = { help = true, admin = true, privilege = true, level = true }
local LEVELS = { user = true, admin = true, superadmin = true, nobody = true }
local DEFAULT_LEVEL = "superadmin"

local function onHandlerError(err)
	return traceback(tostring(err), 2)
end

local function reply(ply, lines)
	if lines == nil then
		return
	end
	if type(lines) ~= "table" then
		lines = { tostring(lines) }
	end
	for _, line in ipairs(lines) do
		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTCONSOLE, tostring(line))
		else
			print(tostring(line))
		end
	end
end

-- opts: log, permissions (the permission service), previous (the service of the
-- previous kernel; its commands are gone by then).
function Service.New(opts)
	return setmetatable({
		log = opts.log,
		permissions = opts.permissions,
		owners = {}, -- name -> module id
		specs = {},  -- name -> { name, module, help, admin, privilege, owned, handler }
	}, Service)
end

function Service:_Run(entry, ply, args)
	-- The engine passes NULL for the server console.
	local caller = IsValid(ply) and ply or nil
	if SERVER and entry.privilege ~= nil and not self.permissions:Can(caller, entry.privilege) then
		reply(caller, entry.name .. ": no access")
		return
	end
	local ok, result = xpcall(entry.handler, onHandlerError, caller, args)
	if not ok then
		self.log:Error("command '%s' of module '%s' failed: %s", entry.name, entry.module, tostring(result))
		reply(caller, entry.name .. ": failed, see the server log")
		return
	end
	reply(caller, result)
end

-- Checks the permission keys of a spec; returns the privilege id (nil for everybody)
-- and whether the command owns it.
function Service:_Privilege(ctx, name, spec)
	local admin, privilege, level = spec.admin, spec.privilege, spec.level
	if admin ~= nil and type(admin) ~= "boolean" then
		error(format("module '%s': command '%s': admin must be a boolean", ctx.id, name), 4)
	end
	if level ~= nil and not LEVELS[level] then
		error(format("module '%s': command '%s': level must be \"user\", \"admin\", \"superadmin\" or \"nobody\"",
			ctx.id, name), 4)
	end
	if privilege ~= nil and type(privilege) ~= "string" then
		error(format("module '%s': command '%s': privilege must be a string", ctx.id, name), 4)
	end
	if admin == false then
		if privilege ~= nil or level ~= nil then
			error(format("module '%s': command '%s' is for everybody (admin = false): it takes no privilege or level",
				ctx.id, name), 4)
		end
		return nil, false
	end
	if privilege ~= nil and level ~= nil then
		error(format("module '%s': command '%s': the level belongs to the privilege '%s', not to the command",
			ctx.id, name, privilege), 4)
	end
	local permissions = self.permissions
	if CLIENT or permissions == nil then
		return nil, false
	end
	if privilege ~= nil then
		local own = ctx.id .. "." .. privilege
		local id = permissions:Get(own) ~= nil and own or privilege
		if permissions:Get(id) == nil then
			error(format("module '%s': command '%s': unknown privilege '%s' (declare it in the manifest)", ctx.id,
				name, privilege), 4)
		end
		return id, false
	end
	permissions:Register(name, { module = ctx.id, name = name, level = level or DEFAULT_LEVEL, desc = spec.help,
		command = name })
	return name, true
end

function Service:_Add(ctx, name, spec, handler)
	if type(name) ~= "string" or not name:find(NAME_PATTERN) then
		error(format("module '%s': command name must match %s, got %s", ctx.id, NAME_PATTERN, tostring(name)), 3)
	end
	spec = spec or {}
	if type(spec) ~= "table" then
		error(format("module '%s': spec of command '%s' must be a table", ctx.id, name), 3)
	end
	for key in pairs(spec) do
		if not SPEC_KEYS[key] then
			error(format("module '%s': command '%s' has an unknown spec key '%s'", ctx.id, name, tostring(key)), 3)
		end
	end
	local owner = self.owners[name]
	if owner ~= nil and owner ~= ctx.id then
		error(format("module '%s': command '%s' already belongs to module '%s'", ctx.id, name, owner), 3)
	end
	local bound = ctx:Handler(handler, "command '" .. name .. "'")
	if owner ~= nil then
		self:_Remove(name, ctx.id)
	end
	local privilege, owned = self:_Privilege(ctx, name, spec)
	local entry = {
		name = name,
		module = ctx.id,
		help = spec.help,
		admin = spec.admin ~= false,
		privilege = privilege,
		owned = owned,
		handler = bound,
	}
	self.owners[name] = ctx.id
	self.specs[name] = entry
	local service = self
	concommand.Add(name, function(ply, _, args)
		service:_Run(entry, ply, args or {})
	end, nil, spec.help)
end

function Service:_Remove(name, id)
	if self.owners[name] ~= id then
		return
	end
	local entry = self.specs[name]
	self.owners[name] = nil
	self.specs[name] = nil
	concommand.Remove(name)
	if entry.owned then
		self.permissions:Unregister(entry.privilege)
	end
end

-- Registered commands sorted by name: { name, module, help, admin, privilege }.
function Service:List()
	local names = {}
	for name in pairs(self.specs) do
		names[#names + 1] = name
	end
	table.sort(names)
	local list = {}
	for i, name in ipairs(names) do
		local entry = self.specs[name]
		list[i] = { name = name, module = entry.module, help = entry.help, admin = entry.admin,
			privilege = entry.privilege }
	end
	return list
end

function Service:ForModule(ctx)
	local service = self
	local names = {}
	local facade = {}

	-- Adds a console command of the module (see the header).
	function facade:Add(name, spec, handler)
		service:_Add(ctx, name, spec, handler)
		names[name] = true
	end

	function facade:Remove(name)
		names[name] = nil
		service:_Remove(name, ctx.id)
	end

	-- Every registered command of every module (copies, see Service:List).
	function facade:List()
		return service:List()
	end

	function facade:Dispose()
		for name in pairs(names) do
			service:_Remove(name, ctx.id)
		end
		names = {}
	end

	return facade
end

-- Removes every command (kernel shutdown and autorefresh).
function Service:Shutdown()
	for name, id in pairs(self.owners) do
		self:_Remove(name, id)
	end
end

return Service
