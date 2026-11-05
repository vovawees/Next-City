-- Homicide, shared part: the roles (registered on both realms in the same order) and the
-- aliases players see instead of names while a round runs (players.name).

local M = NC.Module("mode_homicide")

local ceil = math.ceil
local ipairs = ipairs

M.ALIASES = {
	"Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel", "India", "Juliett", "Kilo", "Lima",
	"Mike", "November", "Oscar", "Papa", "Quebec", "Romeo", "Sierra", "Tango", "Uniform", "Victor", "Whiskey",
	"X-ray", "Yankee", "Zulu",
}

M.ROLES = {
	{ "murderer", { name = "mode_homicide.role.murderer", description = "mode_homicide.goal.murderer",
		color = Color(200, 40, 40), side = "murderer", visible = "side" } },
	{ "sheriff", { name = "mode_homicide.role.sheriff", description = "mode_homicide.goal.sheriff",
		color = Color(60, 120, 230), side = "innocent", visible = "self" } },
	{ "innocent", { name = "mode_homicide.role.innocent", description = "mode_homicide.goal.innocent",
		color = Color(70, 180, 90), side = "innocent", visible = "self" } },
}

function M:Init(ctx)
	self.roles = ctx:Require("roles")
	for _, entry in ipairs(M.ROLES) do
		self.roles:Register(entry[1], entry[2])
	end
	if SERVER then
		self:_InitServer(ctx)
	end
end

function M:Start(ctx)
	ctx:On("players.name", "AnswerName")
end

-- The alias number `index`: the list wraps with a number ("Alpha 2").
function M.AliasName(index)
	local list = M.ALIASES
	local name = list[(index - 1) % #list + 1]
	if index > #list then
		name = name .. " " .. ceil(index / #list)
	end
	return name
end

-- The alias of a player in the round, or nil.
function M:Alias(ply)
	local alias = self.ctx.components.alias:Get(ply)
	if alias == nil or alias.index == 0 then
		return nil
	end
	return M.AliasName(alias.index)
end

function M:AnswerName(_, ply)
	return self:Alias(ply)
end
