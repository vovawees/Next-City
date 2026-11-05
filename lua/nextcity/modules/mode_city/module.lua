-- City: the main mode. An endless round of city life: everybody has a job (a public role)
-- with a salary, a limit of places and the gear of the job; the dead come back, newcomers
-- join at any time, citizens go by the names they choose, the shop sells to each job what
-- it trades in. Money, doors and the police come from the modules economy, doors and law.
return {
	id = "mode_city",
	description = "City: endless city life with jobs, salaries, the gear and the shop of jobs, names of citizens",
	requires = { "rounds", "roles", "players" },
	optional = { "inventory", "economy", "notices", "storage", "doors" },
	files = {
		sh = { "sh_city.lua" },
		sv = { "sv_city.lua" },
		cl = { "cl_city.lua" },
	},
	config = {},
	components = {
		-- The name of a citizen: everybody sees it instead of the nick while the city lives.
		citizen = { replicate = "all", rate = 4, fields = {
			{ "name", "string", max = 32 },
		}, desc = "the name a citizen goes by in the city" },
	},
	net = {
		-- Client -> server: the menu of the city asks for a job (its index) and a name.
		job = { from = "client", rate = 2, burst = 4, fields = { { "job", "uint", bits = 8 } } },
		name = { from = "client", rate = 1, burst = 2, fields = { { "name", "string", max = 32 } } },
		-- Client -> server: a purchase in the shop of the city (the index of the offer).
		buy = { from = "client", rate = 4, burst = 8, fields = {
			{ "offer", "uint", bits = 8 },
			{ "times", "uint", bits = 5 },
		} },
	},
}
