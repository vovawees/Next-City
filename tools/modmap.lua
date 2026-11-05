-- Prints the module map of the repository for .ai/modules.txt: one block per module of
-- every package with what it provides, needs, sends and replicates.
-- Run from the repository root: luajit tools/modmap.lua > /tmp/modmap.txt

local ROOTS = {
	{ "core", "gamemodes/nextcity/gamemode/modules/" },
	{ "addons", "lua/nextcity/modules/" },
}

local WIDTH = 120

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

local function sortedKeys(map)
	local list = {}
	for key in pairs(map or {}) do
		list[#list + 1] = key
	end
	table.sort(list)
	return list
end

local function join(list)
	if list == nil or #list == 0 then
		return "-"
	end
	return concat(list, ",")
end

local function files(manifest)
	local parts = {}
	for _, realm in ipairs({ "sh", "sv", "cl" }) do
		local list = manifest.files and manifest.files[realm]
		if list ~= nil and #list > 0 then
			parts[#parts + 1] = realm .. ":" .. concat(list, ",")
		end
	end
	return join(parts)
end

local function nets(manifest)
	local parts = {}
	for _, name in ipairs(sortedKeys(manifest.net)) do
		parts[#parts + 1] = name .. "<" .. tostring(manifest.net[name].from or "?") .. ">"
	end
	return join(parts)
end

local function components(manifest)
	local parts = {}
	for _, name in ipairs(sortedKeys(manifest.components)) do
		parts[#parts + 1] = name .. "<" .. tostring(manifest.components[name].replicate or "server") .. ">"
	end
	return join(parts)
end

-- Prints `text` after `prefix`; a list wider than WIDTH goes on after a comma on the next
-- line, under the start of the list.
local function printList(prefix, text)
	local indent = string.rep(" ", #prefix)
	local line = prefix
	for item, comma in text:gmatch("([^,]+)(,?)") do
		if #line + #item + #comma > WIDTH and line ~= prefix and line ~= indent then
			print(line)
			line = indent
		end
		line = line .. item .. comma
	end
	print(line)
end

local count = 0
for _, root in ipairs(ROOTS) do
	for _, id in ipairs(folders(root[2])) do
		local chunk = loadfile(root[2] .. id .. "/module.lua")
		if chunk ~= nil then
			setfenv(chunk, {})
			local ok, manifest = pcall(chunk)
			if ok and type(manifest) == "table" then
				count = count + 1
				print(format("[%s] %s: %s", root[1], id, tostring(manifest.description or "")))
				print(format("  provides=%s requires=%s optional=%s", join(manifest.provides),
					join(manifest.requires), join(manifest.optional)))
				printList("  files=", files(manifest))
				printList("  net=", nets(manifest))
				printList("  components=", components(manifest))
			end
		end
	end
end
print(format("total modules: %d", count))
