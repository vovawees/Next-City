-- Players module, server part: states, deploying, spectating.
--
-- Nobody enters the game without Deploy: any other spawn (the engine's first spawn, a
-- respawn by the base gamemode) makes the player an observer, and the base auto-respawn
-- is off. An alive player that something else respawns stays alive.
--
-- Kill is the death on behalf of an attacker (D6: the model of the body decides when a
-- player dies, the engine only carries the death out): an engine damage that nothing
-- may refuse, so frags, the kill feed and the ragdoll credit the attacker.
--
-- Listens:  gm.PlayerInitialSpawn, net.ready, gm.PlayerSpawn and gm.PlayerSelectSpawn and
--           gm.PlayerDeathThink and gm.PlayerShouldTakeDamage (answers), gm.PlayerSpawned,
--           gm.PlayerLoadout, gm.PlayerDeath, gm.PlayerSilentDeath, gm.PlayerDisconnected.
-- Emits:    players.ready (ply)                         loaded, now a spectator
--           players.stateChanged (ply, state, old)
--           players.loadout (ply)                       a deployed player gets equipment
--           players.spawned (ply)                       a deployed player is in the world
--           players.died (ply, inflictor, attacker)     attacker and inflictor may be nil
--           players.left (ply, state)                   disconnected in that state
-- Asks:     players.spawnPoint (ply) -> spawn entity, { pos = Vector, ang = Angle },
--           a spawn group ("a", "b", "any") or nil for the default pick.
-- Commands: nc_players.

local M = NC.Module("players")

local EMPTY = {}
local KILL_DAMAGE = 1e6 -- more than any health and suit armor can take

function M:Init(ctx)
	self.lists = { connecting = {}, spectator = {}, alive = {}, dead = {} }
	self.slots = {}      -- ply -> position in the list of its state
	self.deploying = {}  -- ply -> { spawn, pos, ang } while Deploy runs
	self.silencing = {}  -- ply -> true while MakeSpectator kills silently
	self.killing = {}    -- ply -> true while Kill runs
	self.spawnCursor = 0
	ctx.commands:Add("nc_players", { help = "players and their life states" }, "ListCommand")
end

function M:Start(ctx)
	ctx:On("gm.PlayerInitialSpawn", "OnInitialSpawn")
	ctx:On("net.ready", "OnNetReady")
	ctx:On("gm.PlayerSpawn", "AnswerSpawn")
	ctx:On("gm.PlayerSelectSpawn", "AnswerSelectSpawn")
	ctx:On("gm.PlayerDeathThink", "AnswerDeathThink")
	-- Above the rules of rounds and modes: nothing refuses the damage of Kill.
	ctx:On("gm.PlayerShouldTakeDamage", "AnswerTakeDamage", { priority = 1000 })
	ctx:On("gm.PlayerSpawned", "OnSpawned")
	ctx:On("gm.PlayerLoadout", "OnLoadout")
	ctx:On("gm.PlayerDeath", "OnDeath")
	ctx:On("gm.PlayerSilentDeath", "OnSilentDeath")
	ctx:On("gm.PlayerDisconnected", "OnDisconnected")
	ctx:On("gm.InitPostEntity", "RefreshSpawns")
	ctx:On("gm.PostCleanupMap", "RefreshSpawns")
	self:Adopt()
end

-- Lists ----------------------------------------------------------------------------------

