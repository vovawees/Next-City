-- Explosions, server part.
--
-- Explode(pos, opts) sets off `charge` kg of TNT equivalent at `pos`:
--   blast      the peak overpressure at the middle of every body by the scaled distance
--              Z = R / W^(1/3) (Kinney–Graham, a burst in free air; on the ground the wave
--              reflects and the charge counts 1.8 times), a quarter of it behind the
--              world. It is a "blast" hit of the organism through damage:Inflict with the
--              amount of half the kPa: the lungs, a concussion, a throw; about 500 kPa
--              (amount 250) kills at once, 120 kPa (60) knocks down
--   fragments  the casing breaks up into fragments that fly as projectiles of ballistics
--              every way, or in a cone (a directional charge), and can hit the owner of
--              the charge too; they leave at Gurney's speed of the charge and the casing.
--              Without ballistics a body gets the hits expected for its size
--   engine     util.BlastDamageInfo pushes and breaks props, hurts creatures and pushes
--              fallen bodies; it does not hurt players (their blast is the one above)
--   effects    the explosion with its sound, a scorch mark, a shake of the screens
--
-- opts (all optional): attacker, inflictor (the grenade), charge (kg of TNT, 0.2), casing
-- (kg of metal that breaks up, 0), fragments (their number: a gram each by default),
-- fragment ({ mass g, velocity m/s, diameter mm, penetration cm, range m, ap }: by default
-- a share of the casing at Gurney's speed, a chunk of steel of that mass), dir and cone
-- (degrees: the fragments fly in this cone around dir), radius and damage (of the engine
-- blast, by the charge), filter (an entity the fragments cannot hit), effects (false).
--
-- Emits:    explosions.exploded (pos, attacker, inflictor, charge)
-- Answers:  damage.kind: false for players during the engine blast
-- Commands: nc_explode [charge] [casing] [player]

local M = NC.Module("explosions")

local sqrt = math.sqrt
local min = math.min
local max = math.max
local floor = math.floor
local cos = math.cos
local sin = math.sin
local rad = math.rad
local pi = math.pi
local format = string.format
local IsValid = IsValid
local Vector = Vector
local TraceLine = util.TraceLine

local UNIT_M = 0.0254      -- metres per unit
local CENTER = 36          -- the middle of a standing body above its origin, units
local GROUND = 12          -- a charge this close above the world lies on it, units
local SURFACE = 1.8        -- ...and counts this many times: the wave reflects off the ground
local COVER = 0.25         -- the share of the wave that bends around the world
local Z_MAX = 12           -- m/kg^(1/3): farther the wave is harmless (under 8 kPa)
local KPA_AMOUNT = 0.5     -- the amount of a blast hit per kPa
local MIN_AMOUNT = 1
local GURNEY = 2440        -- m/s: Gurney's constant √(2E) of TNT
local STEEL = 7.85         -- g/cm³
local AIR = 1.225          -- kg/m³
local DRAG = 1             -- drag coefficient of a chunk of metal
local SHAPE = 1.2          -- the face of a chunk against a cube of its volume
local FRAGMENT_SD = 15     -- cm of soft tissue a fragment of 1 g goes through
local BODY_AREA = 0.5      -- m²: the side of a body (fragments without ballistics)
local FORCE = 300          -- engine force per point of blast damage, like the engine's
local DAMAGE = 200         -- engine damage at the centre per kg^(1/3)
local GOLDEN = pi * (3 - sqrt(5))
local MASK_WORLD = MASK_SOLID_BRUSHONLY
local EMPTY = {}

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.damage = ctx:Require("damage")
	self.ballistics = ctx:Require("ballistics")
	self.players = ctx:Require("players")
	self.blasting = false
	self.count = 0     -- explosions so far
	self.launched = 0  -- fragments so far
	self.Random = math.random
	self.trace = {}
	self.traceOut = {}
	ctx.commands:Add("nc_explode", { help = "an explosion where you look: [charge kg] [casing kg] [player]" },
		"ExplodeCommand")
end

function M:Start(ctx)
	ctx:On("damage.kind", "AnswerKind", { priority = 100 })
end

-- The engine blast of Explode does not hurt players: their blast is a hit of their own.
function M:AnswerKind()
	if self.blasting then
		return false
	end
end

-- Physics ------------------------------------------------------------------------------

-- The peak overpressure, kPa, at the scaled distance `z` (m/kg^(1/3)) of a burst of TNT in
-- free air (Kinney–Graham).
function M.Overpressure(z)
	local a, b, c, d = z / 4.5, z / 0.048, z / 0.32, z / 1.35
	return 101.325 * 808 * (1 + a * a) / sqrt((1 + b * b) * (1 + c * c) * (1 + d * d))
end

-- Gurney's speed, m/s, of the fragments of a sphere of `casing` kg around `charge` kg.
function M.FragmentSpeed(charge, casing)
	if charge <= 0 then
		return 0
	end
	return GURNEY / sqrt(casing / charge + 0.6)
end

-- A chunk of steel of `mass` g: its diameter (mm), the range of its drag (m) and how deep
-- it goes into soft tissue (cm).
function M.Chunk(mass)
	local side = (mass / STEEL) ^ (1 / 3) * SHAPE -- cm
	local diameter = side * 10
	local area = pi * (diameter / 2000) ^ 2       -- m²
	return diameter, 2 * mass / 1000 / (AIR * DRAG * area), FRAGMENT_SD * mass ^ (1 / 3)
end

-- The fragment of `opts` (see the top of the file), or nil, and how many fly: the casing
-- (or fragments of a given mass) breaks up into opts.fragments, of which the settings
-- launch a share, at most maxFragments.
function M:_Fragment(opts, charge)
	local given = opts.fragment or EMPTY
	local count = opts.fragments
	local casing = opts.casing or 0
	if casing <= 0 then
		if given.mass == nil or count == nil then
			return nil, 0
		end
		casing = given.mass * count / 1000
	end
	count = count or max(1, floor(casing * 1000 + 0.5))
	local mass = given.mass or casing * 1000 / count
	local config = self.ctx.config
	count = min(floor(count * config.fragments + 0.5), config.maxFragments)
	if count <= 0 or mass <= 0 then
		return nil, 0
	end
	local diameter, range, penetration = M.Chunk(mass)
	local fragment = { mass = mass, diameter = given.diameter or diameter, range = given.range or range,
		penetration = given.penetration or penetration, ap = given.ap, expansion = given.expansion,
		velocity = given.velocity or M.FragmentSpeed(charge, casing) }
	return fragment, count
end

-- Directions of `count` fragments, even over the sphere or the cone of `cone` degrees
-- around `dir`: a golden spiral turned at random. Calls fn(x, y, z) for each.
function M:_Spray(count, dir, cone, fn)
	local R = self.Random
	local spin = R() * 2 * pi
	local top = 1
	local bottom = -1
	local ax, ay, az = 0, 0, 1
	if dir ~= nil and cone ~= nil and cone < 180 then
		bottom = cos(rad(cone))
		local d = dir:GetNormalized()
		ax, ay, az = d:Unpack()
	end
	-- A basis around the axis.
	local ux, uy, uz
	if math.abs(az) < 0.9 then
		ux, uy, uz = -ay, ax, 0
	else
		ux, uy, uz = 0, -az, ay
	end
	local length = sqrt(ux * ux + uy * uy + uz * uz)
	ux, uy, uz = ux / length, uy / length, uz / length
	local vx, vy, vz = ay * uz - az * uy, az * ux - ax * uz, ax * uy - ay * ux
	for i = 0, count - 1 do
		local c = top - (top - bottom) * (i + 0.5) / count
		local s = sqrt(max(0, 1 - c * c))
		local phi = spin + i * GOLDEN
		local cp, sp = cos(phi) * s, sin(phi) * s
		fn(ax * c + ux * cp + vx * sp, ay * c + uy * cp + vy * sp, az * c + uz * cp + vz * sp)
	end
end

-- Explosions ---------------------------------------------------------------------------

-- Whether the world is between `a` and `b`.
function M:_Blocked(a, b)
	local trace, out = self.trace, self.traceOut
	trace.start, trace.endpos, trace.mask, trace.filter, trace.output = a, b, MASK_WORLD, nil, out
	TraceLine(trace)
	return out.Hit and out.Fraction < 0.99
end

-- The middle of the body of `ply`: his hull, or the body he is down in.
function M:_Center(ply)
	local carrier = self.organism:Carrier(ply)
	if carrier ~= nil then
		return carrier:GetPos()
	end
	local pos = ply:GetPos()
	pos.z = pos.z + (ply:Crouching() and CENTER * 0.6 or CENTER)
	return pos
end

-- Sets off a charge at `pos` (see the top of the file). Returns the bodies it hit and the
-- fragments it launched.
function M:Explode(pos, opts)
	opts = opts or {}
	local config = self.ctx.config
	local charge = max(0, opts.charge or 0.2)
	local attacker = opts.attacker
	if not IsValid(attacker) then
		attacker = game.GetWorld()
	end
	local inflictor = IsValid(opts.inflictor) and opts.inflictor or attacker
	local effective = charge
	if self:_Blocked(pos, pos - Vector(0, 0, GROUND)) then
		effective = charge * SURFACE
	end
	local root = effective ^ (1 / 3)
	local radius = opts.radius or Z_MAX * root / UNIT_M
	local fragment, count = self:_Fragment(opts, charge)
	self.count = self.count + 1

	local bodies = self:_Blast(pos, opts, attacker, inflictor, root, fragment, count)
	local launched = 0
	if fragment ~= nil and self.ballistics ~= nil then
		launched = self:_Launch(pos, opts, attacker, inflictor, fragment, count)
	end
	if config.engine and charge > 0 then
		self:_EngineBlast(pos, attacker, inflictor, opts.damage or DAMAGE * root, radius)
	end
	if config.effects and opts.effects ~= false and charge > 0 then
		self:_Effects(pos, root, radius)
	end
	self.ctx.events:Emit("explosions.exploded", pos, attacker, inflictor, charge)
	return bodies, launched
end

-- The blast wave on every living body in reach; without ballistics, also the fragments
-- expected to hit it. Returns the number of bodies hit.
function M:_Blast(pos, opts, attacker, inflictor, root, fragment, count)
	local config = self.ctx.config
	local organism = self.organism
	local reach = Z_MAX * root
	local cone = opts.dir ~= nil and opts.cone ~= nil and opts.cone < 180 and opts.cone or nil
	local axis = cone ~= nil and opts.dir:GetNormalized() or nil
	local solid = cone ~= nil and 2 * pi * (1 - cos(rad(cone))) or 4 * pi
	local expected = fragment ~= nil and self.ballistics == nil
	local hits = 0
	for _, ply in ipairs(player.GetAll()) do
		if organism:IsSimulated(ply) and not organism:IsDead(ply) then
			local center = self:_Center(ply)
			local offset = center - pos
			local distance = max(offset:Length() * UNIT_M, 0.05)
			if distance <= reach then
				local covered = self:_Blocked(pos, center)
				local kpa = root > 0 and M.Overpressure(distance / root) or 0
				local amount = kpa * KPA_AMOUNT * (covered and COVER or 1) * config.blast
				local fragments = 0
				if expected and not covered and (axis == nil or offset:GetNormalized():Dot(axis) >= cos(rad(cone))) then
					local mean = count * BODY_AREA / (solid * distance * distance)
					fragments = min(count, floor(mean + self.Random()))
				end
				if amount >= MIN_AMOUNT or fragments > 0 then
					local dir = offset:LengthSqr() > 1e-6 and offset:GetNormalized() or Vector(0, 0, 1)
					local hit = { kind = "blast", attacker = attacker, inflictor = inflictor, type = DMG_BLAST,
						amount = amount, dir = dir, force = dir * min(amount * FORCE, 30000), fragments = fragments }
					if self.damage:Inflict(ply, hit) ~= nil then
						hits = hits + 1
					end
				end
			end
		end
	end
	return hits
end

-- The fragments as projectiles; their number.
function M:_Launch(pos, opts, attacker, inflictor, fragment, count)
	local ballistics = self.ballistics
	local speed = fragment.velocity / UNIT_M
	local owner = attacker ~= game.GetWorld() and attacker or nil
	local launch = { inflictor = inflictor, kind = "fragment", ammo = opts.ammo, filter = opts.filter,
		hitsOwner = true }
	self:_Spray(count, opts.dir, opts.cone, function(x, y, z)
		ballistics:Launch(owner, Vector(pos.x + x, pos.y + y, pos.z + z), Vector(x * speed, y * speed, z * speed),
			fragment, launch)
	end)
	self.launched = self.launched + count
	return count
end

-- The blast of the engine for everything but the bodies of players.
function M:_EngineBlast(pos, attacker, inflictor, damage, radius)
	local dmginfo = DamageInfo()
	dmginfo:SetAttacker(attacker)
	dmginfo:SetInflictor(inflictor)
	dmginfo:SetDamage(damage)
	dmginfo:SetDamageType(DMG_BLAST)
	dmginfo:SetDamagePosition(pos)
	self.blasting = true
	local ok, err = pcall(util.BlastDamageInfo, dmginfo, pos, radius)
	self.blasting = false
	if not ok then
		self.ctx.log:Error("engine blast failed: %s", tostring(err))
	end
end

function M:_Effects(pos, root, radius)
	local data = EffectData()
	data:SetOrigin(pos)
	data:SetMagnitude(root)
	data:SetScale(root)
	local water = bit.band(util.PointContents(pos), CONTENTS_WATER) ~= 0
	util.Effect(water and "WaterSurfaceExplosion" or "Explosion", data, true, true)
	if not water then
		util.Decal("Scorch", pos + Vector(0, 0, 8), pos - Vector(0, 0, 32))
	end
	util.ScreenShake(pos, min(25, 10 * root), 150, 0.5 + root, radius * 2)
end

-- The console -------------------------------------------------------------------------------

function M:ExplodeCommand(caller, args)
	local charge = tonumber(args[1] or "") or 0.2
	local casing = tonumber(args[2] or "") or 0
	local pos
	if args[3] ~= nil then
		local ply, problem = self.players:Find(args[3], caller)
		if ply == nil then
			return "nc_explode: " .. problem
		end
		pos = ply:GetPos() + Vector(0, 0, 4)
	elseif IsValid(caller) then
		local eye = caller:EyePos()
		local trace, out = self.trace, self.traceOut
		trace.start, trace.endpos, trace.mask, trace.filter, trace.output = eye, eye + caller:GetAimVector() * 4096,
			MASK_SOLID, caller, out
		TraceLine(trace)
		pos = out.HitPos + out.HitNormal * 4
	else
		return "nc_explode: from the server console give a player"
	end
	local bodies, fragments = self:Explode(pos, { attacker = caller, charge = charge, casing = casing })
	return format("nc_explode: %.2f kg at %.0f %.0f %.0f: %d bodies, %d fragments", charge, pos.x, pos.y, pos.z,
		bodies, fragments)
end
