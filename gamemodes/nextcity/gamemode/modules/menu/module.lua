-- The player menu (F1, gm_showhelp): tabs of modules (the profile, the character, the
-- appearance...), the settings (the language) and the help: the keys of the modules and
-- the console commands this player may run.
return {
	id = "menu",
	description = "Player menu on F1: tabs of modules, the settings (language) and help on keys and commands",
	files = {
		sv = { "sv_menu.lua" },
		cl = { "cl_menu.lua", "cl_tabs.lua" },
	},
	config = {
		tab = "", -- the tab the menu shows first ("" - the first one); later the last open one
	},
	net = {
		-- Client -> server: the help tab asks for the commands of the player.
		ask = { from = "client", rate = 1, burst = 3, fields = {} },
		-- Server -> client: the console commands the player may run, by name.
		commands = { from = "server", fields = {
			{ "list", "array", max = 128, of = { "struct", fields = {
				{ "name", "string", max = 32 },
				{ "module", "string", max = 32 },
				{ "help", "string", max = 160 },
				{ "admin", "bool" },
			} } },
		} },
	},
}
