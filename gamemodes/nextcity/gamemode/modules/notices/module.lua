-- Notices: short messages to players in their own language. The server sends the key of
-- a translation and its params, each client translates them; they show up as toasts at
-- the top right of the screen and, when asked, as a line of the chat.
return {
	id = "notices",
	description = "Notices: translated messages to players as toasts and chat lines",
	files = {
		sv = { "sv_notices.lua" },
		cl = { "cl_notices.lua" },
	},
	config = {
		duration = 6, -- s a toast stays on the screen
		max = 5,      -- toasts on the screen at once: a new one pushes the oldest out
	},
	net = {
		-- Server -> client: a notice; params of kind "key" are translated too, "number"
		-- ones are numbers again (plural forms).
		notice = { from = "server", fields = {
			{ "key", "string", max = 64 },
			{ "kind", "enum", values = { "info", "good", "warn", "bad" } },
			{ "chat", "bool" },
			{ "params", "array", max = 8, of = { "struct", fields = {
				{ "name", "string", max = 24 },
				{ "kind", "enum", values = { "text", "key", "number" } },
				{ "value", "string", max = 128 },
			} } },
		} },
	},
}
