-- Next-City core: typed parameters with defaults and bounds (modes and rule blocks, D9).
--
-- Pure Lua (LuaJIT 2.x), no GMod API. See docs/ARCHITECTURE.md, section 11.
--
--   local set = Params.Define({
--   	roundTime = { type = "number", default = 300, min = 30, max = 3600, desc = "round length, s" },
--   	teams = { type = "integer", default = 2, min = 2, max = 4 },
--   	friendlyFire = { type = "boolean" },                                  -- default false
--   	respawn = { type = "enum", values = { "none", "wave", "instant" } }, -- default: first value
--   	title = { type = "string", max = 64 },                               -- default ""
--   	loadout = { type = "list", of = { type = "string", max = 32 }, max = 8, default = { "weapon_crowbar" } },
--   })
--   local values = set:Resolve(overrides, function(message) log:Warn(message) end)
--
-- Types: number (finite), integer, boolean, enum (string values), string (max bytes),
-- list (of = an element type name or spec, max = element count). number and integer
-- require a default; the others default to false, the first value, "" and {}.
-- Define rejects a bad spec with an error. Resolve never fails: a value of a wrong
-- type becomes the default, a number out of bounds is clamped, a fractional integer is
-- rounded, an unknown enum value becomes the default, a long string or list is cut and
-- invalid list elements are dropped. Each fix and every unknown key is reported through
-- warn. Resolved tables are fresh copies; nothing shares the defaults.

local Params = {}

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local setmetatable = setmetatable
local format = string.format
local byte = string.byte
local sub = string.sub
local concat = table.concat
local sort = table.sort
local floor = math.floor
local huge = math.huge

local NAME_PATTERN = "^[%a][%w_]*$"
local SPEC_KEYS = { type = true, default = true, min = true, max = true, values = true, of = true, desc = true }
local SCALAR = { number = true, integer = true, boolean = true, enum = true, string = true }
local TRUE_WORDS = { ["1"] = true, ["true"] = true, yes = true, on = true }
local FALSE_WORDS = { ["0"] = true, ["false"] = true, no = true, off = true }

Params.NAME_PATTERN = NAME_PATTERN

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= huge and value ~= -huge
end

local function isInteger(value)
	return isFinite(value) and floor(value) == value
end

local function show(value)
	if type(value) == "string" then
		return format("'%s'", value)
	end
	if type(value) == "table" then
		local parts = {}
		for i = 1, #value do
			parts[i] = show(value[i])
		end
		return "{" .. concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for i = 1, #value do
		result[i] = value[i]
	end
	return result
end

local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

-- Cuts a string to at most max bytes without splitting a UTF-8 sequence.
local function cut(text, max)
	local stop = max
	while stop > 0 do
		local nextByte = byte(text, stop + 1)
		if nextByte == nil or nextByte < 0x80 or nextByte >= 0xC0 then
			break
		end
		stop = stop - 1
	end
	return sub(text, 1, stop)
end

-- Definition checks ----------------------------------------------------------------------

local function fail(where, message)
	error(format("params: %s: %s", where, message), 0)
end

local function checkBounds(where, def, integer)
	local check = integer and isInteger or isFinite
	local kind = integer and "an integer" or "a finite number"
	if def.min ~= nil and not check(def.min) then
		fail(where, "min must be " .. kind)
	end
	if def.max ~= nil and not check(def.max) then
		fail(where, "max must be " .. kind)
	end
	if def.min ~= nil and def.max ~= nil and def.min > def.max then
		fail(where, "min must not be greater than max")
	end
end

local checkSpec

-- Returns the normalized element definition of a list.
local function checkElement(where, of)
	if type(of) == "string" then
		of = { type = of }
	end
	if type(of) ~= "table" then
		fail(where, "'of' must be a type name or an element spec")
	end
	if of.type == "list" then
		fail(where, "lists of lists are not supported")
	end
	if of.default ~= nil then
		fail(where, "list elements take no default")
	end
	return checkSpec(where .. " element", of, true)
end

local VALIDATE = {}

