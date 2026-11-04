-- Next-City platform: boot sequence, runs on both realms.
--
-- Loads the core libraries and the config (config.lua with the config files of packages,
-- platform/packages.lua), builds the kernel (logger, event bus, scheduler, services,
-- module registry), loads the modules of every package and wires the engine bridge and
-- dev tools.
-- Running this file again (gamemode autorefresh) stops the previous kernel and boots a
-- fresh one; if the gamemode has already started, the new kernel starts right away.

local Lib = {
	Log = NC.IncludeShared("core/log.lua"),
	Events = NC.IncludeShared("core/events.lua"),
	Scheduler = NC.IncludeShared("core/scheduler.lua"),
	FSM = NC.IncludeShared("core/fsm.lua"),
	Modules = NC.IncludeShared("core/modules.lua"),
	Schema = NC.IncludeShared("core/schema.lua"),
	I18n = NC.IncludeShared("core/i18n.lua"),
	Components = NC.IncludeShared("core/components.lua"),
	Params = NC.IncludeShared("core/params.lua"),
	Scope = NC.IncludeShared("core/scope.lua"),
}
NC.Lib = Lib
local Packages = NC.IncludeShared("platform/packages.lua")
NC.Packages = Packages.List(NC.ROOT)
local configProblems
NC.Config, configProblems = Packages.Config(NC.IncludeShared("config.lua"), NC.Packages)
local Loader = NC.IncludeShared("platform/loader.lua")
local NetService = NC.IncludeShared("platform/net.lua")
local I18nService = NC.IncludeShared("platform/i18n.lua")
local ComponentService = NC.IncludeShared("platform/components.lua")
local CommandService = NC.IncludeShared("platform/commands.lua")

-- Console output -----------------------------------------------------------------------

local REALM_COLOR = SERVER and Color(137, 222, 255) or Color(255, 222, 102)
local TEXT_COLOR = Color(230, 230, 230)
local LEVEL_COLORS = {
	trace = Color(140, 140, 140),
	debug = Color(120, 190, 255),
	info = Color(150, 230, 150),
	warn = Color(255, 200, 80),
	error = Color(255, 90, 90),
}
local LEVEL_LABELS = { trace = "TRACE", debug = "DEBUG", info = "INFO ", warn = "WARN ", error = "ERROR" }

local function consoleSink(level, tag, message)
	MsgC(REALM_COLOR, "[NC] ", LEVEL_COLORS[level] or TEXT_COLOR, LEVEL_LABELS[level] or level,
		REALM_COLOR, " [" .. tag .. "] ", TEXT_COLOR, message, "\n")
end

local log = Lib.Log.New("core", { level = NC.Config.logLevel or "info", sink = consoleSink })
for _, message in ipairs(configProblems) do
	log:Error("%s", message)
end

-- Services with a Shutdown method release what they hold outside the kernel (listeners,
-- network receivers). Their data stays readable for the services that take over.
local function shutdownServices(services)
	local names = {}
	for name, service in pairs(services or {}) do
		if type(service.Shutdown) == "function" then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		local ok, err = pcall(services[name].Shutdown, services[name])
		if not ok then
			log:Error("service '%s' failed to shut down: %s", name, tostring(err))
		end
	end
end

-- The previous kernel (autorefresh): modules stop, services shut down and hand their
-- state over to the new ones.
local previous = NC.Services or {}
if NC.Modules then
	NC.Modules:StopAll()
end
shutdownServices(previous)

-- Kernel -----------------------------------------------------------------------------

NC.Log = log

NC.Events = Lib.Events.New({
	onError = function(err, event, listener)
		log:Error("listener '%s' failed on '%s': %s", tostring(listener.id), event, err)
	end,
})

NC.Scheduler = Lib.Scheduler.New({
	now = CurTime(),
	clock = SysTime,
	onError = function(err, id)
		log:Error("job '%s' failed: %s", id, err)
	end,
})

NC.Net = NetService.New({
	config = NC.Config.net,
	log = log:Child("net"),
	events = NC.Events,
	previous = previous.net,
})

local langDirs = {}
for i, package in ipairs(NC.Packages) do
	langDirs[i] = package.path .. "lang/"
end

NC.I18n = I18nService.New({
	dirs = langDirs,
	config = NC.Config.i18n,
	log = log:Child("i18n"),
	events = NC.Events,
	net = NC.Net,
	previous = previous.i18n,
})

NC.Components = ComponentService.New({
	log = log:Child("components"),
	events = NC.Events,
	scheduler = NC.Scheduler,
	net = NC.Net,
	previous = previous.components,
})

NC.Commands = CommandService.New({
	log = log:Child("commands"),
	previous = previous.commands,
})

-- Shared by every module context: ctx.events, ctx.scheduler, ctx.net, ctx.components
-- and ctx.commands (facades per module), ctx.i18n.
NC.Services = {
	events = NC.Events,
	scheduler = NC.Scheduler,
	net = NC.Net,
	i18n = NC.I18n,
	components = NC.Components,
	commands = NC.Commands,
}

NC.Modules = Lib.Modules.New({ log = log, services = NC.Services })

-- Returns the table of a module for its files: local M = NC.Module("id").
function NC.Module(id)
	local instance = NC.Modules:Instance(id)
	if instance == nil then
		error("NC.Module: unknown module '" .. tostring(id) .. "' (no registered manifest)", 2)
	end
	return instance
end

-- Returns the API of the module that provides `iface`, or nil.
-- Modules use ctx:Require instead; this is for the console and external addons.
function NC.Get(iface)
	return NC.Modules:Get(iface)
end

-- Starts every module (called from GM:Initialize, or right away after autorefresh).
function NC.Start()
	NC.started = true
	NC.Modules:StartAll()
	local counts = NC.Modules:Counts()
	log:Info("Next-City %s started (modules: %d running, %d failed)", NC.VERSION, counts.started or 0, counts.failed or 0)
	NC.Events:Emit("nc.ready")
end

-- Stops every module and shuts the services down (called from GM:ShutDown).
function NC.Shutdown()
	NC.Events:Emit("nc.shutdown")
	NC.Modules:StopAll()
	shutdownServices(NC.Services)
	NC.started = false
end

local _, sources = Loader.Load(NC.Modules, NC.Config.modules or {}, log, NC.Packages)
-- The package of every registered module: { [id] = "core" | gamemode | "addons" }.
NC.ModulePackages = sources
NC.Modules:InitAll()

NC.IncludeShared("platform/bridge.lua")
NC.IncludeShared("platform/devtools.lua")

if NC.started then
	NC.Start()
end
