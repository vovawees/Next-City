-- Organism, shared part: the flags of the replicated vitals.
--
-- Capabilities are what consumers read (movement, weapons, the HUD): on the server for
-- every simulated player, on a client for the local player only (vitals go to their
-- owner). The table has the same fields on both realms:
--   alive, unconscious, canStand, canJump, canSprint, canUseArmL, canUseArmR (booleans),
--   moveSpeedMul, aimSway (0..1), recoilMul (1..3), visionBlur (0..1).

local M = NC.Module("organism")

local band = bit.band

-- Capability flags (vitals.caps).
M.CAPS = { stand = 1, jump = 2, sprint = 4, armL = 8, armR = 16, alive = 32, unconscious = 64 }
M.CAPS_HEALTHY = 63

-- Status flags (vitals.status): what the HUD tells the player, in the order it does.
M.STATUS_ORDER = {
	"unconscious", "arrest", "heavyBleeding", "bleeding", "breathless", "shock", "pain", "paralysis",
	"fractureArmL", "fractureArmR", "fractureLegL", "fractureLegR", "fractureRibs", "fracturePelvis",
	"fractureSpine", "fractureSkull", "dislocation", "concussion", "burns", "poisoned", "cold", "exhausted",
	"tourniquet", "bandaged",
}
M.STATUS = {}
for i, name in ipairs(M.STATUS_ORDER) do
	M.STATUS[name] = 2 ^ (i - 1)
end

-- Fills `into` (or a new table) with the capabilities encoded in vitals.
function M.DecodeCapabilities(vitals, into)
	local caps = into or {}
	local bits = vitals.caps
	local flags = M.CAPS
	caps.alive = band(bits, flags.alive) ~= 0
	caps.unconscious = band(bits, flags.unconscious) ~= 0
	caps.canStand = band(bits, flags.stand) ~= 0
	caps.canJump = band(bits, flags.jump) ~= 0
	caps.canSprint = band(bits, flags.sprint) ~= 0
	caps.canUseArmL = band(bits, flags.armL) ~= 0
	caps.canUseArmR = band(bits, flags.armR) ~= 0
	caps.moveSpeedMul = vitals.speed
	caps.aimSway = vitals.sway
	caps.recoilMul = vitals.recoil
	caps.visionBlur = vitals.blur
	return caps
end

-- Whether a status flag (a name of M.STATUS) is set in vitals.status.
function M.HasStatus(vitals, name)
	return band(vitals.status, M.STATUS[name]) ~= 0
end
