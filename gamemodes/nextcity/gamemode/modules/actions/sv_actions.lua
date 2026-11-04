-- Actions, server part.
--
--   actions:Begin(ply, {
--   	id = "bandage", label = "medical.action.bandage", duration = 4,
--   	target = other,           -- optional: an entity that must stay valid and in range
--   	range = 96,               -- units to the target (config.range)
--   	allowMove = false,        -- moving more than config.tolerance cancels
--   	allowDamage = false,      -- a hit cancels
--   	Check = function(ply, target) return true end,     -- every check: false, reason cancels
--   	OnComplete = function(ply, target, action) end,
--   	OnCancel = function(ply, reason, target, action) end,
--   	quiet = false,            -- true: no notice to the player when it is cancelled
--   })
--
-- Begin returns true, or false and the reason: "dead", "unconscious", "busy" (another
-- action), "target", "range" or the reason of Check. Reasons of cancelling: "dead",
-- "left", "unconscious", "moved", "hurt", "target", "range", "cancelled" (Cancel) or the
-- reason of Check. A duration of 0 completes at once. With notices the player is told
-- why his action stopped ("actions.stopped.<reason>", when the language files have it).
--
-- Listens: players.died, players.left, players.stateChanged, damage.hit.
-- Emits:   actions.started (ply, id), actions.completed (ply, id),
--          actions.cancelled (ply, id, reason)  server

local M = NC.Module("actions")

local IsValid = IsValid
local CurTime = CurTime
local pairs = pairs
local type = type
local tostring = tostring
local xpcall = xpcall
local traceback = debug.traceback

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.notices = ctx:Require("notices")
	self.current = {} -- ply -> action
end

function M:Start(ctx)
	ctx:On("players.died", "OnGone")
	ctx:On("players.left", "OnLeft")
	ctx:On("players.stateChanged", "OnStateChanged")
	ctx:On("damage.hit", "OnHit")
	ctx:Every("check", ctx.config.interval, function()
		self:Check(CurTime())
	end)
end

function M:Stop()
	for ply in pairs(self.current) do
		self:Cancel(ply, "cancelled")
	end
end

local function center(ent)
	if ent.WorldSpaceCenter ~= nil then
		return ent:WorldSpaceCenter()
	end
	return ent:GetPos()
end

local function targetName(target)
	if not IsValid(target) then
		return ""
	end
	if target:IsPlayer() then
		return target:Nick()
	end
	return ""
end

function M:_Problem(ply)
	if not IsValid(ply) or not self.players:IsAlive(ply) then
		return "dead"
	end
	if self.organism ~= nil and self.organism:IsUnconscious(ply) then
		return "unconscious"
	end
	return nil
end

function M:_TargetProblem(ply, action)
	local target = action.target
	if target == nil then
		return nil
	end
	if not IsValid(target) then
		return "target"
	end
	if target ~= ply and center(target):Distance(ply:GetShootPos()) > action.range then
		return "range"
	end
	return nil
end

function M:_Call(fn, name, ...)
	local ok, result, reason = xpcall(fn, traceback, ...)
	if not ok then
		self.ctx.log:Error("action %s: %s", name, tostring(result))
		return nil
	end
	return result, reason
end

-- Starts an action (see the top of the file).
function M:Begin(ply, spec)
	local problem = self:_Problem(ply)
	if problem ~= nil then
		return false, problem
	end
	if self.current[ply] ~= nil then
		return false, "busy"
	end
	local now = CurTime()
	local action = {
		id = tostring(spec.id or "action"),
		label = spec.label or "actions.working",
		duration = math.max(0, tonumber(spec.duration) or 0),
		target = spec.target,
		range = spec.range or self.ctx.config.range,
		allowMove = spec.allowMove == true,
		allowDamage = spec.allowDamage == true,
		Check = spec.Check,
		OnComplete = spec.OnComplete,
		OnCancel = spec.OnCancel,
		quiet = spec.quiet == true,
		data = spec.data,
		startedAt = now,
		pos = ply:GetPos(),
	}
	action.endsAt = now + action.duration
	problem = self:_TargetProblem(ply, action)
	if problem ~= nil then
		return false, problem
	end
	if type(action.Check) == "function" then
		local ok, reason = self:_Call(action.Check, action.id, ply, action.target)
		if ok == false then
			return false, reason or "check"
		end
	end
	self.current[ply] = action
	self.ctx.components.action:Add(ply, { label = action.label, target = targetName(action.target):sub(1, 48),
		startedAt = now, duration = action.duration })
	self.ctx.events:Emit("actions.started", ply, action.id)
	if action.duration <= 0 then
		self:_Complete(ply, action)
	end
	return true
end

-- The action of `ply` under way, or nil (do not modify).
function M:Current(ply)
	return self.current[ply]
end

function M:IsBusy(ply)
	return self.current[ply] ~= nil
end

-- The share of the action of `ply` done, 0..1, or nil.
function M:Progress(ply)
	local action = self.current[ply]
	if action == nil then
		return nil
	end
	if action.duration <= 0 then
		return 1
	end
	return math.min(1, (CurTime() - action.startedAt) / action.duration)
end

function M:_Finish(ply)
	self.current[ply] = nil
	if IsValid(ply) then
		self.ctx.components.action:Remove(ply)
	end
end

function M:_Complete(ply, action)
	self:_Finish(ply)
	if type(action.OnComplete) == "function" then
		self:_Call(action.OnComplete, action.id, ply, action.target, action)
	end
	self.ctx.events:Emit("actions.completed", ply, action.id)
end

-- Cancels the action of `ply` (reason default "cancelled"); true if there was one.
function M:Cancel(ply, reason)
	local action = self.current[ply]
	if action == nil then
		return false
	end
	reason = reason or "cancelled"
	self:_Finish(ply)
	if type(action.OnCancel) == "function" then
		self:_Call(action.OnCancel, action.id, ply, reason, action.target, action)
	end
	local key = "actions.stopped." .. tostring(reason)
	if self.notices ~= nil and not action.quiet and IsValid(ply) and self.ctx.i18n:Has(key) then
		self.notices:Send(ply, key, nil, "warn")
	end
	self.ctx.events:Emit("actions.cancelled", ply, action.id, reason)
	return true
end

-- Checks every action under way: cancels or completes them.
function M:Check(now)
	for ply, action in pairs(self.current) do
		local problem = self:_Problem(ply)
		if problem == nil and not action.allowMove and ply:GetPos():Distance(action.pos) > self.ctx.config.tolerance then
			problem = "moved"
		end
		problem = problem or self:_TargetProblem(ply, action)
		if problem == nil and type(action.Check) == "function" then
			local ok, reason = self:_Call(action.Check, action.id, ply, action.target)
			if ok == false then
				problem = reason or "check"
			end
		end
		if problem ~= nil then
			self:Cancel(ply, problem)
		elseif now >= action.endsAt then
			self:_Complete(ply, action)
		end
	end
end

function M:OnGone(ply)
	self:Cancel(ply, "dead")
end

function M:OnLeft(ply)
	self:Cancel(ply, "left")
end

function M:OnStateChanged(ply, state)
	if state ~= "alive" then
		self:Cancel(ply, "dead")
	end
end

function M:OnHit(ply)
	local action = self.current[ply]
	if action ~= nil and not action.allowDamage then
		self:Cancel(ply, "hurt")
	end
end
