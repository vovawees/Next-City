-- Weapons, shared part: the firearm base nc_firearm.
--
-- Every weapon of the registry is a scripted weapon on this base. Its state lives in
-- predicted NetworkVars, so the client of the shooter runs the same code as the server
-- and both agree:
--   State, StateEnd     idle, draw, reload (a magazine), starting, loading, finishing (a
--                       reload of single rounds), and when the current one ends
--   Mode, Burst, Fired  the fire mode (an index of def.modes), rounds left of a burst and
--                       whether the trigger is held since the last shot (semi and burst
--                       fire again after it is released)
--   Heat, HeatTime      the bloom of the last shots (fading at recoil.recovery per s) and
--                       the time of the last shot
--   Aiming, AimFrom, AimStart  the sights rise (or go down) from AimFrom at AimStart
--   Loaded, Reloading   the engine ammo types in the weapon and of the reload under way
--   Stop                a reload of single rounds ends after the round in hand
-- The engine calls PrimaryAttack while the attack key is held (Primary.Automatic is
-- true for all): the trigger discipline of the modes is here. A shot goes along the view
-- with its punch and the sway of the aim, in a cone of spread (degrees): the barrel
-- (accuracy, MOA) + the hip spread by how far the sights are from the eye + movement +
-- bloom, by the stance and the arms. The body of the shooter counts (organism
-- capabilities): no working arm, no shooting; one arm for a two-handed weapon, twice the
-- spread and sway; aimSway sways the aim, recoilMul multiplies the recoil. The recoil
-- punches the view on both realms and climbs it on the client of the shooter (on the
-- server for bots and single player). The attack 2 key raises the sights, the reload key
-- reloads, with the use key it switches the fire mode. Sprinting lowers the weapon.

local M = NC.Module("weapons")

local CurTime = CurTime
local IsValid = IsValid
local IsFirstTimePredicted = IsFirstTimePredicted
local Angle = Angle
local exp = math.exp
local sin = math.sin
local cos = math.cos
local min = math.min
local max = math.max
local sqrt = math.sqrt

local IDLE, DRAW, RELOAD, STARTING, LOADING, FINISHING = 0, 1, 2, 3, 4, 5
M.STATES = { idle = IDLE, draw = DRAW, reload = RELOAD, starting = STARTING, loading = LOADING,
	finishing = FINISHING }

local DRY_FIRE = 0.2   -- s between clicks of an empty weapon
local BASE_SWAY = 0.12 -- degrees of sway of a healthy, aimed shooter
local BODY_SWAY = 2    -- degrees more at the full sway of the body

-- The methods of the base; the classes of the registry inherit them (weapons.Get).
local FIREARM = {}
M.FIREARM = FIREARM

-- Registers the base (Init, both realms).
function M:_RegisterBase()
	local config = self.ctx.config
	local SWEP = {
		Base = "weapon_base",
		PrintName = "Firearm",
		Spawnable = false,
		UseHands = true,
		AutoSwitchTo = false,
		AutoSwitchFrom = false,
		DrawCrosshair = config.crosshair,
		DrawAmmo = config.ammoCounter,
		Primary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
		Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
	}
	for name, fn in pairs(FIREARM) do
		SWEP[name] = fn
	end
	weapons.Register(SWEP, M.BASE)
end

-- The definition of the weapon (the registry); nil for the base itself.
function FIREARM:Def()
	local def = self.def
	if def == nil then
		def = M.defs[self:GetClass()]
		self.def = def
	end
	return def
end

function FIREARM:SetupDataTables()
	self:NetworkVar("Int", 0, "State")
	self:NetworkVar("Int", 1, "Mode")
	self:NetworkVar("Int", 2, "Burst")
	self:NetworkVar("Int", 3, "Loaded")
	self:NetworkVar("Int", 4, "Reloading")
	self:NetworkVar("Float", 0, "StateEnd")
	self:NetworkVar("Float", 1, "Heat")
	self:NetworkVar("Float", 2, "HeatTime")
	self:NetworkVar("Float", 3, "AimFrom")
	self:NetworkVar("Float", 4, "AimStart")
	self:NetworkVar("Bool", 0, "Fired")
	self:NetworkVar("Bool", 1, "Aiming")
	self:NetworkVar("Bool", 2, "Stop")
end

function FIREARM:Initialize()
	local def = self:Def()
	if def ~= nil then
		self:SetHoldType(def.holdType)
	end
end

-- State --------------------------------------------------------------------------------

function FIREARM:_SetState(state, ends)
	self:SetState(state)
	self:SetStateEnd(ends)
