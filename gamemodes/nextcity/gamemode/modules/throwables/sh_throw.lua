-- Throwables, shared part: the base nc_throwable.
--
-- Every throwable of the registry is a scripted weapon on this base. Its state lives in
-- predicted NetworkVars, so the client of the thrower runs it with the server:
--   Step      0 ready, 1 pulling the pin, 2 holding it (the pin out), 3 the throw
--   Throw     the throw under way: 1 overhand (the attack key), 2 underhand (attack 2)
--   StepTime  when pulling the pin or the throw ends
--   Fuse      when the thing goes off once the spoon flew off (0: not yet)
-- A press pulls the pin; letting go of the key throws (at once when the pin is out). The
-- reload key lets the spoon go while holding it: the fuse runs in the hand (cooking), and
-- what is not thrown in time goes off there. Putting the weapon away puts the pin back,
-- or drops the thing when its fuse runs. A throw takes one of the ammo; with none left the
-- weapon goes. The body counts: unconscious or without a working arm, no pin is pulled;
-- one arm pulls it twice as slow; without the stamina a throw has 60% of its energy.

local M = NC.Module("throwables")

local CurTime = CurTime
local IsValid = IsValid

local ONE_ARM_PULL = 2 -- one working arm: pulling the pin takes this much longer
local KEYS = { IN_ATTACK, IN_ATTACK2 }

local THROWABLE = {}
M.THROWABLE = THROWABLE

-- Registers the base (Init, both realms).
function M:_RegisterBase()
	local SWEP = {
		Base = "weapon_base",
		PrintName = "Throwable",
		Spawnable = false,
		UseHands = true,
		AutoSwitchTo = false,
		AutoSwitchFrom = false,
		DrawCrosshair = false,
		DrawAmmo = true,
		Primary = { ClipSize = -1, DefaultClip = 0, Automatic = false, Ammo = "none" },
		Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
	}
	for name, fn in pairs(THROWABLE) do
		SWEP[name] = fn
	end
	weapons.Register(SWEP, M.BASE)
end

-- The definition of the weapon (the registry); nil for the base itself.
function THROWABLE:Def()
	local def = self.def
	if def == nil then
		def = M.defs[self:GetClass()]
		self.def = def
	end
	return def
end

function THROWABLE:SetupDataTables()
	self:NetworkVar("Int", 0, "Step")
	self:NetworkVar("Int", 1, "Throw")
	self:NetworkVar("Float", 0, "StepTime")
	self:NetworkVar("Float", 1, "Fuse")
end

function THROWABLE:Initialize()
	local def = self:Def()
	if def ~= nil then
		self:SetHoldType(def.holdType)
	end
end

-- The owner of the weapon when it is a player (the base is for players only).
function THROWABLE:_Player()
	local owner = self:GetOwner()
	if IsValid(owner) and owner:IsPlayer() then
		return owner
	end
	return nil
end

-- How many of the thing `owner` has.
function THROWABLE:Count(owner)
	local def = self:Def()
	return def ~= nil and owner:GetAmmoCount(def.ammo) or 0
end

-- Whether the body of `owner` lets him pull a pin: awake, a working arm.
function THROWABLE:CanThrow(owner)
	local caps = M.organism:Capabilities(owner)
	return caps == nil or not caps.unconscious and (caps.canUseArmL or caps.canUseArmR)
end

function THROWABLE:Deploy()
	local def = self:Def()
	if def == nil then
		return true
	end
	self:SetStep(0)
	self:SetFuse(0)
	self:SetStepTime(CurTime() + def.draw)
	self:SendWeaponAnim(ACT_VM_DRAW)
	self:_Sound(def.sounds.draw)
	return true
end

-- Putting it away puts the pin back, or drops the thing whose fuse runs.
function THROWABLE:Holster()
	self:_LetGo()
	return true
end

function THROWABLE:OnRemove()
	self:_LetGo()
end

function THROWABLE:OnDrop()
	self:_LetGo()
