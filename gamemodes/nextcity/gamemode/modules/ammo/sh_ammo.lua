-- Ammo, shared part: the registry of ammunition.
--
-- Packages register their rounds (Register, in Init of their module: both realms, in the
-- same order, before the game starts); the core has none. An ammo type is one round:
--   id         also the name of its engine ammo type (weapons, GiveAmmo, the HUD)
--   caliber    rounds of one caliber fit the same weapons ("9x19", "12/70", ...)
--   mass       g, of one projectile
--   velocity   m/s at the muzzle of the reference barrel
--   diameter   mm
--   penetration cm of soft tissue
--   range      m: air drag slows the projectile e times over it
--   expansion  how much a hollow point grows (0: none), optional
--   fragment   cm: the depth where it breaks up, and fragmentFactor, optional
--   ap         how much better it goes through armor and walls, default 1
--   pellets    projectiles in one round (shot), default 1
--   spread     degrees: the cone of the pellets, default 0
--   maxCarry   rounds a player may carry in the engine reserve, default config.maxCarry
-- Names are translated: "ammo.<id>" in the language files of the package.

local M = NC.Module("ammo")

local exp = math.exp
local format = string.format

local REQUIRED = { "mass", "velocity", "diameter", "penetration", "range" }
local OPTIONAL = { "expansion", "fragment", "fragmentFactor", "ap", "pellets", "spread", "maxCarry" }
local DMG_BULLET = DMG_BULLET

function M:Init(ctx)
	self.types = {}    -- id -> ammo type
	self.order = {}    -- ids in the order of registration
	self.calibers = {} -- caliber -> ids
	if SERVER then
		self:_InitServer(ctx)
	end
end

local function fail(id, message)
	error(format("ammo: Register('%s'): %s", tostring(id), message), 3)
end

-- Registers or replaces the ammo type `id` (see the top of the file). Returns it.
function M:Register(id, def)
	if type(id) ~= "string" or not id:find("^[%w_%.%-]+$") then
		fail(id, "id must be a string of letters, digits, _ . -")
	end
	if type(def) ~= "table" then
		fail(id, "def must be a table")
	end
	if type(def.caliber) ~= "string" or def.caliber == "" then
		fail(id, "caliber must be a string")
	end
	for _, field in ipairs(REQUIRED) do
		local value = def[field]
		if type(value) ~= "number" or value <= 0 then
			fail(id, field .. " must be a positive number")
		end
	end
	for _, field in ipairs(OPTIONAL) do
		local value = def[field]
		if value ~= nil and (type(value) ~= "number" or value < 0) then
			fail(id, field .. " must be a number >= 0")
		end
	end
	local entry = {}
	for key, value in pairs(def) do
		entry[key] = value
	end
	entry.id = id
	entry.ap = def.ap or 1
	entry.pellets = math.max(1, math.floor(def.pellets or 1))
	entry.spread = def.spread or 0
	entry.maxCarry = def.maxCarry or self.ctx.config.maxCarry
	local old = self.types[id]
	if old == nil then
		self.order[#self.order + 1] = id
	elseif old.caliber ~= entry.caliber then
		self:_Uncaliber(id, old.caliber)
	end
	self.types[id] = entry
	local list = self.calibers[entry.caliber]
	if list == nil then
		list = {}
		self.calibers[entry.caliber] = list
	end
	local listed = false
	for _, other in ipairs(list) do
		listed = listed or other == id
	end
	if not listed then
		list[#list + 1] = id
	end
	-- After an autorefresh the engine still has the type.
	if game.GetAmmoID(id) == -1 then
		game.AddAmmoType({ name = id, dmgtype = DMG_BULLET, tracer = 0, plydmg = 0, npcdmg = 0, force = 0,
			maxcarry = entry.maxCarry, minsplash = 4, maxsplash = 8 })
	end
	self:_Registered(entry)
	return entry
end

function M:_Uncaliber(id, caliber)
	local list = self.calibers[caliber]
	for i = #(list or {}), 1, -1 do
		if list[i] == id then
			table.remove(list, i)
		end
	end
end

-- The server part tells the damage pipeline (sv_ammo.lua).
function M:_Registered() end

-- The ammo type `id` (do not modify), or nil.
function M:Get(id)
	return id ~= nil and self.types[id] or nil
end

-- Ids of the ammo types of `caliber`, in the order of registration (a new list).
function M:OfCaliber(caliber)
	local out = {}
	for i, id in ipairs(self.calibers[caliber] or {}) do
		out[i] = id
	end
	return out
end

-- Ids of every ammo type, in the order of registration (a new list).
function M:All()
	local out = {}
	for i, id in ipairs(self.order) do
		out[i] = id
	end
	return out
end

-- Velocity (m/s) and energy (J) of one projectile of `id` after `distance` m of flight
-- (by air drag alone), or nil for an unknown type.
function M:At(id, distance)
	local def = self.types[id]
	if def == nil then
		return nil
	end
	local velocity = def.velocity * exp(-(distance or 0) / def.range)
	return velocity, 0.5 * def.mass * 0.001 * velocity * velocity
end
