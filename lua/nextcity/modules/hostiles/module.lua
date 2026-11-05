-- Hostiles: the official creatures of Next-City for the modes against NPCs (Defense, CO-OP)
-- — kinds of Half-Life 2 enemies with their weapons and skill and the groups the waves are
-- drawn from (the npcs module spawns them).
return {
	id = "hostiles",
	description = "Content: kinds of Half-Life 2 enemies and their groups for the modes against NPCs",
	requires = { "npcs" },
	files = {
		sv = { "sv_hostiles.lua" },
	},
	config = {},
}
