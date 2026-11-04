-- Damage, server part: ammunition.
--
-- An ammo type (the name game.GetAmmoName gives) describes one projectile: mass (g),
-- velocity (m/s at the muzzle), diameter (mm), penetration (cm of soft tissue), expansion
-- (how much a hollow point grows), fragment (depth, cm, where it breaks up) and
-- fragmentFactor, range (m: the velocity drops e times over it), ap (how much better it
-- goes through armor, default 1). A shell of shot has one projectile per pellet. Weapon
-- modules register their own types; a bullet of an unknown type carries
-- config.engineEnergy J per point of engine damage.

local M = NC.Module("damage")

local exp = math.exp

-- The ammo of Half-Life 2.
local PISTOL = { mass = 8, velocity = 360, diameter = 9, penetration = 45, range = 540 }         -- 9x19 mm
local HEAVY = { mass = 45, velocity = 900, diameter = 14.5, penetration = 100, range = 1000 }    -- 14.5 mm
local SNIPER = { mass = 9.7, velocity = 850, diameter = 7.8, penetration = 70, fragment = 15, fragmentFactor = 1.5,
	range = 800 }                                                                                 -- 7.62x51 mm
M.AMMO_DEFAULTS = {
	Pistol = PISTOL,
	AlyxGun = PISTOL,
	["357"] = { mass = 10.2, velocity = 440, diameter = 9.1, penetration = 55, expansion = 0.6, range = 500 },
	SMG1 = { mass = 2, velocity = 720, diameter = 4.6, penetration = 35, range = 320, ap = 1.4 }, -- 4.6x30 mm
	AR2 = { mass = 4, velocity = 940, diameter = 5.7, penetration = 35, fragment = 10, fragmentFactor = 2,
		range = 600 },                                                                            -- 5.56x45 mm
	Buckshot = { mass = 3.5, velocity = 400, diameter = 8.4, penetration = 30, range = 100 },     -- a 00 pellet
	XBowBolt = { mass = 100, velocity = 120, diameter = 10, penetration = 80, range = 300, ap = 1.5 },
	SniperRound = SNIPER,
	SniperPenetratedRound = SNIPER,
	AirboatGun = { mass = 30, velocity = 800, diameter = 12.7, penetration = 80, range = 900 },
	StriderMinigun = HEAVY,
	StriderMinigunDirect = HEAVY,
	HelicopterGun = HEAVY,
	CombineCannon = HEAVY,
	CombineHeavyCannon = HEAVY,
}

-- A bullet of unknown ammo: its energy comes from the engine damage.
local UNKNOWN = { mass = 8, velocity = 360, diameter = 9, penetration = 40, range = 500 }

local FIELDS = { "mass", "velocity", "diameter", "penetration", "range" }

-- Registers or replaces an ammo type. def: see the top of the file; mass, velocity,
-- diameter, penetration and range are required.
function M:RegisterAmmo(name, def)
	assert(type(name) == "string" and name ~= "", "damage: RegisterAmmo(name, def): name must be a string")
	assert(type(def) == "table", "damage: RegisterAmmo: def of '" .. name .. "' must be a table")
	for _, field in ipairs(FIELDS) do
		local value = def[field]
		assert(type(value) == "number" and value > 0,
			"damage: RegisterAmmo: " .. field .. " of '" .. name .. "' must be a positive number")
	end
	self.ammo[name] = def
end

-- The definition of an ammo type, or nil.
function M:Ammo(name)
	return name ~= nil and self.ammo[name] or nil
end

-- The projectile of a bullet of ammo `name` after `distance` m and its energy (J), from
-- `damage` of the engine when the ammo is unknown. Returns a new table.
function M:Projectile(name, distance, damage)
	local def = self:Ammo(name)
	local known = def ~= nil
	def = def or UNKNOWN
	local slow = exp(-(distance or 0) / def.range)
	local velocity = def.velocity * slow
	local projectile = { mass = def.mass, velocity = velocity, diameter = def.diameter,
		penetration = def.penetration * slow, expansion = def.expansion, fragment = def.fragment,
		fragmentFactor = def.fragmentFactor, ap = def.ap or 1 }
	local energy
	if known then
		energy = 0.5 * def.mass * 0.001 * velocity * velocity
	else
		energy = (damage or 0) * self.ctx.config.engineEnergy * slow * slow
	end
	return projectile, energy * self.ctx.config.scale
end
