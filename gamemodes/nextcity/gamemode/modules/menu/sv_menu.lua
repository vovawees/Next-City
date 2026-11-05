-- Menu, the server part: answers the help tab with the console commands of a player.
--
--   menu:CommandsFor(ply) -> { { name, module, help, admin } } by name: the commands for
--                            everybody and the admin ones the player has the privilege of
--
-- Net: ask (client) -> commands (to the asking player).

local M = NC.Module("menu")

local ipairs = ipairs
local sub = string.sub

local LIMIT = 128 -- most commands in one answer (the array of the message)

function M:Init(ctx)
	ctx.net:Receive("ask", function(_, ply)
		ctx.net:Send("commands", ply, { list = self:CommandsFor(ply) })
	end)
end

function M:CommandsFor(ply)
	local permissions = self.ctx.permissions
	local list = {}
	for _, command in ipairs(self.ctx.commands:List()) do
		if #list >= LIMIT then
			break
		end
		if not command.admin or permissions:Can(ply, command.privilege) then
			list[#list + 1] = { name = sub(command.name, 1, 32), module = sub(command.module, 1, 32),
				help = sub(command.help or "", 1, 160), admin = command.admin }
		end
	end
	return list
end
