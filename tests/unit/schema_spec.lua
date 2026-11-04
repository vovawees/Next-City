local Schema = T.load("core/schema.lua")
local Wire = dofile(T.root .. "tests/support/wire.lua")

local function roundTrip(schema, message)
	local wire = Wire.New()
	schema:Codec(wire).Write(message)
	local bits = wire.bits
	local out, err = schema:Codec(wire).Read()
	return out, err, bits, wire
end

-- Writes raw entries with `fill(wire)` and decodes them with `schema`.
local function decodeRaw(schema, fill)
	local wire = Wire.New()
	fill(wire)
	return schema:Codec(wire).Read()
end

local function defineError(fields)
	local ok, err = Schema.Validate(fields)
	expect(ok):toBe(false)
	return err
end

describe("schema sizes", function()
	it("counts bits for integers", function()
		expect(Schema.BitsFor(0)):toBe(1)
		expect(Schema.BitsFor(1)):toBe(1)
		expect(Schema.BitsFor(2)):toBe(2)
		expect(Schema.BitsFor(3)):toBe(2)
		expect(Schema.BitsFor(4)):toBe(3)
		expect(Schema.BitsFor(255)):toBe(8)
		expect(Schema.BitsFor(256)):toBe(9)
		expect(Schema.BitsFor(4294967295)):toBe(32)
	end)

	it("computes exact bounds for fixed-size fields", function()
		local function size(field)
			local schema = Schema.Define({ field })
			return { schema.minBits, schema.maxBits }
		end
		expect(size({ "v", "bool" })):toEqual({ 1, 1 })
		expect(size({ "v", "uint", bits = 8 })):toEqual({ 8, 8 })
		expect(size({ "v", "uint", max = 100 })):toEqual({ 7, 7 })
		expect(size({ "v", "int", bits = 12 })):toEqual({ 12, 12 })
		expect(size({ "v", "int", min = -10, max = 10 })):toEqual({ 5, 5 })
		expect(size({ "v", "float" })):toEqual({ 32, 32 })
		expect(size({ "v", "double" })):toEqual({ 64, 64 })
		expect(size({ "v", "quant", min = 0, max = 1 })):toEqual({ 16, 16 })
		expect(size({ "v", "quant", min = 0, max = 1, bits = 6 })):toEqual({ 6, 6 })
		expect(size({ "v", "enum", values = { "a", "b", "c" } })):toEqual({ 2, 2 })
		expect(size({ "v", "enum", values = { "only" } })):toEqual({ 1, 1 })
		expect(size({ "v", "entity" })):toEqual({ 13, 13 })
		expect(size({ "v", "player" })):toEqual({ 8, 8 })
		expect(size({ "v", "color" })):toEqual({ 32, 32 })
		expect(size({ "v", "color", alpha = false })):toEqual({ 24, 24 })
	end)

	it("computes bounds for variable-size fields", function()
		local function size(field)
			local schema = Schema.Define({ field })
			return { schema.minBits, schema.maxBits }
		end
		expect(size({ "v", "string", max = 32 })):toEqual({ 8, 264 })
		expect(size({ "v", "array", max = 4, of = { "uint", bits = 16 } })):toEqual({ 3, 67 })
		expect(size({ "v", "bool", optional = true })):toEqual({ 1, 2 })
		expect(size({ "v", "struct", fields = { { "a", "bool" }, { "b", "uint", bits = 4, optional = true } } }))
			:toEqual({ 2, 6 })
	end)

	it("matches the bits a message actually takes", function()
		local schema = Schema.Define({
			{ "id", "uint", bits = 10 },
			{ "name", "string", max = 16 },
			{ "tags", "array", max = 3, of = { "enum", values = { "a", "b" } } },
			{ "extra", "float", optional = true },
		})
		local _, _, bits = roundTrip(schema, { id = 5, name = "abc", tags = { "a", "b" } })
		expect(bits):toBe(10 + 32 + 2 + 2 + 1)
		expect(bits >= schema.minBits and bits <= schema.maxBits):toBe(true)
	end)
end)

