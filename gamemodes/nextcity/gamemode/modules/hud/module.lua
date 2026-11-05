-- The minimal HUD of the body: no health or suit numbers (D6, the engine's health means
-- nothing); the screen darkens, greys and blurs with the state of the body and goes black
-- while unconscious, with the way to give up; short lines tell what is wrong with the body
-- and what armor is worn.
return {
	id = "hud",
	description = "Minimal HUD: screen effects of the body, its statuses, armor, unconsciousness",
	requires = { "organism" },
	optional = { "armor", "menu" },
	files = {
		cl = { "cl_hud.lua" },
	},
	config = {
		effects = true, -- darkening, loss of colour and blur by the state of the body
		statuses = 8,   -- most status lines shown at once
	},
}
