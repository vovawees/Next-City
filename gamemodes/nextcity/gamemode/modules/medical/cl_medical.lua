-- Medical, client part: the report of an examination. A panel names the patient, lists
-- what was found (red: threatens life, yellow: needs care, green: fine) and offers a button
-- for everything the player can do about it with what he carries and with his hands. A
-- button starts the treatment (the action bar shows it) and closes the panel; the panel
-- closes by itself after config.reportTime s.
--
-- Listens: net report, i18n.changed.
-- Emits:   medical.report (data)  client: a report arrived

local M = NC.Module("medical")

local IsValid = IsValid
local CurTime = CurTime
local ScrH = ScrH
local ipairs = ipairs
local min = math.min
local format = string.format

local FONT = "NC.Medical"
local FONT_TITLE = "NC.MedicalTitle"
local WIDTH = 440
local LINE = 22
local BUTTON = 30

local WHITE = Color(235, 235, 235)
local DIM = Color(150, 150, 150)
local BACK = Color(18, 20, 24, 240)
local RED = Color(230, 95, 80)
local YELLOW = Color(230, 190, 90)
local GREEN = Color(120, 200, 120)
local BUTTON_BACK = Color(42, 46, 52, 240)
local BUTTON_HOVER = Color(62, 68, 76, 250)

-- How bad a finding is: red threatens life, yellow needs care, green is fine.
M.SEVERITY = {
	dead = RED, unconscious = RED, ["pulse.none"] = RED, ["breath.none"] = RED, ["breath.agonal"] = RED, airway = RED,
	["pale.severe"] = RED, ["bleed.arterial"] = RED, ["bleed.heavy"] = RED, internal = RED, ["chest.open"] = RED,
	["chest.tension"] = RED, tamponade = RED, ["rhythm.vf"] = RED, ["rhythm.asystole"] = RED, ["rhythm.pea"] = RED,
	confused = YELLOW, ["pulse.weak"] = YELLOW, ["pulse.fast"] = YELLOW, ["pulse.slow"] = YELLOW,
	["breath.fast"] = YELLOW, ["breath.slow"] = YELLOW, pale = YELLOW, ["bleed.light"] = YELLOW,
	["chest.quiet"] = YELLOW, pupils = YELLOW, ["paralysis.full"] = RED, ["paralysis.legs"] = YELLOW,
	fracture = YELLOW, ["fracture.open"] = RED, dislocation = YELLOW, tourniquet = YELLOW, pain = YELLOW,
	cold = YELLOW, awake = GREEN, ["pulse.normal"] = GREEN, ["breath.normal"] = GREEN, ["bleed.stopped"] = GREEN,
	ok = GREEN, ["rhythm.sinus"] = GREEN,
}

surface.CreateFont(FONT, { font = "Roboto", size = 17, weight = 500, extended = true })
surface.CreateFont(FONT_TITLE, { font = "Roboto", size = 20, weight = 700, extended = true })

function M:Init(ctx)
	self:_InitShared(ctx)
	self.report = nil   -- the last report (net data)
	self.reportAt = 0
	self.frame = nil
end

function M:Start(ctx)
	ctx.net:Receive("report", "OnReport")
	ctx:On("i18n.changed", "OnLanguage")
	ctx:Every("expire", 1, function()
		if IsValid(self.frame) and CurTime() - self.reportAt > self.ctx.config.reportTime then
			self:Close()
		end
	end)
end

function M:Stop()
	self:Close()
end

function M:OnReport(data)
	self.report, self.reportAt = data, CurTime()
	self:Show()
	self.ctx.events:Emit("medical.report", data)
end

function M:OnLanguage()
	if IsValid(self.frame) then
		self:Show()
	end
end

function M:_T(key, params, fallback)
	local i18n = self.ctx.i18n
	if i18n:Has(key) then
		return i18n:T(key, params)
	end
	return fallback or key
end

function M:_Part(part)
	if part == nil or part == "" then
		return ""
	end
	return self:_T("medical.part." .. part, nil, part)
end

