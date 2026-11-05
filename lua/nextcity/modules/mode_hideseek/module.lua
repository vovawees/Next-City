-- Hide and Seek: the hiders hide while the seekers stand frozen and blindfolded, then the
-- seekers hunt them. The hiders win when the time is up, the seekers when nobody hides
-- any more. Catch by a kill or by a tag (a hit turns a hider into a seeker).
return {
	id = "mode_hideseek",
	description = "Hide and Seek: hiders hide from blindfolded seekers, then the hunt; kill or tag",
	requires = { "rounds", "teams", "players" },
	optional = { "inventory", "loot", "notices", "hands" },
	files = {
		sh = { "sh_hideseek.lua" },
		sv = { "sv_hideseek.lua" },
		cl = { "cl_hideseek.lua" },
	},
	config = {},
	net = {
		-- Server -> client: the game time the seekers are released, 0 when nobody hides.
		-- Sent when a round starts and ends and to a player that becomes ready.
		phase = { from = "server", fields = {
			{ "releaseAt", "double", min = 0 },
		} },
	},
}
