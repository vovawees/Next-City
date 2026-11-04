-- Ammunition: the registry of the rounds of content packages (calibers and their
-- projectiles) and their engine ammo types. The core has no ammunition of its own.
return {
	id = "ammo",
	description = "Ammunition registry: calibers, projectiles and engine ammo types of packages",
	requires = { "damage" },
	files = {
		sh = { "sh_ammo.lua" },
		sv = { "sv_ammo.lua" },
	},
	config = {
		maxCarry = 9999, -- rounds of a type a player may carry in the engine reserve, unless the type says
	},
}
