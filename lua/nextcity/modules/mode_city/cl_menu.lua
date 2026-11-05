-- City, the menu (F4, gm_showspare2): the jobs (take one, go by a name), the shop of the
-- job, the bank (the account and the cash in the pockets) and, for those who keep the law,
-- the police (want, warrant, release). An open menu looks twice a second whether what it
-- shows changed and builds the tab again then (not while the player types in it); what he
-- typed stays.
--
--   city:OpenMenu(tab)      -> the frame; tab: "jobs", "shop", "bank", "police" (default:
--                              the last one)
--   city:CloseMenu(), city:ToggleMenu(), city:IsMenuOpen(), city:MenuTab() -> the open tab
--   city:MenuTabs()         -> the tabs this player sees (the police: officers, the mayor)
--   city:MayWarrant()       -> whether this player may issue warrants (the mayor; officers
--                              while the city has none)
--   city:RefreshMenu(force) -> builds the open tab again when it changed (force: anyway)

local M = NC.Module("mode_city")

local CurTime = CurTime
local IsValid = IsValid
local ScrW = ScrW
local ScrH = ScrH
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local concat = table.concat
local sort = table.sort
local min = math.min
local upper = string.upper

local FONT = "NC.City.Menu"
local FONT_SMALL = "NC.City.MenuSmall"
local FONT_TITLE = "NC.City.MenuTitle"
local WHITE = Color(235, 235, 235)
local DIM = Color(160, 160, 160)
local GOLD = Color(235, 190, 80)
local RED = Color(230, 90, 70)
local BACK = Color(18, 20, 24, 240)
local ROW_BACK = Color(255, 255, 255, 8)
local BUTTON_BACK = Color(255, 255, 255, 16)
local BUTTON_HOVER = Color(255, 255, 255, 36)
local ACTIVE = Color(70, 120, 235, 150)
local WIDTH, HEIGHT = 780, 580
local ROW = 34
local JOB_ROW = 54
local CHECK = 0.5 -- s between the looks of an open menu
local BIND = "gm_showspare2"
local MANY = 5    -- the second button of an offer buys this many at once
local BANK = { "deposit", "withdraw", "give", "drop" }

surface.CreateFont(FONT, { font = "Roboto", size = 18, weight = 500, extended = true })
surface.CreateFont(FONT_SMALL, { font = "Roboto", size = 15, weight = 400, extended = true })
surface.CreateFont(FONT_TITLE, { font = "Roboto", size = 24, weight = 700, extended = true })

function M:_InitMenu()
	self.menu = nil -- { frame, title, bar, body, tab, tabList, stamp, checked, entries, values }
	self.lastTab = "jobs"
end

-- Painting --------------------------------------------------------------------------------

local function paintFrame(_, w, h)
	draw.RoundedBox(6, 0, 0, w, h, BACK)
end

local function paintButton(panel, w, h)
	draw.RoundedBox(4, 0, 0, w, h, panel.ncActive and ACTIVE or panel:IsHovered() and BUTTON_HOVER or BUTTON_BACK)
end

local function paintRow(_, w, h)
	draw.RoundedBox(4, 0, 0, w, h, ROW_BACK)
end

local function paintJob(panel, w, h)
	draw.RoundedBox(4, 0, 0, w, h, panel.ncMine and ACTIVE or panel:IsHovered() and BUTTON_HOVER or BUTTON_BACK)
	surface.SetDrawColor(panel.ncColor)
	surface.DrawRect(0, 0, 4, h)
end

-- Building blocks -------------------------------------------------------------------------

local function addLabel(parent, text, font, color, dock)
	local panel = parent:Add("DLabel")
	panel:Dock(dock or TOP)
	panel:SetFont(font or FONT)
	panel:SetTextColor(color or WHITE)
	panel:SetText(text)
	panel:SetMouseInputEnabled(false)
	return panel
end

local function addButton(parent, text, dock, wide, fn)
	local panel = parent:Add("DButton")
	panel:Dock(dock)
	panel:SetWide(wide)
	panel:SetFont(FONT)
	panel:SetTextColor(WHITE)
	panel:SetText(text)
	panel.Paint = paintButton
	panel.DoClick = fn
	return panel
end

local function addRow(parent, tall)
	local panel = parent:Add("DPanel")
	panel:Dock(TOP)
	panel:DockMargin(0, 0, 0, 4)
	panel:SetTall(tall or ROW)
	panel.Paint = paintRow
	return panel
