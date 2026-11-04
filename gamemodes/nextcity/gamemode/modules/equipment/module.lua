-- Equipment: what a player wears and holds is what lies in his equipment, a container of
-- the inventory with a slot for a helmet, a vest, plates, a backpack, a rig and his
-- weapons. Armor is worn, weapons are in the hands and reloads take rounds from his
-- containers while the items lie there; what he carries slows him down.
return {
	id = "equipment",
	description = "Equipment: worn armor, bags on the back and chest, weapons in the hands, ammo and load",
	requires = { "players", "inventory" },
	optional = { "armor", "weapons", "throwables", "movement", "notices" },
	files = {
		sh = { "sh_equipment.lua" },
		sv = { "sv_equipment.lua" },
		cl = { "cl_equipment.lua" },
	},
	config = {
		freeLoad = 15,   -- kg a player carries without slowing down
		fullLoad = 45,   -- kg at which he is slowest
		minSpeed = 0.6,  -- the share of his speeds at fullLoad and more
		sync = 1,        -- s between two copies of the state of the weapons in the hands to their items
	},
}
