-- Organism, server part: physiology.
--
-- A body advances in steps of about 0.1 s through an ordered list of replaceable steps
-- (SetStep): drugs -> bleeding -> circulation -> respiration -> brain -> neuro (pain,
-- adrenaline, shock) -> consciousness -> stamina -> temperature. Afterwards the
-- capabilities are derived from the state; consumers read only them.
--
-- In short: wounds bleed by the pressure, clot by themselves up to a limit that depends
-- on their size, and fill the cavities they bleed into (hemothorax, tamponade, a
-- hematoma in the skull). Blood loss lowers the pressure as a compensating body would;
-- the heart can fibrillate or stop (PEA, asystole). The lungs collapse with air or blood
-- in the chest, an air leak with a valve builds tension; the airway can be blocked.
-- Oxygen reaches the brain by perfusion (pressure minus intracranial pressure), oxygen
-- saturation and hemoglobin; without it the brain dies in brainDeathTime seconds. Pain,
-- adrenaline, drugs and the brain decide consciousness.

local M = NC.Module("organism")

local min = math.min
local max = math.max
local floor = math.floor
local remove = table.remove
local CurTime = CurTime
local bor = bit.bor

local clamp = M.clamp

local DT = 0.1           -- step, s (a late visit takes one step of up to 1.5 DT)
local MAX_GAP = 5        -- a longer pause is simulated as this, s
local NORMAL_MAP = 90    -- mean arterial pressure, mmHg
local CPR_MAP = 35       -- what chest compressions give
local STASIS_CLOT = 0.7  -- how much of a wound clots while a tourniquet stops its flow
local SPRINT_SPEED2 = 150 * 150
local WALK_SPEED2 = 30 * 30

-- Blood loss (share of the volume) -> mean arterial pressure (share of normal) and heart
-- rate of a heart that compensates.
local LOSS = { 0, 0.15, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8 }
local LOSS_MAP = { 1, 0.97, 0.86, 0.7, 0.48, 0.27, 0.1, 0 }
local LOSS_HR = { 72, 95, 120, 138, 150, 140, 90, 40 }

-- Drugs (level 1 = a standard dose): time constants of absorbing a dose and clearing it, s.
M.DRUGS = {
	morphine = { absorb = 40, clear = 2400 },
	naloxone = { absorb = 15, clear = 1500 },
	epinephrine = { absorb = 6, clear = 240 },
	txa = { absorb = 30, clear = 7200 },
}
M.DRUG_LIST = { "morphine", "naloxone", "epinephrine", "txa" }

local DRUGS = M.DRUGS
local DRUG_LIST = M.DRUG_LIST
local CHEST = { l = "chest_l", r = "chest_r" }

