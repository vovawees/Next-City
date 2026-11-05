-- Doors: the doors of the map as property. A mode that lets players own doors (the
-- question doors.property) sells them for money (economy); an owner locks and unlocks his
-- doors, gives keys to co-owners and names them. The admin gives doors of the map to
-- groups (the police station) or keeps them off the market, kept per map in storage. A
-- lockpick opens a locked door after a while, a battering ram breaks one in when the mode
-- allows it.
return {
	id = "doors",
	description = "Doors: own, buy and sell map doors, locks, co-owners, titles, map groups, lockpicks and rams",
	requires = { "players" },
	optional = { "economy", "storage", "inventory", "actions", "notices" },
	files = {
		sh = { "sh_doors.lua" },
		sv = { "sv_doors.lua" },
		cl = { "cl_doors.lua" },
	},
	config = {
		classes = { "prop_door_rotating", "func_door", "func_door_rotating" },
		price = 100,   -- money for a door (without economy: free)
		refund = 0.5,  -- share of the price an owner gets back when he sells
		limit = 8,     -- doors one player owns at most (0: no limit)
		coowners = 4,  -- co-owners of one door at most
		range = 96,    -- units from the eyes to a door the keys, a lockpick and a ram reach
		pick = 12,     -- s to pick a lock when the lockpick does not say
		ram = 3,       -- s to break a door in when the ram does not say
	},
	components = {
		-- A door with something on it: everybody sees its owner, title, group and lock.
		door = { replicate = "all", rate = 4, fields = {
			{ "owner", "uint", bits = 8 },                         -- the entity index of the owner, 0: none
			{ "coowners", "array", of = { "uint", bits = 8 }, max = 8 }, -- entity indexes
			{ "title", "string", max = 48 },
			{ "group", "string", max = 32 },  -- "" or the group that holds the keys (map)
			{ "locked", "bool" },
			{ "closed", "bool" },             -- off the market (map)
		}, defaults = { coowners = {}, title = "", group = "", locked = false, closed = false },
		desc = "a door of the map: owner, co-owners, title, group, lock" },
	},
	net = {
		-- Client -> server: the menu of a door.
		door = { from = "client", rate = 4, burst = 8, fields = {
			{ "op", "enum", values = { "buy", "sell", "lock", "unlock", "add", "remove", "title" } },
			{ "door", "entity" },
			{ "target", "player", optional = true },
			{ "title", "string", max = 48, optional = true },
		} },
	},
}
