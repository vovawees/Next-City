-- Example module, shared part: the public API, available on both realms.
-- Other modules reach it with ctx:Require("example") after declaring the dependency.

local M = NC.Module("example")

function M:Greeting(name)
	return self.ctx.config.greeting .. ", " .. tostring(name) .. "!"
end
