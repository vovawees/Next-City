-- Melee, shared part: the registry of the melee weapons of packages and the strike.
--
-- Packages register their weapons in Init of their module (both realms, in the same
-- order): Register(class, def) makes the scripted weapon `class` on the base nc_melee
-- (sh_swing.lua). A definition is data:
--   primary      the attack of the attack key; secondary: of the attack 2 key (optional):
--                  kind      the injury: "blunt", "slash" or "stab"
--                  energy    J of a full strike (60)
--                  depth     cm a blade goes in at full energy (slash 4, stab 12; blades)
--                  reach     units from the eyes (48); size: the half side of the swing (4)
--                  windup    s from the press to the strike (0.15); recovery: s after it
--                            before the next attack (0.35)
--                  stamina   the share of the stamina a swing takes (0.02)
--                  damage    engine damage to props and creatures (energy·entityDamage)
--                  anims     ACT_VM_* of { swing (ACT_VM_MISSCENTER), hit (on a hit) }
--                  sounds    { swing, hit (a body), world (the rest) } (sound names)
--   hands        2, or 1: a one-handed weapon is as good in one hand
--   draw         s to draw it (0.5); sounds: { draw }
--   holdType, viewModel, worldModel, viewModelFOV, viewModelFlip, useHands, slot, slotPos,
--   weight       as in the engine
--   name         the key of the translated name ("melee.<class>")
-- A strike traces a line from the eyes (hitboxes), and a hull of the swing when it
-- misses; a hull that meets the side of a body turns the blow at its middle. Bodies (a
-- player, or the body he is down in) take a hit of the organism through damage:Inflict;
-- props, creatures and glass take engine damage, the world only the effects.
--
-- Emits:    melee.struck (owner, weapon, ent, index)  server, every strike that meets
--           something (index: 1 primary, 2 secondary; ent: the world too)
-- Commands: nc_melee (sv_melee.lua)

local M = NC.Module("melee")

local format = string.format
local IsValid = IsValid
local Vector = Vector
local TraceLine = util.TraceLine
local TraceHull = util.TraceHull

M.BASE = "nc_melee"
M.KINDS = { blunt = true, slash = true, stab = true }

local ATTACK = { energy = 60, reach = 48, size = 4, windup = 0.15, recovery = 0.35, stamina = 0.02 }
local DEPTH = { slash = 4, stab = 12 } -- cm a blade goes in by default
local CENTER = 36 -- the middle of a standing body above its origin, units
local EMPTY = {}

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.players = ctx:Require("players")
	self.damage = ctx:Require("damage")
	self.defs = {}  -- class -> definition
	self.order = {} -- classes in the order of registration
	self.trace = {}
	self.traceOut = {}
	self:_RegisterBase()
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

local function fail(class, message)
	error(format("melee: Register('%s'): %s", tostring(class), message), 3)
end

-- The attack `given` with its defaults (a new table), or nil and a problem.
function M:_Attack(given, name)
	if type(given) ~= "table" then
		return nil, name .. " must be a table"
	end
	if not M.KINDS[given.kind] then
		return nil, name .. ".kind must be blunt, slash or stab"
	end
	local attack = {}
	for key, value in pairs(given) do
		attack[key] = value
	end
	for field, default in pairs(ATTACK) do
		local value = attack[field]
		if value == nil then
			attack[field] = default
		elseif type(value) ~= "number" or value < 0 then
			return nil, format("%s.%s must be a number >= 0", name, field)
		end
	end
	if attack.windup + attack.recovery <= 0 then
		return nil, name .. ": windup + recovery must be over 0"
	end
	if attack.depth ~= nil and (type(attack.depth) ~= "number" or attack.depth <= 0) then
		return nil, name .. ".depth must be a number > 0"
	end
	attack.depth = attack.depth or DEPTH[attack.kind]
	for _, field in ipairs({ "anims", "sounds" }) do
		if attack[field] ~= nil and type(attack[field]) ~= "table" then
			return nil, format("%s.%s must be a table", name, field)
		end
	end
	local anims = attack.anims or EMPTY
	attack.anims = { swing = anims.swing or ACT_VM_MISSCENTER, hit = anims.hit }
	attack.sounds = attack.sounds or {}
	return attack
end

