-- Emulated game world for the GMod test environment (tests/gmod/env.lua): vectors and
-- angles, players with the engine methods the gamemode uses (spawn, death, observer
-- modes, teams, weapons, frags), the base gamemode behaviour of player hooks, the
-- player, team, ents and game libraries, hull traces and the 2D drawing API of clients.
--
-- Player actions run gamemode hooks like the engine does: ply:Spawn() calls
-- GM:PlayerSelectSpawn and GM:PlayerSpawn, ply:Kill() calls GM:DoPlayerDeath and
-- GM:PlayerDeath, ply:KillSilent() calls GM:PlayerSilentDeath. A player object is shared
-- by the server realm and the clients, like networked state that is always up to date.

local World = {}

World.TEAM_CONNECTING = 0
World.TEAM_UNASSIGNED = 1001
World.TEAM_SPECTATOR = 1002

World.OBS_MODE = { NONE = 0, DEATHCAM = 1, FREEZECAM = 2, FIXED = 3, IN_EYE = 4, CHASE = 5, ROAMING = 6 }
World.IN = {
	ATTACK = 1, JUMP = 2, DUCK = 4, FORWARD = 8, BACK = 16, USE = 32, MOVELEFT = 512, MOVERIGHT = 1024,
	ATTACK2 = 2048, RELOAD = 8192, SCORE = 65536,
}

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
	__unm = function(a) return Vector(-a.x, -a.y, -a.z) end,
	__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end,
}
local AngleMeta = { __tostring = function(a) return string.format("Angle(%g, %g, %g)", a.x, a.y, a.z) end }

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

-- Entities -------------------------------------------------------------------------------

World.NULL = setmetatable({
	__entity = true,
	IsValid = function() return false end,
	IsPlayer = function() return false end,
	EntIndex = function() return 0 end,
	GetClass = function() return "" end,
}, { __tostring = function() return "[NULL Entity]" end })

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
	}, PlayerMeta)
end

function Player:IsValid() return self.valid end
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

local DamageInfo = {}
DamageInfo.__index = DamageInfo
function DamageInfo:GetAttacker() return self.attacker end
function DamageInfo:GetInflictor() return self.inflictor end
function DamageInfo:GetDamage() return self.damage end
function DamageInfo:GetDamageType() return 0 end
function DamageInfo:IsDamageType() return false end

-- Kills `victim`: DoPlayerDeath, then PlayerDeath, like the engine. Weapons are lost.
function World.Die(victim, attacker, inflictor)
	if not victim.alive then
		return
	end
	victim.alive = false
	victim.weapons = {}
	attacker = attacker or victim
	inflictor = inflictor or attacker
	local server = victim.server
	if server ~= nil then
		local dmginfo = setmetatable({ attacker = attacker, inflictor = inflictor, damage = victim.health }, DamageInfo)
		server:Call("DoPlayerDeath", victim, attacker, dmginfo)
		server:Call("PlayerDeath", victim, inflictor, attacker)
	end
end

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
