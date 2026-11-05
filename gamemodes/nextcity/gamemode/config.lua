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

	-- Who may do what (platform/permissions.lua). An admin mod (through CAMI) or an admin
	-- panel decides when it answers; these settings apply when nobody answers.
	permissions = {
		-- The level of a privilege instead of the one its module declares: [id] = "user",
		-- "admin", "superadmin" or "nobody". Ids: nc_privileges. Example: nc_round = "admin".
		levels = {},
		-- The rank of a user group: [group] = "user", "admin" or "superadmin".
		-- Example: moderator = "admin".
		groups = {},
		-- Every player's privileges are checked again once in this many seconds and the
		-- client learns the changes (0 turns it off; Refresh still works).
		refresh = 10,
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
