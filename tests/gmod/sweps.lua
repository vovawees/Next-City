-- Scripted weapons (SWEPs) of the emulated realms (tests/gmod/env.lua), like GMod:
--   classes    weapons.Register / Get / GetStored / GetList / IsBasedOn of every realm; a
--              class takes the fields its own table lacks from its Base (by default
--              weapon_base, a minimal one: SetHoldType, ShootEffects, Deploy, Holster)
--   instances  ply:Give(class) of a class the server knows makes the weapon on the
--              server (SetupDataTables, Initialize, the DefaultClip, Equip) and one of
--              the client's class on every linked client with the same index: each realm
--              runs its own code on its own state. Env.Sync(server) copies what the
--              engine networks (NetworkVars, clips, next attacks) from the server to the
--              clients, like a snapshot
--   switching  ply:SelectWeapon(class): Holster of the active weapon (false keeps it),
--              then Deploy, on every realm; StripWeapon / StripWeapons: Holster of the
--              active one, then OnRemove
--   commands   Env.Use(realm, ply, buttons, opts): one user command: GM:StartCommand
--              (which may change the buttons), KeyDown / KeyPressed / KeyReleased, then
--              ItemPostFrame of the active weapon of that realm: SecondaryAttack and
--              PrimaryAttack when their next attack is due (a non-automatic one only on a
--              press), Reload while held, then Think; meanwhile GetPredictionPlayer is the
--              player and IsFirstTimePredicted answers opts.firstTime (default true)
-- The realm whose code runs (Env:Call, Env.Use, Env.As) decides which instance
-- ply:GetActiveWeapon() and ply:GetWeapons() return. Recorded: weapon.anims
-- (SendWeaponAnim), weapon.sounds (EmitSound), weapon.holdType; ply.animations
-- (SetAnimation), ply.muzzleFlashes.

local Sweps = {}

local band = bit.band
local bnot = bit.bnot
local World, Vector, Angle

Sweps.ACT = {
	VM_DRAW = 172, VM_HOLSTER = 173, VM_IDLE = 174, VM_PULLBACK_HIGH = 177, VM_PULLBACK_LOW = 178, VM_THROW = 179,
	VM_PULLPIN = 180, VM_PRIMARYATTACK = 181, VM_SECONDARYATTACK = 182, VM_RELOAD = 183, VM_DRYFIRE = 184,
	VM_HITLEFT = 185, VM_HITRIGHT = 187, VM_HITCENTER = 189, VM_MISSLEFT = 191, VM_MISSRIGHT = 193,
	VM_MISSCENTER = 195, VM_SWINGHARD = 199, SHOTGUN_RELOAD_START = 267, SHOTGUN_RELOAD_FINISH = 268,
	VM_DEPLOY = 1913,
}
Sweps.PLAYER = { IDLE = 0, WALK = 1, JUMP = 2, SUPERJUMP = 3, DIE = 4, ATTACK1 = 5, IN_VEHICLE = 6, RELOAD = 7 }

local NETWORK_DEFAULTS = { Int = 0, Float = 0, Bool = false, String = "" }

function Sweps.Bind(world)
	World, Vector, Angle = world, world.Vector, world.Angle
	return Sweps
end

local function copy(value)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = copy(v)
	end
	return out
end

-- Fields of `base` that `t` lacks, into `t`, through tables (table.Inherit).
local function inherit(t, base)
	for k, v in pairs(base) do
		if t[k] == nil then
			t[k] = v
		elseif k ~= "BaseClass" and type(t[k]) == "table" and type(v) == "table" and getmetatable(v) == nil then
			inherit(t[k], v)
		end
	end
	t.BaseClass = base
	return t
end

-- The minimal weapon_base of the emulator.
local function weaponBase(G)
	local base = { Primary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
		Secondary = { ClipSize = -1, DefaultClip = -1, Automatic = false, Ammo = "none" },
		PrintName = "Scripted Weapon", HoldType = "pistol", Spawnable = false, DrawCrosshair = true,
		ViewModel = "models/weapons/v_pistol.mdl", WorldModel = "models/weapons/w_pistol.mdl" }
	function base:SetWeaponHoldType(t)
		self.holdType = t
	end
	base.SetHoldType = base.SetWeaponHoldType
	function base:ShootEffects()
		self:SendWeaponAnim(G.ACT_VM_PRIMARYATTACK)
		self:GetOwner():MuzzleFlash()
		self:GetOwner():SetAnimation(G.PLAYER_ATTACK1)
	end
	function base:Deploy() return true end
	function base:Holster() return true end
	function base:PrimaryAttack() end
	function base:SecondaryAttack() end
	function base:Reload() end
	return base
