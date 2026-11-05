-- Player lifecycle: who is loading, spectating, alive or dead; putting players into the
-- game and picking spawn points. Rounds and modes build on top of it.
return {
	id = "players",
	description = "Player lifecycle: connecting, spectator, alive, dead; deploying and spawn points",
	files = {
		sh = { "sh_players.lua" },
		sv = { "sv_spawns.lua", "sv_players.lua" },
		cl = { "cl_players.lua" },
	},
	config = {
		clearance = 40, -- a spawn point is taken while a living player stands closer than this, units
		targetNames = true, -- the name of the player under the crosshair (client)
		targetRange = 800, -- units: farther players show no name
	},
	components = {
		-- Every client sees the life state of every player (scoreboard, spectating, HUD).
		life = { replicate = "all", rate = 10, fields = {
			{ "state", "enum", values = { "connecting", "spectator", "alive", "dead" } },
			{ "respawnAt", "float" }, -- game time a dead player comes back, 0 if not scheduled
		}, desc = "life state of a player" },
	},
}
