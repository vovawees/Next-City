-- Hands, server part: every deployed player gets them, and what they carry.
--
-- Carrying: lowered hands with the attack 2 key held grab what is ahead within carryReach:
-- a physics prop, or a body (a ragdoll, by the physics bone that was met). While the key
-- is held they pull it to where it was ahead of the eyes with at most `strength` (half
-- with one working arm), and pulling spends stamina: a light thing follows, a heavy one
-- drags, one too heavy stays. Letting go of the key, raising the fists, losing the arms or
-- the stamina for a heavy pull, standing on it, or a thing left behind out of reach (a
-- quarter past carryReach) drops it; the attack key throws it with throwEnergy J (at most
-- throwSpeed units/s).
--
-- Queries:  hands.grab (ply, ent) → false: it may not be grabbed (protected props)
-- Emits:    hands.grabbed (ply, ent), hands.dropped (ply, ent, thrown)
-- Listens:  players.loadout (early: the hands first)

local M = NC.Module("hands")

local IsValid = IsValid
local sqrt = math.sqrt
local min = math.min
local max = math.max

local GAIN = 10         -- 1/s: the hands close this share of the gap to where they hold a second
local MAX_SPEED = 300   -- units/s the hands move a thing at most
local MIN_DISTANCE = 24 -- units from the eyes a thing is held at least
local SPIN = 0.5        -- share of the spin of a held thing the hands stop every tick
local LOSE = 1.25       -- a thing this many times carryReach from the eyes slips out of the hands
local UNIT = 0.0254     -- m per unit

function M:_InitServer(ctx)
	self.trace = {}
	ctx:On("players.loadout", "OnLoadout", { priority = 90 })
end

function M:OnLoadout(ply)
	if self.ctx.config.give and not ply:HasWeapon(M.CLASS) then
		ply:Give(M.CLASS)
	end
end

-- The share of the strength of the arms of `ply` that work (1, 0.5 or 0).
function M:_Arms(ply)
	local caps = self.organism:Capabilities(ply)
	if caps == nil then
		return 1
	end
	return ((caps.canUseArmL and 1 or 0) + (caps.canUseArmR and 1 or 0)) / 2
end

-- What the hands of `ply` carry, or nil.
function M:Carried(ply)
	local hands = self:Active(ply)
	local carry = hands ~= nil and hands.carry or nil
	return carry ~= nil and carry.ent or nil
end

-- The mass of every physics object of `ent`, kg.
local function massOf(ent)
	local total = 0
	for i = 0, ent:GetPhysicsObjectCount() - 1 do
		local phys = ent:GetPhysicsObjectNum(i)
		if IsValid(phys) then
			total = total + phys:GetMass()
		end
	end
	return total
end

-- The hands grab what is ahead; whether they hold something.
function M:Grab(hands)
	if hands.carry ~= nil then
		return true
	end
	local owner = hands:_Player()
	if owner == nil or not hands:CanSwing(owner) then
		return false
	end
	local config = self.ctx.config
	local start = owner:GetShootPos()
	local trace = self.trace
	trace.start, trace.endpos, trace.filter, trace.mask = start, start + owner:GetAimVector() * config.carryReach,
		owner, MASK_SHOT
	local tr = util.TraceLine(trace)
	local ent = tr.Entity
	if not tr.Hit or not IsValid(ent) or ent:IsPlayer() or ent:IsNPC() or ent:IsWeapon() then
		return false
	end
	local phys = ent:GetPhysicsObjectNum(tr.PhysicsBone or 0)
	if not IsValid(phys) or not phys:IsMotionEnabled() then
		return false
	end
	if self.ctx.events:Query("hands.grab", owner, ent) == false then
		return false
	end
	local distance = (phys:GetPos() - start):Length()
	hands.carry = { ent = ent, phys = phys, distance = max(MIN_DISTANCE, min(config.carryReach, distance)) }
	self.ctx.events:Emit("hands.grabbed", owner, ent)
	return true
end

-- The hands pull what they carry (every command of their owner while they carry).
function M:Hold(hands)
	local carry = hands.carry
	local owner = hands:_Player()
	local ent, phys = carry.ent, carry.phys
	if owner == nil or not IsValid(ent) or not IsValid(phys) or hands:GetRaised() or not owner:KeyDown(IN_ATTACK2)
		or not hands:CanSwing(owner) or owner:GetGroundEntity() == ent then
		self:Release(hands)
		return
	end
	local arms = self:_Arms(owner)
	local config = self.ctx.config
	local eyes = owner:GetShootPos()
	local pos = phys:GetPos()
	if arms <= 0 or (pos - eyes):Length() > config.carryReach * LOSE then
		self:Release(hands)
		return
	end
	-- One pull a tick of physics, however many commands of the owner the tick runs.
	local tick = engine.TickCount()
	if carry.tick == tick then
		return
	end
	carry.tick = tick
	local gap = eyes + owner:GetAimVector() * carry.distance - pos
	local dt = engine.TickInterval()
	local desired = gap * GAIN
	local speed = desired:Length()
	if speed > MAX_SPEED then
		desired = desired * (MAX_SPEED / speed)
	end
	-- The impulse that gives it the velocity, within the strength of the arms.
	local impulse = (desired - phys:GetVelocity()) * phys:GetMass()
	local most = config.strength * arms * dt
	local size = impulse:Length()
	if size > most then
		impulse = impulse * (most / size)
		size = most
	end
	-- Pulling hard tires; without the stamina for it the hands give up (a light thing
	-- stays in them).
	if not self.organism:Exert(owner, size / config.strength * config.carryStamina) and size > most * 0.5
		and self.organism:IsSimulated(owner) then
		self:Release(hands)
		return
	end
	phys:Wake()
	phys:ApplyForceCenter(impulse)
	phys:AddAngleVelocity(phys:GetAngleVelocity() * -SPIN)
end

-- The hands throw what they carry along the aim; whether they did.
function M:Throw(hands)
	local carry = hands.carry
	local owner = hands:_Player()
	if carry == nil or owner == nil or not IsValid(carry.ent) then
		return false
	end
	local config = self.ctx.config
	local ent = carry.ent
	local mass = massOf(ent)
	-- The energy of the throw in the mass of the thing: E = m·v²/2.
	local speed = config.throwSpeed
	if mass > 0 then
		speed = min(speed, sqrt(2 * config.throwEnergy * self:_Arms(owner) / mass) / UNIT)
	end
	local push = owner:GetAimVector() * speed
	for i = 0, ent:GetPhysicsObjectCount() - 1 do
		local phys = ent:GetPhysicsObjectNum(i)
		if IsValid(phys) then
			phys:Wake()
			phys:AddVelocity(push)
		end
	end
	self.organism:Exert(owner, config.stamina)
	owner:SetAnimation(PLAYER_ATTACK1)
	self:Release(hands, true)
	return true
end

-- The hands let go of what they carry.
function M:Release(hands, thrown)
	local carry = hands.carry
	if carry == nil then
		return
	end
	hands.carry = nil
	local owner = hands:GetOwner()
	self.ctx.events:Emit("hands.dropped", owner, carry.ent, thrown == true)
end
