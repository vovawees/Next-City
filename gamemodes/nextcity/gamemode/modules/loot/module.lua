-- Loot: what is found where. Packages register tables of loot (weighted draws of items,
-- tables inside tables) and kinds of crates; admins put points on the map (nc_loot, kept
-- in storage per map) where crates or loose things appear, for every round (the rule
-- loot) or once (nc_loot spawn), and crates may fill up again after they were emptied.
return {
	id = "loot",
	description = "Loot: tables of loot, crates and the points of the map where they appear",
	requires = { "inventory" },
	optional = { "storage", "rounds" },
	files = {
		sv = { "sv_loot.lua" },
	},
	config = {
		maxDraws = 32,   -- draws of one roll at most (tables inside tables count)
		maxDepth = 4,    -- tables inside tables
		scatter = 20,    -- units around a point loose things spread over
		refill = 5,      -- s between two looks at the crates that fill up again
	},
}
