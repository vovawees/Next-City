-- Next-City platform: network messages (ctx.net), runs on both realms.
--
-- Every message is its own network string "nc.<module>.<name>", declared in the module
-- manifest with a typed schema (core/schema.lua), so both realms use the same format;
-- see docs/ARCHITECTURE.md, section 8:
--
--   net = {
--       state = { from = "server", fields = { { "phase", "enum", values = { "wait", "play" } } } },
--       vote = { from = "client", rate = 1, burst = 3, fields = { { "mode", "string", max = 32 } } },
--   },
--
--   ctx.net:Receive("vote", "OnVote")               -- M:OnVote(data, ply) on the server
--   ctx.net:Send("state", ply, { phase = "play" })  -- also Broadcast, SendOmit, SendPVS, SendPAS
--   ctx.net:SendToServer("vote", { mode = "tdm" })  -- client
--
-- The server treats incoming data as untrusted and checks it from cheap to expensive:
-- the player is ready, a token bucket per player and message (rate per second, burst),
-- the size against the bounds of the schema, then the decoder validates every value;
-- only then the handler runs, protected. Violations are counted, logged at most once a
-- second per player and published as "net.violation" (ply, message, reason, detail).
--
-- Readiness: after InitPostEntity (and again after autorefresh) a client sends
-- "nc.hello" with its client info: small strings the server should know, such as the
-- language (SetInfo on the client, OnInfo on the server, later changes go as "nc.info").
-- The server applies the info, marks the player ready and emits "net.ready" (ply).
-- Send and Broadcast deliver to ready players only, so nothing is lost while a client
-- loads; a module sends the full state on "net.ready". The client emits "net.ready"
-- after its hello.

local Schema = NC.Lib.Schema

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local format = string.format
local ceil = math.ceil
local floor = math.floor
local xpcall = xpcall
local traceback = debug.traceback

local Service = {}
Service.__index = Service

local Facade = {}
Facade.__index = Facade

local PREFIX = "nc."
local NAME_PATTERN = "^[a-z][a-z0-9_]*$"
local MAX_NAME = 32
local SPEC_KEYS = { from = true, fields = true, rate = true, burst = true, unreliable = true, desc = true }
local DEFAULT_RATE = 10
local DEFAULT_BURST = 20
-- Budget of network strings for the whole project (GMod allows 4096).
local STRING_BUDGET = 256
local REPORT_INTERVAL = 1
local ENTITY_BITS = 13
local ENTITY_LIMIT = 8192
local PLAYER_BITS = 8
local PLAYER_LIMIT = 256
local MAX_INFO = 16
local INFO_KEY_MAX = 24
local INFO_VALUE_MAX = 64
local EMPTY = {}

local INFO_FIELDS = {
	{ "info", "array", max = MAX_INFO, of = { "struct", fields = {
		{ "key", "string", max = INFO_KEY_MAX },
		{ "value", "string", max = INFO_VALUE_MAX },
	} } },
}

