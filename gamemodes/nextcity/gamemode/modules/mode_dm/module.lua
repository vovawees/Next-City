-- Deathmatch: every player for himself, a kill is a frag, instant respawns; the frag limit
-- or the leader when the time is up wins.
return {
	id = "mode_dm",
	description = "Deathmatch: every player for himself, frags, instant respawns, frag and time limits",
	requires = { "rounds", "players" },
	optional = { "armor", "inventory", "loot" },
	files = {
		sv = { "sv_dm.lua" },
	},
	config = {},
}
