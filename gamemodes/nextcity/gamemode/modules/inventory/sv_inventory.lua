-- Inventory, server part: the containers of players, what every player sees, the
-- intents of clients, the API of other modules and the console.
--
-- Every player has pockets (config.pockets slots, small things) and the containers other
-- modules give him (AddOwned: the equipment). He sees his own containers and the bags in
-- them all the time, other containers while they are open and in reach (Open). Changes
-- go out once per tick: a snapshot of every changed container to the players who see it.
--
--   inventory:Give(ply or container, "bandage", 3, state, { drop = true }) -> given, reason
--   inventory:Take(ply or container, "ammo_9x19", 30)                      -> taken
--   inventory:Count(ply or container, "ammo_9x19")
--   inventory:Move(ply, fromId, fromSlot, toId, toSlot, count)              -> ok, reason
--   inventory:Act(ply, containerId, slot, verb, count)                     -> ok, reason
--   inventory:Pockets(ply), Owned(ply), Own(ply), Load(ply), Clear(ply), Open(ply, c)
--
-- Listens:  players.spawned, players.loadout (first: empties the containers of the
--           player), players.left, net.ready.
-- Asks:     inventory.place (ply, item, def) -> container, slot: where a thing a player
--           gets goes before the pockets (the equipment answers for what it wears);
--           inventory.canMove (ply, item, from, to) -> false forbids a move
-- Emits:    inventory.changed (container, owner)  once per tick per changed container
--           inventory.moved (ply, item, from, to), inventory.used (ply, item, verb, c),
--           inventory.opened (ply, container)
-- Commands: nc_items [filter], nc_inv [player], nc_item <player> <id> [count]

local M = NC.Module("inventory")

local IsValid = IsValid
local pairs = pairs
local ipairs = ipairs
local next = next
local tostring = tostring
local getmetatable = getmetatable
local min = math.min
local max = math.max
local floor = math.floor
local format = string.format
local sort = table.sort
local concat = table.concat
local traceback = debug.traceback

local EMPTY = {}

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.notices = ctx:Require("notices")
	self:_InitItems()
	self:_InitContainers()
	self:_InitWorld()
	self.pockets = {}  -- ply -> container
	self.owned = {}    -- ply -> { containers of his own, by order }
	self.watching = {} -- ply -> { [container] = "own" | "open" }
	self.watchers = {} -- container -> { [ply] = true }
	self.fresh = {}    -- ply -> { [container] = opened }: whole snapshots due this tick
	self:_RegisterHandlers()
	ctx.net:Receive("move", "OnMove")
	ctx.net:Receive("act", "OnAct")
	ctx.net:Receive("close", "OnClose")
	ctx.commands:Add("nc_items", { help = "[filter] - registered items", admin = false }, "ItemsCommand")
	ctx.commands:Add("nc_inv", { help = "[player] - containers and items of a player" }, "InventoryCommand")
	ctx.commands:Add("nc_item", { help = "<player> <id> [count] - gives a player an item" }, "GiveCommand")
end

function M:Start(ctx)
	ctx:On("players.spawned", "OnSpawned")
	ctx:On("players.loadout", "Clear", { priority = 100 })
	ctx:On("players.left", "OnLeft")
	ctx:On("net.ready", "OnNetReady")
	ctx:Every("flush", 0, function()
		self:Flush()
	end)
	ctx:Every("reach", 0.5, function()
		self:CheckReach()
	end)
	self:_StartWorld(ctx)
end

local function isContainer(value)
	return getmetatable(value) == M.ContainerMeta
end

-- Containers of players -----------------------------------------------------------------

-- The pockets of a player (made on first use).
function M:Pockets(ply)
	local c = self.pockets[ply]
	if c == nil then
		c = self:CreateContainer({ kind = "pockets", size = self.ctx.config.pockets, maxSize = 1 })
		self.pockets[ply] = c
		self:AddOwned(ply, c, 20)
	end
	return c
end

local function byOrder(a, b)
	if a.order ~= b.order then
		return a.order < b.order
	end
	return a.id < b.id
end

