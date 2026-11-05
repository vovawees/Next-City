-- Rounds module, server part: the round state machine and its players.
--
--   waiting    not enough ready players for the mode; the warmup lets everybody play
--   preparing  map cleaned, a new round: Setup, participants added and spawned (frozen)
--   active     Start, Think, deaths, respawns, win checks and the time limit
--   ended      End and the result on screen; then Cleanup and the next round
-- Any phase falls back to waiting when players leave or the mode goes away; an admin can
-- restart a round from any phase (nc_round).
--
-- Listens:  players.ready, players.spawned, players.loadout, players.died, players.left,
--           net.ready; answers players.spawnPoint and gm.PlayerShouldTakeDamage.
-- Emits:    rounds.phase (phase, old, round) after every phase change.

local M = NC.Module("rounds")

local FSM = NC.Lib.FSM
local Scope = NC.Lib.Scope

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local min = math.min
local max = math.max
local floor = math.floor
local random = math.random
local CurTime = CurTime
local IsValid = IsValid

-- Settings ------------------------------------------------------------------------------

local function bounded(ctx, key, low, high)
	local value = ctx.config[key]
	local fixed = value == value and min(max(value, low), high) or low
	if fixed ~= value then
		ctx.log:Warn("setting '%s' = %s is outside %s..%s; using %s", key, tostring(value), low, high, fixed)
	end
	return fixed
end

