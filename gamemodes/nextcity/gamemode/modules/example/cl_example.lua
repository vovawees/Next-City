-- Example module, client part.
--
-- Listens: gm.InitPostEntity (bridge), i18n.changed (translations).

local M = NC.Module("example")

function M:Start(ctx)
	ctx:On("gm.InitPostEntity", "OnWorldReady")
	ctx:On("i18n.changed", "OnLanguageChanged")
	ctx.log:Info("started on the client")
end

-- Cached interface texts are rebuilt here when the player switches the language.
function M:OnLanguageChanged(code)
	self.language = code
	self.ctx.log:Debug("language changed to %s", code)
end

function M:OnWorldReady()
	self.worldReady = true
	self.ctx.log:Debug("world is ready")
end
