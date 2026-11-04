-- Next-City platform: packages, runs on both realms.
--
-- The core holds no content (D15): weapons, items, modes and other content are modules
-- of packages on top of it, so a server is put together by installing packages. A
-- package is a folder with modules/<id>/module.lua, lang/<code>/*.lua and config/*.lua:
--
--   core      the gamemode itself: gamemode/modules, gamemode/lang, gamemode/config.lua
--   <name>    the active gamemode when it derives from Next-City:
--             gamemodes/<name>/gamemode/{modules,lang,config}
--   addons    every addon and the server's own lua folder: lua/nextcity/{modules,lang,config}
--
-- Modules and languages are looked up in this order; the first package that has a
-- module id keeps it (platform/loader.lua). Config files are applied over config.lua of
-- the core in the same order, the files of one package by name and its server.lua
-- last: tables merge key by key, lists and other values replace. Config files are sent
-- to clients like config.lua: no secrets in them.

local Packages = {}

local format = string.format
local sort = table.sort

local CONFIG_DIR = "config/"
local LAST = "server.lua"

-- The packages in lookup order: { { name, path } }, path with a trailing slash.
function Packages.List(root)
	local list = { { name = "core", path = root } }
	local active = engine.ActiveGamemode()
	if type(active) == "string" and active ~= "" and active .. "/gamemode/" ~= root then
		list[#list + 1] = { name = active, path = active .. "/gamemode/" }
	end
	list[#list + 1] = { name = "addons", path = "nextcity/" }
	return list
end

-- Folders of `dir` (LUA path with a trailing slash), sorted.
function Packages.Folders(dir)
	local _, folders = file.Find(dir .. "*", "LUA")
	local sorted = {}
	for i, folder in ipairs(folders or {}) do
		sorted[i] = folder
	end
	sort(sorted)
	return sorted
end

-- Lua files of `dir`, sorted.
function Packages.Files(dir)
	local files = file.Find(dir .. "*.lua", "LUA")
	local sorted = {}
	for i, name in ipairs(files or {}) do
		sorted[i] = name
	end
	sort(sorted)
	return sorted
end

local function isList(value)
	return value[1] ~= nil
end

-- `override` merged over `base`: tables key by key (into a new table), lists and other
-- values replace.
local function merge(base, override)
	if type(base) ~= "table" or type(override) ~= "table" or isList(base) or isList(override) then
		return override
	end
	local out = {}
	for key, value in pairs(base) do
		out[key] = value
	end
	for key, value in pairs(override) do
		out[key] = merge(base[key], value)
	end
	return out
end
Packages.Merge = merge

local function configFiles(dir)
	local names = Packages.Files(dir)
	sort(names, function(a, b)
		if (a == LAST) ~= (b == LAST) then
			return b == LAST
		end
		return a < b
	end)
	return names
end

-- The config of the core with the config files of the packages applied. Returns the
-- config and the problems ({ message }) to log once a logger exists.
function Packages.Config(base, list)
	local config = base
	local problems = {}
	for i = 2, #list do
		local dir = list[i].path .. CONFIG_DIR
		for _, name in ipairs(configFiles(dir)) do
			local path = dir .. name
			if SERVER then
				AddCSLuaFile(path)
			end
			local ok, result = pcall(include, path)
			if not ok then
				problems[#problems + 1] = format("config %s failed: %s", path, tostring(result))
			elseif type(result) ~= "table" then
				problems[#problems + 1] = format("config %s must return a table", path)
			else
				config = merge(config, result)
			end
		end
	end
	return config, problems
end

return Packages
