-- HUD, client part: what the local player sees of their own body.
--
--   effects      darkening at the edges (tunnel vision), loss of colour and blur from
--                the vitals; a black screen while unconscious
--   statuses     lines at the bottom left (bleeding, fractures, pain, ...) in the order
--                of the organism's status flags, coloured by how serious they are
--   armor        the worn pieces and their condition at the bottom right
--   unconscious  the black screen says so and when the player may give up (reload key)
-- The HL2 health, suit and damage elements are always hidden, the crosshair and the
-- weapon elements while unconscious. Texts are rebuilt only when the flags, the armor or
-- the language change (the give-up hint when its second changes), never every frame.
--
-- Listens: organism.vitals, organism.capabilities, armor.changed, i18n.changed,
--          gm.HUDShouldDraw, gm.HUDPaint (before other modules), gm.RenderScreenspaceEffects.

local M = NC.Module("hud")

local ScrW = ScrW
local ScrH = ScrH
local ceil = math.ceil
local floor = math.floor
local min = math.min
local upper = string.upper

local FONT = "NC.Hud"
local FONT_LARGE = "NC.Hud.Large"
local WHITE = Color(255, 255, 255)
local DIM = Color(170, 170, 170)
local OUTLINE = Color(0, 0, 0, 200)
local LINE = 22

-- HL2 elements that mean nothing here, and those hidden while unconscious too.
M.HIDDEN = { CHudHealth = true, CHudBattery = true, CHudSuitPower = true, CHudDamageIndicator = true,
	CHudPoisonDamageIndicator = true }
M.HIDDEN_UNCONSCIOUS = { CHudCrosshair = true, CHudAmmo = true, CHudSecondaryAmmo = true,
	CHudWeaponSelection = true, CHudZoom = true }

local CRITICAL = Color(235, 70, 60)
local SERIOUS = Color(240, 160, 70)
local MILD = Color(235, 215, 130)
local CARE = Color(160, 200, 235)
-- Colours of the status lines (other statuses are white).
M.SEVERITY = {
	arrest = CRITICAL, heavyBleeding = CRITICAL, breathless = CRITICAL, paralysis = CRITICAL,
	bleeding = SERIOUS, shock = SERIOUS, fractureArmL = SERIOUS, fractureArmR = SERIOUS, fractureLegL = SERIOUS,
	fractureLegR = SERIOUS, fractureRibs = SERIOUS, fracturePelvis = SERIOUS, fractureSpine = SERIOUS,
	fractureSkull = SERIOUS, dislocation = SERIOUS, concussion = SERIOUS, burns = SERIOUS, poisoned = SERIOUS,
	cold = SERIOUS,
	pain = MILD, exhausted = MILD,
	tourniquet = CARE, bandaged = CARE,
}

local EDGE_LEFT = Material("vgui/gradient-l")
local EDGE_RIGHT = Material("vgui/gradient-r")
local EDGE_TOP = Material("vgui/gradient-u")
local EDGE_BOTTOM = Material("vgui/gradient-d")

surface.CreateFont(FONT, { font = "Roboto", size = 20, weight = 500, extended = true })
surface.CreateFont(FONT_LARGE, { font = "Roboto", size = 34, weight = 700, extended = true })

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.armor = ctx:Require("armor")
	self.unconscious = false
	self.statusBits = nil
	self.statuses = {} -- { text, color }
	self.pieces = {}   -- texts of the armor lines
	self.title = ""
	self.hint = nil
	self.hintShown = nil
	local playerMenu = ctx:Require("menu")
	if playerMenu ~= nil then
		playerMenu:AddHelp("hud.succumb", { bind = "+reload", fallback = "r", text = "hud.help.succumb", order = 84 })
	end
	self.colorModify = {
		["$pp_colour_addr"] = 0, ["$pp_colour_addg"] = 0, ["$pp_colour_addb"] = 0,
		["$pp_colour_brightness"] = 0, ["$pp_colour_contrast"] = 1, ["$pp_colour_colour"] = 1,
		["$pp_colour_mulr"] = 0, ["$pp_colour_mulg"] = 0, ["$pp_colour_mulb"] = 0,
	}
end

function M:Start(ctx)
	ctx:On("organism.vitals", "OnVitals")
	ctx:On("organism.capabilities", "OnCapabilities")
	ctx:On("armor.changed", "RebuildArmor")
	ctx:On("i18n.changed", "Rebuild")
	ctx:On("gm.HUDShouldDraw", "ShouldDraw")
	ctx:On("gm.HUDPaint", "Paint", { priority = 100 })
	ctx:On("gm.RenderScreenspaceEffects", "Effects")
	self:OnCapabilities(nil, self.organism:Capabilities())
	self:Rebuild()
end

function M:OnVitals(_, vitals)
	local bits = vitals and vitals.status
	if bits ~= self.statusBits then
		self.statusBits = bits
		self:RebuildStatuses()
	end
end

function M:OnCapabilities(_, caps)
	self.unconscious = caps ~= nil and caps.unconscious
end

-- Texts --------------------------------------------------------------------------------------

