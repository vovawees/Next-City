-- NPCs, server part.
--
--   npcs:RegisterKind("combine", {
--   	class = "npc_combine_s",                    -- an engine class npc_*
--   	weapons = { "weapon_smg1", "weapon_ar2" },  -- one of them at random (none: what the class has)
--   	health = 80,                                -- else the health of the class
--   	proficiency = "good",                       -- poor, average, good, very_good or perfect
--   	model = "models/combine_super_soldier.mdl", skin = 1,
--   	keyvalues = { tacticalvariant = 1 }, spawnflags = 256,
--   	hostile = true,                             -- hates players whatever its class (default)
--   })
--   npcs:RegisterGroup("combine", { { kind = "combine", weight = 3 }, { kind = "manhack", weight = 1 } })
--   npcs:Kind(id) / Group(id) / Kinds() / Groups() / Roll(groupId) -> a kind of the group by weight
--   npcs:Spawn(kindId, pos, opts)        -> ent, or nil and the problem; opts: tag, yaw, hunt (true)
--   npcs:SpawnGroup(groupId, count, opts) -> how many appeared at Spots (not over config maxAlive)
--   npcs:Adopt(tag, opts)                -> how many creatures of the map are counted under tag now
--                                           (not of config ignore; opts.hunt: they hunt as well)
--   npcs:Count(tag) / List(tag) / TagOf(ent) / Clear(tag)   creatures of the module (tag nil: all)
--   npcs:Spots(count)                    -> positions for count creatures: the points of the map
--                                           (else the player spawns of side b) far from the living
--   npcs:AddPoint(pos, yaw) / RemovePoint(index) / Points() / Nearest(pos, radius)
--
-- Creatures of one tag do not fight each other. Every config hunt s a hunting one without an
-- enemy runs to the nearest living player (and remembers him as an enemy).
-- Emits:    npcs.spawned (ent, kind, tag), npcs.killed (ent, attacker, inflictor, tag, kind),
--           npcs.removed (ent, tag) — one that is gone without dying (a cleanup, an admin).
-- Listens:  gm.OnNPCKilled, gm.EntityRemoved.
-- Commands: nc_npcs (admin): add | remove [radius] | list | spawn <kind | group> [count] | clear | kinds.

local M = NC.Module("npcs")

local IsValid = IsValid
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local floor = math.floor
local ceil = math.ceil
local max = math.max
local min = math.min
local huge = math.huge
local format = string.format
local concat = table.concat
local sort = table.sort

local ID = "^[a-z][a-z0-9_]*$"
local SKILLS = { "poor", "average", "good", "very_good", "perfect" }

local HULL_MINS = Vector(-16, -16, 0)
local HULL_MAXS = Vector(16, 16, 72)
local LIFT = Vector(0, 0, 8)

