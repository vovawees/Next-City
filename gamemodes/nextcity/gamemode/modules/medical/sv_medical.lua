-- Medical, server part: treating, examining and the reports.
--
--   medical:UseItem(ply, patient, item)        treat a patient (or oneself) with an item of his;
--                                              an action of the time of the item, then
--                                              organism:ApplyTreatment and the item is used up
--   medical:UseHands(ply, patient, id, part)   a treatment of M.HANDS (cpr, ventilate, reduce,
--                                              tourniquet_off); part: a limb
--   medical:Examine(ply, patient)              examine (an action), then send the report
--   medical:Report(ply, patient)               findings and options: what the report shows
--   medical:Aimed(ply)                         the patient in front of the eyes and his body
--                                              (a player or the ragdoll that carries him)
-- Every one returns true, or false and a reason; the player is told the reason
-- (medical.fail.<reason>). The patient of the last report stays chosen for config.reportTime
-- s: the buttons of the report and the verb treat go to him.
--
-- Listens: gm.ShowSpare1 (F3: examine the one in front or oneself), players.left, net
--          treat and examine.
-- Emits:   medical.treated (ply, patient, kind, itemId | nil), medical.examined (ply, patient).
-- Asks:    medical.canTreat (ply, patient, kind, itemId | nil) -> false forbids a treatment.
-- Commands: nc_examine (anyone: examine the one in front or oneself).

local M = NC.Module("medical")

local IsValid = IsValid
local CurTime = CurTime
local ipairs = ipairs
local pairs = pairs
local floor = math.floor
local min = math.min
local max = math.max

local LIMB = { arm_l = true, arm_r = true, leg_l = true, leg_r = true }

function M:Init(ctx)
	self:_InitShared(ctx)
	self.players = ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.actions = ctx:Require("actions")
	self.notices = ctx:Require("notices")
	self.reports = {} -- ply -> { patient, at }
	local inventory = self.inventory
	inventory:HandleVerb("use", function(ply, item)
		return self:_Tell(ply, self:UseItem(ply, ply, item))
	end)
	inventory:HandleVerb("treat", function(ply, item)
		local patient = self:PatientOf(ply, true)
		if patient == nil then
			return self:_Tell(ply, false, "patient")
		end
		return self:_Tell(ply, self:UseItem(ply, patient, item))
	end)
end

function M:Start(ctx)
	ctx:On("gm.ShowSpare1", "ExamineAimed")
	ctx:On("players.left", "OnLeft")
	ctx.net:Receive("treat", "OnTreat")
	ctx.net:Receive("examine", function(_, ply)
		self:ExamineAimed(ply)
	end)
	ctx.commands:Add("nc_examine", { help = "examine the one in front of you (or yourself)", admin = false },
		function(ply)
			if IsValid(ply) then
				self:ExamineAimed(ply)
			end
			return nil
		end)
end

function M:OnLeft(ply)
	self.reports[ply] = nil
	for other, report in pairs(self.reports) do
		if report.patient == ply then
			self.reports[other] = nil
		end
	end
end

-- Tells a player why he could not (a notice) and passes the answer on.
function M:_Tell(ply, ok, reason)
	if not ok and reason ~= nil then
		self:Fail(ply, reason)
	end
	return ok == true
end

function M:Fail(ply, reason)
	local key = "medical.fail." .. tostring(reason)
	if not self.ctx.i18n:Has(key) then
		key = "medical.fail.other"
	end
	if IsValid(ply) then
		self.notices:Send(ply, key, nil, "warn")
	end
end

-- Patients ------------------------------------------------------------------------------

-- The patient in front of the eyes of `ply` (a living or dead body) and the entity of his
-- body, or nil.
function M:Aimed(ply)
	local eye = ply:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * self.ctx.config.reach,
		filter = ply, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	if ent == nil or not IsValid(ent) then
		return nil
	end
	local organism = self.organism
	local patient = ent:IsPlayer() and ent or organism:PlayerOf(ent)
	if patient == nil or not organism:IsSimulated(patient) or organism:BodyEntity(patient) ~= ent then
		return nil
	end
	return patient, ent
end

