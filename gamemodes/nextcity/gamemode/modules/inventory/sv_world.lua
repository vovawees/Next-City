-- Inventory, server part: things in the world.
--
--   things on the ground  SpawnItem(item, pos, ang) puts an item down as a prop of its model
--                         (component ground: every client sees what it is); the use key
--                         picks it up into the player's containers, what does not fit
--                         stays (Pickup). config.maxGround at once, the oldest go first.
--   places                SpawnPlace(pos, ang, spec) / AttachPlace(ent, spec): an entity
--                         with a container (a crate, a stash); the use key opens it.
--   bodies                the dead leave what they carried on their body (ragdoll.corpse)
--                         or, without one, in a bag where they died that goes away
--                         when empty (config.corpses).
-- Removing the entity destroys its item or its container with what is in it.
--
-- Listens: gm.PlayerUse (answers false for things and places: no engine use),
--          gm.EntityRemoved, ragdoll.corpse, players.died (first).
-- Emits:   inventory.picked (ply, id, count), inventory.dropped (ply, item, ent)

local M = NC.Module("inventory")

local IsValid = IsValid
local CurTime = CurTime
local Vector = Vector
local Angle = Angle
local ipairs = ipairs
local max = math.max
local min = math.min
local random = math.random

function M:_InitWorld()
	self.ground = {}     -- ent -> item
	self.groundList = {} -- ents in the order they were put down
	self.places = {}     -- ent -> container
	self.lastUse = {}    -- ply -> time of the last use
end

function M:_StartWorld(ctx)
	ctx:On("gm.PlayerUse", "OnPlayerUse")
	ctx:On("gm.EntityRemoved", "OnEntityRemoved")
	ctx:On("ragdoll.corpse", "OnCorpse")
	ctx:On("players.died", "OnDied", { priority = 100 })
end

-- Things on the ground -------------------------------------------------------------------

-- The item lying as entity `ent`, or nil.
function M:ItemOf(ent)
	return self.ground[ent]
end

-- The container of entity `ent` (a crate, a body), or nil.
function M:PlaceOf(ent)
	return self.places[ent]
end

function M:_LeaveGround(item, remove)
	local ent = item.entity
	item.entity = nil
	if ent == nil then
		return
	end
	self.ground[ent] = nil
	if IsValid(ent) then
		self.ctx.components.ground:Remove(ent)
		if remove then
			ent:Remove()
		end
	end
end

