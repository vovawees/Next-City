-- Example module, server part.
--
-- Listens:    net.ready (a client has loaded).
-- Network:    sends state (to a ready player, then to everybody), receives wave.
-- Components: profile of every player (the platform replicates it and removes it when
--             the player leaves).
-- Jobs:       example:heartbeat, every config.interval seconds.

local M = NC.Module("example")

-- Init: register definitions, network handlers and convars. Dependencies are already
-- initialized; nothing runs yet.
function M:Init(ctx)
	self.beats = 0
	ctx.net:Receive("wave", "OnWave")
	ctx.log:Debug("initialized")
end

-- Start: subscribe and schedule. Everything made through ctx is undone on Stop.
function M:Start(ctx)
	ctx:On("net.ready", "OnPlayerReady")
	ctx:Every("heartbeat", ctx.config.interval, "Heartbeat")
	ctx.log:Info("started, heartbeat every %ss", ctx.config.interval)
end

-- The client has loaded and reported its language: greet it and send the full state.
-- Components need no such step: the platform sends their full state itself.
function M:OnPlayerReady(ply)
	ply:ChatPrint(self:Greeting(ply))
	self.ctx.net:Send("state", ply, { beats = self.beats })
	local profiles = self.ctx.components.profile
	if not profiles:Has(ply) then
		profiles:Add(ply)
	end
	self.ctx.log:Info("greeted %s", ply:Nick())
end

-- Data from clients is validated before handlers run: mood is "happy" or "calm".
-- Only changed fields of the profile go to the clients, a few times a second.
function M:OnWave(data, ply)
	local profiles = self.ctx.components.profile
	local profile = profiles:Get(ply)
	if profile ~= nil then
		profiles:Set(ply, "waves", profile.waves + 1)
		profiles:Set(ply, "mood", data.mood)
	end
	self.ctx.log:Info("%s waves (%s)", ply:Nick(), data.mood)
end

function M:Heartbeat(now)
	self.beats = self.beats + 1
	self.ctx.net:Broadcast("state", { beats = self.beats })
	self.ctx.log:Debug("heartbeat #%d at %.1f", self.beats, now)
end

-- Stop: release what ctx does not track (entities, files, external hooks).
function M:Stop(ctx)
	ctx.log:Info("stopped after %d heartbeats", self.beats)
end
