-- Teams: a fixed palette of up to four teams, balanced assignment, team scores and the
-- team rule blocks for rounds (teams, team_elimination, team_score).
return {
	id = "teams",
	description = "Teams: palette, balanced assignment, scores and team rules for rounds",
	requires = { "players" },
	optional = { "rounds" },
	files = {
		sh = { "sh_teams.lua" },
		sv = { "sv_teams.lua", "sv_rules.lua" },
		cl = { "cl_teams.lua" },
	},
	config = {},
	net = {
		-- Server -> client: scores of the teams in play (team 1 first); empty without teams.
		-- names: translation keys of the names a round gave the teams ("" = the palette).
		scores = { from = "server", fields = {
			{ "scores", "array", max = 4, of = { "int", bits = 16 } },
			{ "names", "array", max = 4, of = { "string", max = 48 } },
		} },
	},
}
