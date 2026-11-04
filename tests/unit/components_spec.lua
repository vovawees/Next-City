local Components = T.load("core/components.lua")

local VITALS = {
	fields = {
		{ "blood", "quant", min = 0, max = 5000, bits = 12 },
		{ "pulse", "uint", max = 250 },
		{ "conscious", "bool" },
	},
	defaults = { blood = 5000, conscious = true },
}

local function vitals(opts)
	return Components.New("vitals", VITALS, opts)
end

local function dirtyOf(store)
	local out = {}
	store:_TakeDirty(function(key, mask)
		out[key] = mask
	end)
	return out
end

local function specError(spec, opts)
	local ok, err = Components.Validate("probe", spec, opts)
	expect(ok):toBe(false)
	return err
end

describe("component specs", function()
	it("accepts fields with defaults and zero values", function()
		expect(Components.Validate("vitals", VITALS)):toBe(true)
		local store = vitals()
		expect(store.names):toEqual({ "blood", "pulse", "conscious" })
		expect(store.defaults):toEqual({ blood = 5000, pulse = 0, conscious = true })
		expect(store.all):toBe(7)
	end)

	it("gives every simple type a zero value", function()
		local store = Components.New("zeros", { fields = {
			{ "flag", "bool" },
			{ "count", "uint", bits = 8 },
			{ "shift", "int", min = -10, max = -2 },
			{ "level", "int", min = 3, max = 9 },
			{ "ratio", "float", min = -1, max = 1 },
			{ "heat", "quant", min = 20, max = 40, bits = 8 },
			{ "label", "string", max = 8 },
			{ "phase", "enum", values = { "idle", "busy" } },
			{ "items", "array", max = 4, of = "uint" },
			{ "owner", "entity" },
		} }, { zero = { entity = "NULL" } })
		expect(store.defaults):toEqual({
			flag = false, count = 0, shift = -2, level = 3, ratio = 0, heat = 20, label = "", phase = "idle",
			items = {}, owner = "NULL",
		})
	end)

	it("rejects bad specs with readable messages", function()
		expect(specError({ fields = {} })):toContain("fields must be a non-empty array")
		expect(specError({ fields = { { "a", "uint" } }, extra = 1 })):toContain("unknown key 'extra'")
		expect(specError({ fields = { { "a", "uint", optional = true } } })):toContain("field 'a' cannot be optional")
		expect(specError({ fields = { { "_a", "uint" } } })):toContain("field 1 needs a name that starts with a letter")
		expect(specError({ fields = { { "a", "uint" }, { "a", "bool" } } })):toContain("field 'a' is defined twice")
		expect(specError({ fields = { { "a", "uint" } }, defaults = { b = 1 } })):toContain("default for unknown field \"b\"")
		expect(specError({ fields = { { "a", "uint" } }, defaults = 5 })):toContain("defaults must be a table")
		expect(specError({ fields = { { "pos", "vector" } } })):toContain("field 'pos' (vector) needs a default")
		expect(specError({ fields = { { "tint", "color" } } })):toContain("field 'tint' (color) needs a default")
		expect(specError({ fields = { "a" } })):toContain("field 1 must be a table")
		local many = {}
		for i = 1, 32 do
			many[i] = { "f" .. i, "bool" }
		end
		expect(specError({ fields = many })):toContain("32 fields, at most 31")
		local ok, err = Components.Validate("Bad Name", { fields = { { "a", "uint" } } })
		expect(ok):toBe(false)
		expect(err):toContain("component name \"Bad Name\" must be a snake_case id")
		expect(function() Components.New("probe", { fields = {} }) end):toFail("component 'probe': fields")
	end)

	it("uses engine zero values from opts", function()
		local ok = Components.Validate("probe", { fields = { { "pos", "vector" } } }, { zero = { vector = {} } })
		expect(ok):toBe(true)
	end)
end)

