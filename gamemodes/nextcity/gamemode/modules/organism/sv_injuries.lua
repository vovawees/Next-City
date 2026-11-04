-- Organism, server part: injuries.
--
-- Injure turns a hit into wounds (sources of bleeding and pain), damaged organs, broken
-- bones, cut nerves and changes of breathing. Each kind of hit has a handler in
-- M.INJURIES (RegisterInjury adds or replaces one):
--   bullet, fragment         a ray through the structures that loses energy (sv_body.lua)
--   stab, slash              a blade: a short ray
--   blunt, crush, vehicle    energy shared by the structures near the point
--   fall                     fractures and internal injuries by the speed of the landing
--   blast                    blast lung, concussion, fragments, a throw and burns
--   burn, shock, stun, poison, generic, lethal
--
-- Hit fields (all optional but kind): attacker, inflictor, type (DMG_* of the death it
-- may cause), pos and dir (Vectors: the point of the hit and where it goes), force
-- (Vector), amount (damage of the engine), energy (J), projectile (mass g, velocity m/s,
-- diameter mm, penetration cm of soft tissue, expansion, fragment: depth in cm where it
-- breaks up, fragmentFactor), depth (of a blade, cm), speed (of a fall, units/s),
-- segment (blunt: the body segment when the point is unknown), toxin (poison factor),
-- cause (lethal), shield (blast: fn(ply, fragment) meets every fragment before it hits,
-- e.g. armor; it may change the fragment, and false keeps it out), fragments (blast: how
-- many fragments hit, by default by its strength; 0 when they fly as projectiles).
-- The report: kind, wounds, bleeding (ml/min added), energy (J deposited), structures
-- (ids along the way), fractures, fatal (the cause of an instant death or nil).

local M = NC.Module("organism")

local sqrt = math.sqrt
local min = math.min
local max = math.max
local exp = math.exp
local floor = math.floor
local CurTime = CurTime
local IsValid = IsValid

local UNIT_CM = M.UNIT_CM
local BACK = 6               -- rays start this far before the point of the hit, units
local GAP = 0.5              -- passes further apart leave the body and enter it again, units
local PISTOL_MARGIN = 0.15   -- vessels and nerves this close to the track tear, units
local RIFLE_MARGIN = 0.5     -- ...for projectiles with at least RIFLE_ENERGY
local RIFLE_ENERGY = 1000    -- J
local CAVITATION = 1.5       -- radius of the temporary cavity at 1000 J, units
local CENTER = 36            -- height of the middle of the body above its origin, units

M.INJURIES = {}

-- A pistol bullet: the projectile of a bullet hit without one.
M.PROJECTILE = { mass = 8, velocity = 360, diameter = 9, penetration = 45 }
-- A fragment of a grenade or a shell.
M.FRAGMENT = { mass = 1, velocity = 700, diameter = 5, penetration = 15 }

-- How much of a wound clotting can stop by itself (bandages shrink the flow).
local CLOT_K = { external = 40, tissue = 60, abdomen = 20, chest_l = 25, chest_r = 25, pericardium = 15,
	skull = 20, airway = 40 }

local function clamp(v, lo, hi)
	if v < lo then
		return lo
	end
	if v > hi then
		return hi
	end
	return v
end
M.clamp = clamp

local function copy(t)
	local out = {}
	for key, value in pairs(t) do
		out[key] = value
	end
	return out
end

-- Registers or replaces the handler of a kind of hit: fn(self, state, hit, report).
function M:RegisterInjury(kind, fn)
	assert(type(kind) == "string" and type(fn) == "function", "organism: RegisterInjury(kind, fn)")
	self.INJURIES[kind] = fn
end

-- The share of a wound that clotting can stop: all of a small one, little of a large or
-- arterial one.
function M.ClotLimit(w)
	local rate = w.base * (1 - w.bandage)
	if rate <= 0 then
		return 1
	end
	local k = CLOT_K[w.cavity] or 30
	if w.arterial then
		k = k * 0.3
	end
	local limit = sqrt(k / rate)
	return limit > 1 and 1 or limit
end

-- Wounds ---------------------------------------------------------------------------------

