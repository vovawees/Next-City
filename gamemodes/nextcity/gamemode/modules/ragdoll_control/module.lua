-- Control of a fallen body: a conscious player that lies in its body (see ragdoll) turns
-- its head where it looks, crawls along the ground with the movement keys and holds on to
-- the world and to objects with its hands (the attack keys).
return {
	id = "ragdoll_control",
	description = "Control of a fallen body: the head follows the view, crawling, grabbing with the hands",
	requires = { "ragdoll", "organism" },
	files = {
		sv = { "sv_control.lua" },
	},
	config = {
		rate = 30,       -- times per second the bodies are moved
		look = true,     -- the head turns where the player looks
		neck = 60,       -- degrees the head turns at most from where it faced when the body fell
		turnSpeed = 240, -- degrees/s the head turns at most
		crawl = 40,      -- units/s a body crawls with both arms (0.65 of it with one, 0.3 with none); 0: no crawling
		reach = 48,      -- units from the eyes a hand reaches for; 0: no hands
		grabRange = 8,   -- units from a surface within which a hand holds on
		gripForce = 0,   -- force that breaks a grip (0: it never breaks)
		pull = 12,       -- 1/s: how fast a hand closes in on where it reaches
	},
}
