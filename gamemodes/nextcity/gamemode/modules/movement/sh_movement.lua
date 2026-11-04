-- Movement, shared part: limits of the user commands.
--
-- A limit is what the body takes away from every user command of a player: keys removed
-- (sprint, jump), keys forced (crouching for a body that cannot stand) or everything
-- (unconscious: no keys but crouching, no movement, no impulses). Players without a
-- limit cost one table lookup per command; noclip is never limited. The server and the
-- predicting client apply the same limits, so the prediction agrees with the server.

local M = NC.Module("movement")

local band = bit.band
local bor = bit.bor
local bnot = bit.bnot
local MOVETYPE_NOCLIP = MOVETYPE_NOCLIP

local FROZEN = { frozen = true, keep = 0, add = IN_DUCK }
local shared = {} -- limits by the keys they remove and force, shared by every player

-- The limit for capabilities of the organism `caps`, or nil for none.
function M.LimitOf(caps)
	if caps == nil or not caps.alive then
		return nil
	end
	if caps.unconscious then
		return FROZEN
	end
	local remove, add = 0, 0
	if not caps.canStand then
		remove, add = IN_JUMP + IN_SPEED, IN_DUCK
	else
		if not caps.canSprint then
			remove = remove + IN_SPEED
		end
		if not caps.canJump then
			remove = remove + IN_JUMP
		end
	end
	if remove == 0 and add == 0 then
		return nil
	end
	local id = remove .. ":" .. add
	local limit = shared[id]
	if limit == nil then
		limit = { frozen = false, keep = bnot(remove), add = add }
		shared[id] = limit
	end
	return limit
end

-- The limit of `ply` now, or nil.
function M:Limit(ply)
	return self.limits[ply]
end

-- Every user command of a player, before the engine runs it.
function M:OnStartCommand(ply, cmd)
	local limit = self.limits[ply]
	if limit == nil or ply:GetMoveType() == MOVETYPE_NOCLIP then
		return
	end
	if limit.frozen then
		cmd:SetButtons(limit.add)
		cmd:ClearMovement()
		cmd:SetImpulse(0)
		return
	end
	local buttons = cmd:GetButtons()
	local limited = bor(band(buttons, limit.keep), limit.add)
	if limited ~= buttons then
		cmd:SetButtons(limited)
	end
end
