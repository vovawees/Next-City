-- Physical projectiles: one manager flies every bullet and fragment in arrays, one loop a
-- tick (air drag, gravity, water), and resolves what they meet: bodies through the damage
-- pipeline, materials they go through or glance off, engine damage for everything else.
return {
	id = "ballistics",
	description = "Physical projectiles: drag, gravity, penetration, ricochets and hits",
	requires = { "organism", "damage", "ammo" },
	files = {
		sv = { "sv_ballistics.lua" },
	},
	config = {
		maxProjectiles = 1024, -- in flight at once; a new one replaces the oldest
		lifetime = 4,          -- s: the longest flight
		minEnergy = 5,         -- J: a slower projectile stops
		gravity = 1,           -- multiplier of the real gravity (9.81 m/s²)
		penetration = 1,       -- multiplier of how deep projectiles go through materials (0: never)
		ricochets = 2,         -- ricochets of one projectile at most (0: none)
		lagCompensation = true, -- the flight a shooter's latency hides runs with lag compensation
		maxCatchUp = 0.25,     -- s: the most of that flight
		scale = 1,             -- multiplier of the energy of hits on bodies
		entityDamage = 0.04,   -- engine damage per J for other entities (props, NPCs, glass)
		push = 1,              -- multiplier of the push of what a projectile hits
		effects = true,        -- impacts, splashes and blood
	},
}
