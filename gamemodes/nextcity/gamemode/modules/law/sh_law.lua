-- Law, shared part: who keeps the law, who is wanted, has a warrant or sits in jail, and
-- what a jailed player cannot do (predicted on both realms).
--
--   law:IsOfficer(ply)    -> he keeps the law (law.officer: the police of the city)
--   law:IsAuthority(ply)  -> he heads the law (law.authority: the mayor of the city)
--   law:Wanted(ply)       -> { ends, reason } or nil; law:IsWanted(ply)
--   law:WarrantOf(ply)    -> { ends, reason } or nil; law:HasWarrant(ply)
--   law:IsJailed(ply), law:JailLeft(ply) -> s left in jail (0 when free)
--   law:Left(data)        -> s until the end of a wanted, warrant or jailed record
--   law.Clock(seconds)    -> "2:05"
--
-- Asks:    law.officer (ply) -> true, law.authority (ply) -> true (both realms; the mode
--          answers).
-- Listens: gm.StartCommand (no attacks, use or reload in jail), gm.PlayerSwitchWeapon
--          (empty hands in jail).

local M = NC.Module("law")

local CurTime = CurTime
local IsValid = IsValid
local floor = math.floor
local max = math.max
local format = string.format

M.BLOCKED = bit.bor(IN_ATTACK, IN_ATTACK2, IN_RELOAD, IN_USE)

function M:Init(ctx)
	self.hands = ctx:Require("hands")
	if SERVER then
		self:_InitServer(ctx)
	end
end

function M:Start(ctx)
	ctx:On("gm.StartCommand", "OnStartCommand")
	ctx:On("gm.PlayerSwitchWeapon", "AnswerSwitch")
	if SERVER then
		self:_StartServer(ctx)
	else
		self:_StartClient(ctx)
	end
end

function M:IsOfficer(ply)
	return IsValid(ply) and ply:IsPlayer() and self.ctx.events:Query("law.officer", ply) == true
end

function M:IsAuthority(ply)
	return IsValid(ply) and ply:IsPlayer() and self.ctx.events:Query("law.authority", ply) == true
end

local function record(self, name, ply)
	if not IsValid(ply) then
		return nil
	end
	return self.ctx.components[name]:Get(ply)
end

function M:Wanted(ply)
	return record(self, "wanted", ply)
end

function M:IsWanted(ply)
	return record(self, "wanted", ply) ~= nil
end

function M:WarrantOf(ply)
	return record(self, "warrant", ply)
end

function M:HasWarrant(ply)
	return record(self, "warrant", ply) ~= nil
end

function M:IsJailed(ply)
	return record(self, "jailed", ply) ~= nil
end

function M:Left(data)
	if data == nil then
		return 0
	end
	return max(0, data.ends - CurTime())
end

function M:JailLeft(ply)
	return self:Left(record(self, "jailed", ply))
end

function M.Clock(seconds)
	local whole = max(0, floor(seconds + 0.999))
	return format("%d:%02d", floor(whole / 60), whole % 60)
end

function M:OnStartCommand(ply, cmd)
	if self:IsJailed(ply) then
		local buttons = cmd:GetButtons()
		local kept = bit.band(buttons, bit.bnot(M.BLOCKED))
		if kept ~= buttons then
			cmd:SetButtons(kept)
		end
	end
end

-- Jailed hands stay empty: no switch to anything but the hands (or nothing without them).
function M:AnswerSwitch(ply, _, new)
	if not self:IsJailed(ply) then
		return nil
	end
	local hands = self.hands
	if hands ~= nil and IsValid(new) and new:GetClass() == hands.CLASS then
		return nil
	end
	return true
end
