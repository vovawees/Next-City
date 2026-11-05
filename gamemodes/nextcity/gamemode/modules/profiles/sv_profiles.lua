-- Profiles, server part.
--
--   profiles:Get(ply)              -> the record of a player on the server, or nil
--   profiles:Section(ply, id)      -> the table of module `id` in the record (made empty), or nil
--   profiles:Touch(ply)            after changing the record or a section: written a moment later
--   profiles:AddStat(ply, name, n) -> the new value of counter stats.<name> (M.STATS go to the summary)
--   profiles:Stat(ply, name)       -> number
--   profiles:Playtime(ply)         -> s in the game with the running session
--   profiles:Key(ply)              -> the storage key (SteamID64, "bot_<name>")
--   profiles:ByKey(key)            -> the record of anybody (on the server or in storage), or nil
--   profiles:IsLoaded(ply), profiles:Save(ply) (counts the playtime and writes now)
--   profiles:IsPersistent(ply)     -> whether his record outlives the session (storage, not a bot)
--
-- A record: { v = 1, name = last nick, first, last = unix times of the first visit and of
-- the last join or leave, visits, playtime = s, stats = { kills, deaths, rounds, wins,
-- creatures, ... }, sections = { [module id] = table } }. Modules keep their data in
-- their section: read it on profiles.loaded, change it and Touch.
--
-- A record is loaded when the player joins (visits + 1) and released when he leaves, after
-- profiles.leaving; the playtime of everybody on the server is counted every saveInterval
-- s and on shutdown. Bots keep their profiles for the session only (config.bots keeps them
-- in storage); without storage every profile lives for the session.
--
-- Listens:  gm.PlayerInitialSpawn, gm.PlayerDisconnected, gm.ShutDown (before storage),
--           players.died (kills, deaths), npcs.killed (creatures), rounds.phase (ended:
--           rounds and wins of the participants).
-- Emits:    profiles.loaded (ply, record, isNew), profiles.leaving (ply, record),
--           profiles.stat (ply, name, value, amount)
-- Asks:     profiles.won (ply, result, round) -> true | false; without an answer the player
--           won when result.winner is him or result.team is his team.
-- Commands: nc_profile [player | steamid64] (his own for everybody; others: profiles.view).

local M = NC.Module("profiles")

local IsValid = IsValid
local CurTime = CurTime
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local floor = math.floor
local max = math.max
local format = string.format
local sort = table.sort

local VERSION = 1
local STAT_NAME = "^[a-z][a-z0-9_]*$"
local IN_SUMMARY = {}
for _, name in ipairs(M.STATS) do
	IN_SUMMARY[name] = true
end

-- Unix time (specs replace it for fixed dates).
function M.Now()
	return os.time()
end

function M:_InitServer(ctx)
	self.storage = ctx:Require("storage")
	self.collection = self.storage ~= nil and self.storage:Collection(ctx.config.collection) or nil
	self.memory = {}   -- key -> record kept for the session only (bots, no storage)
	self.sessions = {} -- ply -> { key, record, counted = game time the playtime was counted last }
	ctx.commands:Add("nc_profile", { help = "[player | steamid64] - visits, playtime and statistics of a profile",
		admin = false }, "ProfileCommand")
end

function M:_StartServer(ctx)
	ctx:On("gm.PlayerInitialSpawn", "OnJoin")
	ctx:On("gm.PlayerDisconnected", "OnLeave")
	ctx:On("gm.ShutDown", "SaveAll", { priority = 100 })
	ctx:On("players.died", "OnDied")
	ctx:On("npcs.killed", "OnCreatureKilled")
	ctx:On("rounds.phase", "OnPhase")
	ctx:Every("save", ctx.config.saveInterval, "SaveAll")
	for _, ply in ipairs(player.GetAll()) do
		self:_Load(ply, false)
	end
end

function M:Stop()
	self:SaveAll()
end

-- Records ---------------------------------------------------------------------------------

function M:Key(ply)
	if self.storage ~= nil then
		return self.storage:PlayerKey(ply)
	end
	if ply:IsBot() then
		return "bot_" .. ply:Nick()
	end
	return ply:SteamID64()
end

local function persistent(self, ply)
	return self.collection ~= nil and (not ply:IsBot() or self.ctx.config.bots == true)
end

function M:IsPersistent(ply)
	return persistent(self, ply)
end

local function newRecord(now)
	local stats = {}
	for _, name in ipairs(M.STATS) do
		stats[name] = 0
	end
	return { v = VERSION, name = "", first = now, last = now, visits = 0, playtime = 0, stats = stats,
		sections = {} }
end

