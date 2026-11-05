-- Economy, client part: the money of the local player for the HUD and the screens of modes.
--
--   economy:Balance() -> the account (component account), economy:Cash() -> the cash he carries
--   economy:Request(op, amount) -> asks the server: "deposit", "withdraw", "give", "drop"

local M = NC.Module("economy")

local IsValid = IsValid

function M:Balance()
	local me = LocalPlayer()
	local account = IsValid(me) and self.ctx.components.account:Get(me) or nil
	return account ~= nil and account.balance or 0
end

function M:Cash()
	return self.inventory:Count(self.item)
end

function M:Request(op, amount)
	self.ctx.net:SendToServer("cash", { op = op, amount = math.max(0, math.floor(tonumber(amount) or 0)) })
end