-- Registers or replaces the weapon `class` of a package (see the top of the file): the
-- definition (a copy) and its scripted weapon. Returns the definition.
function M:Register(class, def)
	if type(class) ~= "string" or not class:find("^[%l%d_]+$") or class == M.BASE then
		fail(class, "class must be a string of lowercase letters, digits and _ (not the base)")
	end
	if type(def) ~= "table" then
		fail(class, "def must be a table")
	end
	local entry = {}
	for key, value in pairs(def) do
		entry[key] = value
	end
	local problem
	entry.primary, problem = self:_Attack(def.primary, "primary")
	if entry.primary == nil then
		fail(class, problem)
	end
	if def.secondary ~= nil then
		entry.secondary, problem = self:_Attack(def.secondary, "secondary")
		if entry.secondary == nil then
			fail(class, problem)
		end
	end
	entry.hands = entry.hands or 2
	if entry.hands ~= 1 and entry.hands ~= 2 then
		fail(class, "hands must be 1 or 2")
	end
	entry.draw = entry.draw or 0.5
	if type(entry.draw) ~= "number" or entry.draw < 0 then
		fail(class, "draw must be a number >= 0")
	end
	if entry.sounds ~= nil and type(entry.sounds) ~= "table" then
		fail(class, "sounds must be a table")
	end
	entry.sounds = entry.sounds or {}
	entry.class = class
	entry.name = entry.name or "melee." .. class
	entry.holdType = entry.holdType or (entry.hands == 1 and "knife" or "melee2")
	if self.defs[class] == nil then
		self.order[#self.order + 1] = class
	end
	self.defs[class] = entry
	weapons.Register(self:_Class(entry), class)
	-- Weapons of the class that exist (an autorefresh) take the new definition.
	for _, weapon in ipairs(ents.FindByClass(class)) do
		weapon.def = nil
	end
	return entry
end

-- The scripted weapon of definition `def`: what the engine reads of the table.
function M:_Class(def)
	return {
		Base = M.BASE,
		PrintName = self:Name(def.class),
		Slot = def.slot or 0,
		SlotPos = def.slotPos or 0,
		Weight = def.weight or 3,
		HoldType = def.holdType,
		ViewModel = def.viewModel,
		WorldModel = def.worldModel,
		ViewModelFOV = def.viewModelFOV,
		ViewModelFlip = def.viewModelFlip,
		UseHands = def.useHands,
	}
end

-- The definition of the weapon `class` (do not modify), or nil.
function M:Get(class)
	return class ~= nil and self.defs[class] or nil
end

-- Classes of every registered weapon, in the order of registration (a new list).
function M:All()
	local out = {}
	for i, class in ipairs(self.order) do
		out[i] = class
	end
	return out
end

-- Whether `weapon` is a melee weapon of the registry.
function M:IsMelee(weapon)
	return IsValid(weapon) and self.defs[weapon:GetClass()] ~= nil
end

-- The translated name of the weapon `class` (the class without a translation).
function M:Name(class)
	local def = self.defs[class]
	local key = def ~= nil and def.name or "melee." .. tostring(class)
	local i18n = self.ctx.i18n
	return i18n:Has(key) and i18n:T(key) or tostring(class)
end

-- The strike ---------------------------------------------------------------------------------

-- What a strike of `attack` by `owner` meets: the trace (reused by the next one; nil when
-- it meets nothing) and the direction of the strike.
function M:Trace(owner, attack)
	local start = owner:GetShootPos()
	local dir = (owner:EyeAngles() + owner:GetViewPunchAngles()):Forward()
	local trace, out = self.trace, self.traceOut
	local reach = attack.reach
	trace.start, trace.endpos, trace.filter, trace.output = start, start + dir * reach, owner, out
	trace.mask, trace.mins, trace.maxs = MASK_SHOT, nil, nil
	TraceLine(trace)
	if out.Hit then
		return out, dir
	end
	local size = attack.size
	local mins, maxs = Vector(-size, -size, -size), Vector(size, size, size)
	trace.mask, trace.mins, trace.maxs = MASK_SHOT_HULL, mins, maxs
	TraceHull(trace)
	if not out.Hit then
		return nil, dir
	end
	local ent = out.Entity
	if not (IsValid(ent) and (ent:IsPlayer() or self.organism:PlayerOf(ent) ~= nil)) then
		return out, dir
	end
	-- The swing met the side of a body: the blow goes at its middle, onto what is there.
	local center = ent:GetPos()
	if ent:IsPlayer() then
		center.z = center.z + (ent:Crouching() and CENTER * 0.6 or CENTER)
	end
	local toward = (center - start):GetNormalized()
	trace.endpos, trace.mask, trace.mins, trace.maxs = start + toward * (reach + size * 2), MASK_SHOT, nil, nil
	TraceLine(trace)
	if out.Hit and out.Entity == ent then
		return out, toward
	end
	-- Nothing of it on that line: the blow lands where the swing met it.
	trace.endpos, trace.mask, trace.mins, trace.maxs = start + dir * reach, MASK_SHOT_HULL, mins, maxs
	TraceHull(trace)
	out.HitPos = start + toward * (out.Fraction * reach)
	return out, toward
end

-- Strikes with `attack` (the index-th of `weapon`): traces it, under lag compensation in
-- a command of the attacker on the server, and the server deals it. `scale` multiplies
-- the energy. Returns the trace, or nil for a miss.
function M:Strike(owner, weapon, attack, index, scale)
	local compensate = SERVER and self.ctx.config.lagCompensation and owner:IsPlayer()
		and GetPredictionPlayer() == owner
	if compensate then
		owner:LagCompensation(true)
	end
	local tr, dir = self:Trace(owner, attack)
	if compensate then
		owner:LagCompensation(false)
	end
	if tr == nil then
		return nil
	end
	if SERVER then
		self:_Deal(owner, weapon, attack, index, tr, dir, scale or 1)
	end
	return tr
end
