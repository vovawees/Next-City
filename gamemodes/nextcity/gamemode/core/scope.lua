-- Next-City core: lifetime scopes.
--
-- Pure Lua (LuaJIT 2.x), no GMod API.
--
-- A scope owns event listeners, periodic jobs, timers and cleanup callbacks and releases
-- them together. Module contexts are built on scopes; the round system gives every round
-- its own scope, so the subscriptions of a mode and its rules end with the round.
--
--   local scope = Scope.New({ id = "rounds:round", events = bus, scheduler = sched })
--   scope:On("players.died", fn, { priority = 10 }) -- listener "rounds:round:#1"
--   scope:On("players.left", fn, { id = "left" })   -- listener "rounds:round:left"
--   scope:Every("think", 1, fn)                      -- job "rounds:round:think"
--   scope:After(5, fn)                               -- timer tagged "rounds:round"
--   scope:Defer(fn)                                  -- runs on Dispose, the last added first
--   local child = scope:Child("tdm")                 -- "rounds:round/tdm", released with the parent
--   scope:Dispose()                                  -- idempotent
--
-- Dispose releases children first (the newest first), then listeners, jobs and timers,
-- then runs deferred callbacks. Deferred callbacks are protected: an error goes to
-- opts.onError(err, scope) (default: print) and the rest still run.

local Scope = {}

local type = type
local tostring = tostring
local pairs = pairs
local xpcall = xpcall
local print = print
local setmetatable = setmetatable
local format = string.format
local traceback = debug.traceback

local COMPACT_MIN = 32

local Instance = {}
Instance.__index = Instance

local function onDeferredError(err)
	return traceback(tostring(err), 2)
end

local function checkAlive(scope, what)
	if not scope.alive then
		error(format("scope '%s': %s after Dispose", scope.id, what), 3)
	end
end

-- Drops released handles from a long-lived list so it does not grow without bound
-- (e.g. a listener re-subscribed with the same id every round).
local function remember(scope, list, handle)
	list[#list + 1] = handle
	if #list < scope.compactAt then
		return
	end
	local kept = 0
	for i = 1, #list do
		local item = list[i]
		list[i] = nil
		if item:IsActive() then
			kept = kept + 1
			list[kept] = item
		end
	end
	scope.compactAt = kept * 2 > COMPACT_MIN and kept * 2 or COMPACT_MIN
end

-- opts: id (prefix of listener and job ids, timer tag), events, scheduler, onError.
function Scope.New(opts)
	opts = opts or {}
	assert(type(opts.id) == "string" and opts.id ~= "", "Scope.New: id must be a non-empty string")
	assert(opts.onError == nil or type(opts.onError) == "function", "Scope.New: onError must be a function")
	return setmetatable({
		id = opts.id,
		events = opts.events,
		scheduler = opts.scheduler,
		onError = opts.onError,
		parent = nil,
		alive = true,
		seq = 0,
		compactAt = COMPACT_MIN,
		listeners = {},
		jobs = {},
		timers = {},
		deferred = {},
		children = {},
	}, Instance)
end

function Instance:IsAlive()
	return self.alive
end

-- Subscribes fn to an event. opts: id (default "#<n>"; the same id replaces the
-- previous listener), priority, once. Returns the listener handle.
function Instance:On(event, fn, opts)
	checkAlive(self, "On('" .. tostring(event) .. "')")
	assert(self.events ~= nil, "scope:On: no event bus")
	local id = opts and opts.id
	if id == nil then
		self.seq = self.seq + 1
		id = "#" .. self.seq
	end
	assert(type(id) == "string", "scope:On: id must be a string")
	local listener = self.events:On(event, fn, {
		id = self.id .. ":" .. id,
		priority = opts and opts.priority,
		once = opts and opts.once,
	})
	remember(self, self.listeners, listener)
	return listener
end

-- Registers the periodic job "<scope id>:<id>" (see Scheduler:Every for opts).
function Instance:Every(id, interval, fn, opts)
	checkAlive(self, "Every('" .. tostring(id) .. "')")
	assert(self.scheduler ~= nil, "scope:Every: no scheduler")
	assert(type(id) == "string" and id ~= "", "scope:Every: id must be a non-empty string")
	local job = self.scheduler:Every(self.id .. ":" .. id, interval, fn, opts)
	remember(self, self.jobs, job)
	return job
end

-- Runs fn(now) once after delay seconds unless the scope is disposed first.
function Instance:After(delay, fn)
	checkAlive(self, "After")
	assert(self.scheduler ~= nil, "scope:After: no scheduler")
	assert(type(fn) == "function", "scope:After: callback must be a function")
	local timers = self.timers
	local timer
	timer = self.scheduler:After(delay, function(now)
		timers[timer] = nil
		return fn(now)
	end, self.id)
	timers[timer] = true
	return timer
end

-- Runs fn(scope) on Dispose; callbacks run in reverse order of registration.
function Instance:Defer(fn)
	checkAlive(self, "Defer")
	assert(type(fn) == "function", "scope:Defer: callback must be a function")
	local deferred = self.deferred
	deferred[#deferred + 1] = fn
	return fn
end

-- Creates a scope "<id>/<name>" with the same services, released with this one
-- (it may also be disposed earlier on its own).
function Instance:Child(name)
	checkAlive(self, "Child('" .. tostring(name) .. "')")
	assert(type(name) == "string" and name ~= "", "scope:Child: name must be a non-empty string")
	local child = Scope.New({
		id = self.id .. "/" .. name,
		events = self.events,
		scheduler = self.scheduler,
		onError = self.onError,
	})
	child.parent = self
	self.children[child] = true
	self.children[#self.children + 1] = child
	return child
end

local function report(scope, err)
	if scope.onError ~= nil then
		scope.onError(err, scope)
	else
		print(format("[scope] '%s': deferred callback failed: %s", scope.id, tostring(err)))
	end
end

function Instance:Dispose()
	if not self.alive then
		return
	end
	self.alive = false
	local children = self.children
	for i = #children, 1, -1 do
		local child = children[i]
		if children[child] then
			child:Dispose()
		end
	end
	local listeners = self.listeners
	for i = #listeners, 1, -1 do
		listeners[i]:Off()
	end
	local jobs = self.jobs
	for i = #jobs, 1, -1 do
		self.scheduler:Remove(jobs[i])
	end
	for timer in pairs(self.timers) do
		timer:Cancel()
	end
	local deferred = self.deferred
	self.children, self.listeners, self.jobs, self.timers, self.deferred = {}, {}, {}, {}, {}
	for i = #deferred, 1, -1 do
		local ok, err = xpcall(deferred[i], onDeferredError, self)
		if not ok then
			report(self, err)
		end
	end
	local parent = self.parent
	if parent ~= nil and parent.children[self] then
		parent.children[self] = nil
		local list = parent.children
		for i = #list, 1, -1 do
			if list[i] == self then
				table.remove(list, i)
				break
			end
		end
	end
end

return Scope
