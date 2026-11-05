-- Inventory, server part: kits — named sets of items packages register and modes give.
--
--   inventory:RegisterKit("tdm", {
--   	{ "helmet" }, { "vest", 1, { cond = 0.8 } },   -- { item, count, state }
--   	{ item = "ammo_9x19", count = 45 },            -- or by name
--   })
--   inventory:GiveKit(ply, "tdm", { drop = true })  -> how many things he got, how many did not fit
--   inventory:GiveKit(ply, "riot", { select = { "melee", "secondary" } })  -- this weapon in the hands
--   inventory:Kit(id) -> { { item, count, state } } (do not modify) or nil; inventory:Kits() -> ids
--
-- Things are given in the order of the kit: what goes into the equipment (inventory.place)
-- goes there, a bag first gives room to what follows. Unknown items are skipped with one
-- warning each. Commands: nc_kit <player> <kit> (admin), nc_kits.

local M = NC.Module("inventory")

local IsValid = IsValid
local ipairs = ipairs
local pairs = pairs
local type = type
local floor = math.floor
local format = string.format
local sort = table.sort
local concat = table.concat

local ID = "^[a-z][a-z0-9_]*$"

function M:_InitKits(ctx)
	self.kits = {}
	self.kitWarned = {}
	ctx.commands:Add("nc_kit", { help = "<player> <kit> - gives a player the things of a kit" }, "KitCommand")
	ctx.commands:Add("nc_kits", { help = "registered kits", admin = false }, "KitsCommand")
end

-- Registers or replaces a kit (see the top of the file).
function M:RegisterKit(id, entries)
	assert(type(id) == "string" and id:find(ID), "inventory: RegisterKit(id): id must be lower_snake_case")
	assert(type(entries) == "table", "inventory: RegisterKit(" .. id .. ", entries): entries must be a list")
	local list = {}
	for i, entry in ipairs(entries) do
		assert(type(entry) == "table", format("inventory: kit %s entry %d must be a table", id, i))
		local item, count, state = entry.item or entry[1], entry.count or entry[2] or 1, entry.state or entry[3]
		assert(type(item) == "string", format("inventory: kit %s entry %d: the id of an item", id, i))
		assert(type(count) == "number" and count >= 1, format("inventory: kit %s entry %d: count must be >= 1", id, i))
		assert(state == nil or type(state) == "table", format("inventory: kit %s entry %d: state must be a table", id, i))
		list[i] = { item = item, count = floor(count), state = state }
	end
	self.kits[id] = list
end

function M:Kit(id)
	return self.kits[id]
end

function M:Kits()
	local out = {}
	for id in pairs(self.kits) do
		out[#out + 1] = id
	end
	sort(out)
	return out
end

-- The state of an entry of a kit with the fields of `extra` added (a new table).
local function withState(state, extra)
	local out = {}
	for key, value in pairs(state or {}) do
		out[key] = value
	end
	for key, value in pairs(extra) do
		out[key] = value
	end
	return out
end

-- Gives a player (or a container) the things of kit `id`; opts as in Give, and select:
-- weapon slots in the order of preference — the weapon of the kit in the first of them the
-- player got goes into his hands; state: fields added to the state of every thing (e.g.
-- issued = true for the gear of a job). Returns how many things were given and how many
-- were not (unknown kit: nil).
function M:GiveKit(target, id, opts)
	local kit = self.kits[id]
	if kit == nil then
		return nil
	end
	local extra = type(opts) == "table" and type(opts.state) == "table" and opts.state or nil
	local given, missed = 0, 0
	for _, entry in ipairs(kit) do
		if self.defs[entry.item] == nil then
			local key = id .. "/" .. entry.item
			if not self.kitWarned[key] then
				self.kitWarned[key] = true
				self.ctx.log:Warn("kit %s: unknown item %s", id, entry.item)
			end
			missed = missed + entry.count
		else
			local state = extra ~= nil and withState(entry.state, extra) or entry.state
			local got = self:Give(target, entry.item, entry.count, state, opts) or 0
			given, missed = given + got, missed + entry.count - got
		end
	end
	if type(opts) == "table" and type(opts.select) == "table" and IsValid(target) and target:IsPlayer() then
		self:_SelectKitWeapon(target, kit, opts.select)
	end
	return given, missed
end

-- The weapon of `kit` in the first slot of `order` that `ply` has goes into his hands.
function M:_SelectKitWeapon(ply, kit, order)
	local best, bestRank
	for _, entry in ipairs(kit) do
		local weapon = self:Trait(entry.item, "weapon")
		if weapon ~= nil and ply:HasWeapon(weapon.class) then
			local slot = weapon.slot or "primary"
			for rank, name in ipairs(order) do
				if name == slot and (bestRank == nil or rank < bestRank) then
					best, bestRank = weapon.class, rank
				end
			end
		end
	end
	if best ~= nil then
		ply:SelectWeapon(best)
	end
	return best
end

function M:KitCommand(caller, args)
	if args[1] == nil or args[2] == nil then
		return "nc_kit <player> <kit> (nc_kits)"
	end
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return problem
	end
	local id = args[2]
	if self.kits[id] == nil then
		return "unknown kit " .. id .. " (nc_kits)"
	end
	local given, missed = self:GiveKit(ply, id, { drop = true })
	return format("%s got %d things of the kit %s%s", ply:Nick(), given, id,
		missed > 0 and format(" (%d left out)", missed) or "")
end

function M:KitsCommand()
	local lines = {}
	for _, id in ipairs(self:Kits()) do
		local parts = {}
		for _, entry in ipairs(self.kits[id]) do
			parts[#parts + 1] = entry.count > 1 and format("%s x%d", entry.item, entry.count) or entry.item
		end
		lines[#lines + 1] = format("%-16s %s", id, concat(parts, ", "))
	end
	if #lines == 0 then
		return "nc_kits: none"
	end
	return lines
end
