-- Inventory: items are data of packages (definitions) and instances that live in
-- containers on the server: the pockets of every player, bags inside other containers,
-- crates, bodies and things on the ground. A client gets a snapshot of every container
-- it looks into and sends intents (move, use, drop) that the server checks (D18).
return {
	id = "inventory",
	description = "Inventory: items, containers, bags, things on the ground, bodies to search and the screen",
	requires = { "players" },
	optional = { "notices", "ragdoll", "menu" },
	files = {
		sh = { "sh_items.lua" },
		sv = { "sv_containers.lua", "sv_inventory.lua", "sv_world.lua", "sv_kits.lua" },
		cl = { "cl_inventory.lua", "cl_screen.lua" },
	},
	config = {
		pockets = 8,          -- slots of the pockets of a player (small things only)
		reach = 110,          -- units from the eyes to a container or a thing to use it
		useDelay = 0.3,       -- s between two uses of things (the use key repeats)
		maxGround = 400,      -- things on the ground at once; the oldest go first
		dropDistance = 36,    -- units in front of the eyes where a dropped thing appears
		maxDepth = 3,         -- bags inside bags inside bags
		corpses = true,       -- the dead leave what they carried on their body (or in a bag)
		bagModel = "models/props_junk/garbage_bag001a.mdl", -- what the dead leave without a body
	},
	net = {
		-- Server -> client: the snapshot of a container the player looks into. Weights in
		-- 0.1 kg; parent: the container the bag this is the inside of lies in (0: none).
		contents = { from = "server", fields = {
			{ "id", "uint", bits = 24 },
			{ "kind", "enum", values = { "pockets", "equipment", "bag", "crate", "corpse", "stash", "other" } },
			{ "title", "string", max = 48 },
			{ "name", "string", max = 32 },
			{ "size", "uint", max = 64 },
			{ "maxSize", "uint", max = 3 },
			{ "maxWeight", "uint", bits = 16 },
			{ "weight", "uint", bits = 16 },
			{ "own", "bool" },
			{ "opened", "bool" },
			{ "parent", "uint", bits = 24 },
			{ "parentSlot", "uint", max = 64 },
			{ "slotNames", "array", max = 16, of = { "string", max = 16 } },
			{ "items", "array", max = 64, of = { "struct", fields = {
				{ "slot", "uint", max = 64 },
				{ "uid", "uint", bits = 24 },
				{ "id", "string", max = 32 },
				{ "count", "uint", bits = 24 },
				{ "charge", "uint", bits = 16 },
				{ "cond", "quant", min = 0, max = 1, bits = 7 },
				{ "label", "string", max = 16 },
				{ "sub", "uint", bits = 24 },
			} } },
		} },
		-- Server -> client: the player no longer sees a container.
		closed = { from = "server", fields = { { "id", "uint", bits = 24 } } },
		-- Client -> server: move count (0: all) from a slot to a slot (0: the first that fits).
		move = { from = "client", rate = 12, burst = 24, fields = {
			{ "from", "uint", bits = 24 },
			{ "fromSlot", "uint", max = 64 },
			{ "to", "uint", bits = 24 },
			{ "toSlot", "uint", max = 64 },
			{ "count", "uint", bits = 24 },
		} },
		-- Client -> server: a verb on the item in a slot (slot 0: the container itself).
		act = { from = "client", rate = 6, burst = 12, fields = {
			{ "container", "uint", bits = 24 },
			{ "slot", "uint", max = 64 },
			{ "verb", "string", max = 24 },
			{ "count", "uint", bits = 24 },
		} },
		-- Client -> server: the player stops looking into a container.
		close = { from = "client", rate = 10, burst = 20, fields = { { "id", "uint", bits = 24 } } },
	},
	components = {
		-- A thing on the ground: every client sees what it is (the hint under the crosshair).
		ground = { replicate = "all", rate = 4, fields = {
			{ "id", "string", max = 32 },
			{ "count", "uint", bits = 24 },
		}, desc = "a thing on the ground" },
		-- An entity with a container (a crate, a body): the hint under the crosshair.
		place = { replicate = "all", rate = 2, fields = {
			{ "kind", "enum", values = { "pockets", "equipment", "bag", "crate", "corpse", "stash", "other" } },
			{ "title", "string", max = 48 },
			{ "name", "string", max = 32 },
		}, desc = "an entity with a container" },
	},
}
