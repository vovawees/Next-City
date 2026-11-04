-- Damage, server part: the pipeline from the engine to the body.
--
-- The health of the engine never changes (D6): damage to a player is blocked and becomes
-- hits on the body instead. A bullet keeps its own pellets: gm.ScalePlayerDamage records
-- every pellet that hits (point, direction, hitgroup, ammo, damage), and the damage they
-- add up to in gm.EntityTakeDamage becomes one hit per pellet. Every hit passes ordered
-- stages (AddStage adds or replaces one; fn(ply, hit) returning false ends the hit):
--   100 localize  where the ray enters the body: hit.structure, segment, region, side
--   200 armor     (the armor module)
--   300 wound     organism:Injure; the report goes to hit.report
--   400 impulse   the view punch of a hit, the push of a blast or an impact
--   500 notify    damage.hit and the history of nc_damage
-- The damage of players:Kill passes untouched. Drowning is the organism's own; god mode,
-- gm.PlayerShouldTakeDamage = false (the rules of a round), damage of 0 and players
-- without a living body take nothing. Landings injure through gm.OnPlayerHitGround; the
-- fall damage of the engine is 0.
--
-- A hit: kind (an injury of the organism), attacker, inflictor, type (DMG_*), amount
-- (engine damage), pos and dir (Vectors, nil when unknown), force, hitgroup; bullets:
-- ammo (name), distance (m), projectile, energy (J), pellet and pellets (its index and
-- the count in the shell); falls: speed; poison: toxin; lethal: cause.
--
-- Listens:  gm.ScalePlayerDamage, gm.EntityTakeDamage, gm.GetFallDamage (answers 0),
--           gm.OnPlayerHitGround, players.left.
-- Emits:    damage.hit (ply, hit) after the stages of every hit.
-- Asks:     gm.PlayerShouldTakeDamage (ply, attacker) -> false: no damage;
--           damage.kind (ply, dmginfo) -> the kind of injury instead of the one of the
--           damage type (e.g. "stab" for a knife), false: no injury.
-- Commands: nc_damage [count] — the latest hits.

local M = NC.Module("damage")

local band = bit.band
local bor = bit.bor
local min = math.min
local random = math.random
local format = string.format
local sort = table.sort
local traceback = debug.traceback
local CurTime = CurTime
local IsValid = IsValid
local Vector = Vector
local Angle = Angle

local UNIT_M = 0.0254   -- metres per unit
local BACK = 6          -- rays start this far before the point of a hit, units (as in the organism)
local NEAR = 96         -- a point farther than this from the middle of the body is not on it, units
local CENTER = 36       -- height of the middle of the body above its origin, units
local MAX_PELLETS = 64  -- pellets recorded per player and tick

-- Kinds of injury by damage type: the first match wins; false: no injury.
local KINDS = {
	{ DMG_DISSOLVE, "lethal" },
	{ bor(DMG_DROWN, DMG_DROWNRECOVER), false }, -- the organism drowns by itself
	{ bor(DMG_BLAST, DMG_BLAST_SURFACE), "blast" },
	{ bor(DMG_BULLET, DMG_BUCKSHOT, DMG_AIRBOAT, DMG_SNIPER), "bullet" },
	{ bor(DMG_BURN, DMG_SLOWBURN, DMG_PLASMA, DMG_ENERGYBEAM), "burn" },
	{ DMG_SHOCK, "shock" },
	{ DMG_SLASH, "slash" },
	{ DMG_CLUB, "blunt" },
	{ DMG_VEHICLE, "vehicle" },
	{ bor(DMG_CRUSH, DMG_PHYSGUN), "crush" },
	{ DMG_FALL, "fall" },
	{ bor(DMG_POISON, DMG_NERVEGAS, DMG_ACID, DMG_RADIATION, DMG_PARALYZE), "poison" },
	{ DMG_SONIC, "blunt" },
}

-- How strong a poison is per point of damage.
local TOXIN = { { DMG_NERVEGAS, 1.5 }, { DMG_RADIATION, 0.5 } }

