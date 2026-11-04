-- Ballistics, server part: the projectile manager.
--
-- Projectiles live in arrays (no entity per bullet) and one job flies them all every tick:
--   flight     quadratic air drag: the velocity drops e times over the range of the round,
--              v(x) = v0·e^(-x/range), the law the damage pipeline uses for engine
--              bullets; real gravity; water slows a projectile like air 800 times denser
--   bodies     a living player or the body he is down in: a hit through damage:Inflict
--              (the rules of the round, armor, the organism); what the body did not take
--              flies on out of it, and a fallen body is pushed by the momentum it took
--   materials  the world and props: a projectile glances off below the ricochet angle of
--              the material, otherwise it goes through as deep as its threat allows
--              (energy·√(9/diameter)·ap over the resistance of the material, J/cm) and
--              loses energy by the thickness, but never through the ground of
--              displacements; props, creatures and glass take engine damage
--   effects    impacts (decals and sounds of the material), exit holes, splashes, blood
-- The part of the flight the latency of a shooting player hides runs at once, with lag
-- compensation, when he shoots in his own command (a weapon), so a shot hits what its
-- shooter saw.
--
-- A projectile: mass (g), diameter (mm), penetration (cm of soft tissue), range (m) and,
-- optional, expansion, fragment, fragmentFactor, ap (see the ammo module).
--
-- Emits:    ballistics.impact (owner, ent, pos, dir, energy, outcome) at every contact;
--           outcome: "body", "through", "ricochet", "stop" or "water".

local M = NC.Module("ballistics")

local sqrt = math.sqrt
local exp = math.exp
local log = math.log
local min = math.min
local max = math.max
local cos = math.cos
local sin = math.sin
local rad = math.rad
local deg = math.deg
local asin = math.asin
local band = bit.band
local bor = bit.bor
local format = string.format
local IsValid = IsValid
local Vector = Vector
local CurTime = CurTime
local TraceLine = util.TraceLine
local PointContents = util.PointContents
local DMG_BULLET = DMG_BULLET
local HITGROUP_GENERIC = HITGROUP_GENERIC

local UNIT_M = 0.0254                -- metres per unit
local UNIT_CM = 2.54
local GRAVITY = 9.81 / UNIT_M        -- units/s²
local WATER_DRAG = 800               -- water slows like air this many times denser
local REF_DIAMETER = 9               -- mm: the threat of a 9 mm projectile is its energy
local CONTACTS = 8                   -- contacts of one projectile in one tick at most
local PROBES = { 0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64 } -- units: depths tried for an exit
local MAX_DEPTH = 64                 -- units: the thickest material a projectile goes through
local SURFACE = 0.05                 -- units: a projectile goes on this far past a surface
local CREATURE = 25                  -- cm of flesh of a creature (NPC) a projectile goes through
local RICOCHET_SCATTER = 3           -- degrees
local EXIT_SCATTER = 4               -- degrees at the most, for the thickest material

local WATERS = bor(CONTENTS_WATER, CONTENTS_SLIME)
local MASK = MASK_SHOT
local MASK_AIR = bor(MASK_SHOT, WATERS)

