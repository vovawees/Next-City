-- Storage, server part.
--
--   local bank = storage:Open("bank")              -- a namespace: every key, loaded at once
--   bank:Set(storage:PlayerKey(ply), { cash = 500 })
--   local account = bank:Get(key)                  -- tables by reference: Set or Touch after a change
--   bank:Delete(key); bank:Keys(); bank:Count(); bank:Each(); bank:Flush()
--
--   local profiles = storage:Collection("profiles") -- a record per key, read when first asked for
--   local record = profiles:Get(key)               -- the record table or nil; kept until Release
--   profiles:Set(key, { kills = 1 }); profiles:Touch(key); profiles:Delete(key)
--   profiles:Release(key)                          -- written if changed, then out of memory
--   profiles:Has(key); profiles:Keys(); profiles:Count(); profiles:LoadedKeys(); profiles:Flush([key])
--
-- A namespace is lowercase letters, digits and _; keys are non-empty strings. Values of a
-- namespace are anything JSON keeps (strings, numbers, booleans, tables with string keys or
-- arrays); records of a collection are tables and their keys at most 80 bytes. A change
-- marks the store and is written config.flushDelay s later (changes in between go in the
-- same write), at shutdown and when the module stops.
--
-- Backends (config.backend, the same API):
--   json    DATA/<folder>/<ns>.json per namespace; a collection is the folder <folder>/<ns>/
--           with a file per record, <key>.json (bytes other than a-z and 0-9 written as _xx).
--           A file that is not valid JSON is moved to <name>_corrupt.txt and reads as empty.
--   sqlite  the sql library of the engine (sv.db): a table <folder>_<ns> ("key" TEXT PRIMARY
--           KEY, "value" TEXT JSON) per namespace or collection; namespaces write only the
--           changed keys (Touch() without a key rewrites the table). A table made for the
--           first time takes the JSON data of the same namespace, so switching keeps the data.
--           Without the sql library the json backend is used (warning).
--
-- Listens:  gm.ShutDown.
-- Emits:    storage.flushed (ns)
-- Commands: nc_storage [flush | <namespace> [key]]

local M = NC.Module("storage")

local type = type
local pairs = pairs
local ipairs = ipairs
local next = next
local tonumber = tonumber
local tostring = tostring
local setmetatable = setmetatable
local format = string.format
local char = string.char
local sort = table.sort

local NAME = "^[a-z][a-z0-9_]*$"
local MAX_RECORD_KEY = 80 -- bytes: an encoded file name stays below 255 characters

local Store = {}
Store.__index = Store

local Collection = {}
Collection.__index = Collection

local Json = { name = "json" }
local Sqlite = { name = "sqlite" }

function M:Init(ctx)
	self.stores = {}      -- ns -> store of a namespace (Open)
	self.collections = {} -- ns -> collection (Collection)
	self.tables = {}      -- sqlite: ns -> true once its table is known to exist
	local prefix = ctx.config.folder:lower():gsub("[^a-z0-9_]", "_")
	self.prefix = prefix .. "_"
	self.backend = self:_PickBackend(ctx, ctx.config.backend)
	ctx.commands:Add("nc_storage", { help = "[flush | <namespace> [key]] - persistent data of modules" },
		"StorageCommand")
end

function M:Start(ctx)
	ctx:On("gm.ShutDown", "FlushAll")
end

function M:Stop()
	self:FlushAll()
end

function M:_PickBackend(ctx, name)
	if name == "sqlite" then
		self.sql = rawget(_G, "sql")
		if type(self.sql) == "table" and type(self.sql.Query) == "function" then
			return Sqlite
		end
		ctx.log:Warn("backend sqlite: the sql library is missing, using json files")
	elseif name ~= nil and name ~= "json" then
		ctx.log:Warn("unknown backend '%s', using json files", tostring(name))
	end
	return Json
end

-- The name of the backend in use: "json" or "sqlite".
function M:Backend()
	return self.backend.name
end