-- Kinds whose point and direction are looked up on the body.
local LOCATED = { bullet = true, fragment = true, stab = true, slash = true, blunt = true, stun = true }

-- View punch, degrees: bullets per J, others per point of damage, and the most.
local PUNCH_J = 1 / 250
local PUNCH_DAMAGE = 1 / 5
local PUNCH_MAX = 6
-- Push of blasts and impacts, units/s per point of damage, and the most.
local PUSH = { blast = 5, vehicle = 4, crush = 3 }
local PUSH_MAX = 600

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.ammo = {}
	for name, def in pairs(M.AMMO_DEFAULTS) do
		self.ammo[name] = def
	end
	self.ammoNames = {} -- ammo id -> name
	self.pellets = {}   -- ply -> { time, n, [i] = pellet } recorded this tick
	self.stages = {}
	self.history = {}
	self.historyNext = 1
	self:AddStage("localize", 100, function(ply, hit) return self:_Localize(ply, hit) end)
	self:AddStage("wound", 300, function(ply, hit) return self:_Wound(ply, hit) end)
	self:AddStage("impulse", 400, function(ply, hit) return self:_Impulse(ply, hit) end)
	self:AddStage("notify", 500, function(ply, hit) return self:_Notify(ply, hit) end)
	ctx.commands:Add("nc_damage", { help = "the latest hits on players: [count]" }, "DamageCommand")
end

function M:Start(ctx)
	-- Low priority: whoever blocks a bullet answers first, and a blocked pellet is not kept.
	ctx:On("gm.ScalePlayerDamage", "OnScaleDamage", { priority = -1000 })
	ctx:On("gm.EntityTakeDamage", "OnTakeDamage")
	ctx:On("gm.GetFallDamage", "OnFallDamage")
	ctx:On("gm.OnPlayerHitGround", "OnHitGround")
	ctx:On("players.left", "OnLeft")
end

-- Stages ------------------------------------------------------------------------------------

