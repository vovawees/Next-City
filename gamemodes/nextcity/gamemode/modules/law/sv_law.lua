-- Law, server part: the wanted, warrants, arrests, the jail and searches.
--
-- The law is in force while a mode answers the question law.enabled with true (the city).
-- An officer (law.officer) or the authority (law.authority) wants a player for a reason
-- for config.wanted s, or calls the search off. The authority issues warrants for
-- config.warrant s (an officer does too while no authority is in the game). Everybody
-- learns of it in the chat.
--
-- Arrest: an officer who ties a wanted player up (restraints) arrests him at once; so do
-- nc_arrest and the menu for the wanted player he tied, within config.reach. The arrested
-- one is no longer wanted and sits config.jail s in the jail of the map: the admin sets
-- its points (nc_jails, kept per map in storage); without them he stays where he is, tied
-- up and barely moving. In jail he keeps empty hands, cannot attack, use, reload, handle
-- his inventory, tie anybody up, buy doors, pick locks or break doors in, and nobody
-- unties him. A death brings him back into the jail; leaving keeps the rest of his time
-- (storage) for his return. When the time is up, or an officer or the authority lets him
-- go, he walks out at a spawn point.
--
-- Searches: anybody within reach searches a tied up or jailed player (the question
-- law.canSearch): the containers of the searched one open for him.
-- Doors: an officer breaks in (doors.canRam) only the doors of the wanted, of those with a
-- warrant (owners and co-owners) and doors nobody owns or holds.
--
--   law:Want(by, ply, reason)          -> true or false, reason (by nil: the server, no checks
--                                        of who gives the order)
--   law:Unwant(by, ply), law:IssueWarrant(by, ply, reason)
--   law:Arrest(by, ply)                -> true or false, reason
--   law:Jail(by, ply, seconds)         -> true or false, reason (at once, no checks of by)
--   law:Release(by, ply)               -> true or false, reason
--   law:Search(by, ply)                -> true or false, reason
--   law:Amnesty()                      -> nobody is wanted, has a warrant or sits in jail
--   law:IsEnabled(), law:Authority()   -> the law is in force; a player who heads it, or nil
--   law:JailPoints(), law:AddJailPoint(pos, yaw), law:ClearJailPoints()
--   law:Do(by, op, target, reason)     -> an operation of the menu: want, unwant, warrant,
--                                        arrest, release, search
--   law:Request(ply, op, target, reason) -> the same asked by a player; he learns why not
-- Reasons: closed, officer, authority, target, reason, long, chars, wanted, warrant, none,
--          jailed, loose, far, free, denied, op.
--
-- Asks:     law.enabled () -> true, law.canSearch (ply, target) -> false.
-- Answers:  inventory.canMove, inventory.canAct, restraints.canTie, restraints.canUntie,
--           doors.canBuy, doors.canPick, doors.canRam, movement.speed.
-- Listens:  restraints.tied, players.spawned, players.left, net law.
-- Emits:    law.wanted (ply, by, reason), law.unwanted (ply, by), law.warrant (ply, by,
--           reason), law.jailed (ply, by, seconds), law.released (ply, by),
--           law.searched (ply, by).
-- Commands: nc_want <player> <reason>, nc_unwant <player>, nc_warrant <player> <reason>,
--           nc_arrest [player], nc_search [player], nc_release <player>, nc_wanted
--           (everybody); nc_jail <player> [seconds], nc_jails [add | clear | list] (admin).

local M = NC.Module("law")

local CurTime = CurTime
local IsValid = IsValid
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local type = type
local ceil = math.ceil
local floor = math.floor
local format = string.format
local concat = table.concat

local MAX_REASON = 96
local BAD_CHARS = "[%c<>\"\\]"
local RECORDS = { "wanted", "warrant", "jailed" }
local DONE = {
	want = "%s is wanted", unwant = "%s is no longer wanted", warrant = "a warrant for %s",
	arrest = "%s is in jail", release = "%s is free", search = "%s searched",
}

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.restraints = ctx:Require("restraints")
	self.inventory = ctx:Require("inventory")
	self.doors = ctx:Require("doors")
	self.actions = ctx:Require("actions")
	self.movement = ctx:Require("movement")
	self.notices = ctx:Require("notices")
	self.storage = ctx:Require("storage")
	self.jails = self.storage ~= nil and self.storage:Open("jails") or nil
	self.sentences = self.storage ~= nil and self.storage:Open("law") or nil
	self.memory = { jails = {}, sentences = {} } -- the same without storage
	self.placed = {}  -- ply -> true: he sits at a point of the jail (not tied up in place)
	self.checked = {} -- ply -> true: his time from an earlier visit was looked up
	self.cursor = 0   -- the last point of the jail somebody went to
