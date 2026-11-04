-- Medical, shared part: the trait of medical items, the verbs and the treatments by hand.
--
-- An item treats with the trait medical (packages register the items):
--   medical = {
--   	treatment = "bandage",  -- a kind of organism:ApplyTreatment (bandage, tourniquet, splint, ...)
--   	opts = { dose = 1 },    -- passed to the treatment (limbs and sides are chosen by it)
--   	time = 4,               -- s on oneself
--   	othersTime = 3,         -- s on another (default: time)
--   	uses = 1,               -- treatments per item; more: state.charge counts what is left;
--   	                        -- 0: never used up (a defibrillator)
--   	self = true,            -- may treat oneself (default true)
--   	others = true,          -- may treat another (default true)
--   	label = "medical.action.bandage", -- the action bar (default medical.action.<treatment>)
--   }
-- and an item with the trait diagnostic = { spo2 = true, pressure = true, rhythm = true,
-- temperature = true } shows those numbers in the reports of the one who carries it.
--
-- Verbs: use (on oneself) and treat (on the wounded in front, or the patient of the last
-- report). Treatments by hand (M.HANDS) come from the report: chest compressions with
-- breaths, rescue breaths, putting a joint back, taking a tourniquet off.

local M = NC.Module("medical")

-- Treatments without an item: treatment kind, s on another and on oneself (nil: not on
-- oneself), a part of the body to choose (the report offers one per limb).
M.HANDS = {
	cpr = { treatment = "cpr", time = 30, every = 1 },
	ventilate = { treatment = "ventilate", time = 20, every = 4 },
	reduce = { treatment = "reduce", time = 5, selfTime = 9, part = true },
	tourniquet_off = { treatment = "tourniquet_off", time = 3, selfTime = 4, part = true },
}
M.HANDS_ORDER = { "cpr", "ventilate", "reduce", "tourniquet_off" }

-- Parts of the body a report names (keys medical.part.<part>).
M.PARTS = { "head", "face", "neck", "chest", "chest_l", "chest_r", "abdomen", "pelvis", "torso", "back", "arm_l",
	"arm_r", "leg_l", "leg_r" }

function M:_InitShared(ctx)
	self.inventory = ctx:Require("inventory")
	local inventory = self.inventory
	inventory:RegisterVerb("use", { label = "medical.verb.use", order = 5,
		Applies = function(_, def, where)
			local trait = def.traits.medical
			return where == "own" and trait ~= nil and trait.self ~= false
		end })
	inventory:RegisterVerb("treat", { label = "medical.verb.treat", order = 6,
		Applies = function(_, def, where)
			local trait = def.traits.medical
			return where == "own" and trait ~= nil and trait.others ~= false
		end })
end

-- The medical trait of item `id`, or nil.
function M:Trait(id)
	return self.inventory:Trait(id, "medical")
end
