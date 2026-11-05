-- Doors, server part: property, locks, the settings of the map, lockpicks and rams.
--
-- Property: while a mode answers the question doors.property with true (the city), a
-- player buys a door that is for sale for config.price (economy:Charge; the reduction
-- doors.price may change it), up to config.limit doors. The owner sells it back for
-- config.refund of what he paid, gives keys to up to config.coowners co-owners and titles
-- it; the owner and the co-owners lock and unlock it. A player who leaves loses his doors.
--
-- Keys: the use key with the walk key (Alt + E) on a door locks or unlocks it for a player
-- who holds its keys (doors:HasKeys). The use key on a locked door he has no keys to
-- starts picking the lock with a lockpick (an item with the trait lockpick = { time }) or,
-- without one, breaking the door in with a battering ram (the trait ram = { time }): the
-- door is unlocked (and thrown open by the ram).
--
-- The map: the admin gives a door to a group (nc_doormap group police: its members hold
-- the keys, nobody buys it), titles it or keeps it off the market; kept per map in storage
-- (namespace doors, key: the map, doors by MapCreationID) and put back after a cleanup.
--
--   doors:Buy(ply, door)            -> true, price or false, reason
--   doors:Sell(ply, door)           -> true, refund or false, reason
--   doors:Lock(ply, door, locked)   -> true or false, reason (ply nil: the server itself)
--   doors:AddCoowner(ply, door, target), doors:RemoveCoowner(ply, door, target)
--   doors:SetTitle(ply, door, text) -> true or false, reason
--   doors:Release(door), doors:ReleaseAll(), doors:Owned(ply) -> his doors, doors:All()
--   doors:Aimed(ply)                -> the door in front within config.range, or nil
--   doors:BeginPick(ply, door), doors:BeginRam(ply, door) -> ok, reason
--   doors:SetMap(door, field, value) -> the settings of the map: group, title, closed
--   doors:Request(ply, op, door, arg) -> an operation a player asked for; he learns why not
-- Reasons: door, closed, yours, owned, sale, limit, denied, funds, owner, keys, target,
-- already, full, long, chars, tool, unlocked, map.
--
-- Asks:     doors.property (ply, door) -> true, doors.canBuy (ply, door) -> false,
--           doors.price (price, ply, door) -> price, doors.canPick (ply, door) -> false,
--           doors.canRam (ply, door) -> false, doors.member (ply, group) -> true.
-- Listens:  gm.InitPostEntity, gm.PostCleanupMap (the settings of the map), gm.KeyPress,
--           players.left, net door.
-- Emits:    doors.bought (ply, door, price), doors.sold (ply, door, refund),
--           doors.locked (ply, door, locked), doors.picked (ply, door), doors.rammed (ply, door).
-- Commands: nc_door [buy | sell | lock | unlock | add <player> | remove <player> |
--           title <text>] (everybody, the door in front), nc_doormap [group <name> |
--           title <text> | closed yes|no | release | list] (admin).

local M = NC.Module("doors")

local IsValid = IsValid
local ipairs = ipairs
local pairs = pairs
local next = next
local tostring = tostring
local tonumber = tonumber
local floor = math.floor
local max = math.max
local format = string.format
local concat = table.concat
local sort = table.sort

local EMPTY = {}
local MAX_TITLE = 48
local BAD_CHARS = "[%c<>\"\\]"

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.economy = ctx:Require("economy")
	self.inventory = ctx:Require("inventory")
	self.actions = ctx:Require("actions")
	self.notices = ctx:Require("notices")
	self.storage = ctx:Require("storage")
	self.store = self.storage ~= nil and self.storage:Open("doors") or nil
	self.memory = {}  -- the settings of maps without storage: map -> { [id] = settings }
	self.owned = {}   -- ply -> { [door] = true }
	self.owners = {}  -- door -> the player who owns it
	self.paid = {}    -- door -> what its owner paid
	self.titles = {}  -- door -> the title its owner gave it