function VALIDATE.number(where, def, spec, element)
	checkBounds(where, def, false)
	if element then
		return
	end
	if not isFinite(spec.default) then
		fail(where, "default must be a finite number")
	end
	def.default = spec.default
end

function VALIDATE.integer(where, def, spec, element)
	checkBounds(where, def, true)
	if element then
		return
	end
	if not isInteger(spec.default) then
		fail(where, "default must be an integer")
	end
	def.default = spec.default
end

function VALIDATE.boolean(where, def, spec)
	if def.min ~= nil or def.max ~= nil then
		fail(where, "booleans take no min or max")
	end
	if spec.default ~= nil and type(spec.default) ~= "boolean" then
		fail(where, "default must be a boolean")
	end
	def.default = spec.default == true
end

function VALIDATE.enum(where, def, spec, element)
	local values = spec.values
	if type(values) ~= "table" or values[1] == nil then
		fail(where, "'values' must be a non-empty array of strings")
	end
	local list, set = {}, {}
	for i, value in ipairs(values) do
		if type(value) ~= "string" or value == "" then
			fail(where, "'values' must contain non-empty strings")
		end
		if set[value] then
			fail(where, "duplicate value '" .. value .. "'")
		end
		set[value] = true
		list[i] = value
	end
	def.values, def.valueSet = list, set
	if element then
		return
	end
	local default = spec.default
	if default == nil then
		default = list[1]
	end
	if not set[default] then
		fail(where, "default must be one of the values")
	end
	def.default = default
end

function VALIDATE.string(where, def, spec, element)
	if def.min ~= nil then
		fail(where, "strings take no min")
	end
	if def.max ~= nil and not (isInteger(def.max) and def.max >= 1) then
		fail(where, "max must be a positive integer (bytes)")
	end
	if element then
		return
	end
	local default = spec.default
	if default == nil then
		default = ""
	end
	if type(default) ~= "string" then
		fail(where, "default must be a string")
	end
	if def.max ~= nil and #default > def.max then
		fail(where, "default is longer than max")
	end
	def.default = default
end

local coerce

function VALIDATE.list(where, def, spec)
	if def.min ~= nil then
		fail(where, "lists take no min")
	end
	if def.max ~= nil and not (isInteger(def.max) and def.max >= 0) then
		fail(where, "max must be a non-negative integer (elements)")
	end
	def.of = checkElement(where, spec.of)
	local default = spec.default
	if default == nil then
		default = {}
	end
	if type(default) ~= "table" then
		fail(where, "default must be an array")
	end
	local count = 0
	for _ in pairs(default) do
		count = count + 1
	end
	if count ~= #default then
		fail(where, "default must be an array")
	end
	if def.max ~= nil and #default > def.max then
		fail(where, "default has more than max elements")
	end
	for i = 1, #default do
		local _, problem = coerce(def.of, default[i], nil)
		if problem ~= nil then
			fail(where, format("default element %d is invalid (%s)", i, problem))
		end
	end
	def.default = copy(default)
end

function checkSpec(where, spec, element)
	if type(spec) ~= "table" then
		fail(where, "spec must be a table")
	end
	for key in pairs(spec) do
		if not SPEC_KEYS[key] then
			fail(where, "unknown spec key '" .. tostring(key) .. "'")
		end
	end
	local kind = spec.type
	local validate = VALIDATE[kind]
	if validate == nil or element and not SCALAR[kind] then
		fail(where, "unknown type '" .. tostring(kind) .. "'")
	end
	if spec.desc ~= nil and type(spec.desc) ~= "string" then
		fail(where, "desc must be a string")
	end
	if spec.of ~= nil and kind ~= "list" then
		fail(where, "'of' is only for lists")
	end
	if spec.values ~= nil and kind ~= "enum" then
		fail(where, "'values' is only for enums")
	end
	local def = { type = kind, min = spec.min, max = spec.max, desc = spec.desc }
	validate(where, def, spec, element)
	return def
end

-- Coercion -------------------------------------------------------------------------------

