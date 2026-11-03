-- Example module, server part.
--
-- Listens: gm.PlayerInitialSpawn (bridge).
-- Jobs:    example:heartbeat, every config.interval seconds.

local M = NC.Module("example")

-- Init: register definitions, network messages and convars. Dependencies are already
-- initialized; nothing runs yet.
function M:Init(ctx)
	self.beats = 0
	ctx.log:Debug("initialized")
end

-- Start: subscribe and schedule. Everything made through ctx is undone on Stop.
function M:Start(ctx)
	ctx:On("gm.PlayerInitialSpawn", "OnPlayerJoined")
	ctx:Every("heartbeat", ctx.config.interval, "Heartbeat")
	ctx.log:Info("started, heartbeat every %ss", ctx.config.interval)
end

function M:OnPlayerJoined(ply)
	self.ctx.log:Info("%s", self:Greeting(ply:Nick()))
end

function M:Heartbeat(now)
	self.beats = self.beats + 1
	self.ctx.log:Debug("heartbeat #%d at %.1f", self.beats, now)
end

-- Stop: release what ctx does not track (entities, files, external hooks).
function M:Stop(ctx)
	ctx.log:Info("stopped after %d heartbeats", self.beats)
end