describe("component stores", function()
	it("adds data from defaults and given values", function()
		local store = vitals()
		local data = store:Add(7, { pulse = 80 })
		expect(data):toEqual({ blood = 5000, pulse = 80, conscious = true })
		expect(store:Get(7)):toBe(data)
		expect(store:Has(7)):toBe(true)
		expect(store:Has(8)):toBe(false)
		expect(store:Get(8)):toBeNil()
		expect(store:Count()):toBe(1)
		-- Add replaces.
		local fresh = store:Add(7)
		expect(fresh):notToBe(data)
		expect(fresh.pulse):toBe(0)
		expect(store:Count()):toBe(1)
	end)

	it("copies defaults for every key", function()
		local store = Components.New("bag", { fields = { { "items", "array", max = 4, of = "uint" } },
			defaults = { items = { 1, 2 } } })
		local a, b = store:Add(1), store:Add(2)
		table.insert(a.items, 3)
		expect(b.items):toEqual({ 1, 2 })
		expect(store.defaults.items):toEqual({ 1, 2 })
		local copies = 0
		local custom = Components.New("bag", { fields = { { "n", "uint" } } }, {
			copy = function(value)
				copies = copies + 1
				return value
			end,
		})
		custom:Add(1)
		expect(copies):toBe(1)
	end)

	it("sets fields and reports changes", function()
		local store = vitals()
		store:Add(7)
		expect(store:Set(7, "pulse", 120)):toBe(true)
		expect(store:Set(7, "pulse", 120)):toBe(false)
		expect(store:Get(7).pulse):toBe(120)
		expect(store:Patch(7, { pulse = 120, blood = 4000 })):toBe(1)
		expect(store:Patch(7, { pulse = 90, conscious = false })):toBe(6)
		expect(store:Patch(7, { pulse = 90 })):toBe(0)
		expect(store:Get(7)):toEqual({ blood = 4000, pulse = 90, conscious = false })
	end)

	it("rejects writes to unknown keys and fields", function()
		local store = vitals()
		store:Add(7)
		expect(function() store:Set(8, "pulse", 1) end):toFail("component 'vitals' has no data for key 8 (Add it first)")
		expect(function() store:Set(7, "pulsee", 1) end):toFail("component 'vitals' has no field \"pulsee\"")
		expect(function() store:Patch(7, { pulse = 1, nope = 2 }) end):toFail("has no field \"nope\"")
		-- A failed Patch changes nothing.
		expect(store:Get(7).pulse):toBe(0)
		expect(function() store:Add(0) end):toFail("key must be an entity or a positive entity index, got 0")
		expect(function() store:Add(1.5) end):toFail("got 1.5")
		expect(function() store:Add("x") end):toFail("got \"x\"")
		expect(function() store:Add(9, { nope = 1 }) end):toFail("has no field \"nope\"")
		expect(store:Has(9)):toBe(false)
		expect(function() store:Touch(7, "nope") end):toFail("has no field \"nope\"")
		expect(function() store:Changed(1, "nope") end):toFail("has no field \"nope\"")
	end)

	it("removes keys and iterates the rest", function()
		local store = vitals()
		store:Add(1)
		store:Add(2)
		store:Add(3)
		expect(store:Remove(2)):toBe(true)
		expect(store:Remove(2)):toBe(false)
		expect(store:Count()):toBe(2)
		local seen = {}
		for key, data in store:Each() do
			seen[#seen + 1] = key
			expect(data.blood):toBe(5000)
		end
		table.sort(seen)
		expect(seen):toEqual({ 1, 3 })
		store:Clear()
		expect(store:Count()):toBe(0)
		expect(store:Get(1)):toBeNil()
	end)

	it("converts other keys with keyOf and checks them with admit", function()
		local players = { alyx = 3 }
		local store = vitals({
			keyOf = function(key)
				return players[key]
			end,
			admit = function(index)
				if index > 128 then
					return "keys must be players"
				end
			end,
		})
		store:Add("alyx")
		expect(store:Get(3)):toBe(store:Get("alyx"))
		expect(store:Set("alyx", "pulse", 60)):toBe(true)
		expect(store:Get(3).pulse):toBe(60)
		expect(store:Get("nobody")):toBeNil()
		expect(store:Get(nil)):toBeNil()
		expect(store:Remove("nobody")):toBe(false)
		expect(function() store:Add("nobody") end):toFail("key must be an entity or a positive entity index, got \"nobody\"")
		expect(function() store:Add(200) end):toFail("component 'vitals': keys must be players")
		expect(store:Remove("alyx")):toBe(true)
	end)

	it("tests masks of changed fields", function()
		local store = vitals()
		expect(store:Changed(3, "blood")):toBe(true)
		expect(store:Changed(3, "pulse")):toBe(true)
		expect(store:Changed(3, "conscious")):toBe(false)
	end)
end)

describe("component dirty tracking", function()
	it("marks added, set, patched and touched fields", function()
		local store = vitals({ track = true })
		store:Add(1)
		store:Add(2)
		expect(dirtyOf(store)):toEqual({ [1] = 7, [2] = 7 })
		expect(dirtyOf(store)):toEqual({})
		store:Set(1, "pulse", 100)
		store:Set(1, "pulse", 100)
		store:Set(2, "blood", 5000)
		expect(dirtyOf(store)):toEqual({ [1] = 2 })
		store:Patch(2, { blood = 10, conscious = false })
		store:Get(1).pulse = 50
		store:Touch(1, "pulse")
		expect(dirtyOf(store)):toEqual({ [1] = 2, [2] = 5 })
		expect(store:Touch(1)):toBe(true)
		expect(store:Touch(9)):toBe(false)
		expect(dirtyOf(store)):toEqual({ [1] = 7 })
	end)

	it("counts table values as changed", function()
		local store = Components.New("bag", { fields = { { "items", "array", max = 4, of = "uint" } } }, { track = true })
		local data = store:Add(1)
		dirtyOf(store)
		expect(store:Set(1, "items", data.items)):toBe(true)
		expect(dirtyOf(store)):toEqual({ [1] = 1 })
	end)

	it("records removed keys once and drops their dirty marks", function()
		local store = vitals({ track = true })
		store:Add(1)
		store:Add(2)
		dirtyOf(store)
		store:Set(1, "pulse", 1)
		store:Remove(1)
		expect(store:_HasChanges()):toBe(true)
		expect(dirtyOf(store)):toEqual({})
		expect(store:_TakeRemoved()):toEqual({ 1 })
		expect(store:_TakeRemoved()):toEqual({})
		expect(store:_HasChanges()):toBe(false)
		-- A key removed and added again in one flush: removal first, then every field.
		store:Remove(2)
		store:Add(2)
		expect(store:_TakeRemoved()):toEqual({ 2 })
		expect(dirtyOf(store)):toEqual({ [2] = 7 })
		store:Set(2, "pulse", 3)
		store:Remove(2)
		store:_ClearChanges()
		expect(store:_HasChanges()):toBe(false)
	end)

	it("keeps no marks without track", function()
		local store = vitals()
		store:Add(1)
		store:Set(1, "pulse", 5)
		store:Remove(1)
		expect(store:_HasChanges()):toBe(false)
	end)
end)

describe("component mirrors", function()
	local function mirror(opts)
		opts = opts or {}
		opts.mirror = true
		return vitals(opts)
	end

	it("is read-only for modules", function()
		local store = mirror()
		local message = "component 'vitals' is a read-only mirror: only the server changes it"
		expect(function() store:Add(1) end):toFail(message)
		expect(function() store:Set(1, "pulse", 1) end):toFail(message)
		expect(function() store:Patch(1, {}) end):toFail(message)
		expect(function() store:Touch(1) end):toFail(message)
		expect(function() store:Remove(1) end):toFail(message)
		expect(function() store:Clear() end):toFail(message)
		expect(function() vitals():OnChange(function() end) end):toFail("OnChange is for mirrors")
	end)

	it("applies received fields and notifies listeners", function()
		local store = mirror()
		local seen = {}
		local off = store:OnChange(function(key, data, mask)
			seen[#seen + 1] = { key, data and data.pulse, mask }
		end)
		local data = store:_Apply(4, { _key = 4, pulse = 90 })
		expect(data):toEqual({ blood = 5000, pulse = 90, conscious = true })
		expect(store:_Apply(4, { blood = 10 })):toBe(data)
		expect(data.blood):toBe(10)
		expect(store:Count()):toBe(1)
		expect(store:_ApplyRemove(4)):toBe(true)
		expect(store:_ApplyRemove(4)):toBe(false)
		expect(seen):toEqual({ { 4, 90, 2 }, { 4, 90, 1 }, { 4, nil, 0 } })
		off()
		store:_Apply(5, { pulse = 1 })
		expect(#seen):toBe(3)
	end)

	it("resets every key with notifications", function()
		local store = mirror()
		store:_Apply(1, { pulse = 1 })
		store:_Apply(2, { pulse = 2 })
		local removed = {}
		store:OnChange(function(key, data)
			if data == nil then
				removed[#removed + 1] = key
			end
		end)
		store:_Reset()
		table.sort(removed)
		expect(removed):toEqual({ 1, 2 })
		expect(store:Count()):toBe(0)
	end)

	it("binds handlers and isolates failing listeners", function()
		local errors = {}
		local store = mirror({
			bind = function(handler)
				return function(...)
					return handler.fn(...)
				end
			end,
			onError = function(err, name)
				errors[#errors + 1] = name .. ": " .. err
			end,
		})
		local calls = 0
		store:OnChange({ fn = function() error("listener broke") end })
		store:OnChange({ fn = function() calls = calls + 1 end })
		store:_Apply(1, { pulse = 1 })
		expect(calls):toBe(1)
		expect(#errors):toBe(1)
		expect(errors[1]):toContain("vitals: ")
		expect(errors[1]):toContain("listener broke")
		expect(function() mirror():OnChange(42) end):toFail("OnChange needs a function")
		store:_ClearListeners()
		store:_Apply(1, { pulse = 2 })
		expect(calls):toBe(1)
	end)
end)

describe("component adoption", function()
	it("moves data between stores with the same fields", function()
		local old = vitals({ track = true })
		old:Add(1, { pulse = 33 })
		old:Remove(1)
		old:Add(2, { pulse = 44 })
		local fresh = vitals({ track = true })
		expect(fresh:_Adopt(old)):toBe(true)
		expect(fresh:Get(2).pulse):toBe(44)
		expect(fresh:Count()):toBe(1)
		expect(fresh:_HasChanges()):toBe(false)
		expect(old:Count()):toBe(0)
		expect(old:Get(2)):toBeNil()
		expect(old:_HasChanges()):toBe(false)
		local other = Components.New("vitals", { fields = { { "blood", "uint" } } })
		expect(other:_Adopt(fresh)):toBe(false)
		expect(fresh:Count()):toBe(1)
	end)
end)
