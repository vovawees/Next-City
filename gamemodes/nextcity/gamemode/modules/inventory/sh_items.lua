-- Inventory, shared part: the registries of items and verbs.
--
-- Packages register their items in Init of their module (both realms, in the same order):
--   inventory:RegisterItem("bandage", {
--   	name = "items.bandage",         -- key of the name (default "items.<id>")
--   	description = "items.bandage.desc", -- key of the description (optional)
--   	model = "models/...",           -- the thing on the ground
--   	weight = 0.1,                   -- kg of one
--   	stack = 5,                      -- how many fit in one slot (1)
--   	size = 1,                       -- 1 small (pockets), 2 medium (bags), 3 large (crates,
--   	                                -- bodies and the slots of the equipment)
--   	category = "medical",           -- see M.CATEGORIES (the screen sorts and colours by it)
--   	traits = { medical = { treatment = "bandage", time = 3 } }, -- data other modules read
--   })
-- An item instance is { uid, id, count, state } on the server; state is free data of the
-- modules of its traits, of which charge (a number: rounds, uses), cond (0..1: wear) and
-- label (a short text) are shown on the screen. Clients see { slot, uid, id, count,
-- charge, cond, label, sub }.
--
-- Verbs are what a player may do with an item (the menu of the screen):
--   RegisterVerb(id, { label = key, order = n, Applies = function(item, def, where) end })
-- on both realms (where: "own" for the player's containers, "external" for others), and
-- HandleVerb(id, fn) on the server: fn(ply, item, container, count) -> true, or false
-- and the key of a reason (a notice). Built in: take, drop, split, open (sv_inventory.lua).

local M = NC.Module("inventory")

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local floor = math.floor
local format = string.format
local sort = table.sort

M.CATEGORIES = { "weapon", "ammo", "medical", "armor", "gear", "tool", "food", "valuable", "misc" }
M.MAX_SLOTS = 64
M.DEFAULT_MODEL = "models/props_junk/cardboard_box004a.mdl"

local CATEGORY = {}
for i, name in ipairs(M.CATEGORIES) do
	CATEGORY[name] = i
end
M.CATEGORY_ORDER = CATEGORY

local ID = "^[a-z0-9_]+$"

function M:_InitItems()
	self.defs = {}     -- id -> definition
	self.order = {}    -- ids in the order of registration
	self.verbs = {}    -- id -> verb
	self.handlers = {} -- verb id -> fn (server)
	self:_RegisterVerbs()
end

local function fail(id, message)
	error(format("inventory: RegisterItem('%s'): %s", tostring(id), message), 3)
end

local function number(def, key, default, low, high)
	local value = def[key]
	if value == nil then
		return default
	end
	if type(value) ~= "number" or value ~= value or value < low or value > high then
		fail(def.id, format("%s must be a number %s..%s", key, tostring(low), tostring(high)))
	end
	return value
end

-- Registers or replaces the item `id` (see the top of the file). Returns the definition.
function M:RegisterItem(id, def)
	if type(id) ~= "string" or #id > 32 or not id:find(ID) then
		fail(id, "id must be lowercase letters, digits and _, at most 32")
	end
	if type(def) ~= "table" then
		fail(id, "def must be a table")
	end
	local entry = {}
	for key, value in pairs(def) do
		entry[key] = value
	end
	entry.id = id
	entry.name = entry.name or "items." .. id
	entry.model = entry.model or M.DEFAULT_MODEL
	entry.weight = number(entry, "weight", 0.1, 0, 1000)
	entry.stack = floor(number(entry, "stack", 1, 1, 1000000))
	entry.size = floor(number(entry, "size", 1, 1, 3))
	entry.category = entry.category or "misc"
	if CATEGORY[entry.category] == nil then
		fail(id, "unknown category " .. tostring(entry.category))
	end
	entry.traits = entry.traits or {}
	if type(entry.traits) ~= "table" then
		fail(id, "traits must be a table")
	end
	if self.defs[id] == nil then
		self.order[#self.order + 1] = id
	end
	self.defs[id] = entry
	return entry
end

-- The definition of item `id` (do not modify), or nil.
function M:Def(id)
	return id ~= nil and self.defs[id] or nil
end

-- Ids of every item, in the order of registration (a new list).
function M:Items()
	local out = {}
	for i, id in ipairs(self.order) do
		out[i] = id
	end
	return out
end

-- The trait `name` of item `id`, or nil.
function M:Trait(id, name)
	local def = self.defs[id]
	return def ~= nil and def.traits[name] or nil
end

-- Ids of the items with trait `name`, in the order of registration.
function M:WithTrait(name)
	local out = {}
	for _, id in ipairs(self.order) do
		if self.defs[id].traits[name] ~= nil then
			out[#out + 1] = id
		end
	end
	return out
end

local function translate(i18n, key, fallback)
	if key ~= nil and i18n:Has(key) then
		return i18n:T(key)
	end
	return fallback
end

-- The translated name of item `id` (the id without a translation).
function M:Name(id)
	local def = self.defs[id]
	return translate(self.ctx.i18n, def and def.name, tostring(id))
end

-- The translated description of item `id`, or nil.
function M:Description(id)
	local def = self.defs[id]
	return def ~= nil and translate(self.ctx.i18n, def.description, nil) or nil
end

-- Verbs ---------------------------------------------------------------------------------

-- Registers or replaces a verb (see the top of the file).
function M:RegisterVerb(id, spec)
	assert(type(id) == "string" and id:find(ID) and #id <= 24, "inventory: RegisterVerb(id): id must be like an item id")
	spec = spec or {}
	self.verbs[id] = {
		id = id,
		label = spec.label or "inventory.verb." .. id,
		order = spec.order or 50,
		Applies = spec.Applies,
	}
end

-- Sets what the server does for verb `id`: fn(ply, item, container, count).
function M:HandleVerb(id, fn)
	assert(type(fn) == "function", "inventory: HandleVerb(id, fn)")
	self.handlers[id] = fn
end

-- Whether verb `id` applies to `item` (an instance or a snapshot item) at `where`.
function M:VerbApplies(id, item, where)
	local verb, def = self.verbs[id], self.defs[item.id]
	if verb == nil or def == nil then
		return false
	end
	return verb.Applies == nil or verb.Applies(item, def, where) == true
end

local function byOrder(a, b)
	if a.order ~= b.order then
		return a.order < b.order
	end
	return a.id < b.id
end

-- The verbs that apply to `item` at `where`, in their order: { id, label, order }.
function M:VerbsFor(item, where)
	local list = {}
	for id, verb in pairs(self.verbs) do
		if self:VerbApplies(id, item, where) then
			list[#list + 1] = verb
		end
	end
	sort(list, byOrder)
	return list
end

-- The inside of a bag: the trait container = { slots, maxWeight, maxSize }.
local function isBag(item, def)
	return def.traits.container ~= nil and (item.sub == nil or item.sub ~= 0)
end

function M:_RegisterVerbs()
	self:RegisterVerb("take", { order = 10, Applies = function(_, _, where) return where == "external" end })
	self:RegisterVerb("split", { order = 80, Applies = function(item, def)
		return def.stack > 1 and item.count > 1
	end })
	self:RegisterVerb("open", { order = 20, Applies = function(item, def, where)
		return where == "external" and isBag(item, def)
	end })
	self:RegisterVerb("drop", { order = 90, Applies = function(_, _, where) return where == "own" end })
end

-- The weight of `count` of item `id`, kg (without what is inside).
function M:WeightOf(id, count)
	local def = self.defs[id]
	return def ~= nil and def.weight * (count or 1) or 0
end
