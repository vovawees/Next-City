-- Next-City core: component stores, per-entity data kept outside entity tables.
--
-- Pure Lua (LuaJIT 2.x), no GMod API. A store holds the data of one component for many
-- keys (entity indexes): a table of fields per key. The platform turns entities into
-- keys, removes data with its entity and replicates changes with the dirty masks a
-- store keeps (platform/components.lua, docs/ARCHITECTURE.md, section 8).
--
--   local vitals = Components.New("vitals", {
--       fields = { { "blood", "quant", min = 0, max = 5000, bits = 12 }, { "pulse", "uint", max = 250 } },
--       defaults = { blood = 5000 },
--   }, { track = true })
--   local data = vitals:Add(7)    -- defaults (pulse starts at 0), then the given values
--   vitals:Set(7, "pulse", 120)   -- true if the value changed; the field becomes dirty
--   data.blood = data.blood - 10  -- direct writes are fine in hot loops...
--   vitals:Touch(7, "blood")      -- ...followed by Touch
--   vitals:Remove(7)
--
-- Fields use the syntax of core/schema.lua (the platform checks the types): at most 31,
-- none optional, names start with a letter. A field without a default starts at its
-- zero value: false, 0 (or the bound of its range closest to 0), "", the first enum
-- value, an empty array or opts.zero[type] (engine types); other fields need a default.
-- Data tables belong to the store: read them freely, write through Set / Patch or mark
-- direct writes with Touch. Values given to Add, Set and Patch are stored as they are.
--
-- A mirror (opts.mirror) is the read-only copy of a replicated component on a client:
-- the platform applies what arrives and OnChange listeners learn which fields changed.
--
-- opts:
--   keyOf(key) -> index | nil   index of a key that is not a number (an entity)
--   admit(index) -> problem     checks a key on Add (e.g. "keys must be players")
--   copy(value) -> value        copies defaults for every key (default: tables, deeply)
--   zero                        { [type] = value }: zero values of engine types
--   track                       keep dirty masks and removed keys for replication
--   mirror                      read-only copy with change listeners
--   bind(handler) -> fn         turns OnChange handlers (e.g. method names) into functions
--   onError(err, name)          a listener failed (default: print)
-- Methods starting with an underscore are for the platform.

local Components = {}

local type = type
local pairs = pairs
local ipairs = ipairs
local next = next
local tostring = tostring
local setmetatable = setmetatable
local getmetatable = getmetatable
local xpcall = xpcall
local pcall = pcall
local print = print
local format = string.format
local traceback = debug.traceback
local band = bit.band
local bor = bit.bor

local MAX_FIELDS = 31
local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local FIELD_PATTERN = "^%a[%w_]*$"
local SPEC_KEYS = { fields = true, defaults = true }
local NUMERIC = { uint = true, int = true, float = true, double = true, quant = true }
local EMPTY = {}

Components.MAX_FIELDS = MAX_FIELDS

local function describe(value)
	if type(value) == "string" then
		return format("%q", value)
	end
	return tostring(value)
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for key, item in pairs(value) do
		out[key] = deepCopy(item)
	end
	return setmetatable(out, getmetatable(value))
end

local function defaultOnError(err, name)
	print("[components] listener of '" .. tostring(name) .. "' failed: " .. tostring(err))
end

local function onListenerError(err)
	return traceback(tostring(err), 2)
end

-- Zero value of a field, or nil if the type has none.
local function zeroOf(field, zero)
	local kind = field[2]
	if kind == "bool" then
		return false
	end
	if NUMERIC[kind] then
		local low, high = field.min, field.max
		if type(low) == "number" and low > 0 then
			return low
		end
		if type(high) == "number" and high < 0 then
			return high
		end
		return 0
	end
	if kind == "string" then
		return ""
	end
	if kind == "enum" then
		return type(field.values) == "table" and field.values[1] or nil
	end
	if kind == "array" then
		return {}
	end
	return zero[kind]
end

local function fail(name, message, ...)
	error(format("component '%s': " .. message, name, ...), 0)
end

