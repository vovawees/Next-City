-- Menu, the client: the frame (F1, gm_showhelp), the tabs of modules and the building
-- blocks they are made of. An open menu looks twice a second whether the tabs or what the
-- open one shows changed (its stamp) and builds it again then, not while the player types
-- in it; what he typed stays. The tabs of the menu itself: the settings and the help
-- (cl_tabs.lua).
--
--   menu:AddTab(id, spec)   spec: title (lang key or function -> text), build (function(panel,
--                           menu): fills the panel of the tab), order (default 100), visible
--                           (function -> bool), stamp (function -> string | number: the tab
--                           is built again when it changes)
--   menu:RemoveTab(id), menu:Tabs() -> the ids of the tabs this player sees, in order
--   menu:AddHelp(id, spec)  a key on the help tab; spec: text (lang key), params (table or
--                           function -> table), bind (a bind or a list of them: "+walk",
--                           "+use"), fallback (the key or keys when the player has no such
--                           bind), label (the text of the key as it is: "/w"), section
--                           ("keys" by default, "chat": the chat of the help), order
--                           (default 100), visible (function -> bool)
--   menu:RemoveHelp(id), menu:Keys(section) -> { { id, key, text } } of a section of the help
--                           tab (default "keys"), in order
--   menu:Open(tab) -> the frame, menu:Close(), menu:Toggle(), menu:IsOpen(), menu:Tab()
--   menu:ShowTab(tab), menu:Refresh(force) (builds the open tab again when it changed)
--   menu:Key()              -> the key of the menu as the player has it ("F1")
--   menu:Commands()         -> the console commands this player may run, { name, module,
--                              help (translated), admin } by name; nil until the server
--                              answers (menu:AskCommands asks)
--
-- Building blocks of tabs (the look of the menu): menu:Heading(parent, text),
-- menu:Label(parent, text, color, font), menu:Row(parent, tall), menu:Caption(row, text,
-- wide), menu:Value(row, text, color), menu:Button(parent, text, fn, wide, dock),
-- menu:Entry(parent, id, default) (keeps what was typed while the tab is built again),
-- menu:Text(id) (what an entry holds), menu:Typing(); menu.COLORS, menu.FONTS.
--
-- Listens: gm.PlayerBindPress (gm_showhelp), i18n.changed, permissions.changed.

local M = NC.Module("menu")

local CurTime = CurTime
local IsValid = IsValid
local LocalPlayer = LocalPlayer
local ScrW = ScrW
local ScrH = ScrH
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local xpcall = xpcall
local error = error
local format = string.format
local upper = string.upper
local concat = table.concat
local sort = table.sort
local min = math.min
local traceback = debug.traceback

local BIND = "gm_showhelp"
local CHECK = 0.5    -- s between the looks of an open menu
local ASK_AGAIN = 5  -- s before the commands are asked for again without an answer
local WIDTH, HEIGHT = 820, 600
local ROW = 34
local TAB_WIDE = 140
local CAPTION_WIDE = 180

local FONTS = { normal = "NC.Menu", small = "NC.MenuSmall", title = "NC.MenuTitle", heading = "NC.MenuHeading" }
local COLORS = {
	white = Color(235, 235, 235),
	dim = Color(160, 160, 160),
	gold = Color(235, 190, 80),
	red = Color(230, 90, 70),
	green = Color(120, 210, 120),
	back = Color(18, 20, 24, 240),
	row = Color(255, 255, 255, 8),
	button = Color(255, 255, 255, 16),
	hover = Color(255, 255, 255, 36),
	active = Color(70, 120, 235, 150),
}
M.FONTS, M.COLORS = FONTS, COLORS

surface.CreateFont(FONTS.normal, { font = "Roboto", size = 18, weight = 500, extended = true })
surface.CreateFont(FONTS.small, { font = "Roboto", size = 15, weight = 400, extended = true })
surface.CreateFont(FONTS.title, { font = "Roboto", size = 24, weight = 700, extended = true })
surface.CreateFont(FONTS.heading, { font = "Roboto", size = 20, weight = 700, extended = true })

