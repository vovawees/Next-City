-- Explosions: one API for every charge of the packages (grenades, mines, shells, barrels).
-- The blast wave by the scaled distance hits bodies through the damage pipeline, the
-- casing flies as fragments of ballistics, the engine blast pushes and breaks the rest.
-- The core has no explosives of its own (D15).
return {
	id = "explosions",
	description = "Explosions: blast waves by the scaled distance, fragments as projectiles, the engine blast",
	requires = { "players", "organism", "damage" },
	optional = { "ballistics" },
	files = {
		sv = { "sv_explosions.lua" },
	},
	config = {
		blast = 1,          -- multiplier of the blast wave on bodies
		fragments = 1,      -- multiplier of the number of fragments (0: none)
		maxFragments = 300, -- fragments of one explosion at most
		engine = true,      -- the engine blast: props, creatures, glass and fallen bodies
		effects = true,     -- the explosion and its sound, a scorch mark, a shake of the screens
	},
}
