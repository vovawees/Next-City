-- Movement, client part: the local player predicts its movement with the limit of its
-- own body (the server sets the speeds and the engine sends them).
--
-- Listens: organism.capabilities, gm.StartCommand.

local M = NC.Module("movement")

local IsValid = IsValid
local LocalPlayer = LocalPlayer

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.limits = {} -- ply -> limit (sh_movement.lua); only the local player
end

function M:Start(ctx)
	ctx:On("organism.capabilities", "OnCapabilities")
	ctx:On("gm.StartCommand", "OnStartCommand")
	local ply = LocalPlayer()
	if IsValid(ply) then
		self:OnCapabilities(ply, self.organism:Capabilities(ply))
	end
end

function M:OnCapabilities(ply, caps)
	self.limits[ply] = M.LimitOf(caps)
end
