-- Timed actions: bandaging, searching, picking a lock take time. One action per player
-- at a time, with a progress bar; it stops when the player moves away, is hurt, falls
-- unconscious, dies or the target is lost.
return {
	id = "actions",
	description = "Timed actions: progress bars, cancelled by moving, damage, death or a lost target",
	requires = { "players" },
	optional = { "organism", "notices" },
	files = {
		sv = { "sv_actions.lua" },
		cl = { "cl_actions.lua" },
	},
	config = {
		range = 96,     -- units between the player and the target an action keeps by default
		tolerance = 32, -- units a player may move during an action that does not allow moving
		interval = 0.1, -- s between the checks of running actions
	},
	components = {
		-- The action of a player under way; only he sees it.
		action = { replicate = "owner", rate = 10, fields = {
			{ "label", "string", max = 64 },  -- key of the translation, param {target}
			{ "target", "string", max = 48 }, -- the name of the target, "" for none
			{ "startedAt", "double" },
			{ "duration", "float" },
		}, desc = "the timed action of a player" },
	},
}
