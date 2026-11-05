-- Restraints, shared part: what a tied player cannot do, predicted on both realms.
--
--   restraints:IsTied(ply)
--
-- Listens: gm.StartCommand (takes the attacks, reload, use, sprint and jump away),
--          gm.PlayerSwitchWeapon (keeps the hands).

local M = NC.Module("restraints")

local bor = bit.bor

M.BLOCKED = bor(IN_ATTACK, IN_ATTACK2, IN_RELOAD, IN_USE, IN_SPEED, IN_JUMP)

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

function M:IsTied(ply)
	return self.ctx.components.tied:Has(ply)
end

function M:OnStartCommand(ply, cmd)
	if self:IsTied(ply) then
		local buttons = cmd:GetButtons()
		local kept = bit.band(buttons, bit.bnot(M.BLOCKED))
		if kept ~= buttons then
			cmd:SetButtons(kept)
		end
	end
end

-- Tied hands stay empty: no switch to anything but the hands (or nothing without them).
function M:AnswerSwitch(ply, _, new)
	if not self:IsTied(ply) then
		return nil
	end
	local hands = self.hands
	if hands ~= nil and IsValid(new) and new:GetClass() == hands.CLASS then
		return nil
	end
	return true
end
