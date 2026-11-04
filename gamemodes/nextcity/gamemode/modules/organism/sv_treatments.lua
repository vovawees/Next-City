-- Organism, server part: treatments.
--
-- ApplyTreatment(ply, kind, opts) does to the body what first aid and a medic do; each
-- kind has a handler in M.TREATMENTS (RegisterTreatment adds or replaces one):
--   bandage {region|limb}     a pressure dressing on the worst bleeding wound outside
--   hemostatic {region|limb}  packing with a hemostatic dressing, junctional wounds too
--   tourniquet {limb}         stops the bleeding of a limb below it; tourniquet_off {limb}
--   splint {limb}             splints the broken bones of a limb (the first one without)
--   reduce {limb}             puts a dislocated joint back
--   chest_seal {side}         closes a sucking wound of the chest
--   needle {side}             needle decompression: lets out the air under tension
--   chest_tube {side}         drains air and blood from one side of the chest
--   pericardiocentesis        drains blood from around the heart
--   suction                   clears blood from the airway
--   cpr, ventilate            chest compressions, rescue breaths: each lasts 2 s
--   defib                     a shock of a defibrillator: may restart a fibrillating heart
--   morphine, naloxone, epinephrine, txa {dose}   a dose of a drug (default 1)
--   saline, blood {ml, seconds}                   an infusion (default 500 ml over 120 s)
--   heal                      a new healthy body
-- Sides are "l" and "r" (default: the worse one). Items (M5) decide who may treat, when
-- and how long it takes; here a treatment works at once.
--
-- ApplyTreatment returns true, or false and the reason: "dead" (no living body),
-- "unknown" (kind), "target" (a needed limb is missing or unknown), "nothing" (nothing to
-- treat), "already" (treated already), "pulse" (the heart beats), "not_shockable".

local M = NC.Module("organism")

local min = math.min
local max = math.max
local CurTime = CurTime

local clamp = M.clamp

M.TREATMENTS = {}
local TREATMENTS = M.TREATMENTS

local LIMB = { arm_l = true, arm_r = true, leg_l = true, leg_r = true }
local SIDE = { l = true, r = true }
local DRESSING = {
	bandage = { venous = 0.8, arterial = 0.5, junctional = 0.4 },
	hemostatic = { venous = 0.95, arterial = 0.9, junctional = 0.85 },
}

-- Registers or replaces a treatment: fn(self, state, opts, now) -> ok, reason.
function M:RegisterTreatment(kind, fn)
	assert(type(kind) == "string" and type(fn) == "function", "organism: RegisterTreatment(kind, fn)")
	self.TREATMENTS[kind] = fn
end

-- Treats a simulated, living player (see the top of the file).
function M:ApplyTreatment(ply, kind, opts)
	local st = self.states[ply]
	if st == nil or st.dead then
		return false, "dead"
	end
	local fn = self.TREATMENTS[kind]
	if fn == nil then
		return false, "unknown"
	end
	opts = opts or {}
	local now = CurTime()
	local ok, reason = fn(self, st, opts, now)
	if not ok then
		return false, reason
	end
	st = self.states[ply] -- heal makes a new body
	self.ctx.events:Emit("organism.treated", ply, kind, opts)
	self:_Output(st, now)
	return true
end

-- Wounds and the chest ----------------------------------------------------------------------

local function dressing(kind)
	return function(_, st, opts, _)
		local limb, region = opts.limb, opts.region
		if limb ~= nil and not LIMB[limb] then
			return false, "target"
		end
		local strength = DRESSING[kind]
		local best, bestRate, value
		local wounds = st.wounds
		for i = 1, #wounds do
			local w = wounds[i]
			if w.cavity == "external" and (limb == nil or w.limb == limb) and (region == nil or w.region == region) then
				local v = w.junctional and strength.junctional or (w.arterial and strength.arterial or strength.venous)
				local rate = w.base * (1 - w.bandage) * (1 - w.clot)
				if w.bandage < v and rate > 0 and (best == nil or rate > bestRate) then
					best, bestRate, value = w, rate, v
				end
			end
		end
		if best == nil then
			return false, "nothing"
		end
		best.bandage = value
		best.clotMax = M.ClotLimit(best)
		best.pain = best.pain * 0.85
		return true
	end
end

TREATMENTS.bandage = dressing("bandage")
TREATMENTS.hemostatic = dressing("hemostatic")

TREATMENTS.tourniquet = function(_, st, opts, now)
	local limb = opts.limb
	if not LIMB[limb] then
		return false, "target"
	end
	if st.tourniquets[limb] ~= nil then
		return false, "already"
	end
	st.tourniquets[limb] = now
	st.tourniquetCount = st.tourniquetCount + 1
	return true
end

TREATMENTS.tourniquet_off = function(_, st, opts)
	local limb = opts.limb
	if not LIMB[limb] then
		return false, "target"
	end
	if st.tourniquets[limb] == nil then
		return false, "nothing"
	end
	st.tourniquets[limb] = nil
	st.tourniquetCount = st.tourniquetCount - 1
	return true
