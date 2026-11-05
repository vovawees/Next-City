-- The sql library of GMod for the emulated realms: SQLite through the LuaJIT FFI and the
-- libsqlite3 of the system. Like the engine: Query returns the rows (every value a string,
-- NULL as "NULL"), nil when there are none and false on an error (LastError tells it);
-- QueryRow, QueryValue, TableExists, IndexExists, Begin, Commit and SQLStr are the Lua
-- helpers of garrysmod/lua/includes/util/sql.lua.
--
--   Sqlite.Available()      whether libsqlite3 could be loaded (specs skip SQL otherwise)
--   Sqlite.Open()           a new database in memory (sv.db of one emulated machine)
--   Sqlite.Library(getDb)   the sql table of a realm; getDb() returns its database (made on
--                           the first query, so realms that never use SQL open nothing)
--
-- The loaded library is kept in package.loaded across the dofile of every spec: a collected
-- library would be unloaded while databases of earlier specs still close through it.

local Sqlite = {}

local SQLITE_OK, SQLITE_ROW, SQLITE_DONE, SQLITE_NULL = 0, 100, 101, 5

local CDEF = [[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open(const char *filename, sqlite3 **db);
int sqlite3_close(sqlite3 *db);
int sqlite3_prepare_v2(sqlite3 *db, const char *sql, int bytes, sqlite3_stmt **stmt, const char **tail);
int sqlite3_step(sqlite3_stmt *stmt);
int sqlite3_finalize(sqlite3_stmt *stmt);
int sqlite3_column_count(sqlite3_stmt *stmt);
const char *sqlite3_column_name(sqlite3_stmt *stmt, int column);
int sqlite3_column_type(sqlite3_stmt *stmt, int column);
const unsigned char *sqlite3_column_text(sqlite3_stmt *stmt, int column);
int sqlite3_column_bytes(sqlite3_stmt *stmt, int column);
const char *sqlite3_errmsg(sqlite3 *db);
]]

local NAMES = { "sqlite3", "libsqlite3.so.0", "libsqlite3.so", "libsqlite3.0.dylib", "libsqlite3.dylib" }

local ANCHOR = "nextcity.tests.sqlite"
local ffi, lib

local function load()
	if lib ~= nil then
		return lib or nil
	end
	local anchored = package.loaded[ANCHOR]
	if anchored ~= nil then
		ffi, lib = anchored.ffi, anchored.lib
		return lib or nil
	end
	lib = false
	package.loaded[ANCHOR] = { lib = false }
	local ok, loaded = pcall(require, "ffi")
	if not ok then
		return nil
	end
	ffi = loaded
	pcall(ffi.cdef, CDEF)
	for _, name in ipairs(NAMES) do
		local found, handle = pcall(ffi.load, name)
		if found and pcall(function() return handle.sqlite3_open end) then
			lib = handle
			package.loaded[ANCHOR] = { ffi = ffi, lib = lib }
			return lib
		end
	end
	return nil
end

function Sqlite.Available()
	return load() ~= nil
end

function Sqlite.Open()
	local L = load()
	assert(L ~= nil, "libsqlite3 is not available")
	local out = ffi.new("sqlite3*[1]")
	assert(L.sqlite3_open(":memory:", out) == SQLITE_OK, "sqlite3_open failed")
	return { handle = ffi.gc(out[0], L.sqlite3_close), queries = 0, lastError = nil }
end

local function rowOf(stmt, columns)
	local row = {}
	for i = 0, columns - 1 do
		local name = ffi.string(lib.sqlite3_column_name(stmt, i))
		if lib.sqlite3_column_type(stmt, i) == SQLITE_NULL then
			row[name] = "NULL"
		else
			row[name] = ffi.string(lib.sqlite3_column_text(stmt, i), lib.sqlite3_column_bytes(stmt, i))
		end
	end
	return row
end

-- Runs every statement of `text`; the rows of all of them, nil without rows, false on an error.
function Sqlite.Query(db, text)
	db.queries = db.queries + 1
	text = tostring(text)
	local buffer = ffi.new("char[?]", #text + 1)
	ffi.copy(buffer, text)
	local cursor = ffi.cast("const char *", buffer)
	local stmtOut = ffi.new("sqlite3_stmt*[1]")
	local tailOut = ffi.new("const char*[1]")
	db.buffer = buffer -- anchored while cursor points into it
	local rows = {}
	while cursor[0] ~= 0 do
		if lib.sqlite3_prepare_v2(db.handle, cursor, -1, stmtOut, tailOut) ~= SQLITE_OK then
			db.lastError = ffi.string(lib.sqlite3_errmsg(db.handle))
			return false
		end
		local stmt = stmtOut[0]
		cursor = tailOut[0]
		if stmt ~= nil then
			local columns = lib.sqlite3_column_count(stmt)
			local rc = lib.sqlite3_step(stmt)
			while rc == SQLITE_ROW do
				rows[#rows + 1] = rowOf(stmt, columns)
				rc = lib.sqlite3_step(stmt)
			end
			lib.sqlite3_finalize(stmt)
			if rc ~= SQLITE_DONE then
				db.lastError = ffi.string(lib.sqlite3_errmsg(db.handle))
				return false
			end
		end
	end
	if rows[1] == nil then
		return nil
	end
	return rows
end

function Sqlite.Library(getDb)
	local sql = {}

	function sql.Query(text)
		return Sqlite.Query(getDb(), text)
	end

	function sql.LastError()
		return getDb().lastError
	end

	function sql.SQLStr(value, noQuotes)
		local text = tostring(value):gsub("'", "''")
		local zero = text:find("\0", 1, true)
		if zero ~= nil then
			text = text:sub(1, zero - 1)
		end
		if noQuotes then
			return text
		end
		return "'" .. text .. "'"
	end

	function sql.QueryRow(text, row)
		local result = sql.Query(text)
		if result then
			return result[row or 1]
		end
		return result
	end

	function sql.QueryValue(text)
		local result = sql.Query(text)
		if result and result[1] then
			for _, value in pairs(result[1]) do
				return value
			end
		end
		return result
	end

	function sql.TableExists(name)
		return sql.Query("SELECT name FROM sqlite_master WHERE name=" .. sql.SQLStr(name) .. " AND type='table'")
			~= nil
	end

	function sql.IndexExists(name)
		return sql.Query("SELECT name FROM sqlite_master WHERE name=" .. sql.SQLStr(name) .. " AND type='index'")
			~= nil
	end

	function sql.Begin()
		sql.Query("BEGIN;")
	end

	function sql.Commit()
		sql.Query("COMMIT;")
	end

	return sql
end

return Sqlite
