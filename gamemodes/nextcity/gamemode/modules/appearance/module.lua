-- Appearance: the look of every player's character — a model of the sets packages add (the
-- citizens of Half-Life 2 in the official one), its skin and bodygroups and the color of the
-- clothes — kept in his profile (the section appearance) and put on at every spawn, unless a
-- mode dresses him itself (gm.PlayerSetModel: the uniforms of the city) or changes the look
-- (appearance.look: the looks of the aliases of Homicide). The appearance tab of the menu (F1)
-- shows a preview of it.
return {
	id = "appearance",
	description = "Appearance: the model, skin, bodygroups and the color of clothes of every player's character",
	requires = { "players", "profiles" },
	optional = { "identity", "notices", "menu" },
	files = {
		sh = { "sh_appearance.lua" },
		sv = { "sv_appearance.lua" },
		cl = { "cl_appearance.lua" },
	},
	config = {
		random = true, -- newcomers get a random look of the sets for the gender of their character
		cooldown = 10, -- s between own changes of the look
	},
	components = {
		-- A player's own look (the appearance tab).
		look = { replicate = "owner", rate = 2, fields = {
			{ "model", "string", max = 128 }, -- "" while he has none
			{ "skin", "uint", bits = 8 },
			{ "bodygroups", "array", max = 16, of = { "uint", bits = 8 } }, -- groups 0, 1, ...
			{ "color", "uint", bits = 24 }, -- of the clothes, 0xRRGGBB
			{ "random", "bool" }, -- the look was given at random: it follows a change of the gender
			{ "ready", "float" }, -- game time the next change is allowed, 0: now
		}, desc = "the player's own look" },
		-- The color of the clothes of a body or a corpse (ragdoll): a prop_ragdoll has no owner
		-- to take the color from.
		clothes = { replicate = "all", rate = 4, fields = {
			{ "color", "uint", bits = 24 },
		}, desc = "the color of the clothes of a body or a corpse" },
	},
	net = {
		-- Client -> server: the appearance tab saves a look.
		change = { from = "client", rate = 1, burst = 3, fields = {
			{ "model", "string", max = 128 },
			{ "skin", "uint", bits = 8 },
			{ "bodygroups", "array", max = 16, of = { "uint", bits = 8 } },
			{ "color", "uint", bits = 24 },
		} },
	},
}
