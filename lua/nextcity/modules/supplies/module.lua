-- Supplies: the official things of Next-City besides weapons — medicine (dressings,
-- tourniquets, splints, drugs, infusions, a defibrillator and diagnostic devices), armor,
-- backpacks and rigs — their loot tables, the crates of the map and the kits of modes.
return {
	id = "supplies",
	description = "Content: medicine, armor, backpacks and rigs, loot tables, crates and kits of modes",
	requires = { "inventory" },
	optional = { "loot", "weaponry" },
	files = {
		sh = { "sh_supplies.lua" },
		sv = { "sv_supplies.lua" },
	},
	config = {},
}
