-- Next-City platform: component data (ctx.components), runs on both realms.
--
-- A module declares per-entity data in its manifest; the platform keeps it in stores
-- outside entity tables (core/components.lua), removes it with its entity and sends
-- changes to the audience of the component (docs/ARCHITECTURE.md, section 8):
--
--   components = {
--       vitals = { replicate = "owner", rate = 10, fields = {
--           { "blood", "quant", min = 0, max = 5000, bits = 12 },
--           { "pulse", "uint", max = 250 },
--       }, defaults = { blood = 5000, pulse = 70 } },
--   },
--
--   local vitals = ctx.components.vitals   -- keys: entities or entity indexes
--   vitals:Add(ply)                         -- server: defaults, then the given values
--   vitals:Set(ply, "pulse", 120)           -- only changed fields go to clients
--   vitals:Get(ply).blood                   -- both realms
--   vitals:OnChange("OnVitals")             -- client: M:OnVitals(index, data, mask)
--
-- replicate: nil keeps a local store on each realm; "all" sends the data to every ready
-- player; "owner" only to the player whose entity is the key (keys must be players).
-- On a client a replicated component is a read-only mirror. Every 1 / rate seconds
-- (default 10 times a second) the server sends what changed since the previous flush:
-- the removed keys and, for each changed key, only the changed fields. A player that
-- becomes ready (net.ready) first gets the full state. Each replicated component is one
-- network message "nc.<module>:<component>"; large batches are split into messages of
-- at most 16 KiB.
--
-- Data survives autorefresh while the fields of a component stay the same.

local Components = NC.Lib.Components
local Schema = NC.Lib.Schema

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local rawget = rawget
local setmetatable = setmetatable
local getmetatable = getmetatable
local pcall = pcall
local format = string.format
local floor = math.floor
local min = math.min
local band = bit.band

local PREFIX = "nc."
local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_NAME = 32
local SPEC_KEYS = { fields = true, defaults = true, replicate = true, rate = true, desc = true }
local AUDIENCES = { all = true, owner = true }
local DEFAULT_RATE = 10
local MAX_RATE = 100
local KEY_BITS = 13
-- Worst-case size of one message (bits); larger batches are split.
local MESSAGE_BITS = 16384 * 8
local REMOVED_CHUNK = 1023
local MAX_CHUNK = 2048
local READY_PRIORITY = 100
local EMPTY = {}

-- Engine zero values; copied for every key, never handed out.
local ZERO = { entity = NULL, player = NULL, vector = Vector(0, 0, 0), angle = Angle(0, 0, 0),
	normal = Vector(0, 0, 1) }

local function copyValue(value)
	if isvector(value) then
		return Vector(value)
	end
	if isangle(value) then
		return Angle(value)
	end
	if type(value) ~= "table" or isentity(value) then
		return value
	end
	local out = {}
	for key, item in pairs(value) do
		out[key] = copyValue(item)
	end
	return setmetatable(out, getmetatable(value))
end

local function keyOf(key)
	if isentity(key) and key:IsValid() then
		return key:EntIndex()
	end
	return nil
end

local function admitPlayer(index)
	local ply = Entity(index)
	if IsValid(ply) and ply:IsPlayer() then
		return nil
	end
	return format("it replicates to the owner, so keys must be players (entity #%d is not)", index)
end

local function sortedKeys(t)
	local keys = {}
	for key in pairs(t) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function isName(value)
	return type(value) == "string" and #value <= MAX_NAME and value:find(NAME_PATTERN) ~= nil
end

-- Wire format ---------------------------------------------------------------------------

-- An update: the entity index, then every field with a presence bit.
local function entryFields(fields)
	local out = { { "_key", "uint", bits = KEY_BITS } }
	for i, field in ipairs(fields) do
		local copy = {}
		for key, value in pairs(field) do
			copy[key] = value
		end
		copy.optional = true
		out[i + 1] = copy
	end
	return out
end

local function messageFields(entry, chunk)
	return {
		{ "reset", "bool" },
		{ "removed", "array", max = REMOVED_CHUNK, of = { "uint", bits = KEY_BITS } },
		{ "updates", "array", max = chunk, of = { "struct", fields = entry } },
	}
end

-- How many updates fit into one message (0 if not even one), and the size of one.
local function chunkOf(entry)
	local entryBits = Schema.Define(entry).maxBits
	local fixed = Schema.Define(messageFields(entry, MAX_CHUNK)).maxBits - MAX_CHUNK * entryBits
	return min(MAX_CHUNK, floor((MESSAGE_BITS - fixed) / entryBits)), entryBits
