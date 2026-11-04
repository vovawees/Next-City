-- Spectating: a death camera, then following living players or a free camera. Who may be
-- followed is decided on the server; the client shows the target and the keys.
return {
	id = "spectator",
	description = "Spectating: death camera, following living players, free camera",
	requires = { "players" },
	optional = { "teams" },
	files = {
		sv = { "sv_spectator.lua" },
		cl = { "cl_spectator.lua" },
	},
	config = {
		deathCam = 3,      -- seconds of the engine's death view before observing (0 = none)
		camera = "in_eye", -- the first camera of an observer: in_eye, chase or roaming
		teamOnly = true,   -- players of a team follow only living teammates while there are any
	},
}