end

-- The weapons library of a realm.
function Sweps.Install(env, G)
	env.sweps = {}
	env.lastButtons = {}
	for name, value in pairs(Sweps.ACT) do
		G["ACT_" .. name] = value
	end
	for name, value in pairs(Sweps.PLAYER) do
		G["PLAYER_" .. name] = value
	end
	local stored = { weapon_base = weaponBase(G) }
	env.sweps = stored
	G.weapons = {}
	function G.weapons.Register(t, class)
		t.ClassName = class
		stored[class] = t
	end
	function G.weapons.GetStored(class)
		return stored[class]
	end
	function G.weapons.Get(class)
		local t = stored[class]
		if t == nil then
			return nil
		end
		local out = copy(t)
		out.Base = out.Base or "weapon_base"
		if out.Base ~= class then
			local base = G.weapons.Get(out.Base)
			if base ~= nil then
				inherit(out, base)
			end
		end
		return out
	end
	function G.weapons.GetList()
		local list = {}
		for class, t in pairs(stored) do
			if class ~= "weapon_base" then
				list[#list + 1] = t
			end
		end
		table.sort(list, function(a, b) return a.ClassName < b.ClassName end)
		return list
	end
	function G.weapons.IsBasedOn(class, base)
		local t = stored[class]
		while t ~= nil do
			if t.Base == base then
				return true
			end
			if t.Base == nil or t.Base == t.ClassName then
				return false
			end
			t = stored[t.Base]
		end
		return false
	end
end

-- Engine methods of scripted weapons (then the ones of every entity).
local Weapon = {}
Sweps.WeaponMethods = Weapon

function Weapon:IsWeapon() return true end
function Weapon:IsScripted() return true end
function Weapon:GetOwner() return self.owner or World.NULL end
function Weapon:SetOwner(ply) self.owner = ply end
function Weapon:Clip1() return self.clip1 end
function Weapon:SetClip1(n) self.clip1 = n end
function Weapon:Clip2() return self.clip2 end
function Weapon:SetClip2(n) self.clip2 = n end
function Weapon:GetMaxClip1() return self.Primary and self.Primary.ClipSize or -1 end
function Weapon:GetMaxClip2() return self.Secondary and self.Secondary.ClipSize or -1 end
function Weapon:GetPrimaryAmmoType()
	return self.realm.G.game.GetAmmoID(self.Primary and self.Primary.Ammo or "none")
end
function Weapon:GetSecondaryAmmoType()
	return self.realm.G.game.GetAmmoID(self.Secondary and self.Secondary.Ammo or "none")
end
function Weapon:Ammo1()
	local owner = self.owner
	return owner ~= nil and owner:GetAmmoCount(self:GetPrimaryAmmoType()) or 0
end
function Weapon:GetNextPrimaryFire() return self.nextPrimary end
function Weapon:SetNextPrimaryFire(t) self.nextPrimary = t end
function Weapon:GetNextSecondaryFire() return self.nextSecondary end
function Weapon:SetNextSecondaryFire(t) self.nextSecondary = t end
function Weapon:SendWeaponAnim(act)
	self.activity = act
	self.anims[#self.anims + 1] = act
end
function Weapon:GetActivity() return self.activity or 0 end
function Weapon:GetHoldType() return self.holdType or "" end
function Weapon:EmitSound(name)
	self.sounds[#self.sounds + 1] = name
end
function Weapon:SetLastShootTime(t) self.lastShot = t or self.realm.time end
function Weapon:LastShootTime() return self.lastShot or 0 end
function Weapon:IsCarriedByLocalPlayer()
	return self.realm.realm == "client" and self.owner ~= nil and self.owner == self.realm.localPlayer
end
-- Server: runs fn(arg) of the instances of the clients.
function Weapon:CallOnClient(name, arg)
	for _, mirror in pairs(self.mirrors or {}) do
		local fn = mirror[name]
		if fn ~= nil then
			fn(mirror, arg)
		end
	end
end
-- NetworkVar(type, [slot,] name): Get<name> / Set<name> on the instance; dt holds the values.
function Weapon:NetworkVar(kind, slot, name)
	if type(slot) == "string" then
		name = slot
	end
	local default = NETWORK_DEFAULTS[kind]
	if kind == "Vector" then
		default = Vector(0, 0, 0)
	elseif kind == "Angle" then
		default = Angle(0, 0, 0)
	elseif kind == "Entity" then
		default = World.NULL
	end
	self.dt[name] = default
	self.dtKinds[name] = kind
	self["Get" .. name] = function(ent) return ent.dt[name] end
	self["Set" .. name] = function(ent, value)
		local old = ent.dt[name]
		ent.dt[name] = value
		local notify = ent.dtNotify[name]
		if notify ~= nil and old ~= value then
			for _, fn in ipairs(notify) do
				fn(ent, name, old, value)
			end
		end
	end
end
function Weapon:NetworkVarNotify(name, fn)
	local list = self.dtNotify[name] or {}
	self.dtNotify[name] = list
	list[#list + 1] = fn
end

local WeaponMeta = {
	__index = function(_, key)
		local method = Weapon[key]
		if method ~= nil then
			return method
		end
		return World.EntityMethods[key]
	end,
	__tostring = function(w) return string.format("Weapon [%d][%s]", w.index, w.class) end,
}

-- Runs a hook of `weapon` as code of its realm (World.realm).
local function call(weapon, name, ...)
	local fn = weapon[name]
	if fn == nil then
		return nil
	end
	local previous = World.realm
	World.realm = weapon.realm
	local results = { pcall(fn, weapon, ...) }
	World.realm = previous
	if not results[1] then
		weapon.realm:_Error(string.format("weapon %s: %s: %s", weapon.class, name, tostring(results[2])))
		return nil
	end
	return unpack(results, 2)
end
Sweps.Call = call

-- An instance of `class` of `realm` held by `owner` at `index`.
function Sweps.Create(realm, class, owner, index)
	local t = realm.G.weapons.Get(class)
	local ent = World.NewEntity(realm, index, class, { pos = owner:GetPos() })
	for k, v in pairs(t) do
		ent[k] = v
	end
	ent.scripted, ent.owner, ent.spawned = true, owner, true
	ent.Weapon, ent.Owner = ent, owner
	ent.clip1, ent.clip2, ent.nextPrimary, ent.nextSecondary = 0, 0, 0, 0
	ent.dt, ent.dtKinds, ent.dtNotify = {}, {}, {}
	ent.anims, ent.sounds = {}, {}
	setmetatable(ent, WeaponMeta)
	call(ent, "SetupDataTables")
	call(ent, "Initialize")
	return ent
end

-- Whether `value` is a scripted weapon of the emulator.
function Sweps.IsScripted(value)
	return type(value) == "table" and rawget(value, "scripted") == true
end

-- The instance of the realm whose code runs (a client) of a weapon of the server.
function Sweps.Local(weapon)
	local realm = World.realm
	if realm == nil or realm.realm ~= "client" or not Sweps.IsScripted(weapon) then
		return weapon
	end
	return realm.entities[weapon.index] or World.NULL
end

-- Gives `ply` a scripted weapon of `class` on the server `server`; nil if unknown there.
function Sweps.Give(server, ply, class, noAmmo)
	if server.G.weapons.GetStored(class) == nil then
		return nil
	end
	local index = server:_NextIndex()
	local weapon = Sweps.Create(server, class, ply, index)
	server.entities[index] = weapon
	weapon.mirrors = {}
	for _, client in pairs(server.links) do
		if client.G.weapons.GetStored(class) ~= nil then
			local mirror = Sweps.Create(client, class, ply, index)
			client.entities[index] = mirror
			weapon.mirrors[client] = mirror
		end
	end
	local function fill(w)
		local clip, default = w:GetMaxClip1(), w.Primary and w.Primary.DefaultClip or -1
		if clip > 0 then
			w.clip1 = math.max(0, math.min(clip, default))
		end
		return clip, default
	end
	local clip, default = fill(weapon)
	for _, mirror in pairs(weapon.mirrors) do
		fill(mirror)
	end
	if not noAmmo and default > 0 then
		local rest = clip > 0 and default - weapon.clip1 or default
		if rest > 0 then
			ply:GiveAmmo(rest, weapon:GetPrimaryAmmoType())
		end
	end
	ply.weapons[#ply.weapons + 1] = weapon
	call(weapon, "Equip", ply)
	if ply.selected == nil or not ply:HasWeapon(ply.selected) then
		ply:SelectWeapon(class)
	end
	return weapon
end

local function instances(weapon)
	local list = { weapon }
	for _, mirror in pairs(weapon.mirrors or {}) do
		list[#list + 1] = mirror
	end
	return list
end

local function find(ply, class)
	for _, weapon in ipairs(ply.weapons) do
		if weapon.class == class then
			return weapon
		end
	end
	return nil
end

-- Switches to `class`: Holster of the active one (false keeps it), then Deploy.
function Sweps.Select(ply, class)
	local target = find(ply, class)
	if target == nil then
		return
	end
	local current = ply.selected ~= nil and find(ply, ply.selected) or nil
	if current == target then
		return
	end
	if current ~= nil and Sweps.IsScripted(current) then
		if call(current, "Holster", target) == false then
			return
		end
		for client, mirror in pairs(current.mirrors) do
			call(mirror, "Holster", client.entities[target.index] or World.NULL)
		end
	end
	ply.selected = class
	if Sweps.IsScripted(target) then
		for _, instance in ipairs(instances(target)) do
			call(instance, "Deploy")
		end
	end
end

local function removeInstance(instance)
	call(instance, "OnRemove")
	instance.valid = false
	if instance.realm.entities[instance.index] == instance then
		instance.realm.entities[instance.index] = nil
	end
end

-- Takes `weapon` (of the server) away from `ply`.
function Sweps.Strip(ply, weapon)
	if ply.selected == weapon.class and Sweps.IsScripted(weapon) then
		for _, instance in ipairs(instances(weapon)) do
			call(instance, "Holster", World.NULL)
		end
	end
	for i, held in ipairs(ply.weapons) do
		if held == weapon then
			table.remove(ply.weapons, i)
			break
		end
	end
	if ply.selected == weapon.class then
		ply.selected = nil
	end
	if Sweps.IsScripted(weapon) then
		for _, instance in ipairs(instances(weapon)) do
			removeInstance(instance)
		end
	end
end

-- What the engine networks of the weapons of `server`, to the instances of the clients.
function Sweps.Sync(server)
	for _, ent in pairs(server.entities) do
		if type(ent) == "table" and ent.IsPlayer ~= nil and ent:IsPlayer() then
			ent.clientAmmo = nil
		end
	end
	for _, weapon in pairs(server.entities) do
		if Sweps.IsScripted(weapon) then
			for _, mirror in pairs(weapon.mirrors) do
				for name, value in pairs(weapon.dt) do
					mirror.dt[name] = value
				end
				mirror.clip1, mirror.clip2 = weapon.clip1, weapon.clip2
				mirror.nextPrimary, mirror.nextSecondary = weapon.nextPrimary, weapon.nextSecondary
				mirror.owner = weapon.owner
			end
		end
	end
end

-- ItemPostFrame of `weapon` for a command with `buttons` (`pressed` this command).
function Sweps.PostFrame(weapon, buttons, pressed)
	local IN = World.IN
	local now = weapon.realm.time
	if band(buttons, IN.ATTACK2) ~= 0 and weapon:GetNextSecondaryFire() <= now then
		call(weapon, "SecondaryAttack")
	end
	-- A semi-automatic weapon fires on a press only.
	local trigger = weapon.Primary == nil or weapon.Primary.Automatic ~= false or band(pressed, IN.ATTACK) ~= 0
	if band(buttons, IN.ATTACK) ~= 0 and trigger and weapon:IsValid() and weapon:GetNextPrimaryFire() <= now then
		call(weapon, "PrimaryAttack")
	end
	if band(buttons, IN.RELOAD) ~= 0 and weapon:IsValid() then
		call(weapon, "Reload")
	end
	if weapon:IsValid() then
		call(weapon, "Think")
	end
end

-- The keys of `ply` for a command with `buttons` after one with `last`.
function Sweps.SetKeys(ply, buttons, last)
	local keys, pressed, released = {}, {}, {}
	for _, value in pairs(World.IN) do
		if band(buttons, value) ~= 0 then
			keys[value] = true
			if band(last, value) == 0 then
				pressed[value] = true
			end
		elseif band(last, value) ~= 0 then
			released[value] = true
		end
	end
	ply.keys, ply.pressedKeys, ply.releasedKeys, ply.lastButtons = keys, pressed, released, last
	return band(buttons, bnot(last))
end

return Sweps
