-- Loot, server part.
--
--   loot:RegisterTable("medical_small", {
--   	draws = { 1, 3 },                                    -- how many draws (a number or min, max)
--   	entries = {
--   		{ item = "bandage", weight = 10, count = { 1, 3 } }, -- count: a number or min, max
--   		{ item = "ifak", weight = 2, state = { charge = 2 } },
--   		{ table = "ammo_pistol", weight = 4 },           -- a draw from another table
--   		{ weight = 5 },                                  -- nothing
--   	},
--   })
--   loot:RegisterCrate("crate_medical", {
--   	model = "models/items/item_item_crate.mdl", title = "loot.crate.medical",
--   	size = 12, maxWeight = 40, maxSize = 3,              -- the container (inventory)
--   	table = "medical_small", respawn = 0,                -- s after it was emptied to fill again (0: never)
--   	frozen = true,                                       -- does not move
--   })
--   loot:Roll(tableId)                 -> { { id, count, state }, ... }
--   loot:Fill(container, tableId)      -> things put in (what does not fit stays out)
--   loot:SpawnCrate(crateId, pos, ang) -> ent, container
--   loot:SpawnLoose(tableId, pos)      -> the entities of the things on the ground
--   loot:AddPoint(kind, id, pos, yaw) / RemovePoint(index) / Points() / Nearest(pos, radius)
--                                         points of the current map: kind "crate" (id of a
--                                         crate) or "items" (id of a table: loose things)
--   loot:SpawnAll(share) / ClearAll()   what the points give (share: of the points, at random)
--
-- Rule of rounds: loot (params loot, lootShare) spawns the points at the setup of a round
-- and clears them at its cleanup. Modes add it when this module runs.
-- Commands: nc_loot (admin): add <crate | table> | remove [radius] | list | spawn | clear |
--           roll <table> [times] | tables.

local M = NC.Module("loot")

local IsValid = IsValid
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local floor = math.floor
local min = math.min
local max = math.max
local format = string.format
local concat = table.concat
local sort = table.sort

local ID = "^[a-z][a-z0-9_]*$"

M.Random = math.random -- () -> [0, 1), (a, b) -> an integer; tests replace it

function M:Init(ctx)
	self.inventory = ctx:Require("inventory")
	self.storage = ctx:Require("storage")
	self.rounds = ctx:Require("rounds")
	self.tables = {}   -- id -> table
	self.crates = {}   -- id -> crate
	self.spawned = {}  -- { ent, c, crate, point, emptyAt } of crates and { ent } of loose things
	self.warned = {}
	self.store = self.storage ~= nil and self.storage:Open("loot") or nil
	self.memory = {}   -- points without storage: map -> list
	if self.rounds ~= nil then
		self.rounds:RegisterRule({
			id = "loot",
			description = "the loot of the map points appears for the round and goes with it",
			params = {
				loot = { type = "boolean", default = true, desc = "spawn loot at the points of the map" },
				lootShare = { type = "number", default = 1, min = 0, max = 1,
					desc = "share of the points that get loot" },
			},
			Setup = function(round)
				self:ClearAll()
				if round.params.loot then
					self:SpawnAll(round.params.lootShare)
				end
			end,
			Cleanup = function()
				self:ClearAll()
			end,
		}, ctx)
	end
end

function M:Start(ctx)
	ctx.commands:Add("nc_loot", { help = "add <crate|table> | remove [radius] | list | spawn | clear"
		.. " | roll <table> [times] | tables" }, "LootCommand")
	ctx:Every("refill", ctx.config.refill, function(now)
		self:Refill(now)
	end)
end

function M:Stop()
	self:ClearAll()
end

-- Registry ---------------------------------------------------------------------------------

local function range(value, what)
	if type(value) == "number" then
		assert(value >= 0, what .. " must not be negative")
		return { floor(value), floor(value) }
	end
	assert(type(value) == "table" and type(value[1]) == "number" and type(value[2]) == "number"
		and value[1] >= 0 and value[2] >= value[1], what .. " must be a number or { min, max }")
	return { floor(value[1]), floor(value[2]) }
end

