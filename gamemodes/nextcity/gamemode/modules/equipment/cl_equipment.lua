-- Equipment, client part: the ammo source predicts reloads of the local player from the
-- snapshots of his containers (the server corrects it with the next one).

local M = NC.Module("equipment")

local LocalPlayer = LocalPlayer
local min = math.min

function M:Init(ctx)
	self:_InitShared(ctx)
end

function M:Start(ctx)
	self:_StartShared(ctx)
end

function M:_ItemCount(ply, id)
	if ply ~= LocalPlayer() then
		return 0
	end
	return self.inventory:Count(id)
end

function M:_ItemTake(ply, id, count)
	if ply ~= LocalPlayer() then
		return 0
	end
	local taken = min(count, self.inventory:Count(id))
	if taken > 0 then
		self.inventory:Spend(id, taken)
	end
	return taken
end