-- Makes `c` a container of a player's own; `order`: lower ones come first on the screen.
function M:AddOwned(ply, c, order)
	c.owner, c.order = ply, order or 50
	local list = self.owned[ply] or {}
	list[#list + 1] = c
	sort(list, byOrder)
	self.owned[ply] = list
	self.ownDirty[ply] = true
end

-- The containers of a player's own (not the bags in them): a new list.
function M:Owned(ply)
	self:Pockets(ply)
	local out = {}
	for i, c in ipairs(self.owned[ply]) do
		out[i] = c
	end
	return out
end

-- Every container a player owns: his own and the bags inside them, in order.
function M:Own(ply)
	local out = {}
	for _, c in ipairs(self:Owned(ply)) do
		out[#out + 1] = c
		self:Inside(c, out)
	end
	return out
end

-- Where things a player gets go when the place question has no answer: the pockets,
-- then the bags inside his containers.
function M:StoreOrder(ply)
	local out = { self:Pockets(ply) }
	for _, c in ipairs(self:Owned(ply)) do
		self:Inside(c, out)
	end
	return out
end

-- kg a player carries.
function M:Load(ply)
	local load = 0
	for _, c in ipairs(self.owned[ply] or EMPTY) do
		load = load + self:ContainerWeight(c)
	end
	return load
end

-- Destroys everything a player carries (his containers stay).
function M:Clear(ply)
	for _, c in ipairs(self.owned[ply] or EMPTY) do
		for slot = 1, c.size do
			local item = c.items[slot]
			if item ~= nil then
				self:Destroy(item)
			end
		end
	end
end

-- Whether a player carries anything.
function M:Carries(ply)
	for _, c in ipairs(self.owned[ply] or EMPTY) do
		if not c:IsEmpty() then
			return true
		end
	end
	return false
end

function M:OnSpawned(ply)
	self:Pockets(ply)
	self.ownDirty[ply] = true
end

function M:OnNetReady(ply)
	self.ownDirty[ply] = true
	for c in pairs(self.watching[ply] or EMPTY) do
		self:_Fresh(ply, c, false)
	end
end

function M:OnLeft(ply)
	self:Clear(ply)
	for c in pairs(self.watching[ply] or EMPTY) do
		self:_Unwatch(ply, c, true)
	end
	for _, c in ipairs(self.owned[ply] or EMPTY) do
		self:RemoveContainer(c)
	end
	self.watching[ply], self.fresh[ply], self.owned[ply], self.pockets[ply] = nil, nil, nil, nil
	self.ownDirty[ply], self.lastUse[ply] = nil, nil
end

-- Giving and taking ---------------------------------------------------------------------

-- Stores a detached item with a player: where the place question says, then the pockets
-- and his bags. Returns how many went in and, when not all, the reason; what did not
-- stays detached.
function M:_Store(ply, item)
	local total, reason = item.count, nil
	local c, slot = self.ctx.events:Query("inventory.place", ply, item, self.defs[item.id])
	if c ~= nil then
		local _, why = self:Insert(c, item, slot)
		reason = why
	end
	if not item.destroyed and item.container == nil then
		for _, store in ipairs(self:StoreOrder(ply)) do
			local _, why = self:Insert(store, item)
			if item.destroyed or item.container ~= nil then
				break
			end
			if why ~= nil and (reason == nil or why ~= "full") then
				reason = why
			end
		end
	end
	if item.destroyed or item.container ~= nil then
		return total
	end
	return total - item.count, reason or "full"
end

-- Gives `count` of item `id` to a player or a container (see the top of the file);
-- opts.drop: what does not fit falls at the player's feet. Returns how many he got and,
-- when not all, the reason.
function M:Give(target, id, count, state, opts)
	local def = self.defs[id]
	if def == nil then
		return 0, "unknown"
	end
	count = floor(count or 1)
	local given, reason = 0, nil
	local drop = opts ~= nil and opts.drop == true and not isContainer(target)
	while count > 0 do
		local n = min(count, def.stack)
		local item = self:Create(id, n, state)
		local placed, why
		if isContainer(target) then
			placed, why = self:Insert(target, item)
		else
			placed, why = self:_Store(target, item)
		end
		given, count = given + placed, count - n
		if not item.destroyed and item.container == nil then
			reason = why or "full"
			if drop and IsValid(target) then
				self:SpawnItem(item, target:GetPos() + Vector(0, 0, 16))
			else
				self:Destroy(item)
				break
			end
		end
	end
	return given, reason
end

local function containersOf(self, target)
	if isContainer(target) then
		return { target }
	end
	return self.owned[target] or EMPTY
end

-- How many of item `id` a player (all his containers) or a container holds.
function M:Count(target, id)
	local count = 0
	for _, c in ipairs(containersOf(self, target)) do
		count = count + self:CountIn(c, id)
	end
	return count
end

-- Takes up to `count` of item `id` from a player or a container; the number taken.
function M:Take(target, id, count)
	local taken = 0
	for _, c in ipairs(containersOf(self, target)) do
		if taken >= count then
			break
		end
		taken = taken + self:TakeIn(c, id, count - taken)
	end
	return taken
end

-- Every item a player carries (with the bags' insides) or a container holds.
function M:ItemsOf(target)
	local out = {}
	for _, c in ipairs(containersOf(self, target)) do
		self:ItemsIn(c, out)
	end
	return out
end

-- Seeing ------------------------------------------------------------------------------

function M:_Fresh(ply, c, opened)
	local fresh = self.fresh[ply]
	if fresh == nil then
		fresh = {}
		self.fresh[ply] = fresh
	end
	fresh[c] = opened or fresh[c] or false
end

function M:_Watch(ply, c, how)
	local set = self.watching[ply]
	if set == nil then
		set = {}
		self.watching[ply] = set
	end
	local was = set[c]
	if was == how or (was == "own" and how == "open") then
		return
	end
	set[c] = how
	local watchers = self.watchers[c]
	if watchers == nil then
		watchers = {}
		self.watchers[c] = watchers
	end
	watchers[ply] = true
	self:_Fresh(ply, c, how == "open")
end

function M:_Unwatch(ply, c, silent)
	local set = self.watching[ply]
	if set == nil or set[c] == nil then
		return
	end
	set[c] = nil
	local watchers = self.watchers[c]
	if watchers ~= nil then
		watchers[ply] = nil
		if next(watchers) == nil then
			self.watchers[c] = nil
		end
	end
	if self.fresh[ply] ~= nil then
		self.fresh[ply][c] = nil
	end
	if not silent and IsValid(ply) then
		self.ctx.net:Send("closed", ply, { id = c.id })
	end
end

-- Whether a player sees container `c` now: "own", "open" or nil.
function M:Watching(ply, c)
	local set = self.watching[ply]
	return set ~= nil and set[c] or nil
end

-- The players who see container `c` (a new list).
function M:Watchers(c)
	local out = {}
	for ply in pairs(self.watchers[c] or EMPTY) do
		out[#out + 1] = ply
	end
	return out
end

function M:_SyncOwn(ply)
	if not IsValid(ply) or ply:IsBot() then
		return
	end
	local own = {}
	for _, c in ipairs(self:Own(ply)) do
		own[c] = true
		self:_Watch(ply, c, "own")
	end
	for c, how in pairs(self.watching[ply] or EMPTY) do
		if how == "own" and not own[c] then
			self:_Unwatch(ply, c)
		end
	end
end

function M:_ContainerGone(c)
	for ply in pairs(self.watchers[c] or EMPTY) do
		self:_Unwatch(ply, c)
	end
	self.watchers[c] = nil
	local owner = c.owner
	if owner ~= nil and self.owned[owner] ~= nil then
		for i, other in ipairs(self.owned[owner]) do
			if other == c then
				table.remove(self.owned[owner], i)
				break
			end
		end
	end
	if c.entity ~= nil and self.places[c.entity] == c then
		self.places[c.entity] = nil
	end
end

-- Whether a player may take from and put into container `c` now: his own while alive,
-- another one while it is open (or the container it lies in) and in reach.
function M:CanReach(ply, c)
	if c == nil or c.removed or not IsValid(ply) or not self.players:IsAlive(ply) then
		return false
	end
	local top, ent, owner = self:Root(c)
	if owner == ply then
		return true
	end
	local set = self.watching[ply]
	if set == nil or (set[c] == nil and set[top] == nil) then
		return false
	end
	local holder = ent or owner
	return holder ~= nil and IsValid(holder) and self:InReach(ply, holder)
end

-- Whether entity `ent` is within config.reach of the eyes of a player.
function M:InReach(ply, ent)
	return ply:GetShootPos():Distance(ent:WorldSpaceCenter()) <= self.ctx.config.reach
end

-- Opens a container for a player who is close enough: he sees it until he closes it or
-- goes away. Returns true, or false and the reason.
function M:Open(ply, c)
	if c == nil or c.removed or not self.players:IsAlive(ply) then
		return false, "container"
	end
	local _, ent, owner = self:Root(c)
	if owner == ply then
		return true
	end
	local holder = ent or owner
	if holder == nil or not IsValid(holder) or not self:InReach(ply, holder) then
		return false, "reach"
	end
	self:_Watch(ply, c, "open")
	self.ctx.events:Emit("inventory.opened", ply, c)
	return true
end

-- Closes a container a player has open, and the bags in it he opened.
function M:Close(ply, c)
	if self:Watching(ply, c) ~= "open" then
		return
	end
	self:_Unwatch(ply, c)
	for _, inner in ipairs(self:Inside(c)) do
		if self:Watching(ply, inner) == "open" then
			self:_Unwatch(ply, inner)
		end
	end
end

function M:CheckReach()
	for ply, set in pairs(self.watching) do
		for c, how in pairs(set) do
			if how == "open" and not self:CanReach(ply, c) then
				self:_Unwatch(ply, c)
			end
		end
	end
end

-- Replication ----------------------------------------------------------------------------

local function tenths(kg)
	return max(0, min(65535, floor(kg * 10 + 0.5)))
end

function M:_Snapshot(ply, c, opened)
	local items = {}
	for slot = 1, c.size do
		local item = c.items[slot]
		if item ~= nil then
			local state = item.state
			items[#items + 1] = {
				slot = slot,
				uid = item.uid,
				id = item.id,
				count = min(item.count, 16777215),
				charge = max(0, min(65535, floor(tonumber(state.charge) or 0))),
				cond = max(0, min(1, tonumber(state.cond) or 1)),
				label = tostring(state.label or ""):sub(1, 16),
				sub = item.sub ~= nil and item.sub.id or 0,
			}
		end
	end
	local bag = c.item
	local parent = bag ~= nil and bag.container or nil
	return {
		id = c.id,
		kind = c.kind,
		title = c.title,
		name = tostring(c.name):sub(1, 32),
		size = c.size,
		maxSize = c.maxSize,
		maxWeight = c.maxWeight ~= nil and tenths(c.maxWeight) or 0,
		weight = tenths(self:ContainerWeight(c)),
		own = self:Watching(ply, c) == "own",
		opened = opened == true,
		parent = parent ~= nil and parent.id or 0,
		parentSlot = parent ~= nil and bag.slot or 0,
		slotNames = c.slotNames or EMPTY,
		items = items,
	}
end

-- Sends what changed since the last tick (every tick).
function M:Flush()
	local ownDirty = self.ownDirty
	if next(ownDirty) ~= nil then
		self.ownDirty = {}
		for ply in pairs(ownDirty) do
			self:_SyncOwn(ply)
		end
	end
	local dirty = self.dirty
	if next(dirty) ~= nil then
		self.dirty = {}
		local net, events = self.ctx.net, self.ctx.events
		for c in pairs(dirty) do
			if not c.removed then
				for ply in pairs(self.watchers[c] or EMPTY) do
					local fresh = self.fresh[ply]
					if fresh == nil or fresh[c] == nil then
						net:Send("contents", ply, self:_Snapshot(ply, c, false))
					end
				end
				local _, _, owner = self:Root(c)
				events:Emit("inventory.changed", c, owner)
				if c.data.removeWhenEmpty and c:IsEmpty() and IsValid(c.entity) then
					c.entity:Remove()
				end
			end
		end
	end
	local fresh = self.fresh
	if next(fresh) ~= nil then
		self.fresh = {}
		for ply, list in pairs(fresh) do
			for c, opened in pairs(list) do
				if not c.removed and self:Watching(ply, c) ~= nil then
					self.ctx.net:Send("contents", ply, self:_Snapshot(ply, c, opened))
				end
			end
		end
	end
end

-- Intents --------------------------------------------------------------------------------

-- Tells a player why something did not work ("inventory.fail.<reason>").
function M:Fail(ply, reason)
	local key = "inventory.fail." .. tostring(reason)
	if self.notices ~= nil and IsValid(ply) and self.ctx.i18n:Has(key) then
		self.notices:Send(ply, key, nil, "warn")
	end
end

-- Moves an item for a player (see Transfer in sv_containers.lua) after checking that he
-- reaches both containers. Returns true, or false and the reason.
function M:Move(ply, fromId, fromSlot, toId, toSlot, count)
	local from, to = self.containers[fromId], self.containers[toId]
	if from == nil or to == nil then
		return false, "container"
	end
	if not self:CanReach(ply, from) or not self:CanReach(ply, to) then
		return false, "reach"
	end
	local item = from.items[fromSlot]
	if item == nil then
		return false, "empty"
	end
	if self.ctx.events:Query("inventory.canMove", ply, item, from, to) == false then
		return false, "denied"
	end
	local ok, reason = self:Transfer(from, fromSlot, to, toSlot, count)
	if ok then
		self.ctx.events:Emit("inventory.moved", ply, item, from, to)
	end
	return ok, reason
end

function M:OnMove(data, ply)
	local ok, reason = self:Move(ply, data.from, data.fromSlot, data.to, data.toSlot, data.count)
	if not ok then
		self:Fail(ply, reason)
	end
end

-- "own" for a container of the player's own (or a bag in one), "external" for others.
function M:Where(ply, c)
	local _, _, owner = self:Root(c)
	return owner == ply and "own" or "external"
end

-- Runs a verb on the item in `slot` of a container for a player (slot 0 and "take_all":
-- everything in it). Returns true, or false and the reason.
function M:Act(ply, containerId, slot, verb, count)
	local c = self.containers[containerId]
	if c == nil or not self:CanReach(ply, c) then
		return false, "reach"
	end
	if slot == 0 then
		if verb == "take_all" then
			return self:TakeAll(ply, c)
		end
		return false, "verb"
	end
	local item = c.items[slot]
	if item == nil then
		return false, "empty"
	end
	local handler = self.handlers[verb]
	if handler == nil or not self:VerbApplies(verb, item, self:Where(ply, c), c.kind) then
		return false, "verb"
	end
	local ok, result, reason = xpcall(handler, traceback, ply, item, c, count or 0)
	if not ok then
		self.ctx.log:Error("verb %s of %s: %s", verb, item.id, tostring(result))
		return false, nil
	end
	if result then
		self.ctx.events:Emit("inventory.used", ply, item, verb, c)
	end
	return result == true, reason
end

function M:OnAct(data, ply)
	local ok, reason = self:Act(ply, data.container, data.slot, data.verb, data.count)
	if not ok and reason ~= nil then
		self:Fail(ply, reason)
	end
end

function M:OnClose(data, ply)
	local c = self.containers[data.id]
	if c ~= nil then
		self:Close(ply, c)
	end
end

-- Moves `count` (0: all) of an item in another container to the player's own ones.
-- Returns true when something moved and, when not all, the reason.
function M:TakeItem(ply, item, count)
	local from, slot = item.container, item.slot
	if from == nil then
		return false, "empty"
	end
	if count == nil or count <= 0 or count > item.count then
		count = item.count
	end
	local left = count
	local function try(c, toSlot)
		if left <= 0 or item.destroyed or item.container ~= from or c == from then
			return
		end
		local before = item.count
		if self:Transfer(from, slot, c, toSlot, left) then
			if item.destroyed or item.container ~= from then
				left = 0
			else
				left = left - (before - item.count)
			end
		end
	end
	local target, targetSlot = self.ctx.events:Query("inventory.place", ply, item, self.defs[item.id])
	if target ~= nil then
		try(target, targetSlot)
	end
	for _, c in ipairs(self:StoreOrder(ply)) do
		try(c, 0)
	end
	if left > 0 then
		return left < count, "full"
	end
	return true
end

-- Takes everything from a container a player has open. Returns true when something
-- moved and, when not all, the reason.
function M:TakeAll(ply, c)
	local any, reason = false, nil
	for slot = 1, c.size do
		local item = c.items[slot]
		if item ~= nil then
			local ok, why = self:TakeItem(ply, item, 0)
			any = any or ok
			if why ~= nil then
				reason = why
			end
		end
	end
	if not any then
		return false, reason or "empty"
	end
	if reason ~= nil then
		self:Fail(ply, reason)
	end
	return true
end

function M:_RegisterHandlers()
	self:HandleVerb("take", function(ply, item, _, count)
		local ok, reason = self:TakeItem(ply, item, count)
		if ok and reason ~= nil then
			self:Fail(ply, reason)
		end
		return ok, not ok and reason or nil
	end)
	self:HandleVerb("drop", function(ply, item, _, count)
		local ent = self:DropItem(ply, item, count)
		return ent ~= nil, ent == nil and "drop" or nil
	end)
	self:HandleVerb("split", function(_, item, c)
		local slot = c:FreeSlot()
		if slot == nil then
			return false, "full"
		end
		return self:Transfer(c, item.slot, c, slot, floor(item.count / 2))
	end)
	self:HandleVerb("open", function(ply, item)
		if item.sub == nil then
			return false, "verb"
		end
		return self:Open(ply, item.sub)
	end)
end

-- Console --------------------------------------------------------------------------------

function M:ItemsCommand(_, args)
	local filter = args[1]
	local lines = {}
	for _, id in ipairs(self.order) do
		local def = self.defs[id]
		if filter == nil or id:find(filter, 1, true) or def.category == filter then
			lines[#lines + 1] = format("  %-24s %-8s %6.2f kg  stack %-5d size %d  %s", id, def.category, def.weight,
				def.stack, def.size, self:Name(id))
		end
	end
	table.insert(lines, 1, format("items: %d of %d", #lines, #self.order))
	return lines
end

function M:_Describe(c, indent)
	local lines = { format("%s%s #%d: %d/%d slots, %.1f%s kg", indent, c.kind, c.id, c.size - #self:_Free(c), c.size,
		self:ContainerWeight(c), c.maxWeight ~= nil and format("/%.1f", c.maxWeight) or "") }
	for slot = 1, c.size do
		local item = c.items[slot]
		if item ~= nil then
			local name = c.slotNames ~= nil and c.slotNames[slot] or tostring(slot)
			local state = {}
			for key, value in pairs(item.state) do
				state[#state + 1] = key .. "=" .. tostring(value)
			end
			sort(state)
			lines[#lines + 1] = format("%s  %s: %s x%d%s", indent, name, item.id, item.count,
				#state > 0 and " (" .. concat(state, ", ") .. ")" or "")
			if item.sub ~= nil then
				for _, line in ipairs(self:_Describe(item.sub, indent .. "    ")) do
					lines[#lines + 1] = line
				end
			end
		end
	end
	return lines
end

function M:_Free(c)
	local free = {}
	for slot = 1, c.size do
		if c.items[slot] == nil then
			free[#free + 1] = slot
		end
	end
	return free
end

function M:InventoryCommand(caller, args)
	local ply = caller
	if args[1] ~= nil then
		local found, problem = self.players:Find(args[1], caller)
		if found == nil then
			return problem
		end
		ply = found
	end
	if not IsValid(ply) then
		return "nc_inv <player>"
	end
	local lines = { format("%s carries %.1f kg", ply:Nick(), self:Load(ply)) }
	for _, c in ipairs(self:Owned(ply)) do
		for _, line in ipairs(self:_Describe(c, "  ")) do
			lines[#lines + 1] = line
		end
	end
	return lines
end

function M:GiveCommand(caller, args)
	if args[1] == nil or args[2] == nil then
		return "nc_item <player> <id> [count]"
	end
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return problem
	end
	if self.defs[args[2]] == nil then
		return "unknown item " .. args[2] .. " (nc_items)"
	end
	local given, reason = self:Give(ply, args[2], tonumber(args[3]) or 1, nil, { drop = true })
	return format("%s got %d of %s%s", ply:Nick(), given, args[2], reason ~= nil and " (" .. reason .. ")" or "")
end
