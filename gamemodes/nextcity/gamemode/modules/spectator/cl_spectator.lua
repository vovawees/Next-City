-- Spectator module, client part: while the local player is not alive, the bottom of the
-- screen shows whom they follow, when they come back and the observer keys.
--
-- The camera and the target come from the engine (observer mode and target are
-- networked); texts are rebuilt when the camera, the target, the shown second or the
-- language changes, never every frame.

local M = NC.Module("spectator")

local CurTime = CurTime
local IsValid = IsValid
local LocalPlayer = LocalPlayer
local ScrW = ScrW
local ScrH = ScrH
local ceil = math.ceil
local floor = math.floor
local max = math.max

local FONT_NAME = "NC.Spectator.Name"
local FONT_SMALL = "NC.Spectator.Small"
local WHITE = Color(255, 255, 255)
local GREY = Color(190, 190, 190)
local OUTLINE = Color(0, 0, 0, 200)

surface.CreateFont(FONT_NAME, { font = "Roboto", size = 28, weight = 700, extended = true })
surface.CreateFont(FONT_SMALL, { font = "Roboto", size = 18, weight = 500, extended = true })

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.text = { label = nil, name = nil, color = WHITE, respawn = nil, hint = nil }
	self.shown = {} -- state, mode, target, respawn second and clock second on screen
end

function M:Start(ctx)
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("i18n.changed", "Invalidate")
end

function M:Invalidate()
	self.shown.state = nil
end

function M:_Refresh(state, mode, target, left)
	local i18n = self.ctx.i18n
	local text = self.text
	text.label, text.name, text.respawn, text.hint = nil, nil, nil, nil
	if target ~= nil and (mode == OBS_MODE_IN_EYE or mode == OBS_MODE_CHASE) then
		text.label = i18n:T("spectator.following")
		text.name = target:Nick()
		text.color = team.GetColor(target:Team())
	elseif mode == OBS_MODE_ROAMING then
		text.label = i18n:T("spectator.roaming")
	end
	if left ~= nil then
		text.respawn = i18n:T("spectator.respawn", { time = left })
	end
	if mode ~= OBS_MODE_NONE then
		text.hint = i18n:T("spectator.hint")
	end
	local shown = self.shown
	shown.state, shown.mode, shown.target, shown.left, shown.second = state, mode, target, left, floor(CurTime())
end

function M:Paint()
	local ply = LocalPlayer()
	if not IsValid(ply) then
		return
	end
	local state = self.players:State(ply)
	if state ~= "dead" and state ~= "spectator" then
		return
	end
	local mode = ply:GetObserverMode()
	local target = ply:GetObserverTarget()
	if not (IsValid(target) and target:IsPlayer()) then
		target = nil
	end
	local at = state == "dead" and self.players:RespawnAt(ply) or nil
	local left = at and max(ceil(at - CurTime() - 1e-3), 0) or nil
	local shown = self.shown
	-- Once a second as well: names and team colors change rarely and without a signal.
	if shown.state ~= state or shown.mode ~= mode or shown.target ~= target or shown.left ~= left
		or shown.second ~= floor(CurTime()) then
		self:_Refresh(state, mode, target, left)
	end
	local text = self.text
	local x, y = ScrW() * 0.5, ScrH()
	if text.label ~= nil then
		draw.SimpleTextOutlined(text.label, FONT_SMALL, x, y - 124, GREY, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, OUTLINE)
	end
	if text.name ~= nil then
		draw.SimpleTextOutlined(text.name, FONT_NAME, x, y - 104, text.color, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1,
			OUTLINE)
	end
	if text.respawn ~= nil then
		draw.SimpleTextOutlined(text.respawn, FONT_SMALL, x, y - 64, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1,
			OUTLINE)
	end
	if text.hint ~= nil then
		draw.SimpleTextOutlined(text.hint, FONT_SMALL, x, y - 38, GREY, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, OUTLINE)
	end
end
