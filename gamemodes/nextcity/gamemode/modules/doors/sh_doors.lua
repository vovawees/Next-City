-- Doors, shared part: what a door is and what everybody knows of it.
--
--   doors:IsDoor(ent)            -> a door of a class of config.classes
--   doors:Info(ent)              -> the component of the door, or nil (nothing on it)
--   doors:Owner(ent)             -> the player who owns it, or nil; doors:Coowners(ent) -> players
--   doors:IsOwner(ply, ent), doors:IsCoowner(ply, ent)
--   doors:HasKeys(ply, ent)      -> the owner, a co-owner or a member of its group
--   doors:ForSale(ent)           -> nobody owns it, no group holds it, it is not closed
--   doors:Title(ent), doors:Group(ent) -> the text or nil
--
-- Asks: doors.member (ply, group) -> true: the player belongs to a group of the map (both
--       realms; the mode answers, e.g. the police of the city).

local M = NC.Module("doors")

local IsValid = IsValid
local ipairs = ipairs

function M:Init(ctx)
	self.classes = {}
	for _, class in ipairs(ctx.config.classes) do
		self.classes[class] = true
	end
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

function M:IsDoor(ent)
	return ent ~= nil and IsValid(ent) and self.classes[ent:GetClass()] == true
end

function M:Info(ent)
	if ent == nil or not IsValid(ent) then
		return nil
	end
	return self.ctx.components.door:Get(ent)
end

-- The player of an entity index of the component, or nil.
local function playerAt(index)
	if index == nil or index <= 0 then
		return nil
	end
	local ply = Entity(index)
	if IsValid(ply) and ply:IsPlayer() then
		return ply
	end
	return nil
end
M.PlayerAt = playerAt

function M:Owner(ent)
	local info = self:Info(ent)
	return info ~= nil and playerAt(info.owner) or nil
end

-- The co-owners of a door (players).
function M:Coowners(ent)
	local out = {}
	local info = self:Info(ent)
	for _, index in ipairs(info ~= nil and info.coowners or {}) do
		local ply = playerAt(index)
		if ply ~= nil then
			out[#out + 1] = ply
		end
	end
	return out
end

function M:IsOwner(ply, ent)
	return ply ~= nil and self:Owner(ent) == ply
end

function M:IsCoowner(ply, ent)
	local info = self:Info(ent)
	if info == nil or ply == nil or not IsValid(ply) then
		return false
	end
	local index = ply:EntIndex()
	for _, other in ipairs(info.coowners) do
		if other == index then
			return true
		end
	end
	return false
end

function M:Group(ent)
	local info = self:Info(ent)
	if info == nil or info.group == "" then
		return nil
	end
	return info.group
end

function M:Title(ent)
	local info = self:Info(ent)
	if info == nil or info.title == "" then
		return nil
	end
	return info.title
end

-- Whether a player holds the keys of a door: its owner, a co-owner, a member of its group.
function M:HasKeys(ply, ent)
	if ply == nil or not IsValid(ply) or not self:IsDoor(ent) then
		return false
	end
	if self:IsOwner(ply, ent) or self:IsCoowner(ply, ent) then
		return true
	end
	local group = self:Group(ent)
	return group ~= nil and self.ctx.events:Query("doors.member", ply, group) == true
end

-- Whether a door may be bought now: a door nobody owns, of no group, not closed.
function M:ForSale(ent)
	if not self:IsDoor(ent) then
		return false
	end
	local info = self:Info(ent)
	if info == nil then
		return true
	end
	return self:Owner(ent) == nil and info.group == "" and not info.closed
end