local function strings(ctx, key)
	local list = {}
	for _, value in ipairs(ctx.config[key]) do
		if type(value) == "string" and value ~= "" then
			list[#list + 1] = value
		else
			ctx.log:Warn("setting '%s': %s is not a non-empty string; skipped", key, tostring(value))
		end
	end
	return list
end

local function readSettings(ctx)
	local cfg = ctx.config
	local params = {}
	for id, values in pairs(cfg.params) do
		if type(values) == "table" then
			params[id] = values
		else
			ctx.log:Warn("setting 'params': params of mode '%s' must be a table; skipped", tostring(id))
		end
	end
	return {
		mode = cfg.mode,
		rotation = strings(ctx, "rotation"),
		roundsPerMode = floor(bounded(ctx, "roundsPerMode", 1, 1000)),
		prepareTime = bounded(ctx, "prepareTime", 0, 600),
		endTime = bounded(ctx, "endTime", 0, 600),
		freeze = cfg.freeze,
		shuffle = cfg.shuffle,
		cleanupMap = cfg.cleanupMap,
		warmup = cfg.warmup,
		warmupRespawn = bounded(ctx, "warmupRespawn", 0, 600),
		warmupLoadout = strings(ctx, "warmupLoadout"),
		params = params,
	}
end

-- Lifecycle -----------------------------------------------------------------------------

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.settings = readSettings(ctx)
	self:_InitRegistry()
	self:_RegisterBuiltinRules()
	self.number = 0          -- rounds created since the map started
	self.round = nil         -- the current round (preparing, active, ended)
	self.modeId = self.settings.mode
	self.nextModeId = nil    -- chosen by an admin for the next round
	self.played = 0          -- finished rounds of the current mode
	self.forceStart = false
	self.phaseEndsAt = 0
	self.phaseScope = nil
	self.reported = {}       -- problems with modes already logged
	self:_AddCommands(ctx)
end

function M:Start(ctx)
	self:_CheckConfig()
	ctx:On("players.ready", "OnReady")
	ctx:On("players.spawned", "OnSpawned")
	ctx:On("players.loadout", "OnLoadout")
	ctx:On("players.died", "OnDied")
	ctx:On("players.left", "OnLeft")
	ctx:On("players.spawnPoint", "AnswerSpawnPoint")
	ctx:On("gm.PlayerShouldTakeDamage", "AnswerTakeDamage")
	ctx:On("net.ready", "OnNetReady")
	ctx:Every("check", 1, "CheckPlayers")
	self.fsm = FSM.New({
		initial = "waiting",
		states = {
			waiting = { to = { "preparing" },
				enter = function() self:_EnterWaiting() end,
				exit = function() self:_EndPhase() end },
			preparing = { to = { "active", "ended", "preparing" },
				enter = function() self:_EnterPreparing() end,
				exit = function(_, to) self:_ExitRoundPhase(to == "preparing" or to == "waiting") end },
			active = { to = { "ended", "preparing" },
				enter = function() self:_EnterActive() end,
				exit = function(_, to) self:_ExitRoundPhase(to == "preparing" or to == "waiting") end },
			ended = { to = { "preparing" },
				enter = function(_, _, result) self:_EnterEnded(result) end,
				exit = function() self:_ExitRoundPhase(true) end },
		},
		any = { "waiting" },
		onChange = function(_, from, to) self:_OnPhase(from, to) end,
		onError = function(err) ctx.log:Error("round state machine: %s", tostring(err)) end,
	}, self)
end

function M:Stop()
	self:_CloseRound()
	self:_EndPhase()
end

-- Warns about config entries that name modes nobody registered.
function M:_CheckConfig()
	local settings = self.settings
	for _, id in ipairs(settings.rotation) do
		if self.modes[id] == nil then
			self.ctx.log:Warn("setting 'rotation': mode '%s' is not registered", id)
		end
	end
	for id in pairs(settings.params) do
		if self.modes[id] == nil then
			self.ctx.log:Warn("setting 'params': mode '%s' is not registered", tostring(id))
		end
	end
end

-- Current phase: waiting, preparing, active or ended.
function M:Phase()
	return self.fsm and self.fsm:Get() or "waiting"
end

-- The current round (preparing, active, ended) or nil.
function M:Round()
	return self.round
end

-- Modes ---------------------------------------------------------------------------------

-- Logs a problem once until it changes.
function M:_Report(key, message, ...)
	local text = string.format(message, ...)
	if self.reported[key] ~= text then
		self.reported[key] = text
		self.ctx.log:Warn("%s", text)
	end
end

-- Entry of the mode the next round plays (without choosing it), or nil.
function M:_PeekMode()
	local wanted = self.nextModeId or self.modeId
	if self:IsAvailable(wanted) then
		return self.modes[wanted]
	end
	local _, reason = self:IsAvailable(wanted)
	local candidates = {}
	for _, id in ipairs(self.settings.rotation) do
		candidates[#candidates + 1] = id
	end
	for _, id in ipairs(self:Modes()) do
		candidates[#candidates + 1] = id
	end
	for _, id in ipairs(candidates) do
		if self:IsAvailable(id) then
			self:_Report("mode", "mode '%s' is not available (%s); playing '%s'", tostring(wanted), reason, id)
			return self.modes[id]
		end
	end
	self:_Report("mode", "no mode to play: mode '%s' is not available (%s)", tostring(wanted), reason)
	return nil
end

-- Chooses the mode of a new round: the admin's pick, the rotation or a fallback. The
-- admin's pick becomes the current mode; a fallback does not, so the wanted mode is
-- played again as soon as it is available.
function M:_PickMode()
	local entry = self:_PeekMode()
	if self.nextModeId ~= nil then
		self.modeId = self.nextModeId
		self.nextModeId = nil
		self.played = 0
	end
	return entry
end

-- After a finished round: the next mode of the rotation once roundsPerMode are played.
function M:_AdvanceRotation()
	self.played = self.played + 1
	local rotation = self.settings.rotation
	if rotation[1] == nil or self.played < self.settings.roundsPerMode or self.nextModeId ~= nil then
		return
	end
	local index = 0
	for i, id in ipairs(rotation) do
		if id == self.modeId then
			index = i
			break
		end
	end
	for step = 1, #rotation do
		local id = rotation[(index + step - 1) % #rotation + 1]
		if self:IsAvailable(id) then
			self.modeId = id
			self.played = 0
			return
		end
	end
end

-- Picks the mode of the next round (an available mode id). Returns true or false and why.
function M:SetNextMode(id)
	local ok, reason = self:IsAvailable(id)
	if not ok then
		return false, string.format("mode '%s' is not available: %s", tostring(id), reason)
	end
	self.nextModeId = id
	return true
end

-- Phases --------------------------------------------------------------------------------

function M:_ReadyCount()
	return #self.players:ReadyPlayers()
end

function M:_CanStart()
	local entry = self:_PeekMode()
	return entry ~= nil and self:_ReadyCount() >= entry.minPlayers
end

function M:_BeginPhase(name, duration)
	self:_EndPhase()
	local ctx = self.ctx
	self.phaseScope = Scope.New({ id = "rounds:" .. name, events = ctx.events, scheduler = ctx.scheduler,
		onError = function(err) ctx.log:Error("phase %s: %s", name, tostring(err)) end })
	self.phaseEndsAt = duration > 0 and CurTime() + duration or 0
end

function M:_EndPhase()
	if self.phaseScope ~= nil then
		self.phaseScope:Dispose()
		self.phaseScope = nil
	end
end

function M:_ExitRoundPhase(close)
	self:_EndPhase()
	if close then
		self:_CloseRound()
	end
end

function M:_EnterWaiting()
	self:_BeginPhase("waiting", 0)
	if self.settings.warmup then
		for _, ply in ipairs(self.players:ReadyPlayers()) do
			if not self.players:IsAlive(ply) then
				self.players:Deploy(ply)
			end
		end
	end
	-- Not from inside the transition: a start right away is the next transition.
	self.phaseScope:After(0, function()
		self:CheckPlayers()
	end)
end

local function shuffle(list)
	for i = #list, 2, -1 do
		local j = random(i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

function M:_EnterPreparing()
	local entry = self:_PickMode()
	if entry == nil then
		self.fsm:Go("waiting")
		return
	end
	local settings = self.settings
	self:_BeginPhase("preparing", settings.prepareTime)
	if settings.cleanupMap then
		game.CleanUpMap()
	end
	local round = self:_CreateRound(entry, self:ResolveParams(entry.id))
	round.forced = self.forceStart
	self.forceStart = false
	self.round = round
	round:_Call("Setup")

	local players = self.players
	local ready = players:ReadyPlayers()
	if settings.shuffle then
		shuffle(ready)
	end
	local chosen = round:_Ask("Participants", ready)
	if type(chosen) ~= "table" then
		chosen = ready
	end
	for _, ply in ipairs(chosen) do
		if IsValid(ply) and players:IsReady(ply) and round:_Add(ply) then
			round:_Call("PlayerAdded", ply)
		end
	end
	for _, ply in ipairs(ready) do
		if not round:IsParticipant(ply) then
			players:MakeSpectator(ply)
		end
	end
	local participants = {}
	for i, ply in ipairs(round:Participants()) do
		participants[i] = ply
	end
	for _, ply in ipairs(participants) do
		if round:IsParticipant(ply) then
			players:Deploy(ply)
		end
	end
	self.phaseScope:After(settings.prepareTime, function()
		self.fsm:Go("active")
	end)
end

function M:_EnterActive()
	local round = self.round
	self:_BeginPhase("active", 0)
	if round == nil then
		self.fsm:Go("waiting")
		return
	end
	round.startedAt = CurTime()
	self:_Unfreeze(round)
	round._starting = true
	self:_ApplyTimeLimit(round)
	round:_Call("Start")
	round._starting = false
	if round:_Has("Think") then
		round._think = round:Every("think", round.entry.thinkInterval, function()
			round:_Call("Think")
		end)
	end
	round:CheckWin()
end

function M:_EnterEnded(result)
	local round = self.round
	self:_BeginPhase("ended", self.settings.endTime)
	if round == nil then
		self.fsm:Go("waiting")
		return
	end
	self:_StopClock(round)
	round:_CancelRespawns()
	self:_Unfreeze(round)
	round:_Call("End", result)
	self:_ClearStatus()
	self.ctx.net:Broadcast("result", self:_ResultMessage(result))
	self.phaseScope:After(self.settings.endTime, function()
		self:_AdvanceRotation()
		self.fsm:Go(self:_CanStart() and "preparing" or "waiting")
	end)
end

-- Releases the current round: Cleanup, its subscriptions, frozen players.
function M:_CloseRound()
	local round = self.round
	if round == nil then
		return
	end
	self.round = nil
	self:_StopClock(round)
	round:_CancelRespawns()
	self:_ClearStatus()
	round:_Call("Cleanup")
	round._scope:Dispose()
	self:_Unfreeze(round)
end

-- Stops what runs only while the round is active: Think and the time limit.
function M:_StopClock(round)
	if round._think ~= nil then
		round._think:Remove()
		round._think = nil
	end
	if round._limitTimer ~= nil then
		round._limitTimer:Cancel()
		round._limitTimer = nil
	end
end

function M:_Unfreeze(round)
	if not self.settings.freeze then
		return
	end
	for _, ply in ipairs(round:Participants()) do
		if IsValid(ply) then
			ply:Freeze(false)
		end
	end
end

function M:_OnPhase(from, to)
	self.ctx.log:Debug("phase %s -> %s", tostring(from), to)
	self:_BroadcastState()
	self.ctx.events:Emit("rounds.phase", to, from, self.round)
end

-- Starts a new round now, even with fewer players than the mode needs; mode is
-- optional. Returns true or false and why.
function M:Restart(mode)
	if mode ~= nil then
		local ok, err = self:SetNextMode(mode)
		if not ok then
			return false, err
		end
	end
	if self:_PeekMode() == nil then
		return false, "no mode to play"
	end
	if self:_ReadyCount() == 0 then
		return false, "no ready players"
	end
	self.forceStart = true
	local ok, err = self.fsm:Go("preparing")
	if not ok then
		self.forceStart = false
	end
	return ok, err
end

-- Ends the current round with a result (see Round:End). Returns false if the round is
-- not preparing or active.
function M:EndRound(round, result)
	local phase = self:Phase()
	local running = phase == "active" or phase == "preparing"
	if round == nil or round ~= self.round or round.result ~= nil or not running then
		return false
	end
	result = self:_NormalizeResult(round, result)
	round.result = result
	return self.fsm:Go("ended", result)
end

local RESULT_TYPES = { reason = "string", key = "string", team = "number" }

function M:_NormalizeResult(round, result)
	if type(result) ~= "table" then
		result = {}
	end
	local fixed = {}
	for key, value in pairs(result) do
		local expected = RESULT_TYPES[key]
		if expected ~= nil and type(value) ~= expected then
			self.ctx.log:Warn("round %d: result.%s must be a %s, got %s; ignored", round.number, key, expected,
				type(value))
		else
			fixed[key] = value
		end
	end
	fixed.reason = fixed.reason or "end"
	if fixed.winner ~= nil and not (IsValid(fixed.winner) and fixed.winner:IsPlayer()) then
		fixed.winner = nil
	end
	return fixed
end

function M:_CheckWin(round)
	if round ~= self.round or self:Phase() ~= "active" then
		return
	end
	local result = round:_Ask("CheckWin")
	if result ~= nil then
		self:EndRound(round, result)
	end
end

function M:_Timeout(round)
	if round ~= self.round or self:Phase() ~= "active" then
		return
	end
	self:EndRound(round, round:_Ask("Timeout") or { reason = "time" })
end

function M:_ApplyTimeLimit(round)
	if round._limitTimer ~= nil then
		round._limitTimer:Cancel()
		round._limitTimer = nil
	end
	local limit = round._limit
	if limit == nil then
		round.endsAt = nil
	else
		round.endsAt = CurTime() + limit
		round._limitTimer = round:After(limit, round._timeout)
	end
	if not round._starting then
		self:_BroadcastState()
	end
end

-- Players -------------------------------------------------------------------------------

-- Every second and when players come and go: start, or fall back to waiting.
function M:CheckPlayers()
	local phase = self:Phase()
	if phase == "waiting" then
		if self:_CanStart() then
			self.fsm:Go("preparing")
		end
		return
	end
	local round = self.round
	if round == nil then
		return
	end
	local available, reason = self:IsAvailable(round.mode)
	if not available then
		self.ctx.log:Warn("round %d: mode '%s' is no longer available (%s)", round.number, round.mode, reason)
		self.fsm:Go("waiting")
	elseif phase == "preparing" and not round.forced and self:_ReadyCount() < round.entry.minPlayers then
		self.fsm:Go("waiting")
	end
end

function M:_Join(round, ply)
	if round ~= self.round or not (IsValid(ply) and self.players:IsReady(ply)) or not round:_Add(ply) then
		return false
	end
	round:_Call("PlayerAdded", ply)
	local phase = self:Phase()
	if phase == "preparing" or phase == "active" then
		self.players:Deploy(ply)
	end
	return true
end

function M:_Respawn(round, ply)
	local phase = self:Phase()
	if round == self.round and (phase == "active" or phase == "preparing") and IsValid(ply)
		and round:IsParticipant(ply) and not self.players:IsAlive(ply) then
		self.players:Deploy(ply)
	end
end

function M:OnReady(ply)
	local phase = self:Phase()
	if phase == "waiting" then
		if self:_CanStart() then
			self.fsm:Go("preparing")
		elseif self.settings.warmup then
			self.players:Deploy(ply)
		end
		return
	end
	local round = self.round
	if round ~= nil and (phase == "preparing" or phase == "active") then
		local join = round:_Ask("LateJoin", ply)
		if join == nil then
			join = phase == "preparing"
		end
		if join then
			self:_Join(round, ply)
		end
	end
end

function M:OnSpawned(ply)
	local round = self.round
	if round == nil or not round:IsParticipant(ply) then
		return
	end
	round:_ForgetRespawn(ply)
	if self.settings.freeze and self:Phase() == "preparing" then
		ply:Freeze(true)
	end
	round:_Call("PlayerSpawned", ply)
end

function M:OnLoadout(ply)
	local phase = self:Phase()
	if phase == "waiting" then
		for _, class in ipairs(self.settings.warmupLoadout) do
			ply:Give(class)
		end
		return
	end
	local round = self.round
	if round ~= nil and round:IsParticipant(ply) and (phase == "preparing" or phase == "active") then
		round:_Call("Loadout", ply)
	end
end

function M:OnDied(ply, inflictor, attacker)
	local phase = self:Phase()
	if phase == "waiting" then
		if self.settings.warmup then
			local delay = self.settings.warmupRespawn
			self.players:SetRespawnAt(ply, CurTime() + delay)
			self.phaseScope:After(delay, function()
				if IsValid(ply) and self.players:State(ply) == "dead" then
					self.players:Deploy(ply)
				end
			end)
		end
		return
	end
	local round = self.round
	if round ~= nil and round:IsParticipant(ply) and (phase == "preparing" or phase == "active") then
		round:_Call("PlayerDied", ply, inflictor, attacker)
		if phase == "active" then
			round:CheckWin()
		end
	end
end

function M:OnLeft(ply)
	local round = self.round
	if round ~= nil and round:_Remove(ply) then
		round:_Call("PlayerLeft", ply)
		if self:Phase() == "active" then
			if round:ParticipantCount() == 0 then
				self:EndRound(round, { reason = "abandoned" })
			else
				round:CheckWin()
			end
		end
	end
	self:CheckPlayers()
end

function M:AnswerSpawnPoint(ply)
	local round = self.round
	if round ~= nil and round:IsParticipant(ply) then
		return round:_Ask("SpawnPoint", ply)
	end
	return nil
end

-- No damage between rounds; while active the mode and its rules decide.
function M:AnswerTakeDamage(ply, attacker)
	local phase = self:Phase()
	if phase == "preparing" or phase == "ended" then
		return false
	end
	local round = self.round
	if phase == "active" and round ~= nil then
		return round:_Ask("ShouldTakeDamage", ply, attacker)
	end
	return nil
end

-- Network -------------------------------------------------------------------------------

function M:_StateMessage()
	local phase = self:Phase()
	local round = self.round
	local entry = round and round.entry or self:_PeekMode()
	local endsAt = self.phaseEndsAt
	if phase == "active" then
		endsAt = round and round.endsAt or 0
	end
	return {
		phase = phase,
		mode = entry and entry.id or "",
		name = entry and entry.name or "",
		number = round and round.number or self.number,
		endsAt = endsAt,
		minPlayers = entry and entry.minPlayers or 0,
	}
end

function M:_ResultMessage(result)
	return {
		reason = result.reason,
		key = type(result.key) == "string" and result.key or "",
		team = type(result.team) == "number" and result.team > 0 and floor(result.team) or 0,
		winner = result.winner,
	}
end

function M:_BroadcastState()
	self.ctx.net:Broadcast("state", self:_StateMessage())
end

function M:OnNetReady(ply)
	self.ctx.net:Send("state", ply, self:_StateMessage())
	local round = self.round
	if self:Phase() == "ended" and round ~= nil and round.result ~= nil then
		self.ctx.net:Send("result", ply, self:_ResultMessage(round.result))
	end
	if self.status ~= nil then
		self.ctx.net:Send("status", ply, self.status)
	end
end

-- The status line of the current round (Round:SetStatus); nil key clears it.
function M:_SetStatus(round, key, params, endsAt)
	if round ~= self.round then
		return
	end
	if type(key) ~= "string" or key == "" then
		self:_ClearStatus()
		return
	end
	self.status = { key = key, endsAt = type(endsAt) == "number" and endsAt or 0, params = self.EncodeParams(params) }
	self.ctx.net:Broadcast("status", self.status)
end

function M:_ClearStatus()
	if self.status ~= nil then
		self.status = nil
		self.ctx.net:Broadcast("status", { key = "", endsAt = 0, params = {} })
	end
end
