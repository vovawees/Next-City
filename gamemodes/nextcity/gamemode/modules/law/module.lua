-- Law: the wanted, warrants, arrests and the jail. While a mode keeps the law (the city),
-- its officers want players for a reason and arrest the wanted by tying them up
-- (restraints): the arrested one sits in the jail of the map for a while with empty hands,
-- even after a death or a reconnect. The authority (the mayor) issues warrants that let
-- officers break into the doors of a player; a tied up or jailed player can be searched.
return {
	id = "law",
	description = "Law: the wanted, warrants, arrests with restraints, the jail with a timer, searches",
	requires = { "players" },
	optional = { "restraints", "inventory", "doors", "hands", "actions", "movement", "notices", "storage" },
	files = {
		sh = { "sh_law.lua" },
		sv = { "sv_law.lua" },
		cl = { "cl_law.lua" },
	},
	config = {
		wanted = 300,  -- s a player stays wanted
		warrant = 300, -- s a warrant lasts
		jail = 120,    -- s in jail after an arrest
		reach = 110,   -- units from the eyes of an officer to a player he arrests
		speed = 0.05,  -- share of the speeds an arrested player keeps on a map without a jail
	},
	components = {
		-- Everybody sees who is wanted, who has a warrant and who sits in jail (the HUD, the menu).
		wanted = { replicate = "all", rate = 4, fields = {
			{ "ends", "double" },             -- game time the search ends
			{ "reason", "string", max = 96 },
		}, desc = "a wanted player: until when and why" },
		warrant = { replicate = "all", rate = 4, fields = {
			{ "ends", "double" },
			{ "reason", "string", max = 96 },
		}, desc = "a warrant for a player: officers may break into his doors" },
		jailed = { replicate = "all", rate = 4, fields = {
			{ "ends", "double" },             -- game time he goes free
		}, desc = "an arrested player in jail" },
	},
	net = {
		-- Client -> server: the menu of the police.
		law = { from = "client", rate = 4, burst = 8, fields = {
			{ "op", "enum", values = { "want", "unwant", "warrant", "arrest", "release", "search" } },
			{ "target", "player" },
			{ "reason", "string", max = 96, optional = true },
		} },
	},
}
