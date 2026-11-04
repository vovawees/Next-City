-- Medical: first aid and medicine with items and hands. A player treats himself or the
-- wounded in front of him (standing or a fallen body) with what he carries; it takes time
-- (an action) and uses the item up. An examination tells what is wrong and offers what he
-- can do about it.
return {
	id = "medical",
	description = "Medicine: treating oneself and others with items and hands, examining the wounded",
	requires = { "players", "inventory", "organism", "actions" },
	optional = { "notices" },
	files = {
		sh = { "sh_medical.lua" },
		sv = { "sv_medical.lua" },
		cl = { "cl_medical.lua" },
	},
	config = {
		reach = 96,        -- units from the eyes to the body of a patient
		examineTime = 2,   -- s to examine another; oneself takes half
		oneArm = 1.6,      -- the time of a treatment with one working arm
		reportTime = 20,   -- s a report stays on the screen and its patient stays chosen
		cprTime = 30,      -- s of one round of chest compressions (two breaths every 6 s)
	},
	net = {
		-- Server -> client: what an examination found and what the player can do about it.
		-- Findings are keys medical.find.<key> with a part of the body, a number and a flag.
		report = { from = "server", fields = {
			{ "patient", "string", max = 32 },
			{ "self", "bool" },
			{ "findings", "array", max = 32, of = { "struct", fields = {
				{ "key", "string", max = 24 },
				{ "part", "string", max = 12 },
				{ "value", "uint", bits = 16 },
				{ "flag", "string", max = 12 },
			} } },
			{ "options", "array", max = 24, of = { "struct", fields = {
				{ "source", "enum", values = { "item", "hands" } },
				{ "id", "string", max = 32 },
				{ "part", "string", max = 12 },
				{ "count", "uint", bits = 16 },
			} } },
		} },
		-- Client -> server: treat the patient of the last report with an item or the hands.
		treat = { from = "client", rate = 4, burst = 8, fields = {
			{ "source", "enum", values = { "item", "hands" } },
			{ "id", "string", max = 32 },
			{ "part", "string", max = 12 },
		} },
		-- Client -> server: examine the one in front (or oneself) again.
		examine = { from = "client", rate = 2, burst = 4, fields = {} },
	},
}