-- Fills what an older or a hand-edited record lacks.
local function normalize(record, now)
	record.v = VERSION
	record.first = type(record.first) == "number" and record.first or now
	record.last = type(record.last) == "number" and record.last or now
	record.visits = type(record.visits) == "number" and record.visits or 0
	record.playtime = type(record.playtime) == "number" and record.playtime or 0
	record.name = type(record.name) == "string" and record.name or ""
	record.stats = type(record.stats) == "table" and record.stats or {}
	for _, name in ipairs(M.STATS) do
		if type(record.stats[name]) ~= "number" then
			record.stats[name] = 0
		end
	end
	record.sections = type(record.sections) == "table" and record.sections or {}
	return record
end

function M:_Load(ply, visit)
	if self.sessions[ply] ~= nil or not IsValid(ply) then
		return
	end
	local key, now = self:Key(ply), M.Now()
	local record, isNew
	if persistent(self, ply) then
		record = self.collection:Get(key)
	else
		record = self.memory[key]
	end
	isNew = record == nil
	record = normalize(record or newRecord(now), now)
	if visit then
		record.visits = record.visits + 1
	end
	record.last = now
	record.name = ply:Nick()
	if persistent(self, ply) then
		self.collection:Set(key, record)
	else
		self.memory[key] = record
	end
	self.sessions[ply] = { key = key, record = record, counted = CurTime() }
	self:_Summary(ply)
	self.ctx.events:Emit("profiles.loaded", ply, record, isNew)
end

function M:OnJoin(ply)
	self:_Load(ply, true)
end

function M:OnLeave(ply)
	local session = self.sessions[ply]
	if session == nil then
		return
	end
	self:_Count(ply, session)
	session.record.last = M.Now()
	self.ctx.events:Emit("profiles.leaving", ply, session.record)
	self.sessions[ply] = nil
	if persistent(self, ply) then
		self.collection:Touch(session.key)
		self.collection:Release(session.key)
	end
end

function M:Get(ply)
	local session = self.sessions[ply]
	return session and session.record or nil
end

function M:IsLoaded(ply)
	return self.sessions[ply] ~= nil
end

-- The record of a key: a player on the server, then storage (an offline player), or nil.
function M:ByKey(key)
	for _, session in pairs(self.sessions) do
		if session.key == key then
			return session.record
		end
	end
	if self.memory[key] ~= nil then
		return self.memory[key]
	end
	if self.collection ~= nil and type(key) == "string" and key ~= "" and #key <= 80 then
		return self.collection:Get(key)
	end
	return nil
end

-- The table of module `id` in the record of `ply` (made empty on first use), or nil.
function M:Section(ply, id)
	local record = self:Get(ply)
	if record == nil then
		return nil
	end
	local section = record.sections[id]
	if type(section) ~= "table" then
		section = {}
		record.sections[id] = section
	end
	return section
end

function M:Touch(ply)
	local session = self.sessions[ply]
	if session ~= nil and persistent(self, ply) then
		self.collection:Touch(session.key)
	end
end

-- Playtime --------------------------------------------------------------------------------

function M:_Count(ply, session)
	local now = CurTime()
	local seconds = floor(max(0, now - session.counted))
	session.record.playtime = session.record.playtime + seconds
	session.counted = session.counted + seconds
	self:_Summary(ply)
end

function M:Playtime(ply)
	local session = self.sessions[ply]
	if session == nil then
		return 0
	end
	return session.record.playtime + floor(max(0, CurTime() - session.counted))
end

-- Counts the playtime of everybody on the server and marks the records for writing.
function M:SaveAll()
	for ply, session in pairs(self.sessions) do
		if IsValid(ply) then
			self:_Count(ply, session)
			session.record.last = M.Now()
			self:Touch(ply)
		end
	end
end

-- Counts the playtime of `ply` and writes his record now.
function M:Save(ply)
	local session = self.sessions[ply]
	if session == nil then
		return
	end
	self:_Count(ply, session)
	session.record.last = M.Now()
	if persistent(self, ply) then
		self.collection:Touch(session.key)
		self.collection:Flush(session.key)
	end
end

-- Statistics ------------------------------------------------------------------------------

function M:Stat(ply, name)
	local record = self:Get(ply)
	return record ~= nil and tonumber(record.stats[name]) or 0
end

function M:AddStat(ply, name, amount)
	if type(name) ~= "string" or not name:find(STAT_NAME) then
		error("profiles: AddStat: a counter name is lowercase letters, digits and _", 2)
	end
	local record = self:Get(ply)
	if record == nil then
		return nil
	end
	amount = amount or 1
	local value = (tonumber(record.stats[name]) or 0) + amount
	record.stats[name] = value
	if IN_SUMMARY[name] then
		self.ctx.components.summary:Set(ply, name, max(0, floor(value)))
	end
	self:Touch(ply)
	self.ctx.events:Emit("profiles.stat", ply, name, value, amount)
	return value