local function clamp(def, value)
	if def.min ~= nil and value < def.min then
		return def.min, format("%s is below the minimum %s", show(value), show(def.min))
	end
	if def.max ~= nil and value > def.max then
		return def.max, format("%s is above the maximum %s", show(value), show(def.max))
	end
	return value
end

local COERCE = {}

function COERCE.number(def, value)
	if not isFinite(value) then
		return nil, format("must be a finite number, got %s", show(value))
	end
	return clamp(def, value)
end

function COERCE.integer(def, value)
	if not isFinite(value) then
		return nil, format("must be an integer, got %s", show(value))
	end
	local rounded = floor(value + 0.5)
	local fixed, problem = clamp(def, rounded)
	if rounded ~= value and problem == nil then
		problem = format("must be an integer, got %s", show(value))
	end
	return fixed, problem
end

function COERCE.boolean(_, value)
	if type(value) ~= "boolean" then
		return nil, format("must be a boolean, got %s", show(value))
	end
	return value
end

function COERCE.enum(def, value)
	if not def.valueSet[value] then
		return nil, format("must be one of %s, got %s", concat(def.values, ", "), show(value))
	end
	return value
end

function COERCE.string(def, value)
	if type(value) ~= "string" then
		return nil, format("must be a string, got %s", show(value))
	end
	if def.max ~= nil and #value > def.max then
		return cut(value, def.max), format("is longer than %d bytes", def.max)
	end
	return value
end

