-- Rounds module, server part: the round object passed to every callback of a mode and
-- its rules (docs/ARCHITECTURE.md, section 11).
--
--   round.number, round.mode (id), round.name, round.params (checked values),
--   round.data (free for the mode), round:RuleData(id) (free for a rule),
--   round.startedAt, round.endsAt (game time, nil without a limit), round.result
--   round:On / Every / After / Defer             subscriptions that end with the round
--   round:Phase(), IsActive()
--   round:Participants(), ParticipantCount(), IsParticipant(ply), Alive(), AliveCount(),
--   round:AddParticipant(ply)                    joins and spawns a ready player
--   round:Respawn(ply, delay), CancelRespawn(ply), IsRespawning(ply), RespawnCount()
--   round:SetTimeLimit(seconds), TimeLeft(), Elapsed()
--   round:CheckWin()                             asks CheckWin on the next tick
--   round:End(result)                            { reason, team, winner, key, ... }
--
-- Callbacks are protected: an error is logged with the name of the mode or the rule and
-- the round goes on.

local M = NC.Module("rounds")

local Scope = NC.Lib.Scope

local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local xpcall = xpcall
local traceback = debug.traceback
local max = math.max
local CurTime = CurTime
local IsValid = IsValid

local LIFECYCLE = M.LIFECYCLE
local QUESTIONS = M.QUESTIONS

local Round = {}
Round.__index = Round

local function onCallbackError(err)
	return traceback(tostring(err), 2)
end