describe("schema round trip", function()
	it("encodes and decodes every type", function()
		local schema = Schema.Define({
			{ "flag", "bool" },
			{ "count", "uint", bits = 12 },
			{ "level", "uint", max = 100 },
			{ "delta", "int", bits = 8 },
			{ "offset", "int", min = -1000, max = 1000 },
			{ "speed", "float" },
			{ "time", "double" },
			{ "ratio", "quant", min = 0, max = 1, bits = 8 },
			{ "name", "string", max = 32 },
			{ "phase", "enum", values = { "waiting", "active", "ended" } },
			{ "code", "enum", values = { 10, 20, 30 } },
			{ "scores", "array", max = 4, of = { "uint", bits = 16 } },
			{ "pos", "struct", fields = { { "x", "float" }, { "y", "float" } } },
			{ "target", "entity" },
			{ "owner", "player" },
			{ "origin", "vector" },
			{ "view", "angle" },
			{ "up", "normal" },
			{ "tint", "color" },
			{ "note", "string", optional = true },
			{ "missing", "uint", bits = 4, optional = true },
		})
		local target, owner = Wire.Entity(42), Wire.Player(3)
		local message = {
			flag = true, count = 4095, level = 100, delta = -128, offset = -999, speed = 1.5, time = 123456.789,
			ratio = 1, name = "Vovawe", phase = "ended", code = 20, scores = { 1, 65535, 0 },
			pos = { x = -2.25, y = 1024 }, target = target, owner = owner,
			origin = { x = 1, y = 2, z = 3 }, view = { x = 0, y = 90, z = 0 }, up = { x = 0, y = 0, z = 1 },
			tint = { r = 10, g = 20, b = 30, a = 40 }, note = "hi",
		}
		expect(schema:Check(message)):toBe(true)
		local out, err, _, wire = roundTrip(schema, message)
		expect(err):toBeNil()
		expect(out):toEqual(message)
		expect(wire:Left()):toBe(0)
		expect(wire.overread):toBe(false)
	end)

	it("handles an empty schema", function()
		local schema = Schema.Define({})
		expect(schema.minBits):toBe(0)
		expect(schema.maxBits):toBe(0)
		local out, err, bits = roundTrip(schema, nil)
		expect(err):toBeNil()
		expect(out):toEqual({})
		expect(bits):toBe(0)
	end)

	it("rounds floats to float32 like the engine", function()
		local schema = Schema.Define({ { "v", "float" } })
		local out = roundTrip(schema, { v = 0.1 })
		expect(out.v):toBe(Wire.RoundFloat32(0.1))
		expect(out.v == 0.1):toBe(false)
	end)

	it("quantizes within half a step", function()
		local schema = Schema.Define({ { "v", "quant", min = -1, max = 1, bits = 8 } })
		local step = 2 / 255
		for _, value in ipairs({ -1, -0.5, 0, 0.123, 0.5, 0.999, 1 }) do
			local out = roundTrip(schema, { v = value })
			expect(math.abs(out.v - value) <= step / 2 + 1e-12):toBe(true)
			expect(out.v >= -1 and out.v <= 1):toBe(true)
		end
		expect(roundTrip(schema, { v = -1 }).v):toBe(-1)
		expect(roundTrip(schema, { v = 1 }).v):toBe(1)
	end)

	it("keeps optional fields absent", function()
		local schema = Schema.Define({ { "a", "uint", bits = 4, optional = true }, { "b", "bool", optional = true } })
		local out, _, bits = roundTrip(schema, { b = false })
		expect(out):toEqual({ b = false })
		expect(bits):toBe(1 + 1 + 1)
	end)
end)

