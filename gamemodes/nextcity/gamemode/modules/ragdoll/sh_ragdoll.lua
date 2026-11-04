-- Ragdoll, shared part: the states of a body and the user commands of a player down in it.
--
-- A player that lies in its body (fallen, unconscious, getting up) gives the engine no
-- keys, no movement and no impulses. The server keeps them for the modules that move the
-- body (input: buttons, forward, side; jump: the jump key went down, a request to get up).
-- The predicting client takes them away the same way, so the prediction agrees.

local M = NC.Module("ragdoll")

local band = bit.band
local IN_JUMP = IN_JUMP

M.STATES = { "standing", "fallen", "unconscious", "getting_up", "dead" }

-- The states of a player that lies in its body.
M.DOWN = { fallen = true, unconscious = true, getting_up = true }

-- Every user command of a player, before the other modules (priority 10) and the engine.
function M:OnStartCommand(ply, cmd)
	local entry = self.down[ply]
	if entry == nil then
		return
	end
	local input = entry.input
	if input ~= nil then
		local buttons = cmd:GetButtons()
		if band(buttons, IN_JUMP) ~= 0 and band(input.buttons, IN_JUMP) == 0 then
			input.jump = true
		end
		input.buttons = buttons
		input.forward = cmd:GetForwardMove()
		input.side = cmd:GetSideMove()
	end
	cmd:ClearButtons()
	cmd:ClearMovement()
	cmd:SetImpulse(0)
end