local function sortedKeys(t)
	local out = {}
	for key in pairs(t) do
		out[#out + 1] = key
	end
	table.sort(out)
	return out
end

local function isName(value, limit)
	return type(value) == "string" and #value <= limit and value:find(NAME_PATTERN) ~= nil
end

-- Schema io -----------------------------------------------------------------------------

local function byte(value)
	value = tonumber(value) or 0
	if value ~= value or value < 0 then
		return 0
	end
	if value > 255 then
		return 255
	end
	return floor(value)
end

-- The io of the schemas over the net library. Engine values are coerced here, so a bad
-- value never breaks a message: anything but a valid entity is sent as index 0, a
-- missing vector as the origin, a missing color as black.
local function newIO()
	local WriteUInt, ReadUInt = net.WriteUInt, net.ReadUInt
	local WriteVector, WriteAngle, WriteNormal = net.WriteVector, net.WriteAngle, net.WriteNormal

	local function index(value, limit)
		if isentity(value) and IsValid(value) then
			local i = value:EntIndex()
			if i > 0 and i < limit then
				return i
			end
		end
		return 0
	end

	return {
		WriteBool = net.WriteBool,
		ReadBool = net.ReadBool,
		WriteUInt = WriteUInt,
		ReadUInt = ReadUInt,
		WriteInt = net.WriteInt,
		ReadInt = net.ReadInt,
		WriteFloat = net.WriteFloat,
		ReadFloat = net.ReadFloat,
		WriteDouble = net.WriteDouble,
		ReadDouble = net.ReadDouble,
		WriteString = net.WriteString,
		ReadString = net.ReadString,
		WriteEntity = function(value)
			WriteUInt(index(value, ENTITY_LIMIT), ENTITY_BITS)
		end,
		ReadEntity = function()
			return Entity(ReadUInt(ENTITY_BITS))
		end,
		WritePlayer = function(value)
			local i = index(value, PLAYER_LIMIT)
			if i ~= 0 and not value:IsPlayer() then
				i = 0
			end
			WriteUInt(i, PLAYER_BITS)
		end,
		ReadPlayer = function()
			local ply = Entity(ReadUInt(PLAYER_BITS))
			if IsValid(ply) and ply:IsPlayer() then
				return ply
			end
			return NULL
		end,
		WriteVector = function(value)
			WriteVector(isvector(value) and value or vector_origin)
		end,
		ReadVector = net.ReadVector,
		WriteAngle = function(value)
			WriteAngle(isangle(value) and value or angle_zero)
		end,
		ReadAngle = net.ReadAngle,
		WriteNormal = function(value)
			WriteNormal(isvector(value) and value or vector_up)
		end,
		ReadNormal = net.ReadNormal,
		WriteColor = function(value, alpha)
			local color = istable(value) and value or EMPTY
			WriteUInt(byte(color.r), 8)
			WriteUInt(byte(color.g), 8)
			WriteUInt(byte(color.b), 8)
			if alpha then
				WriteUInt(color.a == nil and 255 or byte(color.a), 8)
			end
		end,
		ReadColor = function(alpha)
			local r, g, b = ReadUInt(8), ReadUInt(8), ReadUInt(8)
			return Color(r, g, b, alpha and ReadUInt(8) or 255)
		end,
		IsValid = IsValid,
	}
end

-- Manifest section ------------------------------------------------------------------------

local function validateSpec(spec)
	if type(spec) ~= "table" then
		return false, "must be a table"
	end
	for key in pairs(spec) do
		if not SPEC_KEYS[key] then
			return false, format("unknown key '%s'", tostring(key))
		end
	end
	if spec.from ~= "server" and spec.from ~= "client" then
		return false, "from must be \"server\" or \"client\""
	end
	if spec.fields ~= nil then
		if type(spec.fields) ~= "table" then
			return false, "fields must be a table"
		end
		local ok, err = Schema.Validate(spec.fields)
		if not ok then
			return false, err
		end
	end
	if spec.from == "server" and (spec.rate ~= nil or spec.burst ~= nil) then
		return false, "rate and burst limit client messages only"
	end
	local rate = spec.rate
	if rate ~= nil and (type(rate) ~= "number" or rate ~= rate or rate <= 0 or rate == math.huge) then
		return false, "rate must be a positive number of messages per second"
	end
	local burst = spec.burst
	if burst ~= nil and (type(burst) ~= "number" or burst < 1 or burst ~= floor(burst) or burst == math.huge) then
		return false, "burst must be a positive integer"
	end
	if spec.unreliable ~= nil and type(spec.unreliable) ~= "boolean" then
		return false, "unreliable must be a boolean"
	end
	if spec.desc ~= nil and type(spec.desc) ~= "string" then
		return false, "desc must be a string"
	end
	return true
end

-- Service -------------------------------------------------------------------------------

-- opts: log, events, config (NC.Config.net), clock (seconds, default SysTime), previous
-- (service of the previous kernel, on autorefresh).
function Service.New(opts)
	local cfg = opts.config or {}
	local previous = opts.previous
	local service = setmetatable({
		log = opts.log,
		events = opts.events,
		clock = opts.clock or SysTime,
		checkOutgoing = cfg.checkOutgoing == true,
		io = newIO(),
		messages = {},
		count = 0,
		listeners = {},
		-- server
		ready = {},
		readyList = {},
		readyIndex = {},
		infos = {},
		infoHandlers = {},
		violations = {},
		reported = {},
		scratch = {},
		omit = {},
		-- client
		clientReady = false,
		info = {},
	}, Service)

	service.hello = service:_Define(PREFIX .. "hello", { from = "client", rate = 2, burst = 4, fields = INFO_FIELDS })
	service.hello.early = true
	service.update = service:_Define(PREFIX .. "info", { from = "client", rate = 2, burst = 8, fields = INFO_FIELDS })

	if SERVER then
		service.hello.handler = function(data, ply)
			service:_OnHello(data, ply)
		end
		service.update.handler = function(data, ply)
			service:_ApplyInfo(ply, data.info)
		end
		service:_TakeOver(previous)
		service:_Listen("gm.PlayerDisconnected", function(ply)
			service:_Forget(ply)
		end)
	else
		if previous then
			service.clientReady = previous.clientReady == true
			for key, value in pairs(previous.info or EMPTY) do
				service.info[key] = value
			end
		end
		service:_Listen("gm.InitPostEntity", function()
			service:_SendHello()
		end)
		service:_Listen("gm.OnReloaded", function()
			if service.clientReady then
				service:_SendHello()
			end
		end)
	end
	return service
end

function Service:_Listen(event, fn, opts)
	opts = opts or {}
	opts.id = opts.id or "net:" .. event
	self.listeners[#self.listeners + 1] = self.events:On(event, fn, opts)
end

-- Server: ready players and their info survive autorefresh; the new modules get
-- "net.ready" for each of them once the kernel has started.
function Service:_TakeOver(previous)
	if previous == nil then
		return
	end
	for _, ply in ipairs(previous.readyList or EMPTY) do
		if IsValid(ply) then
			self:_MarkReady(ply)
			local info = {}
			for key, value in pairs(previous.infos[ply] or EMPTY) do
				info[key] = value
			end
			self.infos[ply] = info
		end
	end
	if #self.readyList > 0 then
		self:_Listen("nc.ready", function()
			for _, ply in ipairs(self:ReadyPlayers()) do
				self.events:Emit("net.ready", ply)
			end
		end, { once = true })
	end
end

-- Defines a message (once per kernel) and its receiver on the realm that receives it.
function Service:_Define(name, spec)
	if self.messages[name] then
		error("net message '" .. name .. "' is defined twice", 2)
	end
	local schema = Schema.Define(spec.fields or EMPTY)
	local message = {
		name = name,
		from = spec.from,
		schema = schema,
		codec = schema:Codec(self.io),
		minBits = schema.minBits,
		-- The engine may round a message up to whole bytes.
		maxBits = schema.maxBits + 7,
		rate = spec.rate or DEFAULT_RATE,
		burst = spec.burst or DEFAULT_BURST,
		unreliable = spec.unreliable == true,
		early = false,
		handler = nil,
		tokens = {},
		stamps = {},
		sent = 0,
		bytesOut = 0,
		received = 0,
		bytesIn = 0,
		dropped = {},
		errors = 0,
		reportedAt = nil,
	}
	self.messages[name] = message
	self.count = self.count + 1
	if self.count == STRING_BUDGET + 1 then
		self.log:Warn("more than %d network messages: the budget is %d (docs/ARCHITECTURE.md, section 8)",
			STRING_BUDGET, STRING_BUDGET)
	end
	if SERVER then
		util.AddNetworkString(name)
		if message.from == "client" then
			net.Receive(name, self:_ServerReceiver(message))
		end
	elseif message.from == "server" then
		net.Receive(name, self:_ClientReceiver(message))
	end
	return message
end

function Service:_Drop(message, reason)
	message.dropped[reason] = (message.dropped[reason] or 0) + 1
end

-- Logs a problem of a message at most once per REPORT_INTERVAL.
function Service:_Report(message, text, ...)
	local now = self.clock()
	if message.reportedAt == nil or now - message.reportedAt >= REPORT_INTERVAL then
		message.reportedAt = now
		self.log:Error(text, ...)
	end
end

function Service:_Violation(ply, message, reason, detail)
	self:_Drop(message, reason)
	local count = (self.violations[ply] or 0) + 1
	self.violations[ply] = count
	local now = self.clock()
	local last = self.reported[ply]
	if last == nil or now - last >= REPORT_INTERVAL then
		self.reported[ply] = now
		self.log:Warn("%s: '%s' rejected (%s%s), %d violation(s)", tostring(ply), message.name, reason,
			detail and ": " .. detail or "", count)
	end
	self.events:Emit("net.violation", ply, message.name, reason, detail)
end

-- Token bucket of a player for a message: `burst` messages at once, `rate` per second.
function Service:_Take(message, ply)
	local now = self.clock()
	local tokens = message.tokens[ply]
	if tokens == nil then
		tokens = message.burst
	else
		tokens = tokens + (now - message.stamps[ply]) * message.rate
		if tokens > message.burst then
			tokens = message.burst
		end
	end
	message.stamps[ply] = now
	if tokens < 1 then
		message.tokens[ply] = tokens
		return false
	end
	message.tokens[ply] = tokens - 1
	return true
end

function Service:_Handle(message, data, ply)
	local handler = message.handler
	if handler == nil then
		self:_Drop(message, "noHandler")
		return
	end
	local ok, err = xpcall(handler, traceback, data, ply)
	if not ok then
		message.errors = message.errors + 1
		self:_Report(message, "net '%s' handler failed: %s", message.name, tostring(err))
	end
end

function Service:_ServerReceiver(message)
	local service = self
	local ready = self.ready
	local Read = message.codec.Read
	return function(len, ply)
		if not message.early and not ready[ply] then
			service:_Drop(message, "notReady")
			return
		end
		if not service:_Take(message, ply) then
			service:_Violation(ply, message, "rate")
			return
		end
		if len < message.minBits or len > message.maxBits then
			service:_Violation(ply, message, "size", len .. " bits")
			return
		end
		local data, err = Read()
		if data == nil then
			service:_Violation(ply, message, "invalid", err)
			return
		end
		message.received = message.received + 1
		message.bytesIn = message.bytesIn + ceil(len / 8)
		service:_Handle(message, data, ply)
	end
end

function Service:_ClientReceiver(message)
	local service = self
	local Read = message.codec.Read
	return function(len)
		local data, err = Read()
		if data == nil then
			service:_Drop(message, "invalid")
			service:_Report(message, "net '%s' from the server is invalid: %s", message.name, err)
			return
		end
		message.received = message.received + 1
		message.bytesIn = message.bytesIn + ceil(len / 8)
		service:_Handle(message, data)
	end
end

-- Sending ---------------------------------------------------------------------------

function Service:_Write(message, data)
	data = data or EMPTY
	if self.checkOutgoing then
		local ok, err = message.schema:Check(data)
		if not ok then
			self.log:Warn("net '%s' sends bad data: %s", message.name, err)
		end
	end
	net.Start(message.name, message.unreliable)
	message.codec.Write(data)
	local bytes = net.BytesWritten()
	return bytes
end

function Service:_Count(message, bytes, recipients)
	message.sent = message.sent + 1
	message.bytesOut = message.bytesOut + bytes * recipients
end

-- Server: sends to a player or a list of players; only ready ones receive it.
-- Returns the number of recipients.
function Service:Send(message, target, data)
	if isentity(target) then
		if not self.ready[target] then
			self:_Drop(message, "notReady")
			return 0
		end
		local bytes = self:_Write(message, data)
		net.Send(target)
		self:_Count(message, bytes, 1)
		return 1
	end
	if type(target) ~= "table" then
		error(format("net '%s': target must be a player or a list of players, got %s", message.name, type(target)), 3)
	end
	local list, n = self.scratch, 0
	for _, ply in ipairs(target) do
		if self.ready[ply] then
			n = n + 1
			list[n] = ply
		end
	end
	if n < #target then
		self:_Drop(message, "notReady")
	end
	if n > 0 then
		local bytes = self:_Write(message, data)
		net.Send(list)
		self:_Count(message, bytes, n)
	end
	for i = n, 1, -1 do
		list[i] = nil
	end
	return n
end

-- Server: sends to every ready player. Returns the number of recipients.
function Service:Broadcast(message, data)
	local n = #self.readyList
	if n == 0 then
		return 0
	end
	local bytes = self:_Write(message, data)
	net.Send(self.readyList)
	self:_Count(message, bytes, n)
	return n
end

-- Server: sends to every ready player except a player or a list of players.
function Service:SendOmit(message, except, data)
	local omit = self.omit
	if isentity(except) then
		omit[except] = true
	elseif type(except) == "table" then
		for _, ply in ipairs(except) do
			omit[ply] = true
		end
	end
	local list, n = self.scratch, 0
	for _, ply in ipairs(self.readyList) do
		if not omit[ply] then
			n = n + 1
			list[n] = ply
		end
	end
	for ply in pairs(omit) do
		omit[ply] = nil
	end
	if n > 0 then
		local bytes = self:_Write(message, data)
		net.Send(list)
		self:_Count(message, bytes, n)
	end
	for i = n, 1, -1 do
		list[i] = nil
	end
	return n
end

-- Server: sends to the players that can see (PVS) or hear (PAS) a position, ready or
-- not: for instant effects.
function Service:SendPVS(message, pos, data)
	local bytes = self:_Write(message, data)
	net.SendPVS(pos)
	self:_Count(message, bytes, 1)
end

function Service:SendPAS(message, pos, data)
	local bytes = self:_Write(message, data)
	net.SendPAS(pos)
	self:_Count(message, bytes, 1)
end

-- Client: sends to the server. Returns false if the message cannot go yet (before the
-- hello) or the server does not know it (the module failed there).
function Service:SendToServer(message, data)
	if not self.clientReady and not message.early then
		self:_Drop(message, "notReady")
		return false
	end
	if util.NetworkStringToID(message.name) == 0 then
		self:_Drop(message, "unpooled")
		self:_Report(message, "net '%s' is unknown to the server (did its module fail there?)", message.name)
		return false
	end
	local bytes = self:_Write(message, data)
	net.SendToServer()
	self:_Count(message, bytes, 1)
	return true
end

-- Readiness and client info ----------------------------------------------------------------

function Service:_MarkReady(ply)
	if self.ready[ply] then
		return
	end
	self.ready[ply] = true
	local list = self.readyList
	list[#list + 1] = ply
	self.readyIndex[ply] = #list
end

function Service:_Forget(ply)
	local index = self.readyIndex[ply]
	if index ~= nil then
		local list = self.readyList
		local last = list[#list]
		list[index] = last
		self.readyIndex[last] = index
		list[#list] = nil
		self.readyIndex[ply] = nil
		self.ready[ply] = nil
	end
	self.infos[ply] = nil
	self.violations[ply] = nil
	self.reported[ply] = nil
	for _, message in pairs(self.messages) do
		message.tokens[ply] = nil
		message.stamps[ply] = nil
	end
end

function Service:_ApplyInfo(ply, list)
	local store = self.infos[ply]
	if store == nil then
		store = {}
		self.infos[ply] = store
	end
	for _, item in ipairs(list) do
		local handler = self.infoHandlers[item.key]
		if handler ~= nil and store[item.key] ~= item.value then
			store[item.key] = item.value
			local ok, err = xpcall(handler, traceback, ply, item.value)
			if not ok then
				self.log:Error("client info '%s' handler failed: %s", item.key, tostring(err))
			end
		end
	end
end

function Service:_OnHello(data, ply)
	self:_ApplyInfo(ply, data.info)
	self:_MarkReady(ply)
	self.log:Debug("%s is ready", tostring(ply))
	self.events:Emit("net.ready", ply)
end

function Service:_InfoList(keys)
	local out = {}
	for i, key in ipairs(keys or sortedKeys(self.info)) do
		out[i] = { key = key, value = self.info[key] }
	end
	return out
end

function Service:_SendHello()
	self:SendToServer(self.hello, { info = self:_InfoList() })
	self.clientReady = true
	self.events:Emit("net.ready")
end

-- Client: sets a client info value the server receives with the hello and on changes.
function Service:SetInfo(key, value)
	if not isName(key, INFO_KEY_MAX) then
		error(format("net SetInfo: key must be a snake_case id of at most %d characters", INFO_KEY_MAX), 2)
	end
	value = tostring(value)
	if #value > INFO_VALUE_MAX then
		value = value:sub(1, INFO_VALUE_MAX)
	end
	if self.info[key] == value then
		return
	end
	if self.info[key] == nil and #sortedKeys(self.info) >= MAX_INFO then
		error(format("net SetInfo: at most %d keys", MAX_INFO), 2)
	end
	self.info[key] = value
	if self.clientReady then
		self:SendToServer(self.update, { info = self:_InfoList({ key }) })
	end
end

-- Server: calls fn(ply, value) when a player reports a new value of a client info key.
function Service:OnInfo(key, fn)
	if not isName(key, INFO_KEY_MAX) then
		error(format("net OnInfo: key must be a snake_case id of at most %d characters", INFO_KEY_MAX), 2)
	end
	self.infoHandlers[key] = fn
end

-- Server: the last value of a client info key reported by a player (nil if none).
function Service:InfoOf(ply, key)
	local store = self.infos[ply]
	return store and store[key]
end

-- Server: whether a player has sent its hello. Client: whether the hello was sent.
function Service:IsReady(ply)
	if CLIENT then
		return self.clientReady
	end
	return self.ready[ply] == true
end

-- Server: a copy of the list of ready players.
function Service:ReadyPlayers()
	local out = {}
	for i, ply in ipairs(self.readyList) do
		out[i] = ply
	end
	return out
end

-- Statistics ------------------------------------------------------------------------------

-- Messages ordered by name: { name, from, sent, bytesOut, received, bytesIn, dropped, errors }.
function Service:Stats()
	local out = {}
	for _, name in ipairs(sortedKeys(self.messages)) do
		local message = self.messages[name]
		local dropped = {}
		for reason, count in pairs(message.dropped) do
			dropped[reason] = count
		end
		out[#out + 1] = {
			name = name, from = message.from, sent = message.sent, bytesOut = message.bytesOut,
			received = message.received, bytesIn = message.bytesIn, dropped = dropped, errors = message.errors,
		}
	end
	return out
end

function Service:ResetStats()
	for _, message in pairs(self.messages) do
		message.sent, message.bytesOut, message.received, message.bytesIn, message.errors = 0, 0, 0, 0, 0
		message.dropped = {}
	end
end

function Service:Count()
	return self.count
end

-- The schema of a message by its network name, or nil (tools and tests).
function Service:SchemaOf(name)
	local message = self.messages[name]
	return message and message.schema
end

-- Removes the receivers and listeners (kernel shutdown or autorefresh); ready players
-- and client info stay for the service that takes over.
function Service:Shutdown()
	for name in pairs(self.messages) do
		net.Receivers[name] = nil
	end
	for _, listener in ipairs(self.listeners) do
		listener:Off()
	end
	self.listeners = {}
end

-- Module facade -----------------------------------------------------------------------

-- Checks the `net` section of a manifest: { [name] = { from, fields, rate, burst,
-- unreliable, desc } }.
function Service:ValidateManifest(section)
	if type(section) ~= "table" then
		return false, "net must be a table of messages"
	end
	for _, name in ipairs(sortedKeys(section)) do
		if not isName(name, MAX_NAME) then
			return false, format("net message name %s must be a snake_case id of at most %d characters",
				tostring(name), MAX_NAME)
		end
		local ok, err = validateSpec(section[name])
		if not ok then
			return false, format("net message '%s': %s", name, err)
		end
	end
	return true
end

-- ctx.net: defines the messages of the module and releases its handlers on Stop.
function Service:ForModule(ctx, section)
	local facade = setmetatable({ service = self, ctx = ctx, id = ctx.id, messages = {}, alive = true }, Facade)
	for _, name in ipairs(sortedKeys(section or EMPTY)) do
		facade.messages[name] = self:_Define(PREFIX .. ctx.id .. "." .. name, section[name])
	end
	return facade
end

-- level: of the module code calling the facade, counted from this function.
local function messageOf(facade, name, level)
	local message = facade.messages[name]
	if message == nil then
		error(format("module '%s' has no net message '%s' (declare it in module.lua)", facade.id, tostring(name)), level)
	end
	if not facade.alive then
		error(format("module '%s' is stopped: net '%s' is not available", facade.id, name), level)
	end
	return message
end

local function outgoing(facade, name, method, realm)
	local message = messageOf(facade, name, 4)
	if realm == "server" and not SERVER or realm == "client" and not CLIENT then
		error(format("net %s is %s-only", method, realm), 3)
	end
	if message.from ~= realm then
		error(format("net message '%s' goes from the %s, %s cannot send it", message.name, message.from, method), 3)
	end
	return message
end

-- Sets the handler of a message sent to this realm: fn(data, ply) or a method name.
function Facade:Receive(name, handler)
	local message = messageOf(self, name, 3)
	local receiving = SERVER and "client" or "server"
	if message.from ~= receiving then
		error(format("net message '%s' goes from the %s, it cannot be received there", message.name, message.from), 2)
	end
	message.handler = self.ctx:Handler(handler, "net '" .. name .. "'")
	message.owner = self
end

function Facade:Send(name, target, data)
	return self.service:Send(outgoing(self, name, "Send", "server"), target, data)
end

function Facade:Broadcast(name, data)
	return self.service:Broadcast(outgoing(self, name, "Broadcast", "server"), data)
end

function Facade:SendOmit(name, except, data)
	return self.service:SendOmit(outgoing(self, name, "SendOmit", "server"), except, data)
end

function Facade:SendPVS(name, pos, data)
	return self.service:SendPVS(outgoing(self, name, "SendPVS", "server"), pos, data)
end

function Facade:SendPAS(name, pos, data)
	return self.service:SendPAS(outgoing(self, name, "SendPAS", "server"), pos, data)
end

function Facade:SendToServer(name, data)
	return self.service:SendToServer(outgoing(self, name, "SendToServer", "client"), data)
end

function Facade:IsReady(ply)
	return self.service:IsReady(ply)
end

function Facade:ReadyPlayers()
	return self.service:ReadyPlayers()
end

-- The full network name of a message of this module ("nc.<module>.<name>").
function Facade:Name(name)
	return messageOf(self, name, 3).name
end

function Facade:Dispose()
	for _, message in pairs(self.messages) do
		if message.owner == self then
			message.handler = nil
			message.owner = nil
		end
	end
	self.alive = false
end

return Service
