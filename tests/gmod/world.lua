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
--
-- Entities: map and test entities (Env.Spawn) and the ones of the gamemode (ents.Create)
-- share World.EntityMethods; Remove() takes an entity away at the next tick, like the
-- engine. A prop_ragdoll has the 15 physics objects of a ValveBiped player model (in the
-- order of its .phy), the other bones move with the physics bone they hang on, and the
-- "eyes" attachment sits in front of the head. Physics is simple: on every tick of the
-- server each ragdoll moves with the mass-weighted mean velocity of its awake objects,
-- which halves every 0.2 s (joints that hold the body together, friction); no gravity and
-- no collisions. World.TurnRagdoll and World.LayRagdoll pose bodies for tests.

local World = {}
World.Geometry = dofile(T.root .. "tests/gmod/geometry.lua")
World.Sweps = dofile(T.root .. "tests/gmod/sweps.lua")

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
World.MOVETYPE = { NONE = 0, WALK = 2, FLYGRAVITY = 5, VPHYSICS = 6, NOCLIP = 8, LADDER = 9, OBSERVER = 10 }
World.COLLISION_GROUP = { NONE = 0, DEBRIS = 1, DEBRIS_TRIGGER = 2, INTERACTIVE_DEBRIS = 3, INTERACTIVE = 4,
	PLAYER = 5, VEHICLE = 7, PLAYER_MOVEMENT = 8, NPC = 9, WEAPON = 11, PASSABLE_DOOR = 15, WORLD = 20 }
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
	__add = function(a, b) return Angle(a.x + b.x, a.y + b.y, a.z + b.z) end,
	__sub = function(a, b) return Angle(a.x - b.x, a.y - b.y, a.z - b.z) end,
	__mul = function(a, b)
		if type(a) == "number" then
			a, b = b, a
		end
		return Angle(a.x * b, a.y * b, a.z * b)
	end,
	__unm = function(a) return Angle(-a.x, -a.y, -a.z) end,
	__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
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
function VectorMethods:SetUnpacked(x, y, z) self.x, self.y, self.z = x, y, z end
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