describe("schema writers coerce", function()
	it("clamps and floors integers", function()
		local schema = Schema.Define({
			{ "a", "uint", max = 100 }, { "b", "uint", bits = 8 }, { "c", "uint", bits = 8 },
			{ "d", "int", min = -5, max = 5 }, { "e", "int", bits = 4 }, { "f", "uint", bits = 8 },
		})
		local out = roundTrip(schema, { a = 500, b = -3, c = 7.9, d = -50, e = 100, f = 0 / 0 })
		expect(out):toEqual({ a = 100, b = 0, c = 7, d = -5, e = 7, f = 0 })
	end)

	it("replaces NaN and clamps reals", function()
		local schema = Schema.Define({
			{ "a", "float" }, { "b", "float", min = 1, max = 2 }, { "c", "float" }, { "d", "double", min = 0 },
			{ "e", "float", finite = false }, { "f", "quant", min = 0, max = 10 },
		})
		local out = roundTrip(schema, { a = 0 / 0, b = 0 / 0, c = math.huge, d = -1, e = -math.huge, f = 0 / 0 })
		expect(out.a):toBe(0)
		expect(out.b):toBe(1)
		expect(out.c):toBe(3.4028234663852886e38)
		expect(out.d):toBe(0)
		expect(out.e):toBe(-math.huge)
		expect(out.f):toBe(0)
	end)

	it("truncates strings and arrays", function()
		local schema = Schema.Define({
			{ "name", "string", max = 4 },
			{ "list", "array", max = 2, of = "bool" },
		})
		local out = roundTrip(schema, { name = "abcdefgh", list = { true, false, true, true } })
		expect(out):toEqual({ name = "abcd", list = { true, false } })
	end)

	it("replaces values of a wrong type with defaults", function()
		local schema = Schema.Define({
			{ "a", "uint", bits = 4 }, { "b", "string" }, { "c", "bool" }, { "d", "enum", values = { "x", "y" } },
			{ "e", "array", max = 3, of = "bool" }, { "f", "struct", fields = { { "g", "uint", bits = 2 } } },
		})
		local out = roundTrip(schema, { a = "7", b = 5, c = nil, d = "zzz", e = "list", f = 1 })
		expect(out):toEqual({ a = 0, b = "", c = false, d = "x", e = {}, f = { g = 0 } })
	end)

	it("never throws on garbage messages", function()
		local schema = Schema.Define({
			{ "a", "uint", bits = 4 }, { "s", "struct", fields = { { "x", "float" } } },
			{ "list", "array", max = 2, of = { "struct", fields = { { "y", "int", min = 0, max = 3 } } } },
		})
		for _, garbage in ipairs({ 42, "text", true, { a = {}, s = "x", list = { 1, "2" } } }) do
			local out, err = roundTrip(schema, garbage)
			expect(err):toBeNil()
			expect(type(out)):toBe("table")
		end
	end)
end)

describe("schema readers validate", function()
	it("rejects integers above a non-power-of-two maximum", function()
		local schema = Schema.Define({ { "level", "uint", max = 100 } })
		local out, err = decodeRaw(schema, function(w) w.WriteUInt(127, 7) end)
		expect(out):toBeNil()
		expect(err):toBe("level: 127 is above the maximum 100")
		schema = Schema.Define({ { "offset", "int", min = -10, max = 10 } })
		out, err = decodeRaw(schema, function(w) w.WriteUInt(25, 5) end)
		expect(out):toBeNil()
		expect(err):toBe("offset: 15 is above the maximum 10")
	end)

	it("rejects NaN, infinities and out-of-range reals", function()
		local schema = Schema.Define({ { "v", "float" } })
		expect(select(2, decodeRaw(schema, function(w) w.WriteFloat(0 / 0) end))):toBe("v: NaN is not allowed")
		expect(select(2, decodeRaw(schema, function(w) w.WriteFloat(math.huge) end))):toContain("out of range")
		schema = Schema.Define({ { "v", "double", min = 0, max = 1 } })
		expect(select(2, decodeRaw(schema, function(w) w.WriteDouble(1.5) end))):toContain("out of range")
		expect(select(2, decodeRaw(schema, function(w) w.WriteDouble(-0.1) end))):toContain("out of range")
		schema = Schema.Define({ { "v", "float", finite = false } })
		expect(decodeRaw(schema, function(w) w.WriteFloat(-math.huge) end).v):toBe(-math.huge)
		expect(select(2, decodeRaw(schema, function(w) w.WriteFloat(0 / 0) end))):toBe("v: NaN is not allowed")
	end)

	it("accepts bounds moved by float32 rounding and clamps them back", function()
		local schema = Schema.Define({ { "v", "float", min = -0.1, max = 0.1 } })
		expect(Wire.RoundFloat32(0.1) > 0.1):toBe(true)
		local out = roundTrip(schema, { v = 0.1 })
		expect(out.v):toBe(0.1)
		expect(roundTrip(schema, { v = -0.1 }).v):toBe(-0.1)
		local _, err = decodeRaw(schema, function(w) w.WriteFloat(0.11) end)
		expect(err):toContain("out of range")
	end)

	it("rejects long strings, long arrays and bad enum indexes", function()
		local schema = Schema.Define({ { "name", "string", max = 8 } })
		local _, err = decodeRaw(schema, function(w) w.WriteString(("x"):rep(9)) end)
		expect(err):toBe("name: string of 9 bytes is longer than 8")
		schema = Schema.Define({ { "list", "array", max = 4, of = "bool" } })
		_, err = decodeRaw(schema, function(w) w.WriteUInt(7, 3) end)
		expect(err):toBe("list: array of 7 elements is longer than 4")
		schema = Schema.Define({ { "phase", "enum", values = { "a", "b", "c" } } })
		_, err = decodeRaw(schema, function(w) w.WriteUInt(3, 2) end)
		expect(err):toBe("phase: enum index 3 is out of range (3 values)")
	end)

	it("reports the path of a nested error", function()
		local schema = Schema.Define({
			{ "items", "array", max = 4, of = { "struct", fields = {
				{ "name", "string", max = 4 },
				{ "tags", "array", max = 2, of = { "enum", values = { "a", "b", "c" } } },
			} } },
		})
		local _, err = decodeRaw(schema, function(w)
			w.WriteUInt(2, 3)
			w.WriteString("ok")
			w.WriteUInt(0, 2)
			w.WriteString("ok")
			w.WriteUInt(2, 2)
			w.WriteUInt(0, 2)
			w.WriteUInt(3, 2)
		end)
		expect(err):toBe("items[2].tags[2]: enum index 3 is out of range (3 values)")
	end)

	it("rejects invalid entities only when asked to", function()
		local schema = Schema.Define({ { "target", "entity", valid = true }, { "other", "player" } })
		local out, err = decodeRaw(schema, function(w)
			w.WriteEntity(nil)
			w.WritePlayer(nil)
		end)
		expect(out):toBeNil()
		expect(err):toBe("target: invalid entity")
		out = decodeRaw(schema, function(w)
			w.WriteEntity(Wire.Entity(7))
			w.WritePlayer(nil)
		end)
		expect(out.target.index):toBe(7)
		expect(out.other):toBe(Wire.NULL)
	end)
end)

