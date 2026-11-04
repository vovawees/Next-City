-- Next-City platform: module loader, runs on both realms.
--
-- Discovers modules/<id>/module.lua in every package (platform/packages.lua: the core,
-- a derived gamemode, addons), registers the manifests, resolves them and includes the
-- files of every resolved module in dependency order: sh then sv on the server, sh then
-- cl on clients. The first package with a module id keeps it; the same id in a later
-- package is an error. The server sends every manifest and the sh/cl files of resolved
-- modules to clients, so both realms resolve the same set of modules.

local Loader = {}

local format = string.format

local MODULES_DIR = "modules/"

-- Returns { { id = folder, path = manifest path, dir = folder path, package = name } } in
-- package order, then by folder name, and the problems found ({ message }).
function Loader.Discover(packages)
	local found, owners, problems = {}, {}, {}
	for _, package in ipairs(packages) do
		local base = package.path .. MODULES_DIR
		local _, folders = file.Find(base .. "*", "LUA")
		local sorted = {}
		for i, folder in ipairs(folders or {}) do
			sorted[i] = folder
		end
		table.sort(sorted)
		for _, folder in ipairs(sorted) do
			local dir = base .. folder .. "/"
			local path = dir .. "module.lua"
			if file.Exists(path, "LUA") then
				local owner = owners[folder]
				if owner ~= nil then
					problems[#problems + 1] = format("module '%s' of package %s ignored: package %s already has it (%s)",
						folder, package.name, owner.package, owner.path)
				else
					local item = { id = folder, path = path, dir = dir, package = package.name }
					owners[folder] = item
					found[#found + 1] = item
				end
			end
		end
	end
	return found, problems
end

local function registerManifest(registry, item, log)
	if SERVER then
		AddCSLuaFile(item.path)
	end
	local ok, manifest = pcall(include, item.path)
	if not ok then
		log:Error("manifest %s failed: %s", item.path, tostring(manifest))
	elseif type(manifest) ~= "table" then
		log:Error("manifest %s must return a table", item.path)
	elseif manifest.id ~= item.id then
		log:Error("manifest %s: id '%s' must match its folder '%s'", item.path, tostring(manifest.id), item.id)
	else
		return registry:Register(manifest)
	end
	return false
end

local function includeFiles(registry, id, dir, files)
	for _, name in ipairs(files) do
		if registry:State(id) ~= "resolved" then
			return
		end
		local path = dir .. name
		if not file.Exists(path, "LUA") then
			registry:Fail(id, "file not found: " .. path)
			return
		end
		local ok, err = pcall(include, path)
		if not ok then
			registry:Fail(id, "loading " .. name .. " failed: " .. tostring(err))
			return
		end
	end
end

-- Registers, resolves and includes the modules of `packages` (platform/packages.lua).
-- cfg is config.modules. Returns the load order and { [id] = package name }.
function Loader.Load(registry, cfg, log, packages)
	local found, problems = Loader.Discover(packages)
	for _, message in ipairs(problems) do
		log:Error("%s", message)
	end
	local dirs, sources = {}, {}
	for _, item in ipairs(found) do
		if registerManifest(registry, item, log) then
			dirs[item.id] = item.dir
			sources[item.id] = item.package
		end
	end

	local order = registry:Resolve(cfg)

	if SERVER then
		for _, id in ipairs(order) do
			local dir = dirs[id]
			local files = registry:Files(id)
			for _, name in ipairs(files.sh) do
				AddCSLuaFile(dir .. name)
			end
			for _, name in ipairs(files.cl) do
				AddCSLuaFile(dir .. name)
			end
		end
	end

	for _, id in ipairs(order) do
		local dir = dirs[id]
		local files = registry:Files(id)
		includeFiles(registry, id, dir, files.sh)
		includeFiles(registry, id, dir, SERVER and files.sv or files.cl)
	end
	return order, sources
end

return Loader