local function checkName(ns, what)
	if type(ns) ~= "string" or not ns:find(NAME) then
		error(format("storage: %s(%s): a namespace is lowercase letters, digits and _", what, tostring(ns)), 3)
	end
end

-- The store of namespace `ns`, opened once per server.
function M:Open(ns)
	checkName(ns, "Open")
	if self.collections[ns] ~= nil then
		error("storage: Open(" .. ns .. "): it is a collection", 2)
	end
	local store = self.stores[ns]
	if store == nil then
		store = setmetatable({ ns = ns, module = self, data = self.backend.LoadAll(self, ns), dirty = false,
			pending = false, changed = {}, all = false }, Store)
		self.stores[ns] = store
	end
	return store
end

-- Whether namespace `ns` is open.
function M:IsOpen(ns)
	return self.stores[ns] ~= nil
end

-- The collection `ns`: records loaded one by one when asked for (profiles of thousands of
-- players without one big file).
function M:Collection(ns)
	checkName(ns, "Collection")
	if self.stores[ns] ~= nil then
		error("storage: Collection(" .. ns .. "): it is a namespace opened with Open", 2)
	end
	local collection = self.collections[ns]
	if collection == nil then
		collection = setmetatable({ ns = ns, module = self, cache = {}, changed = {}, pending = false }, Collection)
		self.collections[ns] = collection
	end
	return collection
end

-- The key of a player in stores: the SteamID64 ("bot_<name>" for bots).
function M:PlayerKey(ply)
	if ply:IsBot() then
		return "bot_" .. ply:Nick()
	end
	return ply:SteamID64()
end

function M:_Schedule(target)
	if target.pending then
		return
	end
	target.pending = true
	self.ctx:After(self.ctx.config.flushDelay, function()
		target.pending = false
		target:Flush()
	end)
end

-- Writes every changed store and collection now.
function M:FlushAll()
	for _, store in pairs(self.stores) do
		store:Flush()
	end
	for _, collection in pairs(self.collections) do
		collection:Flush()
	end
end

local function decode(self, text, what)
	local data = util.JSONToTable(text, false, true)
	if type(data) ~= "table" then
		self.ctx.log:Warn("%s is not valid JSON", what)
		return nil
	end
	return data
end

-- Backend json: files of DATA ---------------------------------------------------------------

local function encodeKey(key)
	local name = key:gsub("[^a-z0-9]", function(c)
		return format("_%02x", c:byte())
	end)
	return name
end

local function decodeKey(name)
	local key = name:gsub("_(%x%x)", function(hex)
		return char(tonumber(hex, 16))
	end)
	return key
end

local function ensureFolder(folder)
	if not file.IsDir(folder, "DATA") then
		file.CreateDir(folder)
	end
end

-- Reads a JSON file; a broken one is moved aside (<name>_corrupt.txt).
local function readFile(self, path, base)
	local text = file.Read(path, "DATA")
	if text == nil or text == "" then
		return nil
	end
	local data = util.JSONToTable(text, false, true)
	if type(data) ~= "table" then
		local copy = base .. "_corrupt.txt"
		file.Write(copy, text)
		file.Delete(path)
		self.ctx.log:Warn("%s is not valid JSON: moved to %s, starting empty", path, copy)
		return nil
	end
	return data
end

function Json.LoadAll(self, ns)
	local base = format("%s/%s", self.ctx.config.folder, ns)
	return readFile(self, base .. ".json", base) or {}
end

function Json.SaveAll(self, store)
	local folder = self.ctx.config.folder
	ensureFolder(folder)
	file.Write(format("%s/%s.json", folder, store.ns), util.TableToJSON(store.data, self.ctx.config.pretty == true))
	return true
end

local function recordBase(self, ns, key)
	return format("%s/%s/%s", self.ctx.config.folder, ns, encodeKey(key))
end

function Json.Read(self, ns, key)
	local base = recordBase(self, ns, key)
	return readFile(self, base .. ".json", base)
end