-- Spots around a point: four rings of eight directions.
local RING = {}
for ring = 1, 4 do
	for step = 0, 7 do
		local angle = step * math.pi / 4 + (ring % 2) * math.pi / 8
		RING[#RING + 1] = { math.cos(angle) * 48 * ring, math.sin(angle) * 48 * ring }
	end
end

M.Random = math.random -- () -> [0, 1), (n) -> 1..n; specs replace it

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.storage = ctx:Require("storage")
	self.kinds = {}   -- id -> kind
	self.groups = {}  -- id -> { id, entries = { { kind, weight } }, total }
	self.tracked = {} -- ent -> { kind, tag, hunt }
	self.warned = {}
	self.store = self.storage ~= nil and self.storage:Open("npcs") or nil
	self.memory = {}  -- points without storage: map -> list
	self.skills = {
		poor = WEAPON_PROFICIENCY_POOR, average = WEAPON_PROFICIENCY_AVERAGE, good = WEAPON_PROFICIENCY_GOOD,
		very_good = WEAPON_PROFICIENCY_VERY_GOOD, perfect = WEAPON_PROFICIENCY_PERFECT,
	}
end

function M:Start(ctx)
	ctx:On("gm.OnNPCKilled", "OnKilled")
	ctx:On("gm.EntityRemoved", "OnRemoved")
	ctx:Every("hunt", ctx.config.hunt, function()
		self:Hunt()
	end)
	ctx.commands:Add("nc_npcs", { help = "add | remove [radius] | list | spawn <kind | group> [count] | clear"
		.. " | kinds" }, "NpcsCommand")
end

function M:Stop()
	self:Clear()
end

function M:_Warn(what)
	if not self.warned[what] then
		self.warned[what] = true
		self.ctx.log:Warn("%s", what)
	end
end

-- Registry -----------------------------------------------------------------------------------

local function copy(t)
	local out = {}
	for key, value in pairs(t or {}) do
		out[key] = value
	end
	return out
end

function M:RegisterKind(id, spec)
	assert(type(id) == "string" and id:find(ID), "npcs: RegisterKind(id): id must be lower_snake_case")
	assert(type(spec) == "table" and type(spec.class) == "string" and spec.class:find("^npc_"),
		"npcs: RegisterKind(" .. id .. "): spec.class must be an npc_* class")
	assert(spec.proficiency == nil or self.skills[spec.proficiency] ~= nil,
		"npcs: RegisterKind(" .. id .. "): proficiency must be one of " .. concat(SKILLS, ", "))
	local weapons = {}
	for i, class in ipairs(spec.weapons or {}) do
		weapons[i] = class
	end
	local kind = { id = id, class = spec.class, weapons = weapons, health = spec.health,
		proficiency = spec.proficiency, model = spec.model, skin = spec.skin, keyvalues = copy(spec.keyvalues),
		spawnflags = spec.spawnflags, hostile = spec.hostile ~= false }
	self.kinds[id] = kind
	return kind
end

function M:RegisterGroup(id, entries)
	assert(type(id) == "string" and id:find(ID), "npcs: RegisterGroup(id): id must be lower_snake_case")
	assert(type(entries) == "table" and entries[1] ~= nil, "npcs: RegisterGroup(" .. id .. "): entries must be a list")
	local list, total = {}, 0
	for i, entry in ipairs(entries) do
		local kind, weight = entry.kind or entry[1], entry.weight or entry[2] or 1
		assert(type(kind) == "string", "npcs: RegisterGroup(" .. id .. "): entry " .. i .. " needs a kind")
		assert(type(weight) == "number" and weight > 0, "npcs: RegisterGroup(" .. id .. "): weights must be > 0")
		list[i] = { kind = kind, weight = weight }
		total = total + weight
	end
	self.groups[id] = { id = id, entries = list, total = total }
	return self.groups[id]
end

function M:Kind(id)
	return self.kinds[id]
end

function M:Group(id)
	return self.groups[id]
end

local function keys(t)
	local out = {}
	for id in pairs(t) do
		out[#out + 1] = id
	end
	sort(out)
	return out
end

function M:Kinds()
	return keys(self.kinds)
end

function M:Groups()
	return keys(self.groups)
end

-- A kind of the group drawn by the weights (nil for an unknown group).
function M:Roll(groupId)
	local group = self.groups[groupId]
	if group == nil then
		return nil
	end
	local pick = M.Random() * group.total
	for _, entry in ipairs(group.entries) do
		pick = pick - entry.weight
		if pick < 0 then
			return entry.kind
		end
	end
	return group.entries[#group.entries].kind
end

-- Creatures ----------------------------------------------------------------------------------

-- Creates a creature of `kindId` at pos. opts: tag (counted under it), yaw (else at random),
-- hunt (false: it stays where it is). The entity, or nil and the problem.
function M:Spawn(kindId, pos, opts)
	local kind = self.kinds[kindId]
	if kind == nil then
		return nil, "unknown kind " .. tostring(kindId)
	end
	opts = opts or {}
	local ent = ents.Create(kind.class)
	if not IsValid(ent) then
		return nil, "no engine class " .. kind.class
	end
	ent:SetPos(pos)
	ent:SetAngles(Angle(0, opts.yaw or M.Random() * 360, 0))
	if kind.model ~= nil then
		ent:SetModel(kind.model)
	end
	for key, value in pairs(kind.keyvalues) do
		ent:SetKeyValue(key, tostring(value))
	end
	if kind.spawnflags ~= nil then
		ent:SetKeyValue("spawnflags", tostring(kind.spawnflags))
	end
	local weapons = kind.weapons
	if weapons[1] ~= nil then
		-- The engine gives it at the spawn, as the spawn menu does.
		ent:SetKeyValue("additionalequipment", weapons[M.Random(#weapons)])
	end
	ent:Spawn()
	ent:Activate()
	if kind.skin ~= nil then
		ent:SetSkin(kind.skin)
	end
	if kind.health ~= nil then
		ent:SetMaxHealth(kind.health)
		ent:SetHealth(kind.health)
	end
	if kind.proficiency ~= nil then
		ent:SetCurrentWeaponProficiency(self.skills[kind.proficiency])
	end
	if kind.hostile then
		ent:AddRelationship("player D_HT 99")
	end
	local entry = { kind = kindId, tag = opts.tag, hunt = opts.hunt ~= false }
	self.tracked[ent] = entry
	self:_Befriend(ent, entry)
	if entry.hunt then
		self:_Order(ent, self:_Targets())
	end
	self.ctx.events:Emit("npcs.spawned", ent, kindId, opts.tag)
	return ent
end

-- Creatures of one tag do not fight each other (those of one class do not anyway).
function M:_Befriend(ent, entry)
	if entry.tag == nil then
		return
	end
	local class = ent:GetClass()
	for other, o in pairs(self.tracked) do
		if other ~= ent and o.tag == entry.tag and IsValid(other) and other:GetClass() ~= class then
			ent:AddEntityRelationship(other, D_LI, 99)
			other:AddEntityRelationship(ent, D_LI, 99)
		end
	end
end

-- Spawns up to `count` creatures of the group at the Spots: no more than there is room for
-- under config maxAlive. opts as in Spawn. How many appeared.
function M:SpawnGroup(groupId, count, opts)
	if self.groups[groupId] == nil then
		self:_Warn("unknown group " .. tostring(groupId))
		return 0
	end
	count = min(count, self.ctx.config.maxAlive - self:Count())
	if count <= 0 then
		return 0
	end
	local spots = self:Spots(count)
	if spots[1] == nil then
		self:_Warn("no points and no spawn points on the map")
		return 0
	end
	local spawned = 0
	for _, pos in ipairs(spots) do
		local ent, problem = self:Spawn(self:Roll(groupId), pos, opts)
		if ent ~= nil then
			spawned = spawned + 1
		else
			self:_Warn("group " .. groupId .. ": " .. problem)
		end
	end
	return spawned
end

-- The creatures of the map (not of config ignore, not counted yet) are counted under tag
-- from now on; opts.hunt: they hunt as well (else they keep their places). How many.
function M:Adopt(tag, opts)
	local ignore = self.ctx.config.ignore
	local hunt = opts ~= nil and opts.hunt == true
	local count = 0
	for _, ent in ipairs(ents.GetAll()) do
		if IsValid(ent) and ent:IsNPC() and self.tracked[ent] == nil and not ignore[ent:GetClass()] then
			self.tracked[ent] = { tag = tag, hunt = hunt }
			count = count + 1
		end
	end
	return count
end

function M:Count(tag)
	local count = 0
	for ent, entry in pairs(self.tracked) do
		if IsValid(ent) and (tag == nil or entry.tag == tag) then
			count = count + 1
		end
	end
	return count
end

-- Creatures of tag (nil: all) by entity index, a new table.
function M:List(tag)
	local list = {}
	for ent, entry in pairs(self.tracked) do
		if IsValid(ent) and (tag == nil or entry.tag == tag) then
			list[#list + 1] = ent
		end
	end
	sort(list, function(a, b)
		return a:EntIndex() < b:EntIndex()
	end)
	return list
end

function M:TagOf(ent)
	local entry = self.tracked[ent]
	return entry ~= nil and entry.tag or nil
end

function M:IsTracked(ent)
	return self.tracked[ent] ~= nil
end

-- Removes the creatures of tag (nil: all) the module counts, taken over ones too.
function M:Clear(tag)
	for _, ent in ipairs(self:List(tag)) do
		self.tracked[ent] = nil
		ent:Remove()
	end
	for ent, entry in pairs(self.tracked) do
		if not IsValid(ent) and (tag == nil or entry.tag == tag) then
			self.tracked[ent] = nil
		end
	end
end

function M:OnKilled(ent, attacker, inflictor)
	local entry = self.tracked[ent]
	if entry == nil then
		return
	end
	self.tracked[ent] = nil
	if self.ctx.config.frags and IsValid(attacker) and attacker:IsPlayer() then
		attacker:AddFrags(1)
	end
	self.ctx.events:Emit("npcs.killed", ent, attacker, inflictor, entry.tag, entry.kind)
end

function M:OnRemoved(ent)
	local entry = self.tracked[ent]
	if entry ~= nil then
		self.tracked[ent] = nil
		self.ctx.events:Emit("npcs.removed", ent, entry.tag)
	end
end

-- The hunt -----------------------------------------------------------------------------------

function M:_Targets()
	local list = {}
	for _, ply in ipairs(self.players:List("alive")) do
		if IsValid(ply) then
			list[#list + 1] = ply
		end
	end
	return list
end

-- Hunting creatures without an enemy run to the nearest living player.
function M:Hunt()
	local targets = self:_Targets()
	if targets[1] == nil then
		return
	end
	for _, ent in ipairs(self:List()) do
		if self.tracked[ent].hunt then
			self:_Order(ent, targets)
		end
	end
end

function M:_Order(ent, targets)
	if IsValid(ent:GetEnemy()) then
		return
	end
	local pos = ent:GetPos()
	local best, bestDist
	for _, ply in ipairs(targets) do
		local dist = pos:DistToSqr(ply:GetPos())
		if best == nil or dist < bestDist then
			best, bestDist = ply, dist
		end
	end
	if best == nil then
		return
	end
	local at = best:GetPos()
	ent:UpdateEnemyMemory(best, at)
	ent:SetLastPosition(at)
	ent:SetSchedule(SCHED_FORCED_GO_RUN)
end

-- Points and spots ---------------------------------------------------------------------------

local NONE = {}

-- The list of points of the current map; create: make it when there is none.
function M:_List(create)
	local map = game.GetMap()
	local list
	if self.store ~= nil then
		list = self.store:Get(map)
		if list == nil and create then
			list = {}
			self.store:Set(map, list)
		end
	else
		list = self.memory[map]
		if list == nil and create then
			list = {}
			self.memory[map] = list
		end
	end
	return list or NONE
end

-- The points of the current map: a list of { x, y, z, yaw } (do not modify).
function M:Points()
	return self:_List(false)
end

-- Adds a point of the current map; its index.
function M:AddPoint(pos, yaw)
	local list = self:_List(true)
	list[#list + 1] = { x = floor(pos.x + 0.5), y = floor(pos.y + 0.5), z = floor(pos.z + 0.5),
		yaw = floor((yaw or 0) + 0.5) % 360 }
	if self.store ~= nil then
		self.store:Touch()
	end
	return #list
end

function M:RemovePoint(index)
	local list = self:_List(false)
	if list[index] == nil then
		return false
	end
	table.remove(list, index)
	if self.store ~= nil then
		self.store:Touch()
	end
	return true
end

-- The index of the point nearest to `pos` within `radius`, or nil.
function M:Nearest(pos, radius)
	local best, bestDist
	for i, p in ipairs(self:Points()) do
		local dist = Vector(p.x, p.y, p.z):Distance(pos)
		if dist <= radius and (best == nil or dist < bestDist) then
			best, bestDist = i, dist
		end
	end
	return best
end

local function nearestSqr(pos, list)
	local best = huge
	for i = 1, #list do
		local dist = pos:DistToSqr(list[i])
		if dist < best then
			best = dist
		end
	end
	return best
end

-- Positions for `count` creatures. The centers are the points of the map, without them the
-- player spawns of side b (or any); the ones at config clearance from every living player
-- (all of them when none is) by distance, farthest first; the creatures go round the
-- farther half of them, each next one at a center on a free spot of the rings around it.
function M:Spots(count)
	local centers = {}
	for _, p in ipairs(self:Points()) do
		centers[#centers + 1] = Vector(p.x, p.y, p.z)
	end
	if centers[1] == nil then
		for _, ent in ipairs(self.players:SpawnPoints("b")) do
			if IsValid(ent) then
				centers[#centers + 1] = ent:GetPos()
			end
		end
	end
	if centers[1] == nil then
		return {}
	end
	local living = {}
	for _, ply in ipairs(self:_Targets()) do
		living[#living + 1] = ply:GetPos()
	end
	local scored = {}
	for i, pos in ipairs(centers) do
		scored[i] = { pos = pos, dist = nearestSqr(pos, living), index = i }
	end
	sort(scored, function(a, b)
		if a.dist ~= b.dist then
			return a.dist > b.dist
		end
		return a.index < b.index
	end)
	local clearance = self.ctx.config.clearance
	local usable = {}
	for _, s in ipairs(scored) do
		if s.dist >= clearance * clearance then
			usable[#usable + 1] = s
		end
	end
	if usable[1] == nil then
		usable = scored
	end
	local share = max(1, ceil(#usable / 2))
	local spots, used = {}, {}
	for i = 1, count do
		local s = usable[(i - 1) % share + 1]
		local n = used[s] or 0
		used[s] = n + 1
		spots[i] = self:_Spot(s.pos, n)
	end
	return spots
end

-- The n-th spot at a center (0: the center itself): a free one of the rings reachable from it.
function M:_Spot(center, n)
	if n == 0 then
		return center
	end
	local from = center + LIFT
	for i = 0, #RING - 1 do
		local offset = RING[(n - 1 + i) % #RING + 1]
		local pos = Vector(center.x + offset[1], center.y + offset[2], center.z)
		local tr = util.TraceHull({ start = from, endpos = pos + LIFT, mins = HULL_MINS, maxs = HULL_MAXS,
			mask = MASK_NPCSOLID })
		if not tr.Hit and not tr.StartSolid then
			return pos
		end
	end
	return center
end

-- Console ------------------------------------------------------------------------------------

-- Where an admin points at: the hit of his aim (4096 units), else his feet.
local function aimPoint(ply)
	local eye = ply:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * 4096, filter = ply, mask = MASK_SOLID })
	if tr ~= nil and tr.Hit and tr.HitPos ~= nil then
		return tr.HitPos
	end
	return ply:GetPos()
end

local function describe(i, p)
	return format("%3d. at (%d, %d, %d) yaw %d", i, p.x, p.y, p.z, p.yaw or 0)
end

function M:NpcsCommand(caller, args)
	local sub = args[1]
	if sub == "add" then
		if not IsValid(caller) then
			return "nc_npcs add: run it in the game, where the point should be"
		end
		local index = self:AddPoint(aimPoint(caller), caller:EyeAngles().y + 180)
		return "nc_npcs: added " .. describe(index, self:Points()[index])
	elseif sub == "remove" then
		local radius = tonumber(args[2]) or 128
		local pos = IsValid(caller) and aimPoint(caller) or Vector(0, 0, 0)
		local index = self:Nearest(pos, radius)
		if index == nil then
			return format("nc_npcs remove: no point within %d units", radius)
		end
		local line = describe(index, self:Points()[index])
		self:RemovePoint(index)
		return "nc_npcs: removed " .. line
	elseif sub == "list" then
		local lines = { format("nc_npcs: %d points on %s, %d creatures", #self:Points(), game.GetMap(), self:Count()) }
		for i, p in ipairs(self:Points()) do
			lines[#lines + 1] = describe(i, p)
		end
		return lines
	elseif sub == "spawn" then
		local id = args[2]
		local count = max(1, min(self.ctx.config.maxAlive, floor(tonumber(args[3]) or 1)))
		if self.groups[id] ~= nil then
			return format("nc_npcs: %d of %s spawned", self:SpawnGroup(id, count, { tag = "admin" }), id)
		end
		if self.kinds[id] == nil then
			return "nc_npcs spawn: unknown kind or group " .. tostring(id) .. " (nc_npcs kinds)"
		end
		local spawned = 0
		local spots = IsValid(caller) and { aimPoint(caller) } or self:Spots(count)
		for i = 1, count do
			local pos = spots[i] or (spots[1] ~= nil and self:_Spot(spots[1], i - 1)) or nil
			if pos ~= nil and self:Spawn(id, pos, { tag = "admin" }) ~= nil then
				spawned = spawned + 1
			end
		end
		return format("nc_npcs: %d of %s spawned", spawned, id)
	elseif sub == "clear" then
		local count = self:Count()
		self:Clear()
		return format("nc_npcs: %d creatures removed", count)
	elseif sub == "kinds" then
		local kinds = {}
		for _, id in ipairs(self:Kinds()) do
			kinds[#kinds + 1] = id .. "(" .. self.kinds[id].class .. ")"
		end
		local groups = {}
		for _, id in ipairs(self:Groups()) do
			local parts = {}
			for _, entry in ipairs(self.groups[id].entries) do
				parts[#parts + 1] = entry.kind .. " " .. entry.weight
			end
			groups[#groups + 1] = id .. ": " .. concat(parts, ", ")
		end
		local lines = { "kinds: " .. (kinds[1] ~= nil and concat(kinds, ", ") or "-"),
			groups[1] ~= nil and "groups:" or "groups: -" }
		for _, line in ipairs(groups) do
			lines[#lines + 1] = "  " .. line
		end
		return lines
	end
	return "nc_npcs add | remove [radius] | list | spawn <kind | group> [count] | clear | kinds"
end