end

-- Manifest section ------------------------------------------------------------------------

local function validateSpec(name, spec)
	if type(spec) ~= "table" then
		return false, "must be a table"
	end
	for key in pairs(spec) do
		if not SPEC_KEYS[key] then
			return false, format("unknown key '%s'", tostring(key))
		end
	end
	local audience = spec.replicate
	if audience ~= nil and not AUDIENCES[audience] then
		return false, "replicate must be \"all\" or \"owner\" (or nil for a local store)"
	end
	local rate = spec.rate
	if rate ~= nil then
		if audience == nil then
			return false, "rate needs replicate"
		end
		if type(rate) ~= "number" or rate ~= rate or rate <= 0 or rate > MAX_RATE then
			return false, format("rate must be a number of flushes per second in (0, %d]", MAX_RATE)
		end
	end
	if spec.desc ~= nil and type(spec.desc) ~= "string" then
		return false, "desc must be a string"
	end
	if type(spec.fields) ~= "table" then
		return false, "fields must be a non-empty array of { name, type, options... }"
	end
	local ok, err = Schema.Validate(spec.fields)
	if not ok then
		return false, err
	end
	local storeSpec = { fields = spec.fields, defaults = spec.defaults }
	local opts = { zero = ZERO, copy = copyValue }
	ok, err = Components.Validate(name, storeSpec, opts)
	if not ok then
		return false, (err:gsub("^component '[^']*': ", ""))
	end
	local store = Components.New(name, storeSpec, opts)
	local valid, problem = Schema.Define(spec.fields):Check(store.defaults)
	if not valid then
		return false, "bad default, " .. problem
	end
	if audience ~= nil then
		local chunk, entryBits = chunkOf(entryFields(spec.fields))
		if chunk < 1 then
			return false, format("an update can take %d bytes, more than one message holds (%d): shorten strings "
				.. "and arrays or split the component", math.ceil(entryBits / 8), MESSAGE_BITS / 8)
		end
	end
	return true
end

-- Entries -------------------------------------------------------------------------------

local function acquire(component)
	local used = component.used + 1
	component.used = used
	local entry = component.pool[used]
	if entry == nil then
		entry = {}
		component.pool[used] = entry
	end
	return entry
end

local function fill(entry, key, mask, data, store)
	entry._key = key
	local names = store.names
	if mask == store.all then
		for i = 1, #names do
			local name = names[i]
			entry[name] = data[name]
		end
	else
		local bitAt = store.bitAt
		for i = 1, #names do
			if band(mask, bitAt[i]) ~= 0 then
				local name = names[i]
				entry[name] = data[name]
			end
		end
	end
	return entry
end

-- Returns the entries to the pool and empties the scratch lists.
local function recycle(component)
	local pool, names = component.pool, component.store.names
	for i = 1, component.used do
		local entry = pool[i]
		entry._key = nil
		for j = 1, #names do
			entry[names[j]] = nil
		end
	end
	component.used = 0
	local updates = component.updates
	for i = #updates, 1, -1 do
		updates[i] = nil
	end
	component.single[1] = nil
end

