-- Next-City core: event bus.
--
-- Pure Lua (LuaJIT 2.x), no GMod API.
--
--   local bus = Events.New({ onError = function(err, event, listener) ... end })
--   local h = bus:On("player.spawned", function(ply) ... end, { id = "hud", priority = 10 })
--   bus:Emit("player.spawned", ply)                     -- notify every listener
--   local allow = bus:Query("damage.canTake", ply)      -- first non-nil answer wins
--   local amount = bus:Reduce("damage.scale", 10, ply)  -- pipeline: a listener may replace the value
--   h:Off()
--
-- Higher priority runs first; equal priorities run in subscription order.
-- Listeners with the same id on the same event replace each other (like hook.Add).
-- Listener lists are copy-on-write: subscribing or unsubscribing during a dispatch is
-- safe and does not change the dispatch in progress (removed listeners are skipped);
-- a dispatch itself does not allocate (except when it drops a `once` listener).
-- In protected mode (default) a failing listener is reported via onError with a
-- traceback and does not prevent the remaining listeners from running.

local Events = {}

local type = type
local tostring = tostring
local xpcall = xpcall
local pcall = pcall
local print = print
local setmetatable = setmetatable
local traceback = debug.traceback

local EMPTY = {}

local function onListenerError(err)
	return traceback(tostring(err), 2)
end

local function defaultOnError(err, event, listener)
	print("[events] listener '" .. tostring(listener.id or "?") .. "' failed on '" .. event .. "': " .. tostring(err))
end

local Listener = {}
Listener.__index = Listener

-- Unsubscribes the listener. Returns true if it was subscribed.
function Listener:Off()
	return self.bus:Off(self)
end

function Listener:IsActive()
	return self.active
end

local Bus = {}
Bus.__index = Bus

-- opts.onError(err, eventName, listener): error handler, default prints.
-- opts.protected: false disables xpcall around listeners (errors propagate).
function Events.New(opts)
	opts = opts or {}
	assert(opts.onError == nil or type(opts.onError) == "function", "Events.New: onError must be a function")
	return setmetatable({
		lists = {},
		onError = opts.onError or defaultOnError,
		protected = opts.protected ~= false,
	}, Bus)
end

-- Returns a copy of `list` with `listener` inserted by priority (stable).
local function withListener(list, listener)
	local out = {}
	local n = 0
	local inserted = false
	for i = 1, #list do
		local current = list[i]
		if not inserted and listener.priority > current.priority then
			n = n + 1
			out[n] = listener
			inserted = true
		end
		n = n + 1
		out[n] = current
	end
	if not inserted then
		out[n + 1] = listener
	end
	return out
end

-- Returns a copy of `list` without `listener`.
local function withoutListener(list, listener)
	local out = {}
	local n = 0
	for i = 1, #list do
		local current = list[i]
		if current ~= listener then
			n = n + 1
			out[n] = current
		end
	end
	return out
end

local function findById(list, id)
	for i = 1, #list do
		if list[i].id == id then
			return list[i]
		end
	end
	return nil
end

local function remove(bus, listener)
	listener.active = false
	local list = withoutListener(bus.lists[listener.name] or EMPTY, listener)
	bus.lists[listener.name] = list[1] ~= nil and list or nil
end

-- Subscribes `fn` to `name`. opts: id (string, replaces a listener with the same id),
-- priority (number, default 0, higher runs first), once (boolean).
-- Returns a listener handle with :Off().
function Bus:On(name, fn, opts)
	assert(type(name) == "string" and name ~= "", "Events:On: event name must be a non-empty string")
	assert(type(fn) == "function", "Events:On: listener for '" .. name .. "' must be a function")

	local id, priority, once = nil, 0, false
	if opts ~= nil then
		assert(type(opts) == "table", "Events:On: opts must be a table")
		id = opts.id
		priority = opts.priority or 0
		once = opts.once == true
		assert(id == nil or type(id) == "string", "Events:On: id must be a string")
		assert(type(priority) == "number" and priority == priority, "Events:On: priority must be a number")
	end

	if id ~= nil then
		local old = findById(self.lists[name] or EMPTY, id)
		if old then
			remove(self, old)
		end
	end

	local listener = setmetatable({
		bus = self,
		name = name,
		fn = fn,
		id = id,
		priority = priority,
		once = once,
		active = true,
	}, Listener)
	self.lists[name] = withListener(self.lists[name] or EMPTY, listener)
	return listener