-- The patient a player treats: the one in front, else the patient of his last report
-- while it is fresh, else himself (nil with `others`: nobody else).
function M:PatientOf(ply, others)
	local patient = self:Aimed(ply)
	if patient ~= nil then
		return patient
	end
	local report = self.reports[ply]
	if report ~= nil and CurTime() - report.at <= self.ctx.config.reportTime and IsValid(report.patient)
		and (report.patient ~= ply or not others) and self:_Reaches(ply, report.patient) then
		return report.patient
	end
	if others then
		return nil
	end
	return ply
end

local function center(ent)
	return ent.WorldSpaceCenter ~= nil and ent:WorldSpaceCenter() or ent:GetPos()
end

function M:_Reaches(ply, patient)
	if patient == ply then
		return true
	end
	local body = self.organism:BodyEntity(patient)
	return IsValid(body) and center(body):Distance(ply:GetShootPos()) <= self.ctx.config.reach + 24
end

-- Why `patient` cannot be treated by `ply` now, or nil.
function M:_PatientProblem(ply, patient)
	if not IsValid(patient) or not self.organism:IsSimulated(patient) or self.organism:IsDead(patient) then
		return "dead"
	end
	if not self:_Reaches(ply, patient) then
		return "reach"
	end
	return nil
end

-- The share of the time of a treatment by `ply`: his arms (nil: he has none to work with).
function M:_Hands(ply)
	local caps = self.organism:Capabilities(ply)
	if caps == nil then
		return nil
	end
	local arms = (caps.canUseArmL and 1 or 0) + (caps.canUseArmR and 1 or 0)
	if arms == 0 then
		return nil
	end
	return arms == 1 and self.ctx.config.oneArm or 1
end

-- Treatments -------------------------------------------------------------------------------

-- Whether `ply` may treat `patient` with treatment `kind` (opts) now: true, or false and the
-- reason. itemId: the item it takes (nil: the hands).
function M:CanTreat(ply, patient, kind, opts, itemId)
	local problem = self:_PatientProblem(ply, patient)
	if problem ~= nil then
		return false, problem
	end
	if self.ctx.events:Query("medical.canTreat", ply, patient, kind, itemId) == false then
		return false, "denied"
	end
	return self.organism:CanTreat(patient, kind, opts)
end

-- The item stays with the player and the patient keeps the body the action began on.
function M:_Checker(ply, patient, body, item)
	local organism, inventory = self.organism, self.inventory
	return function()
		if item ~= nil and (item.container == nil or inventory:Where(ply, item.container) ~= "own") then
			return false, "item"
		end
		if not organism:IsSimulated(patient) or organism:IsDead(patient) then
			return false, "patient"
		end
		if patient ~= ply and organism:BodyEntity(patient) ~= body then
			return false, "target"
		end
		return true
	end
end

-- Starts the action of a treatment: spec = { id, kind, opts, time, label, item, Tick, Done }.
function M:_Begin(ply, patient, spec)
	local factor = self:_Hands(ply)
	if factor == nil then
		return false, "arms"
	end
	local body = patient ~= ply and self.organism:BodyEntity(patient) or nil
	local ok, reason = self.actions:Begin(ply, {
		id = spec.id,
		label = spec.label,
		duration = spec.time * factor,
		target = body,
		range = self.ctx.config.reach + 24,
		Check = self:_Checker(ply, patient, body, spec.item),
		Tick = spec.Tick,
		OnComplete = function()
			spec.Done()
		end,
	})
	if not ok then
		return false, reason
	end
	return true
end

-- Treats `patient` (or `ply` himself) with `item` of his (see the top of the file).
function M:UseItem(ply, patient, item)
	local trait = item ~= nil and self:Trait(item.id) or nil
	if trait == nil then
		return false, "nothing"
	end
	if item.container == nil or self.inventory:Where(ply, item.container) ~= "own" then
		return false, "item"
	end
	local own = patient == ply
	if own and trait.self == false then
		return false, "self"
	end
	if not own and trait.others == false then
		return false, "others"
	end
	local kind, opts = trait.treatment, trait.opts or {}
	local ok, reason = self:CanTreat(ply, patient, kind, opts, item.id)
	if not ok then
		return false, reason
	end
	local id = item.id
	return self:_Begin(ply, patient, {
		id = "medical",
		label = trait.label or ("medical.action." .. kind),
		time = (own and trait.time or trait.othersTime or trait.time) or 3,
		item = item,
		Done = function()
			local done, why = self:CanTreat(ply, patient, kind, opts, id)
			if done then
				done, why = self.organism:ApplyTreatment(patient, kind, opts)
			end
			if not done then
				self:Fail(ply, why)
				return
			end
			self:_Consume(ply, item, trait)
			self:_Treated(ply, patient, kind, id)
		end,
	})
