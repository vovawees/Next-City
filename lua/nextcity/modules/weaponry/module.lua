-- Weaponry: the official weapons of Next-City on the models of Half-Life 2 (the knife: of
-- Counter-Strike: Source) — rounds, firearms, melee weapons and throwables, their items
-- of the inventory and the loot tables of weapons and ammunition.
return {
	id = "weaponry",
	description = "Content: rounds, firearms, melee weapons and throwables on HL2 models, their items and loot",
	requires = { "ammo", "weapons", "melee", "throwables" },
	optional = { "inventory", "loot", "explosions" },
	files = {
		sh = { "sh_weaponry.lua" },
		sv = { "sv_weaponry.lua" },
	},
	config = {},
}
