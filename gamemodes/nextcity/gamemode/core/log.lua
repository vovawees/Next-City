-- Next-City core: leveled, tagged logger with lazy formatting.
--
-- Pure Lua (LuaJIT 2.x), no GMod API. Loggers form a tree: a child inherits
-- the level and the sink of its parent until it gets its own.
--
--   local log = Log.New("core", { level = "info", sink = mySink })
--   local child = log:Child("organism")
--   child:Debug("pulse %d", bpm)                -- nothing is formatted below the level
--   child:Debug(function() return Dump(x) end)  -- expensive messages are built lazily
--
-- A sink is `function(levelName, tag, message)`. Logging never throws: broken
-- format strings and failing sinks are reported instead of crashing the caller.

local Log = {}

local format = string.format
local select = select
local tostring = tostring
local type = type
local pcall = pcall
local print = print
local unpack = unpack
local concat = table.concat

local LEVELS = { trace = 1, debug = 2, info = 3, warn = 4, error = 5, off = 6 }
local NAMES = { "trace", "debug", "info", "warn", "error", "off" }

Log.LEVELS = LEVELS
Log.NAMES = NAMES

-- Returns the numeric level for a level name or number, or nil if unknown.
function Log.ParseLevel(level)
	if type(level) == "number" then
		return NAMES[level] and level or nil
	end
	if type(level) == "string" then
		return LEVELS[level:lower()]
	end
	return nil
end

local function defaultSink(levelName, tag, message)
	print(format("[%s] %s: %s", tag, levelName:upper(), message))
end

Log.DefaultSink = defaultSink

local function safeArgs(...)
	local n = select("#", ...)
	local out = {}
	for i = 1, n do
		local v = select(i, ...)
		out[i] = type(v) == "number" and v or tostring(v)
	end
	return out, n
end

local function render(fmt, ...)
	if type(fmt) == "function" then
		local ok, result = pcall(fmt, ...)
		if ok then
			return tostring(result)
		end
		return "<log message function failed: " .. tostring(result) .. ">"
	end

	if select("#", ...) == 0 then
		return tostring(fmt)
	end

	local ok, result = pcall(format, tostring(fmt), ...)
	if ok then
		return result
	end

	local args, n = safeArgs(...)
	ok, result = pcall(format, tostring(fmt), unpack(args, 1, n))
	if ok then
		return result
	end

	for i = 1, n do
		args[i] = tostring(args[i])
	end
	return tostring(fmt) .. " <bad format: " .. concat(args, ", ", 1, n) .. ">"
end

Log.Render = render

local Logger = {}
Logger.__index = Logger

local function newLogger(tag, parent, level, sink)
	return setmetatable({ tag = tag, parent = parent, level = level, sink = sink }, Logger)
end

-- Creates a root logger. opts: level (name or number, default "info"), sink.
function Log.New(tag, opts)
	opts = opts or {}
	local level = Log.ParseLevel(opts.level or "info")
	assert(level, "Log.New: unknown level '" .. tostring(opts.level) .. "'")
	assert(opts.sink == nil or type(opts.sink) == "function", "Log.New: sink must be a function")
	return newLogger(tostring(tag or "log"), nil, level, opts.sink or defaultSink)
end

-- Creates a child logger that inherits level and sink until overridden.
function Logger:Child(tag)
	return newLogger(tostring(tag), self, nil, nil)
end

-- Sets own level; nil makes the logger inherit the parent level again.
function Logger:SetLevel(level)
	if level == nil and self.parent then
		self.level = nil
		return
	end
	local parsed = Log.ParseLevel(level)
	assert(parsed, "Logger:SetLevel: unknown level '" .. tostring(level) .. "'")
	self.level = parsed
end

local function effectiveLevel(logger)
	while logger.level == nil do
		logger = logger.parent
	end
	return logger.level
end

local function effectiveSink(logger)
	while logger.sink == nil do
		logger = logger.parent
	end
	return logger.sink
end

function Logger:GetLevel()
	return NAMES[effectiveLevel(self)]
end

-- Sets own sink; nil makes the logger inherit the parent sink again.
function Logger:SetSink(sink)
	assert(sink == nil or type(sink) == "function", "Logger:SetSink: sink must be a function")
	if sink == nil and not self.parent then
		sink = defaultSink
	end
	self.sink = sink
end

function Logger:IsEnabled(level)
	local parsed = Log.ParseLevel(level)
	return parsed ~= nil and parsed < LEVELS.off and parsed >= effectiveLevel(self)
end

local function write(logger, level, fmt, ...)
	if level < effectiveLevel(logger) then
		return
	end
	local message = render(fmt, ...)
	local ok, err = pcall(effectiveSink(logger), NAMES[level], logger.tag, message)
	if not ok then
		defaultSink(NAMES[level], logger.tag, message)
		defaultSink("error", logger.tag, "log sink failed: " .. tostring(err))
	end
end

-- Logs at an explicit level (name or number).
function Logger:Log(level, fmt, ...)
	local parsed = Log.ParseLevel(level)
	if parsed and parsed < LEVELS.off then
		write(self, parsed, fmt, ...)
	end
end

function Logger:Trace(fmt, ...) write(self, 1, fmt, ...) end
function Logger:Debug(fmt, ...) write(self, 2, fmt, ...) end
function Logger:Info(fmt, ...) write(self, 3, fmt, ...) end
function Logger:Warn(fmt, ...) write(self, 4, fmt, ...) end
function Logger:Error(fmt, ...) write(self, 5, fmt, ...) end

-- A logger that discards everything; a safe default for libraries and tests.
local function noop() end

local nullLogger = { tag = "null" }
for _, name in ipairs({ "Log", "Trace", "Debug", "Info", "Warn", "Error", "SetLevel", "SetSink" }) do
	nullLogger[name] = noop
end
function nullLogger:Child() return self end
function nullLogger:GetLevel() return "off" end
function nullLogger:IsEnabled() return false end

Log.Null = nullLogger

return Log
