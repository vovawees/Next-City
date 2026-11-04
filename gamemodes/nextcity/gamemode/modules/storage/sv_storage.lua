-- Storage, server part.
--
--   local bank = storage:Open("bank")          -- data/nextcity/bank.json, loaded once
--   bank:Set(storage:PlayerKey(ply), { cash = 500 })
--   local account = bank:Get(key)              -- tables by reference: Set or Touch after a change
--   bank:Delete(key); bank:Keys(); bank:Count(); bank:Flush()
--
-- A namespace is lowercase letters, digits and _; keys are strings, values anything
-- JSON keeps: strings, numbers, booleans and tables with string keys or arrays. A change
-- marks the store and its file is written config.flushDelay s later (changes in between
-- go in the same write), at shutdown and when the module stops. A file that is not valid
-- JSON is copied to <namespace>_corrupt.txt and the store starts empty.
--
-- Listens:  gm.ShutDown.
-- Emits:    storage.flushed (ns)
-- Commands: nc_storage [flush | <namespace> [key]]

local M = NC.Module("storage")

local type = type
local pairs = pairs
local tostring = tostring
local setmetatable = setmetatable
local format = string.format
local sort = table.sort

local NAME = "^[a-z][a-z0-9_]*$"

local Store = {}
Store.__index = Store

function M:Init(ctx)
	self.stores = {} -- ns -> store
	ctx.commands:Add("nc_storage", { help = "[flush | <namespace> [key]] - persistent data of modules" },
		"StorageCommand")
end

function M:Start(ctx)
	ctx:On("gm.ShutDown", "FlushAll")
end

function M:Stop()
	self:FlushAll()
end

function M:_Path(ns, suffix)
	return format("%s/%s%s", self.ctx.config.folder, ns, suffix or ".json")
end

-- The store of namespace `ns`, opened once per server.
function M:Open(ns)
	if type(ns) ~= "string" or not ns:find(NAME) then
		error(format("storage: Open(%s): a namespace is lowercase letters, digits and _", tostring(ns)), 2)
	end
	local store = self.stores[ns]
	if store == nil then
		store = setmetatable({ ns = ns, module = self, data = self:_Load(ns), dirty = false, pending = false }, Store)
		self.stores[ns] = store
	end
	return store
end

-- Whether namespace `ns` is open.
function M:IsOpen(ns)
	return self.stores[ns] ~= nil
end

function M:_Load(ns)
	local path = self:_Path(ns)
	local text = file.Read(path, "DATA")
	if text == nil or text == "" then
		return {}
	end
	local data = util.JSONToTable(text, false, true)
	if type(data) ~= "table" then
		local copy = self:_Path(ns, "_corrupt.txt")
		file.Write(copy, text)
		self.ctx.log:Warn("%s is not valid JSON: copied to %s, starting empty", path, copy)
		return {}
	end
	return data
end

-- The key of a player in stores: the SteamID64 ("bot_<name>" for bots).
function M:PlayerKey(ply)
	if ply:IsBot() then
		return "bot_" .. ply:Nick()
	end
	return ply:SteamID64()
end

function M:_Schedule(store)
	if store.pending then
		return
	end
	store.pending = true
	self.ctx:After(self.ctx.config.flushDelay, function()
		store.pending = false
		store:Flush()
	end)
end

function M:_Write(store)
	local folder = self.ctx.config.folder
	if not file.IsDir(folder, "DATA") then
		file.CreateDir(folder)
	end
	file.Write(self:_Path(store.ns), util.TableToJSON(store.data, self.ctx.config.pretty == true))
	store.dirty = false
	self.ctx.events:Emit("storage.flushed", store.ns)
end

-- Writes every changed store now.
function M:FlushAll()
	for _, store in pairs(self.stores) do
		store:Flush()
	end
end

-- Store ----------------------------------------------------------------------------------

local function checkKey(key)
	if type(key) ~= "string" or key == "" then
		error("storage: keys are non-empty strings, got " .. tostring(key), 3)
	end
end

function Store:Get(key)
	return self.data[key]
end

-- Sets the value of `key` (nil deletes it); the file is written a moment later.
function Store:Set(key, value)
	checkKey(key)
	self.data[key] = value
	self:Touch()
	return value
end

function Store:Delete(key)
	checkKey(key)
	if self.data[key] ~= nil then
		self.data[key] = nil
		self:Touch()
	end
end

-- Marks the store as changed (after changing a table got with Get).
function Store:Touch()
	self.dirty = true
	self.module:_Schedule(self)
end

-- Keys, sorted (a new list).
function Store:Keys()
	local keys = {}
	for key in pairs(self.data) do
		keys[#keys + 1] = key
	end
	sort(keys)
	return keys
end

function Store:Count()
	local count = 0
	for _ in pairs(self.data) do
		count = count + 1
	end
	return count
end

-- Iterates over key, value (do not add keys while iterating).
function Store:Each()
	return pairs(self.data)
end

-- Writes the file now if the store changed.
function Store:Flush()
	if self.dirty then
		self.module:_Write(self)
	end
end

-- Console --------------------------------------------------------------------------------

function M:StorageCommand(_, args)
	if args[1] == "flush" then
		self:FlushAll()
		return "storage: written"
	end
	if args[1] ~= nil then
		local store = self.stores[args[1]]
		if store == nil then
			return "storage: namespace '" .. tostring(args[1]) .. "' is not open"
		end
		if args[2] ~= nil then
			local value = store:Get(args[2])
			return value == nil and "storage: no such key" or util.TableToJSON({ value = value }, true)
		end
		local lines = { format("storage %s: %d keys", store.ns, store:Count()) }
		for _, key in ipairs(store:Keys()) do
			lines[#lines + 1] = "  " .. key
		end
		return lines
	end
	local names = {}
	for ns in pairs(self.stores) do
		names[#names + 1] = ns
	end
	sort(names)
	local lines = { format("storage: %d namespaces in data/%s", #names, self.ctx.config.folder) }
	for _, ns in ipairs(names) do
		local store = self.stores[ns]
		lines[#lines + 1] = format("  %s: %d keys%s", ns, store:Count(), store.dirty and " (not written yet)" or "")
	end
	return lines
end
