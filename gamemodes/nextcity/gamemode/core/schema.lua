-- Next-City core: typed message schemas compiled into encoders and decoders.
--
-- Pure Lua (LuaJIT 2.x), no GMod API: the bit I/O is passed in. The platform passes an
-- adapter over the net library, tests pass a recorder. See docs/ARCHITECTURE.md, section 8.
--
--   local schema = Schema.Define({
--       { "phase", "enum", values = { "waiting", "active" } },
--       { "endsAt", "float" },
--       { "scores", "array", max = 4, of = { "uint", bits = 16 } },
--       { "leader", "player", optional = true },
--   })
--   local codec = schema:Codec(io)    -- compiled once per io, cached
--   codec.Write(message)              -- coerces values to the schema, never throws
--   local message, err = codec.Read() -- untrusted input: nil and a reason if invalid
--
-- Field: { name, type, options... }; element of an array: "type" or { type, options... }.
--
--   bool
--   uint    bits (1..32) and/or max                   integers 0..max
--   int     bits (2..32, signed) or min and max       range is sent as an offset in the fewest bits
--   float   min, max, finite (default true)           32-bit
--   double  min, max, finite (default true)           64-bit
--   quant   min, max, bits (default 16)               number in [min, max] packed into bits
--   string  max (bytes, default 255)
--   enum    values (strings or numbers)               sent as an index
--   array   of, max
--   struct  fields
--   entity  valid (reject invalid entities on read)   13 bits
--   player  valid                                     8 bits
--   vector, angle, normal                             engine encodings
--   color   alpha (default true)
-- Every field also takes optional = true (a presence bit; absent reads as nil) and desc.
--
-- Writers coerce, so a bug in one module cannot corrupt the stream: numbers are clamped
-- to their range (NaN becomes 0 or the lower bound), strings and arrays are truncated,
-- unknown enum values become the first value, values of a wrong type become defaults.
-- schema:Check(message) reports such problems instead (for debugging and tests).
-- Readers validate: ranges, NaN and infinities, string and array lengths, enum indexes
-- and, with valid = true, entities.
--
-- io functions are called with a dot, like the net library: WriteBool/ReadBool,
-- WriteUInt/ReadUInt(bits), WriteInt/ReadInt(bits), WriteFloat/ReadFloat,
-- WriteDouble/ReadDouble, WriteString/ReadString, WriteEntity/ReadEntity (13 bits),
-- WritePlayer/ReadPlayer (8 bits), WriteVector/ReadVector, WriteAngle/ReadAngle,
-- WriteNormal/ReadNormal, WriteColor/ReadColor(alpha) and IsValid(entity). Only the
-- functions a schema uses are required. Adapters coerce their own engine types (nil
-- entity, missing vector).

local Schema = {}

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable
local format = string.format
local sub = string.sub
local concat = table.concat
local floor = math.floor
local abs = math.abs
local frexp = math.frexp
local ldexp = math.ldexp
local huge = math.huge

local NAME_PATTERN = "^[%a_][%w_]*$"
local UINT32_MAX = 4294967295
local MAX_LENGTH = 65535
local MAX_ENUM = 65536
local FLOAT_MAX = 3.4028234663852886e38
local DOUBLE_MAX = 1.7976931348623157e308
-- float32 rounding may move a bound by an ulp; readers accept that much and clamp back.
local FLOAT_SLACK = 2 ^ -22
local FLOAT_TINY = 2 ^ -126

-- Wire sizes the platform adapter must honour: edict index, player index (0 = none).
local ENTITY_BITS = 13
local PLAYER_BITS = 8
-- Engine encodings of vectors, angles and normals vary in size: safe outer bounds.
local VECTOR_BITS = { 3, 99 }
local NORMAL_BITS = { 3, 51 }

Schema.ENTITY_BITS = ENTITY_BITS
Schema.PLAYER_BITS = PLAYER_BITS

local EMPTY = setmetatable({}, { __newindex = function() error("schema: EMPTY is read-only", 2) end })

