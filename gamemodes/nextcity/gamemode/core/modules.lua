-- Next-City core: module registry, provider selection, dependency order, lifecycle
-- and the module context (`ctx`).
--
-- Pure Lua (LuaJIT 2.x), no GMod API. See docs/ARCHITECTURE.md, section 4.
--
--   local registry = Modules.New({ log = log, services = { events = bus, scheduler = sched, net = net } })
--   registry:Register(manifest)            -- for every discovered module.lua
--   registry:Resolve(config.modules)       -- providers, dependencies, order, settings
--   -- the platform loader includes the files of registry:Order() here
--   registry:InitAll()
--   registry:StartAll()
--   registry:StopAll()
--
-- Module states:
--   registered -> resolved -> initialized -> started -> stopped
--   disabled   turned off in config (modules.disabled)
--   inactive   another provider of the same interface is selected
--   failed     invalid dependency, cycle, ambiguous provider, load/Init/Start error,
--              or a failed hard dependency
-- A failure never takes the rest down: the module and everything that hard-depends on
-- it are switched off with a readable reason (see Report), other modules keep working.
--
-- Services become fields of every module context (ctx.events, ctx.i18n...). A service
-- may also implement:
--   service:ValidateManifest(section) -> ok, err   claims the manifest key with its name
--                                                  (e.g. net = { ... }) and checks it
--   service:ForModule(ctx, section) -> facade      a per-module object put on ctx instead
--                                                  of the service; facade:Dispose() runs
--                                                  when the module stops or fails

local Modules = {}

local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local xpcall = xpcall
local setmetatable = setmetatable
local format = string.format
local concat = table.concat
local sort = table.sort
local traceback = debug.traceback

local ID_PATTERN = "^[a-z][a-z0-9_]*$"
local FILE_PATTERN = "^[%w_%-][%w_%-/]*%.lua$"
local REALMS = { "sh", "sv", "cl" }
local MANIFEST_KEYS = {
	id = true, provides = true, requires = true, optional = true, files = true, config = true, description = true,
}
local LIVE = { resolved = true, initialized = true, started = true }
-- Pending timers are held by the scheduler; a context only has to find them on stop, so
-- cancelled timers drop out of its set on their own.
local WEAK_KEYS = { __mode = "k" }
-- Context fields a service may not take.
local RESERVED = {
	id = true, config = true, log = true, Require = true, On = true, Every = true, After = true,
	IsAlive = true, Handler = true,
}

Modules.ID_PATTERN = ID_PATTERN
Modules.REALMS = REALMS

local function noop() end
local NULL_LOG = { Trace = noop, Debug = noop, Info = noop, Warn = noop, Error = noop }
function NULL_LOG:Child() return self end

local function onCallError(err)
	return traceback(tostring(err), 2)
end

local function isId(value)
	return type(value) == "string" and value:find(ID_PATTERN) ~= nil
end

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

