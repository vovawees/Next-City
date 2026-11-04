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
-- "unknown" (kind), "target" (an unknown limb or side), "nothing" (nothing to treat),
-- "already" (treated already), "pulse" (the heart beats), "not_shockable". Without a limb
-- a tourniquet goes on the limb that bleeds the most (tourniquet_off: the oldest one).
-- CanTreat(ply, kind, opts) answers the same without treating; Examine(ply) is what a
-- medic finds on the body (the medical module turns it into a report).

local M = NC.Module("organism")

local min = math.min
local max = math.max
local floor = math.floor
local sort = table.sort
local ipairs = ipairs
local CurTime = CurTime

local clamp = M.clamp

M.TREATMENTS = {}
M.TREATMENT_CHECKS = {}
local TREATMENTS = M.TREATMENTS
local CHECKS = M.TREATMENT_CHECKS

local LIMB = { arm_l = true, arm_r = true, leg_l = true, leg_r = true }
local LIMBS = { "arm_l", "arm_r", "leg_l", "leg_r" }
local SIDE = { l = true, r = true }
local DRESSING = {
	bandage = { venous = 0.8, arterial = 0.5, junctional = 0.4 },
	hemostatic = { venous = 0.95, arterial = 0.9, junctional = 0.85 },
}

-- Registers or replaces a treatment: fn(self, state, opts, now) -> ok, reason applies it;
-- check(self, state, opts, now) -> ok, reason (optional) tells whether it would, without
-- changing the body (CanTreat).
function M:RegisterTreatment(kind, fn, check)
	assert(type(kind) == "string" and type(fn) == "function", "organism: RegisterTreatment(kind, fn, check)")
	assert(check == nil or type(check) == "function", "organism: RegisterTreatment: check must be a function")
	self.TREATMENTS[kind] = fn
	self.TREATMENT_CHECKS[kind] = check
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

-- Whether ApplyTreatment(ply, kind, opts) would treat: true, or false and the reason.
-- Changes nothing (a treatment without a check is assumed to work).
function M:CanTreat(ply, kind, opts)
	local st = self.states[ply]
	if st == nil or st.dead then
		return false, "dead"
	end
	if self.TREATMENTS[kind] == nil then
		return false, "unknown"
	end
	local check = self.TREATMENT_CHECKS[kind]
	if check == nil then
		return true
	end
	local ok, reason = check(self, st, opts or {}, CurTime())
	if not ok then
		return false, reason
	end
	return true
end

-- A treatment of a finder: find(self, st, opts, now) -> what to treat or nil, reason;
-- apply(self, st, found, opts, now) treats it. The check is the finder alone.
local function define(kind, find, apply)
	TREATMENTS[kind] = function(self, st, opts, now)
		local found, extra = find(self, st, opts, now)
		if found == nil then
			return false, extra
		end
		apply(self, st, found, opts, now, extra)
		return true
	end
	CHECKS[kind] = function(self, st, opts, now)
		local found, extra = find(self, st, opts, now)
		if found == nil then
			return false, extra
		end
		return true
	end
end

-- Wounds and the chest ----------------------------------------------------------------------

-- The rate a wound would bleed at without a tourniquet (ml/min at normal pressure).
local function openRate(w)
	return w.base * (1 - w.bandage) * (1 - w.clot)
end

local function dressing(kind)
	local strength = DRESSING[kind]
	define(kind, function(_, st, opts)
		local limb, region = opts.limb, opts.region
		if limb ~= nil and not LIMB[limb] then
			return nil, "target"
		end
		local best, bestRate, value
		local wounds = st.wounds
		for i = 1, #wounds do
			local w = wounds[i]
			if w.cavity == "external" and (limb == nil or w.limb == limb) and (region == nil or w.region == region) then
				local v = w.junctional and strength.junctional or (w.arterial and strength.arterial or strength.venous)
				local rate = openRate(w)
				if w.bandage < v and rate > 0 and (best == nil or rate > bestRate) then
					best, bestRate, value = w, rate, v
				end
			end
		end
		if best == nil then
			return nil, "nothing"
		end
		return best, value
	end, function(_, _, best, _, _, value)
		best.bandage = value
		best.clotMax = M.ClotLimit(best)
		best.pain = best.pain * 0.85
	end)
end

dressing("bandage")
dressing("hemostatic")

-- The limb a tourniquet would stop the most bleeding of (without one yet), or nil.
local function bleedingLimb(st)
	local rates = {}
	local wounds = st.wounds
	for i = 1, #wounds do
		local w = wounds[i]
		local limb = w.limb
		if limb ~= nil and w.cavity == "external" and not w.junctional and st.tourniquets[limb] == nil then
			rates[limb] = (rates[limb] or 0) + openRate(w)
		end
	end
	local best, bestRate = nil, 0.5
	for _, limb in ipairs(LIMBS) do
		local rate = rates[limb]
		if rate ~= nil and rate > bestRate then
			best, bestRate = limb, rate
		end
	end
	return best
