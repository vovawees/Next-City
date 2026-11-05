-- NPCs: engine creatures for modes. Packages register kinds of creatures (a class with its
-- weapons, health and skill) and groups of kinds; admins put points on the map (nc_npcs,
-- kept in storage per map) where they appear far from the players; modes spawn them, count
-- them by tags, take over the creatures of the map and learn who killed one. Creatures of one
-- tag do not fight each other and run to the nearest player when they have no enemy.
return {
	id = "npcs",
	description = "NPCs: kinds and groups of engine creatures, points of the map, spawning, hunting, kills",
	requires = { "players" },
	optional = { "storage" },
	files = {
		sv = { "sv_npcs.lua" },
	},
	config = {
		hunt = 5,        -- s between two orders to creatures without an enemy to run to the nearest player
		maxAlive = 40,   -- creatures of the module alive at once at most (SpawnGroup spawns no more)
		clearance = 768, -- units from every living player a point has to be to spawn at (if any is)
		frags = true,    -- a player who kills a creature of the module gets a frag
		-- Classes Adopt does not take over from the map: friends, critters, helpers, the ones
		-- that cannot be found or killed on foot. [class] = true; false takes one back.
		ignore = {
			npc_alyx = true, npc_barney = true, npc_breen = true, npc_citizen = true, npc_dog = true, npc_eli = true,
			npc_fisherman = true, npc_gman = true, npc_kleiner = true, npc_magnusson = true, npc_monk = true,
			npc_mossman = true, npc_vortigaunt = true,
			npc_crow = true, npc_pigeon = true, npc_seagull = true, npc_antlion_grub = true,
			npc_bullseye = true, npc_enemyfinder = true, npc_furniture = true, npc_cranedriver = true,
			npc_apcdriver = true, npc_puppet = true,
			npc_helicopter = true, npc_combinegunship = true, npc_combinedropship = true, npc_strider = true,
			npc_sniper = true, npc_turret_ceiling = true, npc_turret_floor = true, npc_turret_ground = true,
			npc_combine_camera = true, npc_rollermine = true, npc_barnacle = true, npc_cscanner = true,
			npc_clawscanner = true, npc_stalker = true,
		},
	},
}