end

-- Uses one treatment of an item up: one of the stack, or one charge of it.
function M:_Consume(ply, item, trait)
	local uses = trait.uses or 1
	local inventory = self.inventory
	if uses <= 0 or item.container == nil then
		return
	end
	if uses == 1 or (item.state.charge or uses) <= 1 then
		if item.count > 1 then
			inventory:SetCount(item, item.count - 1)
		else
			inventory:Destroy(item)
		end
		return
	end
	if item.state.charge == nil and item.count > 1 then
		-- A fresh one comes off the stack with a charge used.
		inventory:SetCount(item, item.count - 1)
		inventory:Give(ply, item.id, 1, { charge = uses - 1 }, { drop = true })
		return
	end
	item.state.charge = (item.state.charge or uses) - 1
	inventory:Touch(item)
end

function M:_Treated(ply, patient, kind, itemId)
	local what = itemId ~= nil and { key = self.inventory:Def(itemId).name } or { key = "medical.hands." .. kind }
	if patient == ply then
		self.notices:Send(ply, "medical.done.self", { what = what }, "good")
	else
		self.notices:Send(ply, "medical.done.other", { what = what, patient = self.players:Name(patient) }, "good")
		if not self.organism:IsUnconscious(patient) then
			self.notices:Send(patient, "medical.done.patient", { what = what, medic = self.players:Name(ply) }, "good")
		end
	end
	self.ctx.events:Emit("medical.treated", ply, patient, kind, itemId)
end

-- Treats `patient` with the hands (M.HANDS[id]); part: the limb.
function M:UseHands(ply, patient, id, part)
	local spec = M.HANDS[id]
	if spec == nil then
		return false, "nothing"
	end
	local own = patient == ply
	if own and spec.selfTime == nil then
		return false, "self"
	end
	if part ~= nil and not LIMB[part] then
		return false, "target"
	end
	local kind = spec.treatment
	local opts = { limb = spec.part and part or nil }
	local ok, reason = self:CanTreat(ply, patient, kind, opts)
	if not ok then
		return false, reason
	end
	if id == "ventilate" and (self.organism:Examine(patient).breathing or 0) > 0 then
		return false, "breathing"
	end
	local time = own and spec.selfTime or spec.time
	if id == "cpr" then
		time = self.ctx.config.cprTime
	end
	local organism = self.organism
	local tick
	if spec.every ~= nil then
		-- Compressions (and breaths) all along: a beating heart ends them early.
		local nextAt, breathAt = 0, 0
		tick = function(_, _, _, now)
			if now < nextAt then
				return false
			end
			nextAt = now + spec.every
			if id == "cpr" and now >= breathAt then
				breathAt = now + 6
				organism:ApplyTreatment(patient, "ventilate")
			end
			local done, why = organism:ApplyTreatment(patient, kind, opts)
			return not done and why == "pulse"
		end
	end
	return self:_Begin(ply, patient, {
		id = "medical",
		label = "medical.action." .. id,
		time = time,
		Tick = tick,
		Done = function()
			if spec.every ~= nil then
				local exam = organism:Examine(patient)
				if id == "cpr" and exam ~= nil and exam.pulse > 0 then
					self.notices:Send(ply, "medical.done.pulse", { patient = self.players:Name(patient) }, "good")
				elseif id == "cpr" then
					self.notices:Send(ply, "medical.done.nopulse", { patient = self.players:Name(patient) }, "warn")
				end
				self.ctx.events:Emit("medical.treated", ply, patient, kind, nil)
				return
			end
			local done, why = organism:ApplyTreatment(patient, kind, opts)
			if not done then
				self:Fail(ply, why)
				return
			end
			self:_Treated(ply, patient, id, nil)
		end,
	})
end

-- Examination -------------------------------------------------------------------------------

-- Examines the one in front of `ply`, or himself (F3, nc_examine).
function M:ExamineAimed(ply)
	if not IsValid(ply) or not self.players:IsAlive(ply) then
		return false
	end
	local patient = self:Aimed(ply) or ply
	return self:_Tell(ply, self:Examine(ply, patient))
end

