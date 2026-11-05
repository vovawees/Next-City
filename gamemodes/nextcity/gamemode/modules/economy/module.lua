-- Economy: the money of players. Cash is an item of the inventory: it lies in the pockets,
-- falls on the ground, stays on the body of the dead and can be stolen. The bank account
-- of a player lives in storage and survives the map and the server. Modes pay into the
-- accounts (salaries, refunds) and charge players (purchases: the account first, then the
-- cash); players deposit and withdraw cash, hand it to others and drop it.
return {
	id = "economy",
	description = "Economy: cash as an item, bank accounts in storage, payments, charges, handing cash over",
	requires = { "players", "inventory" },
	optional = { "storage", "notices" },
	files = {
		sh = { "sh_economy.lua" },
		sv = { "sv_economy.lua" },
		cl = { "cl_economy.lua" },
	},
	config = {
		item = "money",            -- id of the cash item (registered by this module)
		model = "models/props/cs_assault/money.mdl",
		stack = 1000000,           -- cash in one slot
		weight = 0.00001,          -- kg per unit of cash
		currency = "$",            -- before amounts: $1 250
		group = " ",               -- between groups of digits
		start = 500,               -- balance of a new account
		maxBalance = 1000000000,   -- no account holds more
		range = 96,                -- units to the player cash is handed to
		depositOnLeave = true,     -- the cash a leaving player carries goes into his account
	},
	components = {
		-- The bank balance of a player: only he sees it (the HUD, the bank screen).
		account = { replicate = "owner", rate = 4, fields = {
			{ "balance", "uint", bits = 32 },
		}, desc = "the bank balance of a player" },
	},
	net = {
		-- Client -> server: the bank screen and cash in the hands: into the account, out of
		-- it, to the player in front, on the ground.
		cash = { from = "client", rate = 4, burst = 8, fields = {
			{ "op", "enum", values = { "deposit", "withdraw", "give", "drop" } },
			{ "amount", "uint", bits = 32 },
		} },
	},
}
