-- Law, client part: a jailed player sees the time he has left, a wanted one why he is
-- wanted; everybody sees "Wanted" and "In jail" under the name of a target
-- (players.targetLines).
--
--   law:Ask(op, target, reason) -> asks the server: want, unwant, warrant (with a reason),
--                                  arrest, release, search
--
-- Listens: gm.HUDPaint, players.targetLines, i18n.changed.

local M = NC.Module("law")

local IsValid = IsValid
local ScrW = ScrW
local ScrH = ScrH
local floor = math.floor
local tostring = tostring

local FONT = "NC.Law.Text"
local OUTLINE = Color(0, 0, 0, 200)
local RED = Color(230, 90, 70)
local AMBER = Color(240, 190, 80)

surface.CreateFont(FONT, { font = "Roboto", size = 22, weight = 700, extended = true })

function M:_StartClient(ctx)
	self.texts = {} -- slot -> { stamp, text }: rebuilt when what they show changes
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("players.targetLines", "AddTargetLine")
	ctx:On("i18n.changed", function()
		self.texts = {}
	end)
end

function M:_Text(slot, stamp, key, params)
	local cached = self.texts[slot]
	if cached == nil or cached.stamp ~= stamp then
		cached = { stamp = stamp, text = self.ctx.i18n:T(key, params) }
		self.texts[slot] = cached
	end
	return cached.text
end

function M:Paint()
	local me = LocalPlayer()
	if not IsValid(me) then
		return
	end
	local x, y = ScrW() * 0.5, ScrH() * 0.64
	if self:IsJailed(me) then
		local left = floor(self:JailLeft(me) + 0.999)
		local text = self:_Text("jailed", left, "law.hud.jailed", { time = M.Clock(left) })
		draw.SimpleTextOutlined(text, FONT, x, y, RED, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, OUTLINE)
		return
	end
	local wanted = self:Wanted(me)
	if wanted ~= nil then
		local text = self:_Text("wanted", wanted.reason, "law.hud.wanted", { reason = wanted.reason })
		draw.SimpleTextOutlined(text, FONT, x, y, AMBER, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, OUTLINE)
	end
end

function M:AddTargetLine(lines, ply)
	if self:IsJailed(ply) then
		lines[#lines + 1] = self.ctx.i18n:T("law.target.jailed")
	elseif self:IsWanted(ply) then
		lines[#lines + 1] = self.ctx.i18n:T("law.target.wanted")
	end
	return lines
end

function M:Ask(op, target, reason)
	if not IsValid(target) or not target:IsPlayer() then
		return
	end
	local data = { op = op, target = target }
	if reason ~= nil then
		data.reason = tostring(reason)
	end
	self.ctx.net:SendToServer("law", data)
end