local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		keys[#keys + 1] = key
	end
	sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

-- Manifest validation ---------------------------------------------------------------

local function validateIds(manifest, key, own)
	local list = manifest[key]
	if list == nil then
		return {}, {}
	end
	if not isArray(list) then
		return nil, key .. " must be an array of interface ids"
	end
	local set = {}
	for i = 1, #list do
		local iface = list[i]
		if not isId(iface) then
			return nil, format("%s[%d] must be a snake_case id, got %s", key, i, tostring(iface))
		end
		if iface == own then
			return nil, format("%s lists its own interface '%s'", key, iface)
		end
		if set[iface] then
			return nil, format("%s lists '%s' twice", key, iface)
		end
		set[iface] = true
	end
	return list, set
end

local function validateFiles(files)
	local out = { sh = {}, sv = {}, cl = {} }
	if files == nil then
		return out
	end
	if type(files) ~= "table" then
		return nil, "files must be a table { sh = {...}, sv = {...}, cl = {...} }"
	end
	for key in pairs(files) do
		if out[key] == nil then
			return nil, format("files has unknown realm '%s' (expected sh, sv, cl)", tostring(key))
		end
	end
	local seen = {}
	for _, realm in ipairs(REALMS) do
		local list = files[realm]
		if list ~= nil then
			if not isArray(list) then
				return nil, "files." .. realm .. " must be an array of paths"
			end
			for i = 1, #list do
				local path = list[i]
				if type(path) ~= "string" or path:find(FILE_PATTERN) == nil then
					return nil, format("files.%s[%d] must be a relative .lua path, got %s", realm, i, tostring(path))
				end
				if seen[path] then
					return nil, format("file '%s' is listed twice", path)
				end
				seen[path] = true
				out[realm][i] = path
			end
		end
	end
	return out
end

-- sections: { [key] = validator(value) -> ok, err } for manifest keys claimed by services.
local function validate(manifest, sections)
	sections = sections or {}
	if type(manifest) ~= "table" then
		return nil, "manifest must be a table"
	end
	local id = manifest.id
	if not isId(id) then
		return nil, "manifest id must be a snake_case string, got " .. tostring(id)
	end
	local function fail(message)
		return nil, format("module '%s': %s", id, message)
	end
	local claimed = {}
	for key, value in pairs(manifest) do
		if sections[key] then
			claimed[key] = value
		elseif not MANIFEST_KEYS[key] then
			return fail(format("unknown manifest key '%s'", tostring(key)))
		end
	end
	for key, value in pairs(claimed) do
		local ok, valid, err = pcall(sections[key], value)
		if not ok then
			return fail(format("%s: validator failed: %s", key, tostring(valid)))
		end
		if not valid then
			return fail(format("%s: %s", key, tostring(err)))
		end
	end
	local provides = manifest.provides or id
	if not isId(provides) then
		return fail("provides must be a snake_case string")
	end
	local requires, requiresSet = validateIds(manifest, "requires", provides)
	if not requires then
		return fail(requiresSet)
	end
	local optional, optionalSet = validateIds(manifest, "optional", provides)
	if not optional then
		return fail(optionalSet)
	end
	for iface in pairs(optionalSet) do
		if requiresSet[iface] then
			return fail(format("'%s' is both required and optional", iface))
		end
	end
	local files, filesErr = validateFiles(manifest.files)
	if not files then
		return fail(filesErr)
	end
	if manifest.config ~= nil and type(manifest.config) ~= "table" then
		return fail("config must be a table")
	end
	if manifest.description ~= nil and type(manifest.description) ~= "string" then
		return fail("description must be a string")
	end
	return {
		id = id,
		provides = provides,
		description = manifest.description,
		requires = requires,
		optional = optional,
		requiresSet = requiresSet,
		optionalSet = optionalSet,
		files = files,
		sections = claimed,
		defaults = manifest.config or {},
		state = "registered",
		reason = nil,
		instance = { id = id },
		ctx = nil,
		index = nil,
	}
end

-- Checks a manifest without registering it. Returns true, or false and a message.
-- sections: optional { [key] = validator } for keys claimed by services.
function Modules.Validate(manifest, sections)
	local entry, err = validate(manifest, sections)
	return entry ~= nil, err
end

-- Context ---------------------------------------------------------------------------

local Context = {}
Context.__index = Context

local function newContext(registry, entry)
	return setmetatable({
		id = entry.id,
		config = entry.config,
		log = registry.rootLog:Child(entry.id),
		_registry = registry,
		_entry = entry,
		_listeners = {},
		_jobs = {},
		_timers = setmetatable({}, WEAK_KEYS),
		_facades = {},
		_alive = true,
		_seq = 0,
	}, Context)
end

local function checkAlive(ctx, what)
	if not ctx._alive then
		error(format("module '%s': %s on a stopped context", ctx.id, what), 3)
	end
end

-- Turns a function or a method name into a callable. Method names are looked up on
-- every call, so a reloaded file takes effect immediately.
local function handlerOf(ctx, handler, what, level)
	if type(handler) == "function" then
		return handler
	end
	if type(handler) ~= "string" then
		error(format("module '%s': handler for %s must be a function or a method name", ctx.id, what), level or 3)
	end
	local instance = ctx._entry.instance
	local id = ctx.id
	return function(...)
		local method = instance[handler]
		if method == nil then
			error(format("module '%s' has no method '%s' (%s)", id, handler, what), 2)
		end
		return method(instance, ...)
	end
end

-- Public form of the late binding above, for services: ctx:Handler("OnVote", "net 'vote'").
function Context:Handler(handler, what)
	return handlerOf(self, handler, what or "handler", 3)
end

-- Returns the API of a declared interface. A missing required interface is an error,
-- a missing optional one returns nil.
function Context:Require(iface)
	local entry = self._entry
	local required = entry.requiresSet[iface] == true
	if not required and not entry.optionalSet[iface] then
		error(format("module '%s' uses undeclared interface '%s'; add it to requires or optional in module.lua",
			self.id, tostring(iface)), 2)
	end
	local api = self._registry:Get(iface)
	if api == nil and required then
		error(format("module '%s': required interface '%s' is not available", self.id, iface), 2)
	end
	return api
end

-- Subscribes to an event; removed automatically when the module stops.
-- opts: id (default: the method name, so re-subscribing replaces), priority, once.
function Context:On(event, handler, opts)
	checkAlive(self, "On('" .. tostring(event) .. "')")
	assert(self.events ~= nil, "ctx:On: no event bus service")
	local fn = handlerOf(self, handler, "event '" .. tostring(event) .. "'")
	local id = opts and opts.id
	if id == nil then
		if type(handler) == "string" then
			id = handler
		else
			self._seq = self._seq + 1
			id = "#" .. self._seq
		end
	end
	local listener = self.events:On(event, fn, {
		id = self.id .. ":" .. id,
		priority = opts and opts.priority,
		once = opts and opts.once,
	})
	self._listeners[#self._listeners + 1] = listener
	return listener
end

-- Registers a periodic job "<module>:<id>"; removed automatically when the module stops.
function Context:Every(id, interval, handler, opts)
	checkAlive(self, "Every('" .. tostring(id) .. "')")
	assert(self.scheduler ~= nil, "ctx:Every: no scheduler service")
	assert(type(id) == "string" and id ~= "", "ctx:Every: id must be a non-empty string")
	local fn = handlerOf(self, handler, "job '" .. id .. "'")
	local job = self.scheduler:Every(self.id .. ":" .. id, interval, fn, opts)
	self._jobs[#self._jobs + 1] = job
	return job
end

-- Runs once after `delay` seconds unless the module stops first.
function Context:After(delay, handler)
	checkAlive(self, "After")
	assert(self.scheduler ~= nil, "ctx:After: no scheduler service")
	local fn = handlerOf(self, handler, "timer")
	local timers = self._timers
	local timer
	timer = self.scheduler:After(delay, function(now)
		timers[timer] = nil
		return fn(now)
	end, self.id)
	timers[timer] = true
	return timer
end

function Context:IsAlive()
	return self._alive
end

-- Drops every subscription, job and timer of the module. Called by the registry.
function Context:_Dispose()
	if not self._alive then
		return
	end
	self._alive = false
	local listeners = self._listeners
	for i = #listeners, 1, -1 do
		listeners[i]:Off()
	end
	local jobs = self._jobs
	for i = #jobs, 1, -1 do
		self.scheduler:Remove(jobs[i])
	end
	for timer in pairs(self._timers) do
		timer:Cancel()
	end
	local facades = self._facades
	for i = #facades, 1, -1 do
		local facade = facades[i]
		if type(facade.Dispose) == "function" then
			local ok, err = pcall(facade.Dispose, facade)
			if not ok then
				self._registry.log:Error("module '%s': disposing a service facade failed: %s", self.id, tostring(err))
			end
		end
	end
	self._listeners, self._jobs, self._facades = {}, {}, {}
	self._timers = setmetatable({}, WEAK_KEYS)
end

-- Registry --------------------------------------------------------------------------

local Registry = {}
Registry.__index = Registry

-- opts: log (root logger; modules get log:Child(id)), services (shared by every ctx),
-- protected (false lets lifecycle errors propagate, for debugging).
function Modules.New(opts)
	opts = opts or {}
	local rootLog = opts.log or NULL_LOG
	local services = opts.services or {}
	local sections = {}
	for name, service in pairs(services) do
		assert(isId(name) and not RESERVED[name], "Modules.New: bad service name " .. tostring(name))
		if type(service) == "table" and type(service.ValidateManifest) == "function" then
			assert(not MANIFEST_KEYS[name], "Modules.New: service '" .. name .. "' clashes with a manifest key")
			sections[name] = function(value)
				return service:ValidateManifest(value)
			end
		end
	end
	return setmetatable({
		rootLog = rootLog,
		log = rootLog:Child("modules"),
		services = services,
		serviceNames = sortedKeys(services),
		sections = sections,
		protected = opts.protected ~= false,
		entries = {},
		order = {},
		providers = {},
		errors = {},
		resolved = false,
	}, Registry)
end

function Registry:_Error(message)
	self.errors[#self.errors + 1] = message
	self.log:Error("%s", message)
end

-- Registers a manifest. Returns true, or false and an error message.
function Registry:Register(manifest)
	if self.resolved then
		local message = "cannot register modules after Resolve"
		self:_Error(message)
		return false, message
	end
	local entry, err = validate(manifest, self.sections)
	if entry == nil then
		self:_Error(err)
		return false, err
	end
	if self.entries[entry.id] ~= nil then
		local message = format("duplicate module id '%s'", entry.id)
		self:_Error(message)
		return false, message
	end
	self.entries[entry.id] = entry
	return true
end

-- The module table that its files fill (NC.Module(id) returns it).
function Registry:Instance(id)
	local entry = self.entries[id]
	return entry and entry.instance
end

-- Returns the API of the selected provider of `iface` while it is alive, else nil.
function Registry:Get(iface)
	local entry = self.providers[iface]
	if entry ~= nil and LIVE[entry.state] then
		return entry.instance
	end
	return nil
end

-- Returns state and reason of a module, or nil for an unknown id.
function Registry:State(id)
	local entry = self.entries[id]
	if entry == nil then
		return nil
	end
	return entry.state, entry.reason
end

-- Files of a module per realm: { sh = {...}, sv = {...}, cl = {...} }. Do not modify.
function Registry:Files(id)
	local entry = self.entries[id]
	return entry and entry.files
end

-- Ids in load order (modules that passed Resolve; later failures keep their place).
function Registry:Order()
	local ids = {}
	for i, entry in ipairs(self.order) do
		ids[i] = entry.id
	end
	return ids
end

function Registry:Errors()
	local copy = {}
	for i, message in ipairs(self.errors) do
		copy[i] = message
	end
	return copy
end

-- Rows { id, provides, state, reason, index } in load order, then the rest by id.
function Registry:Report()
	local rows = {}
	for _, id in ipairs(sortedKeys(self.entries)) do
		local entry = self.entries[id]
		rows[#rows + 1] = {
			id = id,
			provides = entry.provides,
			state = entry.state,
			reason = entry.reason,
			index = entry.index,
		}
	end
	sort(rows, function(a, b)
		local ia, ib = a.index or math.huge, b.index or math.huge
		if ia ~= ib then
			return ia < ib
		end
		return a.id < b.id
	end)
	return rows
end

local function explainMissing(self, iface, candidates)
	local providers = candidates[iface]
	if providers ~= nil and providers[1] ~= nil then
		return format("dependency '%s' has no selected provider", iface)
	end
	for _, entry in pairs(self.entries) do
		if entry.provides == iface and entry.state == "disabled" then
			return format("dependency '%s' is disabled", iface)
		end
	end
	return format("missing dependency '%s'", iface)
end

local function mergeConfig(self, entry, override)
	local config = {}
	for key, value in pairs(entry.defaults) do
		config[key] = value
	end
	if override == nil then
		return config
	end
	if type(override) ~= "table" then
		self.log:Warn("settings of module '%s' must be a table; using defaults", entry.id)
		return config
	end
	for _, key in ipairs(sortedKeys(override)) do
		local value = override[key]
		local default = entry.defaults[key]
		if default == nil then
			self.log:Warn("module '%s': unknown setting '%s'", entry.id, tostring(key))
			config[key] = value
		elseif type(value) ~= type(default) then
			self.log:Warn("module '%s': setting '%s' must be a %s, got %s; using the default",
				entry.id, tostring(key), type(default), type(value))
		else
			config[key] = value
		end
	end
	return config
end

local function warnUnknown(self, map, what)
	for _, id in ipairs(sortedKeys(map)) do
		if self.entries[id] == nil then
			self.log:Warn("config %s unknown module '%s'", what, tostring(id))
		end
	end
end

-- Groups enabled modules by the interface they provide.
local function collectCandidates(self, ids, disabled)
	local candidates = {}
	for _, id in ipairs(ids) do
		local entry = self.entries[id]
		if disabled[id] then
			entry.state = "disabled"
			entry.reason = "disabled in config"
		else
			local list = candidates[entry.provides]
			if list == nil then
				list = {}
				candidates[entry.provides] = list
			end
			list[#list + 1] = entry
		end
	end
	return candidates
end

local function checkConfiguredProviders(self, chosen)
	for _, iface in ipairs(sortedKeys(chosen)) do
		local want = chosen[iface]
		local entry = self.entries[want]
		if entry == nil then
			self:_Error(format("configured provider '%s' for interface '%s' is not a known module", tostring(want), iface))
		elseif entry.provides ~= iface then
			self:_Error(format("configured provider '%s' provides '%s', not '%s'", want, entry.provides, iface))
		elseif entry.state == "disabled" then
			self:_Error(format("configured provider '%s' for interface '%s' is disabled", want, iface))
		end
	end
end

-- One provider per interface: the configured one, the only candidate, or none (ambiguous).
local function selectProviders(self, candidates, chosen)
	local providers = {}
	for _, iface in ipairs(sortedKeys(candidates)) do
		local list = candidates[iface]
		local want = chosen[iface]
		if want ~= nil then
			for _, entry in ipairs(list) do
				if entry.id == want then
					providers[iface] = entry
				else
					entry.state = "inactive"
					entry.reason = format("'%s' is the configured provider of '%s'", tostring(want), iface)
				end
			end
		elseif #list == 1 then
			providers[iface] = list[1]
		else
			local names = {}
			for i, entry in ipairs(list) do
				names[i] = entry.id
			end
			local message = format("ambiguous provider for interface '%s': %s; choose one in modules.providers",
				iface, concat(names, ", "))
			self:_Error(message)
			for _, entry in ipairs(list) do
				entry.state = "failed"
				entry.reason = message
			end
		end
	end
	return providers
end

-- Returns the first required interface of `entry` without a live provider, and why.
local function firstUnavailable(self, entry, providers, alive, candidates)
	for _, iface in ipairs(entry.requires) do
		local provider = providers[iface]
		if provider == nil then
			return explainMissing(self, iface, candidates)
		end
		if not alive[provider] then
			return format("dependency '%s' (%s) failed", iface, provider.id)
		end
	end
	return nil
end

-- Drops modules with unavailable hard dependencies until nothing changes.
local function dropUnavailable(self, ids, providers, candidates)
	local alive = {}
	for _, entry in pairs(providers) do
		alive[entry] = true
	end
	local changed = true
	while changed do
		changed = false
		for _, id in ipairs(ids) do
			local entry = self.entries[id]
			local reason = alive[entry] and firstUnavailable(self, entry, providers, alive, candidates)
			if reason then
				alive[entry] = nil
				entry.state = "failed"
				entry.reason = reason
				self.log:Error("module '%s' disabled: %s", id, reason)
				changed = true
			end
		end
	end
	return alive
end

-- Builds the dependency graph of live modules: provider -> dependents.
local function buildGraph(self, ids, providers, alive)
	local nodes, indegree, successors = {}, {}, {}
	for _, id in ipairs(ids) do
		local entry = self.entries[id]
		if alive[entry] then
			nodes[#nodes + 1] = entry
			indegree[entry] = 0
			successors[entry] = {}
		end
	end
	local function link(entry, iface)
		local provider = providers[iface]
		if provider ~= nil and alive[provider] then
			indegree[entry] = indegree[entry] + 1
			local list = successors[provider]
			list[#list + 1] = entry
		end
	end
	for _, entry in ipairs(nodes) do
		for _, iface in ipairs(entry.requires) do
			link(entry, iface)
		end
		for _, iface in ipairs(entry.optional) do
			link(entry, iface)
		end
	end
	return nodes, indegree, successors
end

-- Kahn's algorithm; the ready set is ordered by id, so the order is deterministic.
local function topoSort(nodes, indegree, successors)
	local ready = {}
	for _, entry in ipairs(nodes) do
		if indegree[entry] == 0 then
			ready[#ready + 1] = entry
		end
	end
	local order = {}
	while ready[1] ~= nil do
		local best = 1
		for i = 2, #ready do
			if ready[i].id < ready[best].id then
				best = i
			end
		end
		local entry = table.remove(ready, best)
		order[#order + 1] = entry
		for _, successor in ipairs(successors[entry]) do
			indegree[successor] = indegree[successor] - 1
			if indegree[successor] == 0 then
				ready[#ready + 1] = successor
			end
		end
	end
	return order
end

local function hasSuccessorIn(set, successors)
	for _, successor in ipairs(successors) do
		if set[successor] then
			return true
		end
	end
	return false
end

-- Modules left after the sort are in a cycle or depend on one: peel the dependents
-- (nodes without successors among the rest) and report the cycle itself.
local function failCycles(self, nodes, indegree, successors)
	local left = {}
	for _, entry in ipairs(nodes) do
		if indegree[entry] > 0 then
			left[entry] = true
		end
	end
	local downstream = {}
	local peeled = true
	while peeled do
		peeled = false
		for entry in pairs(left) do
			if not hasSuccessorIn(left, successors[entry]) then
				left[entry] = nil
				downstream[entry] = true
				peeled = true
			end
		end
	end
	local cycle = {}
	for entry in pairs(left) do
		cycle[#cycle + 1] = entry.id
	end
	sort(cycle)
	local message = "dependency cycle (requires/optional): " .. concat(cycle, ", ")
	if cycle[1] ~= nil then
		self:_Error(message)
	end
	for _, entry in ipairs(nodes) do
		if left[entry] then
			entry.state = "failed"
			entry.reason = message
		elseif downstream[entry] then
			entry.state = "failed"
			entry.reason = "depends on a module in a dependency cycle"
			self.log:Error("module '%s' disabled: %s", entry.id, entry.reason)
		end
	end
end

-- Selects providers, checks dependencies, builds a deterministic topological order and
-- merges settings. cfg: { disabled = { [id] = true }, providers = { [iface] = id },
-- settings = { [id] = { ... } } }. Returns the ordered ids.
function Registry:Resolve(cfg)
	assert(not self.resolved, "Registry:Resolve: already resolved")
	cfg = cfg or {}
	local disabled = cfg.disabled or {}
	local chosen = cfg.providers or {}
	local settings = cfg.settings or {}
	self.resolved = true

	warnUnknown(self, disabled, "disables")
	warnUnknown(self, settings, "has settings for")

	local ids = sortedKeys(self.entries)
	local candidates = collectCandidates(self, ids, disabled)
	checkConfiguredProviders(self, chosen)
	local providers = selectProviders(self, candidates, chosen)
	local alive = dropUnavailable(self, ids, providers, candidates)
	local nodes, indegree, successors = buildGraph(self, ids, providers, alive)
	local order = topoSort(nodes, indegree, successors)
	if #order < #nodes then
		failCycles(self, nodes, indegree, successors)
	end

	for i, entry in ipairs(order) do
		entry.index = i
		entry.state = "resolved"
		entry.config = mergeConfig(self, entry, settings[entry.id])
	end
	self.order = order
	self.providers = providers
	return self:Order()
end

function Registry:_Call(entry, method, ...)
	local fn = entry.instance[method]
	if fn == nil then
		return true
	end
	if type(fn) ~= "function" then
		return false, method .. " is not a function"
	end
	if not self.protected then
		fn(entry.instance, ...)
		return true
	end
	return xpcall(fn, onCallError, entry.instance, ...)
end

function Registry:_Shutdown(entry)
	if entry.state == "started" then
		local ok, err = self:_Call(entry, "Stop", entry.ctx)
		if not ok then
			self.log:Error("module '%s': Stop failed: %s", entry.id, tostring(err))
		end
	end
	if entry.ctx ~= nil then
		entry.ctx:_Dispose()
	end
end

-- Marks a module failed, stops it and every module that hard-depends on it
-- (dependents first). Returns false if the module is unknown or already failed.
function Registry:Fail(id, reason)
	local root = self.entries[id]
	if root == nil or root.state == "failed" then
		return false
	end
	reason = tostring(reason or "failed")
	local affected = { [root] = reason }
	for _, entry in ipairs(self.order) do
		if entry ~= root and LIVE[entry.state] then
			for _, iface in ipairs(entry.requires) do
				local provider = self.providers[iface]
				if provider ~= nil and affected[provider] then
					affected[entry] = format("dependency '%s' (%s) failed", iface, provider.id)
					break
				end
			end
		end
	end
	for i = #self.order, 1, -1 do
		local entry = self.order[i]
		if affected[entry] and entry ~= root then
			self:_Shutdown(entry)
			entry.state = "failed"
			entry.reason = affected[entry]
			self.log:Error("module '%s' failed: %s", entry.id, entry.reason)
		end
	end
	self:_Shutdown(root)
	root.state = "failed"
	root.reason = reason
	self.log:Error("module '%s' failed: %s", root.id, reason)
	return true
end

-- Builds the context of a module and attaches the services (facades where provided).
-- Returns the context, or nil and a message; partly built facades are disposed.
function Registry:_NewContext(entry)
	local ctx = newContext(self, entry)
	for _, name in ipairs(self.serviceNames) do
		local service = self.services[name]
		if type(service) == "table" and type(service.ForModule) == "function" then
			local ok, facade
			if self.protected then
				ok, facade = xpcall(service.ForModule, onCallError, service, ctx, entry.sections[name])
			else
				ok, facade = true, service:ForModule(ctx, entry.sections[name])
			end
			if not ok or type(facade) ~= "table" then
				ctx:_Dispose()
				return nil, format("service '%s' failed: %s", name, ok and "ForModule must return a table" or tostring(facade))
			end
			ctx[name] = facade
			ctx._facades[#ctx._facades + 1] = facade
		else
			ctx[name] = service
		end
	end
	return ctx
end

-- Creates contexts and calls Init(ctx) in dependency order.
function Registry:InitAll()
	for _, entry in ipairs(self.order) do
		if entry.state == "resolved" then
			local ctx, ctxErr = self:_NewContext(entry)
			if ctx == nil then
				self:Fail(entry.id, ctxErr)
			else
				entry.ctx = ctx
				entry.instance.id = entry.id
				entry.instance.ctx = ctx
				local ok, err = self:_Call(entry, "Init", ctx)
				if ok then
					entry.state = "initialized"
				else
					self:Fail(entry.id, "Init failed: " .. tostring(err))
				end
			end
		end
	end
end

-- Calls Start(ctx) in dependency order.
function Registry:StartAll()
	for _, entry in ipairs(self.order) do
		if entry.state == "initialized" then
			local ok, err = self:_Call(entry, "Start", entry.ctx)
			if ok then
				entry.state = "started"
			else
				self:Fail(entry.id, "Start failed: " .. tostring(err))
			end
		end
	end
end

-- Calls Stop(ctx) in reverse order and disposes every context.
function Registry:StopAll()
	for i = #self.order, 1, -1 do
		local entry = self.order[i]
		if entry.state == "started" or entry.state == "initialized" then
			self:_Shutdown(entry)
			entry.state = "stopped"
		end
	end
end

-- Number of modules per state, e.g. { started = 12, failed = 1 }.
function Registry:Counts()
	local counts = {}
	for _, entry in pairs(self.entries) do
		counts[entry.state] = (counts[entry.state] or 0) + 1
	end
	return counts
end

return Modules
