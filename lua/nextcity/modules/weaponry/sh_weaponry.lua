-- Weaponry, shared part: rounds, firearms, melee weapons, throwables and their items, on
-- both realms in the same order (engine ammo types and scripted weapons).
--
-- Names: lang/<code>/ammo.lua (ammo.<id>), weapons.lua (weapons.<class>), melee.lua,
-- throwables.lua and items.lua (items.<id>) of this package.

local M = NC.Module("weaponry")

local pairs = pairs
local ipairs = ipairs

-- Rounds ------------------------------------------------------------------------------------

M.AMMO = {
	{ "9x19_fmj", { caliber = "9x19", mass = 8, velocity = 360, diameter = 9, penetration = 60, range = 540 } },
	{ "357_jhp", { caliber = ".357", mass = 10.2, velocity = 440, diameter = 9.1, penetration = 40, expansion = 0.6,
		range = 520 } },
	{ "46x30_ap", { caliber = "4.6x30", mass = 2, velocity = 720, diameter = 4.65, penetration = 45, range = 450,
		ap = 1.6 } },
	{ "556_m855", { caliber = "5.56x45", mass = 4, velocity = 940, diameter = 5.7, penetration = 70, range = 900,
		ap = 1.3, fragment = 15, fragmentFactor = 2 } },
	{ "12g_buck", { caliber = "12/70", mass = 3.5, velocity = 400, diameter = 8.4, penetration = 30, range = 100,
		pellets = 9, spread = 1.5 } },
	{ "12g_slug", { caliber = "12/70", mass = 28, velocity = 430, diameter = 18.5, penetration = 40, expansion = 0.3,
		range = 250 } },
}

-- Firearms ----------------------------------------------------------------------------------

M.FIREARMS = {
	-- H&K USP Match (the pistol of HL2).
	{ "nc_usp", { caliber = "9x19", magazine = 15, rpm = 450, hands = 1, accuracy = 4, hipSpread = 2.5,
		moveSpread = 1.5, recoil = { up = 1.2, side = 0.4, punch = 0.4, bloom = 0.35, recovery = 5 },
		aimTime = 0.2, sights = { pos = Vector(-5.9, -6, 2.6), fov = 0.85 }, draw = 0.4, reload = 2, reloadEmpty = 2.4,
		holdType = "pistol", viewModel = "models/weapons/c_pistol.mdl", worldModel = "models/weapons/w_pistol.mdl",
		useHands = true, sounds = { fire = "Weapon_Pistol.Single", empty = "Weapon_Pistol.Empty",
			reload = "Weapon_Pistol.Reload" } } },
	-- Colt Python .357 Magnum.
	{ "nc_python", { caliber = ".357", magazine = 6, chamber = false, rpm = 120, hands = 1, accuracy = 2,
		hipSpread = 3, recoil = { up = 3.2, side = 0.8, punch = 0.8, bloom = 0.8, recovery = 3, kick = 2 },
		aimTime = 0.25, sights = { pos = Vector(-4.7, -3, 0.7), fov = 0.85 }, draw = 0.5, reload = 3.6,
		holdType = "revolver", viewModel = "models/weapons/c_357.mdl", worldModel = "models/weapons/w_357.mdl",
		useHands = true, sounds = { fire = "Weapon_357.Single", empty = "Weapon_Pistol.Empty" } } },
	-- H&K MP7 (the SMG of HL2).
	{ "nc_mp7", { caliber = "4.6x30", magazine = 40, rpm = 950, modes = { "auto", "semi" }, accuracy = 4,
		hipSpread = 3, recoil = { up = 0.55, side = 0.3, punch = 0.4, bloom = 0.2, recovery = 5 }, aimTime = 0.25,
		sights = { pos = Vector(-6.4, -4, 1), fov = 0.8 }, draw = 0.5, reload = 2.2, reloadEmpty = 2.8,
		holdType = "smg", viewModel = "models/weapons/c_smg1.mdl", worldModel = "models/weapons/w_smg1.mdl",
		useHands = true, sounds = { fire = "Weapon_SMG1.Single", empty = "Weapon_SMG1.Empty",
			reload = "Weapon_SMG1.Reload" } } },
	-- The pulse rifle of the Combine, here a 5.56 assault rifle.
	{ "nc_ar2", { caliber = "5.56x45", magazine = 30, rpm = 700, modes = { "auto", "semi" }, accuracy = 2,
		hipSpread = 3.5, recoil = { up = 0.9, side = 0.35, punch = 0.5, bloom = 0.25, recovery = 4 }, aimTime = 0.3,
		sights = { pos = Vector(-5.9, -6, 1.6), fov = 0.75 }, draw = 0.6, reload = 2.4, reloadEmpty = 3,
		holdType = "ar2", viewModel = "models/weapons/c_irifle.mdl", worldModel = "models/weapons/w_irifle.mdl",
		useHands = true, sounds = { fire = "Weapon_AR2.Single", empty = "Weapon_AR2.Empty",
			reload = "Weapon_AR2.Reload" } } },
	-- Franchi SPAS-12, pump action, loaded a shell at a time.
	{ "nc_spas12", { caliber = "12/70", ammo = "12g_buck", magazine = 6, rpm = 70, accuracy = 6, hipSpread = 3,
		recoil = { up = 4, side = 1, punch = 0.9, bloom = 1, recovery = 2.5, kick = 2 }, aimTime = 0.3,
		sights = { pos = Vector(-8.95, -6, 4.2), fov = 0.85 }, draw = 0.6, reloadMode = "single", reload = 0.5,
		reloadStart = 0.4, reloadEnd = 0.6, holdType = "shotgun", viewModel = "models/weapons/c_shotgun.mdl",
		worldModel = "models/weapons/w_shotgun.mdl", useHands = true, sounds = { fire = "Weapon_Shotgun.Single",
			empty = "Weapon_Shotgun.Empty", reload = "Weapon_Shotgun.Reload" } } },
}

