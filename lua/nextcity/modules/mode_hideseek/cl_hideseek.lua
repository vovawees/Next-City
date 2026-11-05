-- Hide and Seek, client part: while the hide phase lasts a living seeker sees a blindfold
-- (a black screen, before the rest of the HUD) with the time to the hunt; everybody else
-- sees the time under the round timer. Texts change with the shown second or the language.
--
-- Listens: gm.HUDPaint (priority 200), i18n.changed.

local M = NC.Module("mode_hideseek")

local CurTime = CurTime
local ScrW = ScrW
local ScrH = ScrH
local ceil = math.ceil

local FONT_BLIND = "NC.HideSeek.Blind"
local FONT_TEXT = "NC.HideSeek.Text"
local OUTLINE = Color(0, 0, 0, 200)
local WHITE = Color(235, 235, 235)

surface.CreateFont(FONT_BLIND, { font = "Roboto", size = 34, weight = 700, extended = true })
surface.CreateFont(FONT_TEXT, { font = "Roboto", size = 22, weight = 600, extended = true })

function M:_InitClient(ctx)
	self.rounds = ctx:Require("rounds")
	self.releaseAt = 0
	self.shown = nil
	self.text = ""
	ctx.net:Receive("phase", "OnPhase")
end

function M:_StartClient(ctx)
	ctx:On("gm.HUDPaint", "Paint", { priority = 200 })
	ctx:On("i18n.changed", "Forget")
end

function M:OnPhase(data)
	self.releaseAt = data.releaseAt
	self:Forget()
end

function M:Forget()
	self.shown = nil
end

-- Seconds to the hunt, nil when nobody hides.
function M:TimeLeft()
	local left = self.releaseAt - CurTime()
	if left <= 0 then
		return nil
	end
	return left
end

function M:IsBlind()
	local me = LocalPlayer()
	return self:TimeLeft() ~= nil and IsValid(me) and me:Team() == M.SEEKERS and me:Alive()
end

function M:Paint()
	local left = self:TimeLeft()
	if left == nil then
		return
	end
	local blind = self:IsBlind()
	local shown = ceil(left - 1e-3) * (blind and -1 or 1)
	if shown ~= self.shown then
		self.shown = shown
		local key = blind and "mode_hideseek.hud.blind" or "mode_hideseek.hud.hiding"
		self.text = self.ctx.i18n:T(key, { time = self.rounds.FormatTime(left) })
	end
	local w, h = ScrW(), ScrH()
	if blind then
		surface.SetDrawColor(0, 0, 0, 255)
		surface.DrawRect(0, 0, w, h)
		draw.SimpleTextOutlined(self.text, FONT_BLIND, w * 0.5, h * 0.45, WHITE, TEXT_ALIGN_CENTER,
			TEXT_ALIGN_CENTER, 1, OUTLINE)
	else
		-- Where the status line of a round goes: under the scores of the teams.
		draw.SimpleTextOutlined(self.text, FONT_TEXT, w * 0.5, self.rounds.STATUS_Y or 98, WHITE, TEXT_ALIGN_CENTER,
			TEXT_ALIGN_TOP, 1, OUTLINE)
	end
end
