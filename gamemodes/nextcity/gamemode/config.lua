-- Next-City configuration: the defaults of the core.
-- A server keeps its own settings in lua/nextcity/config/server.lua and packages in their
-- config/ folders (platform/packages.lua): they apply over this file, which stays as it is.
-- Config files are sent to clients: never put passwords, keys or other secrets in them.

return {
	-- Console log level: "trace", "debug", "info", "warn", "error" or "off".
	logLevel = "info",

	net = {
		-- Check outgoing messages against their schemas and log problems (development aid:
		-- costs time on every send).
		checkOutgoing = false,
	},

	-- Translations live in lang/<code>/ (docs/ARCHITECTURE.md, section 12). Players pick a
	-- language with nc_language: "auto" follows the game language.
	i18n = {
		-- Used when a player's language has no translation, and for server-side texts.
		default = "en",
		-- Uncomment to show one language to everybody, ignoring players' choice:
		-- force = "ru",
	},

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