function M:_Trim()
	local list = self.groundList
	local kept = {}
	for _, ent in ipairs(list) do
		if self.ground[ent] ~= nil then
			kept[#kept + 1] = ent
		end
	end
	local limit = self.ctx.config.maxGround
	while #kept >= limit and kept[1] ~= nil do
		local oldest = table.remove(kept, 1)
		self:Destroy(self.ground[oldest])
	end
	self.groundList = kept
end

-- Puts an item down at `pos` as a prop of its model; returns the entity (nil when the
-- engine has no free entity: the item is destroyed then).
function M:SpawnItem(item, pos, ang)
	local def = self.defs[item.id]
	self:Detach(item)
	self:_Trim()
	local ent = ents.Create("prop_physics")
	if not IsValid(ent) then
		self:Destroy(item)
		return nil
	end
	ent:SetModel(def.model)
	ent:SetPos(pos)
	ent:SetAngles(ang or Angle(0, random(0, 359), 0))
	ent:Spawn()
	ent:Activate()
	ent:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	item.entity = ent
	self.ground[ent] = item
	self.groundList[#self.groundList + 1] = ent
	self.ctx.components.ground:Add(ent, { id = item.id, count = min(item.count, 16777215) })
	return ent
end

-- Where a player drops things: in front of the eyes, short of walls.
function M:DropPos(ply)
	local eye, dir = ply:GetShootPos(), ply:GetAimVector()
	local want = eye + dir * self.ctx.config.dropDistance
	local tr = util.TraceLine({ start = eye, endpos = want, filter = ply, mask = MASK_SOLID })
	if tr ~= nil and tr.Hit then
		return tr.HitPos - dir * 8
	end
	return want
end

-- Drops `count` (0: all) of an item a player has in front of him. Returns the entity.
function M:DropItem(ply, item, count)
	if count == nil or count <= 0 or count > item.count then
		count = item.count
	end
	local moving = count < item.count and self:Split(item, count) or item
	local ent = self:SpawnItem(moving, self:DropPos(ply), Angle(0, ply:EyeAngles().y, 0))
	if ent ~= nil then
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:Wake()
			phys:SetVelocity(ply:GetAimVector() * 120)
		end
		self.ctx.events:Emit("inventory.dropped", ply, moving, ent)
	end
	return ent
end

-- Picks up what lies as entity `ent` into a player's containers; what does not fit stays.
-- Returns how many he took.
function M:Pickup(ply, ent)
	local item = self.ground[ent]
	if item == nil then
		return 0
	end
	local before = item.count
	self.ground[ent], item.entity = nil, nil
	local placed, reason = self:_Store(ply, item)
	if not item.destroyed and item.container == nil then
		item.entity = ent
		self.ground[ent] = item
		self.ctx.components.ground:Set(ent, "count", item.count)
	else
		self.ctx.components.ground:Remove(ent)
		ent:Remove()
	end
	if placed > 0 then
		ply:EmitSound("items/itempickup.wav", 60)
		self.ctx.events:Emit("inventory.picked", ply, item.id, placed)
	end
	if placed < before then
		self:Fail(ply, reason or "full")
	end
	return placed
end

-- Places -----------------------------------------------------------------------------------

-- Makes entity `ent` a place: a container of spec (CreateContainer) with entity = ent.
function M:AttachPlace(ent, spec)
	local old = self.places[ent]
	if old ~= nil then
		self:RemoveContainer(old)
	end
	spec = spec or {}
	local c = self:CreateContainer({ kind = spec.kind or "crate", size = spec.size, title = spec.title, name = spec.name,
		maxWeight = spec.maxWeight, maxSize = spec.maxSize, entity = ent, data = spec.data,
		Accepts = spec.Accepts })
	self.places[ent] = c
	self.ctx.components.place:Add(ent, { kind = c.kind, title = c.title, name = tostring(c.name):sub(1, 32) })
	return c
end

-- A new prop of spec.model at `pos` with a container of spec. Returns the entity and the
-- container (nil when the engine has no free entity).
function M:SpawnPlace(pos, ang, spec)
	spec = spec or {}
	local ent = ents.Create(spec.class or "prop_physics")
	if not IsValid(ent) then
		return nil
	end
	ent:SetModel(spec.model or M.DEFAULT_MODEL)
	ent:SetPos(pos)
	ent:SetAngles(ang or Angle(0, 0, 0))
	ent:Spawn()
	ent:Activate()
	if spec.frozen then
		local phys = ent:GetPhysicsObject()
		if IsValid(phys) then
			phys:EnableMotion(false)
		end
	end
	return ent, self:AttachPlace(ent, spec)
end

-- The use key -----------------------------------------------------------------------------

function M:OnPlayerUse(ply, ent)
	local item, place = self.ground[ent], self.places[ent]
	if item == nil and place == nil then
		return nil
	end
	local now = CurTime()
	if (self.lastUse[ply] or 0) + self.ctx.config.useDelay > now then
		return false
	end
	self.lastUse[ply] = now
	if not self.players:IsAlive(ply) then
		return false
	end
	if item ~= nil then
		self:Pickup(ply, ent)
	else
		local ok, reason = self:Open(ply, place)
		if not ok then
			self:Fail(ply, reason)
		end
	end
	return false
end

function M:OnEntityRemoved(ent)
	local item = self.ground[ent]
	if item ~= nil then
		self.ground[ent], item.entity = nil, nil
		self:Destroy(item)
	end
	local c = self.places[ent]
	if c ~= nil then
		self.places[ent] = nil
		self:RemoveContainer(c)
	end
end

-- Takes the container off a place (the entity stays); its items are destroyed.
function M:DetachPlace(ent)
	local c = self.places[ent]
	if c ~= nil then
		self.places[ent] = nil
		if IsValid(ent) then
			self.ctx.components.place:Remove(ent)
		end
		self:RemoveContainer(c)
	end
end

-- The dead ------------------------------------------------------------------------------

-- Moves everything a player carries into a container on entity `ent`; the container, or
-- nil when he carried nothing.
function M:Bury(ply, ent, spec)
	local items = {}
	for _, c in ipairs(self.owned[ply] or {}) do
		for slot = 1, c.size do
			if c.items[slot] ~= nil then
				items[#items + 1] = c.items[slot]
			end
		end
	end
	if #items == 0 then
		return nil
	end
	spec = spec or {}
	local c = self:AttachPlace(ent, { kind = "corpse", size = max(8, min(M.MAX_SLOTS, #items)),
		title = spec.title or "inventory.kind.corpse", name = self.players:Name(ply), data = spec.data })
	for i, item in ipairs(items) do
		if i > c.size then
			self:Destroy(item)
		else
			self:Detach(item)
			self:_Place(c, i, item)
		end
	end
	return c
end

function M:OnCorpse(ply, corpse)
	if self.ctx.config.corpses then
		self:Bury(ply, corpse)
	end
end

function M:OnDied(ply)
	if not self:Carries(ply) then
		return
	end
	if not self.ctx.config.corpses then
		self:Clear(ply)
		return
	end
	local ent = ents.Create("prop_physics")
	if not IsValid(ent) then
		self:Clear(ply)
		return
	end
	ent:SetModel(self.ctx.config.bagModel)
	ent:SetPos(ply:GetPos() + Vector(0, 0, 12))
	ent:Spawn()
	ent:Activate()
	self:Bury(ply, ent, { title = "inventory.kind.remains", data = { removeWhenEmpty = true } })
end
