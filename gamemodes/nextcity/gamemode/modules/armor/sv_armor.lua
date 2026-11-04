-- Armor, server part: worn armor and the armor stage of the damage pipeline.
--
-- The stage (order 200) looks at every located hit: the pieces that cover the region
-- and side the hit enters, outer layers first (and the roll of their share), meet it.
--   bullets and fragments  the threat (energy, diameter, armor piercing) against the
--                          protection of the class, lower as the piece wears out:
--                          stopped, the projectile hits as a blow (material.blunt of its
--                          energy); through, it goes on with the rest of its energy
--   slash                  stopped by any armor: a light blow
--   stab                   stopped by hard armor and class 3 and up, soft armor below
--                          lets the blade a little way in
--   blunt, stun, crush     the armor spreads the blow (material.melee of it is left)
--   blast                  the fragments of the explosion meet the armor one by one
-- Hits without a point on the body (melee of some NPCs) count as hits on the front of the
-- chest. A hit wears the piece out by its threat over the protection times the hits it
-- is rated for. Armor is taken off at every loadout (modes put it on) and at death.
--
-- Listens:  players.loadout (first: takes the armor off), players.died, players.left,
--           players.stateChanged.
-- Emits:    armor.hit (ply, hit, kind, stopped)  a piece met a hit
-- Commands: nc_armor [player] [kind | -slot | strip] — shows, puts on and takes off.

local M = NC.Module("armor")

local sqrt = math.sqrt
local max = math.max
local format = string.format
local concat = table.concat
local IsValid = IsValid

local MELEE = { slash = true, stab = true }
local BLOWS = { blunt = true, stun = true, crush = true }
local BALLISTIC = { bullet = true, fragment = true }

function M:Init(ctx)
	self:_InitKinds()
	self.players = ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.worn = {} -- ply -> pieces { kind, condition }, outer layers first
	ctx:Require("damage"):AddStage("armor", 200, function(ply, hit) return self:_Stage(ply, hit) end)
	ctx.commands:Add("nc_armor", { help = "armor of a player: [player] [kind | -slot | strip]" }, "ArmorCommand")
end

function M:Start(ctx)
	ctx:On("players.loadout", "OnLoadout", { priority = 100 })
	ctx:On("players.died", "Strip")
	ctx:On("players.left", "OnLeft")
	ctx:On("players.stateChanged", "OnStateChanged")
end

function M:OnLoadout(ply)
	self:Strip(ply)
end

function M:OnLeft(ply)
	self.worn[ply] = nil
end

function M:OnStateChanged(ply, state)
	if state ~= "alive" then
		self:Strip(ply)
	end
end

-- Worn armor --------------------------------------------------------------------------------

function M:_Publish(ply)
	local pieces = self.worn[ply]
	local store = self.ctx.components.armor
	if pieces == nil or #pieces == 0 then
		if store:Has(ply) then
			store:Remove(ply)
		end
		return
	end
	local list = {}
	for i, piece in ipairs(pieces) do
		list[i] = { id = piece.kind.id, condition = piece.condition }
	end
	if store:Has(ply) then
		store:Set(ply, "pieces", list)
	else
		store:Add(ply, { pieces = list })
	end
end

-- Puts a piece of armor of kind `id` on a living player, in place of the piece in its
-- slot. condition: 0..1 (default 1). Returns true, or false and "unknown" or "dead".
function M:Equip(ply, id, condition)
	local kind = self.kinds[id]
	if kind == nil then
		return false, "unknown"
	end
	if not IsValid(ply) or not ply:Alive() then
		return false, "dead"
	end
	local pieces = self.worn[ply] or {}
	for i = #pieces, 1, -1 do
		if pieces[i].kind.slot == kind.slot then
			table.remove(pieces, i)
		end
	end
	local piece = { kind = kind, condition = math.min(1, math.max(0, condition or 1)) }
	local at = #pieces + 1
	for i, other in ipairs(pieces) do
		if kind.layer < other.kind.layer then
			at = i
			break
		end
	end
	table.insert(pieces, at, piece)
	self.worn[ply] = pieces
	self:_Publish(ply)
	return true
end

-- Takes off the piece in `slot`. Returns true if there was one.
function M:Unequip(ply, slot)
	local pieces = self.worn[ply]
	if pieces == nil then
		return false
	end
	for i, piece in ipairs(pieces) do
		if piece.kind.slot == slot then
			table.remove(pieces, i)
			self:_Publish(ply)
			return true
		end
	end
	return false
end

-- Takes off all armor.
function M:Strip(ply)
	if self.worn[ply] ~= nil then
		self.worn[ply] = nil
		self:_Publish(ply)
	end
end

-- The worn pieces, outer layers first: { id, slot, condition } (a new table).
function M:Worn(ply)
	local out = {}
	for i, piece in ipairs(self.worn[ply] or {}) do
		out[i] = { id = piece.kind.id, slot = piece.kind.slot, condition = piece.condition }
	end
	return out
end

-- The stage ------------------------------------------------------------------------------------

function M:_Stage(ply, hit)
	local pieces = self.worn[ply]
	if pieces == nil then
		return
	end
	local kind = hit.kind
	if kind == "blast" then
		hit.shield = function(target, fragment) return self:_Shield(target, fragment) end
		return
	end
	if not (BALLISTIC[kind] or MELEE[kind] or BLOWS[kind]) then
		return
	end
	local region, side = hit.region, hit.side
	if region == nil then
		if BALLISTIC[kind] then
			return
		end
		region, side = "chest", "front"
	end
	self:_Meet(ply, pieces, hit, region, side)
