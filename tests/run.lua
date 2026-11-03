-- Next-City test runner: zero dependencies, plain LuaJIT, no GMod.
--
--   luajit tests/run.lua           -- every spec
--   luajit tests/run.lua events    -- only specs whose path contains "events"
--
-- Specs use the globals describe / it / expect and the helper table T:
--   T.root            repository root with a trailing slash
--   T.gamemode        path of gamemodes/nextcity/gamemode/
--   T.load(path)      runs a gamemode file (e.g. "core/events.lua") and returns its result;
--                     every call returns a fresh copy

local SPECS = {
	"tests/unit/runner_spec.lua",
	"tests/unit/log_spec.lua",
	"tests/unit/events_spec.lua",
	"tests/unit/scheduler_spec.lua",
	"tests/unit/fsm_spec.lua",
	"tests/unit/modules_spec.lua",
}

local source = debug.getinfo(1, "S").source
local root = source:match("^@(.-)tests[/\\]run%.lua$") or ""
if root ~= "" and not root:find("[/\\]$") then
	root = root .. "/"
end

T = {
	root = root,
	gamemode = root .. "gamemodes/nextcity/gamemode/",
}

function T.load(path, ...)
	local fn, err = loadfile(T.gamemode .. path)
	if not fn then
		error(err, 2)
	end
	return fn(...)
end

-- Value formatting for messages ------------------------------------------------------

local function inspect(value, depth)
	depth = depth or 0
	if type(value) == "string" then
		return string.format("%q", value)
	end
	if type(value) ~= "table" then
		return tostring(value)
	end
	if next(value) == nil then
		return "{}"
	end
	if depth >= 3 then
		return "{...}"
	end
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "number" or ta == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	if #keys == #value then
		for i = 1, #value do
			if i > 12 then
				parts[#parts + 1] = "..."
				break
			end
			parts[i] = inspect(value[i], depth + 1)
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	for i, key in ipairs(keys) do
		if i > 12 then
			parts[#parts + 1] = "..."
			break
		end
		local label = type(key) == "string" and key:find("^[%a_][%w_]*$") and key or ("[" .. inspect(key, depth + 1) .. "]")
		parts[#parts + 1] = label .. " = " .. inspect(value[key], depth + 1)
	end
	return "{ " .. table.concat(parts, ", ") .. " }"
end

T.inspect = inspect

local function deepEqual(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- expect -----------------------------------------------------------------------------

local Expect = {}
Expect.__index = Expect

local function check(ok, message)
	if not ok then
		error(message, 3)
	end
end

function expect(value)
	return setmetatable({ value = value }, Expect)
end

function Expect:toBe(expected)
	check(self.value == expected, "expected " .. inspect(expected) .. ", got " .. inspect(self.value))
end

function Expect:notToBe(unexpected)
	check(self.value ~= unexpected, "expected a value other than " .. inspect(unexpected))
end

function Expect:toEqual(expected)
	check(deepEqual(self.value, expected), "expected " .. inspect(expected) .. ", got " .. inspect(self.value))
end

function Expect:toBeTruthy()
	check(self.value, "expected a truthy value, got " .. inspect(self.value))
end

function Expect:toBeFalsy()
	check(not self.value, "expected a falsy value, got " .. inspect(self.value))
end

function Expect:toBeNil()
	check(self.value == nil, "expected nil, got " .. inspect(self.value))
end

function Expect:toBeCloseTo(expected, epsilon)
	epsilon = epsilon or 1e-9
	check(type(self.value) == "number" and math.abs(self.value - expected) <= epsilon,
		"expected " .. tostring(expected) .. " +- " .. tostring(epsilon) .. ", got " .. inspect(self.value))
end

-- Strings: contains the plain fragment. Tables: contains the value as an array element.
function Expect:toContain(item)
	local value = self.value
	if type(value) == "string" then
		check(value:find(item, 1, true) ~= nil, "expected " .. inspect(value) .. " to contain " .. inspect(item))
		return
	end
	check(type(value) == "table", "expected a string or a table, got " .. inspect(value))
	for i = 1, #value do
		if deepEqual(value[i], item) then
			return
		end
	end
	check(false, "expected " .. inspect(value) .. " to contain " .. inspect(item))
end

-- The value must be a function that raises an error containing `fragment` (if given).
function Expect:toFail(fragment)
	check(type(self.value) == "function", "expected a function, got " .. inspect(self.value))
	local ok, err = pcall(self.value)
	check(not ok, "expected the function to fail")
	if fragment ~= nil then
		check(tostring(err):find(fragment, 1, true) ~= nil,
			"expected error containing " .. inspect(fragment) .. ", got " .. inspect(tostring(err)))
	end
end

-- describe / it ----------------------------------------------------------------------

local stats = { passed = 0, failed = 0 }
local failures = {}
local scope = {}
local currentSpec = nil

function describe(name, fn)
	scope[#scope + 1] = name
	fn()
	scope[#scope] = nil
end

local function onTestError(err)
	return debug.traceback(tostring(err), 2)
end

function it(name, fn)
	local title = table.concat(scope, " > ") .. (scope[1] and " > " or "") .. name
	local ok, err = xpcall(fn, onTestError)
	if ok then
		stats.passed = stats.passed + 1
	else
		stats.failed = stats.failed + 1
		failures[#failures + 1] = { spec = currentSpec, title = title, err = err }
	end
end

-- main -------------------------------------------------------------------------------

local filter = arg and arg[1]
local started = os.clock()
local ran = 0

for _, spec in ipairs(SPECS) do
	if filter == nil or spec:find(filter, 1, true) then
		ran = ran + 1
		currentSpec = spec
		local fn, err = loadfile(root .. spec)
		if not fn then
			stats.failed = stats.failed + 1
			failures[#failures + 1] = { spec = spec, title = "(load)", err = err }
		else
			local ok, runErr = xpcall(fn, onTestError)
			if not ok then
				stats.failed = stats.failed + 1
				failures[#failures + 1] = { spec = spec, title = "(top level)", err = runErr }
			end
		end
		scope = {}
	end
end

-- Drops runner internals and C frames from a traceback.
local function trimTrace(err)
	local lines = {}
	for line in (tostring(err) .. "\n"):gmatch("(.-)\n") do
		local internal = line:find("tests/run.lua", 1, true) or line:find("[C]:", 1, true)
			or line:find("<python>", 1, true) or line:find("(tail call)", 1, true)
		if not internal then
			lines[#lines + 1] = line
		end
	end
	if lines[#lines] == "stack traceback:" then
		lines[#lines] = nil
	end
	return table.concat(lines, "\n  ")
end

for _, failure in ipairs(failures) do
	print("FAIL " .. failure.spec .. ": " .. failure.title)
	print("  " .. trimTrace(failure.err))
	print()
end

print(string.format("%d specs, %d passed, %d failed (%.2fs)", ran, stats.passed, stats.failed, os.clock() - started))

if ran == 0 then
	print("no specs matched")
	os.exit(1)
end
os.exit(stats.failed == 0 and 0 or 1)
