-- Inventory, server part: containers and item instances.
--
--   local crate = inventory:CreateContainer({
--   	kind = "crate",            -- pockets, equipment, bag, crate, corpse, stash, other
--   	size = 12,                 -- slots, 1..64
--   	title = "loot.crate",      -- key of the title ({name}: the name below)
--   	name = "",                 -- e.g. whose body
--   	maxWeight = 40,            -- kg (nil: no limit)
--   	maxSize = 3,               -- the largest size of item it takes (3)
--   	owner = ply,               -- a player's own container (he always sees it)
--   	entity = ent,              -- where it is in the world (reach is measured to it)
--   	slotNames = { "head" },    -- names of the slots (the screen shows them)
--   	Accepts = function(container, slot, item, def) return true end,
--   	OnInsert = function(container, slot, item) end, -- an item came into a slot
--   	OnRemove = function(container, slot, item) end, -- an item left a slot
--   	OnChange = function(container, slot, item) end, -- the count of the item changed
--   })
--
-- An item lies in one place at a time: a slot of a container (item.container, item.slot),
-- the ground (item.entity, sv_world.lua) or nowhere (just created or taken out). Items
-- whose definition has the trait container = { slots, maxWeight, maxSize } carry their
-- own container (item.sub, kind "bag"); bags go into bags up to config.maxDepth, never
-- into themselves. Stacks merge when the items are the same and have no state.
--
-- Reasons of a failed move: "container", "reach", "empty", "same", "slot", "size",
-- "accepts", "weight", "cycle", "depth", "occupied", "full".

local M = NC.Module("inventory")

local pairs = pairs
local ipairs = ipairs
local next = next
local min = math.min
local max = math.max
local floor = math.floor
local setmetatable = setmetatable

local EPSILON = 1e-6
local MAX_ID = 16777215

local Container = {}
Container.__index = Container
M.ContainerMeta = Container -- the metatable of containers (M:Container(id) finds one)

function M:_InitContainers()
	self.containers = {} -- id -> container
	self.instances = {}  -- uid -> item
	self.lastContainer = 0
	self.lastUid = 0
	self.dirty = {}      -- container -> true: changed since the last flush
	self.ownDirty = {}   -- ply -> true: a bag changed hands, what he sees is recounted
end

local function copy(state)
	local out = {}
	if state ~= nil then
		for key, value in pairs(state) do
			out[key] = value
		end
	end
	return out
end
M.CopyState = copy

-- Creates a container (see the top of the file).
function M:CreateContainer(spec)
	spec = spec or {}
	repeat
		self.lastContainer = self.lastContainer % MAX_ID + 1
	until self.containers[self.lastContainer] == nil
	local c = setmetatable({
		id = self.lastContainer,
		kind = spec.kind or "other",
		title = spec.title or "inventory.kind." .. (spec.kind or "other"),
		name = spec.name or "",
		size = max(1, min(M.MAX_SLOTS, floor(spec.size or 8))),
		maxWeight = spec.maxWeight,
		maxSize = spec.maxSize or 3,
		owner = spec.owner,
		entity = spec.entity,
		slotNames = spec.slotNames,
		Accepts = spec.Accepts,
		OnInsert = spec.OnInsert,
		OnRemove = spec.OnRemove,
		OnChange = spec.OnChange,
		data = spec.data or {},
		items = {},
	}, Container)
	self.containers[c.id] = c
	self.dirty[c] = true
	return c
end

-- The container with id `id`, or nil.
function M:Container(id)
	return self.containers[id]
end

-- Removes a container and destroys what is in it.
function M:RemoveContainer(c)
	if c == nil or self.containers[c.id] ~= c then
		return
	end
	for slot = 1, c.size do
		local item = c.items[slot]
		if item ~= nil then
			self:Destroy(item)
		end
	end
	self.containers[c.id] = nil
	self.dirty[c] = nil
	c.removed = true
	self:_ContainerGone(c)
end

-- Items -----------------------------------------------------------------------------------

-- A new item of `count` (at most a stack) that lies nowhere yet, or nil and "unknown".
function M:Create(id, count, state)
	local def = self.defs[id]
	if def == nil then
		return nil, "unknown"
	end
	repeat
		self.lastUid = self.lastUid % MAX_ID + 1
	until self.instances[self.lastUid] == nil
	local item = { uid = self.lastUid, id = id, count = max(1, min(def.stack, floor(count or 1))), state = copy(state) }
	self.instances[item.uid] = item
	local bag = def.traits.container
	if bag ~= nil then
		item.sub = self:CreateContainer({ kind = "bag", size = bag.slots or 8, maxWeight = bag.maxWeight,
			maxSize = bag.maxSize or 2, title = def.name })
		item.sub.item = item
	end
	return item
end

