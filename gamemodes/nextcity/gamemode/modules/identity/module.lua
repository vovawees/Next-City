-- Identity: the character of every player, a name and a gender kept in his profile (the
-- section identity). Newcomers get a random one in their language; a player changes his
-- character in the menu (F1, the character tab) or with nc_rpname, then waits a cooldown.
-- Others see the name of the character instead of the nick where a mode turns identities
-- on (the question identity.enabled: the city).
return {
	id = "identity",
	description = "Identity: the name and the gender of every player's character, seen where a mode turns it on",
	requires = { "players", "profiles" },
	optional = { "storage", "notices", "menu" },
	files = {
		sh = { "sh_names.lua", "sh_identity.lua" },
		sv = { "sv_identity.lua" },
		cl = { "cl_identity.lua" },
	},
	config = {
		random = true,         -- newcomers get a random gender and a name in their language
		minLength = 2,         -- characters of a name
		maxLength = 32,        -- (at most 96 bytes: 32 Cyrillic letters fit)
		minWords = 1,          -- words of a name (2: a first and a last name)
		maxWords = 4,
		cooldown = 1800,       -- s between own changes of the character (the first one is free)
		unique = true,         -- no two characters go by one name (any case), offline ones too
		registry = "identity", -- storage namespace of the names taken
		refresh = 1,           -- s between the looks whether modes turn identities on (0: events only)
	},
	components = {
		-- The character others see while a mode turns identities on for its owner.
		identity = { replicate = "all", rate = 4, fields = {
			{ "name", "string", max = 96 },
			{ "gender", "enum", values = { "male", "female" } },
		}, desc = "the character a player goes by where identities are on" },
		-- A player's own character (the character tab of the menu).
		character = { replicate = "owner", rate = 2, fields = {
			{ "name", "string", max = 96 },
			{ "gender", "enum", values = { "male", "female" } },
			{ "random", "bool" }, -- the name was given at random: it follows a change of the gender
			{ "ready", "float" }, -- game time the next change is allowed, 0: now
		}, desc = "the player's own character" },
	},
	net = {
		-- Client -> server: the character tab asks for a name and a gender.
		change = { from = "client", rate = 1, burst = 3, fields = {
			{ "name", "string", max = 96 },
			{ "gender", "enum", values = { "male", "female" } },
		} },
	},
}
