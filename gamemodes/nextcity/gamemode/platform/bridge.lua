-- Next-City platform: engine bridge, the only file that defines GM:* functions.
--
-- Engine callbacks run the base gamemode first and then become bus events named
-- "gm.<Hook>"; modules subscribe with ctx:On and never add engine hooks themselves.
-- The scheduler is driven from GM:Tick. Kernel objects are read from NC on every call,
-- so a rebuilt kernel (autorefresh) takes over immediately.

local CurTime = CurTime

local function base(gm, name, ...)
	local baseClass = gm.BaseClass
	local fn = baseClass and baseClass[name]
	if fn then
		return fn(gm, ...)
	end
end

function GM:Initialize()
	base(self, "Initialize")
	NC.Start()
end

function GM:Tick()
	base(self, "Tick")
	NC.Scheduler:Update(CurTime())
end

function GM:InitPostEntity()
	base(self, "InitPostEntity")
	NC.Events:Emit("gm.InitPostEntity")
end

function GM:OnReloaded()
	base(self, "OnReloaded")
	NC.Events:Emit("gm.OnReloaded")
end

function GM:ShutDown()
	base(self, "ShutDown")
	NC.Shutdown()
end

if SERVER then
	function GM:PlayerInitialSpawn(ply, transition)
		base(self, "PlayerInitialSpawn", ply, transition)
		NC.Events:Emit("gm.PlayerInitialSpawn", ply, transition)
	end

	function GM:PlayerDisconnected(ply)
		base(self, "PlayerDisconnected", ply)
		NC.Events:Emit("gm.PlayerDisconnected", ply)
	end
end