-- The item with uid `uid`, or nil.
function M:Instance(uid)
	return self.instances[uid]
end

-- Destroys an item wherever it lies, with what is inside it.
function M:Destroy(item)
	if item == nil or self.instances[item.uid] ~= item then
		return
	end
	self:Detach(item)
	self.instances[item.uid] = nil
	item.destroyed = true
	if item.sub ~= nil then
		local sub = item.sub
		item.sub = nil
		sub.item = nil
		self:RemoveContainer(sub)
	end
end

-- Takes an item out of its place (a slot or the ground); it lies nowhere afterwards.
function M:Detach(item)
	local c = item.container
	if c ~= nil then
		local slot = item.slot
		c.items[slot] = nil
		item.container, item.slot = nil, nil
		self:_Changed(c, item)
		if c.OnRemove ~= nil then
			self:_Callback(c, "OnRemove", slot, item)
		end
	elseif item.entity ~= nil then
		self:_LeaveGround(item, true)
	end
end

function M:_Callback(c, name, slot, item)
	local ok, err = xpcall(c[name], debug.traceback, c, slot, item)
	if not ok then
		self.ctx.log:Error("container %s %s: %s", c.kind, name, tostring(err))
	end
end

-- Marks a container changed; a bag that changed hands changes what its owners see.
function M:_Changed(c, item)
	self.dirty[c] = true
	if item ~= nil and item.sub ~= nil then
		local _, _, owner = self:Root(c)
		if owner ~= nil then
			self.ownDirty[owner] = true
		end
	end
	-- The weight of a bag counts in the containers above it.
	local bag = c.item
	while bag ~= nil and bag.container ~= nil do
		self.dirty[bag.container] = true
		bag = bag.container.item
	end
end

-- Puts a detached item into an empty slot (no checks).
function M:_Place(c, slot, item)
	c.items[slot] = item
	item.container, item.slot = c, slot
	self:_Changed(c, item)
	if c.OnInsert ~= nil then
		self:_Callback(c, "OnInsert", slot, item)
	end
end

-- Changes the count of an item in place (0 destroys it).
function M:SetCount(item, count)
	count = floor(count)
	if count <= 0 then
		self:Destroy(item)
		return
	end
	if count == item.count then
		return
	end
	item.count = count
	local c = item.container
	if c ~= nil then
		self:_Changed(c)
		if c.OnChange ~= nil then
			self:_Callback(c, "OnChange", item.slot, item)
		end
	elseif item.entity ~= nil then
		self.ctx.components.ground:Set(item.entity, "count", count)
	end
end

-- Marks an item changed after its state changed (charge, cond, label).
function M:Touch(item)
	if item.container ~= nil then
		self:_Changed(item.container)
	end
end

-- Weights -----------------------------------------------------------------------------

-- kg of an item with what is inside it.
function M:ItemWeight(item)
	local def = self.defs[item.id]
	local weight = def ~= nil and def.weight * item.count or 0
	if item.sub ~= nil then
		weight = weight + self:ContainerWeight(item.sub)
	end
	return weight
end

-- kg of what is in a container.
function M:ContainerWeight(c)
	local weight = 0
	for _, item in pairs(c.items) do
		weight = weight + self:ItemWeight(item)
	end
	return weight
end

-- Nesting ----------------------------------------------------------------------------

-- The container at the top of the bags `c` is inside, and where it is: the entity that
-- holds it in the world (a crate, a body, a bag on the ground) and its owner player.
function M:Root(c)
	for _ = 1, 32 do
		local bag = c.item
		if bag == nil then
			return c, c.entity, c.owner
		end
		if bag.container == nil then
			return c, bag.entity, nil
		end
		c = bag.container
	end
	return c, c.entity, c.owner
end

-- How many bags `c` is inside.
local function depthOf(c)
	local depth = 0
	while c ~= nil and c.item ~= nil do
		depth = depth + 1
		c = c.item.container
	end
	return depth
end

-- How deep the bags inside `item` go (1 for an empty bag, 0 for an item without one).
local function innerDepth(item, guard)
	if item.sub == nil or guard > 32 then
		return 0
	end
	local deepest = 0
	for _, inner in pairs(item.sub.items) do
		deepest = max(deepest, innerDepth(inner, guard + 1))
	end
	return 1 + deepest
end

-- Whether container `c` is the inside of `item` or inside it.
function M:IsInside(c, item)
	for _ = 1, 32 do
		if c == nil then
			return false
		end
		if c == item.sub then
			return true
		end
		c = c.item and c.item.container
	end
	return false
end

-- Checks --------------------------------------------------------------------------------

