-- Supplies, server part: loot tables, crates and kits (when the loot module runs; the
-- tables of weapons and the kits with weapons need the weaponry module too).
--
--   medical_small, medical_large, armor, gear   tables of one sort of things
--   civilian, military                          mixed: what flats, shops and depots hold
--   crate_wood (civilian), crate_military (military), crate_medical (medical_large)
--
-- Kits (inventory:GiveKit) for modes: tdm — an SMG, a pistol, armor and first aid; the kits
-- of the modes of the package (homicide_*, hideseek_*, riot_*, defense*, coop, city_*).

local M = NC.Module("supplies")

function M:_InitServer(ctx, inventory)
	local weaponry = ctx:Require("weaponry") ~= nil
	local loot = ctx:Require("loot")
	if loot ~= nil then
		self:_Loot(loot, weaponry)
	end
	if weaponry then
		self:_Kits(inventory)
	end
end

function M:_Loot(loot, weaponry)
	loot:RegisterTable("medical_small", { draws = { 1, 2 }, entries = {
		{ item = "bandage", weight = 10, count = { 1, 3 } },
		{ item = "tourniquet", weight = 4 },
		{ item = "gauze", weight = 3 },
		{ item = "splint", weight = 2 },
		{ item = "morphine", weight = 2 },
		{ weight = 4 },
	} })
	loot:RegisterTable("medical_large", { draws = { 2, 4 }, entries = {
		{ item = "bandage", weight = 6, count = { 2, 4 } },
		{ item = "gauze", weight = 4, count = { 1, 2 } },
		{ item = "tourniquet", weight = 4 },
		{ item = "chest_seal", weight = 3 },
		{ item = "needle", weight = 2 },
		{ item = "splint", weight = 3 },
		{ item = "morphine", weight = 3 },
		{ item = "naloxone", weight = 1 },
		{ item = "epinephrine", weight = 1 },
		{ item = "txa", weight = 2 },
		{ item = "saline", weight = 2 },
		{ item = "blood", weight = 1 },
		{ item = "ifak", weight = 2 },
		{ item = "pulse_oximeter", weight = 1 },
		{ item = "bp_cuff", weight = 1 },
		{ item = "thermometer", weight = 1 },
		{ item = "defibrillator", weight = 0.3 },
	} })
	loot:RegisterTable("armor", { entries = {
		{ item = "helmet", weight = 3 },
		{ item = "vest_light", weight = 4 },
		{ item = "vest", weight = 2 },
		{ item = "plates", weight = 1 },
		{ item = "plates_heavy", weight = 0.3 },
	} })
	loot:RegisterTable("gear", { entries = {
		{ item = "backpack", weight = 3 },
		{ item = "duffel_bag", weight = 1 },
		{ item = "chest_rig", weight = 2 },
		{ item = "pouch", weight = 4 },
	} })
	local civilian = {
		{ table = "medical_small", weight = 4 },
		{ table = "gear", weight = 2 },
		{ weight = 4 },
	}
	local military = {
		{ table = "armor", weight = 3 },
		{ table = "medical_small", weight = 3 },
		{ table = "gear", weight = 1 },
	}
	if weaponry then
		civilian[#civilian + 1] = { table = "weapons_civil", weight = 2 }
		civilian[#civilian + 1] = { table = "ammo_pistol", weight = 3 }
		military[#military + 1] = { table = "weapons_military", weight = 3 }
		military[#military + 1] = { table = "ammo", weight = 4 }
	end
	loot:RegisterTable("civilian", { draws = { 1, 3 }, entries = civilian })
	loot:RegisterTable("military", { draws = { 2, 4 }, entries = military })

	loot:RegisterCrate("crate_wood", { model = "models/props_junk/wood_crate001a.mdl", title = "loot.crate.wood",
		size = 12, maxWeight = 60, table = "civilian" })
	loot:RegisterCrate("crate_military", { model = "models/props_junk/wood_crate002a.mdl",
		title = "loot.crate.military", size = 16, maxWeight = 80, table = "military" })
	loot:RegisterCrate("crate_medical", { model = "models/props_junk/cardboard_box001a.mdl",
		title = "loot.crate.medical", size = 10, maxWeight = 30, maxSize = 2, table = "medical_large" })
end

function M:_Kits(inventory)
	inventory:RegisterKit("tdm", {
		{ "helmet" }, { "vest" },
		{ "mp7" }, { "ammo_46x30", 120 },
		{ "usp" }, { "ammo_9x19", 30 },
		{ "knife" }, { "frag" },
		{ "bandage", 2 }, { "tourniquet" },
	})
	-- Homicide: by variant and role (lua/nextcity/modules/mode_homicide).
	inventory:RegisterKit("homicide_murderer", { { "knife" } })
	inventory:RegisterKit("homicide_murderer_wildwest", { { "knife" }, { "python" }, { "ammo_357", 12 } })
	inventory:RegisterKit("homicide_sheriff", { { "python" }, { "ammo_357", 12 } })
	inventory:RegisterKit("homicide_sheriff_gunfree", { { "stunstick" } })
	inventory:RegisterKit("homicide_wildwest", { { "python" }, { "ammo_357", 12 } })
	-- Hide and Seek: the seekers when they catch by a kill (lua/nextcity/modules/mode_hideseek).
	inventory:RegisterKit("hideseek_seeker", { { "usp" }, { "ammo_9x19", 45 }, { "crowbar" } })
	-- Riot: the police (armed when the round has firearms) and the rioters
	-- (lua/nextcity/modules/mode_riot).
	inventory:RegisterKit("riot_police", { { "helmet" }, { "vest" }, { "stunstick" }, { "zipties", 6 } })
	inventory:RegisterKit("riot_police_armed", {
		{ "helmet" }, { "vest" }, { "stunstick" }, { "zipties", 6 }, { "usp" }, { "ammo_9x19", 30 },
	})
	inventory:RegisterKit("riot_rioter", { { "crowbar" }, { "bottle", 2 } })
	-- Defense: the defenders and what the living get after each wave
	-- (lua/nextcity/modules/mode_defense).
	inventory:RegisterKit("defense", {
		{ "helmet" }, { "vest" },
		{ "ar2" }, { "ammo_556", 120 },
		{ "usp" }, { "ammo_9x19", 30 },
		{ "crowbar" },
		{ "bandage", 2 }, { "tourniquet" },
	})
	inventory:RegisterKit("defense_resupply", { { "ammo_556", 60 }, { "ammo_9x19", 15 }, { "bandage" } })
	-- CO-OP: the team clearing the map (lua/nextcity/modules/mode_coop).
	inventory:RegisterKit("coop", {
		{ "helmet" }, { "vest_light" },
		{ "mp7" }, { "ammo_46x30", 160 },
		{ "usp" }, { "ammo_9x19", 30 },
		{ "crowbar" }, { "frag" },
		{ "bandage", 3 }, { "tourniquet" },
	})
	-- City: the gear of the jobs, given with issued = true (lua/nextcity/modules/mode_city).
	inventory:RegisterKit("city_citizen", { { "bandage" } })
	inventory:RegisterKit("city_police", {
		{ "vest_light" }, { "stunstick" }, { "handcuffs" }, { "ram" }, { "usp" }, { "ammo_9x19", 30 }, { "bandage" },
	})
	inventory:RegisterKit("city_medic", {
		{ "bandage", 5 }, { "gauze", 3 }, { "tourniquet", 2 }, { "splint", 2 }, { "morphine", 2 }, { "epinephrine" },
	})
	inventory:RegisterKit("city_gundealer", { { "usp" }, { "ammo_9x19", 15 } })
	inventory:RegisterKit("city_mayor", { { "vest_light" }, { "bandage" } })
	inventory:RegisterKit("city_bandit", { { "crowbar" }, { "zipties", 2 }, { "lockpick" } })
	-- Deathmatch (gamemodes/nextcity/gamemode/modules/mode_dm).
	inventory:RegisterKit("dm", {
		{ "vest_light" },
		{ "mp7" }, { "ammo_46x30", 80 },
		{ "usp" }, { "ammo_9x19", 30 },
		{ "knife" }, { "bandage" },
	})
end