local TAB_KEYS = { title = true, build = true, order = true, visible = true, stamp = true }
local HELP_KEYS = { text = true, params = true, bind = true, fallback = true, label = true, section = true,
	order = true, visible = true }
local SECTIONS = { keys = true, chat = true }

function M:Init(ctx)
	self.tabs = {}      -- id -> { id, title, build, order, visible, stamp }
	self.help = {}      -- id -> { id, text, params, bind, fallback, order, visible }
	self.view = nil     -- { frame, title, bar, body, tab, tabList, stamp, checked, entries, values }
	self.lastTab = ctx.config.tab ~= "" and ctx.config.tab or nil
	self.commands = nil -- the list of the server and the client commands (help untranslated), or nil
	self.commandsVersion = 0
	self.asked = nil    -- CurTime of the last ask without an answer
	self.failed = {}    -- "<owner>:<what>" -> true: the error is logged once
	ctx:On("gm.PlayerBindPress", "OnBind")
	ctx:On("i18n.changed", "OnLanguage")
	ctx:On("permissions.changed", "OnGrants")
	ctx.net:Receive("commands", "OnCommands")
	self:_AddOwnTabs()
end

function M:Stop()
	self:Close()
end

-- Calls a function of a tab or a help entry; an error is logged once and gives nil.
function M:_Run(owner, what, fn, ...)
	local ok, result = xpcall(fn, traceback, ...)
	if ok then
		return result
	end
	local key = owner .. ":" .. what
	if not self.failed[key] then
		self.failed[key] = true
		self.ctx.log:Error("%s of '%s' failed: %s", what, owner, tostring(result))
	end
	return nil
end

local function checkSpec(kind, id, spec, keys)
	if type(id) ~= "string" or id == "" then
		error(format("menu: the id of a %s must be a non-empty string", kind), 3)
	end
	if type(spec) ~= "table" then
		error(format("menu: %s '%s' needs a spec table", kind, id), 3)
	end
	for key in pairs(spec) do
		if not keys[key] then
			error(format("menu: %s '%s' has an unknown key '%s'", kind, id, tostring(key)), 3)
		end
	end
	if spec.order ~= nil and type(spec.order) ~= "number" then
		error(format("menu: the order of %s '%s' must be a number", kind, id), 3)
	end
	if spec.visible ~= nil and type(spec.visible) ~= "function" then
		error(format("menu: visible of %s '%s' must be a function", kind, id), 3)
	end
end

local function byOrder(a, b)
	if a.order ~= b.order then
		return a.order < b.order
	end
	return a.id < b.id
end

-- Tabs ------------------------------------------------------------------------------------

function M:AddTab(id, spec)
	checkSpec("tab", id, spec, TAB_KEYS)
	if type(spec.build) ~= "function" then
		error(format("menu: tab '%s' needs a build function", id), 2)
	end
	if type(spec.title) ~= "string" and type(spec.title) ~= "function" then
		error(format("menu: the title of tab '%s' must be a lang key or a function", id), 2)
	end
	if spec.stamp ~= nil and type(spec.stamp) ~= "function" then
		error(format("menu: the stamp of tab '%s' must be a function", id), 2)
	end
	self.tabs[id] = { id = id, title = spec.title, build = spec.build, order = spec.order or 100,
		visible = spec.visible, stamp = spec.stamp }
end

function M:RemoveTab(id)
	self.tabs[id] = nil
end

