-- Roles: roles of players that modes register — hidden ones (a murderer, a sheriff) and
-- public ones (a job of the city). The owner always knows his role; allies of the same
-- side and everybody else only when the role says so, and everybody once a round ends.
return {
	id = "roles",
	description = "Roles of players: registered by modes, known to the owner, allies or all, revealed at the end",
	requires = { "players" },
	optional = { "rounds" },
	files = {
		sh = { "sh_roles.lua" },
		sv = { "sv_roles.lua" },
		cl = { "cl_roles.lua" },
	},
	config = {
		intro = 6, -- s the banner of a new role stays on the screen
	},
	net = {
		-- Server -> client: the roles this client knows (his own, his allies', the public
		-- ones; all of them when revealed). role: the index of the registered role.
		known = { from = "server", fields = {
			{ "roles", "array", max = 128, of = { "struct", fields = {
				{ "player", "player" },
				{ "role", "uint", bits = 8 },
			} } },
			{ "revealed", "bool" },
		} },
	},
}