-- [name] = { { fn, label, owner }, ... } for the callbacks the mode and its rules define.
local function collect(links, names)
	local lists = {}
	for _, name in ipairs(names) do
		local list = {}
		for _, link in ipairs(links) do
			local fn = link.def[name]
			if fn ~= nil then
				list[#list + 1] = { fn, link.label, link.owner }
			end
		end
		lists[name] = list
	end
	return lists
end

-- A new round of a mode entry with checked parameter values.
function M:_CreateRound(entry, params)
	self.number = self.number + 1
	local ctx = self.ctx
	local number = self.number
	local links, ruleData = {}, {}
	for _, ruleId in ipairs(entry.rules) do
		local rule = self.rules[ruleId]
		links[#links + 1] = { def = rule.def, label = "rule '" .. ruleId .. "'", owner = rule.owner }
		ruleData[ruleId] = {}
	end
	local modeLink = { def = entry.def, label = "mode '" .. entry.id .. "'", owner = entry.owner }
	local asking = { modeLink }
	for _, link in ipairs(links) do
		asking[#asking + 1] = link
	end
	links[#links + 1] = modeLink

	local round = setmetatable({
		number = number,
		mode = entry.id,
		name = entry.name,
		entry = entry,
		params = params,
		data = {},
		startedAt = nil,
		endsAt = nil,
		result = nil,
		forced = false,
		_module = self,
		_players = self.players,
		_log = ctx.log,
		_scope = Scope.New({ id = "rounds:" .. number, events = ctx.events, scheduler = ctx.scheduler,
			onError = function(err)
				ctx.log:Error("round %d: %s", number, tostring(err))
			end }),
		_ruleData = ruleData,
		_calls = collect(links, LIFECYCLE),
		_asks = collect(asking, QUESTIONS),
		_participants = {},
		_slots = {},
		_respawns = {},
		_respawnCount = 0,
		_limit = nil,
		_limitTimer = nil,
		_think = nil,
		_starting = false,
		_checking = false,
	}, Round)
	round._checkWin = function()
		round._checking = false
		self:_CheckWin(round)
	end
	round._timeout = function()
		round._limitTimer = nil
		self:_Timeout(round)
	end
	return round
end

-- Callbacks of a stopped module are skipped: its context is gone.
local function runnable(item)
	local owner = item[3]
	return owner == nil or owner:IsAlive()
end

-- Runs a notification on every rule, then the mode.
function Round:_Call(name, ...)
	local list = self._calls[name]
	for i = 1, #list do
		local item = list[i]
		if runnable(item) then
			local ok, err = xpcall(item[1], onCallbackError, self, ...)
			if not ok then
				self._log:Error("round %d: %s %s failed: %s", self.number, item[2], name, tostring(err))
			end
		end
	end
end

-- Asks the mode, then the rules; returns the first non-nil answer.
function Round:_Ask(name, ...)
	local list = self._asks[name]
	for i = 1, #list do
		local item = list[i]
		if runnable(item) then
			local ok, answer = xpcall(item[1], onCallbackError, self, ...)
			if not ok then
				self._log:Error("round %d: %s %s failed: %s", self.number, item[2], name, tostring(answer))
			elseif answer ~= nil then
				return answer
			end
		end
	end
	return nil
end

function Round:_Has(name)
	return self._calls[name][1] ~= nil
end

-- Subscriptions -------------------------------------------------------------------------

function Round:On(event, fn, opts)
	return self._scope:On(event, fn, opts)
end

function Round:Every(id, interval, fn, opts)
	return self._scope:Every(id, interval, fn, opts)
end

function Round:After(delay, fn)
	return self._scope:After(delay, fn)
end

function Round:Defer(fn)
	return self._scope:Defer(fn)
end

-- Data table of a rule of this round (nil for a rule the mode does not use).
function Round:RuleData(id)
	return self._ruleData[id]
end

function Round:Phase()
	if self._module.round ~= self then
		return "closed"
	end
	return self._module:Phase()
end

function Round:IsActive()
	return self:Phase() == "active"
end

-- Participants --------------------------------------------------------------------------

-- Players taking part (do not modify; the order changes as players leave).
function Round:Participants()
	return self._participants
end

function Round:ParticipantCount()
	return #self._participants
end

function Round:IsParticipant(ply)
	return self._slots[ply] ~= nil
end

-- Living participants, a new table.
function Round:Alive()
	local alive = {}
	local players = self._players
	for _, ply in ipairs(self._participants) do
		if players:IsAlive(ply) then
			alive[#alive + 1] = ply
		end
	end
	return alive
end

function Round:AliveCount()
	local count = 0
	local players = self._players
	for _, ply in ipairs(self._participants) do
		if players:IsAlive(ply) then
			count = count + 1
		end
	end
	return count
end

-- Adds a ready player to the round (PlayerAdded) and spawns them while preparing or
-- active. Returns false if the player cannot join or already takes part.
function Round:AddParticipant(ply)
	return self._module:_Join(self, ply)
end

function Round:_Add(ply)
	if self._slots[ply] ~= nil then
		return false
	end
	local list = self._participants
	list[#list + 1] = ply
	self._slots[ply] = #list
	return true
end

function Round:_Remove(ply)
	local slot = self._slots[ply]
	if slot == nil then
		return false
	end
	self:CancelRespawn(ply)
	local list = self._participants
	local last = list[#list]
	list[slot] = last
	self._slots[last] = slot
	list[#list] = nil
	self._slots[ply] = nil
	return true
end

-- Respawns ------------------------------------------------------------------------------

-- Spawns a dead participant again after delay seconds (0: on the next tick) and shows
-- clients when. A new call replaces the pending one. Returns false for living players,
-- non-participants and after the round ended.
function Round:Respawn(ply, delay)
	if self._slots[ply] == nil or self.result ~= nil or self._players:IsAlive(ply) then
		return false
	end
	self:CancelRespawn(ply)
	delay = max(tonumber(delay) or 0, 0)
	local timer
	timer = self._scope:After(delay, function()
		if self._respawns[ply] ~= timer then
			return
		end
		self._respawns[ply] = nil
		self._respawnCount = self._respawnCount - 1
		self._module:_Respawn(self, ply)
	end)
	self._respawns[ply] = timer
	self._respawnCount = self._respawnCount + 1
	self._players:SetRespawnAt(ply, CurTime() + delay)
	return true
end

-- Drops a pending respawn. Returns true if there was one.
function Round:CancelRespawn(ply)
	if not self:_ForgetRespawn(ply) then
		return false
	end
	if IsValid(ply) then
		self._players:SetRespawnAt(ply, nil)
	end
	return true
end

function Round:_ForgetRespawn(ply)
	local timer = self._respawns[ply]
	if timer == nil then
		return false
	end
	timer:Cancel()
	self._respawns[ply] = nil
	self._respawnCount = self._respawnCount - 1
	return true
end

function Round:_CancelRespawns()
	local pending = {}
	for ply in pairs(self._respawns) do
		pending[#pending + 1] = ply
	end
	for _, ply in ipairs(pending) do
		self:CancelRespawn(ply)
	end
end

function Round:IsRespawning(ply)
	return self._respawns[ply] ~= nil
end

-- Number of participants waiting for a respawn.
function Round:RespawnCount()
	return self._respawnCount
end

-- Time ----------------------------------------------------------------------------------

-- Limits the round to `seconds` from the start (or from now when already active);
-- nil or 0 removes the limit. When time is up the round ends with the Timeout answer.
function Round:SetTimeLimit(seconds)
	seconds = tonumber(seconds)
	if seconds ~= nil and not (seconds > 0 and seconds < math.huge) then
		seconds = nil
	end
	self._limit = seconds
	if self.startedAt ~= nil and self.result == nil then
		self._module:_ApplyTimeLimit(self)
	end
end

-- Seconds left, nil without a limit.
function Round:TimeLeft()
	if self.endsAt == nil then
		return nil
	end
	return max(self.endsAt - CurTime(), 0)
end

-- Seconds since the round became active (0 before).
function Round:Elapsed()
	if self.startedAt == nil then
		return 0
	end
	return CurTime() - self.startedAt
end

-- Ending --------------------------------------------------------------------------------

-- Asks the CheckWin question on the next tick (several calls in one tick ask once).
function Round:CheckWin()
	if self._checking or self.result ~= nil or not self._scope:IsAlive() then
		return
	end
	self._checking = true
	self._scope:After(0, self._checkWin)
end

-- Ends the round with a result: { reason = "elimination", team = 2 } or
-- { reason = "last", winner = ply }; the mode may add its own fields. Returns false if
-- the round is not running.
function Round:End(result)
	return self._module:EndRound(self, result)
end

M.Round = Round
