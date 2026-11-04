-- Weapons, shared part: the registry of the weapons of packages.
--
-- Packages register their weapons in Init of their module, after their rounds (both
-- realms, in the same order): Register(class, def) makes the scripted weapon `class` on
-- the base nc_firearm (sh_firearm.lua). A definition is data; all but caliber and
-- magazine have defaults:
--   caliber      rounds of this caliber fit (the ammo module); ammo: the type it is
--                loaded with by default (the first one of the caliber)
--   magazine     rounds of a full magazine; chamber: one more in the chamber of a closed
--                bolt (true; false for open bolts and revolvers)
--   rpm          rounds per minute of the action (600)
--   modes        fire modes a switch goes through, the first one to start with: "semi",
--                "burst", "auto" ({ "semi" }); burst: rounds of a burst (3)
--   velocity     multiplier of the muzzle velocity of the rounds: the barrel (1)
--   accuracy     MOA: the spread of the barrel itself (2)
--   hipSpread    degrees: the spread of a shot from the hip (3); moveSpread: added at the
--                full walking speed, twice in the air (2)
--   sway         multiplier of the sway of the aim: weight and balance (1)
--   recoil       { up = degrees the view climbs a shot (1), side = degrees either way
--                (0.3), punch = the kick of the view, a share of them (0.5), bloom =
--                degrees of spread a shot adds (0.25), recovery = 1/s the bloom fades
--                at (4), kick = units the viewmodel jumps back (1) }
--   aimTime      s to raise the sights (0.3); sights: { pos = Vector (right, forward,
--                up), ang = Angle or Vector (turns about the right, up and forward axes
--                of the view), fov = the share of the view left (0.8) } of the viewmodel
--   draw         s to draw it (0.6)
--   reloadMode   "magazine" or "single": rounds one by one (tubes, cylinders)
--   reload       s: a magazine change (2.5) or one round when single; reloadEmpty: of an
--                empty weapon, the bolt to close too (reload); reloadStart, reloadEnd: s
--                before the first round and after the last one when single (0)
--   hands        2, or 1: a one-handed weapon is as good in one hand
--   sounds       { fire, empty, reload, reloadEmpty, draw, mode } (sound names)
--   anims        ACT_VM_* of { fire, fireLast, empty, draw, reload, reloadEmpty,
--                reloadStart, reloadInsert, reloadEnd }
--   holdType, viewModel, worldModel, viewModelFOV, viewModelFlip, useHands, slot, slotPos,
--   weight       as in the engine
--   name         the key of the translated name ("weapons.<class>")
-- The rounds of reloads come from an ammo source: the engine reserve of the player by
-- default (GiveAmmo), predicted by his client; SetAmmoSource replaces it (an inventory).
--
-- Emits:    weapons.fired (owner, weapon, ammoId)  server, every shot
-- Commands: nc_weapons, nc_give <player> <class> [reserve] (sv_weapons.lua).

local M = NC.Module("weapons")

local format = string.format
local floor = math.floor
local min = math.min
local sin = math.sin
local rad = math.rad
local IsValid = IsValid

M.BASE = "nc_firearm"
M.MODES = { semi = true, burst = true, auto = true }

local NUMBERS = { rpm = 600, velocity = 1, accuracy = 2, hipSpread = 3, moveSpread = 2, sway = 1, aimTime = 0.3,
	draw = 0.6, reload = 2.5, reloadStart = 0, reloadEnd = 0 }
local RECOIL = { up = 1, side = 0.3, punch = 0.5, bloom = 0.25, recovery = 4, kick = 1 }
local RELOAD_MODES = { magazine = true, single = true }
local SIGHTS_FOV = 0.8
local ANIMS = { fire = ACT_VM_PRIMARYATTACK, empty = ACT_VM_DRYFIRE, draw = ACT_VM_DRAW, reload = ACT_VM_RELOAD,
	reloadStart = ACT_SHOTGUN_RELOAD_START, reloadInsert = ACT_VM_RELOAD, reloadEnd = ACT_SHOTGUN_RELOAD_FINISH }
local SOUNDS = { empty = "Weapon_Pistol.Empty" }
local ENTITY_DAMAGE = 0.04 -- engine damage per J of engine bullets (without ballistics)

-- The engine reserve of the owner: the default ammo source.
local ENGINE_AMMO = {}
function ENGINE_AMMO.Count(ply, _, id)
	return ply:GetAmmoCount(id)
end
function ENGINE_AMMO.Take(ply, _, id, count)
	local taken = min(count, ply:GetAmmoCount(id))
	if taken > 0 then
		ply:RemoveAmmo(taken, id)
	end
	return taken
end
M.ENGINE_AMMO = ENGINE_AMMO

function M:Init(ctx)
	self.ammo = ctx:Require("ammo")
	self.organism = ctx:Require("organism")
	self.players = ctx:Require("players")
	self.ballistics = ctx:Require("ballistics")
	self.defs = {}  -- class -> definition
	self.order = {} -- classes in the order of registration
	self.source = ENGINE_AMMO
	self:_RegisterBase()
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

