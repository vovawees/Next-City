-- Example module, client part.
--
-- Listens: gm.InitPostEntity (bridge).

local M = NC.Module("example")

function M:Start(ctx)
	ctx:On("gm.InitPostEntity", "OnWorldReady")
	ctx.log:Info("started on the client")
end

function M:OnWorldReady()
	self.worldReady = true
	self.ctx.log:Debug("world is ready")
end
