-- Manifest of the example module, a template for new modules.
-- Copy the folder, rename it and the id (they must match) and list your files per realm.
return {
	id = "example",
	description = "Template module: greets players in their language, shares a heartbeat and counts waves",
	-- provides = "example",      -- interface implemented by this module, defaults to the id
	-- requires = { "organism" }, -- hard dependencies (interfaces)
	-- optional = { "hud" },      -- soft dependencies: loaded first when present
	files = {
		sh = { "sh_example.lua" },
		sv = { "sv_example.lua" },
		cl = { "cl_example.lua" },
	},
	config = {
		interval = 5, -- heartbeat period, seconds
	},
	-- Network messages "nc.example.<name>" with typed fields (docs/ARCHITECTURE.md, section 8).
	net = {
		-- Server -> client: the heartbeat counter.
		state = { from = "server", fields = { { "beats", "uint", bits = 16 } } },
		-- Client -> server: a wave; at most one a second, three in a row.
		wave = { from = "client", rate = 1, burst = 3, fields = { { "mood", "enum", values = { "happy", "calm" } } } },
	},
	-- Per-entity data kept by the platform, removed with the entity and replicated
	-- (docs/ARCHITECTURE.md, section 8): ctx.components.profile.
	components = {
		-- Every client sees how often each player has waved and how.
		profile = { replicate = "all", rate = 4, fields = {
			{ "waves", "uint", bits = 16 },
			{ "mood", "enum", values = { "happy", "calm" } },
		}, defaults = { mood = "calm" } },
	},
	-- Privileges "example.<name>" (platform/permissions.lua): an admin mod or an admin panel
	-- decides who has them, else the level does (user < admin < superadmin < nobody).
	permissions = {
		reset = { level = "admin", desc = "Reset the heartbeat counter" },
	},
	-- Interface strings are not kept here: they live in lang/<code>/example.lua.
}
