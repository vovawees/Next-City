-- Riot: the riot police against the rioters. The police stun the rioters with batons and
-- tie them up with zip ties, the rioters fight back with what they carry and find and free
-- each other. Dead and tied players are out; when the time is up more players standing win.
return {
	id = "mode_riot",
	description = "Riot: the riot police tie up the rioters, the rioters fight back and free each other",
	requires = { "rounds", "teams", "players" },
	optional = { "inventory", "loot", "notices", "restraints" },
	files = {
		sh = { "sh_riot.lua" },
		sv = { "sv_riot.lua" },
	},
	config = {},
}
