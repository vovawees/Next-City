-- Ragdoll, server part: who falls, who gets up and what is left of the dead.
--
--   standing -> fallen | unconscious (waking up: fallen) -> getting_up -> standing
--   any -> dead (a corpse)
--
-- Falls: unconsciousness (organism.unconscious), a body that cannot stand
-- (organism.capabilities, config.fallWhenWeak), a blast, impact or blow of at least
-- config.knockdown engine damage (damage.hit), a landing at config.fallSpeed or faster
-- not into water, at will (net fall from nc_fall; config.voluntary, config.cooldown) and
-- nc_ragdoll. The body falls at the next think, outside the engine call (damage,
-- movement) that caused it, with the velocity that call gave the player. Nobody falls in
-- a vehicle or in noclip, when ragdoll.canFall says no or when no ragdoll fits
-- (sv_bodies.lua).
-- Getting up: the jump key (or nc_fall again) once the body is conscious and can stand
-- (or crawls instead of falling, without fallWhenWeak), after config.getUpDelay down,
-- slower than config.getUpSpeed, where there is room (sv_bodies.lua) and unless
-- ragdoll.canGetUp says no; why a try failed (room, moving) goes to the player. It takes
-- config.getUpTime: the eyes of the player rise to the spot, then the player stands
-- there (or on another spot if it was taken; with none it stays down) and the body goes.
-- Death: the fallen body becomes the corpse; a standing player leaves a corpse in its
-- pose pushed by the killing force. The ragdoll of the engine goes, unless no corpse
-- fits. The organism keeps reading the dead body from the corpse. Damage that leaves no
-- ragdoll (DMG_REMOVENORAGDOLL) leaves no corpse either.
-- A body removed by something else (a cleanup of the map) stands its player up where it
-- lay; out of the game (spectator, a silent death), off the server or a new spawn: the
-- body goes. A player that left its body dead or out of the game gets its hull and
-- movement back when it spawns.
--
-- Listens:  organism.unconscious, organism.capabilities, damage.hit, gm.OnPlayerHitGround,
--           gm.StartCommand (sh_ragdoll.lua), gm.DoPlayerDeath, gm.EntityRemoved,
--           players.spawned, players.stateChanged, players.left, net fall.
-- Emits:    ragdoll.fell (ply, ent, cause)  cause: unconscious, weak, hit, landing,
--                                           voluntary, command
--           ragdoll.stood (ply)
--           ragdoll.corpse (ply, ent)
-- Asks:     ragdoll.canFall (ply, cause) -> false: stays standing;
--           ragdoll.canGetUp (ply) -> false: stays down.
-- Commands: nc_ragdoll [player] [fall | up] — the bodies; a player falls or gets up.

local M = NC.Module("ragdoll")

local IsValid = IsValid
local CurTime = CurTime
local pairs = pairs
local ipairs = ipairs
local next = next
local max = math.max
local band = bit.band
local format = string.format
local DMG_REMOVENORAGDOLL = DMG_REMOVENORAGDOLL

local EMPTY = {}
-- Kinds of hits that knock down with enough damage.
local KNOCKDOWN = { blast = true, vehicle = true, crush = true, blunt = true }
local out = {} -- the component being written

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.bodies = {}        -- ply -> body of a player down in it
	self.down = self.bodies -- read by the user commands (sh_ragdoll.lua)
	self.byEnt = {}         -- ragdoll -> body or corpse
	self.corpses = {}       -- oldest first
	self.fallen = 0         -- count of bodies
	self.pending = {}       -- ply -> cause of a fall at the next think
	self.lastFall = {}      -- ply -> game time of the last fall at will
	self.done = {}          -- bodies done getting up, within a think
	self.hidden = {}        -- ply -> true: hidden (sv_bodies.lua) and without its hull yet
	ctx.net:Receive("fall", "OnFallRequest")
	ctx.commands:Add("nc_ragdoll", { help = "fallen bodies and corpses: [player] [fall | up]", admin = true },
		"RagdollCommand")
end

