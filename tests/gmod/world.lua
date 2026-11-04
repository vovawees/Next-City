-- Emulated game world for the GMod test environment (tests/gmod/env.lua): vectors and
-- angles, players with the engine methods the gamemode uses (spawn, death, observer
-- modes, teams, weapons, frags, damage, bones, movement speeds), damage infos and user
-- commands, the base gamemode behaviour of player hooks, the player, team, ents and game
-- libraries, hull traces and the 2D drawing API of clients.
--
-- Player actions run gamemode hooks like the engine does: ply:Spawn() calls
-- GM:PlayerSelectSpawn and GM:PlayerSpawn, ply:Kill() calls GM:DoPlayerDeath and
-- GM:PlayerDeath, ply:KillSilent() calls GM:PlayerSilentDeath, ply:TakeDamageInfo()
-- calls GM:EntityTakeDamage and GM:PlayerShouldTakeDamage and kills at zero health.
-- A player object is shared by the server realm and the clients, like networked state
-- that is always up to date.
--
-- Bones: every player has the ValveBiped skeleton of a standing man (World.SKELETON,
-- units, x forward, y left, z up from the feet), turned by the yaw of the player and
-- lowered while crouching; tests may move single bones (ply.bones[name] = Vector).

local World = {}

World.TEAM_CONNECTING = 0
World.TEAM_UNASSIGNED = 1001
World.TEAM_SPECTATOR = 1002

World.OBS_MODE = { NONE = 0, DEATHCAM = 1, FREEZECAM = 2, FIXED = 3, IN_EYE = 4, CHASE = 5, ROAMING = 6 }
World.IN = {
	ATTACK = 1, JUMP = 2, DUCK = 4, FORWARD = 8, BACK = 16, USE = 32, MOVELEFT = 512, MOVERIGHT = 1024,
	ATTACK2 = 2048, RELOAD = 8192, SCORE = 65536, SPEED = 131072, WALK = 262144,
}
World.DMG = {
	GENERIC = 0, CRUSH = 1, BULLET = 2, SLASH = 4, BURN = 8, VEHICLE = 16, FALL = 32, BLAST = 64, CLUB = 128,
	SHOCK = 256, SONIC = 512, ENERGYBEAM = 1024, PREVENT_PHYSICS_FORCE = 2048, NEVERGIB = 4096, ALWAYSGIB = 8192,
	DROWN = 16384, PARALYZE = 32768, NERVEGAS = 65536, POISON = 131072, RADIATION = 262144,
	DROWNRECOVER = 524288, ACID = 1048576, SLOWBURN = 2097152, REMOVENORAGDOLL = 4194304, PHYSGUN = 8388608,
	PLASMA = 16777216, AIRBOAT = 33554432, DISSOLVE = 67108864, BLAST_SURFACE = 134217728, DIRECT = 268435456,
	BUCKSHOT = 536870912, SNIPER = 1073741824,
}
World.HITGROUP = { GENERIC = 0, HEAD = 1, CHEST = 2, STOMACH = 3, LEFTARM = 4, RIGHTARM = 5, LEFTLEG = 6,
	RIGHTLEG = 7, GEAR = 10 }
-- Ammo types of Half-Life 2 by id, like game.GetAmmoName.
World.AMMO = { "AR2", "AR2AltFire", "Pistol", "SMG1", "357", "XBowBolt", "Buckshot", "RPG_Round", "SMG1_Grenade",
	"Grenade" }

-- Vectors and angles -------------------------------------------------------------------

local Vector, Angle
local VectorMethods = {}
local VectorMeta = {
	__index = VectorMethods,
	__tostring = function(v) return string.format("Vector(%g, %g, %g)", v.x, v.y, v.z) end,
	__add = function(a, b) return Vector(a.x + b.x, a.y + b.y, a.z + b.z) end,
	__sub = function(a, b) return Vector(a.x - b.x, a.y - b.y, a.z - b.z) end,
	__mul = function(a, b)
		if type(a) == "number" then
			a, b = b, a
		end
		return Vector(a.x * b, a.y * b, a.z * b)
	end,
	__div = function(a, b) return Vector(a.x / b, a.y / b, a.z / b) end,
	__unm = function(a) return Vector(-a.x, -a.y, -a.z) end,
	__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
}
local AngleMethods = {}
local AngleMeta = {
	__index = AngleMethods,
	__tostring = function(a) return string.format("Angle(%g, %g, %g)", a.x, a.y, a.z) end,
}

