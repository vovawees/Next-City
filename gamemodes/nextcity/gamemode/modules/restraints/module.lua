-- Restraints: zip ties, handcuffs. The use key on a player (or on his body when he is
-- down) with a restraint in the inventory ties him up after a while; on a tied player it
-- unties him. A tied player keeps empty hands, cannot attack, use, sprint or jump, moves
-- slower and cannot handle his inventory. Modes and the city decide who may tie whom.
return {
	id = "restraints",
	description = "Restraints: tie players up with the use key and an item, untie them; tied players are helpless",
	requires = { "players", "actions" },
	optional = { "inventory", "organism", "movement", "hands", "notices" },
	files = {
		sh = { "sh_restraints.lua" },
		sv = { "sv_restraints.lua" },
		cl = { "cl_restraints.lua" },
	},
	config = {
		range = 72,    -- units from the eyes to a player the use key reaches
		time = 3,      -- s to tie a player up when the restraint does not say
		untie = 3,     -- s to untie a player when his restraint does not say
		speed = 0.55,  -- share of the speeds a tied player keeps
	},
	components = {
		-- A tied player: everybody sees it (the name under the crosshair, the HUD).
		tied = { replicate = "all", rate = 4, fields = {
			{ "since", "double" }, -- game time he was tied up
		}, desc = "a player tied up with a restraint" },
	},
}
