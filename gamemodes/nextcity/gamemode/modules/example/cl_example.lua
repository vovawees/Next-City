-- Example module, client part.
--
-- Listens:    net.ready (the hello went to the server), i18n.changed (translations).
-- Network:    receives state, sends wave.
-- Components: profile, a read-only mirror of the server data.

local M = NC.Module("example")

function M:Init(ctx)
	self.beats = 0
	ctx.net:Receive("state", "OnState")
	ctx.components.profile:OnChange("OnProfile")
end

function M:Start(ctx)
	ctx:On("net.ready", "OnReady")
	ctx:On("i18n.changed", "OnLanguageChanged")
	ctx.log:Info("started on the client")
end

-- The server knows this client now and sends the full state; wave back.
function M:OnReady()
	self.ready = true
	self.ctx.net:SendToServer("wave", { mood = "happy" })
end

function M:OnState(data)
	self.beats = data.beats
	self.ctx.log:Debug("server heartbeat #%d", data.beats)
end

-- A profile arrived or changed (mask: which fields came); data is nil when the player
-- has left. Read profiles any time with ctx.components.profile:Get(ply).
function M:OnProfile(index, data, mask)
	if data ~= nil and self.ctx.components.profile:Changed(mask, "waves") then
		self.ctx.log:Debug("player #%d has waved %d time(s)", index, data.waves)
	end
end

-- Cached interface texts are rebuilt here when the player switches the language.
function M:OnLanguageChanged(code)
	self.language = code
	self.ctx.log:Debug("language changed to %s", code)
end