-- Materials (MAT_*): resistance, J per cm of thickness for the threat of a 9 mm round,
-- and the ricochet angle (degrees to the surface: lower glances off, more likely the
-- lower it is).
M.MATERIALS = {
	[MAT_CONCRETE] = { resistance = 400, ricochet = 15 },
	[MAT_METAL] = { resistance = 3500, ricochet = 25 },
	[MAT_VENT] = { resistance = 3500, ricochet = 20 },
	[MAT_GRATE] = { resistance = 3500, ricochet = 20 },
	[MAT_COMPUTER] = { resistance = 600, ricochet = 15 },
	[MAT_TILE] = { resistance = 300, ricochet = 15 },
	[MAT_GLASS] = { resistance = 60, ricochet = 10 },
	[MAT_WOOD] = { resistance = 50, ricochet = 5 },
	[MAT_PLASTIC] = { resistance = 40, ricochet = 8 },
	[MAT_DIRT] = { resistance = 50, ricochet = 6 },
	[MAT_SAND] = { resistance = 70, ricochet = 5 },
	[MAT_GRASS] = { resistance = 50, ricochet = 5 },
	[MAT_SNOW] = { resistance = 20, ricochet = 5 },
	[MAT_FOLIAGE] = { resistance = 3, ricochet = 0 },
	[MAT_EGGSHELL] = { resistance = 30, ricochet = 5 },
	[MAT_FLESH] = { resistance = 10, ricochet = 0 },
	[MAT_BLOODYFLESH] = { resistance = 10, ricochet = 0 },
	[MAT_ALIENFLESH] = { resistance = 15, ricochet = 0 },
	[MAT_ANTLION] = { resistance = 40, ricochet = 5 },
	[MAT_SLOSH] = { resistance = 15, ricochet = 7 },
	[MAT_WARPSHIELD] = { resistance = math.huge, ricochet = 0 },
}
M.DEFAULT_MATERIAL = { resistance = 300, ricochet = 10 }
-- The surface of water: a projectile glances off it below this angle.
M.WATER_RICOCHET = 7

M.Random = math.random

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.damage = ctx:Require("damage")
	self.ammo = ctx:Require("ammo")
	self.n = 0
	self.x, self.y, self.z = {}, {}, {}
	self.vx, self.vy, self.vz = {}, {}, {} -- units/s
	self.def = {}       -- the projectile
	self.v0 = {}        -- m/s at launch: penetration in tissue goes down with the velocity
	self.owner, self.inflictor, self.kind, self.ammoId = {}, {}, {}, {}
	self.dist = {}      -- m flown
	self.born = {}
	self.rico = {}      -- ricochets so far
	self.filter = {}    -- { owner, the body it last went through }
	self.pellet, self.pellets = {}, {}
	self.fired = 0
	self.contacts = 0
	-- Reused by every trace.
	self.start, self.stop = Vector(0, 0, 0), Vector(0, 0, 0)
	self.result, self.probeResult = {}, {}
	self.trace = { start = self.start, endpos = self.stop, mask = MASK, output = self.result }
	local probed
	self.probeFilter = function(ent) return ent == probed end
	self.worldOnly = function() return false end
	self.setProbed = function(ent) probed = ent end
	self.probe = { start = Vector(0, 0, 0), endpos = Vector(0, 0, 0), mask = MASK, output = self.probeResult }
	ctx.commands:Add("nc_ballistics", { help = "projectiles in flight and totals" }, "BallisticsCommand")
end

function M:Start(ctx)
	ctx:Every("fly", 0, "Fly")
end

function M:Stop()
	self:Clear()
end

-- Directions --------------------------------------------------------------------------

local function normalize(x, y, z)
	local length = sqrt(x * x + y * y + z * z)
	if length < 1e-9 then
		return 1, 0, 0
	end
	return x / length, y / length, z / length
end

-- A direction within `angle` degrees of (x, y, z), even over the area of the cone.
function M:_Cone(x, y, z, angle)
	if angle <= 0 then
		return x, y, z
	end
	local R = M.Random
	local a = rad(angle) * sqrt(R())
	local phi = R() * 2 * math.pi
	-- Two axes across the direction.
	local hx, hy, hz = 0, 0, 1
	if z > 0.99 or z < -0.99 then
		hx, hy, hz = 1, 0, 0
	end
	local rx, ry, rz = normalize(y * hz - z * hy, z * hx - x * hz, x * hy - y * hx)
	local wx, wy, wz = ry * z - rz * y, rz * x - rx * z, rx * y - ry * x
	local ca, sa = cos(a), sin(a)
	local cp, sp = cos(phi), sin(phi)
	return normalize(x * ca + (rx * cp + wx * sp) * sa, y * ca + (ry * cp + wy * sp) * sa,
		z * ca + (rz * cp + wz * sp) * sa)
end

-- Launching ---------------------------------------------------------------------------

