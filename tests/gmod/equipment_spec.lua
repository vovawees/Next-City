-- Equipment module: armor worn, bags on the back and the chest, weapons in the hands with
-- the rounds of their items, reloads from what the player carries (predicted by his
-- client), stacks of throwables, the load slowing him down and the equipment of the dead,
-- with the real gamemode files and a content package of test items.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local IN = World.IN

local TICK = 1 / 64

local PACKAGE = {
	["nextcity/modules/gearkit/module.lua"] = "return { id = 'gearkit', requires = { 'inventory', 'ammo', 'weapons',"
		.. " 'throwables' }, files = { sh = { 'sh_gearkit.lua' } } }",
	["nextcity/modules/gearkit/sh_gearkit.lua"] = [[
		local M = NC.Module("gearkit")
		function M:Init(ctx)
			local inventory, ammo = ctx:Require("inventory"), ctx:Require("ammo")
			local weapons, throwables = ctx:Require("weapons"), ctx:Require("throwables")
			ammo:Register("9x19_fmj", { caliber = "9x19", mass = 8, velocity = 360, diameter = 9, penetration = 60,
				range = 540 })
			ammo:Register("9x19_ap", { caliber = "9x19", mass = 6, velocity = 420, diameter = 9, penetration = 80,
				range = 540, ap = 1.5 })
			weapons:Register("test_pistol", { caliber = "9x19", magazine = 15, hands = 1, rpm = 480, draw = 0.25,
				reload = 1, reloadEmpty = 1 })
			throwables:Register("test_frag", { model = "models/weapons/w_grenade.mdl", fuse = 2,
				detonate = function() end })
			inventory:RegisterItem("pistol", { weight = 0.9, size = 2, category = "weapon",
				traits = { weapon = { class = "test_pistol", slot = "secondary" } } })
			inventory:RegisterItem("rounds", { weight = 0.01, stack = 50, category = "ammo",
				traits = { ammo = "9x19_fmj" } })
			inventory:RegisterItem("frag", { weight = 0.4, stack = 3, category = "weapon",
				traits = { weapon = { class = "test_frag", slot = "throwable" } } })
			inventory:RegisterItem("vest", { weight = 3.5, size = 3, category = "armor", traits = { armor = "vest" } })
			inventory:RegisterItem("helmet", { weight = 1.4, size = 2, category = "armor",
				traits = { armor = "helmet" } })
			inventory:RegisterItem("backpack", { weight = 1.5, size = 3, category = "gear",
				traits = { wear = "back", container = { slots = 10, maxWeight = 30, maxSize = 2 } } })
			inventory:RegisterItem("anvil", { weight = 20, size = 2 })
		end
	]],
}

local MODULES = { "players", "notices", "organism", "damage", "ammo", "weapons", "throwables", "armor", "movement",
	"inventory", "equipment" }

local function boot()
	local server = Env.Server({ modules = MODULES, files = PACKAGE })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC }
	for _, id in ipairs({ "players", "inventory", "equipment", "armor", "weapons", "throwables" }) do
		w[id] = NC.Modules:Instance(id)
	end
	function w.join(name, opts)
		opts = opts or {}
		local client, ply = Env.Join(server, { name = name, language = opts.language })
		w.players:Deploy(ply)
		ply:SetPos(opts.pos or Vector(0, 0, 0))
		return client, ply
	end
	function w.sync(...)
		Env.Flush(server, ...)
		server:Advance(0.1)
		Env.Flush(server, ...)
	end
	return w
end

local function slotOf(name)
	for i, slot in ipairs({ "helmet", "vest", "plates", "back", "rig", "primary", "secondary", "melee", "throwable" }) do
		if slot == name then
			return i
		end
	end
end

