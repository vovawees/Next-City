-- Equipment, server part: the equipment of every player and what lying there does.
--
--   armor     put on (armor:Equip with state.cond) when it comes into its slot, taken off
--             when it leaves; hits wear the item (armor.hit)
--   weapons   given when it comes into its slot (a firearm with the rounds of
--             state.charge of type state.ammo), stripped when it leaves; the rounds in
--             the hands are copied to the item every config.sync s and at death; a stack
--             of throwables is the engine ammo of its weapon, a throw takes one off
--   bags      worn on the back or the chest: what is inside is his to carry
--   load      the kg he carries slow him down from config.freeLoad to config.fullLoad
-- Things a player gets go into their slot first when it is free (inventory.place). The
-- inventory empties the equipment at every loadout and leaves it on the body at death.
--
--   equipment:Of(ply)            the equipment container of a player (created on demand)
--   equipment:Item(ply, slot)    the item in a slot ("primary"), or nil
--   equipment:Equip(ply, item)   moves an item of his into its slot; ok, reason
--   equipment:SpeedFactor(ply)   the share of his speeds his load leaves him
--
-- Listens: inventory.place, inventory.changed, players.left, gm.DoPlayerDeath (first),
--          throwables.thrown, armor.hit; reduces movement.speed.

local M = NC.Module("equipment")

local IsValid = IsValid
local pairs = pairs
local ipairs = ipairs
local max = math.max
local min = math.min
local floor = math.floor
local abs = math.abs

function M:Init(ctx)
	self:_InitShared(ctx)
	self.players = ctx:Require("players")
	self.movement = ctx:Require("movement")
	self.of = {}        -- ply -> the equipment container
	self.loads = {}     -- ply -> kg at the last speed refresh
	self.leaving = nil  -- the throwable item used up by a throw (its weapon goes by itself)
	self.inventory:HandleVerb("equip", function(ply, item)
		return self:Equip(ply, item)
	end)
	self.inventory:HandleVerb("unequip", function(ply, item, _, count)
		local ok, reason = self.inventory:TakeItem(ply, item, count)
		if ok and reason ~= nil then
			self.inventory:Fail(ply, reason)
		end
		return ok, not ok and reason or nil
	end)
end

function M:Start(ctx)
	self:_StartShared(ctx)
	ctx:On("inventory.place", "OnPlace")
	ctx:On("inventory.changed", "OnChanged")
	ctx:On("players.left", "OnLeft")
	ctx:On("gm.DoPlayerDeath", "SyncPlayer", { priority = 100 })
	ctx:On("throwables.thrown", "OnThrown")
	ctx:On("armor.hit", "OnArmorHit")
	ctx:On("movement.speed", "OnSpeed")
	ctx:Every("sync", ctx.config.sync, function()
		self:SyncAll()
	end)
end

function M:_ItemCount(ply, id)
	return self.inventory:Count(ply, id)
end

function M:_ItemTake(ply, id, count)
	return self.inventory:Take(ply, id, count)
end

-- The container ------------------------------------------------------------------------

-- The equipment of a player (created the first time).
function M:Of(ply)
	local c = self.of[ply]
	if c ~= nil and not c.removed then
		return c
	end
	local slots = M.SLOTS
	c = self.inventory:CreateContainer({
		kind = "equipment",
		size = #slots,
		maxSize = 3,
		slotNames = slots,
		Accepts = function(_, slot, _, def)
			return self:SlotFor(def) == slots[slot]
		end,
		OnInsert = function(_, slot, item)
			self:_Wear(ply, slots[slot], item)
		end,
		OnRemove = function(_, slot, item)
			self:_TakeOff(ply, slots[slot], item)
		end,
		OnChange = function(_, slot, item)
			self:_Recount(ply, slots[slot], item)
		end,
	})
	self.inventory:AddOwned(ply, c, 10)
	self.of[ply] = c
	return c
end

-- The item in slot `name` of a player's equipment, or nil.
function M:Item(ply, name)
	local c = self.of[ply]
	local slot = M.SLOT_INDEX[name]
	return c ~= nil and slot ~= nil and c.items[slot] or nil
end

function M:OnLeft(ply)
	self.of[ply], self.loads[ply] = nil, nil
end

-- Moves an item of a player into its slot (what is there goes where the item was).
-- Returns true, or false and the reason.
function M:Equip(ply, item)
	local def = self.inventory:Def(item.id)
	local name = self:SlotFor(def)
	if name == nil then
		return false, "verb"
	end
	local from = item.container
	if from == nil then
		return false, "empty"
	end
	local c = self:Of(ply)
	if from == c then
		return false, "same"
	end
	return self.inventory:Transfer(from, item.slot, c, M.SLOT_INDEX[name], 0)
end

-- What a player gets goes into its slot when that is free (or holds more of the same).
function M:OnPlace(ply, item, def)
	local name = self:SlotFor(def)
	if name == nil or not IsValid(ply) then
		return nil
	end
	local c = self:Of(ply)
	local slot = M.SLOT_INDEX[name]
	local other = c.items[slot]
	if other == nil or (self.inventory:CanStack(other, item) and other.count < def.stack) then
		return c, slot
	end
	return nil
end

-- Wearing ---------------------------------------------------------------------------------

function M:_Wear(ply, name, item)
	local traits = self.inventory:Def(item.id).traits
	if traits.armor ~= nil then
		if self.armor ~= nil and IsValid(ply) and ply:Alive() then
			self.armor:Equip(ply, traits.armor, item.state.cond or 1)
		end
	elseif traits.weapon ~= nil and M.WEAPON_SLOTS[name] then
		self:_Arm(ply, item, traits.weapon.class)
	end
	self:Refresh(ply)
end