-- Melee -------------------------------------------------------------------------------------

M.MELEE = {
	{ "nc_crowbar", { hands = 1, draw = 0.5, holdType = "melee", viewModel = "models/weapons/c_crowbar.mdl",
		worldModel = "models/weapons/w_crowbar.mdl", useHands = true,
		primary = { kind = "blunt", energy = 110, reach = 52, size = 5, windup = 0.2, recovery = 0.45, stamina = 0.04,
			sounds = { swing = "Weapon_Crowbar.Single", hit = "Weapon_Crowbar.Melee_Hit",
				world = "Weapon_Crowbar.Melee_HitWorld" } } } },
	{ "nc_stunstick", { hands = 1, draw = 0.5, holdType = "melee", viewModel = "models/weapons/c_stunstick.mdl",
		worldModel = "models/weapons/w_stunbaton.mdl", useHands = true,
		primary = { kind = "stun", energy = 70, reach = 48, windup = 0.15, recovery = 0.4, stamina = 0.03,
			sounds = { swing = "Weapon_StunStick.Swing", hit = "Weapon_StunStick.Melee_Hit",
				world = "Weapon_StunStick.Melee_HitWorld" } } } },
	-- Models of CS:S (mounted on most servers).
	{ "nc_knife", { hands = 1, draw = 0.4, holdType = "knife", viewModel = "models/weapons/cstrike/c_knife_t.mdl",
		worldModel = "models/weapons/w_knife_t.mdl", useHands = true,
		primary = { kind = "slash", energy = 40, reach = 40, windup = 0.1, recovery = 0.3,
			sounds = { swing = "Weapon_Knife.Slash", hit = "Weapon_Knife.Hit", world = "Weapon_Knife.HitWall" } },
		secondary = { kind = "stab", energy = 60, depth = 12, reach = 36, windup = 0.25, recovery = 0.6,
			sounds = { swing = "Weapon_Knife.Slash", hit = "Weapon_Knife.Stab", world = "Weapon_Knife.HitWall" } } } },
}

-- Throwables (detonate: sv_weaponry.lua) ------------------------------------------------------

M.THROWABLES = {
	-- M67-like fragmentation grenade.
	{ "nc_frag", { model = "models/weapons/w_grenade.mdl", viewModel = "models/weapons/c_grenade.mdl", useHands = true,
		mass = 0.4, energy = 60, fuse = 4, max = 3, blast = { charge = 0.18, casing = 0.21 },
		sounds = { throw = "WeaponFrag.Throw", bounce = "Grenade.ImpactHard" } } },
	-- A glass bottle that breaks where it lands (the Break input of the prop: shards and sound).
	{ "nc_bottle", { model = "models/props_junk/glassbottle01a.mdl", mass = 0.5, energy = 45, impact = true, arm = 0.1,
		pull = 0.1, throwTime = 0.3, max = 3, remove = false, shatter = true,
		sounds = { bounce = "GlassBottle.ImpactHard" } } },
}

-- Items -------------------------------------------------------------------------------------