local function listAdd(self, state, ply)
	local list = self.lists[state]
	list[#list + 1] = ply
	self.slots[ply] = #list
end

local function listRemove(self, state, ply)
	local list = self.lists[state]
	local slot = self.slots[ply]
	if slot == nil or list[slot] ~= ply then
		return
	end
	local last = list[#list]
	list[slot] = last
	self.slots[last] = slot
	list[#list] = nil
	self.slots[ply] = nil
end

-- Players in a state (do not modify; order changes as players come and go).
function M:List(state)
	return self.lists[state] or EMPTY
end

function M:Count(state)
	return #(self.lists[state] or EMPTY)
end

-- Ready players (spectator, alive, dead) sorted by entity index; a new table.
function M:ReadyPlayers()
	local result = {}
	for _, state in ipairs({ "spectator", "alive", "dead" }) do
		for _, ply in ipairs(self.lists[state]) do
			result[#result + 1] = ply
		end
	end
	table.sort(result, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return result
end

function M:_SetState(ply, state)
	local life = self.ctx.components.life
	local old = self:State(ply)
	if old == state then
		return
	end
	if old ~= nil then
		listRemove(self, old, ply)
	end
	listAdd(self, state, ply)
	if old == nil then
		life:Add(ply, { state = state })
	else
		life:Patch(ply, { state = state, respawnAt = state == "dead" and life:Get(ply).respawnAt or 0 })
	end
	self.ctx.log:Debug("%s: %s -> %s", tostring(ply), tostring(old), state)
	self.ctx.events:Emit("players.stateChanged", ply, state, old)
end

-- Rebuilds the lists for players already on the server (autorefresh keeps the
-- replicated states; others are derived from the engine state).
function M:Adopt()
	local life = self.ctx.components.life
	local stale = {}
	for index in life:Each() do
		local ent = Entity(index)
		if not (IsValid(ent) and ent:IsPlayer()) then
			stale[#stale + 1] = index
		end
	end
	for _, index in ipairs(stale) do
		life:Remove(index)
	end
	for _, ply in ipairs(player.GetAll()) do
		local state = self:State(ply)
		if state == nil then
			if not (ply:IsBot() or self.ctx.net:IsReady(ply)) then
				state = "connecting"
			elseif ply:Alive() then
				state = "alive"
			else
				state = "spectator"
			end
			life:Add(ply, { state = state })
		end
		listAdd(self, state, ply)
	end
end

-- Joining --------------------------------------------------------------------------------

function M:OnInitialSpawn(ply)
	self:_SetState(ply, "connecting")
	if ply:IsBot() then
		-- Not from inside PlayerInitialSpawn: the engine spawns the player right after it.
		self.ctx:After(0, function()
			if IsValid(ply) and self:State(ply) == "connecting" then
				self:_MarkReady(ply)
			end
		end)
	end
end

function M:OnNetReady(ply)
	if IsValid(ply) and self:State(ply) == "connecting" then
		self:_MarkReady(ply)
	end
end

function M:_MarkReady(ply)
	self:_SetState(ply, "spectator")
	self.ctx.events:Emit("players.ready", ply)
end

function M:OnDisconnected(ply)
	local state = self:State(ply)
	self.deploying[ply] = nil
	self.silencing[ply] = nil
	self.killing[ply] = nil
	if state == nil then
		return
	end
	listRemove(self, state, ply)
	self.ctx.components.life:Remove(ply)
	self.ctx.events:Emit("players.left", ply, state)
end

-- Spawning -------------------------------------------------------------------------------

local function observe(ply)
	ply:StripWeapons()
	if ply:GetObserverMode() == OBS_MODE_NONE then
		ply:Spectate(OBS_MODE_ROAMING)
	end
end

-- Puts a ready player into the game: a spawn at a point picked for them, then
-- players.loadout and players.spawned. opts.spawn overrides the point: an entity,
-- { pos, ang } or a spawn group. Works for spectators, dead and alive players (an alive
-- player respawns). Returns true if the player is alive afterwards.
function M:Deploy(ply, opts)
	if not IsValid(ply) or not self:IsReady(ply) then
		return false
	end
	self.deploying[ply] = { spawn = opts and opts.spawn }
	ply:StripWeapons()
	ply:RemoveAllAmmo()
	if ply:GetObserverMode() ~= OBS_MODE_NONE then
		ply:UnSpectate()
	end
	ply:Spawn()
	self.deploying[ply] = nil
	return ply:Alive() and self:State(ply) == "alive"
end

-- Takes a ready player out of the game: a silent death if alive, then an observer.
-- Returns false for players that are not ready.
function M:MakeSpectator(ply)
	if not IsValid(ply) or not self:IsReady(ply) then
		return false
	end
	if ply:Alive() then
		self.silencing[ply] = true
		ply:KillSilent()
		self.silencing[ply] = nil
	end
	observe(ply)
	self:_SetState(ply, "spectator")
	return true
end

-- Shows when a dead player comes back (game time; nil clears it).
function M:SetRespawnAt(ply, at)
	local life = self.ctx.components.life
	if life:Has(ply) then
		life:Set(ply, "respawnAt", at or 0)
	end
end

function M:AnswerSpawn(ply)
	local state = self:State(ply)
	if self.deploying[ply] ~= nil or state == "alive" then
		if state ~= "alive" then
			self:_SetState(ply, "alive")
		end
		return nil -- the base spawn runs: hands, loadout, model
	end
	observe(ply)
	if state == "dead" then
		self:_SetState(ply, "spectator")
	end
	return true
end

function M:AnswerSelectSpawn(ply)
	local deploy = self.deploying[ply]
	local points = self:SpawnPoints("any")
	if deploy == nil then
		return points[1] -- an observer: any point will do
	end
	local answer = deploy.spawn
	if answer == nil then
		answer = self.ctx.events:Query("players.spawnPoint", ply)
	end
	if isentity(answer) and IsValid(answer) then
		return answer
	end
	if type(answer) == "table" and answer.pos ~= nil then
		deploy.pos, deploy.ang = answer.pos, answer.ang
		return points[1]
	end
	local point, spot = self:PickSpawn(ply, self:SpawnPoints(type(answer) == "string" and answer or "any"))
	deploy.pos = spot
	return point
end

function M:OnSpawned(ply)
	if self:State(ply) ~= "alive" then
		return
	end
	local deploy = self.deploying[ply]
	if deploy ~= nil then
		if deploy.pos ~= nil then
			ply:SetPos(deploy.pos)
		end
		if deploy.ang ~= nil then
			ply:SetEyeAngles(deploy.ang)
		end
	end
	self.ctx.events:Emit("players.spawned", ply)
end

function M:OnLoadout(ply)
	if self:State(ply) == "alive" then
		self.ctx.events:Emit("players.loadout", ply)
	end
end

-- Dying ----------------------------------------------------------------------------------

function M:OnDeath(ply, inflictor, attacker)
	if self:State(ply) ~= "alive" then
		return
	end
	self:_SetState(ply, "dead")
	self.ctx.events:Emit("players.died", ply, inflictor, attacker)
end

function M:OnSilentDeath(ply)
	if not self.silencing[ply] then
		self:OnDeath(ply, nil, nil)
	end
end

-- Kills an alive player with an engine damage that credits the attacker. opts: attacker
-- and inflictor (entities; invalid ones become the world, the inflictor defaults to the
-- attacker), damageType (DMG_*, default generic), force and position (Vectors: the push
-- of the ragdoll). If the engine refuses (god mode), the player dies by ply:Kill().
-- Returns true if the player is dead afterwards.
function M:Kill(ply, opts)
	if not (IsValid(ply) and ply:Alive()) then
		return false
	end
	opts = opts or EMPTY
	local attacker = opts.attacker
	if not IsValid(attacker) then
		attacker = game.GetWorld()
	end
	local inflictor = opts.inflictor
	if not IsValid(inflictor) then
		inflictor = attacker
	end
	local dmginfo = DamageInfo()
	dmginfo:SetAttacker(attacker)
	dmginfo:SetInflictor(inflictor)
	dmginfo:SetDamage(KILL_DAMAGE)
	dmginfo:SetDamageType(opts.damageType or DMG_GENERIC)
	if opts.force ~= nil then
		dmginfo:SetDamageForce(opts.force)
	end
	if opts.position ~= nil then
		dmginfo:SetDamagePosition(opts.position)
	end
	self.killing[ply] = true
	local ok, err = pcall(ply.TakeDamageInfo, ply, dmginfo)
	self.killing[ply] = nil
	if not ok then
		self.ctx.log:Error("killing %s failed: %s", tostring(ply), tostring(err))
	end
	if ply:Alive() then
		ply:Kill()
	end
	return not ply:Alive()
end

-- True while Kill damages the player: damage handlers let that damage through.
function M:IsKilling(ply)
	return self.killing[ply] == true
end

function M:AnswerTakeDamage(ply)
	if self.killing[ply] then
		return true
	end
end

-- Dead players stay dead until Deploy.
function M:AnswerDeathThink()
	return true
end

-- Console --------------------------------------------------------------------------------

function M:ListCommand()
	local lines = {}
	local counts = {}
	for _, state in ipairs(self.STATES) do
		counts[#counts + 1] = state .. " " .. self:Count(state)
	end
	lines[1] = "Players: " .. table.concat(counts, ", ")
	local all = player.GetAll()
	for _, ply in ipairs(all) do
		local at = self:RespawnAt(ply)
		lines[#lines + 1] = string.format("  %3d  %-24s %-10s team %-5d%s", ply:EntIndex(), ply:Nick(),
			tostring(self:State(ply)), ply:Team(), at and string.format("  respawn in %.1fs", at - CurTime()) or "")
	end
	return lines
end