local EMPTY = {}

-- Fires a round of `ammoId` (the ammo module) from `origin` along `dir` (Vectors): its
-- pellets fly as projectiles. opts: inflictor (the weapon), spread (degrees: the cone of
-- the aim, shared by the pellets), velocity (multiplier of the muzzle velocity: the
-- barrel), filter (an entity the shot cannot hit, e.g. a vehicle), lagCompensate (false:
-- not even in a command of a shooting player). Returns the number of projectiles.
function M:Fire(owner, origin, dir, ammoId, opts)
	local def = self.ammo:Get(ammoId)
	if def == nil then
		error(format("ballistics: Fire: unknown ammo '%s'", tostring(ammoId)), 2)
	end
	opts = opts or EMPTY
	local ux, uy, uz = normalize(dir.x, dir.y, dir.z)
	ux, uy, uz = self:_Cone(ux, uy, uz, opts.spread or 0)
	local velocity = def.velocity * (opts.velocity or 1)
	local speed = velocity / UNIT_M
	local count = def.pellets
	local cfg = self.ctx.config
	local catchUp = 0
	-- Only in a command of the shooter (a weapon): there the engine knows what he saw.
	if cfg.lagCompensation and opts.lagCompensate ~= false and IsValid(owner) and owner:IsPlayer()
		and GetPredictionPlayer() == owner then
		catchUp = min(cfg.maxCatchUp, owner:Ping() / 1000)
	end
	if catchUp > 0 then
		owner:LagCompensation(true)
	end
	for pellet = 1, count do
		local px, py, pz = self:_Cone(ux, uy, uz, def.spread)
		local i = self:_Add(owner, opts.inflictor, origin.x, origin.y, origin.z, px * speed, py * speed, pz * speed, def,
			velocity, "bullet", ammoId, pellet, count, opts.filter)
		if catchUp > 0 then
			self:_Step(i, catchUp, CurTime())
		end
	end
	if catchUp > 0 then
		owner:LagCompensation(false)
	end
	self.fired = self.fired + count
	return count
end

-- Launches one projectile (see the top of the file) from `origin` with `velocity`
-- (Vectors, units/s), e.g. a fragment. opts: inflictor, kind ("fragment" by default: the
-- injury of the organism), ammo (a name for the hits), filter (an entity it cannot hit).
function M:Launch(owner, origin, velocity, projectile, opts)
	assert(type(projectile) == "table" and type(projectile.mass) == "number" and type(projectile.range) == "number",
		"ballistics: Launch(owner, origin, velocity, projectile): projectile needs mass and range")
	opts = opts or EMPTY
	local speed = velocity:Length()
	self:_Add(owner, opts.inflictor, origin.x, origin.y, origin.z, velocity.x, velocity.y, velocity.z, projectile,
		speed * UNIT_M, opts.kind or "fragment", opts.ammo, 1, 1, opts.filter)
	self.fired = self.fired + 1
end