describe("schema checks", function()
	local schema = Schema.Define({
		{ "phase", "enum", values = { "waiting", "active" } },
		{ "time", "float", min = 0 },
		{ "scores", "array", max = 2, of = { "uint", bits = 8 } },
		{ "leader", "struct", optional = true, fields = { { "name", "string", max = 4 } } },
	})

	it("accepts a valid message", function()
		expect(schema:Check({ phase = "active", time = 3, scores = { 1, 2 } })):toBe(true)
		expect(schema:Check({ phase = "active", time = 3, scores = {}, leader = { name = "abc" } })):toBe(true)
	end)

	it("reports the first problem with its path", function()
		local function problem(message)
			local ok, err = schema:Check(message)
			expect(ok):toBe(false)
			return err
		end
		expect(problem({ phase = "active", time = 3, scores = {}, endsAt = 1 })):toBe("unknown field string \"endsAt\"")
		expect(problem({ phase = "paused", time = 3, scores = {} })):toBe("phase: unknown enum value string \"paused\"")
		expect(problem({ phase = "active", time = -1, scores = {} })):toBe("time: -1 is out of range 0..")
		expect(problem({ phase = "active", time = 0 / 0, scores = {} })):toContain("time: expected a number")
		expect(problem({ phase = "active", time = 1, scores = { 1, 256 } })):toBe("scores[2]: 256 is out of range 0..255")
		expect(problem({ phase = "active", time = 1, scores = { 1, 2, 3 } }))
			:toBe("scores: array of 3 elements is longer than 2")
		expect(problem({ phase = "active", time = 1, scores = {}, leader = { name = "toolong" } }))
			:toBe("leader.name: string of 7 bytes is longer than 4")
		expect(problem("nope")):toBe("expected a table, got string \"nope\"")
	end)
end)