end

-- The index of the fire mode in def.modes.
function FIREARM:ModeIndex()
	local index = self:GetMode()
	return self.def.modes[index] ~= nil and index or 1
end

-- The fire mode: "semi", "burst" or "auto".
function FIREARM:FireMode()
	return self.def.modes[self:ModeIndex()]
end

-- The ammo type (id) of the rounds in the weapon.
function FIREARM:LoadedAmmo()
	local id = self:GetLoaded()
	return id > 0 and game.GetAmmoName(id) or self.def.ammo
end

-- How far the sights are raised at `now`, 0 (the hip) to 1.
function FIREARM:AimFraction(now)
	local def = self.def
	if def == nil then
		return 0
	end
	local from, t = self:GetAimFrom(), def.aimTime > 0 and (now - self:GetAimStart()) / def.aimTime or 1
	if self:GetAiming() then
		return min(1, from + t)
	end
	return max(0, from - t)
end

function FIREARM:_Aim(on, now)
	self:SetAimFrom(self:AimFraction(now))
	self:SetAimStart(now)
	self:SetAiming(on)
end

-- The bloom of the last shots at `now`.
function FIREARM:HeatAt(now)
	local heat = self:GetHeat()
	if heat <= 0 then
		return 0
	end
	return heat * exp(-self.def.recoil.recovery * max(0, now - self:GetHeatTime()))
end

-- Whether the body of `owner` lets him shoot: a working arm, awake, not sprinting.
function FIREARM:CanFire(owner)
	local caps = M.organism:Capabilities(owner)
	if caps ~= nil and (caps.unconscious or not caps.canUseArmL and not caps.canUseArmR) then
		return false
	end
	return not M:Sprinting(owner)
end

-- Whether `owner` can raise the sights now.
function FIREARM:CanAim(owner)
	return self:GetState() == IDLE and self:CanFire(owner)
end

-- A two-handed weapon in one working hand.
function FIREARM:_OneArm(caps)
	return caps ~= nil and self.def.hands == 2 and not (caps.canUseArmL and caps.canUseArmR)
end

-- The spread of a shot at `now`, degrees: the cone around the aim.
function FIREARM:Spread(owner, now, caps, heat)
	local def = self.def
	local moving = min(sqrt(owner:GetVelocity():Length2DSqr()) / max(owner:GetWalkSpeed(), 1), 1.5)
	local spread = def.accuracy / 60 + def.hipSpread * (1 - self:AimFraction(now)) + def.moveSpread * moving
		+ def.recoil.bloom * (heat or self:HeatAt(now))
	if not owner:IsOnGround() then
		spread = spread + def.moveSpread * 2
	end
	if owner:Crouching() then
		spread = spread * 0.8
	end
	if self:_OneArm(caps) then
		spread = spread * 2
	end
	return spread * M.ctx.config.spread
end

-- The sway of the aim of `owner` at `now`: pitch and yaw, degrees. Smooth and the same on
-- every realm: breathing and the tremor of the hands as sines of the time in the phase of
-- the player; more from the hip, with the sway of the body and in one arm.
function FIREARM:SwayAt(owner, now, caps)
	local def = self.def
	local amount = (BASE_SWAY + BODY_SWAY * (caps and caps.aimSway or 0)) * (3 - 2 * self:AimFraction(now)) * def.sway
		* M.ctx.config.sway
	if owner:Crouching() then
		amount = amount * 0.7
	end
	if self:_OneArm(caps) then
		amount = amount * 2
	end
	local phase = owner:EntIndex() * 2.39996
	local pitch = 0.7 * sin(now * 1.3 + phase) + 0.3 * sin(now * 3.1 + phase * 1.7)
	local yaw = 0.6 * sin(now * 0.9 + phase * 2.3) + 0.4 * cos(now * 2.2 + phase)
	return pitch * amount, yaw * amount
end

-- The engine ------------------------------------------------------------------------------

function FIREARM:Deploy()
	local def = self:Def()
	if def == nil then
		return true
	end
	local now = CurTime()
	self:_SetState(DRAW, now + def.draw)
	self:_Aim(false, now)
	self:SetAimFrom(0)
	self:SetFired(false)
	self:SetBurst(0)
	self:SetStop(false)
	self:_Anim("draw", def.draw)
	self:_Sound("draw")
	return true
end

-- Holstering puts the sights down and drops a reload under way (its rounds stay).
function FIREARM:Holster()
	if self:Def() ~= nil then
		self:_SetState(IDLE, 0)
		self:SetAiming(false)
		self:SetAimFrom(0)
		self:SetStop(false)
	end
	return true
