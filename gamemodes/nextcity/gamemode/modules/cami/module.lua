-- CAMI adapter: admin mods (ULX, SAM, ...) decide the privileges of Next-City through
-- the Common Admin Mod Interface. Without the CAMI global (no admin mod) the module does
-- nothing and the levels of platform/permissions.lua apply. Turn it off with
-- modules.disabled.cami = true.
return {
	id = "cami",
	description = "Adapter for admin mods (ULX, SAM...) through CAMI: they decide who has the privileges",
	files = {
		sv = { "sv_cami.lua" },
	},
	config = {
		-- When to ask CAMI: "auto" (only while an admin mod answers CAMI questions; CAMI alone
		-- would ignore permissions.groups), "always" or "never" (only offer the privileges).
		ask = "auto",
		-- Offer the privileges to CAMI, so admin mods list them and grant them to groups.
		register = true,
		-- CAMI name of a privilege: prefix .. id ("nextcity.nc_round").
		prefix = "nextcity.",
		-- Priority of the answers to permissions.can: a source with a higher one (an own
		-- admin panel) is asked first.
		priority = 0,
	},
}