end

function M:_StartServer(ctx)
	ctx.net:Receive("law", "OnLawRequest")
	ctx:On("restraints.tied", "OnTied")
	ctx:On("players.spawned", "OnSpawned", { priority = -20 })
	ctx:On("players.left", "OnLeft")
	ctx:On("inventory.canMove", "AnswerJailed")
	ctx:On("inventory.canAct", "AnswerJailed")
	ctx:On("restraints.canTie", "AnswerHold")
	ctx:On("restraints.canUntie", "AnswerHold")
	ctx:On("doors.canBuy", "AnswerJailed")
	ctx:On("doors.canPick", "AnswerJailed")
	ctx:On("doors.canRam", "AnswerRam")
	ctx:On("movement.speed", "OnSpeed")
	ctx:Every("check", 1, "Check")
	local commands = ctx.commands
	commands:Add("nc_want", { help = "<player> <reason> - want a player (the police)", admin = false },
		function(ply, args) return self:OrderCommand("want", ply, args) end)
	commands:Add("nc_unwant", { help = "<player> - call the search for a player off", admin = false },
		function(ply, args) return self:OrderCommand("unwant", ply, args) end)
	commands:Add("nc_warrant", { help = "<player> <reason> - a warrant for a player (the mayor)", admin = false },
		function(ply, args) return self:OrderCommand("warrant", ply, args) end)
	commands:Add("nc_release", { help = "<player> - let a player out of jail", admin = false },
		function(ply, args) return self:OrderCommand("release", ply, args) end)
	commands:Add("nc_arrest", { help = "[player] - arrest the wanted player you tied up", admin = false },
		function(ply, args) return self:OrderCommand("arrest", ply, args) end)
	commands:Add("nc_search", { help = "[player] - search the player in front, tied up or jailed",
		admin = false }, function(ply, args) return self:OrderCommand("search", ply, args) end)
	commands:Add("nc_wanted", { help = "- the wanted, the warrants and the jail", admin = false }, "WantedCommand")
	commands:Add("nc_jail", { help = "<player> [seconds] - put a player into jail at once" }, "JailCommand")
	commands:Add("nc_jails", { help = "[add | clear | list] - the points of the jail of this map" },
		"JailsCommand")
end

function M:IsEnabled()
	return self.ctx.events:Query("law.enabled") == true
end

-- A player who heads the law now, or nil.
function M:Authority()
	for _, ply in ipairs(player.GetAll()) do
		if self:IsAuthority(ply) then
			return ply
		end
	end
	return nil
end

local function isPlayer(ply)
	return ply ~= nil and IsValid(ply) and ply:IsPlayer()
end