end

-- Unsubscribes by handle (`Off(listener)`) or by event name and id (`Off(name, id)`).
-- Returns true if a listener was removed.
function Bus:Off(target, id)
	local listener
	if type(target) == "table" then
		listener = target
		if listener.bus ~= self or not listener.active then
			return false
		end
	else
		assert(type(target) == "string", "Events:Off: expected a listener handle or an event name")
		assert(type(id) == "string", "Events:Off: expected a listener id; use Clear(name) to drop all listeners")
		listener = findById(self.lists[target] or EMPTY, id)
		if listener == nil then
			return false
		end
	end
	remove(self, listener)
	return true
end

-- Removes all listeners of `name`, or of every event when `name` is nil.
function Bus:Clear(name)
	for event, list in pairs(self.lists) do
		if name == nil or event == name then
			for i = 1, #list do
				list[i].active = false
			end
			self.lists[event] = nil
		end
	end
end

-- Returns the number of listeners of `name`, or of all events when `name` is nil.
function Bus:Count(name)
	if name ~= nil then
		local list = self.lists[name]
		return list and #list or 0
	end
	local total = 0
	for _, list in pairs(self.lists) do
		total = total + #list
	end
	return total
end

local function report(bus, listener, err)
	local ok, handlerErr = pcall(bus.onError, err, listener.name, listener)
	if not ok then
		print("[events] onError failed: " .. tostring(handlerErr) .. "\n" .. tostring(err))
	end
end

-- Calls every listener of `name` with the arguments.
function Bus:Emit(name, ...)
	local list = self.lists[name]
	if list == nil then
		return
	end
	local protected = self.protected
	for i = 1, #list do
		local listener = list[i]
		if listener.active then
			if listener.once then
				remove(self, listener)
			end
			if protected then
				local ok, err = xpcall(listener.fn, onListenerError, ...)
				if not ok then
					report(self, listener, err)
				end
			else
				listener.fn(...)
			end
		end
	end
end

-- Calls listeners in order until one returns a non-nil first value; returns up to
-- four values of that listener (like a GMod hook returning a decision).
function Bus:Query(name, ...)
	local list = self.lists[name]
	if list == nil then
		return nil
	end
	local protected = self.protected
	for i = 1, #list do
		local listener = list[i]
		if listener.active then
			if listener.once then
				remove(self, listener)
			end
			local ok, a, b, c, d = true, nil, nil, nil, nil
			if protected then
				ok, a, b, c, d = xpcall(listener.fn, onListenerError, ...)
				if not ok then
					report(self, listener, a)
				end
			else
				a, b, c, d = listener.fn(...)
			end
			if ok and a ~= nil then
				return a, b, c, d
			end
		end
	end
	return nil
end

-- Passes `value` through every listener as fn(value, ...); a non-nil result replaces
-- the value. Returns the final value.
function Bus:Reduce(name, value, ...)
	local list = self.lists[name]
	if list == nil then
		return value
	end
	local protected = self.protected
	for i = 1, #list do
		local listener = list[i]
		if listener.active then
			if listener.once then
				remove(self, listener)
			end
			local ok, result = true, nil
			if protected then
				ok, result = xpcall(listener.fn, onListenerError, value, ...)
				if not ok then
					report(self, listener, result)
				end
			else
				result = listener.fn(value, ...)
			end
			if ok and result ~= nil then
				value = result
			end
		end
	end
	return value
end

return Events