end

-- Without a limb: the one that bleeds the most.
define("tourniquet", function(_, st, opts)
	local limb = opts.limb
	if limb == nil then
		limb = bleedingLimb(st)
		if limb == nil then
			return nil, st.tourniquetCount > 0 and "already" or "nothing"
		end
	end
	if not LIMB[limb] then
		return nil, "target"
	end
	if st.tourniquets[limb] ~= nil then
		return nil, "already"
	end
	return limb
end, function(_, st, limb, _, now)
	st.tourniquets[limb] = now
	st.tourniquetCount = st.tourniquetCount + 1
end)

-- Without a limb: the tourniquet that has been on the longest.
define("tourniquet_off", function(_, st, opts)
	local limb = opts.limb
	if limb == nil then
		local since
		for _, name in ipairs(LIMBS) do
			local t = st.tourniquets[name]
			if t ~= nil and (since == nil or t < since) then
				limb, since = name, t
			end
		end
		if limb == nil then
			return nil, "nothing"
		end
	end
	if not LIMB[limb] then
		return nil, "target"
	end
	if st.tourniquets[limb] == nil then
		return nil, "nothing"
	end
	return limb
end, function(_, st, limb)
	st.tourniquets[limb] = nil
	st.tourniquetCount = st.tourniquetCount - 1
end)

define("splint", function(_, st, opts)
	local limb = opts.limb
	if limb ~= nil and not LIMB[limb] then
		return nil, "target"
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
		return nil, any and "already" or "nothing"
	end
	return found
end, function(_, st, found)
	local fractures = st.fractureList
	for i = 1, #fractures do
		local f = fractures[i]
		if f.limb == found then
			f.splint = true
		end
	end
end)

define("reduce", function(_, st, opts)
	local limb = opts.limb
	if limb == nil then
		for _, name in ipairs(LIMBS) do
			if st.dislocated[name] then
				limb = name
				break
			end
		end
	end
	if limb == nil then
		return nil, "nothing"
	end
	if not LIMB[limb] then
		return nil, "target"
	end
	if not st.dislocated[limb] then
		return nil, "nothing"
	end
	return limb
end, function(_, st, limb)
	st.dislocated[limb] = nil
	st.dislocations = st.dislocations - 1
end)

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

define("chest_seal", function(_, st, opts)
	local side, bad = pickSide(opts, function(s) return st.open[s] and 1 or 0 end)
	if bad then
		return nil, "target"
	end
	if side == nil or not st.open[side] then
		return nil, "nothing"
	end
	return side
end, function(_, st, side)
	st.open[side] = false
end)

define("needle", function(_, st, opts)
	local side, bad = pickSide(opts, function(s) return st.tension[s] + st.pneumo[s] end)
	if bad then
		return nil, "target"
	end
	if side == nil or (st.tension[side] <= 0 and st.pneumo[side] < 0.3) then
		return nil, "nothing"
	end
	return side
end, function(_, st, side)
	st.tension[side] = 0
	st.valve[side] = false
	st.pneumo[side] = min(st.pneumo[side], 0.6)
end)

define("chest_tube", function(_, st, opts)
	local cavity = st.cavity
	local side, bad = pickSide(opts, function(s)
		return st.pneumo[s] + st.tension[s] + cavity[s == "l" and "chest_l" or "chest_r"] / 1800
	end)
	if bad then
		return nil, "target"
	end
	if side == nil then
		return nil, "nothing"
	end
	if st.tube[side] then
		return nil, "already"
	end
	return side
end, function(_, st, side)
	st.tube[side] = true
end)

define("pericardiocentesis", function(_, st)
	if st.cavity.pericardium <= 0 then
		return nil, "nothing"
	end
	return true
end, function(_, st)
	local cavity = st.cavity
	cavity.pericardium = max(0, cavity.pericardium - 200)
end)

define("suction", function(_, st)
	if st.cavity.airway <= 0 then
		return nil, "nothing"
	end
	return true
end, function(_, st)
	st.cavity.airway = 0
end)

-- Resuscitation -----------------------------------------------------------------------------

define("cpr", function(_, st)
	if st.rhythm == "sinus" then
		return nil, "pulse"
	end
	return true
end, function(_, st, _, _, now)
	st.cprUntil = now + 2
end)

define("ventilate", function()
	return true
end, function(_, st, _, _, now)
	st.ventUntil = now + 2
end)

