-- Menu (F1): the frame with the tabs in order (the profile of profiles first, the character
-- of identity, the appearance, then the settings and the help), F1 toggles it, the language
-- from the settings tab, the help with the keys and the chat of the modules and the commands
-- of the player (admin ones only with the privilege, asked again when the privileges change), tabs
-- and help entries of modules through the API, stamps, entries that keep what was typed, a
-- failing tab.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World

-- opts: modules (default every one), settings of the menu.
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = opts.modules, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.menu = opts.settings
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	return server, server:Get("NC")
end

-- Lets the server answer and the client learn it.
local function settle(server, client)
	for _ = 1, 2 do
		server:Advance(0.5)
		client.time = server.time
		Env.Flush(server, client)
	end
end

-- The panels of a client with `field` (equal to `value` when given).
local function panels(client, field, value)
	return World.FindPanels(client, function(panel)
		return rawget(panel, field) ~= nil and (value == nil or rawget(panel, field) == value)
	end)
end

-- The values of `field` of the panels of a client that have it.
local function fields(client, field)
	local out = {}
	for i, panel in ipairs(panels(client, field)) do
		out[i] = rawget(panel, field)
	end
	return out
end

local function click(client, field, value)
	local button = panels(client, field, value)[1]
	assert(button ~= nil, "no panel with " .. field .. " = " .. tostring(value))
	button.DoClick(button)
end

