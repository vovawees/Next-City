-- Weapons: the firearm base of content packages. A weapon is data (caliber, magazine,
-- rate, modes, accuracy, recoil, handling) that a package registers; the base runs it as
-- a scripted weapon: fire control, recoil, spread, sway, aiming and reloading are
-- predicted on the client of the shooter, the rounds fly as physical projectiles from the
-- server. The core has no weapons of its own (D15).
return {
	id = "weapons",
	description = "Firearm base: weapons of packages, fire control, recoil, aiming and reloading",
	requires = { "players", "organism", "ammo" },
	optional = { "ballistics", "menu" },
	files = {
		sh = { "sh_weapons.lua", "sh_firearm.lua" },
		sv = { "sv_weapons.lua" },
		cl = { "cl_firearm.lua" },
	},
	config = {
		recoil = 1,          -- multiplier of the recoil of every weapon
		spread = 1,          -- multiplier of the spread
		sway = 1,            -- multiplier of the sway of the aim
		sprint = true,       -- a sprinting player lowers the weapon and cannot fire or aim
		crosshair = false,   -- the crosshair of the engine
		ammoCounter = false, -- the ammo counter of the engine (rounds loaded and in reserve)
	},
}