end

function M:_Summary(ply)
	local session = self.sessions[ply]
	local summary = self.ctx.components.summary
	if session == nil or not IsValid(ply) then
		return
	end
	local record = session.record
	local values = { first = record.first, visits = record.visits, playtime = record.playtime,
		since = session.counted }
	for _, name in ipairs(M.STATS) do
		values[name] = max(0, floor(record.stats[name]))
	end
	if summary:Has(ply) then
		summary:Patch(ply, values)
	else
		summary:Add(ply, values)
	end
end

function M:OnDied(ply, _, attacker)
	self:AddStat(ply, "deaths", 1)
	if IsValid(attacker) and attacker:IsPlayer() and attacker ~= ply then
		self:AddStat(attacker, "kills", 1)
	end
end

function M:OnCreatureKilled(_, attacker)
	if IsValid(attacker) and attacker:IsPlayer() then
		self:AddStat(attacker, "creatures", 1)
	end
end

-- Whether `ply` won the round that ended with `result`.
function M:Won(ply, result, round)
	local answer = self.ctx.events:Query("profiles.won", ply, result, round)
	if answer ~= nil then
		return answer == true
	end
	if result == nil then
		return false
	end
	if result.winner ~= nil then
		return result.winner == ply
	end
	return result.team ~= nil and IsValid(ply) and ply:Team() == result.team
end

function M:OnPhase(phase, _, round)
	if phase ~= "ended" or round == nil or round.result == nil then
		return
	end
	for _, ply in ipairs(round:Participants()) do
		if IsValid(ply) and self.sessions[ply] ~= nil then
			self:AddStat(ply, "rounds", 1)
			if self:Won(ply, round.result, round) then
				self:AddStat(ply, "wins", 1)
			end
		end
	end
end

-- Console ---------------------------------------------------------------------------------

local function duration(seconds)
	local hours = floor(seconds / 3600)
	local minutes = floor(seconds % 3600 / 60)
	return format("%dh %02dm", hours, minutes)
end

local function date(time)
	return os.date("%Y-%m-%d %H:%M", time)
end

-- The player or the key an argument names: nothing = the caller, a SteamID64, a player.
function M:_Target(caller, text)
	if text == nil or text == "" then
		return caller, caller ~= nil and self:Key(caller) or nil
	end
	if text:find("^%d+$") and #text >= 15 then
		for ply, session in pairs(self.sessions) do
			if session.key == text then
				return ply, text
			end
		end
		return nil, text
	end
	local lower = text:lower()
	local found, count = nil, 0
	for ply in pairs(self.sessions) do
		if IsValid(ply) then
			local nick = ply:Nick()
			if nick == text then
				return ply, self.sessions[ply].key
			end
			if nick:lower():find(lower, 1, true) ~= nil then
				found, count = ply, count + 1
			end
		end
	end
	if count == 1 then
		return found, self.sessions[found].key
	end
	return nil, nil, count == 0 and "no player matches '" .. text .. "'" or count .. " players match '" .. text .. "'"
end

function M:ProfileCommand(caller, args)
	local ply, key, problem = self:_Target(caller, args[1])
	if problem ~= nil then
		return "nc_profile: " .. problem
	end
	if key == nil then
		return "nc_profile: name a player or a SteamID64"
	end
	if caller ~= nil and ply ~= caller and not self.ctx.permissions:Can(caller, "view") then
		return "nc_profile: no access"
	end
	if ply ~= nil and self.sessions[ply] ~= nil then
		self:_Count(ply, self.sessions[ply])
	end
	local record = self:ByKey(key)
	if record == nil then
		return "nc_profile: no profile " .. key
	end
	local stats, names = record.stats, {}
	for name in pairs(stats) do
		names[#names + 1] = name
	end
	sort(names)
	local parts = {}
	for _, name in ipairs(names) do
		parts[#parts + 1] = format("%s %s", name, tostring(stats[name]))
	end
	local sections = {}
	for id in pairs(record.sections) do
		sections[#sections + 1] = id
	end
	sort(sections)
	return {
		format("profile %s (%s)%s", key, record.name, ply ~= nil and ", on the server" or ""),
		format("  first %s, last %s, visits %d, playtime %s", date(record.first), date(record.last), record.visits,
			duration(record.playtime)),
		"  stats: " .. table.concat(parts, ", "),
		"  sections: " .. (sections[1] ~= nil and table.concat(sections, ", ") or "none"),
	}
end
