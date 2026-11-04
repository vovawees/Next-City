-- Team Deathmatch, the reference mode: assembled from rule blocks, adds only its loadout.
return {
	id = "mode_tdm",
	description = "Team Deathmatch: teams score kills of enemies, instant respawns, a time limit",
	requires = { "rounds", "teams" },
	files = {
		sv = { "sv_tdm.lua" },
	},
	config = {},
}
