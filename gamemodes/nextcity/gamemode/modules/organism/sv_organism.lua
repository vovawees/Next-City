-- Organism, server part: the bodies of the players, the simulation schedule, the outputs,
-- death, the API and the console.
--
-- Every alive player has a body. The bodies advance round-robin, config.rate times a
-- second each, spread over the ticks; injuries and treatments act at once. When the body
-- dies the player is killed on behalf of whoever caused most of the injuries (players:Kill).
-- Another entity may carry the body for a while (SetCarrier: the ragdoll of a fallen
-- player): the bones of hits and the water of breathing are then read from it.
--
-- Listens:  players.spawned (a new body), players.died (killed by something else),
--           players.left, players.stateChanged (no body outside the game), gm.KeyPress
--           (a jump costs stamina), net succumb.
-- Emits:    organism.wounded (ply, hit, report)     after an injury
--           organism.treated (ply, kind, opts)      after a treatment
--           organism.unconscious (ply, unconscious) consciousness lost or regained
--           organism.capabilities (ply, caps)       what the body can do changed
--           organism.died (ply, cause, killer)      the body died; the kill follows
-- Asks:     organism.canSuccumb (ply) -> false keeps an unconscious player from giving up.
-- Commands: nc_organism [player], nc_hurt <player> <kind> [part] [amount],
--           nc_heal [player], nc_treat <player> <kind> [limb | side | region | amount].

local M = NC.Module("organism")

local min = math.min
local floor = math.floor
local sqrt = math.sqrt
local format = string.format
local concat = table.concat
local sort = table.sort
local CurTime = CurTime
local IsValid = IsValid

-- Values of the vitals rounded like the network rounds them, so a change too small to
-- send does not make the component dirty.
local function quantizer(lo, hi, bits)
	local steps = 2 ^ bits - 1
	local scale, step = steps / (hi - lo), (hi - lo) / steps
	return function(v)
		if v ~= v or v <= lo then
			return lo
		end
		if v >= hi then
			return hi
		end
		local value = lo + floor((v - lo) * scale + 0.5) * step
		return value > hi and hi or value
	end
end

local Q_SHARE = quantizer(0, 1, 7)
local Q_UNIT = quantizer(0, 1, 6)
local Q_BLEEDING = quantizer(0, 2000, 8)
local Q_TEMPERATURE = quantizer(25, 42, 8)
local Q_RECOIL = quantizer(1, 3, 6)

local out = {} -- the vitals being written

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.body = self:CompileBody(M.BODY)
	self:_IndexBody()
	self.states = {} -- ply -> state of the body
	self.list = {}   -- states being simulated
	self.cursor = 0
	self.budget = 0
	self.steps, self.stepOrder = {}, {}
	for id, fn in pairs(M.STEPS) do
		self.steps[id] = fn
	end
	for i, id in ipairs(M.STEP_ORDER) do
		self.stepOrder[i] = id
	end
	self:_BuildSteps()
	ctx.net:Receive("succumb", "OnSuccumb")
	ctx.commands:Add("nc_organism", { help = "the body of a player: vitals, wounds, fractures, capabilities" },
		"OrganismCommand")
	ctx.commands:Add("nc_hurt", { help = "hurts a player: <player> <kind> [part] [amount]" }, "HurtCommand")
	ctx.commands:Add("nc_heal", { help = "gives a player a healthy body: [player]" }, "HealCommand")
	ctx.commands:Add("nc_treat", { help = "treats a player: <player> <kind> [limb | side | region | amount]" },
		"TreatCommand")
end

function M:Start(ctx)
	ctx:Every("simulate", 0, "SimTick")
	ctx:On("players.spawned", "OnSpawned")
	ctx:On("players.died", "OnDied")
	ctx:On("players.left", "OnLeft")
	ctx:On("players.stateChanged", "OnStateChanged")
	ctx:On("gm.KeyPress", "OnKeyPress")
	for _, ply in ipairs(self.players:List("alive")) do
		if self.states[ply] == nil then
			self:_Track(ply)
		end
	end
end

-- Bodies -----------------------------------------------------------------------------------

