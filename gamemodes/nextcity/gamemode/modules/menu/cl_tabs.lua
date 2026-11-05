-- Menu, the tabs of the menu itself: the settings (the language of the texts) and the
-- help (the keys and the chat modules add with AddHelp and the console commands of the
-- player, the admin ones apart). The key of the menu is the first help entry.

local M = NC.Module("menu")

local ipairs = ipairs
local concat = table.concat

local SETTINGS_ORDER = 900
local HELP_ORDER = 1000

function M:_AddOwnTabs()
	local i18n = self.ctx.i18n
	self:AddTab("settings", { title = "menu.tab.settings", order = SETTINGS_ORDER,
		build = function(panel) self:_BuildSettings(panel) end,
		stamp = function() return i18n:Choice() .. " " .. i18n:Language() end })
	self:AddTab("help", { title = "menu.tab.help", order = HELP_ORDER,
		build = function(panel) self:_BuildHelp(panel) end,
		stamp = function() return self:_HelpStamp() end })
	self:AddHelp("menu", { bind = "gm_showhelp", fallback = "f1", text = "menu.key", order = 10 })
end

-- Settings ---------------------------------------------------------------------------------

-- The choice of the player: "auto" (the game language) or a code; saved in nc_language.
function M:SetLanguage(code)
	local i18n = self.ctx.i18n
	local language = i18n:SetLanguage(code)
	self:Refresh(false)
	return language
end

function M:_BuildSettings(panel)
	local i18n = self.ctx.i18n
	self:Heading(panel, i18n:T("menu.settings.language"))
	local forced = i18n:Forced()
	local languages = i18n:Languages()
	if forced ~= nil then
		local name = forced
		for _, lang in ipairs(languages) do
			if lang.code == forced then
				name = lang.name
			end
		end
		self:Label(panel, i18n:T("menu.settings.forced", { language = name }), self.COLORS.dim)
		return
	end
	local choice = i18n:Choice()
	local function add(code, text)
		local row = self:Row(panel)
		local button = self:Button(row, text, function()
			self:SetLanguage(code)
		end, nil, FILL)
		button.ncLanguage, button.ncActive = code, code == choice
	end
	add("auto", i18n:T("menu.settings.auto"))
	for _, lang in ipairs(languages) do
		add(lang.code, lang.name ~= lang.english and lang.name .. " · " .. lang.english or lang.name)
	end
	self:Label(panel, i18n:T("menu.settings.console"), self.COLORS.dim, self.FONTS.small)
end

-- Help -------------------------------------------------------------------------------------

function M:_HelpStamp()
	local parts = { self.commandsVersion }
	for _, section in ipairs({ "keys", "chat" }) do
		for _, key in ipairs(self:Keys(section)) do
			parts[#parts + 1] = key.id .. "=" .. key.key
		end
	end
	return concat(parts, " ")
end

function M:_HelpRows(panel, keys)
	for _, key in ipairs(keys) do
		local row = self:Row(panel)
		row.ncHelp = key.id
		local caption = self:Caption(row, key.key)
		caption:SetTextColor(self.COLORS.gold)
		caption.ncKey = key.key
		self:Value(row, key.text).ncText = key.text
	end
end

function M:_BuildHelp(panel)
	local i18n = self.ctx.i18n
	self:Heading(panel, i18n:T("menu.help.keys"))
	self:_HelpRows(panel, self:Keys())
	local chat = self:Keys("chat")
	if chat[1] ~= nil then
		self:Heading(panel, i18n:T("menu.help.chat"))
		self:_HelpRows(panel, chat)
	end
	self:Heading(panel, i18n:T("menu.help.commands"))
	local commands = self:Commands()
	if commands == nil then
		self:AskCommands()
		self:Label(panel, i18n:T("menu.help.loading"), self.COLORS.dim)
		return
	end
	local admin = {}
	for _, command in ipairs(commands) do
		if command.admin then
			admin[#admin + 1] = command
		else
			self:_CommandRow(panel, command)
		end
	end
	if #admin > 0 then
		self:Heading(panel, i18n:T("menu.help.admin"))
		for _, command in ipairs(admin) do
			self:_CommandRow(panel, command)
		end
	end
end

function M:_CommandRow(panel, command)
	local row = self:Row(panel)
	row.ncCommand = command.name
	self:Caption(row, command.name):SetTextColor(command.admin and self.COLORS.red or self.COLORS.white)
	local value = self:Value(row, command.help, self.COLORS.dim)
	value:SetFont(self.FONTS.small)
	value.ncText = command.help
end