function M:Start(ctx)
	ctx:Every("think", 1 / ctx.config.syncRate, "Think")
	ctx:Every("clean", 0.5, "Clean")
	ctx:On("gm.StartCommand", "OnStartCommand", { priority = 10 })
	ctx:On("organism.unconscious", "OnUnconscious")
	ctx:On("organism.capabilities", "OnCapabilities")
	ctx:On("damage.hit", "OnHit")
	ctx:On("gm.OnPlayerHitGround", "OnHitGround")
	ctx:On("gm.DoPlayerDeath", "OnDeath")
	ctx:On("gm.EntityRemoved", "OnEntityRemoved")
	ctx:On("players.spawned", "OnSpawned")
	ctx:On("players.stateChanged", "OnStateChanged")
	ctx:On("players.left", "OnLeft")
end

-- Every player stands up where there is room and every ragdoll goes (autorefresh).
function M:Stop()
	for _, body in pairs(self.bodies) do
		local ply, rag = body.ply, body.ent
		local spot = IsValid(ply) and IsValid(rag) and self:_Spot(ply, rag:GetPos(), rag) or nil
		self:_Release(body, spot)
	end
	for i = #self.corpses, 1, -1 do
		self:_RemoveCorpse(i)
	end
	for ply in pairs(self.hidden) do
		if IsValid(ply) then
			self:_Restore(ply)
		end
	end
end

-- The component of `ply`: the state, the body or corpse, since when, why it cannot get up.
function M:_Publish(ply, state, ent, since, blocked)
	out.state = state
	out.ent = IsValid(ent) and ent:EntIndex() or 0
	out.since = since
	out.blocked = blocked or "none"
	local component = self.ctx.components.body
	if component:Has(ply) then
		component:Patch(ply, out)
	else
		component:Add(ply, out)
	end
end

-- Falling ----------------------------------------------------------------------------------