World.VectorMeta = VectorMeta
World.AngleMeta = AngleMeta

-- Vector(v) and Angle(a) copy, like in GMod.
function Vector(x, y, z)
	if getmetatable(x) == VectorMeta then
		x, y, z = x.x, x.y, x.z
	end
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, VectorMeta)
end

function Angle(p, y, r)
	if getmetatable(p) == AngleMeta then
		p, y, r = p.x, p.y, p.z
	end
	return setmetatable({ x = p or 0, y = y or 0, z = r or 0 }, AngleMeta)
end

World.Vector = Vector
World.Angle = Angle

function VectorMethods:LengthSqr() return self.x * self.x + self.y * self.y + self.z * self.z end
function VectorMethods:Length() return math.sqrt(self:LengthSqr()) end
function VectorMethods:Length2DSqr() return self.x * self.x + self.y * self.y end
function VectorMethods:DistToSqr(other) return (self - other):LengthSqr() end
function VectorMethods:Distance(other) return (self - other):Length() end
function VectorMethods:Dot(other) return self.x * other.x + self.y * other.y + self.z * other.z end
function VectorMethods:WithinAABox(mins, maxs)
	return self.x >= mins.x and self.x <= maxs.x and self.y >= mins.y and self.y <= maxs.y and self.z >= mins.z
		and self.z <= maxs.z
end
function VectorMethods:Unpack() return self.x, self.y, self.z end
function VectorMethods:Cross(o)
	return Vector(self.y * o.z - self.z * o.y, self.z * o.x - self.x * o.z, self.x * o.y - self.y * o.x)
end
function VectorMethods:GetNormalized()
	local length = self:Length()
	if length == 0 then
		return Vector(0, 0, 0)
	end
	return Vector(self.x / length, self.y / length, self.z / length)
end
function VectorMethods:Normalize()
	local n = self:GetNormalized()
	self.x, self.y, self.z = n.x, n.y, n.z
end
function VectorMethods:IsZero() return self.x == 0 and self.y == 0 and self.z == 0 end

-- Source conventions: pitch down is positive, Forward = (cos p cos y, cos p sin y, -sin p).
function AngleMethods:Unpack() return self.x, self.y, self.z end
function AngleMethods:Forward()
	local p, y = math.rad(self.x), math.rad(self.y)
	return Vector(math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p))
end
function AngleMethods:Right()
	local p, y, r = math.rad(self.x), math.rad(self.y), math.rad(self.z)
	local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
	return Vector(-sr * sp * cy + cr * sy, -sr * sp * sy - cr * cy, -sr * cp)
end
function AngleMethods:Up()
	local p, y, r = math.rad(self.x), math.rad(self.y), math.rad(self.z)
	local sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
	return Vector(cr * sp * cy + sr * sy, cr * sp * sy - sr * cy, cr * cp)
end

-- Entities -------------------------------------------------------------------------------

World.NULL = setmetatable({
	__entity = true,
	IsValid = function() return false end,
	IsWorld = function() return false end,
	IsPlayer = function() return false end,
	EntIndex = function() return 0 end,
	GetClass = function() return "" end,
}, { __tostring = function() return "[NULL Entity]" end })

-- The world (game.GetWorld()): entity 0, not valid, like in GMod.
World.WORLD = setmetatable({
	__entity = true,
	IsValid = function() return false end,
	IsWorld = function() return true end,
	IsPlayer = function() return false end,
	EntIndex = function() return 0 end,
	GetClass = function() return "worldspawn" end,
}, { __tostring = function() return "Entity [0][worldspawn]" end })

local function isValid(value)
	return type(value) == "table" and type(value.IsValid) == "function" and value:IsValid() == true
end

local function isPlayer(value)
	return isValid(value) and value:IsPlayer()
end

-- Primary ammo type and clip size of the stock weapons.
local WEAPONS = {
	weapon_crowbar = { -1, -1 }, weapon_stunstick = { -1, -1 }, weapon_physcannon = { -1, -1 },
	weapon_pistol = { 3, 18 }, weapon_357 = { 5, 6 }, weapon_smg1 = { 4, 45 }, weapon_ar2 = { 1, 30 },
	weapon_shotgun = { 7, 6 }, weapon_crossbow = { 6, 1 }, weapon_frag = { 10, -1 }, weapon_rpg = { 8, -1 },
}