-- Registers or replaces a table of loot (see the top of the file).
function M:RegisterTable(id, spec)
	assert(type(id) == "string" and id:find(ID), "loot: RegisterTable(id): id must be lower_snake_case")
	assert(type(spec) == "table" and type(spec.entries) == "table" and spec.entries[1] ~= nil,
		"loot: RegisterTable(" .. id .. "): entries must be a non-empty list")
	local entries, total = {}, 0
	for i, entry in ipairs(spec.entries) do
		local weight = entry.weight or 1
		assert(type(weight) == "number" and weight >= 0, "loot: table " .. id .. " entry " .. i .. ": bad weight")
		assert(entry.item == nil or type(entry.item) == "string", "loot: table " .. id .. " entry " .. i .. ": bad item")
		assert(entry.table == nil or type(entry.table) == "string",
			"loot: table " .. id .. " entry " .. i .. ": bad table")
		entries[i] = { item = entry.item, table = entry.table, weight = weight,
			count = range(entry.count or 1, "loot: table " .. id .. " entry " .. i .. " count"), state = entry.state }
		total = total + weight
	end
	self.tables[id] = { id = id, draws = range(spec.draws or 1, "loot: table " .. id .. " draws"), entries = entries,
		total = total }
end

-- Registers or replaces a kind of crate (see the top of the file).
function M:RegisterCrate(id, spec)
	assert(type(id) == "string" and id:find(ID), "loot: RegisterCrate(id): id must be lower_snake_case")
	assert(type(spec) == "table", "loot: RegisterCrate(" .. id .. ", spec)")
	self.crates[id] = {
		id = id, model = spec.model or "models/props_junk/wood_crate001a.mdl", title = spec.title or "inventory.kind.crate",
		size = spec.size or 12, maxWeight = spec.maxWeight or 60, maxSize = spec.maxSize or 3, table = spec.table,
		respawn = spec.respawn or 0, frozen = spec.frozen ~= false,
	}
end

function M:Table(id)
	return self.tables[id]
end

function M:Crate(id)
	return self.crates[id]
end