function Json.Write(self, collection, keys)
	local folder = format("%s/%s", self.ctx.config.folder, collection.ns)
	ensureFolder(folder)
	local pretty = self.ctx.config.pretty == true
	for _, key in ipairs(keys) do
		local record = collection.cache[key]
		local path = recordBase(self, collection.ns, key) .. ".json"
		if record then
			file.Write(path, util.TableToJSON(record, pretty))
		else
			file.Delete(path)
		end
		collection.changed[key] = nil
	end
	return true
end

function Json.Keys(self, ns)
	local files = file.Find(format("%s/%s/*.json", self.ctx.config.folder, ns), "DATA")
	local keys = {}
	for i, name in ipairs(files) do
		keys[i] = decodeKey(name:sub(1, -6))
	end
	return keys
end

-- Backend sqlite: tables of sv.db ------------------------------------------------------------

local function query(self, text)
	local result = self.sql.Query(text)
	if result == false then
		self.ctx.log:Error("sql: %s (in: %s)", tostring(self.sql.LastError()), text:sub(1, 160))
	end
	return result
end

local function quoteName(self, ns)
	return "\"" .. self.prefix .. ns .. "\""
end

local function insert(self, ns, key, json)
	return query(self, format("INSERT OR REPLACE INTO %s (\"key\", \"value\") VALUES (%s, %s)", quoteName(self, ns),
		self.sql.SQLStr(key), self.sql.SQLStr(json))) ~= false
end

local function remove(self, ns, key)
	return query(self, format("DELETE FROM %s WHERE \"key\" = %s", quoteName(self, ns), self.sql.SQLStr(key))) ~= false
end

-- Writes inside one transaction; fn returns false when a statement failed.
local function transaction(self, fn)
	query(self, "BEGIN")
	local ok = fn()
	query(self, "COMMIT")
	return ok
end

-- Makes the table of `ns` if it is missing and moves the JSON data of the name into it.
local function ensureTable(self, ns, kind)
	if self.tables[ns] then
		return true
	end
	if self.sql.TableExists(self.prefix .. ns) then
		self.tables[ns] = true
		return true
	end
	if query(self, format("CREATE TABLE IF NOT EXISTS %s (\"key\" TEXT PRIMARY KEY NOT NULL, \"value\" TEXT NOT NULL)",
		quoteName(self, ns))) == false then
		return false
	end
	self.tables[ns] = true
	local count = 0
	transaction(self, function()
		if kind == "store" then
			for key, value in pairs(Json.LoadAll(self, ns)) do
				count = count + (insert(self, ns, key, util.TableToJSON({ value })) and 1 or 0)
			end
		else
			for _, key in ipairs(Json.Keys(self, ns)) do
				local record = Json.Read(self, ns, key)
				if record ~= nil then
					count = count + (insert(self, ns, key, util.TableToJSON(record)) and 1 or 0)
				end
			end
		end
		return true
	end)
	if count > 0 then
		self.ctx.log:Info("sqlite: %d keys of the json data of '%s' moved into table %s", count, ns, self.prefix .. ns)
	end
	return true
end

function Sqlite.LoadAll(self, ns)
	local data = {}
	if not ensureTable(self, ns, "store") then
		return data
	end
	local rows = query(self, format("SELECT \"key\", \"value\" FROM %s", quoteName(self, ns)))
	for _, row in ipairs(type(rows) == "table" and rows or {}) do
		local wrapped = decode(self, row.value, format("%s%s[%s]", self.prefix, ns, row.key))
		if wrapped ~= nil then
			data[row.key] = wrapped[1]
		end
	end
	return data
end

function Sqlite.SaveAll(self, store)
	if not ensureTable(self, store.ns, "store") then
		return false
	end
	local ns = store.ns
	return transaction(self, function()
		local ok = true
		if store.all then
			ok = query(self, "DELETE FROM " .. quoteName(self, ns)) ~= false
			for key, value in pairs(store.data) do
				ok = insert(self, ns, key, util.TableToJSON({ value })) and ok
			end
			return ok
		end
		for key in pairs(store.changed) do
			local value = store.data[key]
			if value == nil then
				ok = remove(self, ns, key) and ok
			else
				ok = insert(self, ns, key, util.TableToJSON({ value })) and ok
			end
		end
		return ok
	end)