local function fail(class, message)
	error(format("weapons: Register('%s'): %s", tostring(class), message), 3)
end

-- Fills the defaults of definition `e` in place; a problem, or nil.
function M:_Check(e)
	local calibers = type(e.caliber) == "string" and self.ammo:OfCaliber(e.caliber) or {}
	if #calibers == 0 then
		return format("caliber %s has no rounds (ammo:Register them first)", tostring(e.caliber))
	end
	e.ammo = e.ammo or calibers[1]
	local round = self.ammo:Get(e.ammo)
	if round == nil or round.caliber ~= e.caliber then
		return format("ammo %s is not a round of caliber %s", tostring(e.ammo), e.caliber)
	end
	if type(e.magazine) ~= "number" or e.magazine < 1 or e.magazine ~= floor(e.magazine) then
		return "magazine must be a whole number >= 1"
	end
	for field, default in pairs(NUMBERS) do
		local value = e[field]
		if value == nil then
			e[field] = default
		elseif type(value) ~= "number" or value < 0 then
			return field .. " must be a number >= 0"
		end
	end
	if e.rpm <= 0 then
		return "rpm must be a number > 0"
	end
	e.reloadEmpty = e.reloadEmpty or e.reload
	if type(e.reloadEmpty) ~= "number" or e.reloadEmpty < 0 then
		return "reloadEmpty must be a number >= 0"
	end
	local modes, seen = e.modes or { "semi" }, {}
	if type(modes) ~= "table" or #modes == 0 then
		return "modes must be a list of semi, burst, auto"
	end
	for _, mode in ipairs(modes) do
		if not M.MODES[mode] or seen[mode] then
			return "modes must be a list of semi, burst, auto, each once"
		end
		seen[mode] = true
	end
	e.modes = { unpack(modes) }
	e.burst = e.burst or 3
	if type(e.burst) ~= "number" or e.burst < 2 or e.burst ~= floor(e.burst) then
		return "burst must be a whole number >= 2"
	end
	e.hands = e.hands or 2
	if e.hands ~= 1 and e.hands ~= 2 then
		return "hands must be 1 or 2"
	end
	e.reloadMode = e.reloadMode or "magazine"
	if not RELOAD_MODES[e.reloadMode] then
		return "reloadMode must be magazine or single"
	end
	return self:_CheckTables(e)
end

local function merge(defaults, given, kind)
	if given ~= nil and type(given) ~= "table" then
		return nil, kind .. " must be a table"
	end
	local out = {}
	for key, value in pairs(defaults) do
		out[key] = value
	end
	for key, value in pairs(given or {}) do
		out[key] = value
	end
	return out
end

-- The recoil, sights, sounds and anims of definition `e`; a problem, or nil.
function M:_CheckTables(e)
	local recoil, problem = merge(RECOIL, e.recoil, "recoil")
	if recoil == nil then
		return problem
	end
	for field in pairs(RECOIL) do
		if type(recoil[field]) ~= "number" or recoil[field] < 0 then
			return "recoil." .. field .. " must be a number >= 0"
		end
	end
	e.recoil = recoil
	if e.sights ~= nil then
		if type(e.sights) ~= "table" then
			return "sights must be a table"
		end
		local fov = e.sights.fov or SIGHTS_FOV
		if type(fov) ~= "number" or fov <= 0 or fov > 1 then
			return "sights.fov must be a number over 0 and up to 1"
		end
		e.sights = { pos = e.sights.pos, ang = e.sights.ang, fov = fov }
	end
	e.sounds, problem = merge(SOUNDS, e.sounds, "sounds")
	if e.sounds == nil then
		return problem
	end
	e.anims, problem = merge(ANIMS, e.anims, "anims")
	if e.anims == nil then
		return problem
	end
	e.anims.fireLast = e.anims.fireLast or e.anims.fire
	e.anims.reloadEmpty = e.anims.reloadEmpty or e.anims.reload
	return nil
end

