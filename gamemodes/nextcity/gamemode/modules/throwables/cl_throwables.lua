-- Throwables, client part: PrintName is the translated name, again when the language
-- changes.
--
-- Listens: i18n.changed.

local M = NC.Module("throwables")

function M:_InitClient(ctx)
	ctx:On("i18n.changed", "_Rename")
end

function M:_Rename()
	for _, class in ipairs(self.order) do
		local name = self:Name(class)
		local stored = weapons.GetStored(class)
		if stored ~= nil then
			stored.PrintName = name
		end
		for _, weapon in ipairs(ents.FindByClass(class)) do
			weapon.PrintName = name
		end
	end
end