end

function Sqlite.Read(self, ns, key)
	if not ensureTable(self, ns, "collection") then
		return nil
	end
	local rows = query(self, format("SELECT \"value\" FROM %s WHERE \"key\" = %s", quoteName(self, ns),
		self.sql.SQLStr(key)))
	if type(rows) ~= "table" or rows[1] == nil then
		return nil
	end
	return decode(self, rows[1].value, format("%s%s[%s]", self.prefix, ns, key))
end

function Sqlite.Write(self, collection, keys)
	local ns = collection.ns
	if not ensureTable(self, ns, "collection") then
		return false
	end
	return transaction(self, function()
		local ok = true
		for _, key in ipairs(keys) do
			local record = collection.cache[key]
			local written
			if record then
				written = insert(self, ns, key, util.TableToJSON(record))
			else
				written = remove(self, ns, key)
			end
			if written then
				collection.changed[key] = nil
			end
			ok = written and ok
		end
		return ok
	end)
end

function Sqlite.Keys(self, ns)
	if not ensureTable(self, ns, "collection") then
		return {}
	end
	local rows = query(self, format("SELECT \"key\" FROM %s", quoteName(self, ns)))
	local keys = {}
	for i, row in ipairs(type(rows) == "table" and rows or {}) do
		keys[i] = row.key
	end
	return keys
end

-- Store: a namespace ---------------------------------------------------------------------------

local function checkKey(key)
	if type(key) ~= "string" or key == "" then
		error("storage: keys are non-empty strings, got " .. tostring(key), 3)
	end
end

local function markStore(store, key)
	if key == nil then
		store.all = true
	else
		store.changed[key] = true
	end
	store.dirty = true
	store.module:_Schedule(store)
end

function Store:Get(key)
	return self.data[key]
end

-- Sets the value of `key` (nil deletes it); it is written a moment later.
function Store:Set(key, value)
	checkKey(key)
	self.data[key] = value
	markStore(self, key)
	return value
end

function Store:Delete(key)
	checkKey(key)
	if self.data[key] ~= nil then
		self.data[key] = nil
		markStore(self, key)
	end
end

-- Marks the store as changed after changing a table got with Get: Touch(key) for that key
-- (the sqlite backend writes only it), Touch() for anything.
function Store:Touch(key)
	if key ~= nil then
		checkKey(key)
	end
	markStore(self, key)
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

-- Writes now if the store changed.
function Store:Flush()
	if not self.dirty then
		return
	end
	local module = self.module
	if module.backend.SaveAll(module, self) then
		self.dirty, self.all = false, false
		self.changed = {}
		module.ctx.events:Emit("storage.flushed", self.ns)
	end
end

-- Collection: a record per key ------------------------------------------------------------------

local function checkRecordKey(key)
	if type(key) ~= "string" or key == "" or #key > MAX_RECORD_KEY then
		error(format("storage: record keys are strings of 1-%d bytes, got %s", MAX_RECORD_KEY, tostring(key)), 3)
	end
end

local function markRecord(collection, key)
	collection.changed[key] = true
	collection.module:_Schedule(collection)
end

-- The record of `key` (read on the first call, then kept), or nil.
function Collection:Get(key)
	checkRecordKey(key)
	local record = self.cache[key]
	if record == nil then
		local module = self.module
		record = module.backend.Read(module, self.ns, key) or false
		self.cache[key] = record
	end
	return record or nil
end

function Collection:Has(key)
	checkRecordKey(key)
	return self:Get(key) ~= nil
end

-- Sets the record of `key` (a table; nil deletes it); it is written a moment later.
function Collection:Set(key, record)
	checkRecordKey(key)
	if record ~= nil and type(record) ~= "table" then
		error("storage: a record of a collection is a table, got " .. type(record), 2)
	end
	self.cache[key] = record or false
	markRecord(self, key)
	return record