-- Beyond the limit the wound that bleeds least joins another one of the same cavity.
local function mergeSmallest(list)
	local smallest, size = 1, math.huge
	for i = 1, #list do
		local w = list[i]
		local rate = w.base * (1 - w.bandage) * (1 - w.clot)
		if rate < size then
			smallest, size = i, rate
		end
	end
	local w = list[smallest]
	local into
	for i = 1, #list do
		local other = list[i]
		if i ~= smallest and other.cavity == w.cavity and (into == nil or other.limb == w.limb) then
			into = other
			if other.limb == w.limb then
				break
			end
		end
	end
	if into ~= nil then
		into.base = into.base + size
		into.pain = max(into.pain, w.pain)
		into.painMin = max(into.painMin, w.painMin)
		into.clotMax = M.ClotLimit(into)
	end
	list[smallest] = list[#list]
	list[#list] = nil
end

-- Adds a wound: bleeding into `cavity` (base ml/min at normal pressure) and pain. `s` is
-- the structure (its limb and flags), `region` overrides its region. Returns the wound.
function M:_AddWound(st, hit, s, cavity, base, pain, region, report)
	local w = {
		kind = hit.kind,
		structure = s and s.id,
		region = region or (s and s.region) or "torso",
		limb = s and s.limb,
		cavity = cavity,
		base = base,
		bandage = 0,
		clot = 0,
		clotMax = 1,
		flow = 0,
		arterial = s ~= nil and s.arterial == true,
		junctional = s ~= nil and s.junctional == true,
		pain = pain,
		painMin = pain * 0.4,
		time = CurTime(),
		attacker = hit.attacker,
		lost = 0,
	}
	w.clotMax = M.ClotLimit(w)
	local list = st.wounds
	list[#list + 1] = w
	if #list > self.ctx.config.maxWounds then
		mergeSmallest(list)
	end
	if report ~= nil then
		report.wounds = report.wounds + 1
		report.bleeding = report.bleeding + base
	end
	return w
end

-- Knocks the player out for `seconds`.
function M:_Knockout(st, seconds)
	local now = CurTime()
	if now + seconds > st.knockout then
		st.knockout = now + seconds
	end
	st.consciousness = 0
	if not st.unconscious then
		st.unconscious = true
		st.unconsciousAt = now
	end
end

-- Breaks a bone (severity 1 simple, 2 comminuted); `open` when the skin is broken too.
-- `side` is the side of the chest for the ribs.
function M:_Fracture(st, hit, s, severity, open, report, side)
	local f = st.fractures[s.id]
	if f == nil then
		f = { id = s.id, base = s.base, severity = severity, open = open, splint = false, limb = s.limb,
			region = s.region, pain = s.pain or 0.4, use = s.use }
		st.fractures[s.id] = f
		local list = st.fractureList
		list[#list + 1] = f
		report.fractures = report.fractures + 1
	else
		if severity > f.severity then
			f.severity = severity
		end
		f.open = f.open or open
	end
	if s.bleed ~= nil then
		local cavity = s.cavity
		if cavity == "chest" then
			cavity = side == "r" and "chest_r" or "chest_l"
		end
		local w = self:_AddWound(st, hit, s, cavity, s.bleed * (0.6 + 0.4 * severity), 0.05, nil, report)
		if cavity == "tissue" then
			w.limit = s.bleed * 8 -- the tissue around the bone fills up and stops it
		end
	end
	local R = M.Random
	if s.id == "spine" and R() < 0.25 * severity then
		st.cord = max(st.cord, (report.height or 0) < 12 and 1 or 2)
	elseif s.id == "cervical_spine" and R() < 0.25 * severity then
		st.cord = max(st.cord, 3)
	elseif s.id == "ribcage" and severity >= 2 and R() < 0.4 then
		local leak = st.leak
		local key = side == "r" and "r" or "l"
		leak[key] = leak[key] + 0.005 -- a broken rib tears the lung
	end
end

-- Credit -----------------------------------------------------------------------------------

-- Remembers who caused how much of the injuries: the death goes to the largest share.
function M:_Credit(st, hit, weight)
	local attacker = hit.attacker
	if not IsValid(attacker) then
		return
	end
	local credit = st.credit[attacker]
	if credit == nil then
		credit = { weight = 0, time = 0 }
		st.credit[attacker] = credit
	end
	credit.weight = credit.weight + weight
	credit.time = CurTime()
	credit.inflictor = hit.inflictor
	credit.type = hit.type
end

-- The attacker with the largest share of the injuries (ties: the latest), their inflictor
-- and damage type; nil if nobody valid hurt the player.
function M:_Killer(st)
	local best, bestCredit
	for attacker, credit in pairs(st.credit) do
		if IsValid(attacker) and (bestCredit == nil or credit.weight > bestCredit.weight
			or (credit.weight == bestCredit.weight and credit.time > bestCredit.time)) then
			best, bestCredit = attacker, credit
		end
	end
	if best == nil then
		return nil
	end
	return best, bestCredit.inflictor, bestCredit.type
end

-- Injure -----------------------------------------------------------------------------------

-- Applies a hit to a simulated, living player. Returns the report, or nil if the player
-- has no living body.
function M:Injure(ply, hit)
	local st = self.states[ply]
	if st == nil or st.dead then
		return nil
	end
	local kind = hit.kind or "generic"
	local handler = self.INJURIES[kind] or self.INJURIES.generic
	local report = { kind = kind, wounds = 0, bleeding = 0, energy = 0, structures = {}, fractures = 0 }
	handler(self, st, hit, report)
	st.adrenaline = min(1, st.adrenaline + 0.1 + min(0.4, (report.energy + report.bleeding) / 1000))
	if hit.pos ~= nil then
		st.lastPos = hit.pos
	end
	if hit.force ~= nil then
		st.lastForce = hit.force
	end
	self:_Credit(st, hit, 1 + report.energy / 100 + report.bleeding / 50 + (report.fatal ~= nil and 100 or 0))
	self.ctx.events:Emit("organism.wounded", ply, hit, report)
	if report.fatal ~= nil then
		self:_Die(st, report.fatal)
	else
		self:_Output(st, CurTime())
	end
	return report
end

-- Lists of the body used by the injuries (after CompileBody).
function M:_IndexBody()
	local body = self.body
	local cavitating, soft, skin = {}, {}, {}
	for _, s in ipairs(body.structures) do
		if s.cavitation ~= nil then
			cavitating[#cavitating + 1] = s
		end
		if s.kind == "soft" then
			soft[#soft + 1] = s
			if s.cavity == "external" and skin[s.seg] == nil then
				skin[s.seg] = s
			end
		end
	end
	body.cavitating, body.soft, body.skin = cavitating, soft, skin
end

-- The soft tissue that bleeds outside on a segment (or its first structure) and its bleeding.
function M:_Skin(seg)
	local s = self.body.skin[seg.id]
	if s ~= nil then
		return s, s.bleed or 30
	end
	return self:SegmentStructures(seg.id)[1], 30
end

-- Point and unit direction of a hit: hit.pos and hit.dir, else the force, else from the
-- attacker, else from the front; the middle of the body without a point (the root bone,
-- the pelvis, of a carrier).
local function ray(st, hit)
	local ply = st.ply
	local carrier = st.carrier
	if carrier ~= nil and not IsValid(carrier) then
		carrier = nil
	end
	local px, py, pz
	if hit.pos ~= nil then
		px, py, pz = hit.pos:Unpack()
	elseif carrier ~= nil then
		px, py, pz = carrier:GetPos():Unpack()
	else
		px, py, pz = ply:GetPos():Unpack()
		pz = pz + CENTER
	end
	local dx, dy, dz = 0, 0, 0
	if hit.dir ~= nil then
		dx, dy, dz = hit.dir:Unpack()
	elseif hit.force ~= nil then
		dx, dy, dz = hit.force:Unpack()
	end
	if dx == 0 and dy == 0 and dz == 0 then
		local attacker = hit.attacker
		if IsValid(attacker) and attacker ~= ply then
			local from = attacker:IsPlayer() and attacker:GetShootPos() or attacker:GetPos()
			local ax, ay, az = from:Unpack()
			dx, dy, dz = px - ax, py - ay, pz - az
		end
	end
	local length = sqrt(dx * dx + dy * dy + dz * dz)
	if length < 1e-6 then
		local _, yaw = (carrier or ply):GetAngles():Unpack()
		yaw = math.rad(yaw)
		return px, py, pz, -math.cos(yaw), -math.sin(yaw), 0
	end
	return px, py, pz, dx / length, dy / length, dz / length
end
M._Ray = ray

local SIDES = { "l", "r" }
-- Segments at the root of a limb: wounds there are junctional, their joints dislocate.
local ROOT = { thigh_l = true, thigh_r = true, upperarm_l = true, upperarm_r = true }

-- Middle of the soft tissue of a segment (frames of `ply`).
function M:_SegmentCenter(ply, seg)
	self:_Frames(self.body, ply)
	local w = self:_Skin(seg).shapes[1].world
	return (w[1] + w[4]) * 0.5, (w[2] + w[5]) * 0.5, (w[3] + w[6]) * 0.5
end

function M:_Dislocate(st, limb)
	if limb ~= nil and not st.dislocated[limb] then
		st.dislocated[limb] = true
		st.dislocations = st.dislocations + 1
	end
end

-- Local coordinates of the middle of a pass of the last cast in the frame of its segment.
function M:_PassPoint(s, t0, t1)
	local trace = self.trace
	local t = (t0 + t1) * 0.5
	return self:_ToLocal(s.segment, trace.ox + trace.dx * t, trace.oy + trace.dy * t, trace.oz + trace.dz * t)
end

-- An organ takes `frac` of its strength: damage, bleeding into its cavity and what the
-- organ does when hurt (blunt: without the tears of a projectile).
function M:_HitOrgan(st, hit, s, frac, report, blunt)
	if frac <= 0 then
		return
	end
	local damage = st.damage
	local after = min(1, (damage[s.id] or 0) + frac)
	damage[s.id] = after
	local base = s.base
	local bleed = s.bleed
	if bleed ~= nil and bleed > 0 then
		local rate = bleed * clamp(frac, 0.15, 1)
		if base == "heart" then
			-- Part stays in the pericardium (tamponade), the rest fills the chest.
			self:_AddWound(st, hit, s, "pericardium", rate * 0.3, 0.2, nil, report)
			self:_AddWound(st, hit, s, "chest_l", rate * 0.7, 0, nil, report)
		else
			self:_AddWound(st, hit, s, s.cavity, rate, 0.1 + 0.2 * min(1, frac), nil, report)
		end
	end
	if base == "heart" then
		if after >= 0.75 then
			self:_Arrest(st, "vf", CurTime())
		end
	elseif base == "brain" then
		st.brain = min(1, st.brain + frac)
		if st.brain >= 1 then
			report.fatal = "head"
		elseif frac >= 0.1 then
			self:_Knockout(st, 10 + 60 * min(1, frac))
		end
	elseif base == "lung" and not blunt then
		local side = s.side
		st.leak[side] = st.leak[side] + 0.008 + 0.04 * min(1, frac)
		if M.Random() < 0.15 then
			st.valve[side] = true -- air gets in and cannot get out: tension
		end
		report[side == "l" and "lungL" or "lungR"] = true
	end
end

-- A wound of the skin where a projectile or a blade enters or leaves at `t` along the ray
-- of the last cast.
function M:_SkinWound(st, hit, s, t, energy, isExit, p, report)
	local trace = self.trace
	local x, y, z = trace.ox + trace.dx * t, trace.oy + trace.dy * t, trace.oz + trace.dz * t
	local seg = s.segment
	local skin, bleed = self:_Skin(seg)
	local k
	if isExit then
		k = clamp(0.6 + energy / 600 + (p.expansion or 0), 0.6, 2.5)
	else
		k = clamp(0.5 + energy / 1000, 0.5, 1.6)
	end
	local region = self:_Region(skin, x, y, z)
	self:_AddWound(st, hit, skin, "external", bleed * k, isExit and 0.15 or 0.2, region, report)
	if seg.id == "torso" and region == "chest" then
		local _, l = self:_ToLocal(seg, x, y, z)
		report[l >= 0 and "wallL" or "wallR"] = true
	end
end

-- A projectile that touched the body but missed the structures: a graze.
function M:_Graze(st, hit, px, py, pz, energy, report)
	local seg = self:NearestSegment(st.ply, px, py, pz)
	if seg == nil then
		return
	end
	local skin, bleed = self:_Skin(seg)
	self:_AddWound(st, hit, skin, "external", bleed * 0.5, 0.12, self:_Region(skin, px, py, pz), report)
	report.energy = report.energy + min(energy, 50)
	if seg.id == "head" and M.Random() < 0.3 then
		st.concussion = max(st.concussion, 0.3)
		self:_Knockout(st, 3 + 7 * M.Random())
	end
end

local passed = {} -- organs the current ray went through

-- What a pass of `dose` J through structure `s` does (t0, t1: the pass on the last cast;
-- grow: how far from the track vessels tear).
function M:_Pass(st, hit, s, dose, t0, t1, grow, report)
	local list = report.structures
	list[#list + 1] = s.id
	local kind = s.kind
	if kind == "organ" then
		passed[s] = true
		self:_HitOrgan(st, hit, s, dose * s.fragility / (s.hp or 50), report)
	elseif kind == "bone" then
		local hp = s.hp or 50
		if dose >= hp * 0.4 then
			local _, l, u = self:_PassPoint(s, t0, t1)
			report.height = u
			self:_Fracture(st, hit, s, (dose >= hp * 2 and s.shell == nil) and 2 or 1, true, report,
				l >= 0 and "l" or "r")
		end
	elseif kind == "vessel" then
		local r = s.shapes[1].world[7] + grow
		local severity = clamp((t1 - t0) / (2 * r), 0.05, 1)
		local w = self:_AddWound(st, hit, s, s.cavity, (s.bleed or 100) * sqrt(severity), 0.1, nil, report)
		if not w.junctional and ROOT[s.seg] then
			local _, _, u = self:_PassPoint(s, t0, t1)
			w.junctional = u < 0.15 -- the groin and the armpit: no tourniquet fits above
		end
	elseif kind == "nerve" then
		if s.cord ~= nil then
			st.cord = max(st.cord, s.cord)
		elseif s.base == "brainstem" then
			st.brainstem = 1
			report.fatal = "head"
		end
	elseif kind == "airway" then
		local frac = dose * s.fragility / (s.hp or 30)
		st.damage[s.id] = min(1, (st.damage[s.id] or 0) + frac)
		self:_AddWound(st, hit, s, "airway", 40 * clamp(frac, 0.2, 1), 0.15, nil, report)
	elseif s.limb ~= nil then
		local tissue = st.tissue
		tissue[s.limb] = min(1, tissue[s.limb] + dose / 300) -- torn muscle weakens the limb
	end
end

-- Organs near the track of a fast projectile are torn by its temporary cavity.
function M:_Cavitation(st, hit, ax, ay, az, bx, by, bz, energy, report)
	local radius = CAVITATION * sqrt(energy / 1000)
	local list = self.body.cavitating
	for i = 1, #list do
		local s = list[i]
		if not passed[s] then
			local d = self:_PathDistance(s, ax, ay, az, bx, by, bz)
			if d < radius then
				local frac = 0.6 * (1 - max(0, d) / radius) * min(2, energy / 2000) * s.cavitation
				self:_HitOrgan(st, hit, s, frac, report, true)
			end
		end
	end
end

-- The wall of the chest and the lung behind it are holed: air may get in.
local function openChest(st, report)
	local R = M.Random
	if report.lungL and report.wallL and R() < 0.5 then
		st.open.l = true
	end
	if report.lungR and report.wallR and R() < 0.5 then
		st.open.r = true
	end
end

-- Projectiles ------------------------------------------------------------------------------

local function bullet(self, st, hit, report)
	local p = hit.projectile or (hit.kind == "fragment" and M.FRAGMENT or M.PROJECTILE)
	local energy = hit.energy or 0.5 * p.mass * 0.001 * p.velocity * p.velocity
	local px, py, pz, dx, dy, dz = ray(st, hit)
	local radius = (p.diameter or 9) * 0.5 / 25.4 * (1 + (p.expansion or 0))
	local grow = radius + (energy >= RIFLE_ENERGY and RIFLE_MARGIN or PISTOL_MARGIN)
	local ox, oy, oz = px - dx * BACK, py - dy * BACK, pz - dz * BACK
	local n = self:Cast(st.ply, ox, oy, oz, dx, dy, dz, grow)
	if n == 0 then
		self:_Graze(st, hit, px, py, pz, energy, report)
		return
	end
	for s in pairs(passed) do
		passed[s] = nil
	end
	local trace = self.trace
	local structures, starts, ends = trace.structure, trace.t0, trace.t1
	local perCm = energy / max(1, p.penetration or 40)
	local remaining = energy
	local depth = 0
	local first = starts[1]
	local lastS, lastT1
	for i = 1, n do
		local s, t0, t1 = structures[i], starts[i], ends[i]
		if lastT1 == nil or t0 - lastT1 > GAP then
			if lastS ~= nil then
				self:_SkinWound(st, hit, lastS, lastT1, remaining, true, p, report)
			end
			self:_SkinWound(st, hit, s, t0, remaining, false, p, report)
		end
		local cm = (t1 - t0) * UNIT_CM
		local rate = perCm * s.density
		if p.fragment ~= nil and depth >= p.fragment then
			rate = rate * (p.fragmentFactor or 2)
		end
		local dose = rate * cm
		if dose > remaining then
			dose = remaining
		end
		remaining = remaining - dose
		depth = depth + cm
		report.energy = report.energy + dose
		self:_Pass(st, hit, s, dose, t0, t1, grow, report)
		lastS, lastT1 = s, t1
		if remaining <= 0.5 then
			break
		end
	end
	if remaining > 0.5 then
		self:_SkinWound(st, hit, lastS, lastT1, remaining, true, p, report)
	end
	openChest(st, report)
	if energy >= RIFLE_ENERGY then
		self:_Cavitation(st, hit, ox + dx * first, oy + dy * first, oz + dz * first, ox + dx * lastT1, oy + dy * lastT1,
			oz + dz * lastT1, energy, report)
	end
end

-- Blades -----------------------------------------------------------------------------------

local BLADES = { stab = 12, slash = 4 } -- default depth of the cut, cm

local function blade(self, st, hit, report)
	local slash = hit.kind == "slash"
	local reach = (hit.depth or BLADES[hit.kind] or 8) / UNIT_CM
	local px, py, pz, dx, dy, dz = ray(st, hit)
	local n = self:Cast(st.ply, px - dx * BACK, py - dy * BACK, pz - dz * BACK, dx, dy, dz, 0.05)
	report.energy = report.energy + 30
	if n == 0 then
		if slash then
			self:_Graze(st, hit, px, py, pz, 30, report)
		end
		return
	end
	local trace = self.trace
	local structures, starts, ends = trace.structure, trace.t0, trace.t1
	local limit = starts[1] + reach
	for i = 1, n do
		local s, t0, t1 = structures[i], starts[i], ends[i]
		if t0 >= limit then
			break
		end
		if t1 > limit then
			t1 = limit
		end
		if i == 1 then
			local x, y, z = trace.ox + trace.dx * t0, trace.oy + trace.dy * t0, trace.oz + trace.dz * t0
			local skin, bleed = self:_Skin(s.segment)
			local region = self:_Region(skin, x, y, z)
			self:_AddWound(st, hit, skin, "external", bleed * (slash and 1.4 or 0.8), slash and 0.3 or 0.25, region,
				report)
			if s.seg == "torso" and region == "chest" then
				local _, l = self:_ToLocal(s.segment, x, y, z)
				report[l >= 0 and "wallL" or "wallR"] = true
			end
		end
		local kind = s.kind
		local cm = (t1 - t0) * UNIT_CM
		if kind == "bone" then
			report.structures[#report.structures + 1] = s.id
			break -- the blade stops on the bone
		elseif kind == "organ" then
			report.structures[#report.structures + 1] = s.id
			self:_HitOrgan(st, hit, s, clamp(cm * 0.06 * s.fragility, 0.05, 0.6), report)
		elseif kind == "soft" then
			report.structures[#report.structures + 1] = s.id
			if s.limb ~= nil then
				st.tissue[s.limb] = min(1, st.tissue[s.limb] + cm / 40)
			end
		else
			self:_Pass(st, hit, s, cm * 10, t0, t1, 0.05, report)
		end
	end
	openChest(st, report)
end

-- Blunt force ------------------------------------------------------------------------------

local weights = {}

-- Shares `energy` (J) among the structures of segment `seg` by their distance from the
-- point of the impact: broken bones, dislocations, ruptured organs, bruises, concussion.
function M:_Blunt(st, hit, energy, report, seg, px, py, pz)
	local list = self:SegmentStructures(seg.id)
	local total = 0
	for i = 1, #list do
		local d = self:_Distance(list[i], px, py, pz)
		local w = exp(-(d > 0 and d or 0) / 2.5)
		weights[i] = w
		total = total + w
	end
	local scale = energy / max(1, total * 0.5)
	local R = M.Random
	local skull = false
	for i = 1, #list do
		local s = list[i]
		local share = weights[i] * scale
		local kind = s.kind
		if kind == "bone" then
			local hp = s.hp or 50
			if share >= hp * 1.5 then
				local _, l, u = self:_ToLocal(seg, px, py, pz)
				report.height = u
				self:_Fracture(st, hit, s, share >= hp * 4 and 2 or 1, false, report, l >= 0 and "l" or "r")
				skull = skull or s.id == "skull"
			elseif share >= hp * 0.8 and ROOT[seg.id] and R() < 0.3 then
				self:_Dislocate(st, s.limb)
			end
		elseif kind == "organ" then
			local frac = share * s.fragility / (s.hp or 50) * 0.35
			if frac >= 0.05 then
				self:_HitOrgan(st, hit, s, frac, report, true)
			end
		elseif kind == "vessel" then
			if share >= 400 then
				self:_AddWound(st, hit, s, s.cavity, (s.bleed or 100) * 0.3, 0.1, nil, report)
			end
		elseif kind == "nerve" then
			if s.cord ~= nil and share >= 300 then
				st.cord = max(st.cord, s.cord)
			elseif s.base == "brainstem" and share >= 200 then
				st.brainstem = min(1, st.brainstem + 0.3)
			end
		elseif kind == "airway" then
			if share >= 100 then
				st.damage[s.id] = min(1, (st.damage[s.id] or 0) + share / 400)
			end
		end
	end
	local skin, bleed = self:_Skin(seg)
	local region = self:_Region(skin, px, py, pz)
	local bruise = self:_AddWound(st, hit, skin, "tissue", 2 + energy / 50, min(0.5, 0.08 + energy / 400), region,
		report)
	bruise.limit = 20 + energy / 2
	if energy >= 150 then
		self:_AddWound(st, hit, skin, "external", bleed * 0.4, 0.1, region, report)
	end
	if seg.id == "head" then
		local c = clamp((energy - 30) / 120, 0, 1)
		if c > st.concussion then
			st.concussion = c
		end
		if c > 0 and R() < c * 0.8 then
			self:_Knockout(st, 5 + 25 * c)
		end
		if skull and R() < 0.35 then
			-- A torn artery under the broken skull: a hematoma that grows for minutes.
			self:_AddWound(st, hit, skin, "skull", 15 + 25 * R(), 0.2, "head", report)
		end
	elseif seg.id == "torso" and region == "chest" and energy >= 20 and energy <= 150 and R() < 0.01 then
		self:_Arrest(st, "vf", CurTime()) -- a blow at the wrong moment of the heartbeat
	end
	report.energy = report.energy + energy
end

local function bluntAt(self, st, hit, report, energy)
	local px, py, pz = ray(st, hit)
	local seg = hit.segment ~= nil and self.body.bySeg[hit.segment] or nil
	if seg ~= nil and hit.pos == nil then
		px, py, pz = self:_SegmentCenter(st.ply, seg)
	elseif seg == nil then
		seg = self:NearestSegment(st.ply, px, py, pz)
	end
	if seg ~= nil then
		self:_Blunt(st, hit, energy, report, seg, px, py, pz)
	end
	return seg
end

local function blunt(self, st, hit, report)
	bluntAt(self, st, hit, report, hit.energy or (hit.amount or 10) * 8)
end

local function crush(self, st, hit, report)
	if (hit.amount or 0) >= 250 then
		report.fatal = "trauma"
		return
	end
	bluntAt(self, st, hit, report, hit.energy or (hit.amount or 10) * 10)
end

local function vehicle(self, st, hit, report)
	if (hit.amount or 0) >= 200 then
		report.fatal = "trauma"
		return
	end
	local energy = hit.energy or (hit.amount or 10) * 15
	local seg = bluntAt(self, st, hit, report, energy)
	local torso = self.body.bySeg.torso
	if torso ~= nil and seg ~= torso then
		local x, y, z = self:_SegmentCenter(st.ply, torso)
		self:_Blunt(st, hit, energy * 0.5, report, torso, x, y, z)
	end
end

-- Falls ------------------------------------------------------------------------------------

local gravity -- the convar sv_gravity, false without it

local function breakBone(self, st, hit, id, severity, report)
	local s = self.body.byId[id]
	if s ~= nil then
		self:_Fracture(st, hit, s, severity, false, report, "l")
	end
end

-- The landing speed in m/s of real gravity: Source falls faster (600 units/s² by default).
function M:_LandingSpeed(speed)
	if gravity == nil then
		gravity = GetConVar("sv_gravity") or false
	end
	local g = gravity and gravity:GetFloat() or 600
	if g <= 0 then
		g = 600
	end
	return speed * 0.0254 * sqrt(9.81 / (g * 0.0254))
end

local function fall(self, st, hit, report)
	local v = self:_LandingSpeed(hit.speed or 0)
	report.speed = v
	if v < 6.5 then
		return
	end
	local R = M.Random
	report.energy = report.energy + 40 * (v * v - 42)
	for _, side in ipairs(SIDES) do
		if R() < clamp((v - 6.5) / 4, 0, 0.9) then
			breakBone(self, st, hit, "foot_bones_" .. side, 1, report)
		end
		if R() < clamp((v - 8) / 5, 0, 0.9) then
			breakBone(self, st, hit, "tibia_" .. side, v > 12 and 2 or 1, report)
		end
		if R() < clamp((v - 9.5) / 6, 0, 0.9) then
			breakBone(self, st, hit, "femur_" .. side, 1, report)
		end
	end
	if R() < clamp((v - 9) / 6, 0, 0.9) then
		breakBone(self, st, hit, "pelvis", v > 13 and 2 or 1, report)
	end
	if R() < clamp((v - 10) / 7, 0, 0.9) then
		report.height = 8
		breakBone(self, st, hit, "spine", 1, report)
	end
	local byId = self.body.byId
	if R() < clamp((v - 11) / 6, 0, 0.9) then
		for _, id in ipairs({ "liver", "spleen", "kidney_l", "kidney_r" }) do
			local s = byId[id]
			if s ~= nil and R() < 0.5 then
				self:_HitOrgan(st, hit, s, clamp(0.15 + (v - 11) * 0.08, 0.15, 0.9), report, true)
			end
		end
	end
	if R() < clamp((v - 14) / 6, 0, 0.9) and byId.aorta ~= nil then
		self:_AddWound(st, hit, byId.aorta, "chest_l", 900, 0.2, nil, report) -- the aorta tears off
	end
	if R() < clamp((v - 12) / 5, 0, 0.9) then
		st.concussion = max(st.concussion, clamp((v - 10) / 8, 0, 1))
		self:_Knockout(st, 10 + 3 * (v - 12))
		local brain = byId.brain
		if brain ~= nil then
			self:_HitOrgan(st, hit, brain, clamp((v - 13) / 8, 0, 1) * R(), report, true)
		end
		if v > 14 then
			breakBone(self, st, hit, "skull", 1, report)
		end
	end
	if v >= 17 and R() < clamp((v - 15) / 6, 0, 1) then
		report.fatal = "fall"
	end
	local bruise = self:_AddWound(st, hit, nil, "tissue", 5, min(0.6, 0.15 + 0.06 * (v - 6.5)), "legs", report)
	bruise.limit = 100
end

-- Explosions -------------------------------------------------------------------------------

local function blast(self, st, hit, report)
	local amount = hit.amount or 50
	if amount >= 250 then
		report.fatal = "blast"
		return
	end
	local intensity = amount / 100
	local R = M.Random
	local body = self.body
	-- The pressure wave tears the lungs and shakes the brain.
	for _, side in ipairs(SIDES) do
		local lung = body.byId["lung_" .. side]
		if lung ~= nil then
			self:_HitOrgan(st, hit, lung, 0.25 * intensity, report, true)
			self:_AddWound(st, hit, lung, lung.cavity, 20 * intensity, 0.05, nil, report)
		end
	end
	st.concussion = max(st.concussion, min(1, 0.6 * intensity))
	if R() < intensity - 0.2 then
		self:_Knockout(st, 5 + 20 * min(1, intensity))
	end
	-- Fragments fly from the blast at random parts of the body; armor (hit.shield) meets
	-- each one first and may change it.
	local shield = hit.shield
	local _, _, _, dx, dy, dz = ray(st, hit)
	local soft = body.soft
	local count = hit.fragments or floor(intensity * 5 + R())
	if count > 0 and #soft > 0 then
		self:_Frames(body, st.ply)
		for _ = 1, count do
			local s = soft[floor(R() * #soft) + 1]
			local w = s.shapes[1].world
			local f = R()
			local tx, ty, tz = w[1] + (w[4] - w[1]) * f, w[2] + (w[5] - w[2]) * f, w[3] + (w[6] - w[3]) * f
			local jx, jy, jz = dx + (R() - 0.5) * 0.4, dy + (R() - 0.5) * 0.4, dz + (R() - 0.5) * 0.4
			local length = sqrt(jx * jx + jy * jy + jz * jz)
			if length > 1e-6 then
				jx, jy, jz = jx / length, jy / length, jz / length
				local fragment = { kind = "fragment", attacker = hit.attacker, inflictor = hit.inflictor,
					type = hit.type, pos = Vector(tx - jx * 4, ty - jy * 4, tz - jz * 4), dir = Vector(jx, jy, jz),
					projectile = copy(M.FRAGMENT) }
				if shield == nil or shield(st.ply, fragment) ~= false then
					local injure = self.INJURIES[fragment.kind] or bullet
					injure(self, st, fragment, report)
				end
			end
		end
	end
	-- The body is thrown, the skin is scorched.
	local torso = body.bySeg.torso
	if torso ~= nil then
		local x, y, z = self:_SegmentCenter(st.ply, torso)
		self:_Blunt(st, hit, 40 * intensity, report, torso, x, y, z)
	end
	st.burns = min(1, st.burns + 0.03 * intensity)
	report.energy = report.energy + amount * 5
end

-- Other kinds ------------------------------------------------------------------------------

local function burn(self, st, hit, report)
	local amount = hit.amount or 5
	st.burns = min(1, st.burns + amount * 0.004) -- share of the body surface
	if st.burns >= 0.95 then
		report.fatal = "burns"
	end
	report.energy = report.energy + amount * 5
end

local function shock(self, st, hit, report)
	local amount = hit.amount or 10
	if amount >= 15 then
		self:_Knockout(st, 2 + min(10, amount / 20))
	end
	if M.Random() < clamp((amount - 30) / 150, 0, 0.6) then
		self:_Arrest(st, "vf", CurTime())
	end
	st.burns = min(1, st.burns + amount * 0.001)
	local w = self:_AddWound(st, hit, nil, "tissue", 1, min(0.5, 0.1 + amount / 100), "torso", report)
	w.limit = 5
	report.energy = report.energy + amount * 5
end

local function stun(self, st, hit, report)
	if M.Random() < 0.6 then
		self:_Knockout(st, 3 + 3 * M.Random())
	end
	bluntAt(self, st, hit, report, (hit.amount or 10) * 3)
end

local function poison(self, st, hit, report)
	local amount = hit.amount or 10
	st.toxin = st.toxin + amount / 100 * (hit.toxin or 1)
	report.energy = report.energy + amount * 5
end

local function generic(self, st, hit, report)
	local amount = hit.amount or 0
	if amount <= 0 then
		return
	end
	st.trauma = st.trauma + amount
	if amount >= 100 or st.trauma >= 250 then
		report.fatal = "trauma"
		return
	end
	local w = self:_AddWound(st, hit, nil, "tissue", amount * 2, min(0.6, amount / 100), "torso", report)
	w.limit = amount * 15
	report.energy = report.energy + amount * 10
end

local function lethal(self, st, hit, report)
	report.fatal = hit.cause or "trauma"
end

M.INJURIES.bullet = bullet
M.INJURIES.fragment = bullet
M.INJURIES.stab = blade
M.INJURIES.slash = blade
M.INJURIES.blunt = blunt
M.INJURIES.crush = crush
M.INJURIES.vehicle = vehicle
M.INJURIES.fall = fall
M.INJURIES.blast = blast
M.INJURIES.burn = burn
M.INJURIES.shock = shock
M.INJURIES.stun = stun
M.INJURIES.poison = poison
M.INJURIES.generic = generic
M.INJURIES.lethal = lethal
