-- The damage pipeline (D6): damage of the engine becomes hits on the body of the
-- organism and the health of the engine never changes. Bullets keep their pellets, their
-- ammo and the distance; armor and other modules change hits in ordered stages.
return {
	id = "damage",
	description = "Damage pipeline: engine damage becomes hits on the body",
	requires = { "players", "organism" },
	files = {
		sv = { "sv_ammo.lua", "sv_damage.lua" },
	},
	config = {
		scale = 1,           -- multiplier of the energy of every bullet
		engineEnergy = 25,   -- J per point of engine damage of a bullet of unknown ammo
		falls = true,        -- landings injure (the engine's fall damage is always off)
		fallSpeed = 300,     -- units/s: slower landings are not even looked at
		punch = 1,           -- multiplier of the view punch of hits
		push = 1,            -- multiplier of the push of blasts and impacts
		history = 32,        -- latest hits kept for nc_damage
	},
}
