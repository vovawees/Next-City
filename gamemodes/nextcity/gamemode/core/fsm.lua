-- Next-City core: finite state machine with whitelisted transitions.
--
-- Pure Lua (LuaJIT 2.x), no GMod API.
--
--   local round = FSM.New({
--   	initial = "waiting",
--   	states = {
--   		waiting = { to = { "playing" } },
--   		playing = {
--   			to = { "ended" },
--   			enter = function(fsm, from, ...) end,
--   			update = function(fsm, ...) end,
--   			exit = function(fsm, to) end,
--   		},
--   		ended = { to = { "waiting" } },
--   	},
--   	any = { "aborted" },                    -- optional: reachable from every other state
--   	onChange = function(fsm, from, to) end, -- optional
--   	onError = function(err, fsm) end,       -- optional, default prints
--   }, owner)
--   round:Go("playing", extraArgsForEnter)
--
-- Run-to-completion: a transition requested from inside a callback is queued and runs
-- after the current one completes, so callbacks always observe a consistent state.
-- More than MAX_CHAIN chained transitions are treated as a loop and dropped.
-- Callbacks are protected: an error is reported and the transition still completes.

local FSM = {}

local type = type
local tostring = tostring
local select = select
local unpack = unpack
local xpcall = xpcall
local pcall = pcall
local print = print
local setmetatable = setmetatable
local traceback = debug.traceback

local MAX_CHAIN = 64
FSM.MAX_CHAIN = MAX_CHAIN

local CALLBACKS = { "enter", "exit", "update" }

local function onCallbackError(err)
	return traceback(tostring(err), 2)
end

local function report(fsm, err)
	local handler = fsm.onError
	if handler then
		local ok, handlerErr = pcall(handler, err, fsm)
		if ok then
			return
		end
		err = tostring(err) .. "\n(onError failed: " .. tostring(handlerErr) .. ")"
	end
	print("[fsm] " .. tostring(err))
end

local function call(fsm, fn, ...)
	if fn == nil then
		return
	end
	local ok, err = xpcall(fn, onCallbackError, ...)
	if not ok then
		report(fsm, err)
	end
end

local function targetSet(states, owner, list, field)
	local set = {}
	if list == nil then
		return set
	end
	assert(type(list) == "table", "FSM.New: '" .. field .. "' of '" .. owner .. "' must be an array of state names")
	for i = 1, #list do
		local target = list[i]
		assert(states[target] ~= nil,
			"FSM.New: '" .. field .. "' of '" .. owner .. "' references unknown state '" .. tostring(target) .. "'")
		set[target] = true
	end
	return set
end

local Machine = {}
Machine.__index = Machine

local function transition(fsm, to, ...)
	if not fsm:CanGo(to) then
		return false, "transition '" .. fsm.state .. "' -> '" .. tostring(to) .. "' is not allowed"
	end
	local from = fsm.state
	local states = fsm.states
	fsm.busy = true
	call(fsm, states[from].exit, fsm, to)
	fsm.previous = from
	fsm.state = to
	call(fsm, states[to].enter, fsm, from, ...)
	call(fsm, fsm.onChange, fsm, from, to)
	fsm.busy = false
	return true
end

local function drain(fsm)
	local queue = fsm.queue
	local chain = 0
	while queue[1] ~= nil do
		chain = chain + 1
		if chain > MAX_CHAIN then
			fsm.queue = {}
			report(fsm, "more than " .. MAX_CHAIN .. " chained transitions in state '" .. fsm.state ..
				"', probably a loop; pending transitions dropped")
			return
		end
		local entry = table.remove(queue, 1)
		local ok, err = transition(fsm, entry.to, unpack(entry, 1, entry.n))
		if not ok then
			report(fsm, err)
		end
	end
end

-- Creates a machine and enters the initial state: enter(fsm, nil).
function FSM.New(def, owner)
	assert(type(def) == "table", "FSM.New: definition must be a table")
	assert(type(def.states) == "table", "FSM.New: 'states' must be a table")
	assert(def.onChange == nil or type(def.onChange) == "function", "FSM.New: onChange must be a function")
	assert(def.onError == nil or type(def.onError) == "function", "FSM.New: onError must be a function")

	local states = {}
	for name, state in pairs(def.states) do
		assert(type(name) == "string" and name ~= "", "FSM.New: state names must be non-empty strings")
		assert(type(state) == "table", "FSM.New: state '" .. name .. "' must be a table")
		for i = 1, #CALLBACKS do
			local key = CALLBACKS[i]
			assert(state[key] == nil or type(state[key]) == "function",
				"FSM.New: '" .. key .. "' of state '" .. name .. "' must be a function")
		end
		states[name] = state
	end
	assert(type(def.initial) == "string" and states[def.initial] ~= nil,
		"FSM.New: unknown initial state '" .. tostring(def.initial) .. "'")

	local allowed = {}
	for name, state in pairs(states) do
		allowed[name] = targetSet(states, name, state.to, "to")
	end

	local fsm = setmetatable({
		owner = owner,
		states = states,
		allowed = allowed,
		any = targetSet(states, "machine", def.any, "any"),
		onChange = def.onChange,
		onError = def.onError,
		state = def.initial,
		previous = nil,
		busy = true,
		queue = {},
	}, Machine)
	call(fsm, states[def.initial].enter, fsm, nil)
	fsm.busy = false
	drain(fsm)
	return fsm
end

function Machine:Get()
	return self.state
end

function Machine:Is(name)
	return self.state == name
end

function Machine:Previous()
	return self.previous
end

-- True if `to` is whitelisted from the current state (`any` never allows a self-loop).
function Machine:CanGo(to)
	if self.allowed[self.state][to] then
		return true
	end
	return to ~= self.state and self.any[to] == true
end

-- Switches to `to`, passing extra arguments to its enter callback.
-- Returns true on success, false and a reason if the transition is not allowed,
-- or true and "queued" when called from inside a callback.
function Machine:Go(to, ...)
	if self.busy then
		local queue = self.queue
		queue[#queue + 1] = { to = to, n = select("#", ...), ... }
		return true, "queued"
	end
	local ok, err = transition(self, to, ...)
	drain(self)
	return ok, err
end

-- Runs the update callback of the current state. Returns false if called re-entrantly.
function Machine:Update(...)
	if self.busy then
		return false
	end
	local update = self.states[self.state].update
	if update ~= nil then
		self.busy = true
		call(self, update, self, ...)
		self.busy = false
		drain(self)
	end
	return true
end

return FSM