local WeaponMethods = {}
local WeaponMeta = {
	__index = WeaponMethods,
	__tostring = function(w) return string.format("Weapon [%s]", w.class) end,
}

function WeaponMethods:IsValid() return self.valid end
function WeaponMethods:IsWorld() return false end
function WeaponMethods:IsPlayer() return false end
function WeaponMethods:IsWeapon() return true end
function WeaponMethods:GetClass() return self.class end
function WeaponMethods:GetOwner() return self.owner end
function WeaponMethods:GetPrimaryAmmoType() return (WEAPONS[self.class] or { -1 })[1] end
function WeaponMethods:GetMaxClip1() return (WEAPONS[self.class] or { -1, -1 })[2] end

-- Players ------------------------------------------------------------------------------

local Player = {}
local PlayerMeta = {
	__index = Player,
	__tostring = function(ply) return string.format("Player [%d][%s]", ply.index, ply.name) end,
}
World.PlayerMethods = Player

local playerIndex = 0

-- A player (index 1..128). opts: name, superadmin, index, bot, server (the realm whose
-- gamemode hooks its actions call; Env.Join and Env.Bot set it).
-- Recorded: .printed (PrintMessage), .chat (ChatPrint), .spawns (number of spawns).
function World.FakePlayer(opts)
	opts = opts or {}
	playerIndex = playerIndex % 128 + 1
	return setmetatable({
		__entity = true,
		index = opts.index or playerIndex,
		name = opts.name or "Player",
		admin = opts.superadmin == true,
		bot = opts.bot == true,
		server = opts.server,
		valid = true,
		printed = {},
		chat = {},
		alive = false,
		team = World.TEAM_UNASSIGNED,
		observerMode = World.OBS_MODE.NONE,
		observerTarget = nil,
		pos = Vector(0, 0, 0),
		angles = Angle(0, 0, 0),
		health = 100,
		frags = 0,
		deaths = 0,
		frozen = false,
		weapons = {},
		ammo = {},
		spawns = 0,
		armor = 0,
		god = false,
		lastHitGroup = 0,
		waterLevel = 0,
		keys = {},
		velocity = Vector(0, 0, 0),
		crouching = false,
		onGround = true,
		walkSpeed = 200,
		runSpeed = 400,
		slowWalkSpeed = 100,
		crouchedWalkSpeed = 0.3,
		jumpPower = 200,
		bones = {},
		viewPunches = {},
		pushes = {},
		damage = {},
	}, PlayerMeta)
end