end

function Collection:Delete(key)
	checkRecordKey(key)
	self.cache[key] = false
	markRecord(self, key)
end

-- Marks the record of `key` as changed (after changing the table got with Get).
function Collection:Touch(key)
	checkRecordKey(key)
	if self.cache[key] == nil then
		error("storage: Touch(" .. key .. "): the record was not read with Get", 2)
	end
	markRecord(self, key)
end

-- Writes the record if it changed and forgets it (a player has left); the next Get reads
-- it again.
function Collection:Release(key)
	checkRecordKey(key)
	self:Flush(key)
	if not self.changed[key] then
		self.cache[key] = nil
	end
end

-- Writes the changed records now (only `key` when given).
function Collection:Flush(key)
	local keys
	if key ~= nil then
		if not self.changed[key] then
			return
		end
		keys = { key }
	else
		if next(self.changed) == nil then
			return
		end
		keys = {}
		for changed in pairs(self.changed) do
			keys[#keys + 1] = changed
		end
		sort(keys)
	end
	local module = self.module
	module.backend.Write(module, self, keys)
	module.ctx.events:Emit("storage.flushed", self.ns)
end

-- Every stored key with the changes not written yet, sorted. Reads the folder or the
-- table: for commands and tools, not for hot paths.
function Collection:Keys()
	local module = self.module
	local set = {}
	for _, key in ipairs(module.backend.Keys(module, self.ns)) do
		set[key] = true
	end
	for key, record in pairs(self.cache) do
		set[key] = record and true or nil
	end
	local keys = {}
	for key in pairs(set) do
		keys[#keys + 1] = key
	end
	sort(keys)
	return keys
end

function Collection:Count()
	return #self:Keys()
end

-- Keys of the records in memory, sorted.
function Collection:LoadedKeys()
	local keys = {}
	for key, record in pairs(self.cache) do
		if record then
			keys[#keys + 1] = key
		end
	end
	sort(keys)
	return keys
end

-- Console --------------------------------------------------------------------------------------

local function sortedNames(list)
	local names = {}
	for ns in pairs(list) do
		names[#names + 1] = ns
	end
	sort(names)
	return names
end

function M:_DescribeOne(ns, key)
	local store = self.stores[ns] or self.collections[ns]
	if store == nil then
		return "storage: namespace '" .. tostring(ns) .. "' is not open"
	end
	if key ~= nil then
		local value = store:Get(key)
		return value == nil and "storage: no such key" or util.TableToJSON({ value = value }, true)
	end
	local keys = store:Keys()
	local lines = { format("storage %s: %d keys", ns, #keys) }
	for _, name in ipairs(keys) do
		lines[#lines + 1] = "  " .. name
	end
	return lines
end

function M:StorageCommand(_, args)
	if args[1] == "flush" then
		self:FlushAll()
		return "storage: written"
	end
	if args[1] ~= nil then
		return self:_DescribeOne(args[1], args[2])
	end
	local stores, collections = sortedNames(self.stores), sortedNames(self.collections)
	local where = self.backend == Sqlite and format("tables %s* of sv.db", self.prefix)
		or "data/" .. self.ctx.config.folder
	local lines = { format("storage (%s): %d namespaces, %d collections in %s", self.backend.name, #stores,
		#collections, where) }
	for _, ns in ipairs(stores) do
		local store = self.stores[ns]
		lines[#lines + 1] = format("  %s: %d keys%s", ns, store:Count(), store.dirty and " (not written yet)" or "")
	end
	for _, ns in ipairs(collections) do
		local collection = self.collections[ns]
		local changed = 0
		for _ in pairs(collection.changed) do
			changed = changed + 1
		end
		lines[#lines + 1] = format("  %s: collection, %d loaded%s", ns, #collection:LoadedKeys(),
			changed > 0 and format(" (%d not written yet)", changed) or "")
	end
	return lines
end
