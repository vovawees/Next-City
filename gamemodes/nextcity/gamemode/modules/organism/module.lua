-- The model of the body (D6, D11): injuries become wounds, fractures and damaged organs;
-- blood and circulation, breathing, the brain, pain, shock, consciousness, stamina,
-- temperature and drugs are simulated, and the brain decides death. Consumers (movement,
-- weapons, the HUD) read capabilities and vitals, never the inner state.
return {
	id = "organism",
	description = "Model of the body: injuries, physiology, treatments and death",
	requires = { "players" },
	files = {
		sh = { "sh_organism.lua" },
		sv = { "sv_body.lua", "sv_injuries.lua", "sv_physiology.lua", "sv_treatments.lua", "sv_organism.lua" },
		cl = { "cl_organism.lua" },
	},
	config = {
		rate = 10,            -- simulation steps per second
		bloodVolume = 5000,   -- normal blood volume, ml
		brainDeathTime = 300, -- seconds without oxygen until the brain dies
		bleedScale = 1,       -- multiplier of every bleeding
		painScale = 1,        -- multiplier of pain
		sprintTime = 12,      -- seconds of sprinting on full stamina
		succumbDelay = 5,     -- seconds unconscious before a player may give up (-1: never)
		maxWounds = 48,       -- wounds kept per player; beyond that the smallest ones merge
	},
	net = {
		-- Client -> server: an unconscious player gives up and dies of the injuries now.
		succumb = { from = "client", rate = 1, burst = 2, fields = {} },
	},
	components = {
		-- What the player feels and can do, for the HUD, prediction and weapons. Only the
		-- player sees their own body.
		vitals = { replicate = "owner", rate = 10, fields = {
			{ "blood", "quant", min = 0, max = 1, bits = 7 },        -- blood volume, share of normal
			{ "bleeding", "quant", min = 0, max = 2000, bits = 8 },  -- external bleeding, ml/min
			{ "pulse", "uint", max = 255 },                          -- heart rate, 0 in cardiac arrest
			{ "spo2", "uint", max = 100 },                           -- oxygen saturation, %
			{ "pain", "quant", min = 0, max = 1, bits = 6 },
			{ "stamina", "quant", min = 0, max = 1, bits = 6 },
			{ "consciousness", "quant", min = 0, max = 1, bits = 6 },
			{ "temperature", "quant", min = 25, max = 42, bits = 8 }, -- core temperature, degrees C
			{ "speed", "quant", min = 0, max = 1, bits = 6 },        -- movement speed multiplier
			{ "sway", "quant", min = 0, max = 1, bits = 6 },         -- aim sway
			{ "recoil", "quant", min = 1, max = 3, bits = 6 },       -- recoil multiplier
			{ "blur", "quant", min = 0, max = 1, bits = 6 },         -- blurred vision
			{ "dark", "quant", min = 0, max = 1, bits = 6 },         -- tunnel vision and darkening
			{ "grey", "quant", min = 0, max = 1, bits = 6 },         -- loss of colour
			{ "caps", "uint", bits = 8 },                            -- capability flags (sh_organism.lua)
			{ "status", "uint", bits = 24 },                         -- status flags (sh_organism.lua)
			{ "since", "float" },                                    -- game time consciousness was lost, 0 awake
		}, defaults = { blood = 1, pulse = 72, spo2 = 98, stamina = 1, consciousness = 1, temperature = 37,
			speed = 1, recoil = 1, caps = 63 }, desc = "how the body of a player feels and what it can do" },
	},
}