-- { caption, value } of the rows of the open tab with `field` (ncStat, ncHelp, ncCommand).
local function rows(client, field)
	local out = {}
	for _, row in ipairs(panels(client, field)) do
		out[#out + 1] = { row.children[1]:GetText(), row.children[2]:GetText() }
	end
	return out
end

local function texts(list)
	local out = {}
	for i, item in ipairs(list) do
		out[i] = item[1]
	end
	return out
end

describe("menu", function()
	it("opens on F1 with the profile, the character, the appearance, the settings, the help; F1 closes it", function()
		local server = boot()
		local client = Env.Join(server, { name = "Gordon", language = "en" })
		settle(server, client)
		local menu = client:Get("NC").Modules:Instance("menu")
		expect(Env.BindPress(client, "gm_showhelp")):toBe(true)
		expect({ menu:IsOpen(), menu:Tab() }):toEqual({ true, "profile" })
		local frame = panels(client, "ncMenu")[1]
		expect(frame.popup):toBe(true)
		expect(fields(client, "ncTab")):toEqual({ "profile", "character", "appearance", "settings", "help" })
		expect(panels(client, "ncTab", "profile")[1]:GetText()):toBe("Profile")
		expect(panels(client, "ncTab", "profile")[1].ncActive):toBe(true)
		expect(rows(client, "ncStat")):toEqual({
			{ "First visit", os.date("%Y-%m-%d", os.time()) }, { "Visits", "1" }, { "Time in the game", "0 min" },
			{ "Kills", "0" }, { "Deaths", "0" }, { "Rounds played", "0" }, { "Rounds won", "0" },
			{ "Creatures killed", "0" },
		})

		-- The playtime goes on while the menu is open: the stamp builds the tab again.
		server:Advance(3725)
		settle(server, client)
		menu:Refresh(false)
		expect(rows(client, "ncStat")[3]):toEqual({ "Time in the game", "1 h 2 min" })

		-- F1 closes it, the menu opens again on the last tab.
		client.keyBinds = { [92] = "gm_showhelp" }
		click(client, "ncTab", "help")
		frame = panels(client, "ncMenu")[1]
		frame.OnKeyCodePressed(frame, 92)
		expect({ menu:IsOpen(), frame.removed }):toEqual({ false, true })
		expect(Env.BindPress(client, "gm_showhelp")):toBe(true)
		expect(menu:Tab()):toBe("help")
		expect(Env.BindPress(client, "gm_showhelp")):toBe(true)
		expect(menu:IsOpen()):toBe(false)
		expect(Env.BindPress(client, "gm_showhelp", false)):toBe(nil)
		expect(Env.BindPress(client, "gm_showspare1")):toBe(nil)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("switches the language from the settings tab and follows it at once", function()
		local server = boot()
		local client = Env.Join(server, { name = "Gordon", language = "en" })
		settle(server, client)
		local menu = client:Get("NC").Modules:Instance("menu")
		menu:Open("settings")
		local function languages()
			local out = {}
			for _, button in ipairs(panels(client, "ncLanguage")) do
				out[#out + 1] = { button.ncLanguage, button:GetText(), button.ncActive }
			end
			return out
		end
		expect(languages()):toEqual({
			{ "auto", "Auto — the language of the game", true }, { "en", "English", false },
			{ "ru", "Русский · Russian", false },
		})
		click(client, "ncLanguage", "ru")
		expect(client.convars.nc_language:GetString()):toBe("ru")
		expect(menu:Tab()):toBe("settings")
		expect(panels(client, "ncTab", "profile")[1]:GetText()):toBe("Профиль")
		expect(panels(client, "ncTab", "settings")[1]:GetText()):toBe("Настройки")
		expect(languages()[3]):toEqual({ "ru", "Русский · Russian", true })
		expect(languages()[1][2]):toBe("Авто — как язык игры")
		-- The server learns the language of the player.
		settle(server, client)
		local ply = server:Get("player").GetAll()[1]
		expect(server:Get("NC").I18n:LanguageOf(ply)):toBe("ru")

		-- Back to the language of the game.
		click(client, "ncLanguage", "auto")
		expect(client.convars.nc_language:GetString()):toBe("auto")
		expect(panels(client, "ncTab", "help")[1]:GetText()):toBe("Help")
		expect(languages()[1][3]):toBe(true)
		expect(client:Errors()):toEqual({})
	end)

	it("tells that the server shows one language", function()
		local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
			cfg.i18n.force = "ru"
			return cfg
		end } })
		server:Boot()
		local client = Env.Join(server, { name = "Gordon", language = "en" })
		local menu = client:Get("NC").Modules:Instance("menu")
		menu:Open("settings")
		expect(#panels(client, "ncLanguage")):toBe(0)
		local found = World.FindPanels(client, function(panel)
			return panel.class == "DLabel" and panel:GetText() == "Сервер показывает всем один язык: Русский"
		end)
		expect(#found):toBe(1)
		expect(client:Errors()):toEqual({})
	end)

	it("helps with the keys of the modules and the commands of the player", function()
		local server = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		settle(server, client)
		local menu = client:Get("NC").Modules:Instance("menu")
		menu:Open("help")
		local keys = rows(client, "ncHelp")
		expect(keys[1]):toEqual({ "F1", "This menu: the profile, the settings and the help" })
		expect(keys[2]):toEqual({ "F2", "The menu of the door you look at: buy, sell, keys, sign" })
		-- The keys, then the chat.
		expect(texts(keys)):toEqual({ "F1", "F2", "F3", "C", "E", "ALT + E", "E", "MOUSE2", "R", "E + R", "R", "MOUSE2",
			"SPACE", "not bound", "R", "not bound", "not bound", "not bound", "MOUSE1 + MOUSE2", "SPACE", "/w", "/y",
			"/me", "/it", "//", ".//", "/pm", "/r", "/..." })
		expect(keys[16]):toEqual({ "not bound", "Talk (your voice: normal)" })
		expect(keys[21]):toEqual({ "/w", "whisper: heard only right next to you" })
		expect(#World.FindPanels(client, function(panel)
			return panel.class == "DLabel" and panel:GetText() == "Chat — type it in the chat box (Y)"
		end)):toBe(1)
		local ids = {}
		for i, key in ipairs(menu:Keys()) do
			ids[i] = key.id
		end
		expect(ids):toEqual({ "menu", "doors.menu", "medical.examine", "inventory.screen", "inventory.use",
			"doors.lock", "restraints.tie", "weapons.aim", "weapons.reload", "weapons.mode", "hands.raise",
			"hands.carry", "ragdoll.up", "ragdoll.fall", "hud.succumb", "voice.talk", "voice.radio", "voice.mode",
			"spectator.next", "spectator.camera" })
		-- The commands come from the server: asked once, the tab shows them when they arrive.
		expect(menu:Commands()):toBeNil()
		expect(#client:Sent("nc.menu.ask")):toBe(1)
		menu:Refresh(true)
		expect(#client:Sent("nc.menu.ask")):toBe(1)
		settle(server, client)
		local commands = menu:Commands()
		expect(commands ~= nil):toBe(true)
		local names = {}
		for _, command in ipairs(commands) do
			names[command.name] = command
		end
		expect(names.nc_profile.help):toBe("[player | steamid64] — your profile: visits, time and statistics")
		expect(names.nc_profile.admin):toBe(false)
		expect(names.nc_fall ~= nil):toBe(true) -- a command of the client
		expect(names.nc_round):toBeNil()
		expect(texts(rows(client, "ncCommand"))):toContain("nc_profile")
		expect(#World.FindPanels(client, function(panel)
			return panel.class == "DLabel" and panel:GetText() == "Admin commands"
		end)):toBe(0)

		-- A superadmin: the admin commands apart, asked again when the privileges change.
		gordon:SetUserGroup("superadmin")
		server:Get("NC").Permissions:Refresh(gordon)
		settle(server, client)
		settle(server, client)
		commands = menu:Commands()
		names = {}
		for _, command in ipairs(commands) do
			names[command.name] = command
		end
		expect(names.nc_round.admin):toBe(true)
		expect(names.nc_round.help):toBe("round status; restart, end, next <mode>, param <mode> <name> [value]")
		expect(texts(rows(client, "ncCommand"))):toContain("nc_round")
		expect(#World.FindPanels(client, function(panel)
			return panel.class == "DLabel" and panel:GetText() == "Admin commands"
		end)):toBe(1)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("takes tabs and help entries of modules: order, visibility, stamps, entries, failures", function()
		local server = boot({ modules = { "menu" } })
		local client = Env.Join(server, { name = "Gordon", language = "en" })
		local menu = client:Get("NC").Modules:Instance("menu")
		local shown, count, builds = true, 1, 0
		menu:AddTab("probe", { title = function() return "Probe" end, order = 50,
			visible = function() return shown end,
			stamp = function() return count end,
			build = function(panel, kit)
				builds = builds + 1
				kit:Label(panel, "count " .. count).ncProbe = true
				local row = kit:Row(panel)
				kit:Caption(row, "Name")
				kit:Entry(row, "name", "Alyx")
			end })
		menu:AddTab("broken", { title = "menu.tab.help", order = 60, build = function() error("boom") end })
		menu:AddHelp("probe.walk", { bind = { "+walk", "+use" }, fallback = { "alt", "e" }, text = "menu.key",
			order = 20 })
		menu:AddHelp("probe.fall", { bind = "nc_fall", text = "menu.key", order = 30,
			visible = function() return shown end })
		menu:Open()
		expect(fields(client, "ncTab")):toEqual({ "probe", "broken", "settings", "help" })
		expect(menu:Tab()):toBe("probe")
		expect(panels(client, "ncTab", "probe")[1]:GetText()):toBe("Probe")
		expect(panels(client, "ncProbe")[1]:GetText()):toBe("count 1")

		-- What was typed stays while the tab is built again; not built while typing.
		local entry = panels(client, "ncEntry", "name")[1]
		expect(entry:GetValue()):toBe("Alyx")
		expect(menu:Text("name")):toBe("Alyx")
		entry:SetValue("Eli")
		count = 2
		entry.HasFocus = function() return true end
		menu:Refresh(false)
		expect(builds):toBe(1)
		entry.HasFocus = nil
		menu:Refresh(false)
		expect(builds):toBe(2)
		expect(panels(client, "ncProbe")[1]:GetText()):toBe("count 2")
		expect(panels(client, "ncEntry", "name")[1]:GetValue()):toBe("Eli")
		menu:Refresh(false)
		expect(builds):toBe(2)

		-- A failing tab says so and logs once; the menu keeps working.
		click(client, "ncTab", "broken")
		expect(#World.FindPanels(client, function(panel)
			return panel.class == "DLabel" and panel:GetText() == "This tab failed to open, see the console"
		end)):toBe(1)
		click(client, "ncTab", "broken")
		expect(#client:Lines("build of 'broken' failed")):toBe(1)

		-- Keys: the binds of the player, the fallbacks, unbound ones.
		click(client, "ncTab", "help")
		expect(rows(client, "ncHelp")):toEqual({
			{ "F1", "This menu: the profile, the settings and the help" },
			{ "ALT + E", "This menu: the profile, the settings and the help" },
			{ "not bound", "This menu: the profile, the settings and the help" },
		})
		client.bindings["+use"], client.bindings.nc_fall, client.bindings.gm_showhelp = "f", "g", "f2"
		menu:Refresh(false)
		expect(texts(rows(client, "ncHelp"))):toEqual({ "F2", "ALT + F", "G" })

		-- A tab and a key that go away; the open tab falls back to the first one.
		menu:ShowTab("probe")
		shown = false
		menu:Refresh(false)
		expect(fields(client, "ncTab")):toEqual({ "broken", "settings", "help" })
		expect(menu:Tab()):toBe("broken")
		expect(#menu:Keys()):toBe(2)
		menu:RemoveTab("broken")
		menu:RemoveHelp("probe.walk")
		menu:Refresh(false)
		expect(fields(client, "ncTab")):toEqual({ "settings", "help" })
		expect(#menu:Keys()):toBe(1)

		-- Bad specs are errors of the module that adds them.
		expect(pcall(menu.AddTab, menu, "x", { title = "a" })):toBe(false)
		expect(pcall(menu.AddTab, menu, "x", { title = 1, build = print })):toBe(false)
		expect(pcall(menu.AddTab, menu, "", { title = "a", build = print })):toBe(false)
		expect(pcall(menu.AddTab, menu, "x", { title = "a", build = print, colour = 1 })):toBe(false)
		expect(pcall(menu.AddHelp, menu, "x", { bind = "+use" })):toBe(false)
		expect(pcall(menu.AddHelp, menu, "x", { text = "a", order = "1" })):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("starts on the tab of the settings and survives autorefresh", function()
		local server = boot({ settings = { tab = "help" } })
		local client = Env.Join(server, { name = "Gordon", language = "en" })
		local menu = client:Get("NC").Modules:Instance("menu")
		menu:Open()
		expect(menu:Tab()):toBe("help")
		client:Run(Env.ENTRY.client)
		client:Call("OnReloaded")
		Env.Flush(server, client)
		local again = client:Get("NC").Modules:Instance("menu")
		expect(again:IsOpen()):toBe(false)
		expect(Env.BindPress(client, "gm_showhelp")):toBe(true)
		expect(fields(client, "ncTab")):toEqual({ "profile", "character", "appearance", "settings", "help" })
		expect(client:Errors()):toEqual({})
	end)
end)
