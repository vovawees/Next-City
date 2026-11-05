-- Hands: the empty hands of every player, a scripted weapon on the melee base. Lowered,
-- they carry props and bodies; raised (the reload key), they are fists. The core has the
-- hands of the body, packages the weapons (D15).
return {
	id = "hands",
	description = "Hands of every player: fists on the melee base, carrying props and bodies",
	requires = { "players", "organism", "melee" },
	optional = { "menu" },
	files = {
		sh = { "sh_hands.lua" },
		sv = { "sv_hands.lua" },
		cl = { "cl_hands.lua" },
	},
	config = {
		give = true,                -- every deployed player gets the hands
		raise = 0.35,               -- s to raise the fists or lower them
		energy = 50,                -- J of a punch
		reach = 40,                 -- units a punch reaches from the eyes
		windup = 0.1,               -- s from the press to the punch
		recovery = 0.45,            -- s after a punch before the next one
		stamina = 0.03,             -- share of the stamina a punch takes
		carryReach = 72,            -- units from the eyes the hands grab at
		strength = 24000,           -- the most the arms pull, kg·units/s² (about 40 kg against gravity 600)
		carryStamina = 0.04,        -- share of the stamina per second of pulling at full strength
		throwEnergy = 150,          -- J of a throw
		throwSpeed = 600,           -- units/s a throw gives at most (light things)
		viewModel = "models/weapons/c_arms.mdl",
		swingSound = "WeaponFrag.Throw",
		hitSound = "Flesh.ImpactHard",
	},
}