local function worn(armor, ply)
	local out = {}
	for _, piece in ipairs(armor:Worn(ply)) do
		out[#out + 1] = piece.id .. "@" .. string.format("%.2f", piece.condition)
	end
	return table.concat(out, " ")
end

describe("equipment", function()
	it("wears armor and bags that come into their slots and takes them off when they leave", function()
		local w = boot()
		local client, ply = w.join("Bob")
		local inventory, equipment = w.inventory, w.equipment
		expect(inventory:Give(ply, "vest", 1)):toBe(1)
		expect(inventory:Give(ply, "helmet", 1, { cond = 0.5 })):toBe(1)
		expect(worn(w.armor, ply)):toBe("helmet@0.50 vest@1.00")
		expect(inventory:Give(ply, "backpack", 1)):toBe(1)
		local eq = equipment:Of(ply)
		expect(eq.kind):toBe("equipment")
		expect(equipment:Item(ply, "back").id):toBe("backpack")
		expect(inventory:Give(ply, "rounds", 500)):toBe(500) -- 400 in the pockets, the rest in the backpack
		expect(inventory:Count(equipment:Item(ply, "back").sub, "rounds")):toBe(100)
		-- Off into the backpack and on again; the wear stays with the item.
		expect(inventory:Act(ply, eq.id, slotOf("helmet"), "unequip", 0)):toBe(true)
		expect(worn(w.armor, ply)):toBe("vest@1.00")
		local helmet = equipment:Item(ply, "back").sub.items[3]
		expect(helmet.id):toBe("helmet")
		expect(helmet.state.cond):toBe(0.5)
		expect(inventory:Act(ply, helmet.container.id, helmet.slot, "equip", 0)):toBe(true)
		expect(worn(w.armor, ply)):toBe("helmet@0.50 vest@1.00")
		-- The vest fits nowhere else: dropped, it is no longer worn.
		expect(select(2, inventory:Act(ply, eq.id, slotOf("vest"), "unequip", 0))):toBe("full")
		expect(inventory:Act(ply, eq.id, slotOf("vest"), "drop", 0)):toBe(true)
		expect(worn(w.armor, ply)):toBe("helmet@0.50")
		-- The client sees the slots; the verbs depend on where the item lies.
		w.sync(client)
		local view = client:Get("NC").Modules:Instance("inventory")
		local seen = view:OwnOfKind("equipment")
		expect(seen.slotNames[1]):toBe("helmet")
		local verbs = {}
		for _, verb in ipairs(view:VerbsFor(seen.bySlot[1], "own", "equipment")) do
			verbs[#verbs + 1] = verb.id
		end
		expect(verbs):toEqual({ "unequip", "drop" })
		expect(view:VerbApplies("equip", { id = "helmet", count = 1 }, "own", "bag")):toBe(true)
		expect(view:VerbApplies("equip", { id = "rounds", count = 1 }, "own", "bag")):toBe(false)
		-- A new loadout empties it.
		w.players:Deploy(ply)
		expect(worn(w.armor, ply)):toBe("")
		expect(eq:IsEmpty()):toBe(true)
		expect(w.server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("puts weapons in the hands with the rounds of their items and copies the rounds back", function()
		local w = boot()
		local _, ply = w.join("Bob")
		local _, al = w.join("Al", { pos = Vector(0, 40, 0) })
		local inventory, equipment = w.inventory, w.equipment
		inventory:Give(ply, "pistol", 1)
		local weapon = ply:GetWeapon("test_pistol")
		expect(weapon ~= nil and weapon:IsValid()):toBe(true)
		expect(weapon:Clip1()):toBe(16) -- a full magazine and the chamber
		local item = equipment:Item(ply, "secondary")
		expect(item.state.charge):toBe(16)
		expect(item.state.ammo):toBe("9x19_fmj")
		weapon:SetClip1(5)
		w.server:Advance(1.1)
		expect(item.state.charge):toBe(5)
		-- Dropped: out of the hands, the rounds stay with the item; another player picks it up.
		expect(inventory:Act(ply, equipment:Of(ply).id, slotOf("secondary"), "drop", 0)):toBe(true)
		expect(ply:HasWeapon("test_pistol")):toBe(false)
		local ent = item.entity
		expect(ent ~= nil):toBe(true)
		w.server:Advance(1)
		Env.UseEntity(w.server, al, ent)
		expect(equipment:Item(al, "secondary")):toBe(item)
		expect(al:GetWeapon("test_pistol"):Clip1()):toBe(5)
		-- Another type of rounds in it.
		inventory:Give(ply, "pistol", 1, { charge = 3, ammo = "9x19_ap" })
		expect(ply:GetWeapon("test_pistol"):Clip1()):toBe(3)
		expect(ply:GetWeapon("test_pistol"):LoadedAmmo()):toBe("9x19_ap")
		-- Stripped by someone else: the item gives it back.
		ply:StripWeapon("test_pistol")
		w.server:Advance(1.1)
		expect(ply:HasWeapon("test_pistol")):toBe(true)
		expect(ply:GetWeapon("test_pistol"):Clip1()):toBe(3)
		expect(w.server:Errors()):toEqual({})
	end)

	it("reloads from the rounds the player carries, predicted by his client", function()
		local w = boot()
		local client, ply = w.join("Bob")
		local inventory = w.inventory
		inventory:Give(ply, "pistol", 1, { charge = 0 })
		inventory:Give(ply, "rounds", 40)
		ply:GiveAmmo(10, "9x19_fmj", true)
		ply:SelectWeapon("test_pistol")
		Env.Sync(w.server)
		w.sync(client)
		local weapon = ply:GetWeapon("test_pistol")
		local mirror = client.entities[weapon:EntIndex()]
		expect(w.weapons:CountAmmo(ply, weapon, "9x19_fmj")):toBe(50)
		local clientWeapons = client:Get("NC").Modules:Instance("weapons")
		expect(client:As(function() return clientWeapons:CountAmmo(ply, mirror, "9x19_fmj") end)):toBe(50)
		local function step(seconds)
			for _ = 1, math.floor(seconds / TICK + 0.5) do
				w.server:Advance(TICK)
				client:Advance(TICK)
			end
			Env.Flush(w.server, client)
		end
		local function use(buttons)
			Env.Use(w.server, ply, buttons)
			Env.Use(client, ply, buttons)
		end
		step(0.5)
		use(IN.RELOAD)
		step(1.125)
		use(0)
		expect(weapon:Clip1()):toBe(15)
		expect(mirror:Clip1()):toBe(15)
		-- The items went first, the engine reserve is untouched.
		expect(inventory:Count(ply, "rounds")):toBe(25)
		expect(ply:GetAmmoCount("9x19_fmj")):toBe(10)
		w.sync(client)
		local view = client:Get("NC").Modules:Instance("inventory")
		expect(view:Count("rounds")):toBe(25)
		expect(client:As(function() return clientWeapons:CountAmmo(ply, mirror, "9x19_fmj") end)):toBe(35)
		expect(w.server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("makes a stack of throwables the ammo of their weapon and takes one off a throw", function()
		local w = boot()
		local _, ply = w.join("Bob")
		local inventory, equipment = w.inventory, w.equipment
		expect(inventory:Give(ply, "frag", 2)):toBe(2)
		expect(ply:HasWeapon("test_frag")):toBe(true)
		expect(ply:GetAmmoCount("test_frag")):toBe(2)
		inventory:Give(ply, "frag", 1) -- onto the stack in the slot
		expect(equipment:Item(ply, "throwable").count):toBe(3)
		expect(ply:GetAmmoCount("test_frag")):toBe(3)
		local function throw()
			ply:RemoveAmmo(1, "test_frag")
			w.throwables:Launch(ply, "test_frag", { velocity = Vector(100, 0, 0) })
		end
		throw()
		expect(equipment:Item(ply, "throwable").count):toBe(2)
		expect(ply:GetAmmoCount("test_frag")):toBe(2)
		throw()
		throw()
		expect(equipment:Item(ply, "throwable")):toBeNil()
		expect(ply:GetAmmoCount("test_frag")):toBe(0)
		expect(w.server:Errors()):toEqual({})
	end)

	it("slows a player down by what he carries", function()
		local w = boot()
		local _, ply = w.join("Bob")
		local inventory, equipment = w.inventory, w.equipment
		expect(ply:GetWalkSpeed()):toBe(160)
		inventory:Give(ply, "vest", 1)
		inventory:Give(ply, "backpack", 1)
		inventory:Give(ply, "anvil", 1)
		w.server:Advance(0.1)
		expect(inventory:Load(ply)):toBeCloseTo(25, 1e-9)
		expect(equipment:SpeedFactor(ply)):toBeCloseTo(1 - 0.4 / 3, 1e-9)
		expect(ply:GetWalkSpeed()):toBeCloseTo(160 * (1 - 0.4 / 3), 1e-6)
		expect(ply:GetRunSpeed()):toBeCloseTo(300 * (1 - 0.4 / 3), 1e-6)
		local bag = equipment:Item(ply, "back").sub
		inventory:Act(ply, bag.id, 1, "drop", 0)
		w.server:Advance(0.1)
		expect(ply:GetWalkSpeed()):toBe(160)
		expect(w.server:Errors()):toEqual({})
	end)

	it("leaves the equipment of the dead with their belongings for others to take", function()
		local w = boot()
		local _, bob = w.join("Bob")
		local client, al = w.join("Al", { pos = Vector(40, 0, 0) })
		local inventory, equipment = w.inventory, w.equipment
		inventory:Give(bob, "vest", 1)
		inventory:Give(bob, "pistol", 1)
		bob:GetWeapon("test_pistol"):SetClip1(7)
		w.server:Advance(1.1)
		Env.Kill(bob)
		expect(worn(w.armor, bob)):toBe("")
		expect(equipment:Of(bob):IsEmpty()):toBe(true)
		local bag, c = next(inventory.places)
		expect(inventory:Count(c, "vest")):toBe(1)
		expect(inventory:Count(c, "pistol")):toBe(1)
		Env.UseEntity(w.server, al, bag)
		w.sync(client)
		client:Get("NC").Modules:Instance("inventory"):Act(c.id, 0, "take_all")
		w.sync(client)
		expect(worn(w.armor, al)):toBe("vest@1.00")
		expect(al:GetWeapon("test_pistol"):Clip1()):toBe(7)
		expect(w.server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