local function curve(xs, ys, x)
	if x <= xs[1] then
		return ys[1]
	end
	for i = 2, #xs do
		local b = xs[i]
		if x <= b then
			local a = xs[i - 1]
			return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - a) / (b - a)
		end
	end
	return ys[#ys]
end

-- Opioid effect: morphine minus what naloxone blocks.
local function opioid(st)
	local level = st.level
	local value = level.morphine - 2 * level.naloxone
	return value > 0 and value or 0
end

-- State ------------------------------------------------------------------------------------

-- A healthy body for `ply`.
function M:_NewState(ply, now)
	local volume = self.ctx.config.bloodVolume
	local level, depot = {}, {}
	for _, name in ipairs(DRUG_LIST) do
		level[name], depot[name] = 0, 0
	end
	return {
		ply = ply, dead = false, born = now, time = now,
		-- blood: circulating volume, red cells and clotting factors in ml of normal blood
		volume = volume, blood = volume, cells = volume, factors = volume, hb = 1, coag = 1, loss = 0,
		wounds = {}, external = 0, internal = 0,
		cavity = { chest_l = 0, chest_r = 0, pericardium = 0, abdomen = 0, skull = 0, airway = 0, tissue = 0 },
		-- organs (0..1 by structure id), bones, joints, the spinal cord, muscles of limbs
		damage = {}, fractures = {}, fractureList = {}, dislocated = {}, dislocations = 0, cord = 0,
		tissue = { arm_l = 0, arm_r = 0, leg_l = 0, leg_r = 0 },
		-- heart
		rhythm = "sinus", rhythmTime = 0, vfLimit = 300, hr = 72, map = NORMAL_MAP, tamponade = 0,
		lowFlow = 0, lowOxygen = 0, cprUntil = 0, ventUntil = 0,
		-- breathing: collapse of each lung by air, air leaks, open wounds, tension, valves, drains
		pneumo = { l = 0, r = 0 }, leak = { l = 0, r = 0 }, open = { l = false, r = false },
		tension = { l = 0, r = 0 }, valve = { l = false, r = false }, tube = { l = false, r = false },
		rr = 14, spo2 = 0.98, reserve = 1, ventilation = 1, capacity = 1, water = 0, drowning = false,
		-- brain
		brain = 0, brainstem = 0, icp = 10, delivery = 1,
		-- nerves and the rest
		pain = 0, painRaw = 0, adrenaline = 0, shock = 0, concussion = 0, toxin = 0, trauma = 0, burns = 0,
		consciousness = 1, unconscious = false, unconsciousAt = 0, knockout = 0,
		stamina = 1, exhausted = false, exertion = 0, temperature = 37,
		level = level, depot = depot, infusions = {}, tourniquets = {}, tourniquetCount = 0,
		credit = {},
		-- outputs
		use = { arm_l = 1, arm_r = 1, leg_l = 1, leg_r = 1 },
		caps = M.DecodeCapabilities({ caps = M.CAPS_HEALTHY, speed = 1, sway = 0, recoil = 1, blur = 0 }),
		capsBits = M.CAPS_HEALTHY, statusBits = 0, dark = 0, grey = 0, sentUnconscious = false,
	}
end

-- Heart ------------------------------------------------------------------------------------

-- The heart stops pumping: "vf" (fibrillation, shockable), "pea" or "asystole".
function M:_Arrest(st, rhythm, t)
	if st.rhythm ~= "sinus" then
		return
	end
	st.rhythm = rhythm
	st.rhythmTime = 0
	st.vfLimit = 240 + 180 * M.Random()
	st.lowFlow, st.lowOxygen = 0, 0
	st.arrestAt = t or CurTime()
end

-- The heart beats again.
function M:_Rosc(st)
	st.rhythm = "sinus"
	st.rhythmTime = 0
	st.hr = 110
	st.map = max(st.map, 45)
	st.lowFlow, st.lowOxygen = 0, 0
end

-- Whether what stopped the heart is fixed well enough for it to beat again.
function M:_Reversible(st)
	return st.loss < 0.45 and st.tamponade < 0.3 and max(st.tension.l, st.tension.r) < 0.3
		and (st.damage.heart or 0) < 0.75 and st.temperature >= 30 and st.capacity >= 0.3
end

-- Steps ------------------------------------------------------------------------------------

M.STEP_ORDER = { "drugs", "bleeding", "circulation", "respiration", "brain", "neuro", "consciousness", "stamina",
	"temperature" }
M.STEPS = {}
local STEPS = M.STEPS

STEPS.drugs = function(self, st, dt)
	local level, depot = st.level, st.depot
	for i = 1, #DRUG_LIST do
		local name = DRUG_LIST[i]
		local def = DRUGS[name]
		local amount = level[name]
		local stored = depot[name]
		if stored > 0 then
			local move = stored * min(1, dt / def.absorb)
			depot[name] = stored - move
			amount = amount + move
		end
		if amount > 0 then
			amount = amount - amount * min(1, dt / def.clear)
			if amount < 1e-4 then
				amount = 0
			end
		end
		level[name] = amount
	end
	local infusions = st.infusions
	for i = #infusions, 1, -1 do
		local f = infusions[i]
		local amount = min(f.left, f.rate * dt)
		f.left = f.left - amount
		st.blood = st.blood + amount
		if f.kind == "blood" then
			st.cells = st.cells + amount
			st.factors = st.factors + amount * 0.8
		else
			st.temperature = st.temperature - amount * 0.0005 -- cold fluid
		end
		if f.left <= 0 then
			remove(infusions, i)
		end
	end
end

STEPS.bleeding = function(self, st, dt)
	local pressure = st.map / NORMAL_MAP
	if pressure > 1.3 then
		pressure = 1.3
	end
	-- Veins bleed by a pressure of their own, but only while the heart moves the blood.
	local venous = (0.35 + 0.65 * pressure) * min(1, pressure * 4)
	local txa = st.level.txa
	if txa > 1 then
		txa = 1
	end
	local clotRate = st.coag * (1 + 0.6 * txa) / 60 * dt
	local scale = self.ctx.config.bleedScale
	local tourniquets = st.tourniquets
	local cavity = st.cavity
	local external, internal = 0, 0
	local wounds = st.wounds
	for i = 1, #wounds do
		local w = wounds[i]
		local stopped = w.limb ~= nil and tourniquets[w.limb] ~= nil and not w.junctional
		local limit = w.clotMax
		if txa > 0 then
			limit = limit + (1 - limit) * 0.3 * txa
		end
		if stopped and limit < STASIS_CLOT then
			limit = STASIS_CLOT -- the blood stands still under a tourniquet and clots
		end
		local clot = w.clot
		if clot < limit then
			local k = w.bandage > 0 and clotRate * 1.5 or clotRate
			clot = clot + (limit - clot) * (k > 1 and 1 or k)
			w.clot = clot
		end
		local flow = 0
		if not stopped then
			flow = w.base * (1 - w.bandage) * (1 - clot)
			if flow > 0 then
				flow = flow * (w.arterial and pressure or venous) * scale
				if w.limit ~= nil then
					if w.lost >= w.limit then
						flow = 0
					else
						w.lost = w.lost + flow * dt / 60
					end
				end
			end
		end
		w.flow = flow
		if flow > 0 then
			local into = w.cavity
			if into == "external" then
				external = external + flow
			else
				internal = internal + flow
				cavity[into] = (cavity[into] or 0) + flow * dt / 60
			end
		end
	end
	local blood = st.blood
	local lost = (external + internal) * dt / 60
	if lost > 0 then
		local share = lost / blood
		if share > 1 then
			share = 1
		end
		st.cells = st.cells * (1 - share)
		st.factors = st.factors * (1 - share)
		blood = blood - lost
	end
	blood = blood - st.burns * 30 * dt / 60 -- burns leak plasma
	if blood < st.volume then
		blood = blood + (st.volume - blood) * 0.0002 * dt * min(1, pressure * 4) -- fluid drawn into the vessels
	end
	if blood < 1 then
		blood = 1
	end
	st.blood = blood
	st.external, st.internal = external, internal
	local hb = st.cells / blood
	st.hb = hb > 1.3 and 1.3 or hb
	local coag = st.factors / blood
	if coag > 1 then
		coag = 1
	end
	if st.temperature < 35 then
		coag = coag * max(0.3, 1 - (35 - st.temperature) * 0.12)
	end
	st.coag = coag
	if not st.unconscious and cavity.airway > 0 then
		cavity.airway = max(0, cavity.airway - 3 * dt) -- coughed up
	end
end

STEPS.circulation = function(self, st, dt, t)
	local loss = 1 - st.blood / st.volume
	if loss < 0 then
		loss = 0
	end
	st.loss = loss
	local heart = st.damage.heart or 0
	local tamponade = clamp((st.cavity.pericardium - 50) / 200, 0, 1)
	st.tamponade = tamponade
	local tension = max(st.tension.l, st.tension.r)
	local epi = st.level.epinephrine
	if epi > 2 then
		epi = 2
	end
	if st.rhythm == "sinus" then
		local pump = (1 - 0.85 * heart ^ 1.3) * (1 - 0.9 * tamponade) * (1 - 0.75 * tension)
		local tone = st.cord >= 3 and 0.7 or (st.cord == 2 and 0.85 or 1) -- neurogenic shock
		tone = tone * (1 + 0.25 * epi) * (1 + 0.06 * st.adrenaline)
		local map = NORMAL_MAP * curve(LOSS, LOSS_MAP, loss) * pump ^ 0.7 * tone
		local hr = curve(LOSS, LOSS_HR, loss) + 25 * st.adrenaline + 35 * epi + 60 * st.exertion
			+ 15 * min(1, st.pain) + 40 * max(tamponade, tension) + 20 * heart
		if st.cord >= 3 then
			hr = min(hr, 55 + 20 * epi)
		end
		if st.spo2 < 0.6 then
			hr = hr * max(0.3, st.spo2 / 0.6)
		end
		if st.icp > 45 then
			hr = hr * 0.65 -- the brain is squeezed
		end
		if st.temperature < 35 then
			hr = hr * max(0.4, 1 - (35 - st.temperature) * 0.08)
		end
		hr = clamp(hr, 20, 220)
		st.hr = st.hr + (hr - st.hr) * min(1, dt / 4)
		st.map = st.map + (map - st.map) * min(1, dt / (map < st.map and 1.5 or 4))
		st.lowFlow = st.map < 25 and st.lowFlow + dt or max(0, st.lowFlow - 2 * dt)
		st.lowOxygen = st.spo2 < 0.45 and st.lowOxygen + dt or max(0, st.lowOxygen - 2 * dt)
		if heart >= 0.75 or st.temperature < 28 then
			self:_Arrest(st, "vf", t)
		elseif st.lowFlow >= 12 or st.lowOxygen >= 45 then
			self:_Arrest(st, "pea", t)
		end
		return
	end
	st.rhythmTime = st.rhythmTime + dt
	st.hr = 0
	local cpr = t < st.cprUntil
	if cpr then
		st.map = CPR_MAP * clamp(1 - loss, 0.2, 1)
	else
		st.map = st.map * max(0, 1 - dt)
	end
	if st.rhythm == "vf" and st.rhythmTime >= st.vfLimit then
		st.rhythm = "asystole"
	elseif st.rhythm == "pea" and st.rhythmTime >= 300 then
		st.rhythm = "asystole"
	end
	if cpr and st.rhythm ~= "vf" and self:_Reversible(st) then
		local chance = st.rhythm == "pea" and 0.01 + 0.04 * min(1, epi) or 0.003 * min(1, epi)
		if M.Random() < chance * dt then
			self:_Rosc(st)
		end
	end
end

-- Air and blood in one side of the chest; returns how much the lung is collapsed.
local function pleura(st, side, dt)
	local pneumo = st.pneumo[side]
	local tension = st.tension[side]
	local cavity = st.cavity
	local chest = CHEST[side]
	if st.tube[side] then
		pneumo = pneumo + (0.05 - pneumo) * min(1, dt / 20)
		tension = 0
		cavity[chest] = max(0, cavity[chest] - 30 * dt)
	elseif st.open[side] then
		pneumo = min(1, pneumo + dt / 40) -- air is sucked in through the wound
		tension = max(0, tension - dt / 5)
	else
		local leak = st.leak[side]
		if leak > 0 then
			pneumo = min(1, pneumo + leak * dt)
			leak = leak * (1 - min(1, dt / 300)) -- the lung seals itself
			st.leak[side] = leak >= 1e-4 and leak or 0
			if st.valve[side] and pneumo >= 0.9 then
				tension = min(1, tension + dt / 90)
			end
		elseif pneumo > 0 then
			pneumo = max(0, pneumo - dt / 3600)
		end
	end
	st.pneumo[side], st.tension[side] = pneumo, tension
	local collapse = pneumo + cavity[chest] / 1800
	return collapse > 1 and 1 or collapse
end

STEPS.respiration = function(self, st, dt, t)
	local water = st.ply:WaterLevel()
	st.water = water
	local drive = 1
	local cord = st.cord
	if cord >= 4 then
		drive = 0 -- the diaphragm is paralysed
	elseif cord == 3 then
		drive = 0.65
	end
	if st.brainstem > 0 then
		drive = drive * clamp(1 - st.brainstem * 1.5, 0, 1)
	end
	local opioids = opioid(st)
	if opioids > 1.5 then
		drive = drive * clamp(1 - (opioids - 1.5) * 0.6, 0, 1)
	end
	if st.icp > 60 then
		drive = drive * 0.5
	end
	if st.brain > 0.7 then
		drive = drive * clamp((1 - st.brain) / 0.3, 0, 1)
	end
	if st.rhythm ~= "sinus" then
		drive = st.rhythmTime < 40 and 0.15 or 0 -- agonal gasps
	end
	-- The airway.
	local damage = st.damage
	local block = 0.7 * (damage.trachea or 0)
	local blood = st.cavity.airway / 250
	if not st.unconscious then
		blood = blood * 0.4
	end
	if blood > block then
		block = blood
	end
	if st.unconscious and block < 0.15 then
		block = 0.15 -- the tongue
	end
	st.drowning = water >= 3
	if st.drowning or block > 1 then
		block = 1
	end
	-- The lungs.
	local left = (1 - pleura(st, "l", dt)) * (1 - 0.7 * (damage.lung_l or 0)) * (1 - 0.35 * st.tension.r)
	local right = (1 - pleura(st, "r", dt)) * (1 - 0.7 * (damage.lung_r or 0)) * (1 - 0.35 * st.tension.l)
	local mechanics = 0.45 * left + 0.55 * right
	local ribs = st.fractures.ribcage
	if ribs ~= nil then
		mechanics = mechanics * (ribs.severity >= 2 and 0.65 or 0.88) -- a flail chest or painful breathing
	end
	if st.fractures.sternum ~= nil then
		mechanics = mechanics * 0.9
	end
	local capacity = (1 - block) * mechanics
	st.capacity = capacity
	local ventilation = drive * capacity
	local cpr = t < st.cprUntil
	if t < st.ventUntil and ventilation < 0.8 * capacity then
		ventilation = 0.8 * capacity -- rescue breaths
	elseif cpr and ventilation < 0.5 * capacity then
		ventilation = 0.5 * capacity
	end
	st.ventilation = ventilation
	st.rr = drive > 0 and min(40, (14 + 10 * st.shock + 14 * st.exertion + 40 * max(0, 0.95 - st.spo2))
		* min(1, drive * 1.5)) or 0
	-- Oxygen: the lungs and the circulation set a target; the reserve in the body buys the
	-- first minute without air.
	local target = 0
	if st.rhythm == "sinus" or cpr then
		target = 0.98 * (1 - (1 - ventilation) ^ 4)
	end
	if target < st.spo2 then
		st.reserve = max(0, st.reserve - dt * (1 + 1.5 * st.exertion) * (1 - ventilation) / 60)
		st.spo2 = st.spo2 + (target - st.spo2) * min(1, dt / (st.reserve > 0 and 600 or 20))
	else
		st.reserve = min(1, st.reserve + dt * ventilation / 20)
		st.spo2 = st.spo2 + (target - st.spo2) * min(1, dt / 6)
	end
end

STEPS.brain = function(self, st, dt)
	st.icp = 10 + st.cavity.skull * 0.35 + 25 * (st.damage.brain or 0)
	local perfusion = clamp((st.map - st.icp - 15) / 40, 0, 1)
	local oxygen = st.spo2 / 0.97
	local hb = st.hb
	local toxin = st.toxin
	local delivery = perfusion * (oxygen > 1 and 1 or oxygen) * (hb > 1 and 1 or hb)
		* (1 - 0.7 * (toxin > 1 and 1 or toxin))
	st.delivery = delivery
	if delivery < 0.5 then
		st.brain = st.brain + (0.5 - delivery) / 0.5 * dt / self.ctx.config.brainDeathTime
	end
	if st.icp > 60 then
		st.brainstem = st.brainstem + (st.icp - 60) / 1200 * dt -- herniation
	end
	if st.brainstem >= 1 then
		st.fatal = "brainstem"
	elseif st.brain >= 1 then
		st.fatal = "brain"
	end
end

STEPS.neuro = function(self, st, dt)
	local raw = 0
	local fade = min(1, dt / 240)
	local wounds = st.wounds
	for i = 1, #wounds do
		local w = wounds[i]
		local pain = w.pain
		if pain > w.painMin then
			pain = pain - (pain - w.painMin) * fade
			w.pain = pain
		end
		raw = raw + pain
	end
	local moving = st.exertion
	local fractures = st.fractureList
	for i = 1, #fractures do
		local f = fractures[i]
		local pain = f.pain
		if f.splint then
			pain = pain * 0.35
		elseif moving > 0.2 then
			pain = pain * (1 + moving) -- moving a broken bone
		end
		raw = raw + pain
	end
	raw = raw + 0.35 * st.dislocations + min(1, st.burns * 3) + 0.2 * st.concussion + 0.25 * st.tourniquetCount
	st.painRaw = raw
	-- Pains do not add up: the felt pain saturates towards 2.
	local relief = min(0.85, 0.45 * opioid(st))
	local adrenaline = st.adrenaline
	local pain = 2 * raw / (raw + 1.5) * self.ctx.config.painScale * (1 - relief) * (1 - 0.35 * min(1, adrenaline))
	pain = pain > 2 and 2 or pain
	st.pain = pain
	adrenaline = adrenaline - adrenaline * dt / 180
	if pain > 0.6 then
		adrenaline = adrenaline + (pain - 0.6) * 0.004 * dt
	end
	st.adrenaline = clamp(adrenaline, 0, 1)
	st.shock = clamp((85 - st.map) / 55, 0, 1)
	if st.concussion > 0 then
		st.concussion = max(0, st.concussion - dt / 600)
	end
	if st.toxin > 0 then
		st.toxin = max(0, st.toxin - st.toxin * dt / 900 - dt * 1e-4)
	end
	if st.trauma > 0 then
		st.trauma = max(0, st.trauma - dt * 0.2)
	end
end

STEPS.consciousness = function(self, st, dt, t)
	local target = clamp((st.delivery - 0.25) / 0.35, 0, 1)
	if st.brain > 0.25 then
		target = min(target, clamp(1 - 1.5 * (st.brain - 0.25), 0, 1))
	end
	if st.pain > 1.2 then
		target = min(target, clamp((1.8 - st.pain) / 0.6, 0, 1)) -- fainting from pain
	end
	local opioids = opioid(st)
	if opioids > 2 then
		target = min(target, clamp(1 - (opioids - 2) * 0.7, 0, 1))
	end
	if st.temperature < 32 then
		target = min(target, clamp((st.temperature - 28) / 4, 0, 1))
	end
	if st.toxin > 0.5 then
		target = min(target, clamp((1.4 - st.toxin) / 0.9, 0, 1))
	end
	if st.brainstem > 0 then
		target = min(target, clamp(1 - 2 * st.brainstem, 0, 1))
	end
	if st.icp > 35 then
		target = min(target, clamp((65 - st.icp) / 30, 0, 1))
	end
	if t < st.knockout or st.rhythm ~= "sinus" then
		target = 0
	end
	local c = st.consciousness
	c = c + (target - c) * min(1, dt / (target < c and 1.5 or 4))
	st.consciousness = c
	if st.unconscious then
		if c > 0.45 and t - st.unconsciousAt >= 3 then
			st.unconscious = false
		end
	elseif c < 0.2 then
		st.unconscious = true
		st.unconsciousAt = t
	end
end

STEPS.stamina = function(self, st, dt)
	local ply = st.ply
	local speed2 = ply:GetVelocity():Length2DSqr()
	local sprinting = not st.unconscious and speed2 > SPRINT_SPEED2 and ply:KeyDown(IN_SPEED)
	local walking = speed2 > WALK_SPEED2
	local target = sprinting and 1 or (walking and 0.25 or 0)
	st.exertion = st.exertion + (target - st.exertion) * min(1, dt / (target > st.exertion and 3 or 8))
	local aerobic = clamp(st.delivery * 1.15, 0.1, 1) * (1 - 0.5 * st.shock)
	local stamina = st.stamina
	if sprinting then
		stamina = stamina - dt / self.ctx.config.sprintTime * (2 - aerobic)
	else
		stamina = stamina + dt / (walking and 30 or 15) * aerobic
	end
	stamina = clamp(stamina, 0, 1)
	st.stamina = stamina
	if st.exhausted then
		if stamina >= 0.35 then
			st.exhausted = false
		end
	elseif stamina <= 0.02 then
		st.exhausted = true
	end
end

STEPS.temperature = function(self, st, dt)
	local target = 37 - 2.5 * st.shock - (st.water >= 2 and 4 or 0) - (st.unconscious and 0.5 or 0) - 2 * st.burns
	st.temperature = st.temperature + (target - st.temperature) * min(1, dt / 1500)
end

-- Builds the list of step functions in order.
function M:_BuildSteps()
	local fns = {}
	for i, id in ipairs(self.stepOrder) do
		fns[i] = self.steps[id]
	end
	self.stepFns = fns
end

-- Replaces a step of the simulation, or adds a new one after the step `after` (default:
-- last). fn(self, state, dt, time). Returns the previous function of the step.
function M:SetStep(id, fn, after)
	assert(type(id) == "string" and type(fn) == "function", "organism: SetStep(id, fn, after)")
	local old = self.steps[id]
	self.steps[id] = fn
	if old == nil then
		local order = self.stepOrder
		local at = #order + 1
		for i, other in ipairs(order) do
			if other == after then
				at = i + 1
			end
		end
		table.insert(order, at, id)
	end
	self:_BuildSteps()
	return old
end

-- Ids of the steps in order (a new table).
function M:Steps()
	local list = {}
	for i, id in ipairs(self.stepOrder) do
		list[i] = id
	end
	return list
end

-- Advances a body to `now` in steps of at most DT and writes the outputs; a body that
-- dies on the way stops there.
function M:_Simulate(st, now)
	local dt = now - st.time
	if dt <= 0 then
		return
	end
	st.time = now
	if dt > MAX_GAP then
		dt = MAX_GAP
	end
	local count = floor(dt / DT + 0.5)
	if count < 1 then
		count = 1
	end
	local h = dt / count
	local fns = self.stepFns
	local t = now - dt
	for _ = 1, count do
		t = t + h
		for i = 1, #fns do
			fns[i](self, st, h, t)
		end
		if st.fatal ~= nil then
			break
		end
	end
	if st.fatal ~= nil then
		self:_Die(st, st.fatal)
	else
		self:_Output(st, now)
	end
end

-- Capabilities -----------------------------------------------------------------------------

local LIMBS = { "arm_l", "arm_r", "leg_l", "leg_r" }
local CAPS = M.CAPS
local STATUS = M.STATUS
local LIMB_STATUS = { arm_l = STATUS.fractureArmL, arm_r = STATUS.fractureArmR, leg_l = STATUS.fractureLegL,
	leg_r = STATUS.fractureLegR }
local BONE_STATUS = { ribcage = STATUS.fractureRibs, sternum = STATUS.fractureRibs, clavicle = STATUS.fractureRibs,
	scapula = STATUS.fractureRibs, pelvis = STATUS.fracturePelvis, spine = STATUS.fractureSpine,
	cervical_spine = STATUS.fractureSpine, skull = STATUS.fractureSkull }

-- Derives what the body can do (st.caps, st.capsBits) and what it feels (st.statusBits,
-- st.dark, st.grey) from the state.
function M:_Capabilities(st, t)
	local use = st.use
	local tissue = st.tissue
	for i = 1, #LIMBS do
		local limb = LIMBS[i]
		local value = 1 - 0.6 * tissue[limb]
		if st.dislocated[limb] then
			value = min(value, 0.3)
		end
		local since = st.tourniquets[limb]
		if since ~= nil then
			value = min(value, t - since > 1800 and 0.3 or 0.5)
		end
		use[limb] = value
	end
	local status = 0
	local hips = 1
	local fractures = st.fractureList
	for i = 1, #fractures do
		local f = fractures[i]
		local u = f.use
		if u ~= nil then
			local value = f.splint and u[2] or u[1]
			if f.severity >= 2 then
				value = value * 0.6
			end
			local limb = f.limb
			if limb ~= nil then
				if value < use[limb] then
					use[limb] = value
				end
			elseif value < hips then
				hips = value
			end
		end
		local flag = f.limb ~= nil and LIMB_STATUS[f.limb] or BONE_STATUS[f.base]
		if flag ~= nil then
			status = bor(status, flag)
		end
	end
	if hips < use.leg_l then
		use.leg_l = hips
	end
	if hips < use.leg_r then
		use.leg_r = hips
	end
	local cord = st.cord
	if cord >= 1 then
		use.leg_l, use.leg_r = 0, 0
	end
	if cord >= 4 then
		use.arm_l, use.arm_r = 0, 0
	elseif cord == 3 then
		use.arm_l, use.arm_r = min(use.arm_l, 0.2), min(use.arm_r, 0.2)
	end

	local caps = st.caps
	local alive = not st.dead
	local awake = alive and not st.unconscious
	local legL, legR = use.leg_l, use.leg_r
	local weaker = min(legL, legR)
	local loss = st.loss
	local pain = st.pain
	local stand = awake and legL + legR >= 0.6 and st.consciousness >= 0.5 and loss < 0.45
	local sprint = stand and weaker >= 0.6 and not st.exhausted and loss < 0.35 and st.spo2 >= 0.85 and pain < 1
	local jump = stand and weaker >= 0.7 and not st.exhausted and st.stamina >= 0.1
	local armL, armR = awake and use.arm_l >= 0.25, awake and use.arm_r >= 0.25
	caps.alive, caps.unconscious = alive, alive and st.unconscious
	caps.canStand, caps.canJump, caps.canSprint = stand, jump, sprint
	caps.canUseArmL, caps.canUseArmR = armL, armR
	local speed = 0
	if stand then
		speed = (0.35 + 0.65 * weaker) * (1 - 0.35 * clamp(pain - 0.3, 0, 1)) * (1 - 1.2 * clamp(loss - 0.15, 0, 0.5))
			* clamp((st.spo2 - 0.6) / 0.3, 0.3, 1) * (st.exhausted and 0.75 or 1)
		speed = clamp(speed, 0.15, 1)
	end
	caps.moveSpeedMul = speed
	local arms = min(use.arm_l, use.arm_r)
	caps.aimSway = clamp(0.12 * min(pain, 1.5) + 0.25 * (1 - st.stamina) + 0.4 * (1 - arms) + 0.3 * st.shock
		+ 0.25 * st.concussion + 0.1 * st.adrenaline + 0.4 * (1 - st.consciousness), 0, 1)
	caps.recoilMul = clamp(1 + 0.8 * (2 - use.arm_l - use.arm_r) + 0.3 * min(pain, 1.5) + 0.15 * (1 - st.stamina),
		1, 3)
	caps.visionBlur = clamp(0.6 * st.concussion + 1.2 * max(0, 0.6 - st.delivery) + 0.3 * max(0, opioid(st) - 1)
		+ 0.3 * st.toxin, 0, 1)
	st.dark = (alive and st.unconscious) and 1 or clamp((0.7 - st.delivery) / 0.45, 0, 1)
	st.grey = clamp(max(0, loss - 0.15) * 2.5 + max(0, 0.9 - st.spo2) * 3, 0, 1)

	local bits = 0
	if stand then
		bits = bits + CAPS.stand
	end
	if jump then
		bits = bits + CAPS.jump
	end
	if sprint then
		bits = bits + CAPS.sprint
	end
	if armL then
		bits = bits + CAPS.armL
	end
	if armR then
		bits = bits + CAPS.armR
	end
	if alive then
		bits = bits + CAPS.alive
	end
	if caps.unconscious then
		bits = bits + CAPS.unconscious
	end
	st.capsBits = bits

	if not alive then
		st.statusBits = 0
		return
	end
	if st.unconscious then
		status = bor(status, STATUS.unconscious)
	end
	if st.rhythm ~= "sinus" then
		status = bor(status, STATUS.arrest)
	end
	if st.external >= 150 then
		status = bor(status, STATUS.heavyBleeding)
	elseif st.external >= 5 then
		status = bor(status, STATUS.bleeding)
	end
	if st.ventilation < 0.6 or st.spo2 < 0.9 then
		status = bor(status, STATUS.breathless)
	end
	if st.shock >= 0.4 or loss >= 0.3 then
		status = bor(status, STATUS.shock)
	end
	if pain >= 0.5 then
		status = bor(status, STATUS.pain)
	end
	if cord >= 1 then
		status = bor(status, STATUS.paralysis)
	end
	if st.dislocations > 0 then
		status = bor(status, STATUS.dislocation)
	end
	if st.concussion >= 0.2 then
		status = bor(status, STATUS.concussion)
	end
	if st.burns >= 0.05 then
		status = bor(status, STATUS.burns)
	end
	if st.toxin >= 0.1 then
		status = bor(status, STATUS.poisoned)
	end
	if st.temperature < 35 then
		status = bor(status, STATUS.cold)
	end
	if st.exhausted then
		status = bor(status, STATUS.exhausted)
	end
	if st.tourniquetCount > 0 then
		status = bor(status, STATUS.tourniquet)
	end
	local wounds = st.wounds
	for i = 1, #wounds do
		if wounds[i].bandage > 0 then
			status = bor(status, STATUS.bandaged)
			break
		end
	end
	st.statusBits = status
end

