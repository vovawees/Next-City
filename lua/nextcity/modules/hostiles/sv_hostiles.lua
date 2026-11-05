-- Hostiles, server part: kinds and groups of creatures registered with the npcs module.
-- Ids are what modes and nc_npcs spawn: a group for a wave (params of mode_defense and
-- mode_coop), a kind for one creature.

local M = NC.Module("hostiles")

local ipairs = ipairs

-- Kinds: { id, spec of npcs:RegisterKind }. Health and skill stay those of the engine unless
-- set.
M.KINDS = {
	{ "zombie", { class = "npc_zombie" } },
	{ "zombie_fast", { class = "npc_fastzombie" } },
	{ "zombie_poison", { class = "npc_poisonzombie" } },
	{ "headcrab", { class = "npc_headcrab" } },
	{ "headcrab_fast", { class = "npc_headcrab_fast" } },
	{ "headcrab_poison", { class = "npc_headcrab_black" } },
	{ "antlion", { class = "npc_antlion" } },
	{ "metrocop", { class = "npc_metropolice", weapons = { "weapon_pistol", "weapon_stunstick" },
		proficiency = "average" } },
	{ "combine", { class = "npc_combine_s", model = "models/combine_soldier.mdl",
		weapons = { "weapon_smg1", "weapon_smg1", "weapon_ar2" }, proficiency = "good" } },
	{ "combine_shotgun", { class = "npc_combine_s", model = "models/combine_soldier.mdl", skin = 1,
		weapons = { "weapon_shotgun" }, proficiency = "good" } },
	{ "combine_elite", { class = "npc_combine_s", model = "models/combine_super_soldier.mdl",
		weapons = { "weapon_ar2" }, proficiency = "very_good" } },
	{ "manhack", { class = "npc_manhack" } },
}

-- Groups: { id, { { kind, weight }, ... } } — a wave draws its creatures by the weights.
M.GROUPS = {
	{ "zombies", { { "zombie", 6 }, { "zombie_fast", 2 }, { "zombie_poison", 1 }, { "headcrab", 2 },
		{ "headcrab_fast", 1 } } },
	{ "zombies_fast", { { "zombie_fast", 4 }, { "headcrab_fast", 2 }, { "zombie", 2 } } },
	{ "antlions", { { "antlion", 1 } } },
	{ "metrocops", { { "metrocop", 4 }, { "manhack", 1 } } },
	{ "combine", { { "combine", 4 }, { "combine_shotgun", 2 }, { "metrocop", 1 } } },
	{ "combine_elite", { { "combine", 3 }, { "combine_shotgun", 1 }, { "combine_elite", 2 } } },
}

function M:Init(ctx)
	local npcs = ctx:Require("npcs")
	for _, entry in ipairs(M.KINDS) do
		npcs:RegisterKind(entry[1], entry[2])
	end
	for _, entry in ipairs(M.GROUPS) do
		npcs:RegisterGroup(entry[1], entry[2])
	end
end
