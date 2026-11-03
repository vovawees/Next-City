-- Next-City platform: module loader, runs on both realms.
--
-- Discovers gamemode/modules/<id>/module.lua, registers the manifests, resolves them and
-- includes the files of every resolved module in dependency order: sh then sv on the
-- server, sh then cl on clients. The server sends every manifest and the sh/cl files of
-- resolved modules to clients, so both realms resolve the same set of modules.

local Loader = {}

local MODULES_DIR = "modules/"

-- Returns { { id = folder, path = manifest path } } sorted by folder name.
function Loader.Discover(root)
	local _, folders = file.Find(root .. MODULES_DIR .. "*", "LUA")
	local sorted = {}
	for i, folder in ipairs(folders or {}) do
		sorted[i] = folder
	end
	table.sort(sorted)
	local found = {}
	for _, folder in ipairs(sorted) do
		local path = root .. MODULES_DIR .. folder .. "/module.lua"
		if file.Exists(path, "LUA") then
			found[#found + 1] = { id = folder, path = path }
		end
	end
	return found
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
		registry:Register(manifest)
	end
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

-- Registers, resolves and includes modules. cfg is config.modules.
function Loader.Load(registry, cfg, log)
	local root = NC.ROOT
	for _, item in ipairs(Loader.Discover(root)) do
		registerManifest(registry, item, log)
	end

	local order = registry:Resolve(cfg)

	if SERVER then
		for _, id in ipairs(order) do
			local dir = root .. MODULES_DIR .. id .. "/"
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
		local dir = root .. MODULES_DIR .. id .. "/"
		local files = registry:Files(id)
		includeFiles(registry, id, dir, files.sh)
		includeFiles(registry, id, dir, SERVER and files.sv or files.cl)
	end
	return order
end

return Loader