-- Number of bits needed to store the integers 0..n (at least 1).
local function bitsFor(n)
	local bits, limit = 1, 2
	while n >= limit do
		bits = bits + 1
		limit = limit * 2
	end
	return bits
end
Schema.BitsFor = bitsFor

-- Rounds a number to the nearest float32 value (what WriteFloat/ReadFloat returns).
function Schema.RoundFloat32(x)
	if x == 0 or x ~= x or x == huge or x == -huge then
		return x
	end
	if abs(x) > FLOAT_MAX then
		return x > 0 and huge or -huge
	end
	local m, e = frexp(x)
	if e < -125 then
		-- subnormal range: fixed step of 2^-149
		return floor(x * 2 ^ 149 + 0.5) / 2 ^ 149
	end
	return ldexp(floor(m * 16777216 + 0.5) / 16777216, e)
end

local function isNumber(v)
	return type(v) == "number" and v == v
end

local function isFinite(v)
	return type(v) == "number" and v == v and v ~= huge and v ~= -huge
end

local function isInteger(v)
	return isFinite(v) and v == floor(v)
end

local function num(v)
	return format("%.17g", v)
end

local function describe(v)
	if type(v) == "number" or type(v) == "boolean" then
		return tostring(v)
	end
	if type(v) == "string" then
		return format("string %q", #v > 24 and sub(v, 1, 24) .. "..." or v)
	end
	return type(v)
end

local function fail(path, message, ...)
	local prefix = path == "" and "schema: " or "schema: " .. path .. ": "
	error(prefix .. format(message, ...), 0)
end

-- Joins a field name with the path of an error inside it ("a" + "b" -> "a.b", "a" + "[2]").
local function joinPath(name, path)
	if path == nil then
		return name
	end
	if sub(path, 1, 1) == "[" then
		return name .. path
	end
	return name .. "." .. path
end

-- Types ----------------------------------------------------------------------------

local TYPES = {}
local build

TYPES.bool = {
	options = {},
	define = function(node)
		node.minBits, node.maxBits, node.sig = 1, 1, "b"
		node.needs = { "WriteBool", "ReadBool" }
	end,
	writer = function(_, io)
		local WriteBool = io.WriteBool
		return function(v)
			WriteBool(v and true or false)
		end
	end,
	reader = function(_, io)
		return io.ReadBool
	end,
	check = function()
		return function(v)
			if type(v) ~= "boolean" then
				return "expected a boolean, got " .. describe(v)
			end
		end
	end,
}

TYPES.uint = {
	options = { bits = true, max = true },
	define = function(node, spec, path)
		local bits, max = spec.bits, spec.max
		if bits == nil and max == nil then
			fail(path, "uint needs bits or max")
		end
		if max ~= nil and (not isInteger(max) or max < 0 or max > UINT32_MAX) then
			fail(path, "max must be an integer 0..%d", UINT32_MAX)
		end
		bits = bits or bitsFor(max)
		if not isInteger(bits) or bits < 1 or bits > 32 then
			fail(path, "bits must be an integer 1..32")
		end
		local limit = 2 ^ bits - 1
		if max == nil then
			max = limit
		elseif max > limit then
			fail(path, "max %d does not fit into %d bits", max, bits)
		end
		node.bits, node.max, node.bounded = bits, max, max < limit
		node.minBits, node.maxBits = bits, bits
		node.sig = node.bounded and format("u%d<=%d", bits, max) or "u" .. bits
		node.needs = { "WriteUInt", "ReadUInt" }
	end,
	writer = function(node, io)
		local WriteUInt, bits, max = io.WriteUInt, node.bits, node.max
		return function(v)
			if type(v) ~= "number" or v ~= v or v < 0 then
				v = 0
			elseif v > max then
				v = max
			else
				v = floor(v)
			end
			WriteUInt(v, bits)
		end
	end,
	reader = function(node, io)
		local ReadUInt, bits, max = io.ReadUInt, node.bits, node.max
		if not node.bounded then
			return function()
				return ReadUInt(bits)
			end
		end
		return function()
			local v = ReadUInt(bits)
			if v > max then
				return nil, format("%d is above the maximum %d", v, max)
			end
			return v
		end
	end,
	check = function(node)
		local max = node.max
		return function(v)
			if not isInteger(v) then
				return "expected an integer, got " .. describe(v)
			end
			if v < 0 or v > max then
				return format("%s is out of range 0..%d", num(v), max)
			end
		end
	end,
}

TYPES.int = {
	options = { bits = true, min = true, max = true },
	define = function(node, spec, path)
		local bits, min, max = spec.bits, spec.min, spec.max
		if bits ~= nil then
			if min ~= nil or max ~= nil then
				fail(path, "int takes either bits or min and max, not both")
			end
			if not isInteger(bits) or bits < 2 or bits > 32 then
				fail(path, "bits must be an integer 2..32")
			end
			node.min, node.max, node.signed = -2 ^ (bits - 1), 2 ^ (bits - 1) - 1, true
			node.sig = "i" .. bits
			node.needs = { "WriteInt", "ReadInt" }
		else
			if not isInteger(min) or not isInteger(max) then
				fail(path, "int needs bits, or integer min and max")
			end
			if min > max then
				fail(path, "min %s is above max %s", num(min), num(max))
			end
			bits = bitsFor(max - min)
			if bits > 32 then
				fail(path, "range %s..%s needs more than 32 bits", num(min), num(max))
			end
			node.min, node.max, node.signed = min, max, false
			node.bounded = max - min < 2 ^ bits - 1
			node.sig = format("i%s..%s", num(min), num(max))
			node.needs = { "WriteUInt", "ReadUInt" }
		end
		node.bits = bits
		node.minBits, node.maxBits = bits, bits
	end,
	writer = function(node, io)
		local bits, min, max = node.bits, node.min, node.max
		local Write = node.signed and io.WriteInt or io.WriteUInt
		local offset = node.signed and 0 or min
		return function(v)
			if type(v) ~= "number" or v ~= v then
				v = 0
			end
			if v < min then
				v = min
			elseif v > max then
				v = max
			else
				v = floor(v)
			end
			Write(v - offset, bits)
		end
	end,
	reader = function(node, io)
		local bits, min, max = node.bits, node.min, node.max
		if node.signed then
			local ReadInt = io.ReadInt
			return function()
				return ReadInt(bits)
			end
		end
		local ReadUInt = io.ReadUInt
		if not node.bounded then
			return function()
				return ReadUInt(bits) + min
			end
		end
		return function()
			local v = ReadUInt(bits) + min
			if v > max then
				return nil, format("%s is above the maximum %s", num(v), num(max))
			end
			return v
		end
	end,
	check = function(node)
		local min, max = node.min, node.max
		return function(v)
			if not isInteger(v) then
				return "expected an integer, got " .. describe(v)
			end
			if v < min or v > max then
				return format("%s is out of range %s..%s", num(v), num(min), num(max))
			end
		end
	end,
}

local function defineReal(node, spec, path, single)
	local min, max = spec.min, spec.max
	if min ~= nil and not isFinite(min) then
		fail(path, "min must be a finite number")
	end
	if max ~= nil and not isFinite(max) then
		fail(path, "max must be a finite number")
	end
	if min ~= nil and max ~= nil and min > max then
		fail(path, "min %s is above max %s", num(min), num(max))
	end
	if spec.finite ~= nil and type(spec.finite) ~= "boolean" then
		fail(path, "finite must be a boolean")
	end
	local finite = spec.finite ~= false
	local limit = finite and (single and FLOAT_MAX or DOUBLE_MAX) or huge
	node.min, node.max, node.finite = min, max, finite
	-- write range (clamping), read range (rejecting), both on top of the finite limit
	node.lo, node.hi = min or -limit, max or limit
	node.readLo, node.readHi = node.lo, node.hi
	if single then
		if min ~= nil then
			node.readLo = min - abs(min) * FLOAT_SLACK - FLOAT_TINY
		end
		if max ~= nil then
			node.readHi = max + abs(max) * FLOAT_SLACK + FLOAT_TINY
		end
	end
	local bits = single and 32 or 64
	node.minBits, node.maxBits = bits, bits
	node.sig = (single and "f" or "d") .. (min and "[" .. num(min) or "[") .. "," .. (max and num(max) or "")
		.. (finite and "]" or "]~")
	node.needs = single and { "WriteFloat", "ReadFloat" } or { "WriteDouble", "ReadDouble" }
end

local function realWriter(node, Write)
	local lo, hi = node.lo, node.hi
	return function(v)
		if type(v) ~= "number" or v ~= v then
			v = 0
		end
		if v < lo then
			v = lo
		elseif v > hi then
			v = hi
		end
		Write(v)
	end
end

local function realReader(node, Read)
	local lo, hi, readLo, readHi = node.lo, node.hi, node.readLo, node.readHi
	return function()
		local v = Read()
		if v ~= v then
			return nil, "NaN is not allowed"
		end
		if v < readLo or v > readHi then
			return nil, format("%s is out of range", num(v))
		end
		if v < lo then
			v = lo
		elseif v > hi then
			v = hi
		end
		return v
	end
end

local function realCheck(node)
	local min, max, finite = node.min, node.max, node.finite
	return function(v)
		if not isNumber(v) then
			return "expected a number, got " .. describe(v)
		end
		if finite and (v == huge or v == -huge) then
			return "infinity is not allowed"
		end
		if (min ~= nil and v < min) or (max ~= nil and v > max) then
			return format("%s is out of range %s..%s", num(v), min and num(min) or "", max and num(max) or "")
		end
	end
end

TYPES.float = {
	options = { min = true, max = true, finite = true },
	define = function(node, spec, path)
		defineReal(node, spec, path, true)
	end,
	writer = function(node, io)
		return realWriter(node, io.WriteFloat)
	end,
	reader = function(node, io)
		return realReader(node, io.ReadFloat)
	end,
	check = realCheck,
}

TYPES.double = {
	options = { min = true, max = true, finite = true },
	define = function(node, spec, path)
		defineReal(node, spec, path, false)
	end,
	writer = function(node, io)
		return realWriter(node, io.WriteDouble)
	end,
	reader = function(node, io)
		return realReader(node, io.ReadDouble)
	end,
	check = realCheck,
}

TYPES.quant = {
	options = { min = true, max = true, bits = true },
	define = function(node, spec, path)
		local min, max, bits = spec.min, spec.max, spec.bits or 16
		if not isFinite(min) or not isFinite(max) or min >= max then
			fail(path, "quant needs finite min < max")
		end
		if not isInteger(bits) or bits < 1 or bits > 32 then
			fail(path, "bits must be an integer 1..32")
		end
		local steps = 2 ^ bits - 1
		node.min, node.max, node.bits, node.steps = min, max, bits, steps
		node.scale, node.step = steps / (max - min), (max - min) / steps
		node.minBits, node.maxBits = bits, bits
		node.sig = format("q%d[%s,%s]", bits, num(min), num(max))
		node.needs = { "WriteUInt", "ReadUInt" }
	end,
	writer = function(node, io)
		local WriteUInt = io.WriteUInt
		local min, max, bits, steps, scale = node.min, node.max, node.bits, node.steps, node.scale
		return function(v)
			if type(v) ~= "number" or v ~= v or v < min then
				v = min
			elseif v > max then
				v = max
			end
			local q = floor((v - min) * scale + 0.5)
			if q > steps then
				q = steps
			end
			WriteUInt(q, bits)
		end
	end,
	reader = function(node, io)
		local ReadUInt = io.ReadUInt
		local min, max, bits, step = node.min, node.max, node.bits, node.step
		return function()
			local v = min + ReadUInt(bits) * step
			if v > max then
				v = max
			end
			return v
		end
	end,
	check = function(node)
		local min, max = node.min, node.max
		return function(v)
			if not isNumber(v) then
				return "expected a number, got " .. describe(v)
			end
			if v < min or v > max then
				return format("%s is out of range %s..%s", num(v), num(min), num(max))
			end
		end
	end,
}

TYPES.string = {
	options = { max = true },
	define = function(node, spec, path)
		local max = spec.max or 255
		if not isInteger(max) or max < 1 or max > MAX_LENGTH then
			fail(path, "max must be an integer 1..%d", MAX_LENGTH)
		end
		node.max = max
		node.minBits, node.maxBits = 8, (max + 1) * 8
		node.sig = "s" .. max
		node.needs = { "WriteString", "ReadString" }
	end,
	writer = function(node, io)
		local WriteString, max = io.WriteString, node.max
		return function(v)
			if type(v) ~= "string" then
				v = ""
			elseif #v > max then
				v = sub(v, 1, max)
			end
			WriteString(v)
		end
	end,
	reader = function(node, io)
		local ReadString, max = io.ReadString, node.max
		return function()
			local v = ReadString()
			if #v > max then
				return nil, format("string of %d bytes is longer than %d", #v, max)
			end
			return v
		end
	end,
	check = function(node)
		local max = node.max
		return function(v)
			if type(v) ~= "string" then
				return "expected a string, got " .. describe(v)
			end
			if #v > max then
				return format("string of %d bytes is longer than %d", #v, max)
			end
		end
	end,
}

local function isArray(value)
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for _ in pairs(value) do
		count = count + 1
	end
	return count == #value
end

TYPES.enum = {
	options = { values = true },
	define = function(node, spec, path)
		local values = spec.values
		if not isArray(values) or values[1] == nil then
			fail(path, "enum needs a non-empty array of values")
		end
		if #values > MAX_ENUM then
			fail(path, "enum has more than %d values", MAX_ENUM)
		end
		local list, index, names = {}, {}, {}
		for i, value in ipairs(values) do
			if type(value) ~= "string" and not isFinite(value) then
				fail(path, "enum value %d must be a string or a finite number", i)
			end
			if index[value] ~= nil then
				fail(path, "enum value %s is listed twice", describe(value))
			end
			list[i], index[value] = value, i - 1
			names[i] = type(value) == "string" and format("%q", value) or num(value)
		end
		local count = #list
		local bits = bitsFor(count - 1)
		node.values, node.index, node.count, node.bits = list, index, count, bits
		node.bounded = count < 2 ^ bits
		node.minBits, node.maxBits = bits, bits
		node.sig = "e{" .. concat(names, ",") .. "}"
		node.needs = { "WriteUInt", "ReadUInt" }
	end,
	writer = function(node, io)
		local WriteUInt, index, bits = io.WriteUInt, node.index, node.bits
		return function(v)
			WriteUInt(v ~= nil and index[v] or 0, bits)
		end
	end,
	reader = function(node, io)
		local ReadUInt, values, count, bits = io.ReadUInt, node.values, node.count, node.bits
		return function()
			local i = ReadUInt(bits)
			if i >= count then
				return nil, format("enum index %d is out of range (%d values)", i, count)
			end
			return values[i + 1]
		end
	end,
	check = function(node)
		local index = node.index
		return function(v)
			if v == nil or index[v] == nil then
				return "unknown enum value " .. describe(v)
			end
		end
	end,
}

local compileWriter, compileReader, compileCheck

TYPES.array = {
	options = { of = true, max = true },
	define = function(node, spec, path)
		local max = spec.max
		if not isInteger(max) or max < 1 or max > MAX_LENGTH then
			fail(path, "array needs max, an integer 1..%d", MAX_LENGTH)
		end
		if spec.of == nil then
			fail(path, "array needs an element type (of)")
		end
		local elem = build(spec.of, path .. "[]", true)
		local prefix = bitsFor(max)
		node.elem, node.max, node.prefix = elem, max, prefix
		node.minBits, node.maxBits = prefix, prefix + max * elem.maxBits
		node.sig = format("a%d(%s)", max, elem.sig)
		node.needs = { "WriteUInt", "ReadUInt" }
	end,
	writer = function(node, io)
		local WriteUInt, max, prefix = io.WriteUInt, node.max, node.prefix
		local write = compileWriter(node.elem, io)
		return function(v)
			if type(v) ~= "table" then
				WriteUInt(0, prefix)
				return
			end
			local n = #v
			if n > max then
				n = max
			end
			WriteUInt(n, prefix)
			for i = 1, n do
				write(v[i])
			end
		end
	end,
	reader = function(node, io)
		local ReadUInt, max, prefix = io.ReadUInt, node.max, node.prefix
		local read = compileReader(node.elem, io)
		return function()
			local n = ReadUInt(prefix)
			if n > max then
				return nil, format("array of %d elements is longer than %d", n, max)
			end
			local out = {}
			for i = 1, n do
				local value, err, path = read()
				if err ~= nil then
					return nil, err, joinPath("[" .. i .. "]", path)
				end
				out[i] = value
			end
			return out
		end
	end,
	check = function(node)
		local max = node.max
		local check = compileCheck(node.elem)
		return function(v)
			if not isArray(v) then
				return "expected an array, got " .. describe(v)
			end
			if #v > max then
				return format("array of %d elements is longer than %d", #v, max)
			end
			for i = 1, #v do
				local err, path = check(v[i])
				if err ~= nil then
					return err, joinPath("[" .. i .. "]", path)
				end
			end
		end
	end,
}

local function buildFields(fields, path)
	if not isArray(fields) then
		fail(path, "fields must be an array of { name, type, options... }")
	end
	local nodes, seen = {}, {}
	for i, field in ipairs(fields) do
		if type(field) ~= "table" then
			fail(path, "field %d must be a table { name, type, options... }", i)
		end
		local name = field[1]
		if type(name) ~= "string" or not name:find(NAME_PATTERN) then
			fail(path, "field %d needs a name (identifier) first, got %s", i, describe(name))
		end
		local fieldPath = path == "" and name or path .. "." .. name
		if seen[name] then
			fail(fieldPath, "field is defined twice")
		end
		seen[name] = true
		local node = build(field, fieldPath, false)
		node.name = name
		nodes[i] = node
	end
	return nodes
end

local function structNames(node)
	local names, set = {}, {}
	for i, field in ipairs(node.fields) do
		names[i], set[field.name] = field.name, true
	end
	return names, set
end

TYPES.struct = {
	options = { fields = true },
	define = function(node, spec, path)
		local fields = buildFields(spec.fields, path)
		local minBits, maxBits, sigs = 0, 0, {}
		for i, field in ipairs(fields) do
			minBits, maxBits = minBits + field.minBits, maxBits + field.maxBits
			sigs[i] = field.name .. ":" .. field.sig
		end
		node.fields = fields
		node.minBits, node.maxBits = minBits, maxBits
		node.sig = "{" .. concat(sigs, ";") .. "}"
		node.needs = {}
	end,
	writer = function(node, io)
		local names = structNames(node)
		local writers, count = {}, #names
		for i, field in ipairs(node.fields) do
			writers[i] = compileWriter(field, io)
		end
		return function(v)
			if type(v) ~= "table" then
				v = EMPTY
			end
			for i = 1, count do
				writers[i](v[names[i]])
			end
		end
	end,
	reader = function(node, io)
		local names = structNames(node)
		local readers, count = {}, #names
		for i, field in ipairs(node.fields) do
			readers[i] = compileReader(field, io)
		end
		return function()
			local out = {}
			for i = 1, count do
				local value, err, path = readers[i]()
				if err ~= nil then
					return nil, err, joinPath(names[i], path)
				end
				out[names[i]] = value
			end
			return out
		end
	end,
	check = function(node)
		local names, known = structNames(node)
		local checks, count = {}, #names
		for i, field in ipairs(node.fields) do
			checks[i] = compileCheck(field)
		end
		return function(v)
			if type(v) ~= "table" then
				return "expected a table, got " .. describe(v)
			end
			for key in pairs(v) do
				if not known[key] then
					return format("unknown field %s", describe(key))
				end
			end
			for i = 1, count do
				local err, path = checks[i](v[names[i]])
				if err ~= nil then
					return err, joinPath(names[i], path)
				end
			end
		end
	end,
}

local function defineHandle(kind, bits, write, read)
	return {
		options = { valid = true },
		define = function(node, spec, path)
			if spec.valid ~= nil and type(spec.valid) ~= "boolean" then
				fail(path, "valid must be a boolean")
			end
			node.valid = spec.valid == true
			node.minBits, node.maxBits = bits, bits
			node.sig = node.valid and kind .. "!" or kind
			node.needs = node.valid and { write, read, "IsValid" } or { write, read }
		end,
		writer = function(_, io)
			return io[write]
		end,
		reader = function(node, io)
			local Read = io[read]
			if not node.valid then
				return Read
			end
			local IsValid = io.IsValid
			return function()
				local v = Read()
				if not IsValid(v) then
					return nil, "invalid " .. kind
				end
				return v
			end
		end,
		check = function()
			return function() end
		end,
	}
end

TYPES.entity = defineHandle("entity", ENTITY_BITS, "WriteEntity", "ReadEntity")
TYPES.player = defineHandle("player", PLAYER_BITS, "WritePlayer", "ReadPlayer")

local function defineEngine(kind, bounds, write, read)
	return {
		options = {},
		define = function(node)
			node.minBits, node.maxBits = bounds[1], bounds[2]
			node.sig = kind
			node.needs = { write, read }
		end,
		writer = function(_, io)
			return io[write]
		end,
		reader = function(_, io)
			return io[read]
		end,
		check = function()
			return function(v)
				if v == nil then
					return "expected a " .. kind .. ", got nil"
				end
			end
		end,
	}
end

TYPES.vector = defineEngine("vector", VECTOR_BITS, "WriteVector", "ReadVector")
TYPES.angle = defineEngine("angle", VECTOR_BITS, "WriteAngle", "ReadAngle")
TYPES.normal = defineEngine("normal", NORMAL_BITS, "WriteNormal", "ReadNormal")

TYPES.color = {
	options = { alpha = true },
	define = function(node, spec, path)
		if spec.alpha ~= nil and type(spec.alpha) ~= "boolean" then
			fail(path, "alpha must be a boolean")
		end
		node.alpha = spec.alpha ~= false
		node.minBits = node.alpha and 32 or 24
		node.maxBits = node.minBits
		node.sig = node.alpha and "rgba" or "rgb"
		node.needs = { "WriteColor", "ReadColor" }
	end,
	writer = function(node, io)
		local WriteColor, alpha = io.WriteColor, node.alpha
		return function(v)
			WriteColor(v, alpha)
		end
	end,
	reader = function(node, io)
		local ReadColor, alpha = io.ReadColor, node.alpha
		return function()
			return ReadColor(alpha)
		end
	end,
	check = function()
		return function(v)
			if v == nil then
				return "expected a color, got nil"
			end
		end
	end,
}

-- Building -------------------------------------------------------------------------

local COMMON_OPTIONS = { optional = true, desc = true }

-- spec: a field { name, type, ... } (element = false) or an element "type" / { type, ... }.
function build(spec, path, element)
	if type(spec) == "string" and element then
		spec = { spec }
	end
	if type(spec) ~= "table" then
		fail(path, "expected a type spec, got %s", describe(spec))
	end
	local first = element and 1 or 2
	local typeName = spec[first]
	local kind = TYPES[typeName]
	if kind == nil then
		fail(path, "unknown type %s", describe(typeName))
	end
	for key in pairs(spec) do
		if type(key) == "number" then
			if key ~= 1 and key ~= first then
				fail(path, "unexpected positional value %s", describe(spec[key]))
			end
		elseif not kind.options[key] and not COMMON_OPTIONS[key] then
			fail(path, "unknown option '%s' for %s", tostring(key), typeName)
		end
	end
	if spec.optional ~= nil and type(spec.optional) ~= "boolean" then
		fail(path, "optional must be a boolean")
	end
	if spec.desc ~= nil and type(spec.desc) ~= "string" then
		fail(path, "desc must be a string")
	end
	if element and spec.optional then
		fail(path, "array elements cannot be optional")
	end
	local node = { type = typeName, path = path }
	kind.define(node, spec, path)
	if spec.optional then
		node.optional = true
		node.minBits, node.maxBits = 1, 1 + node.maxBits
		node.sig = "?" .. node.sig
		node.needs[#node.needs + 1] = "WriteBool"
		node.needs[#node.needs + 1] = "ReadBool"
	end
	return node
end

function compileWriter(node, io)
	local write = TYPES[node.type].writer(node, io)
	if not node.optional then
		return write
	end
	local WriteBool = io.WriteBool
	return function(v)
		if v == nil then
			WriteBool(false)
		else
			WriteBool(true)
			write(v)
		end
	end
end

function compileReader(node, io)
	local read = TYPES[node.type].reader(node, io)
	if not node.optional then
		return read
	end
	local ReadBool = io.ReadBool
	return function()
		if ReadBool() then
			return read()
		end
		return nil
	end
end

function compileCheck(node)
	local check = TYPES[node.type].check(node)
	if not node.optional then
		return check
	end
	return function(v)
		if v ~= nil then
			return check(v)
		end
	end
end

local function collectNeeds(node, out)
	for _, name in ipairs(node.needs) do
		out[name] = true
	end
	if node.elem then
		collectNeeds(node.elem, out)
	end
	if node.fields then
		for _, field in ipairs(node.fields) do
			collectNeeds(field, out)
		end
	end
	return out
end

-- Schema objects -------------------------------------------------------------------

local SchemaMeta = {}
SchemaMeta.__index = SchemaMeta

-- Builds a schema from an array of fields; throws a readable error on a bad spec.
function Schema.Define(fields)
	local root = build({ "message", "struct", fields = fields }, "", false)
	local needs = {}
	for name in pairs(collectNeeds(root, {})) do
		needs[#needs + 1] = name
	end
	table.sort(needs)
	return setmetatable({
		minBits = root.minBits,
		maxBits = root.maxBits,
		signature = root.sig,
		fieldCount = #root.fields,
		_root = root,
		_needs = needs,
		_check = compileCheck(root),
		_codecs = setmetatable({}, { __mode = "k" }),
	}, SchemaMeta)
end

-- Same as Define, but returns false and the message instead of throwing.
function Schema.Validate(fields)
	local ok, err = pcall(Schema.Define, fields)
	if ok then
		return true
	end
	return false, tostring(err)
end

function Schema.IsSchema(value)
	return getmetatable(value) == SchemaMeta
end

-- Names of the io functions this schema uses.
function SchemaMeta:Needs()
	local out = {}
	for i, name in ipairs(self._needs) do
		out[i] = name
	end
	return out
end

-- Returns the codec { Write = fn(message), Read = fn() -> message | nil, err } for io.
function SchemaMeta:Codec(io)
	local codec = self._codecs[io]
	if codec ~= nil then
		return codec
	end
	for _, name in ipairs(self._needs) do
		if type(io[name]) ~= "function" then
			error("schema codec: io has no function " .. name, 2)
		end
	end
	local root = self._root
	local read = compileReader(root, io)
	codec = {
		schema = self,
		Write = compileWriter(root, io),
		Read = function()
			local value, err, path = read()
			if err ~= nil then
				return nil, path and path .. ": " .. err or err
			end
			return value
		end,
	}
	self._codecs[io] = codec
	return codec
end

-- Checks a message against the schema without encoding it.
-- Returns true, or false and the first problem ("scores[2]: 70000 is out of range 0..65535").
function SchemaMeta:Check(message)
	local err, path = self._check(message)
	if err == nil then
		return true
	end
	return false, path and path .. ": " .. err or err
end

return Schema
