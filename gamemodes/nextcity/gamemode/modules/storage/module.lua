-- Storage: data of modules that outlives the map and the server (bank accounts, doors,
-- loot points, profiles): namespaces read at once and collections with a record per key
-- read when asked for, written a moment after the last change and at shutdown; JSON files
-- of the DATA folder or tables of the engine's SQLite database (sv.db).
return {
	id = "storage",
	description = "Storage: persistent data of modules, namespaces and collections in JSON files or SQLite",
	files = {
		sv = { "sv_storage.lua" },
	},
	config = {
		folder = "nextcity", -- folder of the files in garrysmod/data
		flushDelay = 2,      -- s after a change before its file is written
		pretty = false,      -- indented JSON: easier to read, bigger
		backend = "json",    -- "json": files of garrysmod/data; "sqlite": tables of sv.db (the sql library)
	},
}
