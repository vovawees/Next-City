-- Melee, shared part: the base nc_melee.
--
-- Every weapon of the registry is a scripted weapon on this base; the hands derive from it
-- too. Its state lives in predicted NetworkVars, so the client of the attacker swings with
-- the server:
--   Attack      the attack under way (1 primary, 2 secondary, 0 none)
--   StrikeTime  when it strikes (the end of the windup)
--   Swings      swings so far (bases alternate their anims by it)
-- The attack key swings the primary attack, the attack 2 key the secondary one, again
-- while held. The body counts (organism capabilities): no working arm or unconscious, no
-- swing; a two-handed weapon in one arm swings half again as slow with half the energy.
-- Every swing spends stamina (organism:Exert); without it the strike has 60% of its energy.

local M = NC.Module("melee")

local CurTime = CurTime
local Angle = Angle

local ONE_ARM_TIME = 1.5   -- a two-handed weapon in one arm: the swing takes this much longer
local ONE_ARM_ENERGY = 0.5 -- ...and strikes with this share of the energy
local TIRED_ENERGY = 0.6   -- the share of a swing without the stamina for it
local KICK = 1 / 100       -- degrees the view kicks per J of a strike that hits
local MAX_KICK = 3

-- The methods of the base; the classes of the registry inherit them (weapons.Get).
local MELEE = {}
M.MELEE = MELEE

-- Registers the base (Init, both realms).
function M:_RegisterBase()
	local SWEP = {
		Base = "weapon_base",
		PrintName = "Melee",
		Spawnable = false,
		UseHands = true,
		AutoSwitchTo = false,
		AutoSwitchFrom = false,
		DrawCrosshair = false,
		DrawAmmo = false,
		Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
		Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
	}
	for name, fn in pairs(MELEE) do
		SWEP[name] = fn
	end
	weapons.Register(SWEP, M.BASE)
end

-- The definition of the weapon (the registry); nil for the base itself. Bases on this one
-- may answer their own.
function MELEE:Def()
	local def = self.def
	if def == nil then
		def = M.defs[self:GetClass()]
		self.def = def
	end
	return def
end

function MELEE:SetupDataTables()
	self:NetworkVar("Int", 0, "Attack")
	self:NetworkVar("Int", 1, "Swings")
	self:NetworkVar("Float", 0, "StrikeTime")
end

function MELEE:Initialize()
	local def = self:Def()
	if def ~= nil then
		self:SetHoldType(def.holdType)
	end
end

-- The owner of the weapon when it is a player (the base is for players only).
function MELEE:_Player()
	local owner = self:GetOwner()
	if IsValid(owner) and owner:IsPlayer() then
		return owner
	end
	return nil
end

-- The attack of the key `index` (1 primary, 2 secondary), or nil.
function MELEE:AttackOf(index)
	local def = self:Def()
	if def == nil then
		return nil
	end
	return index == 1 and def.primary or index == 2 and def.secondary or nil
end

-- Whether the body of `owner` lets him swing: awake, a working arm.
function MELEE:CanSwing(owner)
	local caps = M.organism:Capabilities(owner)
	return caps == nil or not caps.unconscious and (caps.canUseArmL or caps.canUseArmR)
end

-- A two-handed weapon in one working arm.
function MELEE:_OneArm(owner)
	local def = self:Def()
	local caps = M.organism:Capabilities(owner)
	return def ~= nil and def.hands == 2 and caps ~= nil and not (caps.canUseArmL and caps.canUseArmR)
end

function MELEE:Deploy()
	local def = self:Def()
	if def == nil then
		return true
	end
	local ready = CurTime() + def.draw
	self:SetAttack(0)
	self:SetNextPrimaryFire(ready)
	self:SetNextSecondaryFire(ready)
	self:SendWeaponAnim(ACT_VM_DRAW)
	self:_Sound(def.sounds.draw)
	return true
end

-- Holstering drops a swing under way.
function MELEE:Holster()
	self:SetAttack(0)
	return true
end

function MELEE:OnDrop()
	self:SetAttack(0)
end

function MELEE:PrimaryAttack()
	self:Swing(1)
end

function MELEE:SecondaryAttack()
	self:Swing(2)
end

function MELEE:Reload() end

-- Starts the attack `index` when the weapon is ready; whether it did.
function MELEE:Swing(index)
	local owner = self:_Player()
	local attack = self:AttackOf(index)
	if owner == nil or attack == nil or self:GetAttack() ~= 0 or not self:CanSwing(owner) then
		return false
	end
	local now = CurTime()
	local slow = self:_OneArm(owner) and ONE_ARM_TIME or 1
	local ready = now + (attack.windup + attack.recovery) * slow
	self:SetAttack(index)
	self:SetStrikeTime(now + attack.windup * slow)
	self:SetSwings(self:GetSwings() + 1)
	self:SetNextPrimaryFire(ready)
	self:SetNextSecondaryFire(ready)
	self:_SwingAnim(attack, index)
	owner:SetAnimation(PLAYER_ATTACK1)
	self:_Sound(attack.sounds.swing)
	if SERVER then
		self.tired = not M.organism:Exert(owner, attack.stamina) and M.organism:IsSimulated(owner)
	end
	return true
end

-- The anim of a swing; bases may alternate it (Swings).
function MELEE:_SwingAnim(attack)
	self:SendWeaponAnim(attack.anims.swing)
end

function MELEE:Think()
	local index = self:GetAttack()
	if index == 0 or CurTime() < self:GetStrikeTime() then
		return
	end
	self:SetAttack(0)
	local owner = self:_Player()
	local attack = self:AttackOf(index)
	if owner == nil or attack == nil or not self:CanSwing(owner) then
		return
	end
	local scale = (self:_OneArm(owner) and ONE_ARM_ENERGY or 1) * (self.tired and TIRED_ENERGY or 1)
	if M:Strike(owner, self, attack, index, scale) ~= nil then
		if attack.anims.hit ~= nil then
			self:SendWeaponAnim(attack.anims.hit)
		end
		-- The blow comes back into the arms.
		owner:ViewPunch(Angle(math.min(MAX_KICK, attack.energy * scale * KICK), 0, 0))
	end
end

-- Plays the sound `name` (or nothing for nil).
function MELEE:_Sound(name)
	if name ~= nil then
		self:EmitSound(name)
	end
end