function COERCE.list(def, value)
	if type(value) ~= "table" then
		return nil, format("must be a list, got %s", show(value))
	end
	local result, problems = {}, nil
	local of = def.of
	for i = 1, #value do
		local element, problem = coerce(of, value[i], nil)
		if problem ~= nil then
			problems = problems or {}
			if element == nil then
				problems[#problems + 1] = format("element %d %s, dropped", i, problem)
			else
				problems[#problems + 1] = format("element %d %s", i, problem)
			end
		end
		if element ~= nil then
			result[#result + 1] = element
		end
	end
	if def.max ~= nil and #result > def.max then
		problems = problems or {}
		problems[#problems + 1] = format("has more than %d elements, the rest are dropped", def.max)
		for i = #result, def.max + 1, -1 do
			result[i] = nil
		end
	end
	return result, problems and concat(problems, "; ")
end

-- Returns the value to use and a problem description (nil if the value was fine).
-- A rejected value (wrong type, unknown enum value) is replaced by a copy of fallback;
-- with a nil fallback the result is nil.
function coerce(def, value, fallback)
	local fixed, problem = COERCE[def.type](def, value)
	if fixed == nil then
		return copy(fallback), problem
	end
	return fixed, problem
end

-- Parameter sets -------------------------------------------------------------------------

local Set = {}
Set.__index = Set

local function newSet(defs)
	local names = sortedKeys(defs)
	return setmetatable({ defs = defs, names = names }, Set)
end

-- Validates a spec { name = { type, default, min, max, values, of, desc } } and returns
-- a parameter set. Errors name the offending parameter: "params: teams: min must ...".
function Params.Define(spec)
	if type(spec) ~= "table" then
		error("params: spec must be a table of parameter specs", 2)
	end
	local defs = {}
	for name, paramSpec in pairs(spec) do
		if type(name) ~= "string" or not name:find(NAME_PATTERN) then
			fail(tostring(name), "parameter names must start with a letter and contain letters, digits and '_'")
		end
		defs[name] = checkSpec(name, paramSpec, false)
	end
	return newSet(defs)
end

-- Combines sets; a later set overrides parameters of the same name. Returns the new
-- set and the names that changed their type (to warn about likely mistakes).
function Params.Merge(sets)
	local defs, conflicts = {}, {}
	for _, set in ipairs(sets) do
		for name, def in pairs(set.defs) do
			local previous = defs[name]
			if previous ~= nil and previous.type ~= def.type then
				conflicts[#conflicts + 1] = name
			end
			defs[name] = def
		end
	end
	sort(conflicts)
	return newSet(defs), conflicts
end

-- Sorted parameter names.
function Set:Names()
	return self.names
end

function Set:Has(name)
	return self.defs[name] ~= nil
end

-- Normalized definition of a parameter (do not modify): type, default, min, max,
-- values, of, desc.
function Set:Get(name)
	return self.defs[name]
end

function Set:Count()
	return #self.names
end

-- Fresh table of default values.
function Set:Defaults()
	local values = {}
	for name, def in pairs(self.defs) do
		values[name] = copy(def.default)
	end
	return values
end

-- Checks one value. Returns the value to use and a problem description (nil if fine):
-- set:Coerce("teams", 7) -> 4, "7 is above the maximum 4".
function Set:Coerce(name, value)
	local def = self.defs[name]
	if def == nil then
		return nil, "unknown param"
	end
	return coerce(def, value, def.default)
end

-- Validated values for every parameter: overrides win over defaults. warn(message)
-- receives one message per problem, e.g. "param 'teams': 7 is above the maximum 4; using 4".
function Set:Resolve(overrides, warn)
	local values = self:Defaults()
	if overrides == nil then
		return values
	end
	if type(overrides) ~= "table" then
		if warn then
			warn(format("params must be a table, got %s; using the defaults", type(overrides)))
		end
		return values
	end
	for _, key in ipairs(sortedKeys(overrides)) do
		local def = self.defs[key]
		local value = overrides[key]
		if def == nil then
			if warn then
				warn(format("unknown param '%s'", tostring(key)))
			end
		else
			local fixed, problem = coerce(def, value, def.default)
			values[key] = fixed
			if problem ~= nil and warn then
				warn(format("param '%s': %s; using %s", key, problem, show(fixed)))
			end
		end
	end
	return values
end

local function parseScalar(def, text)
	local kind = def.type
	if kind == "number" or kind == "integer" then
		local value = tonumber(text)
		if value == nil then
			return nil, format("'%s' is not a number", text)
		end
		return value
	end
	if kind == "boolean" then
		local word = text:lower()
		if TRUE_WORDS[word] then
			return true
		end
		if FALSE_WORDS[word] then
			return false
		end
		return nil, format("'%s' is not a boolean (true/false, 1/0, yes/no, on/off)", text)
	end
	return text
end

-- Converts console text to a value of the parameter type (lists are comma separated).
-- Returns the value or nil and an error; pass the result to Coerce for the bounds.
function Set:Parse(name, text)
	local def = self.defs[name]
	if def == nil then
		return nil, format("unknown param '%s'", tostring(name))
	end
	text = tostring(text):match("^%s*(.-)%s*$")
	if def.type ~= "list" then
		return parseScalar(def, text)
	end
	local result = {}
	if text == "" then
		return result
	end
	for item in (text .. ","):gmatch("([^,]*),") do
		local value, err = parseScalar(def.of, item:match("^%s*(.-)%s*$"))
		if value == nil then
			return nil, err
		end
		result[#result + 1] = value
	end
	return result
end

local function describeScalar(def)
	local kind = def.type
	if kind == "enum" then
		return "enum " .. concat(def.values, "|")
	end
	if kind == "number" or kind == "integer" then
		if def.min ~= nil or def.max ~= nil then
			return format("%s %s..%s", kind, def.min ~= nil and show(def.min) or "", def.max ~= nil and show(def.max) or "")
		end
		return kind
	end
	if kind == "string" and def.max ~= nil then
		return format("string <=%d", def.max)
	end
	return kind
end

-- One line for admin listings: "integer 2..4 = 2", "list of string <=8 = {'a'}".
function Set:Describe(name, value)
	local def = self.defs[name]
	if def == nil then
		return nil
	end
	local text
	if def.type == "list" then
		text = "list of " .. describeScalar(def.of)
		if def.max ~= nil then
			text = text .. format(" <=%d", def.max)
		end
	else
		text = describeScalar(def)
	end
	if value == nil then
		value = def.default
	end
	return text .. " = " .. show(value)
end

return Params
