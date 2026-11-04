-- Throwables: the base of the thrown weapons of packages (grenades, smoke, flashbangs,
-- bottles). A weapon is data: the thing, its mass, the energy of the throw, a fuse or an
-- impact, and what it does when it goes off (a function of the package, for example
-- explosions:Explode). The base pulls the pin and throws overhand or underhand as a
-- predicted scripted weapon; the thrown thing is a physics prop the server watches. The
-- core has no throwables (D15).
return {
	id = "throwables",
	description = "Thrown weapons base: pins, cooking, throws, fuses and impacts of the things of packages",
	requires = { "organism" },
	files = {
		sh = { "sh_throwables.lua", "sh_throw.lua" },
		sv = { "sv_throwables.lua" },
		cl = { "cl_throwables.lua" },
	},
	config = {
		energy = 1,        -- multiplier of the energy of every throw
		lob = 0.3,         -- share of the energy of an underhand throw (the attack 2 key)
		impactSpeed = 150, -- units/s of a hit that sets off an impact fuse
		maxLive = 64,      -- live thrown things at most; the oldest beyond go out as duds
	},
}
