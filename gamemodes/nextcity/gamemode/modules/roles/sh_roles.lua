-- Roles, shared part: the registry. Modes register their roles in Init on both realms in
-- the same order (the index of a role goes over the network):
--
--   roles:Register("murderer", {
--   	name = "mode_homicide.role.murderer",        -- translation key (default roles.<id>)
--   	description = "mode_homicide.goal.murderer", -- what to do, shown with the role
--   	color = Color(200, 40, 40),
--   	side = "murderer",                           -- allies share a side (default: the id)
--   	visible = "side",                            -- who knows: self | side | all
--   	intro = true,                                -- a banner when a player gets it
--   })
--   roles:Def(id), roles:Index(id), roles:All() -> ids in the order of registration

local M = NC.Module("roles")

local type = type
local format = string.format

local VISIBLE = { self = true, side = true, all = true }
local ID = "^[a-z][a-z0-9_]*$"
local WHITE = Color(235, 235, 235)

function M:Init(ctx)
	self.defs = {}
	self.order = {}
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		self:_StartServer(ctx)
	else
		self:_StartClient(ctx)
	end
end

-- Registers or replaces a role (see the top of the file); its definition.
function M:Register(id, def)
	assert(type(id) == "string" and id:find(ID), "roles: Register(id): id must be lower_snake_case")
	def = def or {}
	assert(type(def) == "table", format("roles: Register(%s, def): def must be a table", id))
	local visible = def.visible or "self"
	assert(VISIBLE[visible], format("roles: role %s: visible must be self, side or all", id))
	local old = self.defs[id]
	local entry = {
		id = id,
		index = old ~= nil and old.index or #self.order + 1,
		name = def.name or "roles." .. id,
		description = def.description,
		color = def.color or WHITE,
		side = def.side or id,
		visible = visible,
		intro = def.intro ~= false,
	}
	assert(entry.index <= 255, "roles: more than 255 roles")
	self.defs[id] = entry
	self.order[entry.index] = id
	return entry
end

function M:Def(id)
	return self.defs[id]
end

function M:Index(id)
	local def = self.defs[id]
	return def and def.index or nil
end

function M:All()
	local out = {}
	for i, id in ipairs(self.order) do
		out[i] = id
	end
	return out
end

-- The side of a role id, or nil.
function M:SideOfRole(id)
	local def = self.defs[id]
	return def and def.side or nil
end
