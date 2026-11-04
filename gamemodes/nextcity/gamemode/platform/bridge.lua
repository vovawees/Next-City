-- Next-City platform: engine bridge, the only file that defines GM:* functions.
--
-- Engine callbacks become bus events named "gm.<Hook>"; modules subscribe with ctx:On and
-- never add engine hooks themselves. Kernel objects are read from NC on every call, so a
-- rebuilt kernel (autorefresh) takes over immediately. Three kinds of callbacks:
--
--   notifications  the base gamemode runs first, then the event is emitted
--   questions      Query "gm.<Hook>": the first non-nil answer is the result; without an
--                  answer the base gamemode decides (as if the hook were not overridden)
--   replacements   the event is emitted and the base gamemode is not called
--
-- Questions with a "handled" answer (PlayerSpawn, PlayerDeathThink) skip the base code
-- when a listener returns true. The scheduler is driven from GM:Tick.

local CurTime = CurTime

local function base(gm, name, ...)
	local baseClass = gm.BaseClass
	local fn = baseClass and baseClass[name]
	if fn then
		return fn(gm, ...)
	end
end

-- Question: the first non-nil answer of the bus, otherwise the base result.
local function ask(gm, name, ...)
	local answer = NC.Events:Query("gm." .. name, ...)
	if answer ~= nil then
		return answer
	end
	return base(gm, name, ...)
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

-- fullUpdate (client): the entity goes away only for a full update and comes back.
function GM:EntityRemoved(ent, fullUpdate)
	base(self, "EntityRemoved", ent, fullUpdate)
	NC.Events:Emit("gm.EntityRemoved", ent, fullUpdate)
end

-- Shared and predicted: runs on the server and on the client of the player.
function GM:KeyPress(ply, key)
	base(self, "KeyPress", ply, key)
	NC.Events:Emit("gm.KeyPress", ply, key)
end

-- After game.CleanUpMap: on the server and, unless the server skipped them, on clients.
function GM:PostCleanupMap()
	base(self, "PostCleanupMap")
	NC.Events:Emit("gm.PostCleanupMap")
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

	-- Question "gm.PlayerSpawn": true means the spawn is handled (e.g. the player became
	-- an observer) and the base spawn (loadout, model, hands) is skipped. Then
	-- "gm.PlayerSpawned" is emitted either way.
	function GM:PlayerSpawn(ply, transition)
		if not NC.Events:Query("gm.PlayerSpawn", ply, transition) then
			base(self, "PlayerSpawn", ply, transition)
		end
		NC.Events:Emit("gm.PlayerSpawned", ply, transition)
	end

	-- Question: the spawn point entity. The base version may kill players that block the
	-- chosen point, so a module should always answer.
	function GM:PlayerSelectSpawn(ply, transition)
		return ask(self, "PlayerSelectSpawn", ply, transition)
	end

	-- Replacement: modules give the equipment; the base pistol and crowbar never appear.
	function GM:PlayerLoadout(ply)
		NC.Events:Emit("gm.PlayerLoadout", ply)
	end

	function GM:DoPlayerDeath(ply, attacker, dmginfo)
		base(self, "DoPlayerDeath", ply, attacker, dmginfo)
		NC.Events:Emit("gm.DoPlayerDeath", ply, attacker, dmginfo)
	end

	function GM:PlayerDeath(ply, inflictor, attacker)
		base(self, "PlayerDeath", ply, inflictor, attacker)
		NC.Events:Emit("gm.PlayerDeath", ply, inflictor, attacker)
	end

	function GM:PlayerSilentDeath(ply)
		base(self, "PlayerSilentDeath", ply)
		NC.Events:Emit("gm.PlayerSilentDeath", ply)
	end

	-- Called every tick for a dead player. Question: true means a module controls the
	-- respawn and the base auto-respawn (on a key press) is skipped.
	function GM:PlayerDeathThink(ply)
		if not NC.Events:Query("gm.PlayerDeathThink", ply) then
			base(self, "PlayerDeathThink", ply)
		end
	end

	function GM:PlayerShouldTakeDamage(ply, attacker)
		return ask(self, "PlayerShouldTakeDamage", ply, attacker)
	end

	function GM:CanPlayerSuicide(ply)
		return ask(self, "CanPlayerSuicide", ply)
	end

	-- Replacement: the "changeteam" console command lands here; without a module that
	-- handles it nobody switches teams on their own.
	function GM:PlayerRequestTeam(ply, teamIndex)
		NC.Events:Emit("gm.PlayerRequestTeam", ply, teamIndex)
	end

else
	function GM:HUDPaint()
		base(self, "HUDPaint")
		NC.Events:Emit("gm.HUDPaint")
	end
end