local function slice(list, from, count)
	local out = {}
	for i = from, min(#list, from + count - 1) do
		out[#out + 1] = list[i]
	end
	return out
end

-- Service -------------------------------------------------------------------------------

local Service = {}
Service.__index = Service

local Facade = {}

local FacadeMeta = {
	__index = function(facade, key)
		local method = Facade[key]
		if method ~= nil then
			return method
		end
		error(format("module '%s' has no component '%s' (declare it in module.lua)", tostring(rawget(facade, "_id")),
			tostring(key)), 2)
	end,
}

-- opts: log, events, scheduler, net (services of the kernel), previous (service of the
-- previous kernel, on autorefresh).
function Service.New(opts)
	local service = setmetatable({
		log = opts.log,
		events = opts.events,
		scheduler = opts.scheduler,
		net = opts.net,
		previous = opts.previous,
		components = {},
		list = {},
		removable = {},
		listeners = {},
	}, Service)
	service:_Listen("gm.EntityRemoved", function(ent, fullUpdate)
		service:_OnEntityRemoved(ent, fullUpdate)
	end)
	if SERVER then
		-- Before the modules: they may send messages that rely on the components.
		service:_Listen("net.ready", function(ply)
			service:_Snapshot(ply)
		end, { priority = READY_PRIORITY })
	end
	service:_Listen("nc.ready", function()
		service.previous = nil
	end, { once = true })
	return service
end

function Service:_Listen(event, fn, opts)
	opts = opts or {}
	opts.id = "components:" .. event
	self.listeners[#self.listeners + 1] = self.events:On(event, fn, opts)
end

-- Checks the `components` section of a manifest: { [name] = { fields, defaults,
-- replicate, rate, desc } }.
function Service:ValidateManifest(section)
	if type(section) ~= "table" then
		return false, "components must be a table of components"
	end
	for _, name in ipairs(sortedKeys(section)) do
		if not isName(name) then
			return false, format("component name %s must be a snake_case id of at most %d characters", tostring(name),
				MAX_NAME)
		end
		local ok, err = validateSpec(name, section[name])
		if not ok then
			return false, format("component '%s': %s", name, err)
		end
	end
	return true
end

-- ctx.components: the stores of the module by name.
function Service:ForModule(ctx, section)
	local facade = setmetatable({ _service = self, _id = ctx.id, _list = {} }, FacadeMeta)
	local ok, err = pcall(function()
		for _, name in ipairs(sortedKeys(section or EMPTY)) do
			local component = self:_Define(ctx, name, section[name])
			facade[name] = component.store
			facade._list[#facade._list + 1] = component
		end
	end)
	if not ok then
		facade:Dispose()
		error(err, 0)
	end
	return facade
end

function Service:_Define(ctx, name, spec)
	local id = ctx.id .. "." .. name
	if self.components[id] ~= nil then
		error(format("component '%s' is defined twice", id), 2)
	end
	local audience = spec.replicate
	local log = self.log
	local store = Components.New(name, { fields = spec.fields, defaults = spec.defaults }, {
		keyOf = keyOf,
		admit = SERVER and audience == "owner" and admitPlayer or nil,
		copy = copyValue,
		zero = ZERO,
		track = SERVER and audience ~= nil,
		mirror = CLIENT and audience ~= nil,
		bind = function(handler)
			return ctx:Handler(handler, "component '" .. name .. "'")
		end,
		onError = function(err)
			log:Error("component '%s' listener failed: %s", id, tostring(err))
		end,
	})
	local component = {
		id = id,
		module = ctx.id,
		name = name,
		audience = audience,
		rate = spec.rate or DEFAULT_RATE,
		store = store,
		signature = Schema.Define(spec.fields).signature,
		alive = true,
		pool = {},
		used = 0,
		updates = {},
		single = {},
		out = { reset = false, removed = EMPTY, updates = EMPTY },
	}
	self:_Adopt(component)
	if audience ~= nil then
		self:_Replicate(component, spec)
	end
	self.components[id] = component
	self.list[#self.list + 1] = component
	if SERVER or audience == nil then
		self.removable[#self.removable + 1] = component
	end
	return component
end

-- Takes over the data of the same component of the previous kernel.
function Service:_Adopt(component)
	local previous = self.previous
	local old = previous and previous.components[component.id]
	if old == nil then
		return
	end
	if old.signature == component.signature and component.store:_Adopt(old.store) then
		self.log:Debug("component '%s' keeps %d entries", component.id, component.store:Count())
	else
		self.log:Info("component '%s' has new fields: its data starts empty", component.id)
	end
end

function Service:_Replicate(component, spec)
	local entry = entryFields(spec.fields)
	component.chunk = chunkOf(entry)
	component.message = self.net:Define(PREFIX .. component.module .. ":" .. component.name, {
		from = "server",
		desc = spec.desc,
		fields = messageFields(entry, component.chunk),
	})
	if CLIENT then
		self.net:Handle(component.message, function(data)
			self:_Receive(component, data)
		end)
		return
	end
	local net, store = self.net, component.store
	if component.audience == "all" then
		component.collect = function(key, mask, data)
			local updates = component.updates
			updates[#updates + 1] = fill(acquire(component), key, mask, data, store)
		end
	else
		component.collect = function(key, mask, data)
			local ply = Entity(key)
			if net:IsReady(ply) then
				local single = component.single
				single[1] = fill(acquire(component), key, mask, data, store)
				self:_Send(component, ply, false, EMPTY, single)
			end
		end
	end
	component.job = self.scheduler:Every("components:" .. component.id, 1 / component.rate, function()
		self:_Flush(component)
	end)
end

-- Server: sends what changed since the previous flush.
function Service:_Flush(component)
	local store = component.store
	if not store:_HasChanges() then
		return
	end
	local net = self.net
	if net:ReadyCount() == 0 then
		store:_ClearChanges()
		return
	end
	local removed = store:_TakeRemoved()
	if component.audience == "all" then
		store:_TakeDirty(component.collect)
		self:_Send(component, nil, false, removed, component.updates)
	else
		for i = 1, #removed do
			local ply = Entity(removed[i])
			if net:IsReady(ply) then
				self:_Send(component, ply, false, { removed[i] }, EMPTY)
			end
		end
		store:_TakeDirty(component.collect)
	end
	recycle(component)
end

-- Server: the full state of every replicated component for a player that became ready.
function Service:_Snapshot(ply)
	local index = ply:EntIndex()
	for _, component in ipairs(self.list) do
		if component.alive and component.message ~= nil then
			local store = component.store
			local updates, all = component.updates, store.all
			if component.audience == "all" then
				for key, data in store:Each() do
					updates[#updates + 1] = fill(acquire(component), key, all, data, store)
				end
			else
				local data = store:Get(index)
				if data ~= nil then
					updates[1] = fill(acquire(component), index, all, data, store)
				end
			end
			self:_Send(component, ply, true, EMPTY, updates)
			recycle(component)
		end
	end
end

-- Server: sends removals and updates to a player (or every ready player when target is
-- nil), split into messages of the component's size.
function Service:_Send(component, target, reset, removed, updates)
	local out, chunk = component.out, component.chunk
	local removedCount, updateCount = #removed, #updates
	if removedCount <= REMOVED_CHUNK and updateCount <= chunk then
		out.reset, out.removed, out.updates = reset, removed, updates
		self:_Deliver(component, target, out)
	else
		local r, u = 1, 1
		repeat
			local removedPart, updatePart = slice(removed, r, REMOVED_CHUNK), slice(updates, u, chunk)
			out.reset, out.removed, out.updates = reset, removedPart, updatePart
			reset = false
			self:_Deliver(component, target, out)
			r, u = r + #removedPart, u + #updatePart
		until r > removedCount and u > updateCount
	end
	out.removed, out.updates = EMPTY, EMPTY
end

function Service:_Deliver(component, target, out)
	if target == nil then
		self.net:Broadcast(component.message, out)
	else
		self.net:Send(component.message, target, out)
	end
end

-- Client: applies a message to the mirror.
function Service:_Receive(component, data)
	local store = component.store
	if data.reset then
		store:_Reset()
	end
	local removed = data.removed
	for i = 1, #removed do
		store:_ApplyRemove(removed[i])
	end
	local updates = data.updates
	for i = 1, #updates do
		local entry = updates[i]
		store:_Apply(entry._key, entry)
	end
end

-- The data of a removed entity goes with it: on the server from every store (clients
-- learn it with the next flush), on a client from local stores. A full update on a
-- client re-creates entities, so it keeps the data.
function Service:_OnEntityRemoved(ent, fullUpdate)
	if fullUpdate then
		return
	end
	local index = ent:EntIndex()
	if index < 1 then
		return
	end
	local removable = self.removable
	for i = 1, #removable do
		removable[i].store:Remove(index)
	end
end

function Service:_Release(component)
	component.alive = false
	if component.job ~= nil then
		self.scheduler:Remove(component.job)
		component.job = nil
	end
	component.store:_ClearListeners()
	if CLIENT and component.message ~= nil then
		self.net:Handle(component.message, nil)
	end
end

-- The store of a component by its id "<module>.<name>", or nil (tools and tests).
function Service:Store(id)
	local component = self.components[id]
	return component and component.store
end

-- Components ordered by id: { id, replicate, rate, count, fields, sent, bytesOut,
-- received, bytesIn, alive }.
function Service:Report()
	local rows = {}
	for _, component in ipairs(self.list) do
		local message = component.message or EMPTY
		rows[#rows + 1] = {
			id = component.id,
			replicate = component.audience,
			rate = component.audience and component.rate or nil,
			count = component.store:Count(),
			fields = #component.store.names,
			sent = message.sent or 0,
			bytesOut = message.bytesOut or 0,
			received = message.received or 0,
			bytesIn = message.bytesIn or 0,
			alive = component.alive,
		}
	end
	table.sort(rows, function(a, b)
		return a.id < b.id
	end)
	return rows
end

-- Removes the listeners (kernel shutdown or autorefresh); the data stays for the
-- service that takes over.
function Service:Shutdown()
	for _, listener in ipairs(self.listeners) do
		listener:Off()
	end
	self.listeners = {}
end

-- Module facade -----------------------------------------------------------------------------

-- Stops the flushes and listeners of the module's components; the data stays.
function Facade:Dispose()
	local service = rawget(self, "_service")
	for _, component in ipairs(rawget(self, "_list")) do
		service:_Release(component)
	end
end

return Service