end

-- A caption at the left of a row.
local function addCaption(parent, text)
	local panel = addLabel(parent, text, FONT, DIM, LEFT)
	panel:SetWide(170)
	panel:DockMargin(10, 0, 0, 0)
	return panel
end

-- An amount of money as typed ("1 000", "$250"): the digits, or 0.
local function amountOf(text)
	local digits = tostring(text or ""):gsub("%D", "")
	return tonumber(digits) or 0
end

local function has(list, value)
	for _, item in ipairs(list) do
		if item == value then
			return true
		end
	end
	return false
end

-- A text entry that fills the rest of a row; what the player typed in it stays while the
-- tab is built again (by `id`).
function M:_Entry(parent, id, default)
	local menu = self.menu
	local entry = parent:Add("DTextEntry")
	entry:Dock(FILL)
	entry:DockMargin(0, 4, 6, 4)
	entry:SetFont(FONT)
	local value = menu.values[id]
	entry.ncEntry, entry.ncDefault = id, default or ""
	entry:SetValue(value ~= nil and value or entry.ncDefault)
	menu.entries[id] = entry
	return entry
end

-- What the entry `id` of the open tab holds ("" without one).
function M:_Value(id)
	local entry = self.menu ~= nil and self.menu.entries[id] or nil
	if entry == nil or not IsValid(entry) then
		return ""
	end
	return tostring(entry:GetValue() or "")
end

-- Whether the player types in an entry of the open tab.
function M:_Typing()
	for _, entry in pairs(self.menu.entries) do
		if IsValid(entry) and entry:HasFocus() then
			return true
		end
	end
	return false
end

-- Opening and closing -------------------------------------------------------------------