-- Examines `patient` (an action), then sends the report.
function M:Examine(ply, patient)
	if not IsValid(patient) or not self.organism:IsSimulated(patient) then
		return false, "dead"
	end
	if not self:_Reaches(ply, patient) then
		return false, "reach"
	end
	local own = patient == ply
	local body = not own and self.organism:BodyEntity(patient) or nil
	local organism = self.organism
	local ok, reason = self.actions:Begin(ply, {
		id = "examine",
		label = own and "medical.action.examine_self" or "medical.action.examine",
		duration = self.ctx.config.examineTime * (own and 0.5 or 1),
		target = body,
		range = self.ctx.config.reach + 24,
		Check = function()
			if not organism:IsSimulated(patient) then
				return false, "target"
			end
			if not own and organism:BodyEntity(patient) ~= body then
				return false, "target"
			end
			return true
		end,
		OnComplete = function()
			self:SendReport(ply, patient)
			self.ctx.events:Emit("medical.examined", ply, patient)
		end,
	})
	if not ok then
		return false, reason
	end
	return true
end

-- What the items of `ply` measure: { spo2, pressure, rhythm, temperature }.
function M:Diagnostics(ply)
	local out = {}
	for _, item in ipairs(self.inventory:ItemsOf(ply)) do
		local trait = self.inventory:Trait(item.id, "diagnostic")
		if trait ~= nil then
			for name, on in pairs(trait) do
				if on then
					out[name] = true
				end
			end
		end
	end
	return out
end

local function round(value, step)
	return floor(value / step + 0.5) * step
end