-- `ply` falls into its body. opts: cause (default "command"), state ("fallen" or
-- "unconscious"; default: as the body is), velocity (Vector; default: the player's).
-- Returns the body, or nil and why not: dead, down, vehicle, noclip, refused, limit, model.
function M:Fall(ply, opts)
	opts = opts or EMPTY
	if not IsValid(ply) or not ply:Alive() or not self.players:IsAlive(ply) then
		return nil, "dead"
	end
	if self.bodies[ply] ~= nil then
		return nil, "down"
	end
	if ply:InVehicle() then
		return nil, "vehicle"
	end
	local moveType = ply:GetMoveType()
	if moveType == MOVETYPE_NOCLIP or moveType == MOVETYPE_OBSERVER then
		return nil, "noclip"
	end
	local cause = opts.cause or "command"
	if self.ctx.events:Query("ragdoll.canFall", ply, cause) == false then
		return nil, "refused"
	end
	if not self:_Fits() then
		return nil, "limit"
	end
	local rag = self:_Build(ply, opts.velocity)
	if rag == nil then
		return nil, "model"
	end
	local now = CurTime()
	local state = opts.state or (self.organism:IsUnconscious(ply) and "unconscious" or "fallen")
	local body = { ply = ply, state = state, since = now, cause = cause, blocked = "none", spot = nil,
		input = { buttons = 0, forward = 0, side = 0, jump = false } }
	self:_Attach(body, rag)
	self:_Hide(ply, body)
	self.bodies[ply] = body
	self.byEnt[rag] = body
	self.fallen = self.fallen + 1
	self.pending[ply] = nil
	self.organism:SetCarrier(ply, rag)
	self:_Follow(body)
	self:_Publish(ply, state, rag, now)
	self.ctx.events:Emit("ragdoll.fell", ply, rag, cause)
	return body
end

-- The hidden player follows the head of its body: what it hears, what the server sees.
function M:_Follow(body)
	local rag = body.ent
	local head = body.head
	body.ply:SetPos(IsValid(head) and head:GetPos() or rag:GetPos())
	body.last = rag:GetPos()
end

-- A body changes its state; leaving getting_up, the eyes go back into it.
function M:_SetState(body, state, now, blocked)
	if body.state == "getting_up" and state ~= "getting_up" then
		body.spot = nil
		self:_HideView(body.ply)
		self:_Follow(body)
	end
	body.state, body.since, body.blocked = state, now, blocked or "none"
	self:_Publish(body.ply, state, body.ent, now, blocked)
end

-- `ply` falls at the next think. A blow or a landing is the cause over what it did to
-- the body (unconscious, weak), which the organism tells first.
function M:_Defer(ply, cause, strong)
	local pending = self.pending
	if strong or pending[ply] == nil then
		pending[ply] = cause
	end
end

function M:Think(now)
	-- One at a time: a listener of ragdoll.fell may defer another fall.
	local pending = self.pending
	local who, cause = next(pending)
	while who ~= nil do
		pending[who] = nil
		self:Fall(who, { cause = cause })
		who, cause = next(pending)
	end
	-- Bodies that are done getting up stand after the loop: ragdoll.stood may make others fall.
	local getUpTime = self.ctx.config.getUpTime
	local done = self.done
	local n = 0
	for ply, body in pairs(self.bodies) do
		if IsValid(ply) and IsValid(body.ent) then
			local input = body.input
			local jump = input.jump
			input.jump = false
			if body.state == "getting_up" then
				if now - body.since >= getUpTime then
					n = n + 1
					done[n] = body
				end
			else
				if jump then
					self:GetUp(ply)
				end
				if body.state ~= "getting_up" then
					self:_Follow(body)
				end
			end
		end
	end
	for i = 1, n do
		local body = done[i]
		done[i] = nil
		if self.bodies[body.ply] == body and body.state == "getting_up" then
			self:_Stand(body, now)
		end
	end
end

-- Getting up -----------------------------------------------------------------------------------

-- `ply` begins to get up. force (admins): only the room is asked. Returns true, or false
-- and why not: standing, unconscious, getting_up, legs, delay, moving, refused, room.
function M:GetUp(ply, force)
	local body = self.bodies[ply]
	if body == nil then
		return false, "standing"
	end
	if body.state ~= "fallen" then
		return false, body.state
	end
	local config = self.ctx.config
	local now = CurTime()
	local rag = body.ent
	if not force then
		local caps = self.organism:Capabilities(ply)
		if caps == nil or caps.unconscious then
			return false, "unconscious"
		end
		if not caps.canStand and config.fallWhenWeak then
			return false, "legs"
		end
		if now - body.since < config.getUpDelay then
			return false, "delay"
		end
		if rag:GetVelocity():Length() >= config.getUpSpeed then
			return self:_Blocked(body, "moving")
		end
		if self.ctx.events:Query("ragdoll.canGetUp", ply) == false then
			return false, "refused"
		end
	end
	local spot = self:_Spot(ply, rag:GetPos(), rag)
	if spot == nil then
		return self:_Blocked(body, "room")
	end
	self:_SetState(body, "getting_up", now)
	body.spot = spot
	ply:SetPos(spot)
	self:_ShowView(ply, body)
	return true
end

function M:_Blocked(body, why)
	if body.blocked ~= why then
		body.blocked = why
		self:_Publish(body.ply, body.state, body.ent, body.since, why)
	end
	return false, why
end

-- Getting up is over: the player stands on its spot (or on another one if that was
-- taken) and the body goes; with no room left the player stays down. Legs that do not
-- hold (an admin stood the player up) fall again at the next think.
function M:_Stand(body, now)
	local ply, rag = body.ply, body.ent
	local spot = body.spot
	if not self:_Free(ply, spot, rag) then
		spot = self:_Spot(ply, rag:GetPos(), rag)
	end
	if spot == nil then
		self:_SetState(body, "fallen", now, "room")
		return false
	end
	self:_Release(body, spot)
	local caps = self.organism:Capabilities(ply)
	if caps ~= nil and not caps.canStand and self.ctx.config.fallWhenWeak then
		self:_Defer(ply, "weak")
	end
	return true
end

-- The body is no longer one of a player down in it.
function M:_Forget(body)
	self.bodies[body.ply] = nil
	if self.byEnt[body.ent] == body then
		self.byEnt[body.ent] = nil
	end
	self.fallen = self.fallen - 1
end

-- The body of a living player goes (unless `removed`: it is going already) and the
-- player stands at `spot` (nil: where it is).
function M:_Release(body, spot, removed)
	local ply, rag = body.ply, body.ent
	self:_Forget(body)
	if not removed and IsValid(rag) then
		rag:Remove()
	end
	if not IsValid(ply) then
		return
	end
	if spot ~= nil then
		ply:SetPos(spot)
	end
	self:_Show(ply, body, true)
	self.organism:SetCarrier(ply, nil)
	self:_Publish(ply, "standing", nil, CurTime())
	self.ctx.events:Emit("ragdoll.stood", ply)
end

-- The body goes without its player standing up: the player is out of the game.
function M:_Drop(body)
	local ply, rag = body.ply, body.ent
	self:_Forget(body)
	if IsValid(rag) then
		rag:Remove()
	end
	if IsValid(ply) then
		self:_Show(ply, body, false)
		self.organism:SetCarrier(ply, nil)
	end
end

-- Death ------------------------------------------------------------------------------------

-- A dying player leaves its body as the corpse, or a corpse in its pose.
function M:OnDeath(ply, _, dmginfo)
	local now = CurTime()
	local body = self.bodies[ply]
	self.pending[ply] = nil
	if band(dmginfo:GetDamageType(), DMG_REMOVENORAGDOLL) ~= 0 then
		if body ~= nil then
			self:_Drop(body)
		end
		self:_Publish(ply, "dead", nil, now)
		return
	end
	local corpse
	if body ~= nil then
		corpse = body.ent
		self:_Forget(body)
		self:_Show(ply, body, false)
	else
		if not self:_Fits() then
			return
		end
		corpse = self:_Build(ply)
		if corpse == nil then
			return
		end
		self:_Push(corpse, dmginfo)
	end
	local engine = ply:GetRagdollEntity()
	if IsValid(engine) then
		engine:Remove()
	end
	self:_AddCorpse(ply, corpse, now)
	self.organism:SetCarrier(ply, corpse)
	self:_Publish(ply, "dead", corpse, now)
	self.ctx.events:Emit("ragdoll.corpse", ply, corpse)
end

-- Events -----------------------------------------------------------------------------------

function M:OnUnconscious(ply, unconscious)
	local body = self.bodies[ply]
	if unconscious then
		if body == nil then
			self:_Defer(ply, "unconscious")
		elseif body.state ~= "unconscious" then
			self:_SetState(body, "unconscious", CurTime())
		end
	elseif body ~= nil and body.state == "unconscious" then
		self:_SetState(body, "fallen", CurTime())
	end
end

-- Legs that do not hold: down, and no getting up on them.
function M:OnCapabilities(ply, caps)
	if caps == nil or not caps.alive or caps.canStand or not self.ctx.config.fallWhenWeak then
		return
	end
	local body = self.bodies[ply]
	if body == nil then
		self:_Defer(ply, caps.unconscious and "unconscious" or "weak")
	elseif body.state == "getting_up" then
		self:_SetState(body, "fallen", CurTime())
	end
end

function M:OnHit(ply, hit)
	if KNOCKDOWN[hit.kind] and (hit.amount or 0) >= self.ctx.config.knockdown and self.bodies[ply] == nil then
		self:_Defer(ply, "hit", true)
	end
end

function M:OnHitGround(ply, inWater, _, speed)
	if not inWater and speed >= self.ctx.config.fallSpeed and self.bodies[ply] == nil then
		self:_Defer(ply, "landing", true)
	end
end

-- Fall at will, or get up.
function M:OnFallRequest(_, ply)
	if self.bodies[ply] ~= nil then
		self:GetUp(ply)
		return
	end
	local config = self.ctx.config
	local now = CurTime()
	if not config.voluntary or now - (self.lastFall[ply] or -1e9) < config.cooldown then
		return
	end
	if self:Fall(ply, { cause = "voluntary" }) ~= nil then
		self.lastFall[ply] = now
	end
end

-- A body removed by something else: its player stands up where it lay. A corpse is
-- forgotten.
function M:OnEntityRemoved(ent)
	local entry = self.byEnt[ent]
	if entry == nil then
		return
	end
	self.byEnt[ent] = nil
	if entry.corpse then
		self:_ForgetCorpse(entry)
		return
	end
	local ply = entry.ply
	local pos = entry.last or ent:GetPos()
	local spot = IsValid(ply) and self:_Spot(ply, pos, ent) or nil
	self:_Release(entry, spot or pos, true)
end

function M:OnSpawned(ply)
	self.pending[ply] = nil
	local body = self.bodies[ply]
	if body ~= nil then
		self:_Forget(body)
		if IsValid(body.ent) then
			body.ent:Remove()
		end
		self:_Show(ply, body, true)
	elseif self.hidden[ply] then
		self:_Restore(ply)
	end
	if self.ctx.components.body:Has(ply) then
		self:_Publish(ply, "standing", nil, CurTime())
	end
end

-- Out of the game without dying the usual way (a silent death, spectating).
function M:OnStateChanged(ply, state)
	if state == "alive" then
		return
	end
	self.pending[ply] = nil
	local body = self.bodies[ply]
	if body ~= nil then
		self:_Drop(body)
		self:_Publish(ply, state == "dead" and "dead" or "standing", nil, CurTime())
	elseif state ~= "dead" and self.ctx.components.body:Has(ply) then
		self:_Publish(ply, "standing", nil, CurTime())
	end
end

function M:OnLeft(ply)
	self.pending[ply] = nil
	self.lastFall[ply] = nil
	self.hidden[ply] = nil
	local body = self.bodies[ply]
	if body ~= nil then
		self:_Forget(body)
		if IsValid(body.ent) then
			body.ent:Remove()
		end
	end
end

-- API --------------------------------------------------------------------------------------

-- The body of a player down in it, or nil. Do not modify: ply, ent, state, since, cause,
-- phys (physics objects by bone name), head, pelvis, input (sh_ragdoll.lua), blocked.
function M:Body(ply)
	return self.bodies[ply]
end

-- Every body of a player down in it: ply -> body. Do not modify.
function M:Bodies()
	return self.bodies
end

function M:IsDown(ply)
	return self.bodies[ply] ~= nil
end

-- The corpses, oldest first: { ent, ply, at, settled }. Do not modify.
function M:Corpses()
	return self.corpses
end

-- Console ------------------------------------------------------------------------------------

local function describe(body, now)
	local line = format("  %s: %s for %.1f s (%s), ragdoll #%d", body.ply:Nick(), body.state, now - body.since,
		body.cause, body.ent:EntIndex())
	if body.blocked ~= "none" then
		line = line .. ", cannot get up: " .. body.blocked
	end
	return line
end

function M:RagdollCommand(caller, args)
	if args[1] == nil then
		local config = self.ctx.config
		local now = CurTime()
		local corpses = #self.corpses
		local lines = { format("nc_ragdoll: %d down, %d corpses; ragdolls %d/%d, corpses %d/%d", self.fallen,
			corpses, self.fallen + corpses, config.ragdolls, corpses, max(1, config.corpses)) }
		for _, ply in ipairs(player.GetAll()) do
			local body = self.bodies[ply]
			if body ~= nil then
				lines[#lines + 1] = describe(body, now)
			end
		end
		return lines
	end
	local ply, err = self.players:Find(args[1], caller)
	if ply == nil then
		return "nc_ragdoll: " .. tostring(err)
	end
	local action = args[2]
	if action == "fall" then
		local body, why = self:Fall(ply, { cause = "command" })
		if body == nil then
			return format("nc_ragdoll: %s cannot fall: %s", ply:Nick(), why)
		end
		return format("nc_ragdoll: %s fell", ply:Nick())
	elseif action == "up" then
		local ok, why = self:GetUp(ply, true)
		if not ok then
			return format("nc_ragdoll: %s cannot get up: %s", ply:Nick(), why)
		end
		return format("nc_ragdoll: %s gets up", ply:Nick())
	elseif action ~= nil then
		return "nc_ragdoll: [player] [fall | up]"
	end
	local body = self.bodies[ply]
	if body == nil then
		return format("nc_ragdoll: %s is not down", ply:Nick())
	end
	return { "nc_ragdoll:", describe(body, CurTime()) }
end