end

function FIREARM:OnDrop()
	self:Holster()
end

-- The owner of the weapon when it is a player (the base is for players only).
function FIREARM:_Player()
	local owner = self:GetOwner()
	return IsValid(owner) and owner:IsPlayer() and owner or nil
end

function FIREARM:Think()
	local def = self:Def()
	local owner = self:_Player()
	if def == nil or owner == nil then
		return
	end
	local now = CurTime()
	if not owner:KeyDown(IN_ATTACK) then
		if self:GetFired() then
			self:SetFired(false)
		end
		if self:GetBurst() ~= 0 then
			self:SetBurst(0)
		end
	end
	self:_Update(owner, def, now)
	local aim = owner:KeyDown(IN_ATTACK2) and self:CanAim(owner)
	if aim ~= self:GetAiming() then
		self:_Aim(aim, now)
	end
end

-- Ends the states that are over at `now` (several, if the weapon did not think for long).
function FIREARM:_Update(owner, def, now)
	for _ = 1, 16 do
		local state = self:GetState()
		if state == IDLE or now < self:GetStateEnd() then
			return
		end
		self:_End(owner, def, state, now)
	end
end

function FIREARM:_End(owner, def, state, now)
	if state == RELOAD then
		local clip = self:Clip1()
		local chambered = def.chamber and clip > 0 and 1 or 0
		self:_Load(owner, def.magazine + chambered - clip)
		self:_SetState(IDLE, 0)
	elseif state == STARTING then
		self:_SetState(LOADING, self:GetStateEnd() + def.reload)
		self:_Anim("reloadInsert", def.reload)
	elseif state == LOADING then
		local id = self:_Load(owner, 1)
		if id ~= nil and not self:GetStop() and self:Clip1() < def.capacity and M:CountAmmo(owner, self, id) > 0 then
			self:_SetState(LOADING, self:GetStateEnd() + def.reload)
			self:_Anim("reloadInsert", def.reload)
		elseif def.reloadEnd > 0 then
			self:_SetState(FINISHING, now + def.reloadEnd)
			self:_Anim("reloadEnd", def.reloadEnd)
		else
			self:_SetState(IDLE, 0)
		end
	else
		self:_SetState(IDLE, 0)
	end
end

-- Up to `count` rounds of the reload under way go into the weapon; their type, or nil if
-- none came.
function FIREARM:_Load(owner, count)
	local id = game.GetAmmoName(self:GetReloading())
	if id == nil or count <= 0 then
		return nil
	end
	local taken = M:TakeAmmo(owner, self, id, count)
	if taken <= 0 then
		return nil
	end
	self:SetClip1(self:Clip1() + taken)
	self:SetLoaded(self:GetReloading())
	return id
end

function FIREARM:PrimaryAttack()
	local def = self:Def()
	local owner = self:_Player()
	if def == nil or owner == nil then
		return
	end
	local now = CurTime()
	self:_Update(owner, def, now)
	local state = self:GetState()
	if state == STARTING or state == LOADING then
		self:SetStop(true)
		return
	end
	if state ~= IDLE or not self:CanFire(owner) then
		return
	end
	local mode, fired, burst = self:FireMode(), self:GetFired(), self:GetBurst()
	if fired and mode ~= "auto" and not (mode == "burst" and burst > 0) then
		return
	end
	if self:Clip1() <= 0 then
		if not fired then
			self:SetFired(true)
			self:SetNextPrimaryFire(now + DRY_FIRE)
			self:_Anim("empty")
			self:_Sound("empty")
		end
		return
	end
	if not fired and mode == "burst" then
		burst = def.burst
	end
	self:SetBurst(max(0, burst - 1))
	self:SetFired(true)
	self:_Shoot(owner, def, now)
end

-- Aiming is the attack 2 key held (Think).
function FIREARM:SecondaryAttack() end

function FIREARM:Reload()
	local def = self:Def()
	local owner = self:_Player()
	if def == nil or owner == nil then
		return
	end
	if owner:KeyDown(IN_USE) then
		if owner:KeyPressed(IN_RELOAD) then
			self:SwitchMode()
		end
		return
	end
	self:_Update(owner, def, CurTime())
	self:StartReload()
end

