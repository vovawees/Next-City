-- Prints the API map of the repository for .ai/api.txt: one block per module of every
-- package with its public methods by realm, the events it emits, the questions it asks,
-- the values it reduces, the events it listens to and its console commands; then every
-- question with the modules that ask and answer it, and every event with its listeners.
-- Public = `function M:Name(...)` or `function M.Name(...)` with a capital first letter, and
-- the methods of classes with title-case names (Round:On, Container:Find).
-- Left out: the lifecycle (Init, Start, Stop) and handlers, i.e. methods whose name is
-- also a string literal of the module (ctx:On(event, "Name"), net:Receive, commands:Add).
-- Events come from the code (:Emit, :Query, :Reduce, :On with a literal name) and from
-- the "Asks:", "Emits:" and "Reduces:" sections of the header comments of the files.
-- Run from the repository root: luajit tools/apimap.lua > .ai/api.txt

local ROOTS = {
	{ "core", "gamemodes/nextcity/gamemode/modules/" },
	{ "addons", "lua/nextcity/modules/" },
}
local REALMS = { "sh", "sv", "cl" }
local SECTIONS = { Asks = "asks", Emits = "emits", Reduces = "reduces" }
local NAMESPACES = { gm = true, i18n = true, net = true }
local LIFECYCLE = { Init = true, Start = true, Stop = true }
local WIDTH = 118

local format = string.format
local concat = table.concat

