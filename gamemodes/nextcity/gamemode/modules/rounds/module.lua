-- Rounds: the round state machine, the registry of modes and rule blocks and their typed
-- parameters (docs/ARCHITECTURE.md, section 11). A mode is a module that registers
-- itself here; this module knows nothing about particular modes.

-- The field with the params of a translated text as messages carry them (EncodeParams and
-- DecodeParams of sh_rounds.lua).
local function params()
	return { "params", "array", max = 8, of = { "struct", fields = {
		{ "name", "string", max = 24 },
		{ "kind", "enum", values = { "text", "key", "number" } },
		{ "value", "string", max = 128 },
	} } }
end

return {
	id = "rounds",
	description = "Round state machine, registry of modes and rule blocks with typed parameters",
	requires = { "players" },
	files = {
		sh = { "sh_rounds.lua" },
		sv = { "sv_registry.lua", "sv_round.lua", "sv_rules.lua", "sv_rounds.lua", "sv_commands.lua" },
		cl = { "cl_rounds.lua" },
	},
	config = {
		mode = "tdm",          -- mode of the first round; without it the first available mode
		rotation = {},         -- modes taking turns, e.g. { "tdm", "homicide" }; empty keeps one mode
		roundsPerMode = 3,     -- rounds of a mode before the rotation moves on
		prepareTime = 5,       -- seconds from spawning to the start
		endTime = 8,           -- seconds the result stays on screen
		freeze = true,         -- participants stand still while preparing
		shuffle = true,        -- participants join a round in random order (random teams)
		cleanupMap = true,     -- clean the map before every round
		warmup = true,         -- while waiting for players everybody plays freely
		warmupRespawn = 3,     -- seconds before a respawn in the warmup
		warmupLoadout = {},    -- weapon classes for the warmup, e.g. { "weapon_crowbar" }
		params = {},           -- parameters per mode: { tdm = { roundTime = 600 } }
	},
	net = {
		-- Server -> client: the phase and its timer; sent on every change and to a player
		-- that becomes ready.
		state = { from = "server", fields = {
			{ "phase", "enum", values = { "waiting", "preparing", "active", "ended" } },
			{ "mode", "string", max = 32 },  -- id of the mode, "" if there is nothing to play
			{ "name", "string", max = 64 },  -- name of the mode: a translation key or plain text
			{ "number", "uint", bits = 16 }, -- round number since the map started
			{ "endsAt", "double", min = 0 }, -- game time the phase ends, 0 without a limit
			{ "minPlayers", "uint", bits = 8 },
		} },
		-- Server -> client: the status line of the round under the timer (Round:SetStatus):
		-- a translation key ("" for none), {time} counting down to endsAt (0: none) and the
		-- params as notices carry them. Sent on every change and to a player that becomes ready.
		status = { from = "server", fields = {
			{ "key", "string", max = 64 },
			{ "endsAt", "double", min = 0 },
			params(),
		} },
		-- Server -> client: how the round ended, sent when it ends.
		result = { from = "server", fields = {
			{ "reason", "string", max = 64 },        -- time, elimination, ... or a translation key
			{ "key", "string", max = 64 },           -- translation key of the headline, "" for the default
			{ "team", "uint", bits = 16 },           -- winning team, 0 if none
			{ "winner", "player", optional = true }, -- winning player
			params(),                                -- of the texts besides team and player
		} },
	},
}
