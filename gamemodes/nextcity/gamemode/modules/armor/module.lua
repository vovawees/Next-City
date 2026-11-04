-- Body armor: kinds of armor worn in slots stop or slow down what hits the areas they
-- cover, by the class of protection against the threat of the projectile; what is
-- stopped still hits as a blow behind the armor, and every hit wears the armor out.
return {
	id = "armor",
	description = "Body armor: protection classes, coverage, blunt trauma and wear",
	requires = { "players", "organism", "damage" },
	files = {
		sh = { "sh_armor.lua" },
		sv = { "sv_armor.lua" },
		cl = { "cl_armor.lua" },
	},
	config = {
		bluntScale = 1, -- multiplier of the blow behind armor that stopped a projectile
		wear = 1,       -- multiplier of the wear of every hit
	},
	components = {
		-- The armor a player wears, outer layers first; only the player sees it.
		armor = { replicate = "owner", rate = 4, fields = {
			{ "pieces", "array", max = 8, of = { "struct", fields = {
				{ "id", "string", max = 32 },
				{ "condition", "quant", min = 0, max = 1, bits = 7 }, -- 1 new, 0 worn out
			} } },
		}, desc = "the armor a player wears" },
	},
}
