-- Example module, shared part: the public API, available on both realms.
-- Other modules reach it with ctx:Require("example") after declaring the dependency.

local M = NC.Module("example")

-- Greeting in the language of `ply` (on the client: the client language).
-- The text comes from lang/<code>/example.lua, key "example.greeting".
function M:Greeting(ply)
	return self.ctx.i18n:TFor(ply, "example.greeting", { name = ply:Nick() })
end