define("defib", function(_, st)
	if st.rhythm == "sinus" then
		return nil, "pulse"
	end
	if st.rhythm ~= "vf" then
		return nil, "not_shockable"
	end
	return true
end, function(self, st)
	local chance = clamp(0.75 - st.rhythmTime / 600, 0.1, 0.75) + 0.1 * min(1, st.level.epinephrine)
	if (st.damage.heart or 0) >= 0.75 or not self:_Reversible(st) then
		chance = chance * 0.2
	end
	if M.Random() < chance then
		self:_Rosc(st)
	end
end)

-- Drugs and fluids --------------------------------------------------------------------------

for _, name in ipairs(M.DRUG_LIST) do
	define(name, function(_, _, opts)
		local dose = tonumber(opts.dose) or 1
		if dose <= 0 then
			return nil, "nothing"
		end
		return dose
	end, function(_, st, dose)
		st.depot[name] = st.depot[name] + dose
	end)
end

local function infusion(kind)
	define(kind, function(_, _, opts)
		local ml = tonumber(opts.ml) or 500
		if ml <= 0 then
			return nil, "nothing"
		end
		return ml
	end, function(_, st, ml, opts)
		local seconds = tonumber(opts.seconds) or 120
		local list = st.infusions
		list[#list + 1] = { kind = kind, left = ml, rate = ml / max(1, seconds) }
	end)
end

infusion("saline")
infusion("blood")

define("heal", function()
	return true
end, function(self, st)
	self:_Track(st.ply)
end)

-- Examination -------------------------------------------------------------------------------

local function byRate(a, b)
	return a.rate > b.rate
end

-- What an examination of `ply` finds (a new table), or nil without a body:
--   dead, unconscious, consciousness (0..1), pulse (beats/min, 0: none), rhythm, map
--   (mm Hg), breathing (breaths/min, 0: none), spo2 (0..1), temperature (C), blood (share
--   of the volume), airway (ml of blood in it), internal (ml/min inside), pain, shock,
--   cord (level of a spinal injury, 0: none), skull (ml), tamponade (ml around the heart),
--   bleeding = { { region, limb, rate, arterial, junctional, bandage, tourniquet } }
--              external wounds that bleed, are dressed or under a tourniquet, worst first
--   fractures = { { id, region, limb, open, splint, severity } }
--   dislocations = { limb, ... }; tourniquets = { { limb, minutes } } (oldest first)
--   chest = { l = { open, tension, collapse (0..1), blood (ml), tube }, r = ... }
function M:Examine(ply)
	local st = self.states[ply]
	if st == nil then
		return nil
	end
	local now = CurTime()
	local cavity = st.cavity
	local exam = {
		dead = st.dead, unconscious = st.unconscious and not st.dead, consciousness = st.consciousness,
		pulse = (not st.dead and st.rhythm == "sinus") and floor(st.hr + 0.5) or 0, rhythm = st.rhythm,
		map = floor(st.map + 0.5), breathing = st.dead and 0 or floor(st.rr + 0.5), spo2 = st.spo2,
		temperature = st.temperature, blood = st.blood / st.volume, airway = cavity.airway,
		internal = st.internal, pain = st.pain, shock = st.shock, cord = st.cord, skull = cavity.skull,
		tamponade = cavity.pericardium, bleeding = {}, fractures = {}, dislocations = {}, tourniquets = {},
		chest = {},
	}
	local bleeding = exam.bleeding
	for _, w in ipairs(st.wounds) do
		if w.cavity == "external" then
			local under = w.limb ~= nil and st.tourniquets[w.limb] ~= nil and not w.junctional
			if w.flow > 0.5 or under or (w.bandage > 0 and openRate(w) > 0.5) then
				bleeding[#bleeding + 1] = { region = w.region, limb = w.limb, rate = w.flow, arterial = w.arterial,
					junctional = w.junctional, bandage = w.bandage, tourniquet = under }
			end
		end
	end
	sort(bleeding, byRate)
	for _, f in ipairs(st.fractureList) do
		exam.fractures[#exam.fractures + 1] = { id = f.base, region = f.region, limb = f.limb, open = f.open,
			splint = f.splint, severity = f.severity }
	end
	for _, limb in ipairs(LIMBS) do
		if st.dislocated[limb] then
			exam.dislocations[#exam.dislocations + 1] = limb
		end
		local since = st.tourniquets[limb]
		if since ~= nil then
			exam.tourniquets[#exam.tourniquets + 1] = { limb = limb, minutes = (now - since) / 60, since = since }
		end
	end
	sort(exam.tourniquets, function(a, b) return a.since < b.since end)
	for _, side in ipairs({ "l", "r" }) do
		exam.chest[side] = { open = st.open[side], tension = st.tension[side] > 0, collapse = st.pneumo[side],
			blood = cavity[side == "l" and "chest_l" or "chest_r"], tube = st.tube[side] }
	end
	return exam
end