local function ids(map)
	local out = {}
	for id in pairs(map) do
		out[#out + 1] = id
	end
	sort(out)
	return out
end

function M:Tables()
	return ids(self.tables)
end

function M:Crates()
	return ids(self.crates)
end

-- Rolls ------------------------------------------------------------------------------------

local function between(r)
	if r[1] == r[2] then
		return r[1]
	end
	return M.Random(r[1], r[2])
end

function M:_Warn(what)
	if not self.warned[what] then
		self.warned[what] = true
		self.ctx.log:Warn("loot: %s", what)
	end
end

function M:_Draw(t, out, depth, budget)
	if t.total <= 0 then
		return
	end
	local pick = M.Random() * t.total
	local chosen
	for _, entry in ipairs(t.entries) do
		pick = pick - entry.weight
		if pick < 0 then
			chosen = entry
			break
		end
	end
	chosen = chosen or t.entries[#t.entries]
	if chosen.table ~= nil then
		local inner = self.tables[chosen.table]
		if inner == nil then
			self:_Warn(format("table %s: unknown table %s", t.id, chosen.table))
		elseif depth >= self.ctx.config.maxDepth then
			self:_Warn(format("table %s: tables nested deeper than %d", t.id, self.ctx.config.maxDepth))
		else
			self:_Roll(inner, out, depth + 1, budget)
		end
		return
	end
	if chosen.item == nil then
		return
	end
	if self.inventory:Def(chosen.item) == nil then
		self:_Warn(format("table %s: unknown item %s", t.id, chosen.item))
		return
	end
	local count = between(chosen.count)
	if count <= 0 then
		return
	end
	local state = nil
	if chosen.state ~= nil then
		state = {}
		for k, v in pairs(chosen.state) do
			state[k] = v
		end
	end
	-- The same item without state adds up.
	if state == nil then
		for _, got in ipairs(out) do
			if got.id == chosen.item and got.state == nil then
				got.count = got.count + count
				return
			end
		end
	end
	out[#out + 1] = { id = chosen.item, count = count, state = state }
end

function M:_Roll(t, out, depth, budget)
	local draws = between(t.draws)
	for _ = 1, draws do
		if budget.left <= 0 then
			return
		end
		budget.left = budget.left - 1
		self:_Draw(t, out, depth, budget)
	end
end

-- What a roll of table `id` gives: { { id, count, state } } (empty for an unknown table).
function M:Roll(id)
	local out = {}
	local t = self.tables[id]
	if t == nil then
		self:_Warn("unknown table " .. tostring(id))
		return out
	end
	self:_Roll(t, out, 1, { left = self.ctx.config.maxDraws })
	return out
end

-- Puts a roll of table `id` into a container; the number of things put in.
function M:Fill(c, id)
	local placed = 0
	for _, got in ipairs(self:Roll(id)) do
		placed = placed + (self.inventory:Give(c, got.id, got.count, got.state) or 0)
	end
	return placed
end

-- The world ----------------------------------------------------------------------------------

-- A crate of kind `crateId` at `pos`, filled from its table. Returns the entity and the
-- container, or nil.
function M:SpawnCrate(crateId, pos, ang, point)
	local crate = self.crates[crateId]
	if crate == nil then
		self:_Warn("unknown crate " .. tostring(crateId))
		return nil
	end
	local ent, c = self.inventory:SpawnPlace(pos, ang, { model = crate.model, kind = "crate", title = crate.title,
		size = crate.size, maxWeight = crate.maxWeight, maxSize = crate.maxSize, frozen = crate.frozen,
		data = { loot = crateId } })
	if ent == nil then
		return nil
	end
	if crate.table ~= nil then
		self:Fill(c, crate.table)
	end
	self.spawned[#self.spawned + 1] = { ent = ent, c = c, crate = crate, point = point }
	return ent, c
end

-- A roll of table `id` as loose things on the ground around `pos`; their entities.
function M:SpawnLoose(id, pos)
	local out = {}
	local inventory, scatter = self.inventory, self.ctx.config.scatter
	for _, got in ipairs(self:Roll(id)) do
		local def = inventory:Def(got.id)
		local left = got.count
		while left > 0 do
			local n = min(left, def.stack)
			left = left - n
			local item = inventory:Create(got.id, n, got.state)
			local angle = M.Random() * 2 * math.pi
			local radius = M.Random() * scatter
			local ent = inventory:SpawnItem(item, Vector(pos.x + math.cos(angle) * radius,
				pos.y + math.sin(angle) * radius, pos.z + 4))
			if ent == nil then
				return out
			end
			out[#out + 1] = ent
			self.spawned[#self.spawned + 1] = { ent = ent }
		end
	end
	return out
end

-- Crates that fill up again: emptied, they wait for their respawn time and nobody looking.
function M:Refill(now)
	local inventory = self.inventory
	for _, entry in ipairs(self.spawned) do
		local crate = entry.crate
		if crate ~= nil and crate.respawn > 0 and crate.table ~= nil and IsValid(entry.ent) and not entry.c.removed then
			if entry.c:IsEmpty() then
				entry.emptyAt = entry.emptyAt or now
				if now - entry.emptyAt >= crate.respawn and #inventory:Watchers(entry.c) == 0 then
					self:Fill(entry.c, crate.table)
					entry.emptyAt = nil
				end
			else
				entry.emptyAt = nil
			end
		end
	end
end

-- Removes everything the points and SpawnCrate/SpawnLoose made that is still in the world
-- (loose things somebody picked up stay with him).
function M:ClearAll()
	local inventory = self.inventory
	for _, entry in ipairs(self.spawned) do
		local ent = entry.ent
		if IsValid(ent) and (entry.crate ~= nil or inventory:ItemOf(ent) ~= nil) then
			ent:Remove()
		end
	end
	self.spawned = {}
end

-- Points -----------------------------------------------------------------------------------

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

-- The points of the current map: a list of { kind, id, x, y, z, yaw } (do not modify).
function M:Points()
	return self:_List(false)
end

-- Adds a point: kind "crate" (id of a crate) or "items" (id of a table). Its index, or nil
-- and the problem.
function M:AddPoint(kind, id, pos, yaw)
	if kind == "crate" and self.crates[id] == nil then
		return nil, "unknown crate " .. tostring(id)
	end
	if kind == "items" and self.tables[id] == nil then
		return nil, "unknown table " .. tostring(id)
	end
	if kind ~= "crate" and kind ~= "items" then
		return nil, "kind must be crate or items"
	end
	local list = self:_List(true)
	list[#list + 1] = { kind = kind, id = id, x = floor(pos.x + 0.5), y = floor(pos.y + 0.5), z = floor(pos.z + 0.5),
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
		local d = Vector(p.x, p.y, p.z):Distance(pos)
		if d <= radius and (best == nil or d < bestDist) then
			best, bestDist = i, d
		end
	end
	return best
end

-- Spawns what the points of the map give (share: of the points, chosen at random). The
-- number of points used.
function M:SpawnAll(share)
	share = share or 1
	local used = 0
	for _, p in ipairs(self:Points()) do
		if share >= 1 or M.Random() < share then
			local pos = Vector(p.x, p.y, p.z)
			if p.kind == "crate" then
				if self:SpawnCrate(p.id, pos, Angle(0, p.yaw or 0, 0), p) ~= nil then
					used = used + 1
				end
			elseif p.kind == "items" then
				self:SpawnLoose(p.id, pos)
				used = used + 1
			end
		end
	end
	return used
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
	return format("%3d. %-5s %-24s at (%d, %d, %d) yaw %d", i, p.kind, p.id, p.x, p.y, p.z, p.yaw or 0)
end

function M:LootCommand(caller, args)
	local sub = args[1]
	if sub == "add" then
		if not IsValid(caller) then
			return "nc_loot add: run it in the game, where the point should be"
		end
		local id = args[2]
		local kind = self.crates[id] ~= nil and "crate" or (self.tables[id] ~= nil and "items" or nil)
		if kind == nil then
			return "nc_loot add: unknown crate or table " .. tostring(id) .. " (nc_loot tables)"
		end
		local index, problem = self:AddPoint(kind, id, aimPoint(caller), caller:EyeAngles().y + 180)
		if index == nil then
			return "nc_loot add: " .. problem
		end
		return "nc_loot: added " .. describe(index, self:Points()[index])
	elseif sub == "remove" then
		local radius = tonumber(args[2]) or 128
		local pos = IsValid(caller) and aimPoint(caller) or Vector(0, 0, 0)
		local index = self:Nearest(pos, radius)
		if index == nil then
			return format("nc_loot remove: no point within %d units", radius)
		end
		local line = describe(index, self:Points()[index])
		self:RemovePoint(index)
		return "nc_loot: removed " .. line
	elseif sub == "list" then
		local lines = { format("nc_loot: %d points on %s", #self:Points(), game.GetMap()) }
		for i, p in ipairs(self:Points()) do
			lines[#lines + 1] = describe(i, p)
		end
		return lines
	elseif sub == "spawn" then
		self:ClearAll()
		return format("nc_loot: %d points spawned", self:SpawnAll(1))
	elseif sub == "clear" then
		self:ClearAll()
		return "nc_loot: cleared"
	elseif sub == "roll" then
		local id = args[2]
		if self.tables[id] == nil then
			return "nc_loot roll: unknown table " .. tostring(id)
		end
		local times = max(1, min(1000, floor(tonumber(args[3]) or 1)))
		local totals, order = {}, {}
		for _ = 1, times do
			for _, got in ipairs(self:Roll(id)) do
				if totals[got.id] == nil then
					totals[got.id] = 0
					order[#order + 1] = got.id
				end
				totals[got.id] = totals[got.id] + got.count
			end
		end
		sort(order)
		local lines = { format("nc_loot: %s x%d", id, times) }
		for _, item in ipairs(order) do
			lines[#lines + 1] = format("  %-24s %d", item, totals[item])
		end
		return lines
	elseif sub == "tables" then
		local crates = {}
		for _, id in ipairs(self:Crates()) do
			crates[#crates + 1] = id .. (self.crates[id].table and ("(" .. self.crates[id].table .. ")") or "")
		end
		return { "tables: " .. (concat(self:Tables(), ", ") ~= "" and concat(self:Tables(), ", ") or "-"),
			"crates: " .. (#crates > 0 and concat(crates, ", ") or "-") }
	end
	return "nc_loot add <crate|table> | remove [radius] | list | spawn | clear | roll <table> [times] | tables"
end
