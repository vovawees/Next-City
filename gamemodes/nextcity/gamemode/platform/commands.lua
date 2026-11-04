-- Next-City platform: console commands of modules (service "commands", ctx.commands).
--
--   ctx.commands:Add("nc_round", {
--   	help = "restart | end | next <mode>",
--   	admin = true, -- default: only the server console and superadmins may run it
--   }, function(ply, args) return { "line", "line" } end) -- or a method name: "OnRoundCommand"
--
-- The handler gets the caller (nil for the server console) and the arguments and returns
-- the reply: a string or an array of lines for the caller's console. Errors are caught,
-- logged and reported to the caller. Commands go away when their module stops.
-- On the server, admin commands check Player:IsSuperAdmin (CAMI permissions come in M8).
-- Commands added on the client run locally and are never checked.

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
local SPEC_KEYS = { help = true, admin = true }

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

-- opts: log, previous (the service of the previous kernel; its commands are gone by then).
function Service.New(opts)
	return setmetatable({
		log = opts.log,
		owners = {}, -- name -> module id
		specs = {},  -- name -> { help, admin, module }
	}, Service)
end

function Service:_Run(entry, ply, args)
	if SERVER and entry.admin and IsValid(ply) and not ply:IsSuperAdmin() then
		reply(ply, entry.name .. ": superadmin only")
		return
	end
	local ok, result = xpcall(entry.handler, onHandlerError, ply, args)
	if not ok then
		self.log:Error("command '%s' of module '%s' failed: %s", entry.name, entry.module, tostring(result))
		reply(ply, entry.name .. ": failed, see the server log")
		return
	end
	reply(ply, result)
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
	local entry = {
		name = name,
		module = ctx.id,
		help = spec.help,
		admin = spec.admin ~= false,
		handler = ctx:Handler(handler, "command '" .. name .. "'"),
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
	self.owners[name] = nil
	self.specs[name] = nil
	concommand.Remove(name)
end

-- Registered commands sorted by name: { name, module, help, admin }.
function Service:List()
	local names = {}
	for name in pairs(self.specs) do
		names[#names + 1] = name
	end
	table.sort(names)
	local list = {}
	for i, name in ipairs(names) do
		local entry = self.specs[name]
		list[i] = { name = name, module = entry.module, help = entry.help, admin = entry.admin }
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
