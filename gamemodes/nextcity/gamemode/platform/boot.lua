-- Next-City platform: boot sequence, runs on both realms.
--
-- Loads the core libraries and config, builds the kernel (logger, event bus, scheduler,
-- module registry), loads modules and wires the engine bridge and dev tools.
-- Running this file again (gamemode autorefresh) stops the previous kernel and boots a
-- fresh one; if the gamemode has already started, the new kernel starts right away.

local Lib = {
	Log = NC.IncludeShared("core/log.lua"),
	Events = NC.IncludeShared("core/events.lua"),
	Scheduler = NC.IncludeShared("core/scheduler.lua"),
	FSM = NC.IncludeShared("core/fsm.lua"),
	Modules = NC.IncludeShared("core/modules.lua"),
}
NC.Lib = Lib
NC.Config = NC.IncludeShared("config.lua")
local Loader = NC.IncludeShared("platform/loader.lua")

if NC.Modules then
	NC.Modules:StopAll()
end

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

-- Kernel -----------------------------------------------------------------------------

local log = Lib.Log.New("core", { level = NC.Config.logLevel or "info", sink = consoleSink })
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

NC.Modules = Lib.Modules.New({
	log = log,
	services = { events = NC.Events, scheduler = NC.Scheduler },
})

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

-- Stops every module (called from GM:ShutDown).
function NC.Shutdown()
	NC.Events:Emit("nc.shutdown")
	NC.Modules:StopAll()
	NC.started = false
end

Loader.Load(NC.Modules, NC.Config.modules or {}, log)
NC.Modules:InitAll()

NC.IncludeShared("platform/bridge.lua")
NC.IncludeShared("platform/devtools.lua")

if NC.started then
	NC.Start()
end