-- The findings of an examination (organism:Examine) with the numbers of `diag`: a list of
-- { key, part, value, flag } (keys medical.find.<key>).
function M:Findings(exam, diag)
	local list = {}
	local function add(key, part, value, flag)
		if #list < 32 then
			list[#list + 1] = { key = key, part = part or "", value = max(0, min(65535, floor(value or 0))),
				flag = flag or "" }
		end
	end
	if exam.dead then
		add("dead")
		return list
	end
	if exam.unconscious then
		add("unconscious")
	elseif exam.consciousness < 0.7 then
		add("confused")
	else
		add("awake")
	end
	local pulse = exam.pulse
	if pulse <= 0 then
		add("pulse.none")
	elseif exam.map < 55 then
		add("pulse.weak", nil, round(pulse, 5))
	elseif pulse > 110 then
		add("pulse.fast", nil, round(pulse, 5))
	elseif pulse < 50 then
		add("pulse.slow", nil, round(pulse, 5))
	else
		add("pulse.normal", nil, round(pulse, 5))
	end
	local rr = exam.breathing
	if rr <= 0 then
		add("breath.none")
	elseif pulse <= 0 then
		add("breath.agonal")
	elseif rr > 24 then
		add("breath.fast", nil, rr)
	elseif rr < 9 then
		add("breath.slow", nil, rr)
	else
		add("breath.normal", nil, rr)
	end
	if exam.airway > 0 then
		add("airway")
	end
	if exam.blood < 0.7 then
		add("pale.severe")
	elseif exam.blood < 0.85 then
		add("pale")
	end
	for i = 1, min(6, #exam.bleeding) do
		local w = exam.bleeding[i]
		local part = w.limb or w.region
		local key = w.arterial and "bleed.arterial" or (w.rate > 60 and "bleed.heavy" or "bleed.light")
		local flag = ""
		if w.tourniquet then
			flag = "tourniquet"
		elseif w.bandage > 0 then
			flag = w.rate > 5 and "soaked" or "dressed"
		end
		if w.rate <= 0.5 then
			key = "bleed.stopped"
		end
		add(key, part, w.rate, flag)
	end
	if exam.internal > 40 then
		add("internal")
	end
	for _, side in ipairs({ "l", "r" }) do
		local c = exam.chest[side]
		local part = "chest_" .. side
		if c.open then
			add("chest.open", part)
		end
		if c.tension then
			add("chest.tension", part)
		elseif c.collapse > 0.3 or c.blood > 600 then
			add("chest.quiet", part)
		end
		if c.tube then
			add("chest.tube", part)
		end
	end
	if exam.tamponade > 100 then
		add("tamponade")
	end
	if exam.skull > 30 then
		add("pupils")
	end
	if exam.cord >= 3 then
		add("paralysis.full")
	elseif exam.cord >= 1 then
		add("paralysis.legs")
	end
	local seen = {}
	for _, f in ipairs(exam.fractures) do
		local part = f.limb or f.region
		local key = f.open and "fracture.open" or "fracture"
		if not seen[key .. part] then
			seen[key .. part] = true
			add(key, part, nil, f.splint and "splinted" or "")
		end
	end
	for _, limb in ipairs(exam.dislocations) do
		add("dislocation", limb)
	end
	for _, t in ipairs(exam.tourniquets) do
		add("tourniquet", t.limb, t.minutes + 0.5)
	end
	if exam.pain > 0.6 then
		add("pain")
	end
	if exam.temperature < 35 then
		add("cold")
	end
	if #list == 3 and list[1].key == "awake" and list[2].key == "pulse.normal" and list[3].key == "breath.normal" then
		add("ok")
	end
	if diag.spo2 then
		add("spo2", nil, exam.spo2 * 100 + 0.5)
	end
	if diag.pressure then
		add("pressure", nil, exam.map)
	end
	if diag.rhythm then
		add("rhythm." .. tostring(exam.rhythm))
	end
	if diag.temperature then
		add("temperature", nil, exam.temperature * 10 + 0.5)
	end
	return list
end

-- What `ply` can do for `patient` now: a list of { source, id, part, count }.
function M:Options(ply, patient, exam)
	local list = {}
	if exam.dead then
		return list
	end
	local own = patient == ply
	local inventory = self.inventory
	local seen = {}
	for _, item in ipairs(inventory:ItemsOf(ply)) do
		local id = item.id
		local trait = seen[id] == nil and self:Trait(id) or nil
		if trait ~= nil then
			seen[id] = true
			local allowed = (own and trait.self ~= false) or (not own and trait.others ~= false)
			if allowed and self:CanTreat(ply, patient, trait.treatment, trait.opts or {}, id) then
				list[#list + 1] = { source = "item", id = id, part = "", count = min(65535, inventory:Count(ply, id)) }
			end
		end
	end
	for _, id in ipairs(M.HANDS_ORDER) do
		local spec = M.HANDS[id]
		if not own or spec.selfTime ~= nil then
			if id == "reduce" then
				for _, limb in ipairs(exam.dislocations) do
					list[#list + 1] = { source = "hands", id = id, part = limb, count = 0 }
				end
			elseif id == "tourniquet_off" then
				for _, t in ipairs(exam.tourniquets) do
					list[#list + 1] = { source = "hands", id = id, part = t.limb, count = 0 }
				end
			elseif id == "cpr" then
				if exam.pulse <= 0 and self:CanTreat(ply, patient, "cpr") then
					list[#list + 1] = { source = "hands", id = id, part = "", count = 0 }
				end
			elseif id == "ventilate" then
				if exam.breathing <= 0 and exam.pulse > 0 then
					list[#list + 1] = { source = "hands", id = id, part = "", count = 0 }
				end
			end
		end
	end
	while #list > 24 do
		list[#list] = nil
	end
	return list
end

-- The report of `ply` on `patient`: findings and options (nil without a body).
function M:Report(ply, patient)
	local exam = self.organism:Examine(patient)
	if exam == nil then
		return nil
	end
	return self:Findings(exam, self:Diagnostics(ply)), self:Options(ply, patient, exam)
end

function M:SendReport(ply, patient)
	local findings, options = self:Report(ply, patient)
	if findings == nil or not IsValid(ply) then
		return
	end
	self.reports[ply] = { patient = patient, at = CurTime() }
	self.ctx.net:Send("report", ply, { patient = self.players:Name(patient):sub(1, 32), self = patient == ply,
		findings = findings, options = options })
end

-- A button of the report: treat its patient (or the one in front).
function M:OnTreat(data, ply)
	if not self.players:IsAlive(ply) then
		return
	end
	local report = self.reports[ply]
	local patient
	if report ~= nil and CurTime() - report.at <= self.ctx.config.reportTime and IsValid(report.patient) then
		patient = report.patient
	else
		patient = self:Aimed(ply) or ply
	end
	if data.source == "item" then
		local item
		for _, candidate in ipairs(self.inventory:ItemsOf(ply)) do
			if candidate.id == data.id then
				item = candidate
				break
			end
		end
		if item == nil then
			return self:_Tell(ply, false, "item")
		end
		return self:_Tell(ply, self:UseItem(ply, patient, item))
	end
	return self:_Tell(ply, self:UseHands(ply, patient, data.id, data.part ~= "" and data.part or nil))
end