function M:_List(st)
	local list = self.list
	list[#list + 1] = st
	st.slot = #list
end

function M:_Unlist(st)
	local slot = st.slot
	if slot == nil then
		return
	end
	local list = self.list
	local last = list[#list]
	list[slot] = last
	last.slot = slot
	list[#list] = nil
	st.slot = nil
end

-- Gives `ply` a new healthy body (replacing the old one). Returns the state.
function M:_Track(ply)
	local old = self.states[ply]
	if old ~= nil then
		self:_Unlist(old)
	end
	local now = CurTime()
	local st = self:_NewState(ply, now)
	if old ~= nil and not old.dead then
		st.sentUnconscious, st.sentCaps, st.sentSpeed = old.sentUnconscious, old.sentCaps, old.sentSpeed
	end
	self.states[ply] = st
	self:_List(st)
	self:_Output(st, now)
	return st
end

-- Drops the body of `ply` and its vitals.
function M:_Forget(ply)
	local st = self.states[ply]
	if st == nil then
		return
	end
	self:_Unlist(st)
	self.states[ply] = nil
	if IsValid(ply) then
		self.ctx.components.vitals:Remove(ply)
	end
end

-- Advances the bodies due this tick: config.rate steps per body and second in total.
function M:SimTick(now, dt)
	local list = self.list
	local n = #list
	if n == 0 then
		self.budget = 0
		return
	end
	local budget = self.budget + n * self.ctx.config.rate * dt
	if budget > n then
		budget = n
	end
	local cursor = self.cursor
	while budget >= 1 and #list > 0 do
		budget = budget - 1
		cursor = cursor + 1
		if cursor > #list then
			cursor = 1
		end
		local st = list[cursor]
		if IsValid(st.ply) then
			self:_Simulate(st, now)
		else
			self:_Forget(st.ply)
		end
		if list[cursor] ~= st then
			cursor = cursor - 1 -- the body left the list: another one took its place
		end
	end
	self.cursor = cursor
	self.budget = budget
end

-- Outputs ----------------------------------------------------------------------------------

-- Derives the capabilities and writes the vitals; tells about changes.
function M:_Output(st, now)
	self:_Capabilities(st, now)
	local ply = st.ply
	local caps = st.caps
	local alive = not st.dead
	out.blood = Q_SHARE(st.blood / st.volume)
	out.bleeding = Q_BLEEDING(st.external)
	out.pulse = alive and floor(min(255, st.hr) + 0.5) or 0
	out.spo2 = alive and floor(min(1, st.spo2) * 100 + 0.5) or 0
	out.pain = Q_UNIT(st.pain)
	out.stamina = Q_UNIT(st.stamina)
	out.consciousness = alive and Q_UNIT(st.consciousness) or 0
	out.temperature = Q_TEMPERATURE(st.temperature)
	out.speed = Q_UNIT(caps.moveSpeedMul)
	out.sway = Q_UNIT(caps.aimSway)
	out.recoil = Q_RECOIL(caps.recoilMul)
	out.blur = Q_UNIT(caps.visionBlur)
	out.dark = Q_UNIT(st.dark)
	out.grey = Q_UNIT(st.grey)
	out.caps = st.capsBits
	out.status = st.statusBits
	out.since = (alive and st.unconscious) and st.unconsciousAt or 0
	-- The server reads the same values as the client of the player.
	caps.moveSpeedMul, caps.aimSway, caps.recoilMul, caps.visionBlur = out.speed, out.sway, out.recoil, out.blur
	local vitals = self.ctx.components.vitals
	if vitals:Has(ply) then
		vitals:Patch(ply, out)
	else
		vitals:Add(ply, out)
	end
	local events = self.ctx.events
	local unconscious = caps.unconscious
	if alive and unconscious ~= st.sentUnconscious then
		st.sentUnconscious = unconscious
		events:Emit("organism.unconscious", ply, unconscious)
	end
	if st.capsBits ~= st.sentCaps or out.speed ~= st.sentSpeed then
		st.sentCaps, st.sentSpeed = st.capsBits, out.speed
		events:Emit("organism.capabilities", ply, caps)
	end
end

-- Death ------------------------------------------------------------------------------------

-- The body dies of `cause`; the player is killed on behalf of the killer right after.
function M:_Die(st, cause)
	if st.dead then
		return
	end
	st.dead = true
	st.cause = cause
	self:_Unlist(st)
	local ply = st.ply
	self:_Output(st, CurTime())
	local killer, inflictor, damageType = self:_Killer(st)
	self.ctx.events:Emit("organism.died", ply, cause, killer)
	-- Not inside the damage hook that may have caused it.
	self.ctx:After(0, function()
		if self.states[ply] == st and IsValid(ply) and ply:Alive() then
			self.players:Kill(ply, { attacker = killer, inflictor = inflictor, damageType = damageType,
				force = st.lastForce, position = st.lastPos })
		end
	end)
end

-- An unconscious player gives up: dies of the injuries now. Allowed after
-- config.succumbDelay seconds without consciousness unless organism.canSuccumb says no.
-- Returns true if the body died.
function M:Succumb(ply)
	local st = self.states[ply]
	if st == nil or st.dead or not st.unconscious then
		return false
	end
	local delay = self.ctx.config.succumbDelay
	if delay < 0 or CurTime() - st.unconsciousAt < delay then
		return false
	end
	if self.ctx.events:Query("organism.canSuccumb", ply) == false then
		return false
	end
	self:_Die(st, "succumb")
	return true
end

function M:OnSuccumb(_, ply)
	self:Succumb(ply)
end

-- Events -----------------------------------------------------------------------------------

function M:OnSpawned(ply)
	self:_Track(ply)
end

-- Killed by something else than the body (a command, a map, a mode): the body is dead.
function M:OnDied(ply)
	local st = self.states[ply]
	if st == nil or st.dead then
		return
	end
	st.dead = true
	st.cause = "killed"
	self:_Unlist(st)
	self:_Output(st, CurTime())
end

function M:OnLeft(ply)
	self:_Forget(ply)
end

function M:OnStateChanged(ply, state)
	if state == "spectator" or state == "connecting" then
		self:_Forget(ply)
	end
end

function M:OnKeyPress(ply, key)
	if key ~= IN_JUMP then
		return
	end
	local st = self.states[ply]
	if st ~= nil and not st.dead and ply:OnGround() then
		st.stamina = st.stamina > 0.05 and st.stamina - 0.05 or 0
	end
end

-- API --------------------------------------------------------------------------------------

-- Whether `ply` has a body (alive or dead) that the organism simulates or simulated.
function M:IsSimulated(ply)
	return self.states[ply] ~= nil
end

function M:IsDead(ply)
	local st = self.states[ply]
	return st ~= nil and st.dead
end

function M:IsUnconscious(ply)
	local st = self.states[ply]
	return st ~= nil and not st.dead and st.unconscious
end

-- What the body can do (see sh_organism.lua), or nil without a body. Do not modify.
function M:Capabilities(ply)
	local st = self.states[ply]
	return st and st.caps
end

-- The vitals of `ply` (the replicated component), or nil. Do not modify.
function M:Vitals(ply)
	return self.ctx.components.vitals:Get(ply)
end

-- The entity that carries the body of `ply` instead of the player (the ragdoll of a
-- fallen player), or nil.
function M:Carrier(ply)
	local st = self.states[ply]
	local carrier = st and st.carrier
	if carrier ~= nil and IsValid(carrier) then
		return carrier
	end
	return nil
end

-- Makes `ent` carry the body of `ply` (nil: the player again). A new body (every spawn)
-- has no carrier. Returns false if `ply` has no body.
function M:SetCarrier(ply, ent)
	assert(ent == nil or IsValid(ent), "organism: SetCarrier(ply, ent): ent must be a valid entity or nil")
	local st = self.states[ply]
	if st == nil then
		return false
	end
	st.carrier = ent
	return true
end

-- The entity whose bones hold the body of `ply`: its carrier or the player.
function M:BodyEntity(ply)
	return self:Carrier(ply) or ply
end

-- The inner state of the body, for tools and tests. Do not modify outside the organism.
function M:State(ply)
	return self.states[ply]
end

-- Wounds of the body (do not modify), or nil.
function M:Wounds(ply)
	local st = self.states[ply]
	return st and st.wounds
end

-- Console ----------------------------------------------------------------------------------

local LIMB_NAMES = { arm_l = true, arm_r = true, leg_l = true, leg_r = true }

-- Parts of the body for nc_hurt: a name or a structure id.
local PARTS = {
	head = "brain", face = "face", neck = "neck_soft", chest = "lung_r", heart = "heart", abdomen = "stomach",
	liver = "liver", pelvis = "bladder", back = "spine", arm_l = "upperarm_soft_l", arm_r = "upperarm_soft_r",
	leg_l = "thigh_soft_l", leg_r = "thigh_soft_r",
}

local function findPlayer(self, text, caller)
	local ply, problem = self.players:Find(text, caller)
	if ply == nil then
		return nil, problem
	end
	if self.states[ply] == nil then
		return nil, ply:Nick() .. " has no body (not in the game)"
	end
	return ply
end

local function percent(value)
	return floor(value * 100 + 0.5)
end

local function capsLine(caps)
	local parts = {}
	for _, name in ipairs({ "canStand", "canJump", "canSprint", "canUseArmL", "canUseArmR" }) do
		if caps[name] then
			parts[#parts + 1] = name:sub(4)
		end
	end
	return format("caps: %s; speed %.2f, sway %.2f, recoil %.2f, blur %.2f", #parts > 0 and concat(parts, " ") or "-",
		caps.moveSpeedMul, caps.aimSway, caps.recoilMul, caps.visionBlur)
end

local function statusLine(bits)
	local parts = {}
	for _, name in ipairs(M.STATUS_ORDER) do
		if bit.band(bits, M.STATUS[name]) ~= 0 then
			parts[#parts + 1] = name
		end
	end
	return "status: " .. (#parts > 0 and concat(parts, " ") or "-")
end

-- Lines that describe a body.
function M:Describe(ply)
	local st = self.states[ply]
	if st == nil then
		return { ply:Nick() .. ": no body" }
	end
	local lines = {}
	lines[1] = format("%s: %s%s; consciousness %.2f, pain %.2f, shock %.2f, stamina %.2f, %.1f C", ply:Nick(),
		st.dead and "dead (" .. tostring(st.cause) .. ")" or "alive",
		(st.unconscious and not st.dead) and ", unconscious" or "",
		st.consciousness, st.pain, st.shock, st.stamina, st.temperature)
	lines[2] = format("  blood %d/%d ml (%d%%), bleeding %d ml/min outside, %d inside; hb %.2f, clotting %.2f",
		st.blood, st.volume, percent(st.blood / st.volume), st.external, st.internal, st.hb, st.coag)
	lines[3] = format("  heart %s %d/min, MAP %d; breathing %d/min, SpO2 %d%%, ventilation %.2f; brain %.2f, ICP %d",
		st.rhythm, st.hr, st.map, st.rr, percent(st.spo2), st.ventilation, st.brain, st.icp)
	local cavity = st.cavity
	lines[4] = format("  chest L %d ml (air %.2f%s), R %d ml (air %.2f%s), pericardium %d, abdomen %d, skull %d,"
		.. " airway %d", cavity.chest_l, st.pneumo.l, st.tension.l > 0 and format(", tension %.2f", st.tension.l) or "",
		cavity.chest_r, st.pneumo.r, st.tension.r > 0 and format(", tension %.2f", st.tension.r) or "",
		cavity.pericardium, cavity.abdomen, cavity.skull, cavity.airway)
	local wounds = {}
	for i, w in ipairs(st.wounds) do
		wounds[i] = w
	end
	sort(wounds, function(a, b) return a.flow > b.flow end)
	lines[#lines + 1] = format("  wounds %d:", #wounds)
	for i = 1, min(8, #wounds) do
		local w = wounds[i]
		lines[#lines + 1] = format("    %s %s (%s) -> %s: %.0f ml/min of %.0f, clot %.2f/%.2f%s%s%s", w.kind,
			w.region, tostring(w.structure), w.cavity, w.flow, w.base, w.clot, w.clotMax,
			w.bandage > 0 and format(", bandage %.2f", w.bandage) or "", w.arterial and ", arterial" or "",
			w.junctional and ", junctional" or "")
	end
	local fractures = {}
	for _, f in ipairs(st.fractureList) do
		fractures[#fractures + 1] = format("%s%s%s%s", f.id, f.severity >= 2 and " (comminuted)" or "",
			f.open and " open" or "", f.splint and " splinted" or "")
	end
	for limb in pairs(st.dislocated) do
		fractures[#fractures + 1] = limb .. " dislocated"
	end
	lines[#lines + 1] = "  bones: " .. (#fractures > 0 and concat(fractures, ", ") or "-")
		.. (st.cord > 0 and format("; spinal cord level %d", st.cord) or "")
	local tourniquets = {}
	for limb in pairs(st.tourniquets) do
		tourniquets[#tourniquets + 1] = limb
	end
	sort(tourniquets)
	local level = st.level
	lines[#lines + 1] = format("  tourniquets: %s; morphine %.2f, naloxone %.2f, epinephrine %.2f, txa %.2f",
		#tourniquets > 0 and concat(tourniquets, " ") or "-", level.morphine, level.naloxone, level.epinephrine,
		level.txa)
	lines[#lines + 1] = "  " .. capsLine(st.caps)
	lines[#lines + 1] = "  " .. statusLine(st.statusBits)
	return lines
end

function M:OrganismCommand(caller, args)
	local ply, problem = findPlayer(self, args[1], caller)
	if ply == nil then
		return "nc_organism: " .. problem
	end
	return self:Describe(ply)
end

-- A point in front of structure `s` and the direction into it (frames of `ply`).
function M:_AimAt(ply, s)
	self:_Frames(self.body, ply)
	local w = s.shapes[1].world
	local cx, cy, cz = (w[1] + w[4]) * 0.5, (w[2] + w[5]) * 0.5, (w[3] + w[6]) * 0.5
	local f = s.segment.frame
	local fx, fy, fz = f[4], f[5], f[6]
	local length = sqrt(fx * fx + fy * fy + fz * fz)
	fx, fy, fz = fx / length, fy / length, fz / length
	return Vector(cx + fx * 12, cy + fy * 12, cz + fz * 12), Vector(-fx, -fy, -fz)
end

function M:HurtCommand(caller, args)
	local ply, problem = findPlayer(self, args[1], caller)
	if ply == nil then
		return "nc_hurt: " .. problem
	end
	local kind = args[2] or "bullet"
	if self.INJURIES[kind] == nil then
		local kinds = {}
		for name in pairs(self.INJURIES) do
			kinds[#kinds + 1] = name
		end
		sort(kinds)
		return "nc_hurt: unknown kind '" .. kind .. "', known: " .. concat(kinds, ", ")
	end
	local hit = { kind = kind, attacker = IsValid(caller) and caller or nil }
	local part, amount = args[3], tonumber(args[4] or "")
	if tonumber(part or "") ~= nil then
		part, amount = nil, tonumber(part)
	end
	if part ~= nil then
		local s = self.body.byId[PARTS[part] or part]
		if s == nil then
			local names = {}
			for name in pairs(PARTS) do
				names[#names + 1] = name
			end
			sort(names)
			return "nc_hurt: unknown part '" .. part .. "': " .. concat(names, ", ") .. " or a structure id"
		end
		hit.pos, hit.dir = self:_AimAt(ply, s)
		hit.segment = s.seg
	end
	if kind == "fall" then
		hit.speed = amount or 900
	else
		hit.amount = amount or 50
	end
	local report = self:Injure(ply, hit)
	if report == nil then
		return "nc_hurt: " .. ply:Nick() .. " has no living body"
	end
	return format("nc_hurt: %s %s: %d wounds, +%d ml/min, %d fractures, %d J%s; %s", kind, ply:Nick(), report.wounds,
		report.bleeding, report.fractures, report.energy, report.fatal and ", fatal (" .. report.fatal .. ")" or "",
		#report.structures > 0 and concat(report.structures, " ") or "no structures")
end

function M:HealCommand(caller, args)
	local ply, problem = findPlayer(self, args[1], caller)
	if ply == nil then
		return "nc_heal: " .. problem
	end
	local ok, reason = self:ApplyTreatment(ply, "heal")
	return ok and "nc_heal: " .. ply:Nick() .. " is healthy" or "nc_heal: " .. reason
end

function M:TreatCommand(caller, args)
	local ply, problem = findPlayer(self, args[1], caller)
	if ply == nil then
		return "nc_treat: " .. problem
	end
	local kind = args[2]
	if kind == nil or self.TREATMENTS[kind] == nil then
		local kinds = {}
		for name in pairs(self.TREATMENTS) do
			kinds[#kinds + 1] = name
		end
		sort(kinds)
		return "nc_treat: kinds: " .. concat(kinds, ", ")
	end
	local target = args[3]
	local opts = {}
	if target ~= nil then
		local number = tonumber(target)
		if number ~= nil then
			opts.dose, opts.ml = number, number
		elseif LIMB_NAMES[target] then
			opts.limb = target
		elseif target == "l" or target == "r" then
			opts.side = target
		else
			opts.region = target
		end
	end
	local ok, reason = self:ApplyTreatment(ply, kind, opts)
	return ok and format("nc_treat: %s %s: done", kind, ply:Nick()) or format("nc_treat: %s %s: %s", kind,
		ply:Nick(), reason)
end
