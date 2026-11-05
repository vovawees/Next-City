-- Fallen bodies (D14): a player who falls (unconscious, legs that do not hold, a heavy
-- blow, a hard landing, at will) becomes a server prop_ragdoll in the pose of the moment;
-- the player stays alive, hidden and without a hull, and looks out of the eyes of the
-- body. The organism reads hits and breathing from the ragdoll. When the body allows it
-- the player gets up where there is room. A dead player leaves a server ragdoll as the
-- corpse; corpses are limited and cleaned up within a budget.
return {
	id = "ragdoll",
	description = "Fallen bodies: falling, getting up, the camera of a fallen player, corpses",
	requires = { "players", "organism", "damage" },
	optional = { "menu" },
	files = {
		sh = { "sh_ragdoll.lua" },
		sv = { "sv_bodies.lua", "sv_ragdoll.lua" },
		cl = { "cl_ragdoll.lua" },
	},
	config = {
		fallWhenWeak = true, -- a body that cannot stand falls (false: it crawls, see movement)
		knockdown = 60,      -- engine damage of one blast, impact or blow that knocks down
		fallSpeed = 650,     -- units/s: landings at least this fast knock down
		voluntary = true,    -- players may fall at will (nc_fall)
		cooldown = 1,        -- s between falls at will
		getUpDelay = 1.5,    -- s on the ground before getting up
		getUpTime = 1.2,     -- s that getting up takes
		getUpSpeed = 60,     -- units/s: a body moving faster cannot get up
		ragdolls = 64,       -- fallen bodies and corpses at most
		corpses = 24,        -- corpses at most: a new one takes the place of the oldest
		corpseTime = 0,      -- s a corpse stays (0: until the limit takes it)
		settleTime = 6,      -- s at rest after which a corpse sleeps and lets players and bodies pass
		cleanupBudget = 2,   -- corpses removed per tick at most
		syncRate = 20,       -- times per second the hidden player follows its body
	},
	net = {
		-- Client -> server: fall at will, or get up.
		fall = { from = "client", rate = 2, burst = 3, fields = {} },
	},
	components = {
		-- The body of a player as the player sees it: the camera and the hints.
		body = { replicate = "owner", rate = 20, fields = {
			{ "state", "enum", values = { "standing", "fallen", "unconscious", "getting_up", "dead" } },
			{ "ent", "uint", bits = 13 }, -- index of the ragdoll or the corpse, 0 for none
			{ "since", "float" },         -- game time the state began
			{ "blocked", "enum", values = { "none", "room", "moving" } }, -- why getting up failed
		}, desc = "the fallen body or the corpse of a player" },
	},
}
