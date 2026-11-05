-- Homicide: a murderer among innocents. Hidden roles (the murderer, the sheriff, the
-- innocents), aliases instead of names, quiet deaths, the dead do not talk to the living,
-- variants of a round (standard, gun-free zone, wild west) and the loot of the map.
return {
	id = "mode_homicide",
	description = "Homicide: find the murderer among innocents; hidden roles, aliases, variants",
	requires = { "rounds", "roles", "players" },
	optional = { "inventory", "loot", "notices", "hands" },
	files = {
		sh = { "sh_homicide.lua" },
		sv = { "sv_homicide.lua" },
	},
	config = {},
	components = {
		-- The alias of a player in a round of Homicide: everybody sees it instead of the name.
		alias = { replicate = "all", rate = 4, fields = {
			{ "index", "uint", bits = 8 }, -- 1.. into the list of aliases
		}, desc = "the alias of a player in a round of Homicide" },
	},
}