-- Adds or replaces the stage `id`: fn(ply, hit) runs for every hit in the order of
-- `order` (equal orders: in the order of adding); returning false ends the hit.
function M:AddStage(id, order, fn)
	assert(type(id) == "string" and type(order) == "number" and type(fn) == "function",
		"damage: AddStage(id, order, fn)")
	self:RemoveStage(id)
	local stages = self.stages
	stages[#stages + 1] = { id = id, order = order, fn = fn, seq = #stages + 1 }
	sort(stages, function(a, b)
		if a.order ~= b.order then
			return a.order < b.order
		end
		return a.seq < b.seq
	end)
	for i, stage in ipairs(stages) do
		stage.seq = i
	end
end

-- Removes the stage `id`; true if there was one.
function M:RemoveStage(id)
	local stages = self.stages
	for i, stage in ipairs(stages) do
		if stage.id == id then
			table.remove(stages, i)
			return true
		end
	end
	return false
end

-- Ids of the stages in order (a new table).
function M:Stages()
	local ids = {}
	for i, stage in ipairs(self.stages) do
		ids[i] = stage.id
	end
	return ids
end

-- Runs a hit (see the top of the file) on `ply` through the stages, as if the engine
-- dealt it. Returns the report of the organism, or nil if there was no wound.
function M:Apply(ply, hit)
	local stages = self.stages
	for i = 1, #stages do
		if stages[i].fn(ply, hit) == false then
			break
		end
	end
	return hit.report
end

function M:_Localize(ply, hit)
	local pos, dir = hit.pos, hit.dir
	if pos == nil or dir == nil or not LOCATED[hit.kind] then
		return
	end
	local px, py, pz = pos:Unpack()
	local dx, dy, dz = dir:Unpack()
	local s, region, side = self.organism:Locate(ply, px - dx * BACK, py - dy * BACK, pz - dz * BACK, dx, dy, dz)
	if s ~= nil then
		hit.structure, hit.segment, hit.region, hit.side = s.id, s.seg, region, side
	end
end

function M:_Wound(ply, hit)
	local report = self.organism:Injure(ply, hit)
	if report == nil then
		return false
	end
	hit.report = report
end

function M:_Impulse(ply, hit)
	local config = self.ctx.config
	local kind = hit.kind
	local degrees
	if kind == "bullet" or kind == "fragment" then
		degrees = (hit.energy or 0) * PUNCH_J
	else
		degrees = (hit.amount or 0) * PUNCH_DAMAGE
	end
	degrees = min(PUNCH_MAX, degrees) * config.punch
	if degrees >= 0.2 then
		ply:ViewPunch(Angle(-degrees, (random() - 0.5) * degrees, 0))
	end
	local push = PUSH[kind]
	local dir = hit.dir
	if push ~= nil and dir ~= nil then
		local speed = min(PUSH_MAX, (hit.amount or 0) * push) * config.push
		if speed >= 10 then
			local x, y, z = dir:Unpack()
			ply:SetVelocity(Vector(x * speed, y * speed, (z + 0.3) * speed))
		end
	end
end

local function nick(ent)
	if IsValid(ent) and ent:IsPlayer() then
		return ent:Nick()
	end
	return IsValid(ent) and ent:GetClass() or "world"
end

function M:_Notify(ply, hit)
	local report = hit.report
	local size = self.ctx.config.history
	if size > 0 then
		local at = self.historyNext
		self.history[at] = { time = CurTime(), victim = nick(ply), attacker = nick(hit.attacker), kind = hit.kind,
			ammo = hit.ammo, distance = hit.distance, energy = hit.energy, amount = hit.amount, region = hit.region,
			side = hit.side, structure = hit.structure, armor = hit.armor, absorbed = hit.absorbed,
			pellet = hit.pellet, pellets = hit.pellets, wounds = report and report.wounds or 0,
			bleeding = report and report.bleeding or 0, fractures = report and report.fractures or 0,
			fatal = report and report.fatal or nil }
		self.historyNext = at % size + 1
	end
	self.ctx.events:Emit("damage.hit", ply, hit)
end

-- The engine ----------------------------------------------------------------------------------

-- The kind of injury of `dmginfo` (see the top of the file), or false for none.
function M:KindOf(ply, dmginfo)
	local answer = self.ctx.events:Query("damage.kind", ply, dmginfo)
	if answer ~= nil then
		return answer
	end
	local dtype = dmginfo:GetDamageType()
	for i = 1, #KINDS do
		local entry = KINDS[i]
		if band(dtype, entry[1]) ~= 0 then
			local kind = entry[2]
			if kind == "shock" and band(dtype, DMG_CLUB) ~= 0 then
				return "stun" -- a stun baton
			end
			return kind
		end
	end
	return "generic"
end

function M:_AmmoName(id)
	if id == nil or id < 0 then
		return nil
	end
	local name = self.ammoNames[id]
	if name == nil then
		name = game.GetAmmoName(id) or false
		self.ammoNames[id] = name
	end
	return name or nil
end

local function unit(v)
	if v == nil or v:LengthSqr() < 1e-6 then
		return nil
	end
	return v:GetNormalized()
end

local function center(ply)
	local pos = ply:GetPos()
	pos.z = pos.z + CENTER
	return pos
end

-- `pos` if it is a point on the body of `ply`, otherwise nil.
local function onBody(ply, pos)
	if pos == nil or pos:IsZero() or pos:DistToSqr(center(ply)) > NEAR * NEAR then
		return nil
	end
	return pos
end

local function source(attacker)
	if not IsValid(attacker) then
		return nil
	end
	return attacker:IsPlayer() and attacker:GetShootPos() or attacker:GetPos()
end

function M:OnScaleDamage(ply, hitgroup, dmginfo)
	if self.players:IsKilling(ply) then
		return
	end
	local now = CurTime()
	local list = self.pellets[ply]
	if list == nil then
		list = { time = now, n = 0 }
		self.pellets[ply] = list
	elseif list.time ~= now then
		list.time, list.n = now, 0 -- left over from a damage that never came
	end
	local n = list.n
	if n >= MAX_PELLETS then
		return
	end
	n = n + 1
	list.n = n
	local pellet = list[n]
	if pellet == nil then
		pellet = {}
		list[n] = pellet
	end
	pellet.pos = dmginfo:GetDamagePosition()
	pellet.force = dmginfo:GetDamageForce()
	pellet.src = dmginfo:GetReportedPosition()
	pellet.hitgroup = hitgroup
	pellet.ammo = dmginfo:GetAmmoType()
	pellet.damage = dmginfo:GetDamage()
	pellet.attacker = dmginfo:GetAttacker()
	pellet.inflictor = dmginfo:GetInflictor()
end

local function onError(err)
	return traceback(tostring(err), 2)
end

-- Blocks every damage to a player but the one of players:Kill and turns it into hits.
function M:OnTakeDamage(ent, dmginfo)
	if not ent:IsPlayer() or self.players:IsKilling(ent) then
		return nil
	end
	local ok, err = xpcall(self._TakeDamage, onError, self, ent, dmginfo)
	if not ok then
		self.ctx.log:Error("damage to %s failed: %s", tostring(ent), tostring(err))
	end
	return true
end

function M:_TakeDamage(ply, dmginfo)
	local list = self.pellets[ply]
	local count = 0
	if list ~= nil then
		if list.time == CurTime() then
			count = list.n
		end
		list.n = 0
	end
	local organism = self.organism
	if dmginfo:GetDamage() <= 0 or not organism:IsSimulated(ply) or organism:IsDead(ply) or ply:HasGodMode() then
		return
	end
	if self.ctx.events:Query("gm.PlayerShouldTakeDamage", ply, dmginfo:GetAttacker()) == false then
		return
	end
	local kind = self:KindOf(ply, dmginfo)
	if not kind then
		return
	end
	if kind == "bullet" then
		if count == 0 then
			self:Apply(ply, self:_BulletHit(ply, dmginfo, nil, 1, 1))
		end
		for i = 1, count do
			self:Apply(ply, self:_BulletHit(ply, dmginfo, list[i], i, count))
		end
		return
	end
	self:Apply(ply, self:_Hit(ply, dmginfo, kind, count > 0 and list[count] or nil))
end

-- A bullet hit from a recorded pellet, or from the damage info without one.
function M:_BulletHit(ply, dmginfo, pellet, index, count)
	local pos, force, src, hitgroup, ammo, amount, attacker, inflictor
	if pellet ~= nil then
		pos, force, src, hitgroup = pellet.pos, pellet.force, pellet.src, pellet.hitgroup
		ammo, amount, attacker, inflictor = pellet.ammo, pellet.damage, pellet.attacker, pellet.inflictor
	else
		pos, force, src, hitgroup = dmginfo:GetDamagePosition(), dmginfo:GetDamageForce(),
			dmginfo:GetReportedPosition(), ply:LastHitGroup()
		ammo, amount, attacker, inflictor = dmginfo:GetAmmoType(), dmginfo:GetDamage(), dmginfo:GetAttacker(),
			dmginfo:GetInflictor()
	end
	pos = onBody(ply, pos)
	if src == nil or src:IsZero() then
		src = source(attacker)
	end
	local dir = unit(force)
	if dir == nil and pos ~= nil and src ~= nil then
		dir = unit(pos - src)
	end
	local distance = (pos ~= nil and src ~= nil) and pos:Distance(src) * UNIT_M or 0
	local name = self:_AmmoName(ammo)
	local projectile, energy = self:Projectile(name, distance, amount)
	return { kind = "bullet", attacker = attacker, inflictor = inflictor, type = dmginfo:GetDamageType(),
		amount = amount, pos = pos, dir = dir, force = force, hitgroup = hitgroup, ammo = name,
		distance = distance, projectile = projectile, energy = energy, pellet = index, pellets = count }
end

-- Any other hit; `pellet` is the trace of a melee hit when there was one.
function M:_Hit(ply, dmginfo, kind, pellet)
	local dtype = dmginfo:GetDamageType()
	local amount = dmginfo:GetDamage()
	local attacker = dmginfo:GetAttacker()
	local force = dmginfo:GetDamageForce()
	local hit = { kind = kind, attacker = attacker, inflictor = dmginfo:GetInflictor(), type = dtype,
		amount = amount, force = force, hitgroup = pellet and pellet.hitgroup or ply:LastHitGroup() }
	local point = pellet and pellet.pos or dmginfo:GetDamagePosition()
	local dir = unit(force)
	if kind == "blast" then
		-- The point is the centre of the explosion: only the direction from it matters.
		if dir == nil and not point:IsZero() then
			dir = unit(center(ply) - point)
		end
	else
		hit.pos = onBody(ply, point)
		if dir == nil and attacker ~= ply then
			local from = source(attacker)
			if from ~= nil then
				dir = unit((hit.pos or center(ply)) - from)
			end
		end
	end
	hit.dir = dir
	if kind == "fall" then
		hit.speed = 526.5 + amount * 3.96 -- the inverse of the engine's realistic fall damage
	elseif kind == "poison" then
		hit.toxin = 1
		for _, entry in ipairs(TOXIN) do
			if band(dtype, entry[1]) ~= 0 then
				hit.toxin = entry[2]
				break
			end
		end
	elseif kind == "lethal" then
		hit.cause = "dissolve"
	end
	return hit
end

-- The engine never takes health for a fall.
function M:OnFallDamage()
	return 0
end

-- A landing injures by its speed (units/s) unless it ends in water.
function M:OnHitGround(ply, inWater, _, speed)
	if inWater or speed < self.ctx.config.fallSpeed or not self.ctx.config.falls then
		return
	end
	local organism = self.organism
	if not organism:IsSimulated(ply) or organism:IsDead(ply) or ply:HasGodMode() then
		return
	end
	local world = game.GetWorld()
	if self.ctx.events:Query("gm.PlayerShouldTakeDamage", ply, world) == false then
		return
	end
	local ok, err = xpcall(self.Apply, onError, self, ply, { kind = "fall", speed = speed, attacker = world,
		inflictor = world, type = DMG_FALL, amount = 0 })
	if not ok then
		self.ctx.log:Error("fall of %s failed: %s", tostring(ply), tostring(err))
	end
end

function M:OnLeft(ply)
	self.pellets[ply] = nil
end

-- Console ------------------------------------------------------------------------------------

-- The latest hits, oldest first (at most `count`).
function M:History(count)
	local size = self.ctx.config.history
	local out = {}
	local at = self.historyNext
	for _ = 1, size do
		local entry = self.history[at]
		if entry ~= nil then
			out[#out + 1] = entry
		end
		at = at % size + 1
	end
	count = count or #out
	local first = #out - count + 1
	if first <= 1 then
		return out
	end
	local last = {}
	for i = first, #out do
		last[#last + 1] = out[i]
	end
	return last
end

function M:DamageCommand(_, args)
	local count = tonumber(args[1] or "") or 10
	local hits = self:History(count)
	if #hits == 0 then
		return "nc_damage: no hits yet"
	end
	local now = CurTime()
	local lines = { format("nc_damage: the latest %d hits", #hits) }
	for _, h in ipairs(hits) do
		local what = h.kind
		if h.ammo ~= nil then
			what = what .. " " .. h.ammo
		end
		if h.pellets ~= nil and h.pellets > 1 then
			what = what .. format(" %d/%d", h.pellet, h.pellets)
		end
		local where = h.region and (h.region .. (h.side and " " .. h.side or "")) or "-"
		lines[#lines + 1] = format("  %5.1fs ago  %s <- %s: %s, %s%s%s at %s%s; %d wounds, +%d ml/min, %d fractures%s",
			now - h.time, h.victim, h.attacker, what, h.energy and format("%d J", h.energy) or format("%g dmg", h.amount),
			h.distance and h.distance > 0 and format(", %.1f m", h.distance) or "",
			h.armor and format(", armor %s -%d J", h.armor, h.absorbed or 0) or "", where,
			h.structure and " (" .. h.structure .. ")" or "", h.wounds, h.bleeding, h.fractures,
			h.fatal and ", fatal (" .. h.fatal .. ")" or "")
	end
	return lines
end
