-- Profiles: what the server remembers of every player across visits (by SteamID64): the
-- first and the last visit, the time in the game, the visits, statistics and sections of
-- other modules (the character, the appearance), one record per player in a storage
-- collection. A player sees the summary of his own profile (the profile tab of the menu).
return {
	id = "profiles",
	description = "Profiles: visits, playtime, statistics and module sections of every player, kept in storage",
	optional = { "storage", "menu" },
	files = {
		sh = { "sh_profiles.lua" },
		sv = { "sv_profiles.lua" },
		cl = { "cl_profiles.lua" },
	},
	config = {
		collection = "profiles", -- storage collection of the records
		saveInterval = 60,       -- s between counting the playtime of the players on the server
		bots = false,            -- keep the profiles of bots in storage (else for the session only)
	},
	components = {
		-- The summary a player sees of his own profile (the profile tab of the F1 menu).
		summary = { replicate = "owner", rate = 1, fields = {
			{ "first", "uint", bits = 32 },    -- unix time of the first visit
			{ "visits", "uint", bits = 24 },
			{ "playtime", "uint", bits = 32 }, -- s in the game until `since`
			{ "since", "float" },              -- game time the playtime was counted last
			{ "kills", "uint", bits = 24 },
			{ "deaths", "uint", bits = 24 },
			{ "rounds", "uint", bits = 24 },
			{ "wins", "uint", bits = 24 },
			{ "creatures", "uint", bits = 24 },
		}, desc = "the summary of a player's own profile" },
	},
	permissions = {
		view = { level = "admin", desc = "See the profiles of other players (nc_profile <player>)" },
	},
}
