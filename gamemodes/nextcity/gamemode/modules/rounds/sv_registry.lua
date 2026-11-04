-- Rounds module, server part: the registry of modes and rule blocks.
--
-- A mode or a rule is a table of settings and callbacks (docs/ARCHITECTURE.md, section 11).
-- Unknown keys are errors, so a misspelt callback does not go unnoticed. Pass the context
-- of the registering module: its modes and rules go away when that module stops.
--
--   local rounds = ctx:Require("rounds")
--   rounds:RegisterRule({ id = "time_limit", params = { ... }, Start = function(round) end }, ctx)
--   rounds:RegisterMode({ id = "tdm", name = "mode_tdm.name", minPlayers = 2,
--   	rules = { "time_limit" }, params = { ... }, Loadout = function(round, ply) end }, ctx)
--
-- Parameters of a mode are the parameters of its rules and its own (the same name in a
-- later set wins, so a mode can change the default of a rule parameter). Values for a
-- round: defaults, then config params[mode], then overrides from the console.

local M = NC.Module("rounds")

local Params = NC.Lib.Params

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local format = string.format
local concat = table.concat
local floor = math.floor

local ID_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_ID = 32
local MAX_NAME = 64
local EMPTY = {}

-- Notifications: every rule in the order of the mode, then the mode.
M.LIFECYCLE = {
	"Setup",         -- (round) preparing, before participants are added
	"PlayerAdded",   -- (round, ply) a participant joins (round start or late join), before spawning
	"Start",         -- (round) the round becomes active
	"Think",         -- (round) while active, thinkRate times a second
	"PlayerSpawned", -- (round, ply) a participant is in the world
	"Loadout",       -- (round, ply) equipment of a spawning participant
	"PlayerDied",    -- (round, ply, inflictor, attacker) attacker and inflictor may be nil
	"PlayerLeft",    -- (round, ply) a participant disconnected
	"End",           -- (round, result) the round ended
	"Cleanup",       -- (round) the round is over; always follows Setup, also when it is aborted
}

-- Questions: the mode first, then the rules in order; the first non-nil answer wins.
M.QUESTIONS = {
	"Participants",     -- (round, ready) -> players to take part; default: every ready player
	"LateJoin",         -- (round, ply) -> may a player that became ready join; default: while preparing
	"SpawnPoint",       -- (round, ply) -> an answer to players.spawnPoint (entity, { pos, ang }, group)
	"CheckWin",         -- (round) -> a result to end the round with
	"Timeout",          -- (round) -> the result when time is up; default { reason = "time" }
	"ShouldTakeDamage", -- (round, ply, attacker) -> boolean
}

local CALLBACKS = {}
for _, name in ipairs(M.LIFECYCLE) do
	CALLBACKS[name] = true
end
for _, name in ipairs(M.QUESTIONS) do
	CALLBACKS[name] = true
end

local MODE_FIELDS = {
	id = "string", name = "string", description = "string", minPlayers = "number", thinkRate = "number",
	params = "table", rules = "table",
}
local RULE_FIELDS = { id = "string", description = "string", params = "table" }

function M:_InitRegistry()
	self.modes = {}
	self.rules = {}
	self.overrides = {} -- [mode] = { [param] = value } from the console
	self.version = 0    -- bumped by every registration, invalidates merged parameter sets
end

local function isId(value)
	return type(value) == "string" and #value <= MAX_ID and value:find(ID_PATTERN) ~= nil
end

local function checkDef(kind, def, fields)
	if type(def) ~= "table" then
		error(kind .. " definition must be a table", 3)
	end
	local id = def.id
	if not isId(id) then
		error(format("%s id must match %s and be at most %d characters, got %s", kind, ID_PATTERN, MAX_ID,
			tostring(id)), 3)
	end
	for key, value in pairs(def) do
		local expected = fields[key]
		if expected ~= nil then
			if type(value) ~= expected then
				error(format("%s '%s': '%s' must be a %s, got %s", kind, id, tostring(key), expected, type(value)), 3)
			end
		elseif CALLBACKS[key] then
			if type(value) ~= "function" then
				error(format("%s '%s': callback '%s' must be a function", kind, id, key), 3)
			end
		else
			error(format("%s '%s': unknown key '%s'", kind, id, tostring(key)), 3)
		end
	end
	return id
end

local function checkOwner(kind, id, owner)
	if owner ~= nil and (type(owner) ~= "table" or type(owner.IsAlive) ~= "function") then
		error(format("%s '%s': the owner must be the module context (ctx)", kind, id), 3)
	end
end

local function defineParams(kind, id, spec)
	local ok, set = pcall(Params.Define, spec or EMPTY)
	if not ok then
		error(format("%s '%s': %s", kind, id, tostring(set)), 3)
	end
	return set
end

local function isAlive(entry)
	return entry.owner == nil or entry.owner:IsAlive()
end

local function store(self, kind, map, entry)
	local previous = map[entry.id]
	if previous ~= nil and previous.owner ~= nil and previous.owner ~= entry.owner and previous.owner:IsAlive() then
		error(format("%s '%s' is already registered by module '%s'", kind, entry.id, tostring(previous.owner.id)), 3)
	end
	map[entry.id] = entry
	self.version = self.version + 1
end

-- Registers a rule block: { id, description, params, callbacks... }. owner: ctx of the
-- registering module. Returns the registry entry.
function M:RegisterRule(def, owner)
	local id = checkDef("rule", def, RULE_FIELDS)
	checkOwner("rule", id, owner)
	local entry = {
		id = id,
		def = def,
		description = def.description or "",
		params = defineParams("rule", id, def.params),
		owner = owner,
	}
	store(self, "rule", self.rules, entry)
	return entry
