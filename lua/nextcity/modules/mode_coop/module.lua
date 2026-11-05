-- CO-OP: the players clear the map of creatures together with a shared pool of lives; the
-- round is won when no creature is left and lost when the lives run out or the time is up.
return {
	id = "mode_coop",
	description = "CO-OP: clear the map of creatures together with shared lives",
	requires = { "rounds", "players", "npcs" },
	optional = { "inventory", "loot", "notices" },
	files = {
		sv = { "sv_coop.lua" },
	},
	config = {},
}