M.ITEMS = {
	{ "usp", { model = "models/weapons/w_pistol.mdl", weight = 0.75, size = 1, category = "weapon",
		traits = { weapon = { class = "nc_usp", slot = "secondary" } } } },
	{ "python", { model = "models/weapons/w_357.mdl", weight = 1.2, size = 1, category = "weapon",
		traits = { weapon = { class = "nc_python", slot = "secondary" } } } },
	{ "mp7", { model = "models/weapons/w_smg1.mdl", weight = 1.9, size = 2, category = "weapon",
		traits = { weapon = { class = "nc_mp7" } } } },
	{ "ar2", { model = "models/weapons/w_irifle.mdl", weight = 3.4, size = 3, category = "weapon",
		traits = { weapon = { class = "nc_ar2" } } } },
	{ "spas12", { model = "models/weapons/w_shotgun.mdl", weight = 4.4, size = 3, category = "weapon",
		traits = { weapon = { class = "nc_spas12" } } } },
	{ "crowbar", { model = "models/weapons/w_crowbar.mdl", weight = 1.5, size = 2, category = "weapon",
		traits = { weapon = { class = "nc_crowbar", slot = "melee" } } } },
	{ "stunstick", { model = "models/weapons/w_stunbaton.mdl", weight = 0.7, size = 2, category = "weapon",
		traits = { weapon = { class = "nc_stunstick", slot = "melee" } } } },
	{ "knife", { model = "models/weapons/w_knife_t.mdl", weight = 0.2, size = 1, category = "weapon",
		traits = { weapon = { class = "nc_knife", slot = "melee" } } } },
	{ "frag", { model = "models/weapons/w_grenade.mdl", weight = 0.4, stack = 3, size = 1, category = "weapon",
		traits = { weapon = { class = "nc_frag", slot = "throwable" } } } },
	{ "bottle", { model = "models/props_junk/glassbottle01a.mdl", weight = 0.5, stack = 3, size = 1,
		category = "weapon", traits = { weapon = { class = "nc_bottle", slot = "throwable" } } } },
	{ "ammo_9x19", { model = "models/items/boxsrounds.mdl", weight = 0.012, stack = 60, category = "ammo",
		traits = { ammo = "9x19_fmj" } } },
	{ "ammo_357", { model = "models/items/357ammo.mdl", weight = 0.016, stack = 30, category = "ammo",
		traits = { ammo = "357_jhp" } } },
	{ "ammo_46x30", { model = "models/items/boxmrounds.mdl", weight = 0.007, stack = 80, category = "ammo",
		traits = { ammo = "46x30_ap" } } },
	{ "ammo_556", { model = "models/items/combine_rifle_cartridge01.mdl", weight = 0.012, stack = 60,
		category = "ammo", traits = { ammo = "556_m855" } } },
	{ "ammo_12g_buck", { model = "models/items/boxbuckshot.mdl", weight = 0.04, stack = 24, category = "ammo",
		traits = { ammo = "12g_buck" } } },
	{ "ammo_12g_slug", { model = "models/items/boxbuckshot.mdl", weight = 0.045, stack = 24, category = "ammo",
		traits = { ammo = "12g_slug" } } },
}

function M:Init(ctx)
	local ammo, weapons = ctx:Require("ammo"), ctx:Require("weapons")
	local melee, throwables = ctx:Require("melee"), ctx:Require("throwables")
	for _, entry in ipairs(M.AMMO) do
		ammo:Register(entry[1], entry[2])
	end
	for _, entry in ipairs(M.FIREARMS) do
		weapons:Register(entry[1], entry[2])
	end
	for _, entry in ipairs(M.MELEE) do
		melee:Register(entry[1], entry[2])
	end
	for _, entry in ipairs(M.THROWABLES) do
		local def = {}
		for key, value in pairs(entry[2]) do
			if key ~= "blast" and key ~= "shatter" then
				def[key] = value
			end
		end
		local spec = entry[2]
		def.detonate = function(ent, thrower, pos)
			self:Detonate(ent, thrower, pos, spec)
		end
		throwables:Register(entry[1], def)
	end
	local inventory = ctx:Require("inventory")
	if inventory ~= nil then
		for _, entry in ipairs(M.ITEMS) do
			local def = entry[2]
			def.description = def.description or "items." .. entry[1] .. ".desc"
			inventory:RegisterItem(entry[1], def)
		end
	end
	if SERVER then
		self:_InitServer(ctx)
	end
end
