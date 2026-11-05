-- Restraints, client part: a tied player sees it at the bottom of the screen; everybody
-- sees "tied up" under the name of a tied player (players.targetLines).
--
-- Listens: gm.HUDPaint, players.targetLines.

local M = NC.Module("restraints")

local ScrW = ScrW
local ScrH = ScrH

local FONT = "NC.Restraints.Text"
local OUTLINE = Color(0, 0, 0, 200)
local RED = Color(230, 90, 70)

surface.CreateFont(FONT, { font = "Roboto", size = 24, weight = 700, extended = true })

function M:_StartClient(ctx)
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("players.targetLines", "AddTargetLine")
	local playerMenu = ctx:Require("menu")
	if playerMenu ~= nil then
		playerMenu:AddHelp("restraints.tie", { bind = "+use", fallback = "e", text = "restraints.help.tie", order = 64 })
	end
end

function M:Paint()
	local me = LocalPlayer()
	if not IsValid(me) or not me:Alive() or not self:IsTied(me) then
		return
	end
	draw.SimpleTextOutlined(self.ctx.i18n:T("restraints.hud.tied"), FONT, ScrW() * 0.5, ScrH() * 0.72, RED,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, OUTLINE)
end

function M:AddTargetLine(lines, ply)
	if self:IsTied(ply) then
		lines[#lines + 1] = self.ctx.i18n:T("restraints.target.tied")
	end
	return lines
end
