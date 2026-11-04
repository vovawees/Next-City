-- Throwables, shared part: the registry of the thrown weapons of packages.
--
-- Packages register their throwables in Init of their module (both realms, in the same
-- order): Register(class, def) makes the scripted weapon `class` on the base nc_throwable
-- (sh_throw.lua) and the ammo type `class`: how many a player carries. A definition is
-- data:
--   model        the world model of the weapon and of the thrown thing (required)
--   mass         kg of the thing (0.4)
--   energy       J of a full overhand throw (60); underhand: config.lob of it
--   fuse         s from the spoon flying off (at the throw, or earlier by the reload key:
--                cooking) to going off; nil: no fuse
--   impact       true: goes off on the first hit at config.impactSpeed or faster, arm s
--                after the throw (0)
--   detonate     function(ent, thrower, pos, def) of the server: what going off does (ent
--                is no longer valid when the thing broke on the hit: use pos); remove: the
--                thing is removed after it (true)
--   pull, throwTime, draw
--                s to pull the pin (0.5; twice as long with one working arm), of the throw
--                before the next one (0.5), to draw it (0.5)
--   count, max   how many come with the weapon (1) and how many a player carries (3)
--   stamina      the share of the stamina a throw takes (0.03)
--   entity       the class of the thrown thing ("prop_physics")
--   anims        ACT_VM_* of { pull (ACT_VM_PULLPIN), throw (ACT_VM_THROW), lob (ACT_VM_THROW) }
--   sounds       { draw, pin, spoon, throw, bounce } (sound names)
--   holdType, viewModel, viewModelFOV, viewModelFlip, useHands, slot, slotPos, weight
--                as in the engine ("grenade", slot 4)
--   name         the key of the translated name ("throwables.<class>")
--
-- Emits:    throwables.thrown (owner, ent, class), throwables.detonated (ent, class,
--           thrower, pos)  server
-- Commands: nc_throwables (sv_throwables.lua)

local M = NC.Module("throwables")

local format = string.format

M.BASE = "nc_throwable"

local DEFAULTS = { mass = 0.4, energy = 60, arm = 0, pull = 0.5, throwTime = 0.5, draw = 0.5, count = 1, max = 3,
	stamina = 0.03 }

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.defs = {}  -- class -> definition
	self.order = {} -- classes in the order of registration
	self:_RegisterBase()
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

local function fail(class, message)
	error(format("throwables: Register('%s'): %s", tostring(class), message), 3)
end

-- Registers or replaces the throwable `class` of a package (see the top of the file): the
-- definition (a copy), its ammo type and its scripted weapon. Returns the definition.
function M:Register(class, def)
	if type(class) ~= "string" or not class:find("^[%l%d_]+$") or class == M.BASE then
		fail(class, "class must be a string of lowercase letters, digits and _ (not the base)")
	end
	if type(def) ~= "table" then
		fail(class, "def must be a table")
	end
	if type(def.model) ~= "string" or def.model == "" then
		fail(class, "model must be a model path")
	end
	local entry = {}
	for key, value in pairs(def) do
		entry[key] = value
	end
	for field, default in pairs(DEFAULTS) do
		local value = entry[field]
		if value == nil then
			entry[field] = default
		elseif type(value) ~= "number" or value < 0 then
			fail(class, field .. " must be a number >= 0")
		end
	end
	if entry.mass <= 0 then
		fail(class, "mass must be a number > 0")
	end
	if entry.fuse ~= nil and (type(entry.fuse) ~= "number" or entry.fuse < 0) then
		fail(class, "fuse must be a number >= 0 or nil")
	end
	if entry.fuse == nil and not entry.impact and entry.detonate ~= nil then
		fail(class, "a thing that goes off needs a fuse or impact")
	end
	if entry.detonate ~= nil and type(entry.detonate) ~= "function" then
		fail(class, "detonate must be a function")
	end
	for _, field in ipairs({ "count", "max" }) do
		if entry[field] < 1 or entry[field] % 1 ~= 0 then
			fail(class, field .. " must be a whole number >= 1")
		end
	end
	for _, field in ipairs({ "anims", "sounds" }) do
		if entry[field] ~= nil and type(entry[field]) ~= "table" then
			fail(class, field .. " must be a table")
		end
	end
	local anims = entry.anims or {}
	entry.anims = { pull = anims.pull or ACT_VM_PULLPIN, throw = anims.throw or ACT_VM_THROW,
		lob = anims.lob or anims.throw or ACT_VM_THROW }
	entry.sounds = entry.sounds or {}
	entry.class = class
	entry.ammo = class
	entry.entity = entry.entity or "prop_physics"
	entry.remove = entry.remove ~= false
	entry.holdType = entry.holdType or "grenade"
	entry.name = entry.name or "throwables." .. class
	if self.defs[class] == nil then
		self.order[#self.order + 1] = class
	end
	self.defs[class] = entry
	-- After an autorefresh the engine still has the type.
	if game.GetAmmoID(class) == -1 then
		game.AddAmmoType({ name = class, dmgtype = DMG_BLAST, tracer = 0, plydmg = 0, npcdmg = 0, force = 0,
			maxcarry = entry.max, minsplash = 4, maxsplash = 8 })
	end
	weapons.Register(self:_Class(entry), class)
	return entry
end

-- The scripted weapon of definition `def`: what the engine reads of the table.
function M:_Class(def)
	return {
		Base = M.BASE,
		PrintName = self:Name(def.class),
		Slot = def.slot or 4,
		SlotPos = def.slotPos or 0,
		Weight = def.weight or 1,
		HoldType = def.holdType,
		ViewModel = def.viewModel,
		WorldModel = def.model,
		ViewModelFOV = def.viewModelFOV,
		ViewModelFlip = def.viewModelFlip,
		UseHands = def.useHands,
		Primary = { ClipSize = -1, DefaultClip = def.count, Automatic = false, Ammo = def.ammo },
	}
end

-- The definition of the throwable `class` (do not modify), or nil.
function M:Get(class)
	return class ~= nil and self.defs[class] or nil
end

-- Classes of every registered throwable, in the order of registration (a new list).
function M:All()
	local out = {}
	for i, class in ipairs(self.order) do
		out[i] = class
	end
	return out
end

-- The translated name of the throwable `class` (the class without a translation).
function M:Name(class)
	local def = self.defs[class]
	local key = def ~= nil and def.name or "throwables." .. tostring(class)
	local i18n = self.ctx.i18n
	return i18n:Has(key) and i18n:T(key) or tostring(class)
end

-- The speed in units/s of a throw of `energy` J of a thing of `mass` kg: E = m·v²/2.
function M.Speed(energy, mass)
	return math.sqrt(2 * math.max(0, energy) / mass) / 0.0254
end
