-- Inventory, client part: the snapshots of the containers the player sees, his intents
-- and the item registry (sh_items.lua).
--
--   inventory:Get(id)      a container: { id, kind, title, name, size, maxSize, maxWeight
--                          (kg or nil), weight (kg), own, parent, parentSlot, slotNames,
--                          items (list), bySlot = { [slot] = item } }; an item is { slot,
--                          uid, id, count, charge, cond, label, sub }
--   inventory:Own()        the player's containers: equipment, pockets, then bags
--   inventory:External()   the other containers he has open
--   inventory:Count(id)    how many of item `id` he carries (less what Spend predicted)
--   inventory:Spend(id, n) predicts that n of item `id` were used (until the next snapshot)
--   inventory:Move(fromId, fromSlot, toId, toSlot, count), Act(id, slot, verb, count),
--   inventory:Close(id)    intents to the server
--
-- Emits: inventory.updated (id, container, new), inventory.closed (id)  client

local M = NC.Module("inventory")

local ipairs = ipairs
local pairs = pairs
local sort = table.sort

local KIND_ORDER = { equipment = 1, pockets = 2, bag = 3 }

function M:Init(ctx)
	self:_InitItems()
	self.containers = {} -- id -> container
	self.spent = {}      -- item id -> predicted count used since the last own snapshot
	ctx.net:Receive("contents", "OnContents")
	ctx.net:Receive("closed", "OnClosed")
	self:_InitScreen(ctx)
end

function M:Start(ctx)
	self:_StartScreen(ctx)
end

function M:OnContents(data)
	local bySlot = {}
	for _, item in ipairs(data.items) do
		bySlot[item.slot] = item
	end
	data.bySlot = bySlot
	data.weight = data.weight / 10
	data.maxWeight = data.maxWeight > 0 and data.maxWeight / 10 or nil
	local new = self.containers[data.id] == nil
	self.containers[data.id] = data
	if data.own then
		self.spent = {}
	end
	self.ctx.events:Emit("inventory.updated", data.id, data, new)
	if data.opened then
		self:OpenScreen()
	end
end

function M:OnClosed(data)
	if self.containers[data.id] ~= nil then
		self.containers[data.id] = nil
		self.ctx.events:Emit("inventory.closed", data.id)
	end
end

function M:Get(id)
	return self.containers[id]
end

local function byKind(a, b)
	local ka, kb = KIND_ORDER[a.kind] or 9, KIND_ORDER[b.kind] or 9
	if ka ~= kb then
		return ka < kb
	end
	return a.id < b.id
end

local function byId(a, b)
	return a.id < b.id
end

-- The player's own containers in the order of the screen (a new list).
function M:Own()
	local out = {}
	for _, c in pairs(self.containers) do
		if c.own then
			out[#out + 1] = c
		end
	end
	sort(out, byKind)
	return out
end

-- The other containers the player has open (a new list).
function M:External()
	local out = {}
	for _, c in pairs(self.containers) do
		if not c.own then
			out[#out + 1] = c
		end
	end
	sort(out, byId)
	return out
end

-- The first own container of `kind`, or nil.
function M:OwnOfKind(kind)
	for _, c in ipairs(self:Own()) do
		if c.kind == kind then
			return c
		end
	end
	return nil
end

function M:Count(id)
	local count = 0
	for _, c in pairs(self.containers) do
		if c.own then
			for _, item in ipairs(c.items) do
				if item.id == id then
					count = count + item.count
				end
			end
		end
	end
	return math.max(0, count - (self.spent[id] or 0))
end

function M:Spend(id, count)
	self.spent[id] = (self.spent[id] or 0) + count
end

function M:Where(c)
	return c.own and "own" or "external"
end

function M:Move(fromId, fromSlot, toId, toSlot, count)
	self.ctx.net:SendToServer("move", { from = fromId, fromSlot = fromSlot, to = toId, toSlot = toSlot or 0,
		count = count or 0 })
end

function M:Act(id, slot, verb, count)
	self.ctx.net:SendToServer("act", { container = id, slot = slot, verb = verb, count = count or 0 })
end

function M:Close(id)
	self.ctx.net:SendToServer("close", { id = id })
end