end

TREATMENTS.splint = function(_, st, opts)
	local limb = opts.limb
	if limb ~= nil and not LIMB[limb] then
		return false, "target"
	end
	local found, any = nil, false
	local fractures = st.fractureList
	for i = 1, #fractures do
		local f = fractures[i]
		if f.limb ~= nil and (limb == nil or f.limb == limb) then
			any = true
			if not f.splint and found == nil then
				found = f.limb
			end
		end
	end
	if found == nil then
		return false, any and "already" or "nothing"
	end
	for i = 1, #fractures do
		local f = fractures[i]
		if f.limb == found then
			f.splint = true
		end
	end
	return true
end

TREATMENTS.reduce = function(_, st, opts)
	local limb = opts.limb
	if limb == nil then
		for name in pairs(LIMB) do
			if st.dislocated[name] then
				limb = name
				break
			end
		end
	end
	if limb == nil then
		return false, "nothing"
	end
	if not LIMB[limb] then
		return false, "target"
	end
	if not st.dislocated[limb] then
		return false, "nothing"
	end
	st.dislocated[limb] = nil
	st.dislocations = st.dislocations - 1
	return true
end

-- The side given in opts, else the one where `score` is higher (nil if both are 0).
local function pickSide(opts, score)
	local side = opts.side
	if side ~= nil then
		return SIDE[side] and side or nil, SIDE[side] == nil
	end
	local l, r = score("l"), score("r")
	if l <= 0 and r <= 0 then
		return nil, false
	end
	return l >= r and "l" or "r", false
end

TREATMENTS.chest_seal = function(_, st, opts)
	local side, bad = pickSide(opts, function(s) return st.open[s] and 1 or 0 end)
	if bad then
		return false, "target"
	end
	if side == nil or not st.open[side] then
		return false, "nothing"
	end
	st.open[side] = false
	return true
end

TREATMENTS.needle = function(_, st, opts)
	local side, bad = pickSide(opts, function(s) return st.tension[s] + st.pneumo[s] end)
	if bad then
		return false, "target"
	end
	if side == nil or (st.tension[side] <= 0 and st.pneumo[side] < 0.3) then
		return false, "nothing"
	end
	st.tension[side] = 0
	st.valve[side] = false
	st.pneumo[side] = min(st.pneumo[side], 0.6)
	return true
end

TREATMENTS.chest_tube = function(_, st, opts)
	local cavity = st.cavity
	local side, bad = pickSide(opts, function(s)
		return st.pneumo[s] + st.tension[s] + cavity[s == "l" and "chest_l" or "chest_r"] / 1800
	end)
	if bad then
		return false, "target"
	end
	if side == nil then
		return false, "nothing"
	end
	if st.tube[side] then
		return false, "already"
	end
	st.tube[side] = true
	return true
end

TREATMENTS.pericardiocentesis = function(_, st)
	local cavity = st.cavity
	if cavity.pericardium <= 0 then
		return false, "nothing"
	end
	cavity.pericardium = max(0, cavity.pericardium - 200)
	return true
end

TREATMENTS.suction = function(_, st)
	if st.cavity.airway <= 0 then
		return false, "nothing"
	end
	st.cavity.airway = 0
	return true
end

-- Resuscitation -----------------------------------------------------------------------------

TREATMENTS.cpr = function(_, st, _, now)
	if st.rhythm == "sinus" then
		return false, "pulse"
	end
	st.cprUntil = now + 2
	return true
end

TREATMENTS.ventilate = function(_, st, _, now)
	st.ventUntil = now + 2
	return true
end

TREATMENTS.defib = function(self, st)
	if st.rhythm == "sinus" then
		return false, "pulse"
	end
	if st.rhythm ~= "vf" then
		return false, "not_shockable"
	end
	local chance = clamp(0.75 - st.rhythmTime / 600, 0.1, 0.75) + 0.1 * min(1, st.level.epinephrine)
	if (st.damage.heart or 0) >= 0.75 or not self:_Reversible(st) then
		chance = chance * 0.2
	end
	if M.Random() < chance then
		self:_Rosc(st)
	end
	return true
end

-- Drugs and fluids --------------------------------------------------------------------------

for _, name in ipairs(M.DRUG_LIST) do
	TREATMENTS[name] = function(_, st, opts)
		local dose = tonumber(opts.dose) or 1
		if dose <= 0 then
			return false, "nothing"
		end
		st.depot[name] = st.depot[name] + dose
		return true
	end
end

local function infusion(kind)
	return function(_, st, opts)
		local ml = tonumber(opts.ml) or 500
		local seconds = tonumber(opts.seconds) or 120
		if ml <= 0 then
			return false, "nothing"
		end
		local list = st.infusions
		list[#list + 1] = { kind = kind, left = ml, rate = ml / max(1, seconds) }
		return true
	end
end

TREATMENTS.saline = infusion("saline")
TREATMENTS.blood = infusion("blood")

TREATMENTS.heal = function(self, st)
	self:_Track(st.ply)
	return true
end