function M:_Add(owner, inflictor, x, y, z, vx, vy, vz, def, v0, kind, ammoId, pellet, pellets, extra)
	if self.n >= self.ctx.config.maxProjectiles then
		local oldest, at = 1, self.born[1]
		for i = 2, self.n do
			if self.born[i] < at then
				oldest, at = i, self.born[i]
			end
		end
		self:_Remove(oldest)
	end
	local i = self.n + 1
	self.n = i
	self.x[i], self.y[i], self.z[i] = x, y, z
	self.vx[i], self.vy[i], self.vz[i] = vx, vy, vz
	self.def[i], self.v0[i] = def, v0
	self.owner[i], self.inflictor[i] = owner, inflictor
	self.kind[i], self.ammoId[i] = kind, ammoId
	self.dist[i], self.born[i], self.rico[i] = 0, CurTime(), 0
	self.pellet[i], self.pellets[i] = pellet, pellets
	-- What it cannot hit, a list without holes (the engine reads it up to the first nil).
	local filter = self.filter[i]
	if filter == nil then
		filter = {}
		self.filter[i] = filter
	end
	if owner ~= nil then
		filter[#filter + 1] = owner
	end
	if extra ~= nil then
		filter[#filter + 1] = extra
	end
	return i
end

local FIELDS = { "x", "y", "z", "vx", "vy", "vz", "def", "v0", "owner", "inflictor", "kind", "ammoId", "dist", "born",
	"rico", "pellet", "pellets" }

-- Removes projectile i: the last one takes its place.
function M:_Remove(i)
	local n = self.n
	if i ~= n then
		for _, field in ipairs(FIELDS) do
			local list = self[field]
			list[i] = list[n]
		end
		self.filter[i], self.filter[n] = self.filter[n], self.filter[i]
	end
	for _, field in ipairs(FIELDS) do
		self[field][n] = nil
	end
	local filter = self.filter[n]
	for k = #filter, 1, -1 do
		filter[k] = nil
	end
	self.n = n - 1
	return false
end

-- Projectiles in flight.
function M:Count()
	return self.n
end

-- Removes every projectile in flight.
function M:Clear()
	while self.n > 0 do
		self:_Remove(self.n)
	end
end

-- Replaces the material `mat` (MAT_*): { resistance = J/cm, ricochet = degrees }.
function M:SetMaterial(mat, def)
	assert(type(mat) == "number" and type(def) == "table" and type(def.resistance) == "number",
		"ballistics: SetMaterial(mat, { resistance, ricochet })")
	M.MATERIALS[mat] = { resistance = def.resistance, ricochet = def.ricochet or 0 }
end

-- Flight ------------------------------------------------------------------------------

function M:Fly(now, dt)
	if dt <= 0 then
		return
	end
	local i = 1
	while i <= self.n do
		if self:_Step(i, dt, now) then
			i = i + 1
		end
	end
end

-- Flies projectile i for `dt` s; false when it is gone (the last one took its place).
function M:_Step(i, dt, now)
	local cfg = self.ctx.config
	if now - self.born[i] > cfg.lifetime then
		return self:_Remove(i)
	end
	local def = self.def[i]
	local mass = def.mass * 0.001
	local x, y, z = self.x[i], self.y[i], self.z[i]
	local vx, vy, vz = self.vx[i], self.vy[i], self.vz[i]
	local g = GRAVITY * cfg.gravity
	local trace, start, stop = self.trace, self.start, self.stop
	trace.filter = self.filter[i]
	local contacts = 0
	while dt > 1e-6 do
		local s = sqrt(vx * vx + vy * vy + vz * vz)
		local v0 = s * UNIT_M
		if 0.5 * mass * v0 * v0 < cfg.minEnergy then
			return self:_Remove(i)
		end
		local ux, uy, uz = vx / s, vy / s, vz / s
		start:SetUnpacked(x, y, z)
		local inWater = band(PointContents(start), WATERS) ~= 0
		local k = (inWater and WATER_DRAG or 1) / def.range
		local kv = k * v0 * dt
		local travel = log(1 + kv) / k / UNIT_M
		local drop = 0.5 * g * dt * dt
		local ex, ey, ez = x + ux * travel, y + uy * travel, z + uz * travel - drop
		stop:SetUnpacked(ex, ey, ez)
		trace.mask = inWater and MASK or MASK_AIR
		local tr = TraceLine(trace)
		if tr.StartSolid then
			return self:_Remove(i)
		end
		if not tr.Hit then
			local v1 = v0 / (1 + kv) / UNIT_M
			x, y, z = ex, ey, ez
			vx, vy, vz = ux * v1, uy * v1, uz * v1 - g * dt
			self.dist[i] = self.dist[i] + travel * UNIT_M
			dt = 0
		else
			local metres = travel * tr.Fraction * UNIT_M
			local v = v0 * exp(-k * metres)
			dt = dt - (exp(k * metres) - 1) / (k * v0)
			self.dist[i] = self.dist[i] + metres
			-- Along the segment, the drop included.
			local sx, sy, sz = normalize(ex - x, ey - y, ez - z)
			contacts = contacts + 1
			self.contacts = self.contacts + 1
			local nx, ny, nz, speed, px, py, pz = self:_Contact(i, tr, sx, sy, sz, v, inWater)
			if nx == nil then
				return self:_Remove(i)
			end
			trace.filter = self.filter[i]
			local f = speed / UNIT_M
			x, y, z = px, py, pz
			vx, vy, vz = nx * f, ny * f, nz * f
			if contacts >= CONTACTS then
				break
			end
		end
	end
	self.x[i], self.y[i], self.z[i] = x, y, z
	self.vx[i], self.vy[i], self.vz[i] = vx, vy, vz
	return true
end

-- Contacts ----------------------------------------------------------------------------

local function attackerOf(self, i)
	local owner = self.owner[i]
	return IsValid(owner) and owner or game.GetWorld()
end

local function inflictorOf(self, i)
	local inflictor = self.inflictor[i]
	if IsValid(inflictor) then
		return inflictor
	end
	return attackerOf(self, i)
end

-- Resolves a contact of projectile i that flies along u at v m/s. Returns the new
-- direction, speed (m/s) and position, or nil when it stops there.
function M:_Contact(i, tr, ux, uy, uz, v, inWater)
	if tr.HitSky then
		return nil
	end
	local hp = tr.HitPos
	if not inWater and band(tr.Contents or 0, WATERS) ~= 0 then
		return self:_Water(i, tr, ux, uy, uz, v)
	end
	local ent = tr.Entity
	if IsValid(ent) then
		if ent:IsPlayer() then
			return self:_Body(i, ent, nil, hp, tr.HitGroup, ux, uy, uz, v)
		end
		local ply = self.organism:PlayerOf(ent)
		if ply ~= nil then
			return self:_Body(i, ply, ent, hp, HITGROUP_GENERIC, ux, uy, uz, v, tr.PhysicsBone)
		end
		if ent:IsNPC() or ent:IsNextBot() then
			return self:_Creature(i, ent, hp, ux, uy, uz, v)
		end
	end
	return self:_Material(i, tr, ent, ux, uy, uz, v)
end

function M:_Emit(i, ent, x, y, z, ux, uy, uz, energy, outcome)
	self.ctx.events:Emit("ballistics.impact", self.owner[i], ent, Vector(x, y, z), Vector(ux, uy, uz), energy, outcome)
end

-- A projectile meets the surface of water: it glances off at a low angle, else goes in.
function M:_Water(i, tr, ux, uy, uz, v)
	local hp, n = tr.HitPos, tr.HitNormal
	local def = self.def[i]
	local energy = 0.5 * def.mass * 0.001 * v * v
	local glance = self:_Glance(i, n, ux, uy, uz, M.WATER_RICOCHET)
	if self.ctx.config.effects then
		local data = EffectData()
		data:SetOrigin(hp)
		data:SetNormal(Vector(0, 0, 1))
		data:SetScale(min(10, 2 + energy / 300))
		util.Effect("gunshotsplash", data, true, true)
	end
	if glance ~= nil then
		local rx, ry, rz, retain = glance[1], glance[2], glance[3], glance[4]
		self:_Emit(i, game.GetWorld(), hp.x, hp.y, hp.z, ux, uy, uz, energy, "ricochet")
		return rx, ry, rz, v * retain, hp.x + n.x * SURFACE, hp.y + n.y * SURFACE, hp.z + n.z * SURFACE
	end
	self:_Emit(i, game.GetWorld(), hp.x, hp.y, hp.z, ux, uy, uz, energy, "water")
	return ux, uy, uz, v, hp.x + ux * SURFACE, hp.y + uy * SURFACE, hp.z + uz * SURFACE
end

local glanced = {}

-- Whether a projectile along u glances off a surface with normal `n` below `limit`
-- degrees: { direction, the share of the speed kept } (reused), or nil.
function M:_Glance(i, n, ux, uy, uz, limit)
	if limit <= 0 or self.rico[i] >= self.ctx.config.ricochets then
		return nil
	end
	local nx, ny, nz = n.x, n.y, n.z
	local d = ux * nx + uy * ny + uz * nz
	local angle = deg(asin(min(1, max(0, -d))))
	if angle >= limit or M.Random() >= 1 - angle / limit then
		return nil
	end
	-- Reflected, flatter than it came (the surface takes part of the normal speed).
	local rx, ry, rz = ux - 2 * d * nx, uy - 2 * d * ny, uz - 2 * d * nz
	local rn = rx * nx + ry * ny + rz * nz
	rx, ry, rz = normalize(rx - 0.5 * rn * nx, ry - 0.5 * rn * ny, rz - 0.5 * rn * nz)
	rx, ry, rz = self:_Cone(rx, ry, rz, RICOCHET_SCATTER)
	-- A scatter must not turn it into the surface.
	if rx * nx + ry * ny + rz * nz < 0.02 then
		rx, ry, rz = normalize(rx + nx * 0.05, ry + ny * 0.05, rz + nz * 0.05)
	end
	self.rico[i] = self.rico[i] + 1
	-- After a ricochet its own shooter is no longer safe.
	local filter = self.filter[i]
	local owner = self.owner[i]
	if owner ~= nil and filter[1] == owner then
		table.remove(filter, 1)
	end
	glanced[1], glanced[2], glanced[3], glanced[4] = rx, ry, rz, 0.75 * (1 - 0.5 * angle / limit)
	return glanced
end

-- A hit on the body of `ply` (in `carrier` when he is down: its physics bone `bone`).
function M:_Body(i, ply, carrier, hp, hitgroup, ux, uy, uz, v, bone)
	local cfg = self.ctx.config
	local def = self.def[i]
	local mass = def.mass * 0.001
	local energy = 0.5 * mass * v * v
	local slow = v / self.v0[i]
	local dir = Vector(ux, uy, uz)
	local hit = { kind = self.kind[i], attacker = attackerOf(self, i), inflictor = inflictorOf(self, i),
		type = DMG_BULLET, amount = energy * cfg.entityDamage, pos = Vector(hp), dir = dir,
		force = dir * (mass * v / UNIT_M), hitgroup = hitgroup, ammo = self.ammoId[i], distance = self.dist[i],
		projectile = { mass = def.mass, velocity = v, diameter = def.diameter, penetration = def.penetration * slow,
			expansion = def.expansion, fragment = def.fragment, fragmentFactor = def.fragmentFactor, ap = def.ap or 1 },
		energy = energy * cfg.scale, pellet = self.pellet[i], pellets = self.pellets[i] }
	local report = self.damage:Inflict(ply, hit)
	local rest
	if report ~= nil then
		rest = hit.stopped and 0 or max(0, hit.energy - report.energy) / cfg.scale
	elseif carrier ~= nil then
		-- A dead body (or one the rules keep out of harm) is flesh in the way.
		rest = max(0, energy - M.MATERIALS[MAT_FLESH].resistance * self:_Factor(def) * CREATURE)
	else
		rest = energy -- the rules keep the player out of harm: as if he was not there
	end
	local filter = self.filter[i]
	filter[#filter + 1] = carrier or ply
	local out = rest > cfg.minEnergy and v * sqrt(rest / energy) or 0
	if carrier ~= nil then
		local phys = carrier:GetPhysicsObjectNum(bone or 0)
		if not IsValid(phys) then
			phys = carrier:GetPhysicsObject()
		end
		if IsValid(phys) then
			phys:ApplyForceOffset(dir * (mass * (v - out) / UNIT_M * cfg.push), hp)
		end
	end
	if cfg.effects then
		local data = EffectData()
		data:SetOrigin(hp)
		data:SetNormal(-dir)
		data:SetScale(min(4, 1 + energy / 1000))
		data:SetColor(0)
		util.Effect("BloodImpact", data, true, true)
		if out > 0 then
			util.Decal("Blood", hp, hp + dir * 128, carrier or ply)
		end
	end
	self:_Emit(i, carrier or ply, hp.x, hp.y, hp.z, ux, uy, uz, energy, "body")
	if out <= 0 then
		return nil
	end
	return ux, uy, uz, out, hp.x + ux * SURFACE, hp.y + uy * SURFACE, hp.z + uz * SURFACE
end

-- How much harder a projectile goes through materials than a 9 mm round of its energy:
-- the divisor of the resistance.
function M:_Factor(def)
	return 1 / (sqrt(REF_DIAMETER / (def.diameter or REF_DIAMETER)) * (def.ap or 1))
end

-- Engine damage of `energy` J and a push of `impulse` (kg·units/s) for an entity.
function M:_EngineDamage(i, ent, hp, ux, uy, uz, energy, impulse)
	local cfg = self.ctx.config
	local dmginfo = DamageInfo()
	dmginfo:SetDamage(energy * cfg.entityDamage)
	dmginfo:SetDamageType(DMG_BULLET)
	dmginfo:SetAttacker(attackerOf(self, i))
	dmginfo:SetInflictor(inflictorOf(self, i))
	dmginfo:SetDamagePosition(hp)
	dmginfo:SetDamageForce(Vector(ux, uy, uz) * (impulse * cfg.push))
	local ammoId = self.ammoId[i]
	if ammoId ~= nil then
		local id = game.GetAmmoID(ammoId)
		if id > 0 then
			dmginfo:SetAmmoType(id)
		end
	end
	ent:TakeDamageInfo(dmginfo)
end

-- A creature of the engine (NPC, nextbot): engine damage, and on through its flesh.
function M:_Creature(i, ent, hp, ux, uy, uz, v)
	local cfg = self.ctx.config
	local def = self.def[i]
	local mass = def.mass * 0.001
	local energy = 0.5 * mass * v * v
	local rest = max(0, energy - M.MATERIALS[MAT_FLESH].resistance * self:_Factor(def) * CREATURE)
	local out = rest > cfg.minEnergy and v * sqrt(rest / energy) or 0
	self:_EngineDamage(i, ent, hp, ux, uy, uz, energy - (out > 0 and rest or 0), mass * (v - out) / UNIT_M)
	local filter = self.filter[i]
	filter[#filter + 1] = ent
	if cfg.effects then
		local data = EffectData()
		data:SetOrigin(hp)
		data:SetNormal(Vector(-ux, -uy, -uz))
		data:SetScale(min(4, 1 + energy / 1000))
		util.Effect("BloodImpact", data, true, true)
	end
	self:_Emit(i, ent, hp.x, hp.y, hp.z, ux, uy, uz, energy, "body")
	if out <= 0 then
		return nil
	end
	return ux, uy, uz, out, hp.x + ux * SURFACE, hp.y + uy * SURFACE, hp.z + uz * SURFACE
end

function M:_Impact(hp, sx, sy, sz, ent, tr)
	local data = EffectData()
	data:SetOrigin(hp)
	data:SetStart(Vector(sx, sy, sz))
	data:SetSurfaceProp(tr and tr.SurfaceProps or 0)
	data:SetHitBox(tr and tr.HitBox or 0)
	data:SetEntity(IsValid(ent) and ent or game.GetWorld())
	data:SetDamageType(DMG_BULLET)
	util.Effect("Impact", data, true, true)
end

-- The world or a prop: a ricochet, or through as deep as the threat allows, or a stop.
function M:_Material(i, tr, ent, ux, uy, uz, v)
	local cfg = self.ctx.config
	local def = self.def[i]
	local mass = def.mass * 0.001
	local energy = 0.5 * mass * v * v
	local hp, n = tr.HitPos, tr.HitNormal
	local hx, hy, hz = hp.x, hp.y, hp.z
	local material = M.MATERIALS[tr.MatType] or M.DEFAULT_MATERIAL
	local isEntity = IsValid(ent)
	if cfg.effects then
		self:_Impact(hp, hx - ux * 32, hy - uy * 32, hz - uz * 32, ent, tr)
	end
	local glance = self:_Glance(i, n, ux, uy, uz, material.ricochet)
	if glance ~= nil then
		local rx, ry, rz, retain = glance[1], glance[2], glance[3], glance[4]
		if isEntity then
			self:_EngineDamage(i, ent, hp, ux, uy, uz, energy * (1 - retain * retain), mass * v * (1 - retain) / UNIT_M)
		end
		self:_Emit(i, ent, hx, hy, hz, ux, uy, uz, energy, "ricochet")
		return rx, ry, rz, v * retain, hx + n.x * SURFACE, hy + n.y * SURFACE, hz + n.z * SURFACE
	end
	-- How deep it could go, cm, and where it comes out. The ground of displacements is a
	-- surface without a far side: nothing goes through it.
	local depth = 0
	if isEntity or (tr.DispFlags or 0) == 0 then
		depth = cfg.penetration * energy / (material.resistance * self:_Factor(def))
	end
	local ex, ey, ez
	if depth > 0 and depth < math.huge then
		ex, ey, ez = self:_Exit(hx, hy, hz, ux, uy, uz, min(MAX_DEPTH, depth / UNIT_CM), isEntity and ent or nil)
	end
	local rest = 0
	if ex ~= nil then
		local thickness = sqrt((ex - hx) ^ 2 + (ey - hy) ^ 2 + (ez - hz) ^ 2) * UNIT_CM
		rest = energy * (1 - thickness / depth)
	end
	local out = rest > cfg.minEnergy and v * sqrt(rest / energy) or 0
	if isEntity then
		self:_EngineDamage(i, ent, hp, ux, uy, uz, energy - (out > 0 and rest or 0), mass * (v - out) / UNIT_M)
	end
	if out <= 0 then
		self:_Emit(i, ent, hx, hy, hz, ux, uy, uz, energy, "stop")
		return nil
	end
	if cfg.effects then
		self:_Impact(Vector(ex, ey, ez), ex + ux * 8, ey + uy * 8, ez + uz * 8, ent, nil)
	end
	self:_Emit(i, ent, hx, hy, hz, ux, uy, uz, energy, "through")
	local nx, ny, nz = self:_Cone(ux, uy, uz, EXIT_SCATTER * (1 - rest / energy))
	return nx, ny, nz, out, ex + ux * SURFACE, ey + uy * SURFACE, ez + uz * SURFACE
end

-- Where a projectile that entered at h along u comes out of what it entered (`ent`, or the
-- world): the first depth (units, up to `depth`) outside of it, traced back to the far
-- surface; nil when it is deeper.
function M:_Exit(hx, hy, hz, ux, uy, uz, depth, ent)
	local probe = self.probe
	if ent ~= nil then
		self.setProbed(ent)
		probe.filter = self.probeFilter
		probe.ignoreworld = true
	else
		probe.filter = self.worldOnly
		probe.ignoreworld = false
	end
	local start, stop = probe.start, probe.endpos
	stop:SetUnpacked(hx + ux * SURFACE, hy + uy * SURFACE, hz + uz * SURFACE)
	for _, d in ipairs(PROBES) do
		local last = d >= depth
		if last then
			d = depth
		end
		start:SetUnpacked(hx + ux * d, hy + uy * d, hz + uz * d)
		local tr = TraceLine(probe)
		if not tr.StartSolid then
			self.setProbed(nil)
			if tr.Hit then
				local p = tr.HitPos
				return p.x, p.y, p.z
			end
			return hx + ux * SURFACE, hy + uy * SURFACE, hz + uz * SURFACE
		end
		if last then
			break
		end
	end
	self.setProbed(nil)
	return nil
end

-- Console ------------------------------------------------------------------------------

function M:BallisticsCommand()
	return format("nc_ballistics: %d in flight (at most %d), %d fired, %d contacts", self.n,
		self.ctx.config.maxProjectiles, self.fired, self.contacts)
end
