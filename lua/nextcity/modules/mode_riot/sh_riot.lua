-- Riot, shared part: the teams of the mode (the palette indexes of the teams module the
-- round names "rioters" and "police").

local M = NC.Module("mode_riot")

M.RIOTERS = 1
M.POLICE = 2

function M:Init(ctx)
	if SERVER then
		self:_InitServer(ctx)
	end
end