function Player:IsValid() return self.valid end
function Player:IsWorld() return false end
function Player:IsPlayer() return true end
function Player:IsBot() return self.bot end
function Player:EntIndex() return self.index end
function Player:UserID() return self.index end
function Player:SteamID64() return string.format("765611980%08d", self.index) end
function Player:GetClass() return "player" end
function Player:IsSuperAdmin() return self.admin end
function Player:IsAdmin() return self.admin end
function Player:Nick() return self.name end
Player.Name = Player.Nick
function Player:PrintMessage(_, text) self.printed[#self.printed + 1] = text end
function Player:ChatPrint(text) self.chat[#self.chat + 1] = text end

function Player:Alive() return self.alive end
function Player:Health() return self.health end
function Player:SetHealth(value) self.health = value end
function Player:Team() return self.team end
function Player:SetTeam(index) self.team = index end
function Player:GetPos() return Vector(self.pos) end
function Player:SetPos(pos) self.pos = Vector(pos) end
function Player:EyePos() return Vector(self.pos.x, self.pos.y, self.pos.z + 64) end
function Player:EyeAngles() return Angle(self.angles) end
function Player:GetAngles() return Angle(self.angles) end
function Player:SetEyeAngles(ang) self.angles = Angle(ang) end
function Player:Freeze(frozen) self.frozen = frozen == true end
function Player:IsFrozen() return self.frozen end
function Player:Frags() return self.frags end
function Player:Deaths() return self.deaths end
function Player:AddFrags(n) self.frags = self.frags + n end
function Player:AddDeaths(n) self.deaths = self.deaths + n end
function Player:SetFrags(n) self.frags = n end
function Player:SetDeaths(n) self.deaths = n end
function Player:SetupHands() self.hands = true end
function Player:Armor() return self.armor end
function Player:SetArmor(value) self.armor = value end
function Player:HasGodMode() return self.god end
function Player:GodEnable() self.god = true end
function Player:GodDisable() self.god = false end
function Player:LastHitGroup() return self.lastHitGroup end
function Player:WaterLevel() return self.waterLevel end
function Player:KeyDown(key) return self.keys[key] == true end
function Player:GetVelocity() return Vector(self.velocity) end
function Player:Crouching() return self.crouching end
function Player:IsOnGround() return self.onGround end
function Player:OnGround() return self.onGround end
function Player:GetShootPos() return self:EyePos() end
function Player:GetAimVector() return self.angles:Forward() end
function Player:ViewPunch(ang) self.viewPunches[#self.viewPunches + 1] = ang end
-- Like for players in GMod, this adds to the velocity; every push is recorded.
function Player:SetVelocity(v)
	self.pushes[#self.pushes + 1] = Vector(v)
	self.velocity = self.velocity + v
end
function Player:GetWalkSpeed() return self.walkSpeed end
function Player:SetWalkSpeed(value) self.walkSpeed = value end
function Player:GetRunSpeed() return self.runSpeed end
function Player:SetRunSpeed(value) self.runSpeed = value end
function Player:GetSlowWalkSpeed() return self.slowWalkSpeed end
function Player:SetSlowWalkSpeed(value) self.slowWalkSpeed = value end
function Player:GetCrouchedWalkSpeed() return self.crouchedWalkSpeed end
function Player:SetCrouchedWalkSpeed(value) self.crouchedWalkSpeed = value end
function Player:GetJumpPower() return self.jumpPower end
function Player:SetJumpPower(value) self.jumpPower = value end

-- Standing ValveBiped skeleton, facing +x; positions relative to the feet.
World.SKELETON = {
	["ValveBiped.Bip01_Pelvis"] = Vector(0, 0, 38.5),
	["ValveBiped.Bip01_Spine"] = Vector(0, 0, 42.5),
	["ValveBiped.Bip01_Spine1"] = Vector(0, 0, 47),
	["ValveBiped.Bip01_Spine2"] = Vector(0, 0, 51.5),
	["ValveBiped.Bip01_Spine4"] = Vector(0, 0, 57),
	["ValveBiped.Bip01_Neck1"] = Vector(0.3, 0, 62),
	["ValveBiped.Bip01_Head1"] = Vector(0.6, 0, 65.5),
	["ValveBiped.Bip01_L_Clavicle"] = Vector(1, 1.2, 60),
	["ValveBiped.Bip01_R_Clavicle"] = Vector(1, -1.2, 60),
	["ValveBiped.Bip01_L_UpperArm"] = Vector(0, 7, 59),
	["ValveBiped.Bip01_R_UpperArm"] = Vector(0, -7, 59),
	["ValveBiped.Bip01_L_Forearm"] = Vector(0, 8, 48),
	["ValveBiped.Bip01_R_Forearm"] = Vector(0, -8, 48),
	["ValveBiped.Bip01_L_Hand"] = Vector(2, 8, 38),
	["ValveBiped.Bip01_R_Hand"] = Vector(2, -8, 38),
	["ValveBiped.Bip01_L_Thigh"] = Vector(0, 3.8, 37.5),
	["ValveBiped.Bip01_R_Thigh"] = Vector(0, -3.8, 37.5),
	["ValveBiped.Bip01_L_Calf"] = Vector(0.5, 3.8, 20.5),
	["ValveBiped.Bip01_R_Calf"] = Vector(0.5, -3.8, 20.5),
	["ValveBiped.Bip01_L_Foot"] = Vector(-0.5, 3.8, 3.5),
	["ValveBiped.Bip01_R_Foot"] = Vector(-0.5, -3.8, 3.5),
	["ValveBiped.Bip01_L_Toe0"] = Vector(4.5, 3.8, 0.8),
	["ValveBiped.Bip01_R_Toe0"] = Vector(4.5, -3.8, 0.8),
}
World.BONE_NAMES = {}
for name in pairs(World.SKELETON) do
	World.BONE_NAMES[#World.BONE_NAMES + 1] = name
end
table.sort(World.BONE_NAMES)
World.BONE_IDS = {}
for id, name in ipairs(World.BONE_NAMES) do
	World.BONE_IDS[name] = id - 1
end

-- Bone ids of the skeleton (nil for unknown names or a player with ply.noBones).
function Player:LookupBone(name)
	if self.noBones then
		return nil
	end
	return World.BONE_IDS[name]
end

-- World position of a bone: the skeleton turned by the yaw, lowered by 20 units above the
-- pelvis and 14 below it while crouching; ply.bones[name] overrides (relative too).
function Player:GetBonePosition(id)
	local name = World.BONE_NAMES[(id or -1) + 1]
	if name == nil then
		return nil
	end
	local rel = self.bones[name] or World.SKELETON[name]
	local x, y, z = rel.x, rel.y, rel.z
	if self.crouching then
		z = z > 38.5 and z - 20 or z * 0.65
	end
	local yaw = math.rad(self.angles.y)
	local c, s = math.cos(yaw), math.sin(yaw)
	return Vector(self.pos.x + x * c - y * s, self.pos.y + x * s + y * c, self.pos.z + z), Angle(0, self.angles.y, 0)
end

function Player:GetActiveWeapon()
	for _, weapon in ipairs(self.weapons) do
		if weapon.class == self.selected then
			return weapon
		end
	end
	return self.weapons[#self.weapons] or World.NULL
end
function Player:SetModel(model) self.model = model end
function Player:GetModel() return self.model end

-- Observer mode makes the player dead for the engine (lifeState), like StartObserverMode.
function Player:Spectate(mode)
	self.observerMode = mode
	self.alive = false
end
function Player:SpectateEntity(ent) self.observerTarget = ent end
function Player:UnSpectate()
	self.observerMode = World.OBS_MODE.NONE
	self.observerTarget = nil
end
function Player:GetObserverMode() return self.observerMode end
function Player:GetObserverTarget() return self.observerTarget or World.NULL end

function Player:StripWeapons() self.weapons = {} end
function Player:RemoveAllAmmo() self.ammo = {} end
function Player:Give(class)
	local weapon = setmetatable({ __entity = true, class = class, owner = self, valid = true }, WeaponMeta)
	self.weapons[#self.weapons + 1] = weapon
	return weapon
end
function Player:SelectWeapon(class) self.selected = class end
function Player:GiveAmmo(amount, ammoType)
	self.ammo[ammoType] = (self.ammo[ammoType] or 0) + amount
	return amount
end
function Player:GetAmmoCount(ammoType) return self.ammo[ammoType] or 0 end
function Player:HasWeapon(class)
	for _, weapon in ipairs(self.weapons) do
		if weapon.class == class then
			return true
		end
	end
	return false
end
function Player:GetWeapons()
	local list = {}
	for i, weapon in ipairs(self.weapons) do
		list[i] = weapon
	end
	return list
end

-- Classes of the weapons the player holds, in the order they were given.
function Player:WeaponClasses()
	local list = {}
	for i, weapon in ipairs(self.weapons) do
		list[i] = weapon.class
	end
	return list
end

-- The engine spawn: the gamemode picks a spawn point, then GM:PlayerSpawn runs.
function Player:Spawn()
	self.alive = true
	self.observerMode = World.OBS_MODE.NONE
	self.observerTarget = nil
	self.health = 100
	self.lastHitGroup = 0
	self.spawns = self.spawns + 1
	local server = self.server
	if server == nil then
		return
	end
	local point = server:Call("PlayerSelectSpawn", self, false)
	self.spawnPoint = point
	if isValid(point) then
		self.pos = point:GetPos()
		self.angles = point:GetAngles()
	end
	server:Call("PlayerSpawn", self, false)
end

-- Damage infos ----------------------------------------------------------------------------

local DamageInfo = {}
DamageInfo.__index = DamageInfo
World.DamageInfoMeta = DamageInfo

-- A new damage info (the global DamageInfo()).
function World.DamageInfo()
	return setmetatable({ attacker = World.NULL, inflictor = World.NULL, damage = 0, maxDamage = 0, baseDamage = 0,
		type = 0, position = Vector(0, 0, 0), reported = Vector(0, 0, 0), force = Vector(0, 0, 0), ammo = -1,
		custom = 0 }, DamageInfo)
end

function DamageInfo:GetAttacker() return self.attacker end
function DamageInfo:SetAttacker(ent) self.attacker = ent end
function DamageInfo:GetInflictor() return self.inflictor end
function DamageInfo:SetInflictor(ent) self.inflictor = ent end
function DamageInfo:GetDamage() return self.damage end
function DamageInfo:SetDamage(value) self.damage = value end
function DamageInfo:AddDamage(value) self.damage = self.damage + value end
function DamageInfo:SubtractDamage(value) self.damage = self.damage - value end
function DamageInfo:ScaleDamage(scale) self.damage = self.damage * scale end
function DamageInfo:GetMaxDamage() return self.maxDamage end
function DamageInfo:SetMaxDamage(value) self.maxDamage = value end
function DamageInfo:GetBaseDamage() return self.baseDamage end
function DamageInfo:GetDamageType() return self.type end
function DamageInfo:SetDamageType(value) self.type = value end
function DamageInfo:IsDamageType(value) return bit.band(self.type, value) ~= 0 end
function DamageInfo:IsBulletDamage() return bit.band(self.type, World.DMG.BULLET + World.DMG.BUCKSHOT) ~= 0 end
function DamageInfo:IsExplosionDamage() return bit.band(self.type, World.DMG.BLAST) ~= 0 end
function DamageInfo:IsFallDamage() return bit.band(self.type, World.DMG.FALL) ~= 0 end
function DamageInfo:GetDamagePosition() return Vector(self.position) end
function DamageInfo:SetDamagePosition(pos) self.position = Vector(pos) end
function DamageInfo:GetReportedPosition() return Vector(self.reported) end
function DamageInfo:SetReportedPosition(pos) self.reported = Vector(pos) end
function DamageInfo:GetDamageForce() return Vector(self.force) end
function DamageInfo:SetDamageForce(force) self.force = Vector(force) end
function DamageInfo:GetAmmoType() return self.ammo end
function DamageInfo:SetAmmoType(id) self.ammo = id end
function DamageInfo:GetDamageCustom() return self.custom end
function DamageInfo:SetDamageCustom(value) self.custom = value end

-- Kills `victim`: DoPlayerDeath, then PlayerDeath, like the engine. Weapons are lost.
-- dmginfo: the killing damage (default: generic damage of the remaining health).
function World.Die(victim, attacker, inflictor, dmginfo)
	if not victim.alive then
		return
	end
	victim.alive = false
	victim.weapons = {}
	attacker = attacker or victim
	inflictor = inflictor or attacker
	local server = victim.server
	if server ~= nil then
		if dmginfo == nil then
			dmginfo = World.DamageInfo()
			dmginfo:SetAttacker(attacker)
			dmginfo:SetInflictor(inflictor)
			dmginfo:SetDamage(victim.health)
		end
		victim.deathInfo = dmginfo
		server:Call("DoPlayerDeath", victim, attacker, dmginfo)
		server:Call("PlayerDeath", victim, inflictor, attacker)
	end
end

-- The engine damage: GM:EntityTakeDamage (true blocks), god mode, then
-- GM:PlayerShouldTakeDamage (false blocks); the health drops and at zero the player dies.
-- Every damage that reached the health is recorded in ply.damage.
function Player:TakeDamageInfo(dmginfo)
	if not self.alive then
		return
	end
	local server = self.server
	if server ~= nil then
		if server:Call("EntityTakeDamage", self, dmginfo) == true then
			return
		end
		if self.god or server:Call("PlayerShouldTakeDamage", self, dmginfo:GetAttacker()) == false then
			return
		end
	end
	self.damage[#self.damage + 1] = dmginfo
	self.health = self.health - dmginfo:GetDamage()
	if self.health <= 0 then
		World.Die(self, dmginfo:GetAttacker(), dmginfo:GetInflictor(), dmginfo)
	end
end

function Player:TakeDamage(amount, attacker, inflictor)
	local dmginfo = World.DamageInfo()
	dmginfo:SetDamage(amount)
	dmginfo:SetAttacker(attacker or World.WORLD)
	dmginfo:SetInflictor(inflictor or attacker or World.WORLD)
	self:TakeDamageInfo(dmginfo)
end

-- User commands ----------------------------------------------------------------------------

local UserCmd = {}
UserCmd.__index = UserCmd

-- A user command (CUserCmd) with buttons and movement.
function World.UserCmd(buttons, forward, side)
	return setmetatable({ buttons = buttons or 0, forward = forward or 0, side = side or 0, up = 0,
		impulse = 0 }, UserCmd)
end

function UserCmd:GetButtons() return self.buttons end
function UserCmd:SetButtons(buttons) self.buttons = buttons end
function UserCmd:KeyDown(key) return bit.band(self.buttons, key) ~= 0 end
function UserCmd:AddKey(key) self.buttons = bit.bor(self.buttons, key) end
function UserCmd:RemoveKey(key) self.buttons = bit.band(self.buttons, bit.bnot(key)) end
function UserCmd:ClearButtons() self.buttons = 0 end
function UserCmd:ClearMovement()
	self.forward, self.side, self.up = 0, 0, 0
end
function UserCmd:GetForwardMove() return self.forward end
function UserCmd:SetForwardMove(value) self.forward = value end
function UserCmd:GetSideMove() return self.side end
function UserCmd:SetSideMove(value) self.side = value end
function UserCmd:GetUpMove() return self.up end
function UserCmd:SetUpMove(value) self.up = value end
function UserCmd:GetImpulse() return self.impulse end
function UserCmd:SetImpulse(value) self.impulse = value end

function Player:Kill()
	World.Die(self, self, self)
end

function Player:KillSilent()
	if not self.alive then
		return
	end
	self.alive = false
	self.weapons = {}
	if self.server ~= nil then
		self.server:Call("PlayerSilentDeath", self)
	end
end

-- Base gamemode -------------------------------------------------------------------------

-- What the base gamemode does in the hooks the bridge forwards to it (simplified).
World.BASE = {
	PlayerSpawn = function(_, gm, ply, transition)
		ply:UnSpectate()
		ply:SetWalkSpeed(200)
		ply:SetRunSpeed(400)
		ply:SetJumpPower(200)
		ply:SetupHands()
		if not transition then
			gm:PlayerLoadout(ply)
		end
		gm:PlayerSetModel(ply)
	end,
	PlayerLoadout = function(_, _, ply)
		ply:Give("weapon_pistol")
	end,
	PlayerSetModel = function(_, _, ply)
		ply:SetModel("models/player/kleiner.mdl")
	end,
	PlayerSelectSpawn = function(env)
		return env.G.ents.FindByClass("info_player_start")[1]
	end,
	DoPlayerDeath = function(_, _, ply, attacker)
		ply:AddDeaths(1)
		if isPlayer(attacker) then
			attacker:AddFrags(attacker == ply and -1 or 1)
		end
	end,
	PlayerDeath = function(env, _, ply)
		ply.NextSpawnTime = env.time + 2
		ply.DeathTime = env.time
	end,
	PlayerSilentDeath = function(env, _, ply)
		ply.NextSpawnTime = env.time + 2
		ply.DeathTime = env.time
	end,
	-- Respawns bots and players that pressed a key (ply.wantsRespawn in tests).
	PlayerDeathThink = function(env, _, ply)
		if ply.NextSpawnTime and ply.NextSpawnTime > env.time then
			return
		end
		if ply:IsBot() or ply.wantsRespawn then
			ply.wantsRespawn = nil
			ply:Spawn()
		end
	end,
	PlayerShouldTakeDamage = function() return true end,
	CanPlayerSuicide = function() return true end,
	GetFallDamage = function() return 10 end,
	HUDShouldDraw = function() return true end,
}

-- Libraries ------------------------------------------------------------------------------

local function globMatcher(mask)
	local escaped = mask:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
	return "^" .. escaped:gsub("%*", ".*") .. "$"
end

local function sortedEntities(env, filter)
	local list = {}
	for _, ent in pairs(env.entities) do
		if isValid(ent) and filter(ent) then
			list[#list + 1] = ent
		end
	end
	table.sort(list, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return list
end

-- Installs the world libraries into the globals G of the realm env.
function World.Install(env, G)
	G.TEAM_CONNECTING = World.TEAM_CONNECTING
	G.TEAM_UNASSIGNED = World.TEAM_UNASSIGNED
	G.TEAM_SPECTATOR = World.TEAM_SPECTATOR
	for name, value in pairs(World.OBS_MODE) do
		G["OBS_MODE_" .. name] = value
	end
	for name, value in pairs(World.IN) do
		G["IN_" .. name] = value
	end
	for name, value in pairs(World.DMG) do
		G["DMG_" .. name] = value
	end
	for name, value in pairs(World.HITGROUP) do
		G["HITGROUP_" .. name] = value
	end
	G.DamageInfo = World.DamageInfo
	G.MASK_PLAYERSOLID = 33636363
	G.MASK_SOLID = 33570827
	G.HUD_PRINTNOTIFY = 1
	G.HUD_PRINTTALK = 3
	G.HUD_PRINTCENTER = 4

	G.player = {}
	function G.player.GetAll()
		return sortedEntities(env, function(ent) return ent:IsPlayer() end)
	end
	function G.player.GetCount()
		return #G.player.GetAll()
	end
	function G.player.GetHumans()
		return sortedEntities(env, function(ent) return ent:IsPlayer() and not ent:IsBot() end)
	end
	function G.player.GetBots()
		return sortedEntities(env, function(ent) return ent:IsPlayer() and ent:IsBot() end)
	end

	local teams = {
		[World.TEAM_CONNECTING] = { name = "Joining/Connecting", color = G.Color(255, 255, 100), joinable = false },
		[World.TEAM_UNASSIGNED] = { name = "Unassigned", color = G.Color(255, 255, 100), joinable = false },
		[World.TEAM_SPECTATOR] = { name = "Spectator", color = G.Color(255, 255, 100), joinable = true },
	}
	env.teams = teams
	G.team = {}
	function G.team.SetUp(index, name, color, joinable)
		teams[index] = { name = name, color = color, joinable = joinable ~= false }
	end
	function G.team.Valid(index)
		return teams[index] ~= nil
	end
	function G.team.GetName(index)
		local info = teams[index]
		return info and info.name or ""
	end
	function G.team.GetColor(index)
		local info = teams[index]
		local color = info and info.color or G.Color(255, 255, 100)
		return G.Color(color.r, color.g, color.b, color.a)
	end
	function G.team.Joinable(index)
		local info = teams[index]
		return info ~= nil and info.joinable
	end
	function G.team.GetPlayers(index)
		local list = {}
		for _, ply in ipairs(G.player.GetAll()) do
			if ply:Team() == index then
				list[#list + 1] = ply
			end
		end
		return list
	end
	function G.team.NumPlayers(index)
		return #G.team.GetPlayers(index)
	end

	G.ents = {}
	function G.ents.GetAll()
		return sortedEntities(env, function() return true end)
	end
	function G.ents.FindByClass(mask)
		local matcher = globMatcher(mask)
		return sortedEntities(env, function(ent) return ent:GetClass():find(matcher) ~= nil end)
	end
	function G.ents.FindInBox(mins, maxs)
		return sortedEntities(env, function(ent) return ent.GetPos ~= nil and ent:GetPos():WithinAABox(mins, maxs) end)
	end
	function G.ents.FindInSphere(pos, radius)
		return sortedEntities(env, function(ent)
			return ent.GetPos ~= nil and ent:GetPos():DistToSqr(pos) <= radius * radius
		end)
	end

	-- Traces hit nothing unless a test sets env.traceHull / env.traceLine.
	local function emptyTrace(trace)
		return { Hit = false, StartSolid = false, HitWorld = false, Fraction = 1, HitPos = Vector(trace.endpos),
			Entity = World.NULL }
	end
	function G.util.TraceHull(trace)
		return (env.traceHull or emptyTrace)(trace)
	end
	function G.util.TraceLine(trace)
		return (env.traceLine or emptyTrace)(trace)
	end

	if env.realm == "client" then
		World.InstallDrawing(env, G)
	end
end

-- Records drawn texts in env.drawn; text sizes are 8 px per byte by 16 px.
function World.InstallDrawing(env, G)
	env.drawn = {}
	env.fonts = {}
	G.TEXT_ALIGN_LEFT = 0
	G.TEXT_ALIGN_CENTER = 1
	G.TEXT_ALIGN_RIGHT = 2
	G.TEXT_ALIGN_TOP = 3
	G.TEXT_ALIGN_BOTTOM = 4
	function G.ScrW() return 1920 end
	function G.ScrH() return 1080 end
	local function noop() end
	G.surface = {
		CreateFont = function(name, data) env.fonts[name] = data end,
		SetFont = function(name) env.font = name end,
		GetTextSize = function(text) return #tostring(text) * 8, 16 end,
		SetDrawColor = noop,
		DrawRect = noop,
		DrawOutlinedRect = noop,
		SetTextColor = noop,
		SetTextPos = noop,
		DrawText = function(text) env.drawn[#env.drawn + 1] = tostring(text) end,
	}
	local function drawText(text)
		env.drawn[#env.drawn + 1] = tostring(text)
		return #tostring(text) * 8, 16
	end
	G.draw = {
		SimpleText = drawText,
		SimpleTextOutlined = drawText,
		DrawText = drawText,
		RoundedBox = noop,
	}
end

return World