describe("schema definition errors", function()
	it("rejects unknown types and options", function()
		expect(defineError({ { "a", "vec" } })):toBe("schema: a: unknown type string \"vec\"")
		expect(defineError({ { "a", "uint", bit = 8 } })):toBe("schema: a: unknown option 'bit' for uint")
		expect(defineError({ { "a", "bool", 5 } })):toBe("schema: a: unexpected positional value 5")
		expect(defineError({ { "a", "bool", optional = "yes" } })):toBe("schema: a: optional must be a boolean")
	end)

	it("rejects bad field lists", function()
		expect(defineError(nil)):toBe("schema: fields must be an array of { name, type, options... }")
		expect(defineError({ "a" })):toBe("schema: field 1 must be a table { name, type, options... }")
		expect(defineError({ { 1, "bool" } })):toBe("schema: field 1 needs a name (identifier) first, got 1")
		expect(defineError({ { "a b", "bool" } })):toContain("needs a name")
		expect(defineError({ { "a", "bool" }, { "a", "uint", bits = 2 } })):toBe("schema: a: field is defined twice")
	end)

	it("rejects inconsistent numeric options", function()
		expect(defineError({ { "a", "uint" } })):toBe("schema: a: uint needs bits or max")
		expect(defineError({ { "a", "uint", bits = 33 } })):toBe("schema: a: bits must be an integer 1..32")
		expect(defineError({ { "a", "uint", bits = 4, max = 16 } })):toBe("schema: a: max 16 does not fit into 4 bits")
		expect(defineError({ { "a", "int", bits = 8, min = 0, max = 1 } })):toContain("either bits or min and max")
		expect(defineError({ { "a", "int", min = 5, max = 1 } })):toBe("schema: a: min 5 is above max 1")
		expect(defineError({ { "a", "int", min = 0, max = 2 ^ 40 } })):toContain("needs more than 32 bits")
		expect(defineError({ { "a", "float", min = 0 / 0 } })):toBe("schema: a: min must be a finite number")
		expect(defineError({ { "a", "quant", min = 1, max = 1 } })):toBe("schema: a: quant needs finite min < max")
		expect(defineError({ { "a", "string", max = 0 } })):toBe("schema: a: max must be an integer 1..65535")
	end)

	it("rejects bad enums and arrays", function()
		expect(defineError({ { "a", "enum", values = {} } })):toBe("schema: a: enum needs a non-empty array of values")
		expect(defineError({ { "a", "enum", values = { "x", "x" } } }))
			:toBe("schema: a: enum value string \"x\" is listed twice")
		expect(defineError({ { "a", "enum", values = { "x", true } } }))
			:toBe("schema: a: enum value 2 must be a string or a finite number")
		expect(defineError({ { "a", "array", of = "bool" } })):toBe("schema: a: array needs max, an integer 1..65535")
		expect(defineError({ { "a", "array", max = 2 } })):toBe("schema: a: array needs an element type (of)")
		expect(defineError({ { "a", "array", max = 2, of = { "bool", optional = true } } }))
			:toBe("schema: a[]: array elements cannot be optional")
		expect(defineError({ { "a", "array", max = 2, of = { "struct", fields = { { "b", "nope" } } } } }))
			:toBe("schema: a[].b: unknown type string \"nope\"")
	end)

	it("Define throws the same message", function()
		expect(function() Schema.Define({ { "a", "vec" } }) end):toFail("unknown type")
	end)
end)

describe("schema objects", function()
	it("builds a stable signature from the wire format", function()
		local a = Schema.Define({ { "x", "uint", bits = 4 }, { "e", "enum", values = { "a", "b" } } })
		local b = Schema.Define({ { "x", "uint", bits = 4 }, { "e", "enum", values = { "a", "b" } } })
		local c = Schema.Define({ { "x", "uint", bits = 4 }, { "e", "enum", values = { "b", "a" } } })
		local d = Schema.Define({
			{ "x", "uint", bits = 4, desc = "documentation only" },
			{ "e", "enum", values = { "a", "b" } },
		})
		expect(a.signature):toBe(b.signature)
		expect(a.signature):toBe(d.signature)
		expect(a.signature == c.signature):toBe(false)
		expect(a.signature):toBe("{x:u4;e:e{\"a\",\"b\"}}")
	end)

	it("caches codecs per io and checks the io", function()
		local schema = Schema.Define({ { "target", "entity", valid = true } })
		local wire = Wire.New()
		expect(schema:Codec(wire)):toBe(schema:Codec(wire))
		expect(schema:Needs()):toEqual({ "IsValid", "ReadEntity", "WriteEntity" })
		expect(function() schema:Codec({ WriteEntity = print, ReadEntity = print }) end)
			:toFail("io has no function IsValid")
		expect(Schema.IsSchema(schema)):toBe(true)
		expect(Schema.IsSchema({})):toBe(false)
	end)

	it("rounds to float32 like a C cast", function()
		for _, value in ipairs({ 0.1, 1 / 3, -2.5, 123456.789, 1e-40, 3e38, 3.5e38, -3.5e38, 0, 2 ^ -149 }) do
			expect(Schema.RoundFloat32(value)):toBe(Wire.RoundFloat32(value))
		end
	end)
end)