function M:Tabs()
	local list = {}
	for id, tab in pairs(self.tabs) do
		if tab.visible == nil or self:_Run(id, "visible", tab.visible) then
			list[#list + 1] = tab
		end
	end
	sort(list, byOrder)
	local ids = {}
	for i, tab in ipairs(list) do
		ids[i] = tab.id
	end
	return ids
end

function M:_TabTitle(id)
	local tab = self.tabs[id]
	if type(tab.title) == "function" then
		return tostring(self:_Run(id, "title", tab.title) or id)
	end
	return self.ctx.i18n:T(tab.title)
end

-- Help on keys ----------------------------------------------------------------------------

local function listOf(value)
	if value == nil or type(value) == "table" then
		return value or {}
	end
	return { value }
end

function M:AddHelp(id, spec)
	checkSpec("help entry", id, spec, HELP_KEYS)
	if type(spec.text) ~= "string" then
		error(format("menu: help entry '%s' needs a text (a lang key)", id), 2)
	end
	if spec.section ~= nil and not SECTIONS[spec.section] then
		error(format("menu: help entry '%s': section must be \"keys\" or \"chat\"", id), 2)
	end
	if spec.label ~= nil and type(spec.label) ~= "string" then
		error(format("menu: help entry '%s': label must be a string", id), 2)
	end
	self.help[id] = { id = id, text = spec.text, params = spec.params, binds = listOf(spec.bind),
		fallbacks = listOf(spec.fallback), label = spec.label, section = spec.section or "keys",
		order = spec.order or 100, visible = spec.visible }
end

function M:RemoveHelp(id)
	self.help[id] = nil
end

-- The key of an entry as the player has it: "F2", "ALT + E"; unbound without a fallback.
function M:_KeyText(entry)
	if entry.label ~= nil then
		return entry.label
	end
	local parts = {}
	for i, bind in ipairs(entry.binds) do
		local key = input.LookupBinding(bind) or entry.fallbacks[i]
		if key == nil then
			return self.ctx.i18n:T("menu.help.unbound")
		end
		parts[#parts + 1] = upper(key)
	end
	if #parts == 0 then
		return entry.fallbacks[1] ~= nil and upper(entry.fallbacks[1]) or ""
	end
	return concat(parts, " + ")
end

function M:Keys(section)
	section = section or "keys"
	local list = {}
	for id, entry in pairs(self.help) do
		if entry.section == section and (entry.visible == nil or self:_Run(id, "visible", entry.visible)) then
			list[#list + 1] = entry
		end
	end
	sort(list, byOrder)
	local out = {}
	for i, entry in ipairs(list) do
		local params = entry.params
		if type(params) == "function" then
			params = self:_Run(entry.id, "params", params)
		end
		out[i] = { id = entry.id, key = self:_KeyText(entry), text = self.ctx.i18n:T(entry.text, params) }
	end
	return out
end

function M:Key()
	return upper(input.LookupBinding(BIND) or "f1")
end

-- Commands --------------------------------------------------------------------------------

function M:Commands()
	if self.commands == nil then
		return nil
	end
	local out = {}
	for i, command in ipairs(self.commands) do
		out[i] = { name = command.name, module = command.module, help = self:_CommandHelp(command),
			admin = command.admin }
	end
	return out
end

-- Asks the server for the commands of the player (once in ASK_AGAIN s without an answer).
function M:AskCommands()
	local now = CurTime()
	if self.asked ~= nil and now - self.asked < ASK_AGAIN then
		return
	end
	self.asked = now
	self.ctx.net:SendToServer("ask", {})
end

-- The help line of a command: <module>.command.<name> when the module translates it.
function M:_CommandHelp(command)
	local i18n = self.ctx.i18n
	local key = command.module .. ".command." .. command.name
	if i18n:Has(key) then
		return i18n:T(key)
	end
	return command.help
end

function M:OnCommands(msg)
	local list, seen = {}, {}
	for _, command in ipairs(msg.list) do
		seen[command.name] = true
		list[#list + 1] = { name = command.name, module = command.module, help = command.help,
			admin = command.admin }
	end
	-- Commands of the client run here and are for everybody; key commands (+name, -name)
	-- belong to the keys.
	for _, command in ipairs(self.ctx.commands:List()) do
		if not seen[command.name] and not command.name:find("^[%+%-]") then
			list[#list + 1] = { name = command.name, module = command.module, help = command.help or "",
				admin = false }
		end
	end
	sort(list, function(a, b) return a.name < b.name end)
	self.commands, self.asked = list, nil
	self.commandsVersion = self.commandsVersion + 1
	self:Refresh(false)
end

-- The privileges changed: the commands are asked for again when the help tab needs them.
function M:OnGrants()
	self.commands, self.asked = nil, nil
	self.commandsVersion = self.commandsVersion + 1
	self:Refresh(false)
end

function M:OnLanguage()
	if self:IsOpen() then
		self:ShowTab(self.view.tab)
	end
end

-- Opening and closing ---------------------------------------------------------------------

function M:IsOpen()
	return self.view ~= nil and IsValid(self.view.frame)
end

function M:Tab()
	return self:IsOpen() and self.view.tab or nil
end

function M:Open(tab)
	if not IsValid(LocalPlayer()) then
		return nil
	end
	if not self:IsOpen() then
		self:_BuildFrame()
	end
	self:ShowTab(tab or self.lastTab)
	return self.view.frame
end

function M:Close()
	local view = self.view
	self.view = nil
	if view ~= nil and IsValid(view.frame) then
		view.frame:Remove()
	end
end

function M:Toggle()
	if self:IsOpen() then
		self:Close()
	else
		self:Open()
	end
end

-- F1 opens the menu, F1 in the open menu closes it (OnKeyCodePressed).
function M:OnBind(_, bind, pressed)
	if not pressed or bind ~= BIND then
		return nil
	end
	self:Toggle()
	return true
end

local function paintFrame(_, w, h)
	draw.RoundedBox(6, 0, 0, w, h, COLORS.back)
end

function M:_BuildFrame()
	local frame = vgui.Create("DFrame")
	frame:SetSize(min(WIDTH, ScrW() - 40), min(HEIGHT, ScrH() - 40))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(true)
	frame:SetDraggable(true)
	frame:DockPadding(14, 8, 14, 14)
	frame:MakePopup()
	frame.Paint = paintFrame
	frame.ncMenu = true
	local view = { frame = frame, entries = {}, values = {}, checked = CurTime() + CHECK }
	self.view = view
	frame.OnRemove = function()
		if self.view == view then
			self.view = nil
		end
	end
	frame.OnKeyCodePressed = function(_, code)
		if input.LookupKeyBinding(code) == BIND then
			self:Close()
		end
	end
	local think = frame.Think
	frame.Think = function(panel)
		think(panel)
		if CurTime() >= view.checked then
			view.checked = CurTime() + CHECK
			self:Refresh(false)
		end
	end
	view.title = self:Label(frame, "", COLORS.white, FONTS.title)
	view.title:SetTall(30)
	view.bar = frame:Add("DPanel")
	view.bar:Dock(TOP)
	view.bar:DockMargin(0, 4, 0, 10)
	view.bar:SetTall(ROW)
	view.bar:SetPaintBackground(false)
	view.body = frame:Add("DScrollPanel")
	view.body:Dock(FILL)
	return view
end

local function has(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

-- Shows a tab (the first one when this player does not see `tab`).
function M:ShowTab(tab)
	local view = self.view
	if view == nil then
		return
	end
	local tabs = self:Tabs()
	if not has(tabs, tab) then
		tab = tabs[1]
	end
	view.tab, view.tabList = tab, concat(tabs, " ")
	self.lastTab = tab
	view.title:SetText(self.ctx.i18n:T("menu.title", { key = self:Key() }))
	view.bar:Clear()
	for _, id in ipairs(tabs) do
		local button = self:Button(view.bar, self:_TabTitle(id), function()
			self:ShowTab(id)
		end, TAB_WIDE, LEFT)
		button:DockMargin(0, 0, 6, 0)
		button.ncTab, button.ncActive = id, id == tab
	end
	self:_BuildBody()
end

-- Builds the open tab again (keeping what the player typed).
function M:_BuildBody()
	local view = self.view
	for id, entry in pairs(view.entries) do
		if IsValid(entry) then
			local value = tostring(entry:GetValue() or "")
			view.values[id] = value ~= entry.ncDefault and value or nil
		end
	end
	view.entries = {}
	view.body:Clear()
	local tab = view.tab ~= nil and self.tabs[view.tab] or nil
	if tab == nil then
		view.stamp = nil
		return
	end
	local ok = self:_Run(tab.id, "build", function()
		tab.build(view.body, self)
		return true
	end)
	if not ok then
		self:Label(view.body, self.ctx.i18n:T("menu.failed"), COLORS.red)
	end
	view.stamp = tab.stamp ~= nil and self:_Run(tab.id, "stamp", tab.stamp) or nil
end

function M:Refresh(force)
	local view = self.view
	if view == nil then
		return
	end
	if not IsValid(view.frame) then
		self.view = nil
		return
	end
	if force or concat(self:Tabs(), " ") ~= view.tabList then
		self:ShowTab(view.tab)
		return
	end
	if self:Typing() then
		return
	end
	local tab = self.tabs[view.tab]
	if tab ~= nil and tab.stamp ~= nil and self:_Run(tab.id, "stamp", tab.stamp) ~= view.stamp then
		self:_BuildBody()
	end
end

-- Building blocks -------------------------------------------------------------------------

local function paintButton(panel, w, h)
	local color = panel.ncActive and COLORS.active or panel:IsHovered() and COLORS.hover or COLORS.button
	draw.RoundedBox(4, 0, 0, w, h, color)
end

local function paintRow(_, w, h)
	draw.RoundedBox(4, 0, 0, w, h, COLORS.row)
end

-- A line of text at the top of `parent` (wraps when long).
function M:Label(parent, text, color, font)
	local panel = parent:Add("DLabel")
	panel:Dock(TOP)
	panel:SetFont(font or FONTS.normal)
	panel:SetTextColor(color or COLORS.white)
	panel:SetText(text)
	panel:SetWrap(true)
	panel:SetAutoStretchVertical(true)
	panel:SetMouseInputEnabled(false)
	return panel
end

-- The title of a part of a tab.
function M:Heading(parent, text)
	local panel = self:Label(parent, text, COLORS.gold, FONTS.heading)
	panel:DockMargin(0, 10, 0, 6)
	return panel
end

-- A row with the look of the menu (captions and values go into it).
function M:Row(parent, tall)
	local panel = parent:Add("DPanel")
	panel:Dock(TOP)
	panel:DockMargin(0, 0, 0, 4)
	panel:SetTall(tall or ROW)
	panel.Paint = paintRow
	return panel
end

-- A caption at the left of a row.
function M:Caption(row, text, wide)
	local panel = row:Add("DLabel")
	panel:Dock(LEFT)
	panel:SetWide(wide or CAPTION_WIDE)
	panel:DockMargin(10, 0, 0, 0)
	panel:SetFont(FONTS.normal)
	panel:SetTextColor(COLORS.dim)
	panel:SetText(text)
	panel:SetMouseInputEnabled(false)
	return panel
end

-- The value that fills the rest of a row.
function M:Value(row, text, color)
	local panel = row:Add("DLabel")
	panel:Dock(FILL)
	panel:DockMargin(6, 0, 6, 0)
	panel:SetFont(FONTS.normal)
	panel:SetTextColor(color or COLORS.white)
	panel:SetText(text)
	panel:SetMouseInputEnabled(false)
	return panel
end

function M:Button(parent, text, fn, wide, dock)
	local panel = parent:Add("DButton")
	panel:Dock(dock or LEFT)
	panel:SetWide(wide or TAB_WIDE)
	panel:SetFont(FONTS.normal)
	panel:SetTextColor(COLORS.white)
	panel:SetText(text)
	panel.Paint = paintButton
	panel.DoClick = fn
	return panel
end

-- A text entry that fills the rest of a row; what the player typed in it stays while the
-- tab is built again (by `id`).
function M:Entry(parent, id, default)
	local view = self.view
	local entry = parent:Add("DTextEntry")
	entry:Dock(FILL)
	entry:DockMargin(0, 4, 6, 4)
	entry:SetFont(FONTS.normal)
	entry.ncEntry, entry.ncDefault = id, default or ""
	local value = view ~= nil and view.values[id] or nil
	entry:SetValue(value ~= nil and value or entry.ncDefault)
	if view ~= nil then
		view.entries[id] = entry
	end
	return entry
end

-- What the entry `id` of the open tab holds ("" without one).
function M:Text(id)
	local entry = self.view ~= nil and self.view.entries[id] or nil
	if entry == nil or not IsValid(entry) then
		return ""
	end
	return tostring(entry:GetValue() or "")
end

-- Whether the player types in an entry of the open tab.
function M:Typing()
	if self.view == nil then
		return false
	end
	for _, entry in pairs(self.view.entries) do
		if IsValid(entry) and entry:HasFocus() then
			return true
		end
	end
	return false
end