local function folders(dir)
	local list = {}
	local pipe = io.popen("ls -1 " .. dir .. " 2>/dev/null")
	for line in pipe:lines() do
		list[#list + 1] = line
	end
	pipe:close()
	return list
end

local function readFile(path)
	local handle = io.open(path, "r")
	if handle == nil then
		return ""
	end
	local text = handle:read("*a")
	handle:close()
	return text
end

-- Words of `list` after `label`, wrapped at WIDTH with an indent under the first word.
local function wrapped(label, list)
	if #list == 0 then
		return
	end
	local head = format("  %-8s ", label)
	local line = head
	local pad = string.rep(" ", #head)
	for _, word in ipairs(list) do
		if #line + #word + 1 > WIDTH and line ~= head and line ~= pad then
			local trimmed = line:gsub("%s+$", "")
			print(trimmed)
			line = pad
		end
		line = line .. word .. " "
	end
	local trimmed = line:gsub("%s+$", "")
	print(trimmed)
end

-- Unique values of `pattern` in `text`, in the order they first appear, added to `into`.
local function collect(text, pattern, into, seen)
	for value in text:gmatch(pattern) do
		if not seen[value] then
			seen[value] = true
			into[#into + 1] = value
		end
	end
end

-- Event names in the "Asks:", "Emits:" and "Reduces:" sections of the leading comment of
-- `text`, added to lists[kind]; only names of known namespaces (module ids, gm, i18n, net).
-- A section goes on over indented lines and ends at a new sentence or an empty line.
local function headerEvents(text, lists, seen, ids)
	local kind
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		if line:sub(1, 2) ~= "--" then
			break
		end
		local section = line:match("^%-%-%s*(%u%l+)[%w ]*:")
		if section ~= nil then
			kind = SECTIONS[section]
		elseif line:match("^%-%-%s?%S") or line:match("^%-%-%s*$") then
			kind = nil -- a new sentence or an empty line ends the section
		end
		if kind ~= nil then
			for name in line:gmatch("([%a_][%w_]*%.[%w_%.]*[%w_])") do
				local space = name:match("^([%w_]+)")
				if (ids[space] or NAMESPACES[space]) and not seen[kind][name] then
					seen[kind][name] = true
					local list = lists[kind]
					list[#list + 1] = name
				end
			end
		end
	end
end

local function sortedKeys(map)
	local list = {}
	for key in pairs(map) do
		list[#list + 1] = key
	end
	table.sort(list)
	return list
end

local ids = {}
for _, root in ipairs(ROOTS) do
	for _, id in ipairs(folders(root[2])) do
		ids[id] = true
	end
end

local askers, emitters, hearers = {}, {}, {}
local function note(map, name, id)
	local list = map[name]
	if list == nil then
		list = {}
		map[name] = list
	end
	if list[#list] ~= id then
		list[#list + 1] = id
	end
end

local count, methods = 0, 0

-- The manifest of a module folder, or nil.
local function manifestOf(dir)
	local chunk = loadfile(dir .. "module.lua")
	if chunk == nil then
		return nil
	end
	setfenv(chunk, {})
	local ok, result = pcall(chunk)
	return ok and type(result) == "table" and result or nil
end

-- The files of a manifest in load order: { { realm, text } }, and all of them as one text.
local function sources(dir, manifest)
	local texts, all = {}, {}
	for _, realm in ipairs(REALMS) do
		for _, name in ipairs(manifest.files and manifest.files[realm] or {}) do
			local text = readFile(dir .. name)
			texts[#texts + 1] = { realm = realm, text = text }
			all[#all + 1] = text
		end
	end
	return texts, concat(all, "\n")
end

-- Public methods of one line into the lists of the module.
local function methodOf(line, realm, api)
	local class, method, params = line:match("^function (%u%l[%w_]*):(%u[%w_]*)%(([^)]*)%)")
	if class ~= nil and not api.classSeen[class .. ":" .. method] then
		api.classSeen[class .. ":" .. method] = true
		if api.classes[class] == nil then
			api.classes[class] = {}
			api.classOrder[#api.classOrder + 1] = class
		end
		local list = api.classes[class]
		list[#list + 1] = method .. "(" .. params:gsub("%s+", "") .. ")"
	end
	local sep, name, args = line:match("^function M([:.])(%u[%w_]*)%(([^)]*)%)")
	if name == nil or LIFECYCLE[name] or api.strings[name] or api.seen[realm][name] then
		return
	end
	api.seen[realm][name] = true
	local list = api.byRealm[realm]
	list[#list + 1] = (sep == "." and "." or "") .. name .. "(" .. args:gsub("%s+", "") .. ")"
	methods = methods + 1
end

local function printModule(rootName, id, dir, manifest)
	local texts, whole = sources(dir, manifest)
	local api = {
		byRealm = { sh = {}, sv = {}, cl = {} }, seen = { sh = {}, sv = {}, cl = {} },
		classes = {}, classOrder = {}, classSeen = {}, strings = {},
	}
	for value in whole:gmatch("\"([%w_]+)\"") do
		api.strings[value] = true
	end
	for _, file in ipairs(texts) do
		for line in file.text:gmatch("[^\n]+") do
			methodOf(line, file.realm, api)
		end
	end

	local lists = { emits = {}, asks = {}, reduces = {} }
	local found = { emits = {}, asks = {}, reduces = {} }
	local listens, commands = {}, {}
	collect(whole, ":Emit%(%s*\"([%w%._]+)\"", lists.emits, found.emits)
	collect(whole, ":Query%(%s*\"([%w%._]+)\"", lists.asks, found.asks)
	collect(whole, ":Reduce%(%s*\"([%w%._]+)\"", lists.reduces, found.reduces)
	for _, file in ipairs(texts) do
		headerEvents(file.text, lists, found, ids)
	end
	collect(whole, ":On%(%s*\"([%w%._]+)\"", listens, {})
	collect(whole, ":Add%(%s*\"(nc_[%w_]+)\"", commands, {})
	for _, kind in ipairs({ "asks", "reduces" }) do
		for _, name in ipairs(lists[kind]) do
			note(askers, name, id)
		end
	end
	for _, name in ipairs(lists.emits) do
		note(emitters, name, id)
	end
	for _, name in ipairs(listens) do
		note(hearers, name, id)
	end

	print(format("[%s] %s", rootName, id))
	for _, realm in ipairs(REALMS) do
		wrapped(realm, api.byRealm[realm])
	end
	for _, class in ipairs(api.classOrder) do
		wrapped(class .. ":", api.classes[class])
	end
	wrapped("emits", lists.emits)
	wrapped("asks", lists.asks)
	wrapped("reduces", lists.reduces)
	wrapped("listens", listens)
	wrapped("commands", commands)
end

print("API MAP (generated: luajit tools/apimap.lua > .ai/api.txt; do not edit by hand)")
print("contracts with arguments and returns: the header comment of every module file and the API section")
print("of its README; sh/sv/cl = realm, .Name = static function, Class: = methods of a class of the module;")
print("questions: Query (first non-nil answer wins), reductions: Reduce (a value through every listener)\n")
for _, root in ipairs(ROOTS) do
	for _, id in ipairs(folders(root[2])) do
		local dir = root[2] .. id .. "/"
		local manifest = manifestOf(dir)
		if manifest ~= nil then
			count = count + 1
			printModule(root[1], id, dir, manifest)
		end
	end
end

local function crossRef(title, from)
	print("\n" .. title)
	for _, name in ipairs(sortedKeys(from)) do
		local line = format("  %-28s %s -> ", name, concat(from[name], ","))
		local pad = string.rep(" ", #line)
		local to = hearers[name] or { "-" }
		for i, id in ipairs(to) do
			local word = id .. (i < #to and "," or "")
			if #line + #word > WIDTH then
				print(line)
				line = pad
			end
			line = line .. word
		end
		print(line)
	end
end

crossRef("QUESTIONS AND REDUCTIONS (name  askers -> answerers)", askers)
crossRef("EVENTS (name  emitters -> listeners)", emitters)
print(format("\n%d modules, %d public methods", count, methods))
