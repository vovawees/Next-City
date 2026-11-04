-- Hands, shared part: the scripted weapon nc_hands on the melee base.
--
-- Its state lives in predicted NetworkVars (with the ones of the base):
--   Raised     the fists are up
--   RaiseTime  when raising or lowering them ends (no attack before)
-- The reload key raises the fists or lowers them. Raised, the attack key punches: an
-- attack of the base (blunt, `energy` J at `reach` units, its windup, recovery and
-- effort), the left and the right in turn; a hand without a working arm sits out. Lowered,
-- nothing is in view: the attack 2 key carries what is ahead and the attack key throws it
-- (the server, sv_hands.lua).

local M = NC.Module("hands")

local CurTime = CurTime
local IsValid = IsValid

M.CLASS = "nc_hands"
-- Sequences of the view model (c_arms).
M.SEQUENCES = { draw = "fists_draw", holster = "fists_holster", left = "fists_left", right = "fists_right" }

-- The methods of the hands; the base gives the rest.
local HANDS = {}
M.HANDS = HANDS
local MELEE -- the methods of the melee base

function M:Init(ctx)
	self.melee = ctx:Require("melee")
	self.organism = ctx:Require("organism")
	self.players = ctx:Require("players")
	MELEE = self.melee.MELEE
	local config = ctx.config
	local punch, problem = self.melee:Attack({ kind = "blunt", energy = config.energy, reach = config.reach,
		windup = config.windup, recovery = config.recovery, stamina = config.stamina,
		sounds = { swing = config.swingSound, hit = config.hitSound, world = config.hitSound } }, "punch")
	if punch == nil then
		ctx.log:Error("bad settings of the punch (%s); using the defaults", problem)
		punch = self.melee:Attack({ kind = "blunt", energy = 50, reach = 40 }, "punch")
	end
	-- The definition the base reads (Def).
	self.def = { class = M.CLASS, hands = 1, draw = 0, primary = punch, sounds = {}, holdType = "normal" }
	self:_Register(config)
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:_Register(config)
	local SWEP = {
		Base = self.melee.BASE,
		PrintName = self:Name(),
		Spawnable = false,
		Slot = 0,
		SlotPos = 0,
		Weight = 0,
		HoldType = "normal",
		ViewModel = config.viewModel,
		WorldModel = "",
		ViewModelFOV = 54,
		UseHands = true,
	}
	for name, fn in pairs(HANDS) do
		SWEP[name] = fn
	end
	weapons.Register(SWEP, M.CLASS)
end

-- The translated name of the hands.
function M:Name()
	local i18n = self.ctx.i18n
	return i18n:Has("hands.name") and i18n:T("hands.name") or "Hands"
end

-- The hands of `ply` when he holds them, or nil.
function M:Active(ply)
	local weapon = IsValid(ply) and ply:GetActiveWeapon() or nil
	if weapon ~= nil and IsValid(weapon) and weapon:GetClass() == M.CLASS then
		return weapon
	end
	return nil
end

-- Whether `ply` holds his fists up.
function M:Raised(ply)
	local hands = self:Active(ply)
	return hands ~= nil and hands:GetRaised()
end

-- The weapon -------------------------------------------------------------------------------

function HANDS:Def()
	return M.def
end

function HANDS:SetupDataTables()
	MELEE.SetupDataTables(self)
	self:NetworkVar("Bool", 0, "Raised")
	self:NetworkVar("Float", 1, "RaiseTime")
end

function HANDS:Initialize()
	self:SetHoldType("normal")
end

function HANDS:Deploy()
	self:SetAttack(0)
	self:SetRaised(false)
	self:SetRaiseTime(0)
	self:SetHoldType("normal")
	return true
end

function HANDS:Holster()
	self:SetAttack(0)
	if SERVER then
		M:Release(self)
	end
	return true
end

function HANDS:OnDrop()
	self:SetAttack(0)
	if SERVER then
		M:Release(self)
	end
end

function HANDS:OnRemove()
	if SERVER then
		M:Release(self)
	end
end

-- Raises the fists or lowers them (over the raise time); whether it did.
function HANDS:Raise(raised)
	if raised == self:GetRaised() or self:GetAttack() ~= 0 then
		return false
	end
	local now = CurTime()
	local time = M.ctx.config.raise
	self:SetRaised(raised)
	self:SetRaiseTime(now + time)
	self:SetNextPrimaryFire(now + time)
	self:SetNextSecondaryFire(now + time)
	self:SetHoldType(raised and "fist" or "normal")
	self:_Sequence(raised and "draw" or "holster", time)
	if SERVER and raised then
		M:Release(self)
	end
	return true
end

-- The reload key, on a press: up or down.
function HANDS:Reload()
	local owner = self:_Player()
	if owner == nil or not owner:KeyPressed(IN_RELOAD) or CurTime() < self:GetRaiseTime() then
		return
	end
	self:Raise(not self:GetRaised())
end

function HANDS:PrimaryAttack()
	if self:GetRaised() then
		self:Swing(1)
	elseif SERVER then
		M:Throw(self)
	end
end

function HANDS:SecondaryAttack()
	if SERVER and not self:GetRaised() then
		M:Grab(self)
	end
end

-- A punch: the left and the right in turn, by the arms that work.
function HANDS:_SwingAnim()
	local owner = self:_Player()
	local caps = owner ~= nil and M.organism:Capabilities(owner) or nil
	local right = self:GetSwings() % 2 == 0
	if caps ~= nil then
		if right and not caps.canUseArmR then
			right = false
		elseif not right and not caps.canUseArmL then
			right = true
		end
	end
	self:_Sequence(right and "right" or "left")
end

function HANDS:Think()
	MELEE.Think(self)
	if SERVER and self.carry ~= nil then
		M:Hold(self)
	end
end

-- Plays the sequence `name` of M.SEQUENCES on the view model, over `duration` s if given.
function HANDS:_Sequence(name, duration)
	local owner = self:_Player()
	local vm = owner ~= nil and owner:GetViewModel() or nil
	if vm == nil or not IsValid(vm) then
		return
	end
	local seq = vm:LookupSequence(M.SEQUENCES[name])
	if seq == nil or seq < 0 then
		return
	end
	vm:SendViewModelMatchingSequence(seq)
	local length = vm:SequenceDuration(seq)
	vm:SetPlaybackRate(duration ~= nil and duration > 0 and length > 0 and length / duration or 1)
end

-- Lowered hands hold nothing in view.
function HANDS:ShouldDrawViewModel()
	return self:GetRaised() or CurTime() < self:GetRaiseTime()
end
