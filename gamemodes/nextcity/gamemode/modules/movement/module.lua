-- Movement limited by the body (D6): the capabilities of the organism set the speeds of
-- the engine's player movement, take the sprint and jump keys away, make a body that
-- cannot stand crawl and leave an unconscious one no input. Shared: the client predicts
-- its own movement with the same limits.
return {
	id = "movement",
	description = "Movement limited by the body: speeds, sprint, jumps, crawling, no input while unconscious",
	requires = { "players", "organism" },
	files = {
		sh = { "sh_movement.lua" },
		sv = { "sv_movement.lua" },
		cl = { "cl_movement.lua" },
	},
	config = {
		walk = 160,    -- walking speed of a healthy body, units/s
		run = 300,     -- sprinting speed
		slowWalk = 90, -- with the walk key (+walk)
		crouch = 0.4,  -- crouching: share of the walking speed
		crawl = 45,    -- a body that cannot stand, with both arms, units/s
		jump = 190,    -- jump power of a healthy body
	},
}
