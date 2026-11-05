-- Hands, client part: PrintName is the translated name, again when the language changes.
--
-- Listens: i18n.changed.

local M = NC.Module("hands")

function M:_InitClient(ctx)
	ctx:On("i18n.changed", "_Rename")
	local playerMenu = ctx:Require("menu")
	if playerMenu ~= nil then
		playerMenu:AddHelp("hands.raise", { bind = "+reload", fallback = "r", text = "hands.help.raise", order = 76 })
		playerMenu:AddHelp("hands.carry", { bind = "+attack2", fallback = "mouse2", text = "hands.help.carry",
			order = 77 })
	end
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