end

-- The pieces covering (region, side) meet the hit, outer layers first.
function M:_Meet(ply, pieces, hit, region, side)
	local random = self.organism.Random
	local changed = false
	for i = 1, #pieces do
		local piece = pieces[i]
		local kind = piece.kind
		if M.Covers(kind, region, side) and (kind.share >= 1 or random() < kind.share) then
			changed = true
			local stopped
			if BALLISTIC[hit.kind] then
				stopped = self:_Ballistic(piece, hit)
			elseif MELEE[hit.kind] then
				stopped = self:_Blade(piece, hit)
			else
				self:_Blow(piece, hit)
				stopped = true
			end
			hit.armor = kind.id
			self.ctx.events:Emit("armor.hit", ply, hit, kind.id, stopped)
			if stopped then
				break
			end
		end
	end
	if changed then
		self:_Publish(ply)
	end
end

local function energyOf(hit)
	if hit.energy ~= nil then
		return hit.energy
	end
	local p = hit.projectile
	return p ~= nil and 0.5 * p.mass * 0.001 * p.velocity * p.velocity or 0
end

-- A projectile meets a piece. Returns true if the piece stopped it.
function M:_Ballistic(piece, hit)
	local kind = piece.kind
	local material = M.MATERIALS[kind.material]
	local config = self.ctx.config
	local p = hit.projectile
	local energy = energyOf(hit)
	local threat = M.Threat(energy, p)
	local protection = kind.protection * (material.floor + (1 - material.floor) * piece.condition)
	piece.condition = max(0, piece.condition - threat / (kind.protection * kind.hits) * config.wear)
	if threat <= protection then
		local blow = energy * material.blunt * config.bluntScale
		hit.absorbed = (hit.absorbed or 0) + energy - blow
		hit.kind = "blunt"
		hit.energy = blow
		hit.projectile = nil
		hit.stopped = true
		return true
	end
	local rest = 1 - protection / threat
	hit.absorbed = (hit.absorbed or 0) + energy * (1 - rest)
	hit.energy = energy * rest
	if p ~= nil then
		p.velocity = p.velocity * sqrt(rest)
		p.penetration = p.penetration * (0.4 + 0.6 * rest)
		p.fragment = nil
	end
	return false
end

-- A blade meets a piece. Returns true if the piece stopped it.
function M:_Blade(piece, hit)
	local kind = piece.kind
	local material = M.MATERIALS[kind.material]
	piece.condition = max(0, piece.condition - 0.02 * self.ctx.config.wear)
	if hit.kind == "slash" or kind.material == "hard" or kind.class >= 3 then
		hit.kind = "blunt"
		hit.energy = (hit.amount or 10) * 2 * material.melee
		hit.stopped = true
		return true
	end
	hit.depth = (hit.depth or 12) * 0.4
	return false
end

-- A blow spreads over a piece.
function M:_Blow(piece, hit)
	local melee = M.MATERIALS[piece.kind.material].melee
	if hit.energy ~= nil then
		hit.absorbed = (hit.absorbed or 0) + hit.energy * (1 - melee)
		hit.energy = hit.energy * melee
	end
	if hit.amount ~= nil then
		hit.amount = hit.amount * melee
	end
end

-- A fragment of an explosion on its way into the body of `ply`: false keeps it out
-- (the organism then injures by the changed kind of the fragment).
function M:_Shield(ply, fragment)
	local pieces = self.worn[ply]
	if pieces == nil or fragment.pos == nil or fragment.dir == nil then
		return
	end
	local px, py, pz = fragment.pos:Unpack()
	local dx, dy, dz = fragment.dir:Unpack()
	local s, region, side = self.organism:Locate(ply, px - dx * 6, py - dy * 6, pz - dz * 6, dx, dy, dz)
	if s == nil then
		return
	end
	self:_Meet(ply, pieces, fragment, region, side)
end

-- Console ---------------------------------------------------------------------------------------

function M:ArmorCommand(caller, args)
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return "nc_armor: " .. problem
	end
	local what = args[2]
	if what == "strip" then
		self:Strip(ply)
	elseif what ~= nil and what:sub(1, 1) == "-" then
		if not self:Unequip(ply, what:sub(2)) then
			return format("nc_armor: %s wears nothing in slot '%s'", ply:Nick(), what:sub(2))
		end
	elseif what ~= nil then
		local ok, reason = self:Equip(ply, what)
		if not ok then
			return format("nc_armor: %s: %s; kinds: %s", what, reason, concat(self:Kinds(), ", "))
		end
	end
	local worn = self:Worn(ply)
	if #worn == 0 then
		return "nc_armor: " .. ply:Nick() .. " wears no armor"
	end
	local lines = { "nc_armor: " .. ply:Nick() .. ":" }
	for _, piece in ipairs(worn) do
		local kind = self.kinds[piece.id]
		lines[#lines + 1] = format("  %-8s %-14s class %d %s, condition %d%%", piece.slot, piece.id, kind.class,
			kind.material, math.floor(piece.condition * 100 + 0.5))
	end
	return lines
end
