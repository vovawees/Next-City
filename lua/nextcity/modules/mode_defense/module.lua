-- Defense: the players hold out against waves of creatures with a pause before each; the
-- round is won after the last wave and lost when everybody is dead.
return {
	id = "mode_defense",
	description = "Defense: hold out against waves of creatures with pauses between them",
	requires = { "rounds", "players", "npcs" },
	optional = { "inventory", "loot", "notices" },
	files = {
		sv = { "sv_defense.lua" },
	},
	config = {},
}