end

function M:_StartServer(ctx)
	ctx:On("gm.InitPostEntity", "ApplyMap")
	ctx:On("gm.PostCleanupMap", "OnCleanup")
	ctx:On("gm.KeyPress", "OnKeyPress")
	ctx:On("players.left", "OnLeft")
	ctx.net:Receive("door", "OnDoorRequest")
	ctx.commands:Add("nc_door", { admin = false,
		help = "[buy | sell | lock | unlock | add <player> | remove <player> | title <text>] - the door in front" },
		"DoorCommand")
	ctx.commands:Add("nc_doormap", {
		help = "[group <name|none> | title <text|none> | closed yes|no | release | list] - doors of the map" },
		"MapCommand")
	self:ApplyMap()
end

-- Every door of the map.
function M:All()
	local out = {}
	for _, class in ipairs(self.ctx.config.classes) do
		for _, ent in ipairs(ents.FindByClass(class)) do
			out[#out + 1] = ent
		end
	end
	sort(out, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return out
end

-- The door in front of a player within config.range, or nil.
function M:Aimed(ply)
	local eye = ply:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * self.ctx.config.range,
		filter = ply, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	return self:IsDoor(ent) and ent or nil
end

-- Whether a player is close enough to a door to handle it from its menu.
function M:Near(ply, door)
	return ply:GetShootPos():Distance(door:WorldSpaceCenter()) <= self.ctx.config.range * 2
end

-- The component of a door, made when `create` and it has none.
function M:_Data(door, create)
	local comp = self.ctx.components.door
	local data = comp:Get(door)
	if data == nil and create then
		data = comp:Add(door)
	end
	return data
end

-- A door with nothing on it loses its component.
function M:_Tidy(door)
	local data = self.ctx.components.door:Get(door)
	if data ~= nil and data.owner == 0 and data.coowners[1] == nil and data.title == "" and data.group == ""
		and not data.locked and not data.closed then
		self.ctx.components.door:Remove(door)
	end
end

-- Whether a door is locked: as the module left it, or as the map did.
function M:IsLocked(door)
	local data = self:Info(door)
	if data ~= nil then
		return data.locked
	end
	return door:GetInternalVariable("m_bLocked") == true
end

function M:_Lock(door, locked)
	door:Fire(locked and "Lock" or "Unlock")
	door:EmitSound(locked and "doors/door_latch3.wav" or "doors/door_latch1.wav")
	local data = self:_Data(door, locked)
	if data ~= nil then
		self.ctx.components.door:Set(door, "locked", locked)
		self:_Tidy(door)
	end
end

-- The settings of the map ---------------------------------------------------------------

local function idOf(door)
	local id = door:MapCreationID()
	if id == nil or id < 0 then
		return nil
	end
	return tostring(id)
end

function M:_Settings(create)
	local map = game.GetMap()
	local all
	if self.store ~= nil then
		all = self.store:Get(map)
		if all == nil and create then
			all = {}
			self.store:Set(map, all)
		end
	else
		all = self.memory[map]
		if all == nil and create then
			all = {}
			self.memory[map] = all
		end
	end
	return all
end

-- The settings of the map for a door: { group, title, closed }, or nil.
function M:MapSettings(door)
	local id = idOf(door)
	local all = id ~= nil and self:_Settings(false) or nil
	return all ~= nil and all[id] or nil
end

-- Changes a setting of the map for a door: group (a name or nil), title (text or nil),
-- closed (true or nil). true, or false and "map" for a door the map did not make.
function M:SetMap(door, field, value)
	local id = idOf(door)
	if id == nil then
		return false, "map"
	end
	if value == "" or value == false then
		value = nil
	end
	local all = self:_Settings(true)
	local entry = all[id] or {}
	entry[field] = value
	all[id] = next(entry) ~= nil and entry or nil
	if self.store ~= nil then
		self.store:Touch()
	end
	self:_Apply(door)
	return true
end

-- Puts the settings of the map on a door; a door of a group is nobody's.
function M:_Apply(door)
	local settings = self:MapSettings(door) or EMPTY
	local comp = self.ctx.components.door
	if settings.group ~= nil then
		self:Release(door)
	end
	local data = self:_Data(door, next(settings) ~= nil)
	if data == nil then
		return
	end
	comp:Set(door, "group", settings.group or "")
	comp:Set(door, "closed", settings.closed == true)
	if self.titles[door] == nil then
		comp:Set(door, "title", settings.title or "")
	end
	self:_Tidy(door)
end

function M:ApplyMap()
	for _, door in ipairs(self:All()) do
		self:_Apply(door)
	end
end

-- After a cleanup the doors are new entities: nobody owns them, the map settings return.
function M:OnCleanup()
	self.owned, self.owners, self.paid, self.titles = {}, {}, {}, {}
	self:ApplyMap()
end

-- Property ------------------------------------------------------------------------------

-- What a door costs a player now.
function M:Price(ply, door)
	local price = self.ctx.events:Reduce("doors.price", self.ctx.config.price, ply, door)
	return max(0, floor(tonumber(price) or 0))
end

-- The doors a player owns, by entity index.
function M:Owned(ply)
	local out = {}
	for door in pairs(self.owned[ply] or EMPTY) do
		if IsValid(door) and self:Owner(door) == ply then
			out[#out + 1] = door
		end
	end
	sort(out, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return out
end

function M:Buy(ply, door)
	if not self:IsDoor(door) then
		return false, "door"
	end
	local events = self.ctx.events
	if events:Query("doors.property", ply, door) ~= true then
		return false, "closed"
	end
	local owner = self:Owner(door)
	if owner ~= nil then
		return false, owner == ply and "yours" or "owned"
	end
	if not self:ForSale(door) then
		return false, "sale"
	end
	local limit = self.ctx.config.limit
	if limit > 0 and #self:Owned(ply) >= limit then
		return false, "limit"
	end
	if events:Query("doors.canBuy", ply, door) == false then
		return false, "denied"
	end
	local price = self.economy ~= nil and self:Price(ply, door) or 0
	if price > 0 then
		local ok, reason = self.economy:Charge(ply, price, "doors.buy")
		if not ok then
			return false, reason
		end
	end
	self:_Data(door, true)
	self.ctx.components.door:Set(door, "owner", ply:EntIndex())
	self.owners[door] = ply
	local set = self.owned[ply] or {}
	self.owned[ply] = set
	set[door] = true
	self.paid[door] = price
	events:Emit("doors.bought", ply, door, price)
	return true, price
end

function M:Sell(ply, door)
	if not self:IsDoor(door) then
		return false, "door"
	end
	if self:Owner(door) ~= ply then
		return false, "owner"
	end
	local refund = floor((self.paid[door] or 0) * self.ctx.config.refund)
	self:Release(door)
	if refund > 0 and self.economy ~= nil then
		self.economy:Pay(ply, refund, "doors.sell")
	end
	self.ctx.events:Emit("doors.sold", ply, door, refund)
	return true, refund
end

-- The door goes back to the market: no owner, no co-owners, no title of an owner, unlocked.
function M:Release(door)
	local data = self:Info(door)
	if data == nil then
		return
	end
	local owner = self.owners[door]
	if owner ~= nil and self.owned[owner] ~= nil then
		self.owned[owner][door] = nil
	end
	self.owners[door], self.paid[door] = nil, nil
	if data.owner == 0 and data.coowners[1] == nil then
		return
	end
	local comp = self.ctx.components.door
	comp:Set(door, "owner", 0)
	comp:Set(door, "coowners", {})
	if self.titles[door] ~= nil then
		self.titles[door] = nil
		comp:Set(door, "title", (self:MapSettings(door) or EMPTY).title or "")
	end
	if data.locked then
		self:_Lock(door, false)
	end
	self:_Tidy(door)
end

-- Every door goes back to the market (the end of the city).
function M:ReleaseAll()
	for _, door in ipairs(self:All()) do
		self:Release(door)
	end
	self.owned, self.owners, self.paid = {}, {}, {}
end

function M:Lock(ply, door, locked)
	if not self:IsDoor(door) then
		return false, "door"
	end
	if ply ~= nil and not self:HasKeys(ply, door) then
		return false, "keys"
	end
	locked = locked ~= false
	self:_Lock(door, locked)
	self.ctx.events:Emit("doors.locked", ply, door, locked)
	return true
end

function M:AddCoowner(ply, door, target)
	if not self:IsDoor(door) then
		return false, "door"
	end
	if self:Owner(door) ~= ply then
		return false, "owner"
	end
	if target == nil or not IsValid(target) or not target:IsPlayer() or target == ply then
		return false, "target"
	end
	if self:IsCoowner(target, door) then
		return false, "already"
	end
	local list = self:Info(door).coowners
	if #list >= self.ctx.config.coowners then
		return false, "full"
	end
	local out = {}
	for i, other in ipairs(list) do
		out[i] = other
	end
	out[#out + 1] = target:EntIndex()
	self.ctx.components.door:Set(door, "coowners", out)
	return true
end

-- The owner takes the keys from a co-owner, or a co-owner gives them back.
function M:RemoveCoowner(ply, door, target)
	if not self:IsDoor(door) then
		return false, "door"
	end
	if self:Owner(door) ~= ply and not (ply == target and self:IsCoowner(ply, door)) then
		return false, "owner"
	end
	if not self:IsCoowner(target, door) then
		return false, "target"
	end
	local out, index = {}, target:EntIndex()
	for _, other in ipairs(self:Info(door).coowners) do
		if other ~= index then
			out[#out + 1] = other
		end
	end
	self.ctx.components.door:Set(door, "coowners", out)
	return true
end

function M.CleanTitle(text)
	return (tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- The owner titles his door; an empty title brings back the title of the map.
function M:SetTitle(ply, door, text)
	if not self:IsDoor(door) then
		return false, "door"
	end
	if self:Owner(door) ~= ply then
		return false, "owner"
	end
	text = M.CleanTitle(text)
	if #text > MAX_TITLE then
		return false, "long"
	end
	if text:find(BAD_CHARS) then
		return false, "chars"
	end
	self.titles[door] = text ~= "" and text or nil
	if text == "" then
		text = (self:MapSettings(door) or EMPTY).title or ""
	end
	self.ctx.components.door:Set(door, "title", text)
	return true
end

-- A player leaves: his doors go back to the market, his keys to their owners.
function M:OnLeft(ply)
	for _, door in ipairs(self:Owned(ply)) do
		self:Release(door)
	end
	self.owned[ply] = nil
	local comp = self.ctx.components.door
	local keys, me = {}, ply:EntIndex()
	for index, data in comp:Each() do
		for _, other in ipairs(data.coowners) do
			if other == me then
				keys[#keys + 1] = index
			end
		end
	end
	for _, index in ipairs(keys) do
		local door = Entity(index)
		local out = {}
		for _, other in ipairs(comp:Get(index).coowners) do
			if other ~= me then
				out[#out + 1] = other
			end
		end
		comp:Set(index, "coowners", out)
		if IsValid(door) then
			self:_Tidy(door)
		end
	end
end

-- Lockpicks and rams --------------------------------------------------------------------

-- The first tool with trait `trait` (lockpick, ram) a player carries, and its item id.
function M:Tool(ply, trait)
	local inventory = self.inventory
	if inventory == nil then
		return nil
	end
	for _, id in ipairs(inventory:WithTrait(trait)) do
		if inventory:Count(ply, id) > 0 then
			return inventory:Trait(id, trait), id
		end
	end
	return nil
end

function M:_BeginForce(ply, door, trait, question, finish)
	local tool = self:Tool(ply, trait)
	if tool == nil or self.actions == nil then
		return false, "tool"
	end
	if not self:IsLocked(door) then
		return false, "unlocked"
	end
	if self.ctx.events:Query(question, ply, door) == false then
		return false, "denied"
	end
	return self.actions:Begin(ply, {
		id = "doors." .. trait, label = "doors.action." .. trait,
		duration = tool.time or self.ctx.config[trait == "lockpick" and "pick" or "ram"],
		target = door, range = self.ctx.config.range * 1.5,
		Check = function()
			if not IsValid(door) or not self:IsLocked(door) then
				return false, "target"
			end
			return true
		end,
		OnComplete = function()
			if self:Tool(ply, trait) ~= nil and IsValid(door) then
				finish(door)
			end
		end,
	})
end

-- Starts picking the lock of a door (the action of ply). ok, or false and the reason.
function M:BeginPick(ply, door)
	return self:_BeginForce(ply, door, "lockpick", "doors.canPick", function()
		self:_Lock(door, false)
		self.ctx.events:Emit("doors.picked", ply, door)
	end)
end

-- Starts breaking a door in with a ram (the action of ply). ok, or false and the reason.
function M:BeginRam(ply, door)
	return self:_BeginForce(ply, door, "ram", "doors.canRam", function()
		self:_Lock(door, false)
		door:Fire("Open")
		door:EmitSound("physics/wood/wood_crate_break3.wav")
		self.ctx.events:Emit("doors.rammed", ply, door)
	end)
end

function M:OnKeyPress(ply, key)
	if key ~= IN_USE or not self.players:IsAlive(ply) then
		return
	end
	local door = self:Aimed(ply)
	if door == nil then
		return
	end
	if ply:KeyDown(IN_WALK) then
		if self:HasKeys(ply, door) then
			self:Request(ply, self:IsLocked(door) and "unlock" or "lock", door)
		end
		return
	end
	if not self:IsLocked(door) or self:HasKeys(ply, door) or self.actions == nil or self.actions:IsBusy(ply) then
		return
	end
	local ok, reason
	if self:Tool(ply, "lockpick") ~= nil then
		ok, reason = self:BeginPick(ply, door)
	elseif self:Tool(ply, "ram") ~= nil then
		ok, reason = self:BeginRam(ply, door)
	else
		return
	end
	if not ok then
		self:_Tell(ply, "doors.fail." .. tostring(reason), nil, "bad")
	end
end

-- Requests ------------------------------------------------------------------------------

function M:_Tell(ply, key, params, kind)
	if self.notices ~= nil then
		self.notices:Send(ply, key, params, kind)
	end
end

local function money(self, amount)
	return self.economy ~= nil and self.economy:Format(amount) or tostring(amount)
end

-- An operation on a door a player asked for (buy, sell, lock, unlock, add, remove, title;
-- arg: the player or the title); he learns what happened. ok, and the reason or value.
function M:Request(ply, op, door, arg)
	local ok, value
	if op == "buy" then
		ok, value = self:Buy(ply, door)
		if ok then
			self:_Tell(ply, "doors.bought", { price = money(self, value) }, "good")
		end
	elseif op == "sell" then
		ok, value = self:Sell(ply, door)
		if ok then
			self:_Tell(ply, "doors.sold", { price = money(self, value) }, "good")
		end
	elseif op == "lock" or op == "unlock" then
		ok, value = self:Lock(ply, door, op == "lock")
		if ok then
			self:_Tell(ply, "doors." .. op .. "ed", nil, "info")
		end
	elseif op == "add" or op == "remove" then
		local fn = op == "add" and self.AddCoowner or self.RemoveCoowner
		ok, value = fn(self, ply, door, arg)
		if ok then
			self:_Tell(ply, "doors." .. op .. "ed", { who = self.players:Name(arg) }, "good")
		end
	elseif op == "title" then
		ok, value = self:SetTitle(ply, door, arg)
		if ok then
			self:_Tell(ply, "doors.titled", nil, "good")
		end
	else
		return false, "op"
	end
	if not ok then
		self:_Tell(ply, "doors.fail." .. tostring(value), { count = self.ctx.config[op == "buy" and "limit"
			or "coowners"] }, "bad")
	end
	return ok, value
end

function M:OnDoorRequest(data, ply)
	local door = data.door
	if not self:IsDoor(door) or not self.players:IsAlive(ply) or not self:Near(ply, door) then
		return
	end
	local arg = data.target
	if data.op == "title" then
		arg = data.title or ""
	end
	self:Request(ply, data.op, door, arg)
end

-- Commands ------------------------------------------------------------------------------

function M:_Describe(door)
	local info = self:Info(door) or EMPTY
	local owner = self:Owner(door)
	local parts = { format("door %d (map %d)", door:EntIndex(), door:MapCreationID()) }
	parts[#parts + 1] = owner ~= nil and "owner " .. owner:Nick() or (self:ForSale(door) and "for sale" or "not for sale")
	local names = {}
	for _, other in ipairs(self:Coowners(door)) do
		names[#names + 1] = other:Nick()
	end
	if names[1] ~= nil then
		parts[#parts + 1] = "co-owners " .. concat(names, ", ")
	end
	if (info.title or "") ~= "" then
		parts[#parts + 1] = format("title %q", info.title)
	end
	if (info.group or "") ~= "" then
		parts[#parts + 1] = "group " .. info.group
	end
	parts[#parts + 1] = self:IsLocked(door) and "locked" or "unlocked"
	return concat(parts, ", ")
end

local OPS = { buy = true, sell = true, lock = true, unlock = true, add = true, remove = true, title = true }

function M:DoorCommand(caller, args)
	if not IsValid(caller) then
		return "nc_door: run it in the game"
	end
	local door = self:Aimed(caller)
	if door == nil then
		return "nc_door: look at a door"
	end
	local op = args[1]
	if op == nil then
		return self:_Describe(door)
	end
	if not OPS[op] then
		return "nc_door [buy | sell | lock | unlock | add <player> | remove <player> | title <text>]"
	end
	local arg
	if op == "add" or op == "remove" then
		local problem
		arg, problem = self.players:Find(args[2] or "", caller)
		if arg == nil then
			return problem
		end
	elseif op == "title" then
		arg = concat(args, " ", 2)
	end
	local ok, value = self:Request(caller, op, door, arg)
	if not ok then
		return format("nc_door %s: %s", op, tostring(value))
	end
	return "nc_door " .. op .. ": done"
end

function M:MapCommand(caller, args)
	local op = args[1]
	if op == "list" or op == nil then
		local lines = {}
		for _, door in ipairs(self:All()) do
			if self:Info(door) ~= nil then
				lines[#lines + 1] = self:_Describe(door)
			end
		end
		lines[#lines + 1] = format("nc_doormap: %d doors on %s", #self:All(), game.GetMap())
		return lines
	end
	local door = IsValid(caller) and self:Aimed(caller) or nil
	if door == nil then
		return "nc_doormap: look at a door"
	end
	local ok, reason
	if op == "group" or op == "title" then
		local value = concat(args, " ", 2)
		if value == "none" then
			value = nil
		end
		if op == "title" and value ~= nil then
			value = M.CleanTitle(value):sub(1, MAX_TITLE)
		end
		ok, reason = self:SetMap(door, op, value)
	elseif op == "closed" then
		ok, reason = self:SetMap(door, "closed", args[2] == "yes" or args[2] == "1" or args[2] == "true")
	elseif op == "release" then
		self:Release(door)
		ok = true
	else
		return "nc_doormap [group <name|none> | title <text|none> | closed yes|no | release | list]"
	end
	if not ok then
		return "nc_doormap: " .. tostring(reason)
	end
	return self:_Describe(door)
end