local function clean(text)
	return (tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- The checks of an order of `by` about `ply`: a reason against it, or nil and the reason
-- of the order cleaned up (when `reason` is given).
function M:_Order(by, ply, reason, warrant)
	if not self:IsEnabled() then
		return "closed"
	end
	if not isPlayer(ply) or ply == by then
		return "target"
	end
	if by ~= nil then
		if warrant then
			if not self:IsAuthority(by) and not (self:IsOfficer(by) and self:Authority() == nil) then
				return self:IsOfficer(by) and "authority" or "officer"
			end
		elseif not self:IsOfficer(by) and not self:IsAuthority(by) then
			return "officer"
		end
	end
	if reason == nil then
		return nil
	end
	local text = clean(reason)
	if text == "" then
		return "reason"
	end
	if #text > MAX_REASON then
		return "long"
	end
	if text:find(BAD_CHARS) then
		return "chars"
	end
	return nil, text
end

function M:_Name(ply)
	return self.players:Name(ply)
end

function M:_Tell(ply, key, params, kind)
	if self.notices ~= nil and isPlayer(ply) then
		self.notices:Send(ply, key, params, kind)
	end
end

function M:_Announce(key, params, kind)
	if self.notices ~= nil then
		self.notices:Broadcast(key, params, kind, { chat = true })
	end
end

-- Wanted and warrants ------------------------------------------------------------------

function M:Want(by, ply, reason)
	local problem, text = self:_Order(by, ply, reason or "")
	if problem ~= nil then
		return false, problem
	end
	if self:IsJailed(ply) then
		return false, "jailed"
	end
	if self:IsWanted(ply) then
		return false, "wanted"
	end
	self.ctx.components.wanted:Add(ply, { ends = CurTime() + self.ctx.config.wanted, reason = text })
	self:_Announce("law.wanted", { who = self:_Name(ply), reason = text }, "warn")
	self.ctx.events:Emit("law.wanted", ply, by, text)
	return true
end

function M:Unwant(by, ply)
	if not isPlayer(ply) or not self:IsWanted(ply) then
		return false, "none"
	end
	if by ~= nil and not self:IsOfficer(by) and not self:IsAuthority(by) then
		return false, "officer"
	end
	self.ctx.components.wanted:Remove(ply)
	self:_Announce("law.unwanted", { who = self:_Name(ply) }, "info")
	self.ctx.events:Emit("law.unwanted", ply, by)
	return true
end

function M:IssueWarrant(by, ply, reason)
	local problem, text = self:_Order(by, ply, reason or "", true)
	if problem ~= nil then
		return false, problem
	end
	if self:HasWarrant(ply) then
		return false, "warrant"
	end
	self.ctx.components.warrant:Add(ply, { ends = CurTime() + self.ctx.config.warrant, reason = text })
	self:_Announce("law.warrant", { who = self:_Name(ply), reason = text }, "warn")
	self.ctx.events:Emit("law.warrant", ply, by, text)
	return true
end

-- Arrests and the jail -----------------------------------------------------------------

function M:_Near(by, ply)
	return by:GetShootPos():Distance(ply:WorldSpaceCenter()) <= self.ctx.config.reach
end

function M:Arrest(by, ply)
	local problem = self:_Order(by, ply)
	if problem ~= nil then
		return false, problem
	end
	if by ~= nil and not self:IsOfficer(by) then
		return false, "officer"
	end
	if not self.players:IsAlive(ply) then
		return false, "target"
	end
	if self:IsJailed(ply) then
		return false, "jailed"
	end
	if by ~= nil then
		if not self:IsWanted(ply) then
			return false, "none"
		end
		if self.restraints ~= nil and not self.restraints:IsTied(ply) then
			return false, "loose"
		end
		if not self:_Near(by, ply) then
			return false, "far"
		end
	end
	return self:Jail(by, ply, self.ctx.config.jail)
end

-- An officer tied a wanted player up: the arrest.
function M:OnTied(ply, by)
	if isPlayer(by) and self:IsOfficer(by) and self:IsWanted(ply) and not self:IsJailed(ply) and self:IsEnabled() then
		self:Jail(by, ply, self.ctx.config.jail)
	end
end

function M:Jail(by, ply, seconds)
	if not self:IsEnabled() then
		return false, "closed"
	end
	if not isPlayer(ply) then
		return false, "target"
	end
	if self:IsJailed(ply) then
		return false, "jailed"
	end
	seconds = seconds or self.ctx.config.jail
	self.checked[ply] = true
	self.ctx.components.wanted:Remove(ply)
	self.ctx.components.jailed:Add(ply, { ends = CurTime() + seconds })
	if self.players:IsAlive(ply) then
		self:_Lock(ply)
	end
	self:_Announce("law.jailed", { who = self:_Name(ply), time = M.Clock(seconds) }, "warn")
	self.ctx.events:Emit("law.jailed", ply, by, seconds)
	return true
end

local function mapKey()
	return game.GetMap()
end

-- The points of the jail of this map: { { pos = Vector, ang = Angle } } (a new list).
function M:JailPoints()
	local list
	if self.jails ~= nil then
		list = self.jails:Get(mapKey())
	else
		list = self.memory.jails[mapKey()]
	end
	local out = {}
	for _, p in ipairs(type(list) == "table" and list or {}) do
		out[#out + 1] = { pos = Vector(p.x, p.y, p.z), ang = Angle(0, p.yaw or 0, 0) }
	end
	return out
end

local function setPoints(self, list)
	if self.jails ~= nil then
		self.jails:Set(mapKey(), list[1] ~= nil and list or nil)
	else
		self.memory.jails[mapKey()] = list[1] ~= nil and list or nil
	end
end

-- Adds a point of the jail of this map (kept in storage). Returns how many there are.
function M:AddJailPoint(pos, yaw)
	local list = {}
	for _, p in ipairs(self:JailPoints()) do
		list[#list + 1] = { x = p.pos.x, y = p.pos.y, z = p.pos.z, yaw = p.ang.y }
	end
	list[#list + 1] = { x = floor(pos.x + 0.5), y = floor(pos.y + 0.5), z = floor(pos.z + 0.5),
		yaw = floor((yaw or 0) + 0.5) }
	setPoints(self, list)
	return #list
end

function M:ClearJailPoints()
	setPoints(self, {})
end

-- Puts a living jailed player into the jail: the next point, or tied up where he is.
function M:_Lock(ply)
	if self.actions ~= nil then
		self.actions:Cancel(ply, "cancelled")
	end
	local points = self:JailPoints()
	local restraints = self.restraints
	if points[1] ~= nil then
		self.cursor = self.cursor % #points + 1
		local point = points[self.cursor]
		if restraints ~= nil then
			restraints:Untie(ply, nil, true)
		end
		ply:SetPos(point.pos)
		ply:SetEyeAngles(point.ang)
		self.placed[ply] = true
	else
		self.placed[ply] = nil
		if restraints ~= nil and not restraints:IsTied(ply) then
			restraints:Tie(ply, nil)
		end
	end
	local hands = self.hands
	if hands ~= nil and ply:HasWeapon(hands.CLASS) then
		ply:SelectWeapon(hands.CLASS)
	end
	self:_Refresh(ply)
end

function M:_Refresh(ply)
	if self.movement ~= nil and IsValid(ply) then
		self.movement:Refresh(ply)
	end
end

-- Out of jail: from a point of the jail to a spawn point, or untied where he sits.
function M:_Free(ply)
	self.ctx.components.jailed:Remove(ply)
	local placed = self.placed[ply]
	self.placed[ply] = nil
	if not self.players:IsAlive(ply) then
		return
	end
	if placed then
		local point, spot = self.players:PickSpawn(ply, self.players:SpawnPoints("any"))
		if spot ~= nil then
			ply:SetPos(spot)
		elseif point ~= nil then
			ply:SetPos(point:GetPos())
			ply:SetEyeAngles(point:GetAngles())
		end
	elseif self.restraints ~= nil then
		self.restraints:Untie(ply, nil, true)
	end
	self:_Refresh(ply)
end

function M:Release(by, ply)
	if not isPlayer(ply) or not self:IsJailed(ply) then
		return false, "free"
	end
	if by ~= nil and not self:IsOfficer(by) and not self:IsAuthority(by) then
		return false, "officer"
	end
	self:_Free(ply)
	self:_Announce("law.released", { who = self:_Name(ply) }, "good")
	self.ctx.events:Emit("law.released", ply, by)
	return true
end

-- Records that ran out: the search ends, the warrant goes, the jailed walk out.
function M:Check()
	local now = CurTime()
	local comps = self.ctx.components
	for _, name in ipairs(RECORDS) do
		local due = {}
		for index, data in comps[name]:Each() do
			if data.ends <= now then
				due[#due + 1] = index
			end
		end
		for _, index in ipairs(due) do
			local ply = Entity(index)
			if not IsValid(ply) then
				comps[name]:Remove(index)
			elseif name == "wanted" then
				self:Unwant(nil, ply)
			elseif name == "warrant" then
				comps.warrant:Remove(ply)
			else
				self:Release(nil, ply)
			end
		end
	end
end

-- The end of the law (the end of the city): every record goes, the jailed walk out.
function M:Amnesty()
	local comps = self.ctx.components
	comps.wanted:Clear()
	comps.warrant:Clear()
	local jailed = {}
	for index in comps.jailed:Each() do
		jailed[#jailed + 1] = index
	end
	for _, index in ipairs(jailed) do
		local ply = Entity(index)
		if IsValid(ply) then
			self:_Free(ply)
			self.ctx.events:Emit("law.released", ply, nil)
		else
			comps.jailed:Remove(index)
		end
	end
	if self.sentences ~= nil then
		for _, key in ipairs(self.sentences:Keys()) do
			self.sentences:Delete(key)
		end
	end
	self.memory.sentences = {}
	self.placed, self.checked = {}, {}
end

-- Time in jail across visits ------------------------------------------------------------

function M:_Key(ply)
	if self.storage ~= nil then
		return self.storage:PlayerKey(ply)
	end
	return ply:IsBot() and "bot_" .. ply:Nick() or ply:SteamID64()
end

-- The rest of the time of a player who left in jail, taken out of the store (or nil).
function M:_TakeSentence(ply)
	local key = self:_Key(ply)
	local record
	if self.sentences ~= nil then
		record = self.sentences:Get(key)
		self.sentences:Delete(key)
	else
		record = self.memory.sentences[key]
		self.memory.sentences[key] = nil
	end
	local left = type(record) == "table" and tonumber(record.jail) or nil
	return left ~= nil and left > 0 and left or nil
end

function M:OnLeft(ply)
	if self:IsJailed(ply) then
		local left = ceil(self:JailLeft(ply))
		if left > 0 then
			local record = { jail = left }
			if self.sentences ~= nil then
				self.sentences:Set(self:_Key(ply), record)
			else
				self.memory.sentences[self:_Key(ply)] = record
			end
		end
		self.ctx.components.jailed:Remove(ply)
	end
	self.placed[ply], self.checked[ply] = nil, nil
end

-- A jailed player comes back to life in the jail; one who left in jail goes back into it.
function M:OnSpawned(ply)
	if self:IsJailed(ply) then
		self:_Lock(ply)
		return
	end
	if self.checked[ply] or not self:IsEnabled() then
		return
	end
	self.checked[ply] = true
	local left = self:_TakeSentence(ply)
	if left ~= nil then
		self:Jail(nil, ply, left)
	end
end

-- Searches ------------------------------------------------------------------------------

function M:Search(by, ply)
	if not self:IsEnabled() then
		return false, "closed"
	end
	if not isPlayer(ply) or ply == by or not self.players:IsAlive(ply) then
		return false, "target"
	end
	local inventory = self.inventory
	if inventory == nil or self:IsJailed(by) then
		return false, "denied"
	end
	if not self:IsJailed(ply) and not (self.restraints ~= nil and self.restraints:IsTied(ply)) then
		return false, "loose"
	end
	if self.ctx.events:Query("law.canSearch", by, ply) == false then
		return false, "denied"
	end
	for _, c in ipairs(inventory:Owned(ply)) do
		local ok, why = inventory:Open(by, c)
		if not ok then
			return false, why == "reach" and "far" or "denied"
		end
	end
	self:_Tell(ply, "law.searched", { who = self:_Name(by) }, "warn")
	self.ctx.events:Emit("law.searched", ply, by)
	return true
end

-- Answers -------------------------------------------------------------------------------

function M:AnswerJailed(ply)
	if self:IsJailed(ply) then
		return false
	end
	return nil
end

-- A jailed player ties nobody up and unties nobody; nobody ties or unties him.
function M:AnswerHold(ply, target)
	if self:IsJailed(ply) or self:IsJailed(target) then
		return false
	end
	return nil
end

local function suspect(self, ply)
	return ply ~= nil and (self:IsWanted(ply) or self:HasWarrant(ply))
end

-- Officers break into the doors of the wanted and of those with a warrant only.
function M:AnswerRam(ply, door)
	if self:IsJailed(ply) then
		return false
	end
	local doors = self.doors
	if doors == nil or not self:IsOfficer(ply) then
		return nil
	end
	local owner = doors:Owner(door)
	if owner == nil then
		return doors:Group(door) ~= nil and false or nil
	end
	if suspect(self, owner) then
		return nil
	end
	for _, other in ipairs(doors:Coowners(door)) do
		if suspect(self, other) then
			return nil
		end
	end
	return false
end

function M:OnSpeed(factor, ply)
	if self:IsJailed(ply) and not self.placed[ply] then
		return factor * self.ctx.config.speed
	end
	return factor
end

-- Requests ------------------------------------------------------------------------------

function M:Do(by, op, target, reason)
	if op == "want" then
		return self:Want(by, target, reason)
	elseif op == "unwant" then
		return self:Unwant(by, target)
	elseif op == "warrant" then
		return self:IssueWarrant(by, target, reason)
	elseif op == "arrest" then
		return self:Arrest(by, target)
	elseif op == "release" then
		return self:Release(by, target)
	elseif op == "search" then
		return self:Search(by, target)
	end
	return false, "op"
end

function M:Request(ply, op, target, reason)
	local ok, value = self:Do(ply, op, target, reason)
	if not ok then
		self:_Tell(ply, "law.fail." .. tostring(value), nil, "bad")
	end
	return ok, value
end

function M:OnLawRequest(data, ply)
	if isPlayer(data.target) then
		self:Request(ply, data.op, data.target, data.reason)
	end
end

-- Commands ------------------------------------------------------------------------------

-- nc_want, nc_unwant, nc_warrant, nc_release <player> [reason]; nc_arrest, nc_search
-- [player] (the player in front without one).
function M:OrderCommand(op, caller, args)
	local name = "nc_" .. op
	local target, problem
	if args[1] ~= nil then
		target, problem = self.players:Find(args[1], nil)
	elseif (op == "arrest" or op == "search") and IsValid(caller) and self.restraints ~= nil then
		target = self.restraints:Aimed(caller)
		problem = "nobody in front"
	else
		problem = (op == "want" or op == "warrant") and "<player> <reason>" or "<player>"
		return name .. " " .. problem
	end
	if target == nil then
		return name .. ": " .. tostring(problem)
	end
	local by = IsValid(caller) and caller or nil
	local reason = (op == "want" or op == "warrant") and concat(args, " ", 2) or nil
	local ok, value
	if by ~= nil then
		ok, value = self:Request(by, op, target, reason)
	else
		ok, value = self:Do(nil, op, target, reason)
	end
	if not ok then
		return name .. ": " .. tostring(value)
	end
	return name .. ": " .. format(DONE[op], target:Nick())
end

function M:WantedCommand()
	local lines = {}
	local comps = self.ctx.components
	for _, name in ipairs(RECORDS) do
		for index, data in comps[name]:Each() do
			local ply = Entity(index)
			if IsValid(ply) then
				local reason = data.reason ~= nil and "  " .. data.reason or ""
				lines[#lines + 1] = format("%-8s %-16s %s%s", name, ply:Nick(), M.Clock(self:Left(data)), reason)
			end
		end
	end
	if lines[1] == nil then
		return "nc_wanted: nobody is wanted, has a warrant or sits in jail"
	end
	return lines
end

function M:JailCommand(caller, args)
	if args[1] == nil then
		return "nc_jail <player> [seconds]"
	end
	local ply, problem = self.players:Find(args[1], nil)
	if ply == nil then
		return "nc_jail: " .. problem
	end
	local seconds = tonumber(args[2] or "") or self.ctx.config.jail
	if seconds < 1 or seconds > 86400 then
		return "nc_jail: from 1 to 86400 seconds"
	end
	local ok, reason = self:Jail(IsValid(caller) and caller or nil, ply, seconds)
	if not ok then
		return "nc_jail: " .. reason
	end
	return format("nc_jail: %s is in jail for %s", ply:Nick(), M.Clock(seconds))
end

function M:JailsCommand(caller, args)
	local op = args[1] or "list"
	if op == "add" then
		if not IsValid(caller) then
			return "nc_jails add: in the game only"
		end
		local count = self:AddJailPoint(caller:GetPos(), caller:EyeAngles().y)
		local pos = caller:GetPos()
		return format("nc_jails: point %d at %d %d %d", count, floor(pos.x + 0.5), floor(pos.y + 0.5),
			floor(pos.z + 0.5))
	elseif op == "clear" then
		self:ClearJailPoints()
		return "nc_jails: no points on " .. mapKey()
	elseif op ~= "list" then
		return "nc_jails [add | clear | list]"
	end
	local points = self:JailPoints()
	local lines = { format("nc_jails: %d points on %s", #points, mapKey()) }
	for i, p in ipairs(points) do
		lines[#lines + 1] = format("%d: %d %d %d, yaw %d", i, p.pos.x, p.pos.y, p.pos.z, p.ang.y)
	end
	return lines
end