-- Starts a reload when the weapon is idle, has room and there are rounds for it; whether
-- it did.
function FIREARM:StartReload()
	local def = self:Def()
	local owner = self:_Player()
	if def == nil or owner == nil or self:GetState() ~= IDLE then
		return false
	end
	local clip = self:Clip1()
	local caps = M.organism:Capabilities(owner)
	if clip >= def.capacity or caps ~= nil and (caps.unconscious or not caps.canUseArmL and not caps.canUseArmR) then
		return false
	end
	local id = M:ReloadAmmo(owner, self)
	if id == nil then
		return false
	end
	local now = CurTime()
	self:SetReloading(game.GetAmmoID(id))
	self:SetStop(false)
	self:_Aim(false, now)
	if def.reloadMode == "single" then
		if def.reloadStart > 0 then
			self:_SetState(STARTING, now + def.reloadStart)
			self:_Anim("reloadStart", def.reloadStart)
		else
			self:_SetState(LOADING, now + def.reload)
			self:_Anim("reloadInsert", def.reload)
		end
		self:_Sound("reload")
	else
		local empty = clip == 0
		local time = empty and def.reloadEmpty or def.reload
		self:_SetState(RELOAD, now + time)
		self:_Anim(empty and "reloadEmpty" or "reload", time)
		self:_Sound(empty and "reloadEmpty" or "reload")
	end
	owner:SetAnimation(PLAYER_RELOAD)
	return true
end

-- The next fire mode of def.modes; whether it switched.
function FIREARM:SwitchMode()
	local def = self:Def()
	if def == nil or #def.modes < 2 or self:GetState() ~= IDLE then
		return false
	end
	self:SetMode(self:ModeIndex() % #def.modes + 1)
	self:SetBurst(0)
	self:_Sound("mode")
	self:_ModeChanged()
	return true
end

-- The client shows the new mode (cl_firearm.lua).
function FIREARM:_ModeChanged() end

-- Shots ------------------------------------------------------------------------------------

function FIREARM:_Shoot(owner, def, now)
	local caps = M.organism:Capabilities(owner)
	local heat = self:HeatAt(now)
	local spread = self:Spread(owner, now, caps, heat)
	local pitch, yaw = self:SwayAt(owner, now, caps)
	local p, y, r = (owner:EyeAngles() + owner:GetViewPunchAngles()):Unpack()
	local dir = Angle(p + pitch, y + yaw, r):Forward()
	local ammoId = self:LoadedAmmo()
	self:SetClip1(self:Clip1() - 1)
	self:SetNextPrimaryFire(now + def.interval)
	self:SetHeat(heat + 1)
	self:SetHeatTime(now)
	self:SetLastShootTime(now)
	M:_Discharge(self, owner, dir, spread, ammoId)
	self:_Kick(owner, def, caps)
	self:_Anim(self:Clip1() == 0 and "fireLast" or "fire")
	owner:MuzzleFlash()
	owner:SetAnimation(PLAYER_ATTACK1)
	self:_Sound("fire")
end

-- The recoil of a shot: the punch of the view (both realms) and the climb of the aim,
-- where the eye angles of the shooter are made: his client, the server for bots and in
-- single player.
function FIREARM:_Kick(owner, def, caps)
	local recoil = def.recoil
	local scale = M.ctx.config.recoil * (caps and caps.recoilMul or 1) * (owner:Crouching() and 0.8 or 1)
	local up = recoil.up * scale
	local side = recoil.side * scale * util.SharedRandom("nc_recoil", -1, 1)
	owner:ViewPunch(Angle(-up * recoil.punch, side * recoil.punch, 0))
	local climbs
	if CLIENT then
		climbs = IsFirstTimePredicted()
	else
		climbs = owner:IsBot() or game.SinglePlayer()
	end
	if climbs then
		local p, y, r = owner:EyeAngles():Unpack()
		owner:SetEyeAngles(Angle(max(-89, p - up), y + side, r))
	end
	self:_Kicked()
end

-- The client kicks the viewmodel back (cl_firearm.lua).
function FIREARM:_Kicked() end

-- Plays the anim `name` of def.anims, stretched over `duration` s if given.
function FIREARM:_Anim(name, duration)
	local act = self.def.anims[name]
	if act == nil then
		return
	end
	self:SendWeaponAnim(act)
	local owner = self:_Player()
	local vm = owner ~= nil and owner:GetViewModel() or nil
	if vm ~= nil and IsValid(vm) then
		vm:SetPlaybackRate(1)
		local length = duration ~= nil and duration > 0 and vm:SequenceDuration() or 0
		if length > 0 then
			vm:SetPlaybackRate(length / duration)
		end
	end
end

-- Plays the sound `name` of def.sounds.
function FIREARM:_Sound(name)
	local sound = self.def.sounds[name]
	if sound ~= nil then
		self:EmitSound(sound)
	end
end
