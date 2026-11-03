-- Next-City configuration.
-- This file is sent to clients: never put passwords, keys or other secrets here.

return {
	-- Console log level: "trace", "debug", "info", "warn", "error" or "off".
	logLevel = "info",

	modules = {
		-- Modules to turn off: [id] = true.
		disabled = {
			example = true, -- template for new modules, see modules/example
		},

		-- Implementation to use when several modules provide one interface: [interface] = id.
		-- Example: organism = "organism_realistic".
		providers = {},

		-- Settings per module, merged over the config defaults of its module.lua: [id] = { ... }.
		-- Example: example = { interval = 10 }.
		settings = {},
	},
}
