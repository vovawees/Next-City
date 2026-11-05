-- Voice: what players say into the microphone is heard from where they stand and as far as
-- the mode of the voice carries (a whisper, the normal voice, a yell) where the mode makes
-- voices local (the city), by everybody otherwise (the team in team play); a radio carried
-- in the inventory, tuned to a frequency, carries the voice to every radio on it while its
-- key is held. The unconscious neither talk nor hear, the dead talk to the dead where voices
-- are local, the rules of the round stay (dead_mute). Who hears whom is kept in a matrix
-- rebuilt a few times a second: the engine asks many times a tick. The HUD shows who talks.
return {
	id = "voice",
	description = "Voice: 3D by distance with whisper, normal and yell, radios with frequencies and a talk key, HUD",
	requires = { "players" },
	optional = { "inventory", "organism", "teams", "notices", "menu" },
	files = {
		sh = { "sh_voice.lua" },
		sv = { "sv_voice.lua" },
		cl = { "cl_voice.lua" },
	},
	config = {
		proximity = false,  -- voices are heard by distance (modes answer voice.proximity)
		whisperRange = 120, -- units (~2 m) of a whisper
		normalRange = 600,  -- units (~11 m) of the normal voice
		yellRange = 1400,   -- units (~27 m) of a yell
		mode = "normal",    -- the voice of a newcomer
		refresh = 0.25,     -- s between the rebuilds of who hears whom
		teamOnly = true,    -- where voices are global, team play keeps them in the team (unless sv_alltalk)
		frequency = 1,      -- of a new radio
		maxFrequency = 999, -- radios tune to 1..maxFrequency
		radioRange = 0,     -- units a radio carries, 0: everywhere (the trait radio of an item may say its own)
	},
	components = {
		-- How every player talks: the mode of his voice and whether he talks into his radio.
		voice = { replicate = "all", rate = 4, fields = {
			{ "mode", "enum", values = { "whisper", "normal", "yell" } },
			{ "radio", "bool" },
		}, defaults = { mode = "normal", radio = false }, desc = "the mode of the voice and the talk key of the radio" },
		-- The radio a player carries (the first one): its frequency and whether it is on.
		radio = { replicate = "owner", rate = 2, fields = {
			{ "frequency", "uint", bits = 10 },
			{ "on", "bool" },
		}, desc = "the frequency of the player's radio and whether it is on" },
	},
	net = {
		-- Client -> server: the talk key of the radio is held (on) or released.
		ptt = { from = "client", rate = 4, burst = 8, fields = {
			{ "on", "bool" },
		} },
	},
}
