-- Storage: data of modules that outlives the map and the server (bank accounts, doors,
-- loot points): one JSON file per namespace in the DATA folder, read once and written a
-- moment after the last change and at shutdown.
return {
	id = "storage",
	description = "Storage: persistent data of modules in JSON files of the DATA folder",
	files = {
		sv = { "sv_storage.lua" },
	},
	config = {
		folder = "nextcity", -- folder of the files in garrysmod/data
		flushDelay = 2,      -- s after a change before its file is written
		pretty = false,      -- indented JSON: easier to read, bigger
	},
}
