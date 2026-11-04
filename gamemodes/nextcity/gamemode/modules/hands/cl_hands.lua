-- Hands, client part: PrintName is the translated name, again when the language changes.
--
-- Listens: i18n.changed.

local M = NC.Module("hands")

function M:_InitClient(ctx)
	ctx:On("i18n.changed", "_Rename")
end

function M:_Rename()
	local name = self:Name()
	local stored = weapons.GetStored(M.CLASS)
	if stored ~= nil then
		stored.PrintName = name
	end
	for _, hands in ipairs(ents.FindByClass(M.CLASS)) do
		hands.PrintName = name
	end
end
