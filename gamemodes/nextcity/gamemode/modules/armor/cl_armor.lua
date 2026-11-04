-- Armor, client part: the armor of the local player.
--
-- Listens: component armor.
-- Emits:   armor.changed (pieces)  the worn armor or its condition changed (nil: none)

local M = NC.Module("armor")

local IsValid = IsValid
local LocalPlayer = LocalPlayer

function M:Init(ctx)
	self:_InitKinds()
	self.pieces = nil
	ctx.components.armor:OnChange("OnArmor")
end

function M:Start(ctx)
	local ply = LocalPlayer()
	local data = IsValid(ply) and ctx.components.armor:Get(ply) or nil
	if data ~= nil then
		self:OnArmor(ply:EntIndex(), data)
	end
end

function M:OnArmor(index, data)
	local ply = LocalPlayer()
	if not IsValid(ply) or index ~= ply:EntIndex() then
		return
	end
	self.pieces = data and data.pieces or nil
	self.ctx.events:Emit("armor.changed", self.pieces)
end

-- The armor of the local player, outer layers first: { id, condition } (do not modify),
-- or nil.
function M:Worn(ply)
	if ply ~= nil and ply ~= LocalPlayer() then
		return nil
	end
	return self.pieces
end
