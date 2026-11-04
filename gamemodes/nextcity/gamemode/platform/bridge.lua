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
--
-- Damage (D6): the engine's health is not the model of the body. EntityTakeDamage is a
-- question (true blocks the damage), ScalePlayerDamage is a replacement without the
-- base scaling (head x2, limbs x0.25), falls arrive as OnPlayerHitGround and
-- GetFallDamage. StartCommand runs for every user command (shared and predicted).

local CurTime = CurTime

-- "gm.<Hook>" names built once, so hot questions do not concatenate strings.
local EVENT = setmetatable({}, { __index = function(names, hookName)
	local name = "gm." .. hookName
	names[hookName] = name
	return name
end })

local function base(gm, name, ...)
	local baseClass = gm.BaseClass
	local fn = baseClass and baseClass[name]
	if fn then
		return fn(gm, ...)
	end
end

-- Question: the first non-nil answer of the bus, otherwise the base result.
local function ask(gm, name, ...)
	local answer = NC.Events:Query(EVENT[name], ...)
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

-- Shared and predicted: every user command of a player before the engine runs it, so
-- modules can take buttons and movement away (cmd is the CUserCmd).
function GM:StartCommand(ply, cmd)
	base(self, "StartCommand", ply, cmd)
	NC.Events:Emit("gm.StartCommand", ply, cmd)
end

-- Replacement and question: a bullet hit a player (shared; before EntityTakeDamage on
-- the server). The base scaling is off: the damage module decides what a hit does.
-- An answer true blocks the damage.
function GM:ScalePlayerDamage(ply, hitgroup, dmginfo)
	return NC.Events:Query("gm.ScalePlayerDamage", ply, hitgroup, dmginfo)
end

-- Question (shared and predicted): a player lands; speed is the fall speed, units/s.
-- An answer true skips the engine's landing (fall damage and view punch).
function GM:OnPlayerHitGround(ply, inWater, onFloater, speed)
	return ask(self, "OnPlayerHitGround", ply, inWater, onFloater, speed)
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

	-- Question: true blocks the damage; without an answer the engine applies it.
	function GM:EntityTakeDamage(ent, dmginfo)
		return ask(self, "EntityTakeDamage", ent, dmginfo)
	end

	-- Question: the health a fall at `speed` (units/s) takes; called only for falls faster
	-- than the engine's safe speed (526.5 units/s).
	function GM:GetFallDamage(ply, speed)
		return ask(self, "GetFallDamage", ply, speed)
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

	-- Question, asked for every HUD element every frame: false hides the element.
	function GM:HUDShouldDraw(name)
		return ask(self, "HUDShouldDraw", name)
	end

	function GM:RenderScreenspaceEffects()
		base(self, "RenderScreenspaceEffects")
		NC.Events:Emit("gm.RenderScreenspaceEffects")
	end

	-- Question: true blocks the bind (bind is the command, e.g. "+reload").
	function GM:PlayerBindPress(ply, bind, pressed, code)
		return ask(self, "PlayerBindPress", ply, bind, pressed, code)
	end
end
