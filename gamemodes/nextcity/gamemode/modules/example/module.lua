-- Manifest of the example module, a template for new modules.
-- Copy the folder, rename it and the id (they must match) and list your files per realm.
return {
	id = "example",
	description = "Template module: greets joining players in their language and logs a heartbeat",
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
	-- Interface strings are not kept here: they live in lang/<code>/example.lua.
}
