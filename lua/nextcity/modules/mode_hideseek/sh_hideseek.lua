-- Hide and Seek, shared part: the teams of the mode (the palette indexes of the teams
-- module the round names "hiders" and "seekers").

local M = NC.Module("mode_hideseek")

M.HIDERS = 1
M.SEEKERS = 2

function M:Init(ctx)
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		ctx:On("net.ready", "OnNetReady")
	else
		self:_StartClient(ctx)
	end
end