function M:Rebuild()
	self.title = self.ctx.i18n:T("hud.unconscious")
	self.hintShown = nil
	self:RebuildStatuses()
	self:RebuildArmor()
end

function M:RebuildStatuses()
	local list = {}
	local organism = self.organism
	local vitals = organism:Vitals()
	if vitals ~= nil then
		local i18n = self.ctx.i18n
		local most = self.ctx.config.statuses
		for _, name in ipairs(organism.STATUS_ORDER) do
			if name ~= "unconscious" and organism.HasStatus(vitals, name) then
				list[#list + 1] = { text = i18n:T("hud.status." .. name), color = M.SEVERITY[name] or WHITE }
				if #list >= most then
					break
				end
			end
		end
	end
	self.statuses = list
end

function M:RebuildArmor()
	local list = {}
	local worn = self.armor and self.armor:Worn()
	if worn ~= nil then
		local i18n = self.ctx.i18n
		for i, piece in ipairs(worn) do
			local key = "armor." .. piece.id
			list[i] = i18n:T("hud.armor", { name = i18n:Has(key) and i18n:T(key) or piece.id,
				condition = floor(piece.condition * 100 + 0.5) })
		end
	end
	self.pieces = list
end

-- The give-up hint for `left` seconds until the player may give up (nil: may not).
function M:_Hint(left)
	if left == nil then
		return nil
	end
	local i18n = self.ctx.i18n
	if left > 0 then
		return i18n:T("hud.succumbIn", { time = ceil(left - 1e-3) })
	end
	return i18n:T("hud.succumb", { key = upper(input.LookupBinding("+reload") or "r") })
end

-- Drawing ------------------------------------------------------------------------------------

function M:ShouldDraw(name)
	if M.HIDDEN[name] or (self.unconscious and M.HIDDEN_UNCONSCIOUS[name]) then
		return false
	end
end

-- Darkening, loss of colour and blur of the vitals (screen space, before the HUD).
function M:Effects()
	local vitals = self.organism:Vitals()
	if vitals == nil or self.unconscious or not self.ctx.config.effects then
		return
	end
	local grey, dark, blur = vitals.grey, vitals.dark, vitals.blur
	if grey > 0.02 or dark > 0.02 then
		local params = self.colorModify
		params["$pp_colour_colour"] = 1 - 0.95 * grey
		params["$pp_colour_brightness"] = -0.08 * dark
		params["$pp_colour_contrast"] = 1 - 0.25 * dark
		DrawColorModify(params)
	end
	if blur > 0.02 then
		DrawMotionBlur(1 - 0.75 * blur, blur, 0.01)
	end
end

-- Tunnel vision: the edges of the screen darken towards the middle.
local function edges(w, h, dark)
	local alpha = min(255, 360 * dark)
	local across, down = w * (0.12 + 0.38 * dark), h * (0.12 + 0.38 * dark)
	surface.SetDrawColor(0, 0, 0, alpha)
	surface.SetMaterial(EDGE_LEFT)
	surface.DrawTexturedRect(0, 0, across, h)
	surface.SetMaterial(EDGE_RIGHT)
	surface.DrawTexturedRect(w - across, 0, across, h)
	surface.SetMaterial(EDGE_TOP)
	surface.DrawTexturedRect(0, 0, w, down)
	surface.SetMaterial(EDGE_BOTTOM)
	surface.DrawTexturedRect(0, h - down, w, down)
end

function M:_PaintUnconscious(w, h)
	surface.SetDrawColor(0, 0, 0, 255)
	surface.DrawRect(0, 0, w, h)
	local left = self.organism:SuccumbIn()
	local shown = left and ceil(left - 1e-3) or -1
	if shown ~= self.hintShown then
		self.hintShown = shown
		self.hint = self:_Hint(left)
	end
	local x, y = w * 0.5, h * 0.45
	draw.SimpleTextOutlined(self.title, FONT_LARGE, x, y, DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, OUTLINE)
	if self.hint ~= nil then
		draw.SimpleTextOutlined(self.hint, FONT, x, y + 36, DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, OUTLINE)
	end
end

function M:Paint()
	local caps = self.organism:Capabilities()
	if caps == nil or not caps.alive then
		return
	end
	local w, h = ScrW(), ScrH()
	if caps.unconscious then
		self:_PaintUnconscious(w, h)
		return
	end
	local vitals = self.organism:Vitals()
	if self.ctx.config.effects and vitals.dark > 0.02 then
		edges(w, h, vitals.dark)
	end
	local y = h - 24
	local statuses = self.statuses
	for i = #statuses, 1, -1 do
		local line = statuses[i]
		draw.SimpleTextOutlined(line.text, FONT, 24, y, line.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_BOTTOM, 1, OUTLINE)
		y = y - LINE
	end
	y = h - 140
	local pieces = self.pieces
	for i = #pieces, 1, -1 do
		draw.SimpleTextOutlined(pieces[i], FONT, w - 24, y, WHITE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM, 1, OUTLINE)
		y = y - LINE
	end
end