-- Rotates the angle in place by `degrees` around `axis` (right-hand rule, like GMod).
function AngleMethods:RotateAroundAxis(axis, degrees)
	local k = axis:GetNormalized()
	local t = math.rad(degrees)
	local c, s = math.cos(t), math.sin(t)
	local function rotate(v)
		return v * c + k:Cross(v) * s + k * (k:Dot(v) * (1 - c))
	end
	local f, u = rotate(self:Forward()), rotate(self:Up())
	local pitch = math.deg(math.asin(math.max(-1, math.min(1, -f.z))))
	local yaw = math.deg(math.atan2(f.y, f.x))
	local base = Angle(pitch, yaw, 0)
	local roll = math.deg(math.atan2(u:Dot(base:Right()), u:Dot(base:Up())))
	self.x, self.y, self.z = pitch, yaw, roll
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
		moveType = World.MOVETYPE.WALK,
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
function Player:IsNPC() return false end
function Player:IsNextBot() return false end
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
function Player:EyePos() return self.pos + self:GetViewOffset() end
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
-- Pressed or released in the current command (Env.Use).
function Player:KeyPressed(key) return self.pressedKeys ~= nil and self.pressedKeys[key] == true end
function Player:KeyReleased(key) return self.releasedKeys ~= nil and self.releasedKeys[key] == true end
function Player:KeyDownLast(key) return bit.band(self.lastButtons or 0, key) ~= 0 end
-- Recorded: .animations (SetAnimation), .muzzleFlashes, .sounds (EmitSound).
function Player:SetAnimation(anim)
	self.animations = self.animations or {}
	self.animations[#self.animations + 1] = anim
end
function Player:MuzzleFlash() self.muzzleFlashes = (self.muzzleFlashes or 0) + 1 end
-- Engine bullets are recorded in .bullets: { realm = "server" | "client", bullet = the table }.
function Player:FireBullets(bullet)
	self.bullets = self.bullets or {}
	self.bullets[#self.bullets + 1] = { realm = World.realm ~= nil and World.realm.realm or "server", bullet = bullet }
end
function Player:EmitSound(name)
	self.sounds = self.sounds or {}
	self.sounds[#self.sounds + 1] = name
end
function Player:GetVelocity() return Vector(self.velocity) end
function Player:Crouching() return self.crouching end
function Player:IsOnGround() return self.onGround end
function Player:OnGround() return self.onGround end
function Player:GetShootPos() return self:EyePos() end
function Player:GetAimVector() return self.angles:Forward() end
function Player:ViewPunch(ang) self.viewPunches[#self.viewPunches + 1] = ang end
-- The punch of the view now (.viewPunch, set by tests): the engine decays it.
function Player:GetViewPunchAngles() return Angle(self.viewPunch or Angle(0, 0, 0)) end
function Player:SetViewPunchAngles(ang) self.viewPunch = Angle(ang) end
-- The view model of the player on the realm whose code runs (tests read
-- ply.viewModels[realm]): LookupSequence answers an index for any name, the sequences sent
-- are recorded by name in vm.sequences, SequenceDuration answers vm.duration (0.5 s).
local ViewModel = {}
ViewModel.__index = ViewModel
World.SEQUENCE_NAMES = {}
function ViewModel:IsValid() return true end
function ViewModel:LookupSequence(name)
	local names = World.SEQUENCE_NAMES
	for i, known in ipairs(names) do
		if known == name then
			return i - 1
		end
	end
	names[#names + 1] = name
	return #names - 1
end
function ViewModel:SendViewModelMatchingSequence(seq)
	self.sequences[#self.sequences + 1] = World.SEQUENCE_NAMES[seq + 1]
end
function ViewModel:SequenceDuration() return self.duration end
function ViewModel:SetPlaybackRate(rate) self.rate = rate end
function ViewModel:GetPlaybackRate() return self.rate end
function Player:GetViewModel()
	self.viewModels = self.viewModels or {}
	local key = World.realm or false
	local vm = self.viewModels[key]
	if vm == nil then
		vm = setmetatable({ owner = self, sequences = {}, duration = 0.5, rate = 1 }, ViewModel)
		self.viewModels[key] = vm
	end
	return vm
end
-- What the player stands on: ply.groundEntity (set by tests), else the world on the
-- ground, else NULL.
function Player:GetGroundEntity()
	if self.groundEntity ~= nil then
		return self.groundEntity
	end
	return self.onGround and World.WORLD or World.NULL
end
-- Like for players in GMod, this adds to the velocity; every push is recorded.
function Player:SetVelocity(v)
	self.pushes[#self.pushes + 1] = Vector(v)
	self.velocity = self.velocity + v
end
function Player:GetMoveType() return self.moveType end
function Player:SetMoveType(value) self.moveType = value end
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
function Player:SetLocalVelocity(v) self.velocity = Vector(v) end
function Player:GetNoDraw() return self.noDraw == true end
function Player:SetNoDraw(value) self.noDraw = value == true end
function Player:IsSolid() return not self.notSolid end
function Player:SetNotSolid(value) self.notSolid = value == true end
function Player:GetViewOffset() return Vector(self.viewOffset or Vector(0, 0, 64)) end
function Player:SetViewOffset(v) self.viewOffset = Vector(v) end
function Player:GetViewOffsetDucked() return Vector(self.viewOffsetDucked or Vector(0, 0, 28)) end
function Player:SetViewOffsetDucked(v) self.viewOffsetDucked = Vector(v) end
function Player:GetCurrentViewOffset() return self:GetViewOffset() end
function Player:SetCurrentViewOffset() end
-- Whether the view model and the world model of the weapon are drawn (both default true).
function Player:DrawViewModel(value) self.viewModelHidden = not value end
function Player:DrawWorldModel(value) self.worldModelHidden = not value end
function Player:GetHull() return Vector(-16, -16, 0), Vector(16, 16, 72) end
function Player:GetHullDuck() return Vector(-16, -16, 0), Vector(16, 16, 36) end
function Player:InVehicle() return self.vehicle ~= nil end
function Player:GetVehicle() return self.vehicle or World.NULL end
function Player:GetSkin() return self.skin or 0 end
function Player:SetSkin(value) self.skin = value end
function Player:GetNumBodyGroups() return 2 end
function Player:GetBodygroup(id) return (self.bodygroups or {})[id] or 0 end
function Player:SetBodygroup(id, value)
	self.bodygroups = self.bodygroups or {}
	self.bodygroups[id] = value
end
function Player:GetColor() return self.color or { r = 255, g = 255, b = 255, a = 255 } end
function Player:SetColor(color) self.color = color end
function Player:GetMaterial() return self.material or "" end
function Player:SetMaterial(value) self.material = value end
function Player:GetPlayerColor() return Vector(self.playerColor or Vector(0.24, 0.34, 0.41)) end
function Player:SetPlayerColor(v) self.playerColor = Vector(v) end
function Player:IsRagdoll() return false end
function Player:IsMarkedForDeletion() return false end
function Player:GetCollisionGroup() return self.collisionGroup or 5 end
function Player:SetCollisionGroup(value) self.collisionGroup = value end
function Player:LookupAttachment(name) return name == "eyes" and 1 or 0 end
function Player:GetAttachment(id)
	if id ~= 1 then
		return nil
	end
	return { Pos = self:EyePos(), Ang = self:EyeAngles(), Bone = World.BONE_IDS["ValveBiped.Bip01_Head1"] }
end

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

function Player:GetBoneName(bone) return World.BONE_NAMES[(bone or -1) + 1] end
-- Bones are set up again (ply.setups counts the calls); positions are always current here.
function Player:SetupBones() self.setups = (self.setups or 0) + 1 end

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

-- Scripted weapons (World.Sweps): the instance of the realm whose code runs.
function Player:GetActiveWeapon()
	for _, weapon in ipairs(self.weapons) do
		if weapon.class == self.selected then
			return World.Sweps.Local(weapon)
		end
	end
	if World.Sweps.IsScripted(self.weapons[#self.weapons]) then
		return World.NULL
	end
	return self.weapons[#self.weapons] or World.NULL
end
function Player:GetWeapon(class)
	for _, weapon in ipairs(self.weapons) do
		if weapon.class == class then
			return World.Sweps.Local(weapon)
		end
	end
	return World.NULL
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

function Player:StripWeapons()
	for i = #self.weapons, 1, -1 do
		World.Sweps.Strip(self, self.weapons[i])
	end
	self.weapons = {}
end
function Player:StripWeapon(class)
	for _, weapon in ipairs(self.weapons) do
		if weapon.class == class then
			World.Sweps.Strip(self, weapon)
			return
		end
	end
end
function Player:RemoveAllAmmo()
	self.ammo = {}
	self.clientAmmo = nil
end
-- A class the server registered with weapons.Register is a scripted weapon (World.Sweps).
function Player:Give(class, noAmmo)
	local scripted = self.server ~= nil and World.Sweps.Give(self.server, self, class, noAmmo)
	if scripted then
		return scripted
	end
	local weapon = setmetatable({ __entity = true, class = class, owner = self, valid = true }, WeaponMeta)
	self.weapons[#self.weapons + 1] = weapon
	return weapon
end
function Player:SelectWeapon(class)
	World.Sweps.Select(self, class)
	self.selected = class
end
-- Ammo is kept by name; ids of custom types are the ones of the server (game.AddAmmoType).
local function ammoName(ply, ammoType)
	if type(ammoType) ~= "number" then
		return ammoType
	end
	if World.AMMO[ammoType] ~= nil then
		return World.AMMO[ammoType]
	end
	local custom = ply.server and ply.server.ammoTypes
	local entry = custom and custom[ammoType - #World.AMMO]
	return entry and entry.name or ammoType
end
-- The reserve of the server is .ammo; the code of a client (World.realm) predicts its
-- own copy (.clientAmmo[client]), which a snapshot (Env.Sync) sets to the server's again.
local function reserve(ply)
	local realm = World.realm
	if realm == nil or realm.realm ~= "client" then
		return ply.ammo
	end
	ply.clientAmmo = ply.clientAmmo or {}
	local copy = ply.clientAmmo[realm]
	if copy == nil then
		copy = {}
		for name, count in pairs(ply.ammo) do
			copy[name] = count
		end
		ply.clientAmmo[realm] = copy
	end
	return copy
end
function Player:GiveAmmo(amount, ammoType)
	local name, ammo = ammoName(self, ammoType), reserve(self)
	ammo[name] = (ammo[name] or 0) + amount
	return amount
end
function Player:GetAmmoCount(ammoType) return reserve(self)[ammoName(self, ammoType)] or 0 end
function Player:SetAmmo(amount, ammoType) reserve(self)[ammoName(self, ammoType)] = amount end
function Player:RemoveAmmo(amount, ammoType)
	local name, ammo = ammoName(self, ammoType), reserve(self)
	ammo[name] = math.max(0, (ammo[name] or 0) - amount)
end
-- Lag compensation: .lagCompensation is on or off, .lagCompensations counts the calls.
function Player:LagCompensation(on)
	self.lagCompensation = on == true
	if on then
		self.lagCompensations = (self.lagCompensations or 0) + 1
	end
end
function Player:Ping() return self.ping or 0 end
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
		list[i] = World.Sweps.Local(weapon)
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
	victim:StripWeapons()
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
	self:StripWeapons()
	if self.server ~= nil then
		self.server:Call("PlayerSilentDeath", self)
	end
end

-- The engine's ragdoll of a dead player (an hl2mp_ragdoll at the player; a new one
-- replaces the previous one).
function Player:CreateRagdoll()
	local server = self.server
	if server == nil then
		return
	end
	local old = self.engineRagdoll
	if old ~= nil and old.valid then
		old:Remove()
	end
	local rag = server.G.ents.Create("hl2mp_ragdoll")
	rag:SetPos(self.pos)
	rag:SetAngles(Angle(0, self.angles.y, 0))
	rag:SetModel(self.model)
	rag:SetOwner(self)
	rag:Spawn()
	self.engineRagdoll = rag
end
function Player:GetRagdollEntity()
	local rag = self.engineRagdoll
	if rag ~= nil and rag.valid then
		return rag
	end
	return World.NULL
end

-- Entities -------------------------------------------------------------------------------

-- Rotations: the axes of angles (forward, left, up), local (x forward, y left, z up) to
-- world and back, and the angles of axes (Source's MatrixAngles).
local function axes(ang)
	return ang:Forward(), -ang:Right(), ang:Up()
end

local function rotate(ang, v)
	local f, l, u = axes(ang)
	return f * v.x + l * v.y + u * v.z
end

local function unrotate(ang, v)
	local f, l, u = axes(ang)
	return Vector(v:Dot(f), v:Dot(l), v:Dot(u))
end

local function anglesOf(f, l, u)
	local xy = math.sqrt(f.x * f.x + f.y * f.y)
	if xy > 0.001 then
		return Angle(math.deg(math.atan2(-f.z, xy)), math.deg(math.atan2(f.y, f.x)), math.deg(math.atan2(l.z, u.z)))
	end
	return Angle(math.deg(math.atan2(-f.z, xy)), math.deg(math.atan2(-l.x, l.y)), 0)
end
World.Rotate, World.Unrotate, World.AnglesOf = rotate, unrotate, anglesOf

-- LocalToWorld and WorldToLocal of GMod: a position and angles in the frame (pos, ang).
function World.LocalToWorld(lpos, lang, pos, ang)
	local f, l, u = axes(lang)
	return pos + rotate(ang, lpos), anglesOf(rotate(ang, f), rotate(ang, l), rotate(ang, u))
end
function World.WorldToLocal(wpos, wang, pos, ang)
	local f, l, u = axes(wang)
	return unrotate(ang, wpos - pos), anglesOf(unrotate(ang, f), unrotate(ang, l), unrotate(ang, u))
end

local Entity = {}
local EntityMeta = {
	__index = Entity,
	__tostring = function(ent) return string.format("Entity [%d][%s]", ent.index, ent.class) end,
}
World.EntityMethods = Entity
World.EntityMeta = EntityMeta

-- An entity of the server realm `realm` at `index`. opts: pos, ang, map.
function World.NewEntity(realm, index, class, opts)
	opts = opts or {}
	return setmetatable({ __entity = true, realm = realm, index = index, class = class or "prop_physics",
		valid = true, pos = Vector(opts.pos), ang = Angle(opts.ang), map = opts.map == true, skin = 0,
		bodygroups = {}, color = { r = 255, g = 255, b = 255, a = 255 }, material = "", collisionGroup = 0,
		noDraw = false, callbacks = {}, boneScales = {}, spawned = false, removing = false, damage = {} }, EntityMeta)
end

function Entity:IsValid() return self.valid end
function Entity:IsWorld() return false end
function Entity:IsPlayer() return false end
-- A creature of the engine: ent.npc / ent.nextbot = true.
function Entity:IsNPC() return self.npc == true end
function Entity:IsNextBot() return self.nextbot == true end
function Entity:IsRagdoll() return false end
function Entity:IsWeapon() return false end
function Entity:IsMarkedForDeletion() return self.removing end
-- Recorded in .sounds.
function Entity:EmitSound(name)
	self.sounds = self.sounds or {}
	self.sounds[#self.sounds + 1] = name
end
function Entity:EntIndex() return self.index end
function Entity:GetClass() return self.class end
function Entity:GetPos() return Vector(self.pos) end
function Entity:SetPos(pos) self.pos = Vector(pos) end
function Entity:GetAngles() return Angle(self.ang) end
function Entity:SetAngles(ang) self.ang = Angle(ang) end
function Entity:GetModel() return self.model end
function Entity:SetModel(model) self.model = model end
function Entity:GetSkin() return self.skin end
function Entity:SetSkin(value) self.skin = value end
function Entity:GetNumBodyGroups() return 2 end
function Entity:GetBodygroup(id) return self.bodygroups[id] or 0 end
function Entity:SetBodygroup(id, value) self.bodygroups[id] = value end
function Entity:GetColor() return self.color end
function Entity:SetColor(color) self.color = color end
function Entity:GetMaterial() return self.material end
function Entity:SetMaterial(value) self.material = value end
function Entity:GetCollisionGroup() return self.collisionGroup end
function Entity:SetCollisionGroup(value) self.collisionGroup = value end
function Entity:GetNoDraw() return self.noDraw end
function Entity:GetMoveType() return self.moveType or World.MOVETYPE.NONE end
function Entity:SetMoveType(value) self.moveType = value end
function Entity:SetNoDraw(value) self.noDraw = value == true end
function Entity:GetOwner() return self.owner or World.NULL end
function Entity:SetOwner(ent) self.owner = ent end
function Entity:WaterLevel() return 0 end
function Entity:GetVelocity() return Vector(0, 0, 0) end
function Entity:EyePos() return self:GetPos() end
function Entity:EyeAngles() return self:GetAngles() end
function Entity:LookupBone() return nil end
function Entity:GetBonePosition() return nil end
function Entity:GetBoneName(bone) return World.BONE_NAMES[(bone or -1) + 1] end
function Entity:GetBoneCount() return 0 end
-- Bones are set up again (ent.setups counts the calls); positions are always current here.
function Entity:SetupBones() self.setups = (self.setups or 0) + 1 end
function Entity:LookupAttachment() return 0 end
function Entity:GetAttachment() return nil end
function Entity:GetPhysicsObject() return World.NULL_PHYS end
function Entity:GetPhysicsObjectCount() return 0 end
function Entity:GetPhysicsObjectNum() return World.NULL_PHYS end
function Entity:ManipulateBoneScale(bone, scale) self.boneScales[bone] = Vector(scale) end
function Entity:GetManipulateBoneScale(bone) return Vector(self.boneScales[bone] or Vector(1, 1, 1)) end
function Entity:Activate() self.activated = true end
-- Networked from now on: the linked clients know the entity. A prop_physics gets its
-- physics object (World.AddPhysics, 10 kg) as from its model.
function Entity:Spawn()
	self.spawned = true
	if self.class == "prop_physics" and rawget(self, "GetPhysicsObject") == nil then
		World.AddPhysics(self, 10)
	end
	if self.realm ~= nil then
		self.realm:_Network(self)
	end
end
-- Removed at the next tick of the server (EntityRemoved, then invalid), like the engine.
function Entity:Remove()
	if self.valid and not self.removing then
		self.removing = true
		if self.realm ~= nil then
			self.realm:_QueueRemove(self)
		else
			self.valid = false
		end
	end
end
-- The engine damage of an entity but a player: GM:EntityTakeDamage (true blocks), then
-- the damage is recorded in .damage and pushes the entity (_Push).
function Entity:TakeDamageInfo(dmginfo)
	local realm = self.realm
	if realm ~= nil and realm:Call("EntityTakeDamage", self, dmginfo) == true then
		return
	end
	self.damage[#self.damage + 1] = dmginfo
	self:_Push(dmginfo)
end
function Entity:_Push() end
function Entity:AddCallback(name, fn)
	local list = self.callbacks[name] or {}
	self.callbacks[name] = list
	list[#list + 1] = fn
	return #list
end
function Entity:RemoveCallback(name, id)
	local list = self.callbacks[name]
	if list ~= nil then
		list[id] = false
	end
end
function Entity:GetCallbacks(name)
	local out = {}
	for _, fn in ipairs(self.callbacks[name] or {}) do
		if fn then
			out[#out + 1] = fn
		end
	end
	return out
end

-- Physics objects ----------------------------------------------------------------------------

local Phys = {}
local PhysMeta = {
	__index = Phys,
	__tostring = function(phys) return string.format("PhysObject [%s][%d]", tostring(phys.ent), phys.num) end,
}
World.PhysMethods = Phys

World.NULL_PHYS = setmetatable({ IsValid = function() return false end }, {
	__tostring = function() return "[NULL PhysObject]" end })

local function newPhys(ent, num, bone, mass)
	return setmetatable({ ent = ent, num = num, bone = bone, mass = mass, pos = Vector(0, 0, 0),
		ang = Angle(0, 0, 0), vel = Vector(0, 0, 0), angvel = Vector(0, 0, 0), asleep = false, motion = true,
		gravity = true, forces = {} }, PhysMeta)
end

function Phys:IsValid() return self.ent.valid end
function Phys:GetEntity() return self.ent end
function Phys:GetPos() return Vector(self.pos) end
function Phys:SetPos(pos) self.pos = Vector(pos) end
function Phys:GetAngles() return Angle(self.ang) end
function Phys:SetAngles(ang) self.ang = Angle(ang) end
function Phys:GetVelocity() return Vector(self.vel) end
function Phys:SetVelocity(v)
	self.vel = Vector(v)
	self.asleep = false
end
Phys.SetVelocityInstantaneous = Phys.SetVelocity
function Phys:AddVelocity(v)
	self.vel = self.vel + v
	self.asleep = false
end
-- The angular velocity is local to the object (degrees/s about its axes), like in GMod.
function Phys:GetAngleVelocity() return Vector(self.angvel) end
function Phys:AddAngleVelocity(v)
	self.angvel = self.angvel + v
	self.asleep = false
end
-- A force (mass x units/s) pushes the object; every force is recorded in .forces.
function Phys:ApplyForceCenter(force)
	self.forces[#self.forces + 1] = Vector(force)
	self.vel = self.vel + force / self.mass
	self.asleep = false
end
function Phys:ApplyForceOffset(force)
	self:ApplyForceCenter(force)
end
function Phys:Wake() self.asleep = false end
function Phys:Sleep() self.asleep = true end
function Phys:IsAsleep() return self.asleep end
function Phys:GetMass() return self.mass end
function Phys:SetMass(mass) self.mass = mass end
function Phys:EnableMotion(value) self.motion = value == true end
function Phys:IsMotionEnabled() return self.motion end
function Phys:EnableGravity(value) self.gravity = value == true end
function Phys:IsGravityEnabled() return self.gravity end
function Phys:SetDamping(linear, angular) self.damping = { linear, angular } end
function Phys:WorldToLocalVector(v) return unrotate(self.ang, v) end
function Phys:LocalToWorldVector(v) return rotate(self.ang, v) end

-- Gives a plain entity (a prop) one physics object where it is: physics moves it.
function World.AddPhysics(ent, mass)
	local phys = newPhys(ent, 0, nil, mass or 10)
	phys.pos = Vector(ent.pos)
	phys.ang = Angle(ent.ang)
	ent.moveType = World.MOVETYPE.VPHYSICS
	ent.GetPhysicsObject = function() return phys end
	ent.GetPhysicsObjectCount = function() return 1 end
	ent.GetPhysicsObjectNum = function(_, num) return num == 0 and phys or World.NULL_PHYS end
	return phys
end

-- Ragdolls -------------------------------------------------------------------------------------

local B = "ValveBiped.Bip01_"
-- Physics bones of a ValveBiped player model in the order of its .phy, with masses (kg).
World.PHYS_BONES = {
	{ B .. "Pelvis", 12.5 }, { B .. "Spine2", 24 }, { B .. "R_UpperArm", 3.5 }, { B .. "L_UpperArm", 3.5 },
	{ B .. "L_Forearm", 2 }, { B .. "L_Hand", 0.6 }, { B .. "R_Forearm", 2 }, { B .. "R_Hand", 0.6 },
	{ B .. "R_Thigh", 10 }, { B .. "R_Calf", 4.5 }, { B .. "Head1", 5.5 }, { B .. "L_Thigh", 10 },
	{ B .. "L_Calf", 4.5 }, { B .. "L_Foot", 1.2 }, { B .. "R_Foot", 1.2 },
}
-- The physics bone every other bone moves with.
local PHYS_PARENT = {
	[B .. "Spine"] = B .. "Pelvis", [B .. "Spine1"] = B .. "Pelvis", [B .. "Spine4"] = B .. "Spine2",
	[B .. "Neck1"] = B .. "Spine2", [B .. "L_Clavicle"] = B .. "Spine2", [B .. "R_Clavicle"] = B .. "Spine2",
	[B .. "L_Toe0"] = B .. "L_Foot", [B .. "R_Toe0"] = B .. "R_Foot",
}
local EYES = Vector(3.5, 0, 0) -- the eyes attachment in the frame of the head
local HALF_LIFE = 0.2           -- s: the speed of a ragdoll halves this fast
local REST = 1                  -- units/s: slower is at rest

local Ragdoll = setmetatable({}, { __index = Entity })
local RagdollMeta = {
	__index = Ragdoll,
	__tostring = function(ent) return string.format("Entity [%d][%s]", ent.index, ent.class) end,
}
World.RagdollMethods = Ragdoll

-- A prop_ragdoll of the server realm `realm`; its physics objects appear on Spawn.
function World.NewRagdoll(realm, index, class)
	local ent = World.NewEntity(realm, index, class or "prop_ragdoll")
	ent.phys = {}
	ent.physByBone = {}
	ent.moveType = World.MOVETYPE.VPHYSICS
	return setmetatable(ent, RagdollMeta)
end

function Ragdoll:IsRagdoll() return true end

-- The physics objects stand in the reference pose at the position (the feet) and angles.
function Ragdoll:Spawn()
	for i, entry in ipairs(World.PHYS_BONES) do
		local name, mass = entry[1], entry[2]
		local phys = newPhys(self, i - 1, name, mass)
		phys.pos = self.pos + rotate(self.ang, World.SKELETON[name])
		phys.ang = Angle(self.ang)
		self.phys[i - 1] = phys
		self.physByBone[name] = phys
	end
	Entity.Spawn(self)
end

local function root(self)
	return self.phys[0]
end

function Ragdoll:GetPos()
	local phys = root(self)
	return phys and phys:GetPos() or Vector(self.pos)
end
-- Before Spawn: where the ragdoll appears; afterwards the whole body moves (teleport).
function Ragdoll:SetPos(pos)
	local phys = root(self)
	if phys == nil then
		self.pos = Vector(pos)
		return
	end
	local delta = pos - phys.pos
	for i = 0, #World.PHYS_BONES - 1 do
		self.phys[i].pos = self.phys[i].pos + delta
	end
end
function Ragdoll:GetAngles()
	local phys = root(self)
	return phys and phys:GetAngles() or Angle(self.ang)
end
function Ragdoll:SetAngles(ang)
	if root(self) == nil then
		self.ang = Angle(ang)
	end
end
function Ragdoll:GetVelocity()
	local phys = root(self)
	return phys and phys:GetVelocity() or Vector(0, 0, 0)
end
function Ragdoll:GetPhysicsObject() return root(self) or World.NULL_PHYS end
function Ragdoll:GetPhysicsObjectCount() return root(self) and #World.PHYS_BONES or 0 end
function Ragdoll:GetPhysicsObjectNum(num) return self.phys[num] or World.NULL_PHYS end
function Ragdoll:TranslatePhysBoneToBone(num)
	local entry = World.PHYS_BONES[num + 1]
	return entry and World.BONE_IDS[entry[1]] or -1
end
function Ragdoll:TranslateBoneToPhysBone(bone)
	local name = World.BONE_NAMES[bone + 1]
	name = PHYS_PARENT[name] or name
	local phys = self.physByBone[name]
	return phys and phys.num or -1
end
function Ragdoll:LookupBone(name) return World.BONE_IDS[name] end
function Ragdoll:GetBoneCount() return #World.BONE_NAMES end
-- Physics bones where their objects are; the others hang on theirs as in the skeleton.
function Ragdoll:GetBonePosition(bone)
	local name = World.BONE_NAMES[(bone or -1) + 1]
	if name == nil or root(self) == nil then
		return nil
	end
	local phys = self.physByBone[name]
	if phys ~= nil then
		return phys:GetPos(), phys:GetAngles()
	end
	local parent = PHYS_PARENT[name]
	phys = self.physByBone[parent]
	return phys.pos + rotate(phys.ang, World.SKELETON[name] - World.SKELETON[parent]), phys:GetAngles()
end
-- The force of a damage pushes the physics object nearest to its point (the engine swaps
-- in the object of the bone a trace hit).
function Ragdoll:_Push(dmginfo)
	local pos = dmginfo:GetDamagePosition()
	local nearest, best
	for i = 0, #World.PHYS_BONES - 1 do
		local phys = self.phys[i]
		local d = phys and phys.pos:DistToSqr(pos)
		if d ~= nil and (best == nil or d < best) then
			nearest, best = phys, d
		end
	end
	if nearest ~= nil then
		nearest:ApplyForceOffset(dmginfo:GetDamageForce(), pos)
	end
end
function Ragdoll:LookupAttachment(name) return name == "eyes" and 1 or 0 end
function Ragdoll:GetAttachment(id)
	local head = self.physByBone[B .. "Head1"]
	if id ~= 1 or head == nil then
		return nil
	end
	return { Pos = head.pos + rotate(head.ang, EYES), Ang = Angle(head.ang), Bone = World.BONE_IDS[B .. "Head1"] }
end
function Ragdoll:EyePos()
	local eyes = self:GetAttachment(1)
	return eyes and eyes.Pos or self:GetPos()
end
function Ragdoll:EyeAngles()
	local eyes = self:GetAttachment(1)
	return eyes and eyes.Ang or self:GetAngles()
end

-- One tick of physics (see the top of the file).
function Ragdoll:_Simulate(dt)
	local momentum, mass = Vector(0, 0, 0), 0
	local list = {}
	for i = 0, #World.PHYS_BONES - 1 do
		local phys = self.phys[i]
		if phys ~= nil and not phys.asleep and phys.motion then
			list[#list + 1] = phys
			momentum = momentum + phys.vel * phys.mass
			mass = mass + phys.mass
		end
	end
	if mass == 0 then
		return
	end
	local vel = momentum / mass
	for _, phys in ipairs(list) do
		phys.pos = phys.pos + vel * dt
	end
	vel = vel * 0.5 ^ (dt / HALF_LIFE)
	if vel:Length() < REST then
		vel = Vector(0, 0, 0)
	end
	for _, phys in ipairs(list) do
		phys.vel = Vector(vel)
		phys.angvel = phys.angvel * 0.5 ^ (dt / HALF_LIFE)
	end
end

-- Turns the pose of `rag` about its pelvis so that what faced the angles `from` faces
-- `to`, then moves it by `offset` (a Vector or nil).
function World.TurnRagdoll(rag, from, to, offset)
	local pivot = rag.phys[0].pos
	offset = offset or Vector(0, 0, 0)
	for i = 0, #World.PHYS_BONES - 1 do
		local phys = rag.phys[i]
		phys.pos = pivot + rotate(to, unrotate(from, phys.pos - pivot)) + offset
		local f, l, u = axes(phys.ang)
		phys.ang = anglesOf(rotate(to, unrotate(from, f)), rotate(to, unrotate(from, l)),
			rotate(to, unrotate(from, u)))
	end
end

-- Lays a standing `rag` down where it stands: on its back (prone: on its face), the
-- pelvis 6 units above the feet's floor, head away from where it faced (prone: towards).
function World.LayRagdoll(rag, prone)
	local pelvis = rag.phys[0]
	local yaw = pelvis.ang.y
	local floor = pelvis.pos.z - World.SKELETON[B .. "Pelvis"].z
	World.TurnRagdoll(rag, Angle(0, yaw, 0), Angle(prone and 90 or -90, yaw, 0))
	World.MoveRagdoll(rag, Vector(0, 0, floor + 6 - pelvis.pos.z))
end

-- Moves every physics object of `rag` by `offset`.
function World.MoveRagdoll(rag, offset)
	for i = 0, #World.PHYS_BONES - 1 do
		rag.phys[i].pos = rag.phys[i].pos + offset
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
	-- The engine's ragdoll of the player (hl2mp_ragdoll) unless the damage removes it.
	DoPlayerDeath = function(_, _, ply, attacker, dmginfo)
		if dmginfo == nil or bit.band(dmginfo:GetDamageType(), World.DMG.REMOVENORAGDOLL) == 0 then
			ply:CreateRagdoll()
		end
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
	-- The view of the player's eyes (no vehicle, drive or weapon view in tests).
	CalcView = function(_, _, _, origin, angles, fov, znear, zfar)
		return { origin = origin, angles = angles, fov = fov, znear = znear, zfar = zfar, drawviewer = false }
	end,
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
	for name, value in pairs(World.MOVETYPE) do
		G["MOVETYPE_" .. name] = value
	end
	G.DamageInfo = World.DamageInfo
	World.Sweps.Install(env, G)
	G.LocalToWorld = World.LocalToWorld
	G.WorldToLocal = World.WorldToLocal
	for name, value in pairs(World.Geometry.MASK) do
		G["MASK_" .. name] = value
	end
	for name, value in pairs(World.Geometry.CONTENTS) do
		G["CONTENTS_" .. name] = value
	end
	for name, value in pairs(World.Geometry.MAT) do
		G["MAT_" .. name] = value
	end
	for name, value in pairs(World.COLLISION_GROUP) do
		G["COLLISION_GROUP_" .. name] = value
	end
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

	-- Traces hit nothing unless a test sets env.traceHull / env.traceLine (Env.Geometry).
	local function emptyTrace(trace)
		local out = trace.output or {}
		out.Hit, out.StartSolid, out.AllSolid, out.HitWorld, out.HitSky = false, false, false, false, false
		out.Fraction, out.HitPos, out.Entity = 1, Vector(trace.endpos), World.NULL
		out.HitNormal, out.MatType, out.HitGroup, out.FractionLeftSolid = Vector(0, 0, 0), 0, 0, 0
		return out
	end
	function G.util.TraceHull(trace)
		return (env.traceHull or emptyTrace)(trace)
	end
	function G.util.TraceLine(trace)
		return (env.traceLine or emptyTrace)(trace)
	end
	-- CONTENTS_* at a point: empty unless a test sets env.pointContents(pos).
	function G.util.PointContents(pos)
		return env.pointContents and env.pointContents(pos) or 0
	end
	-- Like the engine: every entity in the sphere takes a copy of the damage, less linearly
	-- with the distance, with a force away from the centre. env.blasts records the calls
	-- ({ pos, radius, damage, type, attacker, inflictor }).
	env.blasts = {}
	function G.util.BlastDamageInfo(dmginfo, pos, radius)
		local damage = dmginfo:GetDamage()
		env.blasts[#env.blasts + 1] = { pos = Vector(pos), radius = radius, damage = damage,
			type = dmginfo:GetDamageType(), attacker = dmginfo:GetAttacker(), inflictor = dmginfo:GetInflictor() }
		for _, ent in ipairs(G.ents.FindInSphere(pos, radius)) do
			if ent ~= World.WORLD and ent.TakeDamageInfo ~= nil and ent:IsValid() then
				local offset = ent:GetPos() - pos
				local share = 1 - offset:Length() / radius
				local each = World.DamageInfo()
				each:SetAttacker(dmginfo:GetAttacker())
				each:SetInflictor(dmginfo:GetInflictor())
				each:SetDamageType(dmginfo:GetDamageType())
				each:SetDamage(damage * share)
				each:SetDamagePosition(pos)
				local dir = offset:LengthSqr() > 1e-6 and offset:GetNormalized() or Vector(0, 0, 1)
				each:SetDamageForce(dir * (damage * share * 300))
				ent:TakeDamageInfo(each)
			end
		end
	end

	World.InstallEffects(env, G)

	-- Welds are entities (phys_constraint) recorded in env.welds: { ent1, ent2, bone1, bone2, constraint }.
	env.welds = {}
	G.constraint = {}
	function G.constraint.Weld(ent1, ent2, bone1, bone2, forceLimit)
		if env.realm ~= "server" then
			return nil
		end
		local weld = G.ents.Create("phys_constraint")
		weld:Spawn()
		env.welds[#env.welds + 1] = { ent1, ent2, bone1, bone2, weld, forceLimit = forceLimit }
		return weld
	end

	if env.realm == "client" then
		World.InstallDrawing(env, G)
	end
end

-- Effect data of util.Effect: every Set* has its Get*.
local EffectData = {}
EffectData.__index = EffectData
local EFFECT_FIELDS = { "Origin", "Start", "Normal", "Angles", "Magnitude", "Scale", "Radius", "Entity",
	"EntIndex", "SurfaceProp", "DamageType", "HitBox", "Flags", "Attachment", "Color", "MaterialIndex" }
for _, field in ipairs(EFFECT_FIELDS) do
	EffectData["Set" .. field] = function(self, value) self[field] = value end
	EffectData["Get" .. field] = function(self) return self[field] end
end

function World.EffectData()
	return setmetatable({}, EffectData)
end

-- Effects, decals, shakes, prediction and lag compensation of a realm. Recorded:
-- env.fx ({ name, data, filter }), env.decals ({ name, start, endpos }), env.shakes
-- ({ pos, amplitude, frequency, duration, radius }). IsFirstTimePredicted answers
-- env.firstTimePredicted (default true); GetPredictionPlayer answers env.predictionPlayer
-- (the player whose command runs, Env.RunCommand); util.SharedRandom is a hash of its
-- arguments and env.commandNumber, the same on every realm.
function World.InstallEffects(env, G)
	env.fx, env.decals, env.shakes = {}, {}, {}
	G.EffectData = World.EffectData
	function G.util.Effect(name, data, _, filter)
		env.fx[#env.fx + 1] = { name = name, data = data, filter = filter }
	end
	function G.util.Decal(name, start, endpos)
		env.decals[#env.decals + 1] = { name = name, start = Vector(start), endpos = Vector(endpos) }
	end
	function G.util.ScreenShake(pos, amplitude, frequency, duration, radius)
		env.shakes[#env.shakes + 1] = { pos = Vector(pos), amplitude = amplitude, frequency = frequency,
			duration = duration, radius = radius }
	end
	function G.IsFirstTimePredicted()
		return env.firstTimePredicted ~= false
	end
	function G.GetPredictionPlayer()
		return env.predictionPlayer or World.NULL
	end
	function G.util.SharedRandom(name, low, high, seed)
		local key = tostring(name) .. ":" .. tostring(seed or 0) .. ":" .. tostring(env.commandNumber or 0)
		local h = 5381
		for i = 1, #key do
			h = (h * 33 + key:byte(i)) % 2147483647
		end
		h = h * 16807 % 2147483647
		return low + (high - low) * (h / 2147483647)
	end
	function G.FrameTime()
		return env.frameTime or 0.015
	end
	G.engine = G.engine or {}
	function G.engine.TickInterval()
		return env.tickInterval or 0.015
	end
	-- Ticks so far: the game time over the tick interval.
	function G.engine.TickCount()
		return math.floor(env.time / (env.tickInterval or 0.015) + 0.5)
	end
end

-- Records drawn texts in env.drawn, rectangles in env.rects ({ x, y, w, h, r, g, b, a },
-- textured ones with the material name first) and screen effects in env.effects; text
-- sizes are 8 px per byte by 16 px. env.bindings: keys of binds for input.LookupBinding.
function World.InstallDrawing(env, G)
	env.drawn = {}
	env.fonts = {}
	env.rects = {}
	env.effects = {}
	env.bindings = { ["+reload"] = "r", ["+jump"] = "space" }
	local color = { 255, 255, 255, 255 }
	local material = nil
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
		SetDrawColor = function(r, g, b, a)
			if type(r) == "table" then
				r, g, b, a = r.r, r.g, r.b, r.a
			end
			color = { r, g, b, a or 255 }
		end,
		DrawRect = function(x, y, w, h)
			env.rects[#env.rects + 1] = { x, y, w, h, color[1], color[2], color[3], color[4] }
		end,
		SetMaterial = function(mat) material = mat end,
		DrawTexturedRect = function(x, y, w, h)
			env.rects[#env.rects + 1] = { material and material.name or "?", x, y, w, h, color[1], color[2], color[3],
				color[4] }
		end,
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
	function G.Material(name)
		return { name = name, IsError = function() return false end }
	end
	function G.DrawColorModify(params)
		local copy = {}
		for key, value in pairs(params) do
			copy[key] = value
		end
		env.effects[#env.effects + 1] = { "color", copy }
	end
	function G.DrawMotionBlur(add, alpha, delay)
		env.effects[#env.effects + 1] = { "blur", add, alpha, delay }
	end
	G.input = {
		LookupBinding = function(bind) return env.bindings[bind] end,
	}
end

World.Geometry.Bind(World)
World.Sweps.Bind(World)

return World
