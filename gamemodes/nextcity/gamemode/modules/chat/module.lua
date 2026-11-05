-- Chat: what players type becomes lines of channels — said aloud, whispered, yelled, an
-- action (/me) or the world around (/it), in character and heard around the speaker where
-- the mode makes the chat local (the city), everywhere otherwise; out of character for
-- everybody (OOC) or around (LOOC); private messages (/pm, /r); /<command> runs a command of
-- a module. Names are those others see (players:Name: characters, aliases); the unconscious
-- speak only out of character; the rules of the round about the dead stay; floods are held
-- back.
return {
	id = "chat",
	description = "Chat: local or global, whisper and yell, /me and /it, OOC and LOOC, private messages, "
		.. "commands, antispam",
	requires = { "players" },
	optional = { "notices", "menu", "organism", "teams" },
	files = {
		sh = { "sh_chat.lua" },
		sv = { "sv_chat.lua" },
		cl = { "cl_chat.lua" },
	},
	config = {
		proximity = false,  -- lines in character are heard only around the speaker (modes answer chat.proximity)
		whisperRange = 100, -- units (~2 m) of a whisper, always around
		sayRange = 350,     -- units (~7 m) of what is said aloud, /me and /it where the chat is local
		yellRange = 900,    -- units (~17 m) of a yell where the chat is local
		loocRange = 350,    -- units of LOOC, always around
		maxLength = 200,    -- characters of a line
		rate = 1,           -- lines per s a player may send on average
		burst = 5,          -- lines he may send in a row
		repeatDelay = 2,    -- s before the same line may come again
		log = true,         -- the lines in the server console
	},
	net = {
		-- Server -> client: a line of a channel (info: the reply of a command).
		line = { from = "server", fields = {
			{ "channel", "enum", values = { "say", "whisper", "yell", "me", "it", "ooc", "looc", "pm", "pmto", "team",
				"info" } },
			{ "speaker", "entity" },        -- the player who wrote it (NULL when he left)
			{ "name", "string", max = 96 }, -- his name as the others see it ("" for /it; pmto: the receiver's)
			{ "text", "string", max = 800 },
			{ "dead", "bool" },             -- in character from a player who is not alive
		} },
	},
}