-- The text of a finding of a report.
function M:Line(finding)
	local value = finding.value
	if finding.key == "temperature" then
		value = format("%.1f", value / 10)
	end
	local text = self:_T("medical.find." .. finding.key, { part = self:_Part(finding.part), value = value })
	if finding.flag ~= "" then
		text = text .. " — " .. self:_T("medical.flag." .. finding.flag, nil, finding.flag)
	end
	return text
end

-- The text of the button of an option of a report.
function M:OptionText(option)
	if option.source == "item" then
		local name = self.inventory:Name(option.id)
		return option.count > 1 and format("%s ×%d", name, option.count) or name
	end
	local text = self:_T("medical.hands." .. option.id, nil, option.id)
	if option.part ~= "" then
		text = text .. ": " .. self:_Part(option.part)
	end
	return text
end

local function paintFrame(_, w, h)
	draw.RoundedBox(6, 0, 0, w, h, BACK)
end

local function paintButton(panel, w, h)
	draw.RoundedBox(4, 0, 0, w, h, panel:IsHovered() and BUTTON_HOVER or BUTTON_BACK)
end

-- Shows the last report (again).
function M:Show()
	local data = self.report
	if data == nil then
		return nil
	end
	self:Close()
	local findings, options = data.findings, data.options
	local height = 64 + #findings * LINE + 28 + math.max(1, #options) * (BUTTON + 4) + BUTTON + 24
	local frame = vgui.Create("DFrame")
	frame:SetSize(WIDTH, min(ScrH() - 80, height))
	frame:Center()
	frame:SetTitle("")
	frame:ShowCloseButton(true)
	frame:SetDraggable(true)
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.Paint = paintFrame
	frame.ncReport = true
	local title = frame:Add("DLabel")
	title:Dock(TOP)
	title:SetTall(28)
	title:SetFont(FONT_TITLE)
	title:SetTextColor(WHITE)
	title:SetText(data.self and self:_T("medical.report.self") or self:_T("medical.report.title",
		{ patient = data.patient }))
	title.ncTitle = true
	local body = frame:Add("DScrollPanel")
	body:Dock(FILL)
	for _, finding in ipairs(findings) do
		local label = body:Add("DLabel")
		label:Dock(TOP)
		label:SetTall(LINE)
		label:SetFont(FONT)
		label:SetTextColor(M.SEVERITY[finding.key] or WHITE)
		label:SetText("• " .. self:Line(finding))
		label.ncFinding = finding
	end
	local heading = body:Add("DLabel")
	heading:Dock(TOP)
	heading:DockMargin(0, 8, 0, 2)
	heading:SetTall(20)
	heading:SetFont(FONT)
	heading:SetTextColor(DIM)
	heading:SetText(#options > 0 and self:_T("medical.report.options") or self:_T("medical.report.none"))
	for _, option in ipairs(options) do
		local button = body:Add("DButton")
		button:Dock(TOP)
		button:DockMargin(0, 2, 0, 2)
		button:SetTall(BUTTON)
		button:SetFont(FONT)
		button:SetTextColor(WHITE)
		button:SetText(self:OptionText(option))
		button.Paint = paintButton
		button.ncOption = option
		button.DoClick = function()
			self:Choose(option)
		end
	end
	local again = frame:Add("DButton")
	again:Dock(BOTTOM)
	again:DockMargin(0, 6, 0, 0)
	again:SetTall(BUTTON)
	again:SetFont(FONT)
	again:SetTextColor(WHITE)
	again:SetText(self:_T("medical.report.again"))
	again.Paint = paintButton
	again.ncAction = "again"
	again.DoClick = function()
		self:Close()
		self.ctx.net:SendToServer("examine", {})
	end
	self.frame = frame
	return frame
end

-- Treats with an option of the report.
function M:Choose(option)
	self.ctx.net:SendToServer("treat", { source = option.source, id = option.id, part = option.part })
	self:Close()
end

function M:Close()
	if IsValid(self.frame) then
		self.frame:Remove()
	end
	self.frame = nil
end

function M:IsOpen()
	return IsValid(self.frame)
end
