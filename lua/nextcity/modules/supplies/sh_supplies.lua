-- Supplies, shared part: the items, on both realms in the same order. Names and
-- descriptions: lang/<code>/items.lua of this package (armor: the names of its kinds).

local M = NC.Module("supplies")

local pairs = pairs
local ipairs = ipairs

local function medical(treatment, time, othersTime, extra)
	local trait = { treatment = treatment, time = time, othersTime = othersTime }
	for key, value in pairs(extra or {}) do
		trait[key] = value
	end
	return { medical = trait }
end

local BOX = "models/props_lab/box01a.mdl"
local VIAL = "models/healthvial.mdl"
local KIT = "models/items/healthkit.mdl"
local BOTTLE = "models/props_junk/garbage_plasticbottle001a.mdl"

M.ITEMS = {
	-- Medicine.
	{ "bandage", { model = BOX, weight = 0.05, stack = 5, category = "medical",
		traits = medical("bandage", 3, 2.5) } },
	{ "gauze", { model = BOX, weight = 0.05, stack = 3, category = "medical",
		traits = medical("hemostatic", 5, 4) } },
	{ "tourniquet", { model = BOX, weight = 0.1, stack = 2, category = "medical",
		traits = medical("tourniquet", 4, 3) } },
	{ "splint", { model = BOX, weight = 0.2, stack = 2, category = "medical",
		traits = medical("splint", 8, 6) } },
	{ "chest_seal", { model = BOX, weight = 0.05, stack = 2, category = "medical",
		traits = medical("chest_seal", 4, 3) } },
	{ "needle", { model = VIAL, weight = 0.03, stack = 2, category = "medical",
		traits = medical("needle", 6, 5) } },
	{ "morphine", { model = VIAL, weight = 0.03, stack = 3, category = "medical",
		traits = medical("morphine", 2, 2, { opts = { dose = 1 } }) } },
	{ "naloxone", { model = VIAL, weight = 0.03, stack = 3, category = "medical",
		traits = medical("naloxone", 2, 2, { opts = { dose = 1 } }) } },
	{ "epinephrine", { model = VIAL, weight = 0.03, stack = 3, category = "medical",
		traits = medical("epinephrine", 2, 2, { opts = { dose = 1 } }) } },
	{ "txa", { model = VIAL, weight = 0.03, stack = 3, category = "medical",
		traits = medical("txa", 3, 3, { opts = { dose = 1 } }) } },
	{ "saline", { model = BOTTLE, weight = 0.55, category = "medical",
		traits = medical("saline", 10, 8, { opts = { ml = 500, seconds = 300 } }) } },
	{ "blood", { model = BOTTLE, weight = 0.5, category = "medical",
		traits = medical("blood", 12, 10, { opts = { ml = 450, seconds = 300 } }) } },
	{ "ifak", { model = KIT, weight = 0.4, category = "medical",
		traits = medical("bandage", 3, 2.5, { uses = 4 }) } },
	{ "defibrillator", { model = "models/props_c17/BriefCase001a.mdl", weight = 2, size = 2, category = "medical",
		traits = medical("defib", 3, 3, { uses = 0, self = false }) } },
	{ "pulse_oximeter", { model = BOX, weight = 0.05, category = "medical",
		traits = { diagnostic = { spo2 = true, rhythm = true } } } },
	{ "bp_cuff", { model = BOX, weight = 0.3, category = "medical", traits = { diagnostic = { pressure = true } } } },
	{ "thermometer", { model = VIAL, weight = 0.02, category = "medical",
		traits = { diagnostic = { temperature = true } } } },
	-- Armor (kinds of the armor module; the item takes the name of its kind).
	{ "helmet", { name = "armor.helmet", model = "models/props_junk/MetalBucket01a.mdl", weight = 1.4, size = 2,
		category = "armor", traits = { armor = "helmet" } } },
	{ "vest_light", { name = "armor.vest_light", model = "models/items/hevsuit.mdl", weight = 2, size = 2,
		category = "armor", traits = { armor = "vest_light" } } },
	{ "vest", { name = "armor.vest", model = "models/items/hevsuit.mdl", weight = 3.5, size = 3, category = "armor",
		traits = { armor = "vest" } } },
	{ "plates", { name = "armor.plates", model = "models/items/battery.mdl", weight = 6, size = 3, category = "armor",
		traits = { armor = "plates" } } },
	{ "plates_heavy", { name = "armor.plates_heavy", model = "models/items/battery.mdl", weight = 8, size = 3,
		category = "armor", traits = { armor = "plates_heavy" } } },
	-- Bags.
	{ "backpack", { model = "models/props_c17/SuitCase_Passenger_Physics.mdl", weight = 1.2, size = 3,
		category = "gear", traits = { wear = "back", container = { slots = 12, maxWeight = 25, maxSize = 2 } } } },
	{ "duffel_bag", { model = "models/props_junk/garbage_bag001a.mdl", weight = 1.6, size = 3, category = "gear",
		traits = { wear = "back", container = { slots = 16, maxWeight = 35, maxSize = 3 } } } },
	{ "chest_rig", { model = "models/props_c17/BriefCase001a.mdl", weight = 0.9, size = 2, category = "gear",
		traits = { wear = "rig", container = { slots = 6, maxWeight = 10, maxSize = 1 } } } },
	{ "pouch", { model = BOX, weight = 0.15, size = 1, category = "gear",
		traits = { container = { slots = 3, maxWeight = 3, maxSize = 1 } } } },
	-- Tools.
	{ "zipties", { model = "models/items/crossbowrounds.mdl", weight = 0.02, stack = 10, category = "gear",
		traits = { restraint = { time = 3, untie = 4, consume = true } } } },
	{ "handcuffs", { model = "models/items/crossbowrounds.mdl", weight = 0.3, category = "gear",
		traits = { restraint = { time = 2, untie = 6, consume = false } } } },
	{ "lockpick", { model = "models/props_c17/tools_pliers01a.mdl", weight = 0.1, category = "gear",
		traits = { lockpick = { time = 10 } } } },
	{ "ram", { model = "models/props_canal/mattpipe.mdl", weight = 6, category = "gear",
		traits = { ram = { time = 3 } } } },
}

function M:Init(ctx)
	local inventory = ctx:Require("inventory")
	for _, entry in ipairs(M.ITEMS) do
		local def = entry[2]
		def.description = def.description or "items." .. entry[1] .. ".desc"
		inventory:RegisterItem(entry[1], def)
	end
	if SERVER then
		self:_InitServer(ctx, inventory)
	end
end
