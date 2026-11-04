-- Typed bit-stream recorder for tests: a strict stand-in for the GMod net library.
--
-- Writes append typed entries and count bits like the engine. Reads must match the type
-- and size of the next entry, so an encoder and a decoder that disagree fail loudly.
-- Reading past the end returns zero values like the engine and sets wire.overread.
-- Floats are rounded to float32 like net.WriteFloat. Entities are tables made with
-- Wire.Entity / Wire.Player; Wire.NULL stands for the engine's NULL entity.

local Wire = {}
Wire.__index = Wire

local format = string.format
local floor = math.floor

local ffiOk, ffi = pcall(require, "ffi")
local float32 = ffiOk and ffi.new("float[1]") or nil

local function roundFloat32(x)
	if float32 then
		float32[0] = x
		return tonumber(float32[0])
	end
	if x == 0 or x ~= x or x == math.huge or x == -math.huge then
		return x
	end
	local m, e = math.frexp(x)
	return math.ldexp(floor(m * 16777216 + 0.5) / 16777216, e)
end
Wire.RoundFloat32 = roundFloat32

Wire.NULL = setmetatable({ index = 0, valid = false }, { __tostring = function() return "[NULL Entity]" end })

function Wire.Entity(index, opts)
	opts = opts or {}
	return { index = index, valid = opts.valid ~= false, isPlayer = opts.player == true }
end

function Wire.Player(index)
	return Wire.Entity(index, { player = true })
end

function Wire.IsValid(value)
	return type(value) == "table" and value.valid == true
end

local function isInteger(v)
	return type(v) == "number" and v == floor(v) and v == v and v ~= math.huge and v ~= -math.huge
end

local function coordBits(v)
	local bits = 3
	for _, key in ipairs({ "x", "y", "z" }) do
		if (v[key] or 0) ~= 0 then
			bits = bits + 22
		end
	end
	return bits
end

local function copy(t)
	local out = {}
	for key, value in pairs(t) do
		out[key] = value
	end
	return out
end

-- Creates an empty wire; entries (optional) start it with recorded data.
function Wire.New(entries)
	local wire = setmetatable({ entries = entries or {}, pos = 0, bits = 0, overread = false }, Wire)
	for _, entry in ipairs(wire.entries) do
		wire.bits = wire.bits + entry.bits
	end

	local function push(kind, bits, value)
		local list = wire.entries
		list[#list + 1] = { kind = kind, bits = bits, value = value }
		wire.bits = wire.bits + bits
	end

	local function pop(kind, bits, zero)
		local entry = wire.entries[wire.pos + 1]
		if entry == nil then
			wire.overread = true
			return zero
		end
		if entry.kind ~= kind or (bits ~= nil and entry.bits ~= bits) then
			error(format("wire: read %s%s, but the next entry is %s%d", kind, bits and tostring(bits) or "",
				entry.kind, entry.bits), 3)
		end
		wire.pos = wire.pos + 1
		return entry.value
	end

	function wire.WriteBool(v)
		assert(type(v) == "boolean", "wire: WriteBool expects a boolean")
		push("bool", 1, v)
	end
	function wire.ReadBool()
		return pop("bool", 1, false)
	end

	function wire.WriteUInt(v, bits)
		assert(isInteger(bits) and bits >= 1 and bits <= 32, "wire: WriteUInt bits must be 1..32")
		assert(isInteger(v) and v >= 0 and v < 2 ^ bits, format("wire: WriteUInt(%s, %d) out of range", tostring(v), bits))
		push("uint", bits, v)
	end
	function wire.ReadUInt(bits)
		return pop("uint", bits, 0)
	end

	function wire.WriteInt(v, bits)
		assert(isInteger(bits) and bits >= 2 and bits <= 32, "wire: WriteInt bits must be 2..32")
		local half = 2 ^ (bits - 1)
		assert(isInteger(v) and v >= -half and v < half, format("wire: WriteInt(%s, %d) out of range", tostring(v), bits))
		push("int", bits, v)
	end
	function wire.ReadInt(bits)
		return pop("int", bits, 0)
	end

	function wire.WriteFloat(v)
		assert(type(v) == "number", "wire: WriteFloat expects a number")
		push("float", 32, roundFloat32(v))
	end
	function wire.ReadFloat()
		return pop("float", 32, 0)
	end

	function wire.WriteDouble(v)
		assert(type(v) == "number", "wire: WriteDouble expects a number")
		push("double", 64, v)
	end
	function wire.ReadDouble()
		return pop("double", 64, 0)
	end

	function wire.WriteString(s)
		assert(type(s) == "string", "wire: WriteString expects a string")
		s = s:match("^[^%z]*") -- the engine stops at the first zero byte
		push("string", (#s + 1) * 8, s)
	end
	function wire.ReadString()
		return pop("string", nil, "")
	end

	function wire.WriteEntity(e)
		push("entity", 13, Wire.IsValid(e) and e or Wire.NULL)
	end
	function wire.ReadEntity()
		return pop("entity", 13, Wire.NULL)
	end

	function wire.WritePlayer(p)
		push("player", 8, Wire.IsValid(p) and p.isPlayer and p or Wire.NULL)
	end
	function wire.ReadPlayer()
		return pop("player", 8, Wire.NULL)
	end

	function wire.WriteVector(v)
		assert(type(v) == "table", "wire: WriteVector expects a vector table")
		push("vector", coordBits(v), copy(v))
	end
	function wire.ReadVector()
		local v = pop("vector", nil, nil)
		return v and copy(v) or { x = 0, y = 0, z = 0 }
	end

	function wire.WriteAngle(a)
		assert(type(a) == "table", "wire: WriteAngle expects an angle table")
		push("angle", coordBits(a), copy(a))
	end
	function wire.ReadAngle()
		local a = pop("angle", nil, nil)
		return a and copy(a) or { x = 0, y = 0, z = 0 }
	end

	function wire.WriteNormal(n)
		assert(type(n) == "table", "wire: WriteNormal expects a vector table")
		push("normal", 27, copy(n))
	end
	function wire.ReadNormal()
		local n = pop("normal", 27, nil)
		return n and copy(n) or { x = 0, y = 0, z = 0 }
	end

	function wire.WriteColor(c, alpha)
		assert(type(c) == "table", "wire: WriteColor expects a color table")
		alpha = alpha ~= false
		push(alpha and "rgba" or "rgb", alpha and 32 or 24, { r = c.r, g = c.g, b = c.b, a = alpha and c.a or 255 })
	end
	function wire.ReadColor(alpha)
		alpha = alpha ~= false
		local c = pop(alpha and "rgba" or "rgb", alpha and 32 or 24, nil)
		return c and copy(c) or { r = 0, g = 0, b = 0, a = 0 }
	end

	wire.IsValid = Wire.IsValid
	return wire
end

-- Starts reading from the first entry again.
function Wire:Rewind()
	self.pos = 0
	self.overread = false
	return self
end

-- A new wire with the same recorded entries, positioned at the start.
function Wire:Copy()
	local entries = {}
	for i, entry in ipairs(self.entries) do
		entries[i] = entry
	end
	return Wire.New(entries)
end

-- Number of entries not read yet.
function Wire:Left()
	return #self.entries - self.pos
end

return Wire