-- Registers or replaces the weapon `class` of a package (see the top of the file): the
-- definition (a copy) and its scripted weapon. Returns the definition.
function M:Register(class, def)
	if type(class) ~= "string" or not class:find("^[%l%d_]+$") or class == M.BASE then
		fail(class, "class must be a string of lowercase letters, digits and _ (not the base)")
	end
	if type(def) ~= "table" then
		fail(class, "def must be a table")
	end
	local entry = {}
	for key, value in pairs(def) do
		entry[key] = value
	end
	local problem = self:_Check(entry)
	if problem ~= nil then
		fail(class, problem)
	end
	entry.class = class
	entry.name = entry.name or "weapons." .. class
	entry.chamber = entry.chamber ~= false
	entry.capacity = entry.magazine + (entry.chamber and 1 or 0)
	entry.interval = 60 / entry.rpm
	entry.holdType = entry.holdType or (entry.hands == 1 and "pistol" or "ar2")
	if self.defs[class] == nil then
		self.order[#self.order + 1] = class
	end
	self.defs[class] = entry
	weapons.Register(self:_Class(entry), class)
	-- Weapons of the class that exist (an autorefresh) take the new definition.
	for _, weapon in ipairs(ents.FindByClass(class)) do
		weapon.def = nil
	end
	return entry
end

-- The scripted weapon of definition `def`: what the engine reads of the table.
function M:_Class(def)
	return {
		Base = M.BASE,
		PrintName = self:Name(def.class),
		Slot = def.slot or (def.hands == 1 and 1 or 2),
		SlotPos = def.slotPos or 0,
		Weight = def.weight or 5,
		HoldType = def.holdType,
		ViewModel = def.viewModel,
		WorldModel = def.worldModel,
		ViewModelFOV = def.viewModelFOV,
		ViewModelFlip = def.viewModelFlip,
		UseHands = def.useHands,
		Primary = { ClipSize = def.capacity, DefaultClip = def.capacity, Automatic = true, Ammo = def.ammo },
		Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = true, Ammo = "none" },
	}
end

-- The definition of the weapon `class` (do not modify), or nil.
function M:Get(class)
	return class ~= nil and self.defs[class] or nil
end

-- Classes of every registered weapon, in the order of registration (a new list).
function M:All()
	local out = {}
	for i, class in ipairs(self.order) do
		out[i] = class
	end
	return out
end

-- Whether `weapon` is a firearm of the registry.
function M:IsFirearm(weapon)
	return IsValid(weapon) and self.defs[weapon:GetClass()] ~= nil
end

-- The translated name of the weapon `class` (the class without a translation).
function M:Name(class)
	local def = self.defs[class]
	local key = def ~= nil and def.name or "weapons." .. tostring(class)
	local i18n = self.ctx.i18n
	return i18n:Has(key) and i18n:T(key) or tostring(class)
end

-- Ammunition ------------------------------------------------------------------------------

-- Replaces where reloads take rounds from: Count(ply, weapon, ammoId) and Take(ply,
-- weapon, ammoId, count) -> rounds taken, the same on both realms (prediction); nil: the
-- engine reserve again.
function M:SetAmmoSource(source)
	assert(source == nil or type(source.Count) == "function" and type(source.Take) == "function",
		"weapons: SetAmmoSource(source): source needs Count and Take")
	self.source = source or ENGINE_AMMO
end

-- Rounds of `ammoId` the source has for `weapon` of `ply`.
function M:CountAmmo(ply, weapon, ammoId)
	return self.source.Count(ply, weapon, ammoId)
end

-- Takes up to `count` rounds of `ammoId` from the source; the rounds taken.
function M:TakeAmmo(ply, weapon, ammoId, count)
	return self.source.Take(ply, weapon, ammoId, count)
end

-- The type the next reload of `weapon` takes: the loaded one while there are rounds of it;
-- with an empty magazine, the first type of its caliber there are rounds of; nil: none.
function M:ReloadAmmo(ply, weapon)
	local loaded = weapon:LoadedAmmo()
	if self:CountAmmo(ply, weapon, loaded) > 0 then
		return loaded
	end
	if weapon:Clip1() > 0 then
		return nil
	end
	for _, id in ipairs(self.ammo:OfCaliber(weapon.def.caliber)) do
		if self:CountAmmo(ply, weapon, id) > 0 then
			return id
		end
	end
	return nil
end

-- Whether `ply` sprints (the weapon is lowered): the sprint key, on the ground, faster
-- than walking.
function M:Sprinting(ply)
	if not self.ctx.config.sprint or not ply:KeyDown(IN_SPEED) or not ply:IsOnGround() then
		return false
	end
	local walk = ply:GetWalkSpeed()
	return ply:GetVelocity():Length2DSqr() > walk * walk * 1.21
end

-- A shot of `weapon` (PrimaryAttack) along `dir` with `spread` degrees: the server flies
-- the round through ballistics; without it, engine bullets on both realms (the client of
-- the shooter draws their impacts).
function M:_Discharge(weapon, owner, dir, spread, ammoId)
	if self.ballistics == nil then
		local round = self.ammo:Get(ammoId)
		local _, energy = self.ammo:At(ammoId, 0)
		local cone = sin(rad(spread + round.spread))
		local velocity = weapon.def.velocity
		owner:FireBullets({ Attacker = owner, Src = owner:GetShootPos(), Dir = dir, Num = round.pellets,
			Spread = Vector(cone, cone, 0), AmmoType = ammoId, Damage = energy * velocity * velocity * ENTITY_DAMAGE,
			Force = 1, Tracer = 0 })
	elseif SERVER then
		self.ballistics:Fire(owner, owner:GetShootPos(), dir, ammoId, { inflictor = weapon, spread = spread,
			velocity = weapon.def.velocity })
	end
	if SERVER then
		self.ctx.events:Emit("weapons.fired", owner, weapon, ammoId)
	end
end