function M:_TakeOff(ply, name, item)
	local traits = self.inventory:Def(item.id).traits
	if traits.armor ~= nil then
		if self.armor ~= nil and IsValid(ply) then
			for _, piece in ipairs(self.armor:Worn(ply)) do
				if piece.slot == name then
					item.state.cond = piece.condition
					self.armor:Unequip(ply, name)
					break
				end
			end
		end
	elseif traits.weapon ~= nil and M.WEAPON_SLOTS[name] then
		self:_Disarm(ply, item, traits.weapon.class)
	end
	self:Refresh(ply)
end

-- The count of a stack in a slot changed: a stack of throwables is the engine ammo.
function M:_Recount(ply, name, item)
	if name ~= "throwable" or not IsValid(ply) then
		return
	end
	local def = self.throwables ~= nil and self.throwables:Get(self:WeaponClass(item.id)) or nil
	if def ~= nil then
		ply:SetAmmo(item.count, def.ammo)
	end
end

function M:_Arm(ply, item, class)
	if not IsValid(ply) or not ply:Alive() or class == nil then
		return
	end
	local state = item.state
	local firearm = self.weapons ~= nil and self.weapons:Get(class) or nil
	if firearm ~= nil then
		local weapon = state.ammo ~= nil and self.weapons:Give(ply, class, { ammo = state.ammo, empty = true }) or nil
		if weapon == nil then
			weapon = self.weapons:Give(ply, class, { empty = true })
		end
		if weapon ~= nil then
			local rounds = state.charge
			if rounds == nil then
				rounds = firearm.capacity
			end
			weapon:SetClip1(max(0, min(firearm.capacity, floor(rounds))))
			state.charge, state.ammo = weapon:Clip1(), weapon:LoadedAmmo()
		end
		return
	end
	if not ply:HasWeapon(class) then
		ply:Give(class)
	end
	local throwable = self.throwables ~= nil and self.throwables:Get(class) or nil
	if throwable ~= nil then
		ply:SetAmmo(item.count, throwable.ammo)
	end
end

function M:_Disarm(ply, item, class)
	if not IsValid(ply) or class == nil then
		return
	end
	self:_Copy(ply, item, class)
	local throwable = self.throwables ~= nil and self.throwables:Get(class) or nil
	if throwable ~= nil then
		ply:SetAmmo(0, throwable.ammo)
	end
	if self.leaving ~= item and ply:HasWeapon(class) then
		ply:StripWeapon(class)
	end
end

-- Copies the rounds in the hands to the item of a firearm; true if they changed.
function M:_Copy(ply, item, class)
	if self.weapons == nil or self.weapons:Get(class) == nil then
		return false
	end
	local weapon = ply:GetWeapon(class)
	if not IsValid(weapon) then
		return false
	end
	local state = item.state
	local charge, ammo = weapon:Clip1(), weapon:LoadedAmmo()
	if state.charge == charge and state.ammo == ammo then
		return false
	end
	state.charge, state.ammo = charge, ammo
	return true
end

-- Copies the state of the weapons in the hands of a player to their items.
function M:SyncPlayer(ply)
	local c = self.of[ply]
	if c == nil or not IsValid(ply) then
		return
	end
	for name in pairs(M.WEAPON_SLOTS) do
		local item = c.items[M.SLOT_INDEX[name]]
		if item ~= nil then
			local class = self:WeaponClass(item.id)
			if class ~= nil then
				if ply:Alive() and not ply:HasWeapon(class) and self.players:IsAlive(ply) then
					self:_Arm(ply, item, class) -- the item is the truth: someone stripped the weapon
				elseif self:_Copy(ply, item, class) then
					self.inventory:Touch(item)
				end
			end
		end
	end
end

function M:SyncAll()
	for ply in pairs(self.of) do
		self:SyncPlayer(ply)
	end
end

-- A throw takes one off the stack in the throwable slot.
function M:OnThrown(owner, _, class)
	local item = IsValid(owner) and self:Item(owner, "throwable") or nil
	if item == nil or self:WeaponClass(item.id) ~= class then
		return
	end
	if item.count <= 1 then
		self.leaving = item
		self.inventory:Destroy(item)
		self.leaving = nil
	else
		self.inventory:SetCount(item, item.count - 1)
	end
end

-- A hit wears the item of the armor that met it.
function M:OnArmorHit(ply, _, kindId)
	local kind = self.armor ~= nil and self.armor:Kind(kindId) or nil
	local item = kind ~= nil and self:Item(ply, kind.slot) or nil
	if item == nil then
		return
	end
	for _, piece in ipairs(self.armor:Worn(ply)) do
		if piece.slot == kind.slot then
			item.state.cond = piece.condition
			self.inventory:Touch(item)
			return
		end
	end
end

-- Load ----------------------------------------------------------------------------------

-- The share of his speeds the load of a player leaves him.
function M:SpeedFactor(ply)
	local config = self.ctx.config
	local load = self.inventory:Load(ply)
	if load <= config.freeLoad then
		return 1
	end
	local span = max(1e-6, config.fullLoad - config.freeLoad)
	return 1 - (1 - config.minSpeed) * min(1, (load - config.freeLoad) / span)
end

function M:OnSpeed(factor, ply)
	return factor * self:SpeedFactor(ply)
end

-- Sets the speeds of a player again when his load changed.
function M:Refresh(ply)
	if self.movement == nil or not IsValid(ply) or not ply:Alive() then
		return
	end
	local load = self.inventory:Load(ply)
	if abs(load - (self.loads[ply] or 0)) < 0.05 then
		return
	end
	self.loads[ply] = load
	self.movement:Refresh(ply)
end

function M:OnChanged(_, owner)
	if owner ~= nil then
		self:Refresh(owner)
	end
end