-- Checks a spec and returns field names, bits by name and by position, and defaults.
local function define(name, spec, opts)
	if type(name) ~= "string" or not name:find(NAME_PATTERN) then
		error(format("component name %s must be a snake_case id", describe(name)), 0)
	end
	if type(spec) ~= "table" then
		fail(name, "spec must be a table")
	end
	for key in pairs(spec) do
		if not SPEC_KEYS[key] then
			fail(name, "unknown key '%s'", tostring(key))
		end
	end
	local fields = spec.fields
	if type(fields) ~= "table" or fields[1] == nil then
		fail(name, "fields must be a non-empty array of { name, type, options... }")
	end
	if #fields > MAX_FIELDS then
		fail(name, "%d fields, at most %d: split the component", #fields, MAX_FIELDS)
	end
	local defaults = spec.defaults
	if defaults ~= nil and type(defaults) ~= "table" then
		fail(name, "defaults must be a table { [field] = value }")
	end
	defaults = defaults or EMPTY
	local zero = opts.zero or EMPTY
	local names, bitOf, bitAt, values = {}, {}, {}, {}
	for i, field in ipairs(fields) do
		if type(field) ~= "table" then
			fail(name, "field %d must be a table { name, type, options... }", i)
		end
		local fieldName = field[1]
		if type(fieldName) ~= "string" or not fieldName:find(FIELD_PATTERN) then
			fail(name, "field %d needs a name that starts with a letter, got %s", i, describe(fieldName))
		end
		if bitOf[fieldName] ~= nil then
			fail(name, "field '%s' is defined twice", fieldName)
		end
		if field.optional then
			fail(name, "field '%s' cannot be optional: give it a default instead", fieldName)
		end
		local value = defaults[fieldName]
		if value == nil then
			value = zeroOf(field, zero)
			if value == nil then
				fail(name, "field '%s' (%s) needs a default", fieldName, tostring(field[2]))
			end
		end
		local fieldBit = 2 ^ (i - 1)
		names[i], bitOf[fieldName], bitAt[i], values[fieldName] = fieldName, fieldBit, fieldBit, value
	end
	if #names ~= #fields then
		fail(name, "fields must be an array without holes")
	end
	for key in pairs(defaults) do
		if bitOf[key] == nil then
			fail(name, "default for unknown field %s", describe(key))
		end
	end
	return names, bitOf, bitAt, values
end

-- Checks a spec { fields, defaults }. Returns true, or false and a message.
function Components.Validate(name, spec, opts)
	local ok, err = pcall(define, name, spec, opts or EMPTY)
	if ok then
		return true
	end
	return false, tostring(err)
end

local Store = {}
Store.__index = Store

-- Creates a store; throws a readable error on a bad spec.
function Components.New(name, spec, opts)
	opts = opts or EMPTY
	local ok, names, bitOf, bitAt, defaults = pcall(define, name, spec, opts)
	if not ok then
		error(names, 2)
	end
	return setmetatable({
		name = name,
		names = names,
		bitOf = bitOf,
		bitAt = bitAt,
		all = 2 ^ #names - 1,
		defaults = defaults,
		data = {},
		count = 0,
		dirty = {},
		removed = {},
		listeners = {},
		track = opts.track == true,
		mirror = opts.mirror == true,
		keyOf = opts.keyOf,
		admit = opts.admit,
		copy = opts.copy or deepCopy,
		bind = opts.bind,
		onError = opts.onError or defaultOnError,
	}, Store)
end

-- Keys ---------------------------------------------------------------------------------

-- Index of a key for reads: a number as it is, anything else through keyOf (or nil).
local function readKey(store, key)
	if type(key) == "number" then
		return key
	end
	local keyOf = store.keyOf
	if keyOf == nil or key == nil then
		return nil
	end
	return keyOf(key)
end

-- Index of a key for writes; throws at the caller of the store method.
local function writeKey(store, key)
	local index = readKey(store, key)
	if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
		error(format("component '%s': key must be an entity or a positive entity index, got %s", store.name,
			describe(key)), 3)
	end
	return index
end

local function writable(store)
	if store.mirror then
		error(format("component '%s' is a read-only mirror: only the server changes it", store.name), 3)
	end
end

local function unknownField(store, field)
	return format("component '%s' has no field %s", store.name, describe(field))
end

local function missing(store, key)
	return format("component '%s' has no data for key %s (Add it first)", store.name, tostring(key))
end

local function newData(store)
	local data, names, defaults, copy = {}, store.names, store.defaults, store.copy
	for i = 1, #names do
		local name = names[i]
		data[name] = copy(defaults[name])
	end
	return data
end

-- Writing ------------------------------------------------------------------------------

-- Adds data for a key: defaults, then `values`. Replaces data the key already has.
-- Every field becomes dirty. Returns the data table.
function Store:Add(key, values)
	writable(self)
	local index = writeKey(self, key)
	if self.admit ~= nil then
		local problem = self.admit(index)
		if problem ~= nil then
			error(format("component '%s': %s", self.name, tostring(problem)), 2)
		end
	end
	local data = newData(self)
	if values ~= nil then
		local bitOf = self.bitOf
		for field, value in pairs(values) do
			if bitOf[field] == nil then
				error(unknownField(self, field), 2)
			end
			data[field] = value
		end
	end
	if self.data[index] == nil then
		self.count = self.count + 1
	end
	self.data[index] = data
	if self.track then
		self.dirty[index] = self.all
	end
	return data
end

-- Sets a field. Returns true if the value changed (the field becomes dirty); a table
-- value (array, struct) always counts as a change.
function Store:Set(key, field, value)
	if self.mirror then
		writable(self)
	end
	if type(key) ~= "number" then
		key = writeKey(self, key)
	end
	local data = self.data[key]
	if data == nil then
		error(missing(self, key), 2)
	end
	local fieldBit = self.bitOf[field]
	if fieldBit == nil then
		error(unknownField(self, field), 2)
	end
	if data[field] == value and type(value) ~= "table" then
		return false
	end
	data[field] = value
	if self.track then
		local dirty = self.dirty
		dirty[key] = bor(dirty[key] or 0, fieldBit)
	end
	return true
end

-- Sets several fields. Returns the mask of the fields that changed (0 if none).
function Store:Patch(key, values)
	writable(self)
	if type(key) ~= "number" then
		key = writeKey(self, key)
	end
	local data = self.data[key]
	if data == nil then
		error(missing(self, key), 2)
	end
	local bitOf = self.bitOf
	for field in pairs(values) do
		if bitOf[field] == nil then
			error(unknownField(self, field), 2)
		end
	end
	local mask = 0
	for field, value in pairs(values) do
		if data[field] ~= value or type(value) == "table" then
			data[field] = value
			mask = bor(mask, bitOf[field])
		end
	end
	if mask ~= 0 and self.track then
		local dirty = self.dirty
		dirty[key] = bor(dirty[key] or 0, mask)
	end
	return mask
end

-- Marks a field (or every field) dirty after direct writes to the data table.
-- Returns false if the key has no data.
function Store:Touch(key, field)
	writable(self)
	if type(key) ~= "number" then
		key = writeKey(self, key)
	end
	if self.data[key] == nil then
		return false
	end
	local mask = self.all
	if field ~= nil then
		mask = self.bitOf[field]
		if mask == nil then
			error(unknownField(self, field), 2)
		end
	end
	if self.track then
		local dirty = self.dirty
		dirty[key] = bor(dirty[key] or 0, mask)
	end
	return true
end

-- Removes the data of a key. Returns true if there was data.
function Store:Remove(key)
	writable(self)
	key = readKey(self, key)
	local data = self.data
	if key == nil or data[key] == nil then
		return false
	end
	data[key] = nil
	self.count = self.count - 1
	if self.track then
		self.dirty[key] = nil
		local removed = self.removed
		removed[#removed + 1] = key
	end
	return true
end

-- Removes the data of every key.
function Store:Clear()
	writable(self)
	for key in pairs(self.data) do
		self:Remove(key)
	end
end

-- Reading ------------------------------------------------------------------------------

-- The data table of a key, or nil.
function Store:Get(key)
	if type(key) ~= "number" then
		key = readKey(self, key)
		if key == nil then
			return nil
		end
	end
	return self.data[key]
end

function Store:Has(key)
	return self:Get(key) ~= nil
end

-- Iterates (index, data) in no particular order. Do not add keys while iterating.
function Store:Each()
	return pairs(self.data)
end

function Store:Count()
	return self.count
end

-- Whether `field` is in `mask` (the mask an OnChange listener gets).
function Store:Changed(mask, field)
	local fieldBit = self.bitOf[field]
	if fieldBit == nil then
		error(unknownField(self, field), 2)
	end
	return band(mask, fieldBit) ~= 0
end

-- Change listeners (mirrors) -------------------------------------------------------------

-- Calls handler(index, data, mask) after fields of a key arrive (mask: what came) and
-- handler(index, nil, 0) after a key is removed. Returns a function that unsubscribes.
function Store:OnChange(handler)
	if not self.mirror then
		error(format("component '%s': OnChange is for mirrors (replicated components on a client)", self.name), 2)
	end
	local fn = handler
	if self.bind ~= nil then
		fn = self.bind(handler)
	end
	if type(fn) ~= "function" then
		error(format("component '%s': OnChange needs a function", self.name), 2)
	end
	local copy = {}
	for i, listener in ipairs(self.listeners) do
		copy[i] = listener
	end
	copy[#copy + 1] = fn
	self.listeners = copy
	return function()
		local rest = {}
		for _, listener in ipairs(self.listeners) do
			if listener ~= fn then
				rest[#rest + 1] = listener
			end
		end
		self.listeners = rest
	end
end

local function notify(store, key, data, mask)
	local listeners = store.listeners
	for i = 1, #listeners do
		local ok, err = xpcall(listeners[i], onListenerError, key, data, mask)
		if not ok then
			local reported, problem = pcall(store.onError, err, store.name)
			if not reported then
				print("[components] onError failed: " .. tostring(problem) .. "\n" .. tostring(err))
			end
		end
	end
end

-- Platform: replication ------------------------------------------------------------------

-- Calls fn(index, mask, data) for every key with dirty fields and clears the marks.
-- fn must not change the store.
function Store:_TakeDirty(fn)
	local dirty, data = self.dirty, self.data
	for key, mask in pairs(dirty) do
		dirty[key] = nil
		fn(key, mask, data[key])
	end
end

-- Keys removed since the previous call (do not modify the list).
function Store:_TakeRemoved()
	local removed = self.removed
	if removed[1] == nil then
		return EMPTY
	end
	self.removed = {}
	return removed
end

function Store:_HasChanges()
	return next(self.dirty) ~= nil or self.removed[1] ~= nil
end

-- Forgets dirty marks and removed keys (nobody to send them to).
function Store:_ClearChanges()
	local dirty = self.dirty
	for key in pairs(dirty) do
		dirty[key] = nil
	end
	if self.removed[1] ~= nil then
		self.removed = {}
	end
end

-- Platform: mirrors ----------------------------------------------------------------------

-- Applies received fields (`values` may hold other keys too) and notifies listeners.
-- A new key starts with the defaults.
function Store:_Apply(key, values)
	local data = self.data[key]
	if data == nil then
		data = newData(self)
		self.data[key] = data
		self.count = self.count + 1
	end
	local names, bitAt = self.names, self.bitAt
	local mask = 0
	for i = 1, #names do
		local name = names[i]
		local value = values[name]
		if value ~= nil then
			data[name] = value
			mask = bor(mask, bitAt[i])
		end
	end
	notify(self, key, data, mask)
	return data
end

-- Removes a key and notifies listeners. Returns false if the key had no data.
function Store:_ApplyRemove(key)
	local data = self.data
	if data[key] == nil then
		return false
	end
	data[key] = nil
	self.count = self.count - 1
	notify(self, key, nil, 0)
	return true
end

-- Removes every key (a full state follows).
function Store:_Reset()
	for key in pairs(self.data) do
		self:_ApplyRemove(key)
	end
end

function Store:_ClearListeners()
	self.listeners = {}
end

-- Takes over the data of a store with the same fields (autorefresh) and leaves it empty.
-- Returns false if the fields differ.
function Store:_Adopt(other)
	local names = other.names
	if #names ~= #self.names then
		return false
	end
	for i, name in ipairs(self.names) do
		if names[i] ~= name then
			return false
		end
	end
	self.data, self.count = other.data, other.count
	other.data, other.count, other.dirty, other.removed = {}, 0, {}, {}
	return true
end

return Components
