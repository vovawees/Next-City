-- Equipment, shared part: the slots, what goes where, the verbs and the ammo source.
--
-- The equipment of a player is a container of the inventory (kind "equipment") with a
-- slot for each of M.SLOTS. Items say where they go by their traits:
--   armor = "vest"        a kind of the armor module: the slot of the kind (helmet, vest,
--                         plates); worn while the item lies there, its wear is state.cond
--   wear = "back"         a bag (trait container) worn on the back or the chest ("rig")
--   weapon = { class = "nc_glock17", slot = "secondary" }
--                         a scripted weapon in the hands while the item lies there; slot:
--                         primary (default), secondary, melee, throwable. A firearm keeps
--                         the rounds in it in state.charge and their type in state.ammo
--                         (nil: a full magazine of its default type); a stack of
--                         throwables is the ammo of its weapon
--   ammo = "9x19_fmj"     rounds of an ammo type of the ammo module: reloads take them from
--                         every container of the player, then from the engine reserve
-- Verbs: equip (from his other containers into its slot, swapping what is there) and
-- unequip (into his pockets and bags).

local M = NC.Module("equipment")

local ipairs = ipairs
local min = math.min

M.SLOTS = { "helmet", "vest", "plates", "back", "rig", "primary", "secondary", "melee", "throwable" }
M.WEAPON_SLOTS = { primary = true, secondary = true, melee = true, throwable = true }

local SLOT = {}
for i, name in ipairs(M.SLOTS) do
	SLOT[name] = i
end
M.SLOT_INDEX = SLOT

local EMPTY = {}

function M:_InitShared(ctx)
	self.inventory = ctx:Require("inventory")
	self.armor = ctx:Require("armor")
	self.weapons = ctx:Require("weapons")
	self.throwables = ctx:Require("throwables")
	self.ammoItems = {}   -- ammo id -> item ids with the trait ammo of it
	self.ammoVersion = -1 -- the number of items the map was built for
	self.inventory:RegisterVerb("equip", { label = "equipment.verb.equip", order = 15,
		Applies = function(_, def, where, kind)
			return where == "own" and kind ~= "equipment" and self:SlotFor(def) ~= nil
		end })
	self.inventory:RegisterVerb("unequip", { label = "equipment.verb.unequip", order = 15,
		Applies = function(_, _, where, kind)
			return where == "own" and kind == "equipment"
		end })
end

function M:_StartShared()
	if self.weapons ~= nil then
		self.weapons:SetAmmoSource({
			Count = function(ply, _, ammoId) return self:CountAmmo(ply, ammoId) end,
			Take = function(ply, _, ammoId, count) return self:TakeAmmo(ply, ammoId, count) end,
		})
	end
end

function M:Stop()
	if self.weapons ~= nil then
		self.weapons:SetAmmoSource(nil)
	end
end

-- The slot (a name of M.SLOTS) an item of definition `def` goes into, or nil.
function M:SlotFor(def)
	if def == nil then
		return nil
	end
	local traits = def.traits
	if traits.armor ~= nil then
		local kind = self.armor ~= nil and self.armor:Kind(traits.armor) or nil
		return kind ~= nil and SLOT[kind.slot] ~= nil and kind.slot or nil
	end
	if traits.weapon ~= nil then
		local slot = traits.weapon.slot or "primary"
		return M.WEAPON_SLOTS[slot] and slot or nil
	end
	if traits.wear ~= nil and traits.container ~= nil then
		return SLOT[traits.wear] ~= nil and not M.WEAPON_SLOTS[traits.wear] and traits.wear or nil
	end
	return nil
end

-- The class of the weapon of item `id`, or nil.
function M:WeaponClass(id)
	local trait = self.inventory:Trait(id, "weapon")
	return trait ~= nil and trait.class or nil
end

-- Ammo ----------------------------------------------------------------------------------

-- The items whose trait ammo is `ammoId`, in the order of registration.
function M:AmmoItems(ammoId)
	local inventory = self.inventory
	local version = #inventory.order
	if version ~= self.ammoVersion then
		local map = {}
		for _, id in ipairs(inventory:WithTrait("ammo")) do
			local ammo = inventory:Trait(id, "ammo")
			local list = map[ammo] or {}
			list[#list + 1] = id
			map[ammo] = list
		end
		self.ammoItems, self.ammoVersion = map, version
	end
	return self.ammoItems[ammoId] or EMPTY
end

-- Rounds of `ammoId` a player has for reloads: his items, then his engine reserve.
function M:CountAmmo(ply, ammoId)
	local count = ply:GetAmmoCount(ammoId)
	for _, id in ipairs(self:AmmoItems(ammoId)) do
		count = count + self:_ItemCount(ply, id)
	end
	return count
end

-- Takes up to `count` rounds of `ammoId` from a player: his items first, the smallest
-- stacks first, then the engine reserve. The rounds taken.
function M:TakeAmmo(ply, ammoId, count)
	local taken = 0
	for _, id in ipairs(self:AmmoItems(ammoId)) do
		if taken >= count then
			break
		end
		taken = taken + self:_ItemTake(ply, id, count - taken)
	end
	if taken < count then
		local reserve = min(count - taken, ply:GetAmmoCount(ammoId))
		if reserve > 0 then
			ply:RemoveAmmo(reserve, ammoId)
			taken = taken + reserve
		end
	end
	return taken
end
