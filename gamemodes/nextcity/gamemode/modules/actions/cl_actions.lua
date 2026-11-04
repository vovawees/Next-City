-- Actions, client part: the progress bar of the local player's action, at the bottom
-- middle of the screen, with the translated label and the time left.
--
-- Listens: gm.HUDPaint.

local M = NC.Module("actions")

local CurTime = CurTime
local ScrW = ScrW
local ScrH = ScrH
local LocalPlayer = LocalPlayer
local min = math.min
local max = math.max
local format = string.format

local FONT = "NC.Action"
local WIDTH = 320
local HEIGHT = 10
local BACK = Color(0, 0, 0, 170)
local FILL = Color(235, 235, 235, 230)
local TEXT = Color(235, 235, 235)

surface.CreateFont(FONT, { font = "Roboto", size = 20, weight = 500, extended = true })

function M:Init() end

function M:Start(ctx)
	ctx:On("gm.HUDPaint", "Paint")
end

-- The action of the local player: { label, target, startedAt, duration } or nil.
function M:Current()
	local ply = LocalPlayer()
	if not IsValid(ply) then
		return nil
	end
	return self.ctx.components.action:Get(ply)
end

-- The share of the action done, 0..1, or nil.
function M:Progress(now)
	local action = self:Current()
	if action == nil then
		return nil
	end
	if action.duration <= 0 then
		return 1
	end
	return max(0, min(1, ((now or CurTime()) - action.startedAt) / action.duration))
end

function M:Paint()
	local action = self:Current()
	if action == nil then
		return
	end
	local now = CurTime()
	local share = self:Progress(now)
	local i18n = self.ctx.i18n
	local label = i18n:Has(action.label) and i18n:T(action.label, { target = action.target }) or action.label
	local left = max(0, action.startedAt + action.duration - now)
	local x, y = (ScrW() - WIDTH) / 2, ScrH() * 0.72
	draw.SimpleText(format("%s  %.1f", label, left), FONT, ScrW() / 2, y - 6, TEXT, TEXT_ALIGN_CENTER,
		TEXT_ALIGN_BOTTOM)
	draw.RoundedBox(3, x, y, WIDTH, HEIGHT, BACK)
	draw.RoundedBox(3, x + 1, y + 1, (WIDTH - 2) * share, HEIGHT - 2, FILL)
end