end

-- Registers a mode: { id, name, description, minPlayers (1), thinkRate (2 a second),
-- rules, params, callbacks... }. name is a translation key or plain text (default: id).
-- owner: ctx of the registering module. Returns the registry entry.
function M:RegisterMode(def, owner)
	local id = checkDef("mode", def, MODE_FIELDS)
	checkOwner("mode", id, owner)
	local name = def.name or id
	if #name == 0 or #name > MAX_NAME then
		error(format("mode '%s': name must be 1..%d bytes", id, MAX_NAME), 2)
	end
	local minPlayers = def.minPlayers or 1
	if minPlayers ~= floor(minPlayers) or minPlayers < 1 or minPlayers > 255 then
		error(format("mode '%s': minPlayers must be an integer 1..255", id), 2)
	end
	local thinkRate = def.thinkRate or 2
	if not (thinkRate > 0 and thinkRate <= 100) then
		error(format("mode '%s': thinkRate must be within 0..100 times a second", id), 2)
	end
	local rules, seen = {}, {}
	for key, ruleId in pairs(def.rules or EMPTY) do
		if type(key) ~= "number" or not isId(ruleId) then
			error(format("mode '%s': rules must be an array of rule ids", id), 2)
		end
		if seen[ruleId] then
			error(format("mode '%s': rule '%s' is listed twice", id, ruleId), 2)
		end
		seen[ruleId] = true
	end
	for i = 1, #(def.rules or EMPTY) do
		rules[i] = def.rules[i]
	end
	local entry = {
		id = id,
		def = def,
		name = name,
		description = def.description or "",
		minPlayers = minPlayers,
		thinkInterval = 1 / thinkRate,
		rules = rules,
		params = defineParams("mode", id, def.params),
		owner = owner,
	}
	store(self, "mode", self.modes, entry)
	return entry
end

-- Registry entry of a mode or a rule (do not modify).
function M:Mode(id)
	return self.modes[id]
end

function M:Rule(id)
	return self.rules[id]
end

local function sortedIds(map)
	local ids = {}
	for id in pairs(map) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

-- Ids of registered modes and rules, sorted.
function M:Modes()
	return sortedIds(self.modes)
end

function M:Rules()
	return sortedIds(self.rules)
end

-- True if a mode can be played: registered, and its module and the modules of its
-- rules run. Otherwise false and the reason.
function M:IsAvailable(id)
	local entry = self.modes[id]
	if entry == nil then
		return false, "not registered"
	end
	if not isAlive(entry) then
		return false, format("module '%s' is stopped", tostring(entry.owner.id))
	end
	for _, ruleId in ipairs(entry.rules) do
		local rule = self.rules[ruleId]
		if rule == nil then
			return false, format("rule '%s' is not registered", ruleId)
		end
		if not isAlive(rule) then
			return false, format("rule '%s': module '%s' is stopped", ruleId, tostring(rule.owner.id))
		end
	end
	return true
end

-- Parameter set of a mode with the parameters of its rules (nil for an unknown mode).
function M:ParamSet(id)
	local entry = self.modes[id]
	if entry == nil then
		return nil
	end
	if entry.paramVersion ~= self.version then
		local sets = {}
		for _, ruleId in ipairs(entry.rules) do
			local rule = self.rules[ruleId]
			if rule ~= nil then
				sets[#sets + 1] = rule.params
			end
		end
		sets[#sets + 1] = entry.params
		local set, conflicts = Params.Merge(sets)
		if conflicts[1] ~= nil then
			self.ctx.log:Warn("mode '%s': params declared with different types: %s", id, concat(conflicts, ", "))
		end
		entry.paramSet, entry.paramVersion, entry.warned = set, self.version, false
	end
	return entry.paramSet
end

-- Parameter values for a round of a mode: defaults, config params, console overrides.
-- Problems in the config are logged once per change. nil for an unknown mode.
function M:ResolveParams(id)
	local set = self:ParamSet(id)
	if set == nil then
		return nil
	end
	local values = {}
	local configured = self.settings.params[id]
	if type(configured) == "table" then
		for key, value in pairs(configured) do
			values[key] = value
		end
	end
	for key, value in pairs(self.overrides[id] or EMPTY) do
		values[key] = value
	end
	local entry = self.modes[id]
	local warn
	if not entry.warned then
		entry.warned = true
		local log = self.ctx.log
		warn = function(message)
			log:Warn("config params of mode '%s': %s", id, message)
		end
	end
	return set:Resolve(values, warn)
end

-- Overrides a parameter of a mode from the next round on. Returns the value in use and
-- a description of what was fixed (nil if nothing), or nil and an error.
function M:SetParam(id, name, value)
	local set = self:ParamSet(id)
	if set == nil then
		return nil, format("unknown mode '%s'", tostring(id))
	end
	if not set:Has(name) then
		return nil, format("mode '%s' has no param '%s'", id, tostring(name))
	end
	local fixed, problem = set:Coerce(name, value)
	local overrides = self.overrides[id] or {}
	self.overrides[id] = overrides
	overrides[name] = fixed
	return fixed, problem
end

-- Drops a console override (every override of the mode without a name).
function M:ResetParam(id, name)
	local overrides = self.overrides[id]
	if overrides == nil then
		return
	end
	if name == nil then
		self.overrides[id] = nil
	else
		overrides[name] = nil
	end
end

-- Console overrides of a mode (do not modify).
function M:Overrides(id)
	return self.overrides[id] or EMPTY
end