function M:MenuTabs()
	local tabs = { "jobs" }
	if self.economy ~= nil and self.inventory ~= nil then
		tabs[#tabs + 1] = "shop"
	end
	if self.economy ~= nil then
		tabs[#tabs + 1] = "bank"
	end
	local me, law = LocalPlayer(), self.law
	if law ~= nil and (law:IsOfficer(me) or law:IsAuthority(me)) then
		tabs[#tabs + 1] = "police"
	end
	return tabs
end

function M:IsMenuOpen()
	return self.menu ~= nil and IsValid(self.menu.frame)
end

function M:MenuTab()
	return self:IsMenuOpen() and self.menu.tab or nil
end

function M:OpenMenu(tab)
	if not self:IsRunning() or not IsValid(LocalPlayer()) then
		return nil
	end
	if not self:IsMenuOpen() then
		self:_BuildFrame()
	end
	self:ShowTab(tab or self.lastTab)
	return self.menu.frame
end

function M:CloseMenu()
	local menu = self.menu
	self.menu = nil
	if menu ~= nil and IsValid(menu.frame) then
		menu.frame:Remove()
	end
end

function M:ToggleMenu()
	if self:IsMenuOpen() then
		self:CloseMenu()
	else
		self:OpenMenu()
	end
end

-- F4 opens the menu while the city runs; F4 in the open menu closes it (OnKeyCodePressed).
function M:OnBind(_, bind, pressed)
	if not pressed or bind ~= BIND or not self:IsRunning() then
		return nil
	end
	self:ToggleMenu()
	return true
end

-- The key that opens the menu, as the player has it ("F4").
function M:MenuKey()
	return upper(input.LookupBinding(BIND) or "f4")
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
	frame.ncCityMenu = true
	local menu = { frame = frame, entries = {}, values = {}, checked = CurTime() + CHECK }
	self.menu = menu
	frame.OnRemove = function()
		if self.menu == menu then
			self.menu = nil
		end
	end
	frame.OnKeyCodePressed = function(_, code)
		if input.LookupKeyBinding(code) == BIND then
			self:CloseMenu()
		end
	end
	local think = frame.Think
	frame.Think = function(panel)
		think(panel)
		if CurTime() >= menu.checked then
			menu.checked = CurTime() + CHECK
			self:RefreshMenu(false)
		end
	end
	menu.title = addLabel(frame, "", FONT_TITLE, WHITE)
	menu.title:SetTall(30)
	menu.bar = frame:Add("DPanel")
	menu.bar:Dock(TOP)
	menu.bar:DockMargin(0, 4, 0, 10)
	menu.bar:SetTall(ROW)
	menu.bar:SetPaintBackground(false)
	menu.body = frame:Add("DScrollPanel")
	menu.body:Dock(FILL)
	return menu
end

-- Shows a tab (the first one when this player does not see `tab`).
function M:ShowTab(tab)
	local menu = self.menu
	if menu == nil then
		return
	end
	local tabs = self:MenuTabs()
	if not has(tabs, tab) then
		tab = tabs[1]
	end
	menu.tab, menu.tabList = tab, concat(tabs, " ")
	self.lastTab = tab
	local i18n = self.ctx.i18n
	menu.title:SetText(i18n:T("mode_city.menu.title", { name = self.players:Name(LocalPlayer()) }))
	menu.bar:Clear()
	for _, id in ipairs(tabs) do
		local button = addButton(menu.bar, i18n:T("mode_city.menu.tab." .. id), LEFT, 150, function()
			self:ShowTab(id)
		end)
		button:DockMargin(0, 0, 6, 0)
		button.ncTab, button.ncActive = id, id == tab
	end
	self:_BuildBody()
end

local BUILD, STAMP = {}, {}

-- Builds the open tab again (keeping what the player typed).
function M:_BuildBody()
	local menu = self.menu
	for id, entry in pairs(menu.entries) do
		if IsValid(entry) then
			local value = tostring(entry:GetValue() or "")
			menu.values[id] = value ~= entry.ncDefault and value or nil
		end
	end
	menu.entries = {}
	menu.body:Clear()
	BUILD[menu.tab](self, menu.body)
	menu.stamp = STAMP[menu.tab](self)
end

function M:RefreshMenu(force)
	local menu = self.menu
	if menu == nil then
		return
	end
	if not IsValid(menu.frame) then
		self.menu = nil
		return
	end
	if not self:IsRunning() or not IsValid(LocalPlayer()) then
		self:CloseMenu()
		return
	end
	if force or concat(self:MenuTabs(), " ") ~= menu.tabList then
		self:ShowTab(menu.tab)
	elseif STAMP[menu.tab](self) ~= menu.stamp and not self:_Typing() then
		self:_BuildBody()
	end
end

-- The jobs ------------------------------------------------------------------------------

function STAMP.jobs(self)
	local me = LocalPlayer()
	local parts = { self.roles:Of(me) or "", self.players:Name(me) }
	for _, id in ipairs(self.jobOrder) do
		parts[#parts + 1] = self:Count(id)
	end
	return concat(parts, " ")
end

function BUILD.jobs(self, body)
	local me, i18n = LocalPlayer(), self.ctx.i18n
	local line = addRow(body, ROW + 6)
	addCaption(line, i18n:T("mode_city.menu.name"))
	local save = addButton(line, i18n:T("mode_city.menu.rename"), RIGHT, 160, nil)
	save:DockMargin(0, 4, 4, 4)
	save.ncAction = "name"
	local entry = self:_Entry(line, "name", self:CitizenName(me) or me:Nick())
	save.DoClick = function()
		self:AskName(entry:GetValue())
	end
	entry.OnEnter = save.DoClick
	local mine = self.roles:Of(me)
	for _, id in ipairs(self.jobOrder) do
		self:_JobRow(body, self.jobs[id], id == mine)
	end
end

function M:_JobRow(body, job, mine)
	local i18n = self.ctx.i18n
	local count, limit = self:Count(job.id), job.limit
	local full = limit > 0 and count >= limit and not mine
	local name = self:_Name(job.name, job.id)
	local button = body:Add("DButton")
	button:Dock(TOP)
	button:DockMargin(0, 0, 0, 4)
	button:SetTall(JOB_ROW)
	button:SetFont(FONT)
	button:SetTextColor(full and DIM or WHITE)
	button:SetContentAlignment(7)
	button:SetTextInset(16, 7)
	button:SetText(mine and i18n:T("mode_city.menu.mine", { job = name }) or name)
	if full then
		button:SetTooltip(i18n:T("mode_city.fail.limit", { job = name }))
	end
	button.Paint = paintJob
	button.ncJob, button.ncColor, button.ncMine, button.ncFull = job.id, job.color, mine, full
	button.DoClick = function()
		self:AskJob(job.id)
	end
	local note = addLabel(button, self:_Name(job.description, ""), FONT_SMALL, DIM, BOTTOM)
	note:SetTall(20)
	note:DockMargin(16, 0, 16, 6)
	local places = limit > 0 and count .. "/" .. limit or count .. "/∞"
	local info = addLabel(button, i18n:T("mode_city.menu.job", { salary = self:Money(job.salary), places = places }),
		FONT, full and RED or GOLD, RIGHT)
	info:SetWide(300)
	info:SetContentAlignment(9)
	info:DockMargin(0, 7, 16, 0)
	info.ncInfo = true
	return button
end

-- The shop ------------------------------------------------------------------------------

function STAMP.shop(self)
	local economy = self.economy
	return concat({ self.roles:Of(LocalPlayer()) or "", economy:Balance(), economy:Cash() }, " ")
end

-- The money of the player at the top of a tab.
function M:_MoneyLine(body)
	local economy = self.economy
	local text = self.ctx.i18n:T("mode_city.hud.money", { balance = self:Money(economy:Balance()),
		cash = self:Money(economy:Cash()) })
	local money = addLabel(body, text, FONT, GOLD)
	money:SetTall(26)
	money:DockMargin(4, 0, 0, 6)
	money.ncMoney = true
	return money
end

function BUILD.shop(self, body)
	local i18n, economy, inventory = self.ctx.i18n, self.economy, self.inventory
	self:_MoneyLine(body)
	local offers = self:OffersFor(LocalPlayer())
	if offers[1] == nil then
		addLabel(body, i18n:T("mode_city.menu.nothing"), FONT, DIM).ncNothing = true
		return
	end
	local wealth = economy:Balance() + economy:Cash()
	for _, offer in ipairs(offers) do
		local line = addRow(body)
		line.ncOffer = offer.id
		local many = addButton(line, "×" .. MANY, RIGHT, 56, function()
			self:AskBuy(offer.id, MANY)
		end)
		many:DockMargin(4, 3, 3, 3)
		many:SetTooltip(i18n:T("mode_city.menu.many", { count = MANY, price = self:Money(offer.price * MANY) }))
		many.ncOffer, many.ncTimes = offer.id, MANY
		local buy = addButton(line, i18n:T("mode_city.menu.buy"), RIGHT, 110, function()
			self:AskBuy(offer.id, 1)
		end)
		buy:DockMargin(4, 3, 0, 3)
		buy.ncOffer, buy.ncTimes = offer.id, 1
		local price = addLabel(line, self:Money(offer.price), FONT, offer.price <= wealth and GOLD or RED, RIGHT)
		price:SetWide(110)
		price:SetContentAlignment(6)
		price.ncPrice = true
		local item = addLabel(line, i18n:T("mode_city.menu.offer", { item = inventory:Name(offer.item),
			count = offer.count }), FONT, WHITE, FILL)
		item:DockMargin(12, 0, 0, 0)
		local description = inventory:Description(offer.item)
		if description ~= nil then
			item:SetTooltip(description)
		end
		item.ncItem = true
	end
end

-- The bank ------------------------------------------------------------------------------

function STAMP.bank(self)
	return concat({ self.economy:Balance(), self.economy:Cash() }, " ")
end

function BUILD.bank(self, body)
	local i18n, economy = self.ctx.i18n, self.economy
	local balance = addLabel(body, i18n:T("mode_city.menu.balance", { amount = self:Money(economy:Balance()) }),
		FONT_TITLE, GOLD)
	balance:SetTall(32)
	balance:DockMargin(4, 0, 0, 0)
	balance.ncBalance = true
	local cash = addLabel(body, i18n:T("mode_city.menu.cash", { amount = self:Money(economy:Cash()) }), FONT, WHITE)
	cash:SetTall(26)
	cash:DockMargin(4, 0, 0, 10)
	cash.ncCash = true
	local line = addRow(body, ROW + 6)
	addCaption(line, i18n:T("mode_city.menu.amount"))
	self:_Entry(line, "amount", "")
	local actions = addRow(body, ROW + 6)
	actions.Paint = nil
	actions:SetPaintBackground(false)
	for _, op in ipairs(BANK) do
		local button = addButton(actions, i18n:T("mode_city.menu." .. op), LEFT, 182, function()
			economy:Request(op, amountOf(self:_Value("amount")))
		end)
		button:DockMargin(0, 0, 6, 0)
		button.ncBank = op
	end
	local hint = addLabel(body, i18n:T("mode_city.menu.bank"), FONT_SMALL, DIM)
	hint:SetTall(40)
	hint:SetWrap(true)
	hint:DockMargin(4, 6, 4, 0)
end

-- The police ----------------------------------------------------------------------------

function M:MayWarrant()
	local law, me = self.law, LocalPlayer()
	if law == nil or law:IsAuthority(me) then
		return law ~= nil
	end
	if not law:IsOfficer(me) then
		return false
	end
	for _, ply in ipairs(player.GetAll()) do
		if law:IsAuthority(ply) then
			return false
		end
	end
	return true
end

function STAMP.police(self)
	local law = self.law
	local parts = { self:MayWarrant() and "w" or "-" }
	for _, ply in ipairs(player.GetAll()) do
		local wanted, warrant = law:Wanted(ply), law:WarrantOf(ply)
		parts[#parts + 1] = concat({ ply:EntIndex(), self.players:Name(ply), self.roles:Of(ply) or "",
			law:IsJailed(ply) and "j" or "-", wanted ~= nil and wanted.reason or "-",
			warrant ~= nil and warrant.reason or "-" }, ":")
	end
	return concat(parts, " ")
end

-- The others in the order of the police: the jailed, the wanted, with warrants, the rest,
-- by name.
function M:_Suspects()
	local law, me = self.law, LocalPlayer()
	local out, rank, name = {}, {}, {}
	for _, ply in ipairs(player.GetAll()) do
		if ply ~= me and IsValid(ply) then
			out[#out + 1] = ply
			rank[ply] = law:IsJailed(ply) and 1 or law:IsWanted(ply) and 2 or law:HasWarrant(ply) and 3 or 4
			name[ply] = self.players:Name(ply):lower()
		end
	end
	sort(out, function(a, b)
		if rank[a] ~= rank[b] then
			return rank[a] < rank[b]
		end
		if name[a] ~= name[b] then
			return name[a] < name[b]
		end
		return a:EntIndex() < b:EntIndex()
	end)
	return out
end

function M:_LawButton(parent, op, ply)
	local button = addButton(parent, self.ctx.i18n:T("mode_city.menu." .. op), RIGHT, 150, function()
		local reason = (op == "want" or op == "warrant") and self:_Value("reason") or nil
		self.law:Ask(op, ply, reason)
	end)
	button:DockMargin(4, 3, 3, 3)
	button.ncLaw, button.ncTarget = op, ply
	return button
end

-- The state of a suspect for the police: text and colour, or nil.
function M:_Record(ply)
	local law, i18n = self.law, self.ctx.i18n
	if law:IsJailed(ply) then
		return i18n:T("mode_city.menu.jailed", { time = law.Clock(law:JailLeft(ply)) }), DIM
	end
	local wanted = law:Wanted(ply)
	if wanted ~= nil then
		return i18n:T("mode_city.menu.wanted", { reason = wanted.reason }), RED
	end
	local warrant = law:WarrantOf(ply)
	if warrant ~= nil then
		return i18n:T("mode_city.menu.warranted", { reason = warrant.reason }), GOLD
	end
	return nil
end

function BUILD.police(self, body)
	local i18n, law = self.ctx.i18n, self.law
	local line = addRow(body, ROW + 6)
	addCaption(line, i18n:T("mode_city.menu.reason"))
	self:_Entry(line, "reason", "")
	local suspects = self:_Suspects()
	if suspects[1] == nil then
		addLabel(body, i18n:T("mode_city.menu.nobody"), FONT, DIM).ncNobody = true
		return
	end
	local warrants = self:MayWarrant()
	for _, ply in ipairs(suspects) do
		local row = addRow(body, ROW + 4)
		row.ncSuspect = ply
		if law:IsJailed(ply) then
			self:_LawButton(row, "release", ply)
		else
			if warrants and not law:HasWarrant(ply) then
				self:_LawButton(row, "warrant", ply)
			end
			self:_LawButton(row, law:IsWanted(ply) and "unwant" or "want", ply)
		end
		local job = self:JobOf(ply)
		local who = self.players:Name(ply)
		if job ~= nil then
			who = who .. " · " .. self:_Name(job.name, job.id)
		end
		local name = addLabel(row, who, FONT, job ~= nil and job.color or WHITE, LEFT)
		name:SetWide(300)
		name:DockMargin(12, 0, 0, 0)
		name.ncName = true
		local text, color = self:_Record(ply)
		if text ~= nil then
			local record = addLabel(row, text, FONT_SMALL, color, FILL)
			record.ncRecord = true
			if law:IsJailed(ply) then
				record.Think = function(panel)
					local now = self:_Record(ply)
					if now ~= nil and now ~= panel:GetText() then
						panel:SetText(now)
					end
				end
			end
		end
	end
end