-- Whether `count` of `item` (all of it: with its inside) may go into `slot` of `c`, as if
-- the slot were empty; `freed` kg leave `c` at the same time (a swap or a move inside it).
function M:CanPlace(c, slot, item, count, freed)
	local def = self.defs[item.id]
	if slot < 1 or slot > c.size then
		return false, "slot"
	end
	if def.size > c.maxSize then
		return false, "size"
	end
	if c.Accepts ~= nil and not c.Accepts(c, slot, item, def) then
		return false, "accepts"
	end
	local whole = count >= item.count
	if item.sub ~= nil and whole then
		if self:IsInside(c, item) then
			return false, "cycle"
		end
		if depthOf(c) + innerDepth(item, 0) > self.ctx.config.maxDepth then
			return false, "depth"
		end
	end
	if c.maxWeight ~= nil then
		local adds = whole and self:ItemWeight(item) or def.weight * count
		if self:ContainerWeight(c) - (freed or 0) + adds > c.maxWeight + EPSILON then
			return false, "weight"
		end
	end
	return true
end

-- Whether two items merge into one stack.
function M:CanStack(a, b)
	if a.id ~= b.id or a.sub ~= nil or b.sub ~= nil then
		return false
	end
	local def = self.defs[a.id]
	return def ~= nil and def.stack > 1 and next(a.state) == nil and next(b.state) == nil
end

-- How many of `item` fit onto the stack `other` in `c` (by the stack and the weight).
function M:_StackRoom(c, other, item, count, freed)
	local def = self.defs[item.id]
	local room = min(count, def.stack - other.count)
	if c.maxWeight ~= nil and def.weight > 0 then
		local free = c.maxWeight + EPSILON - (self:ContainerWeight(c) - (freed or 0))
		room = min(room, floor(free / def.weight))
	end
	return max(0, room)
end

-- Inserting -----------------------------------------------------------------------------

-- Puts a detached item into `c`: into `slot`, or onto stacks of it first and then into the
-- first slot that takes it. Returns how many went in and, when not all, the reason; what
-- merged into stacks leaves the item (destroyed when nothing is left of it).
function M:Insert(c, item, slot)
	local total = item.count
	if slot ~= nil and slot > 0 then
		local other = c.items[slot]
		if other == nil then
			local ok, reason = self:CanPlace(c, slot, item, total)
			if not ok then
				return 0, reason
			end
			self:_Place(c, slot, item)
			return total
		end
		if not self:CanStack(other, item) then
			return 0, "occupied"
		end
		local room = self:_StackRoom(c, other, item, total)
		if room <= 0 then
			return 0, "full"
		end
		self:SetCount(other, other.count + room)
		self:_Shrink(item, room)
		return room, room < total and "full" or nil
	end
	local placed, reason = 0, "full"
	for i = 1, c.size do
		local other = c.items[i]
		if other ~= nil and self:CanStack(other, item) then
			local room = self:_StackRoom(c, other, item, item.count)
			if room > 0 then
				self:SetCount(other, other.count + room)
				placed = placed + room
				if self:_Shrink(item, room) then
					return placed
				end
			end
		end
	end
	for i = 1, c.size do
		if c.items[i] == nil then
			local ok, why = self:CanPlace(c, i, item, item.count)
			if ok then
				self:_Place(c, i, item)
				return placed + item.count
			end
			if why ~= "accepts" and why ~= "slot" then
				reason = why
			end
		end
	end
	return placed, reason
end

-- Takes `count` off a detached item; true when nothing is left (it is destroyed).
function M:_Shrink(item, count)
	item.count = item.count - count
	if item.count <= 0 then
		self.instances[item.uid] = nil
		item.destroyed = true
		return true
	end
	return false
end

-- Splits `count` off an item into a new detached item with the same state.
function M:Split(item, count)
	local part = self:Create(item.id, count, item.state)
	self:SetCount(item, item.count - count)
	return part
end

-- Moving --------------------------------------------------------------------------------

-- Moves `count` (nil or 0: all) of the item in `fromSlot` of `from` to `toSlot` of `to`
-- (nil or 0: onto its stacks or into the first slot that takes it). An occupied slot
-- swaps whole items. No checks of who moves it (Move in sv_inventory.lua checks the
-- player). Returns true, or false and the reason.
function M:Transfer(from, fromSlot, to, toSlot, count)
	local item = from.items[fromSlot]
	if item == nil then
		return false, "empty"
	end
	if count == nil or count <= 0 or count > item.count then
		count = item.count
	end
	local whole = count == item.count
	if toSlot == nil or toSlot <= 0 then
		return self:_TransferAny(from, item, to, count)
	end
	if from == to and fromSlot == toSlot then
		return false, "same"
	end
	local other = to.items[toSlot]
	local freed = from == to and (whole and self:ItemWeight(item) or self.defs[item.id].weight * count) or 0
	if other == nil then
		local ok, reason = self:CanPlace(to, toSlot, item, count, freed)
		if not ok then
			return false, reason
		end
		if whole then
			self:Detach(item)
			self:_Place(to, toSlot, item)
		else
			self:_Place(to, toSlot, self:Split(item, count))
		end
		return true
	end
	if self:CanStack(other, item) then
		local room = self:_StackRoom(to, other, item, count, freed)
		if room <= 0 then
			return false, "full"
		end
		self:SetCount(other, other.count + room)
		self:SetCount(item, item.count - room)
		return true
	end
	if not whole then
		return false, "occupied"
	end
	return self:_Swap(from, fromSlot, item, to, toSlot, other)
