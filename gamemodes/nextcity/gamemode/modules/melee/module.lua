-- Melee: the base of the melee weapons of packages (knives, bats, axes) and of the hands.
-- A weapon is data: its attacks (the kind of injury, energy, depth of a blade, reach,
-- timing, effort). The base swings them as a scripted weapon predicted on the client of
-- the attacker; the strike is traced under lag compensation and hits bodies through the
-- damage pipeline, the rest with engine damage. The core has no melee weapons (D15).
return {
	id = "melee",
	description = "Melee base: weapons of packages, swings and strikes on bodies and props",
	requires = { "players", "organism", "damage" },
	files = {
		sh = { "sh_melee.lua", "sh_swing.lua" },
		sv = { "sv_melee.lua" },
		cl = { "cl_melee.lua" },
	},
	config = {
		energy = 1,             -- multiplier of the energy of every strike
		entityDamage = 0.1,     -- engine damage per J for props, creatures and glass
		push = 1,               -- multiplier of the push of what a strike hits
		lagCompensation = true, -- strikes see the others where the attacker saw them
	},
}