end

function THROWABLE:_LetGo()
	local step = self:GetStep()
	if step ~= 1 and step ~= 2 then
		return
	end
	local owner = self:_Player()
	if SERVER and owner ~= nil and self:GetFuse() > 0 then
		M:_Drop(self, owner)
	end
	self:SetStep(0)
	self:SetFuse(0)
end

function THROWABLE:PrimaryAttack()
	self:Pull(1)
end

function THROWABLE:SecondaryAttack()
	self:Pull(2)
end

-- Starts pulling the pin for the throw `index` (1 overhand, 2 underhand); whether it did.
function THROWABLE:Pull(index)
	local owner = self:_Player()
	local def = self:Def()
	local now = CurTime()
	if owner == nil or def == nil or self:GetStep() ~= 0 or now < self:GetStepTime() or self:Count(owner) <= 0
		or not self:CanThrow(owner) then
		return false
	end
	local caps = M.organism:Capabilities(owner)
	local slow = caps ~= nil and not (caps.canUseArmL and caps.canUseArmR) and ONE_ARM_PULL or 1
	self:SetStep(1)
	self:SetThrow(index)
	self:SetStepTime(now + def.pull * slow)
	self:SendWeaponAnim(def.anims.pull)
	self:_Sound(def.sounds.pin)
	return true
end

-- The reload key while the pin is out lets the spoon go: the fuse runs.
function THROWABLE:Reload()
	local owner = self:_Player()
	local def = self:Def()
	local step = self:GetStep()
	if owner == nil or def == nil or def.fuse == nil or (step ~= 1 and step ~= 2) or self:GetFuse() > 0
		or not owner:KeyPressed(IN_RELOAD) then
		return
	end
	self:SetFuse(CurTime() + def.fuse)
	self:_Sound(def.sounds.spoon)
end

function THROWABLE:Think()
	local owner = self:_Player()
	local def = self:Def()
	if owner == nil or def == nil then
		return
	end
	local now = CurTime()
	local step = self:GetStep()
	local fuse = self:GetFuse()
	if (step == 1 or step == 2) and fuse > 0 and now >= fuse then
		-- Held too long: it goes off in the hand.
		self:SetStep(3)
		self:SetStepTime(now + def.throwTime)
		if SERVER then
			M:_GoOffInHand(self, owner)
		end
		return
	end
	if step == 1 and now >= self:GetStepTime() then
		step = 2
		self:SetStep(2)
	end
	if step == 2 and not owner:KeyDown(KEYS[self:GetThrow()] or IN_ATTACK) then
		self:_Throw(owner, def, now)
		return
	end
	if step == 3 and now >= self:GetStepTime() then
		step = 0
		self:SetStep(0)
		self:SetFuse(0)
		if self:Count(owner) > 0 then
			self:SetStepTime(now + def.draw)
			self:SendWeaponAnim(ACT_VM_DRAW)
		end
	end
	if step == 0 and SERVER and self:Count(owner) <= 0 then
		-- None left: the weapon goes.
		owner:StripWeapon(self:GetClass())
	end
end

-- Throws the thing: the anim and the sound on both realms, the thing on the server.
function THROWABLE:_Throw(owner, def, now)
	local index = self:GetThrow()
	self:SetStep(3)
	self:SetStepTime(now + def.throwTime)
	self:SendWeaponAnim(index == 2 and def.anims.lob or def.anims.throw)
	owner:SetAnimation(PLAYER_ATTACK1)
	self:_Sound(def.sounds.throw)
	if SERVER then
		local fuse = self:GetFuse()
		if fuse <= 0 and def.fuse ~= nil then
			fuse = now + def.fuse
		end
		M:_Thrown(self, owner, index, fuse > 0 and fuse or nil)
	end
	self:SetFuse(0)
end

-- Plays the sound `name` (or nothing for nil).
function THROWABLE:_Sound(name)
	if name ~= nil then
		self:EmitSound(name)
	end
end