end

function M:_Swap(from, fromSlot, item, to, toSlot, other)
	local same = from == to
	local ok, reason = self:CanPlace(to, toSlot, item, item.count, same and 0 or self:ItemWeight(other))
	if ok then
		ok, reason = self:CanPlace(from, fromSlot, other, other.count, same and 0 or self:ItemWeight(item))
	end
	if ok and other.sub ~= nil and self:IsInside(from, other) then
		ok, reason = false, "cycle"
	end
	if not ok then
		return false, reason
	end
	self:Detach(item)
	self:Detach(other)
	self:_Place(to, toSlot, item)
	self:_Place(from, fromSlot, other)
	return true
end

function M:_TransferAny(from, item, to, count)
	if from == to then
		return false, "same"
	end
	local whole = count == item.count
	if whole then
		-- Stacks first, then a free slot; what did not fit stays where it was.
		local merged = false
		for i = 1, to.size do
			local other = to.items[i]
			if other ~= nil and self:CanStack(other, item) then
				local room = self:_StackRoom(to, other, item, item.count)
				if room > 0 then
					merged = true
					self:SetCount(other, other.count + room)
					if room >= item.count then
						self:Destroy(item)
						return true
					end
					self:SetCount(item, item.count - room)
				end
			end
		end
		local reason = "full"
		for i = 1, to.size do
			if to.items[i] == nil then
				local ok, why = self:CanPlace(to, i, item, item.count)
				if ok then
					self:Detach(item)
					self:_Place(to, i, item)
					return true
				end
				if why ~= "accepts" and why ~= "slot" then
					reason = why
				end
			end
		end
		return merged, reason
	end
	local part = self:Split(item, count)
	local placed, reason = self:Insert(to, part)
	if placed < count then
		-- Back onto the stack it came from.
		local back = count - placed
		if item.destroyed then
			return placed > 0, reason
		end
		self:SetCount(item, item.count + back)
		if not part.destroyed then
			self.instances[part.uid] = nil
			part.destroyed = true
		end
		return placed > 0, placed > 0 and nil or reason
	end
	return true
end

-- Owners -------------------------------------------------------------------------------

-- The containers inside the items of `c`, deepest last.
function M:Inside(c, out)
	out = out or {}
	for slot = 1, c.size do
		local item = c.items[slot]
		if item ~= nil and item.sub ~= nil then
			out[#out + 1] = item.sub
			self:Inside(item.sub, out)
		end
	end
	return out
end

-- Every item in `c` and in the bags inside it.
function M:ItemsIn(c, out)
	out = out or {}
	for slot = 1, c.size do
		local item = c.items[slot]
		if item ~= nil then
			out[#out + 1] = item
			if item.sub ~= nil then
				self:ItemsIn(item.sub, out)
			end
		end
	end
	return out
end

-- Count of item `id` in `c` and in the bags inside it.
function M:CountIn(c, id)
	local count = 0
	for _, item in ipairs(self:ItemsIn(c)) do
		if item.id == id then
			count = count + item.count
		end
	end
	return count
end

-- Takes up to `count` of item `id` out of `c` and the bags inside it, the smallest
-- stacks first; the number taken.
function M:TakeIn(c, id, count)
	local list = {}
	for _, item in ipairs(self:ItemsIn(c)) do
		if item.id == id then
			list[#list + 1] = item
		end
	end
	table.sort(list, function(a, b) return a.count < b.count end)
	local taken = 0
	for _, item in ipairs(list) do
		if taken >= count then
			break
		end
		local n = min(item.count, count - taken)
		taken = taken + n
		self:SetCount(item, item.count - n)
	end
	return taken
end

-- Container methods for readability in other modules.
function Container:Item(slot)
	return self.items[slot]
end

function Container:IsEmpty()
	return next(self.items) == nil
end

-- The first empty slot, or nil.
function Container:FreeSlot()
	for slot = 1, self.size do
		if self.items[slot] == nil then
			return slot
		end
	end
	return nil
end

-- The slot named `name` (slotNames), or nil.
function Container:SlotOf(name)
	for slot, slotName in ipairs(self.slotNames or {}) do
		if slotName == name then
			return slot
		end
	end
	return nil
end
