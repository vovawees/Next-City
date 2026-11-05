-- Players module, client part: the names players show to each other. The name of the
-- player under the crosshair replaces the target ID of the base gamemode (no engine
-- health: D6), within targetRange; chat lines of renamed players (players.name: an alias
-- in Homicide, a character in the city) show that name instead of the nickname.
--
-- Listens: gm.HUDDrawTargetID (answers true: the base one never draws), gm.OnPlayerChat.

local M = NC.Module("players")

local IsValid = IsValid
local CurTime = CurTime
local ScrW = ScrW
local ScrH = ScrH

local FONT = "NC.Players.Target"
local OUTLINE = Color(0, 0, 0, 200)
local DEAD = Color(255, 30, 40)
local TEAM = Color(30, 160, 40)
local WHITE = Color(255, 255, 255)
local REFRESH = 0.5 -- s before the name of the same target is asked again

surface.CreateFont(FONT, { font = "Roboto", size = 22, weight = 700, extended = true })

function M:Init()
	self.target = nil -- { ent, name, color, until }
end

function M:Start(ctx)
	ctx:On("gm.HUDDrawTargetID", "DrawTargetID")
	ctx:On("gm.OnPlayerChat", "AnswerChat")
end

-- The living player the local player looks at within targetRange, or nil.
function M:Aimed()
	local me = LocalPlayer()
	if not IsValid(me) or not self:IsAlive(me) then
		return nil
	end
	local eye = me:EyePos()
	local tr = util.TraceLine({ start = eye, endpos = eye + me:GetAimVector() * self.ctx.config.targetRange,
		filter = me, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	if ent == nil or not IsValid(ent) or not ent:IsPlayer() or not self:IsAlive(ent) then
		return nil
	end
	return ent
end

function M:DrawTargetID()
	local ent = self.ctx.config.targetNames and self:Aimed() or nil
	if ent == nil then
		self.target = nil
		return true
	end
	local target, now = self.target, CurTime()
	if target == nil or target.ent ~= ent or now >= target.refresh then
		target = { ent = ent, name = self:Name(ent), color = team.GetColor(ent:Team()), refresh = now + REFRESH }
		self.target = target
	end
	draw.SimpleTextOutlined(target.name, FONT, ScrW() * 0.5, ScrH() * 0.5 + 32, target.color, TEXT_ALIGN_CENTER,
		TEXT_ALIGN_TOP, 1, OUTLINE)
	return true
end

-- A renamed player's line: "*DEAD* (TEAM) Name: text" as the base gamemode prints it.
function M:AnswerChat(ply, text, teamChat, dead)
	if ply == nil or not IsValid(ply) or not ply:IsPlayer() then
		return nil
	end
	local name = self:Name(ply)
	if name == ply:Nick() then
		return nil
	end
	local i18n, parts = self.ctx.i18n, {}
	if dead then
		parts[#parts + 1] = DEAD
		parts[#parts + 1] = i18n:T("players.chat.dead") .. " "
	end
	if teamChat then
		parts[#parts + 1] = TEAM
		parts[#parts + 1] = i18n:T("players.chat.team") .. " "
	end
	parts[#parts + 1] = team.GetColor(ply:Team())
	parts[#parts + 1] = name
	parts[#parts + 1] = WHITE
	parts[#parts + 1] = ": " .. text
	chat.AddText(unpack(parts))
	return true
end
