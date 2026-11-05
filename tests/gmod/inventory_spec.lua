-- Inventory module: items, containers, bags, things on the ground, places to search, the
-- belongings of the dead, the snapshots and intents of clients and the screen, with the
-- real gamemode files and a module of test items on both realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local MODULES = "nextcity/gamemode/modules/"
local KEY_LCONTROL = 83

local KIT = {
	[MODULES .. "testkit/module.lua"] = [[
		return { id = "testkit", requires = { "inventory" }, files = { sh = { "sh_testkit.lua" } } }
	]],
	[MODULES .. "testkit/sh_testkit.lua"] = [[
		local M = NC.Module("testkit")
		function M:Init(ctx)
			local inventory = ctx:Require("inventory")
			inventory:RegisterItem("bandage", { weight = 0.1, stack = 5, category = "medical",
				model = "models/bandage.mdl" })
			inventory:RegisterItem("ammo", { weight = 0.01, stack = 60, category = "ammo" })
			inventory:RegisterItem("pistol", { weight = 1, size = 2, category = "weapon" })
			inventory:RegisterItem("rifle", { weight = 3.5, size = 3, category = "weapon" })
			inventory:RegisterItem("brick", { weight = 30, size = 2 })
			inventory:RegisterItem("sack", { weight = 0.5, size = 2, category = "gear",
				traits = { container = { slots = 4, maxWeight = 20, maxSize = 2 } } })
			inventory:RegisterItem("pouch", { name = "testkit.pouch", weight = 0.2, category = "gear",
				traits = { container = { slots = 2, maxSize = 1 } } })
		end
	]],
}

local function boot(modules, opts)
	opts = opts or {}
	local server = Env.Server({ modules = modules or { "players", "notices", "inventory" }, files = KIT,
		patch = opts.patch })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC.Modules:Instance("inventory"), NC.Modules:Instance("players"), NC
end

local function join(server, name, opts)
	opts = opts or {}
	local client, ply = Env.Join(server, { name = name, language = opts.language })
	server:Get("NC").Modules:Instance("players"):Deploy(ply)
	ply:SetPos(opts.pos or Vector(0, 0, 0))
	return client, ply
end

local function bot(server, name, pos)
	local ply = Env.Bot(server, { name = name })
	server:Advance(0.1)
	server:Get("NC").Modules:Instance("players"):Deploy(ply)
	ply:SetPos(pos or Vector(0, 0, 0))
	return ply
end

local function mine(client)
	return client:Get("NC").Modules:Instance("inventory")
end

-- What clients sent arrives, the server ticks (the snapshots go out) and they arrive.
local function sync(server, ...)
	Env.Flush(server, ...)
	server:Advance(0.1)
	Env.Flush(server, ...)
end

local function groundOf(inventory)
	local out = {}
	for ent, item in pairs(inventory.ground) do
		out[#out + 1] = { ent = ent, item = item }
	end
	table.sort(out, function(a, b) return a.ent:EntIndex() < b.ent:EntIndex() end)
	return out
end

local function slotButton(client, id, slot)
	return World.FindPanels(client, function(panel)
		return panel.class == "DButton" and panel.ncContainer == id and panel.ncSlot == slot
	end)[1]
end

local function texts(panels)
	local out = {}
	for _, panel in ipairs(panels) do
		out[#out + 1] = panel.text
	end
	return out
end

local function counts(c)
	local out = {}
	for slot = 1, c.size do
		local item = c.items[slot]
		out[slot] = item and (item.id .. "x" .. item.count) or "-"
	end
	return table.concat(out, " ")
end

describe("inventory items", function()
	it("registers items with defaults on both realms and refuses bad definitions", function()
		local server, inventory = boot()
		local client = join(server, "Bob")
		local def = inventory:Def("ammo")
		expect(def.name):toBe("items.ammo")
		expect(def.stack):toBe(60)
		expect(def.size):toBe(1)
		expect(def.model):toBe(inventory.DEFAULT_MODEL)
		expect(inventory:Def("brick").category):toBe("misc")
		expect(inventory:WithTrait("container")):toEqual({ "sack", "pouch" })
		expect(inventory:Trait("sack", "container").slots):toBe(4)
		expect(inventory:Trait("brick", "container")):toBeNil()
		expect(inventory:Name("brick")):toBe("brick") -- no translation: the id
		expect(mine(client):Items()):toEqual(inventory:Items())
		expect(function() inventory:RegisterItem("Bad Id", {}) end):toFail("lowercase")
		expect(function() inventory:RegisterItem("thing", { category = "junk" }) end):toFail("unknown category")
		expect(function() inventory:RegisterItem("thing", { size = 4 }) end):toFail("size must be")
		expect(inventory:Def("thing")):toBeNil()
		server:Command("nc_items", nil, { "gear" })
		expect(#server:Lines("items: 2 of 7")):toBe(1)
		expect(#server:Lines("pouch")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("offers verbs by where the item is and lets packages add their own", function()
		local server, inventory = boot()
		local function ids(item, where)
			local out = {}
			for _, verb in ipairs(inventory:VerbsFor(item, where)) do
				out[#out + 1] = verb.id
			end
			return out
		end
		expect(ids({ id = "ammo", count = 30 }, "own")):toEqual({ "split", "drop" })
		expect(ids({ id = "ammo", count = 1 }, "own")):toEqual({ "drop" })
		expect(ids({ id = "sack", count = 1, sub = 7 }, "external")):toEqual({ "take", "open" })
		inventory:RegisterVerb("use", { order = 5, Applies = function(_, def) return def.category == "medical" end })
		expect(ids({ id = "bandage", count = 1 }, "own")):toEqual({ "use", "drop" })
		expect(ids({ id = "unknown", count = 1 }, "own")):toEqual({})
		expect(server:Errors()):toEqual({})
	end)
end)

describe("inventory containers", function()
	it("stack things up to their stack and keep the sizes and weights of containers", function()
		local server, inventory = boot()
		local crate = inventory:CreateContainer({ kind = "crate", size = 3, maxWeight = 5 })
		expect(inventory:Give(crate, "ammo", 130)):toBe(130)
		expect(counts(crate)):toBe("ammox60 ammox60 ammox10")
		local given, reason = inventory:Give(crate, "bandage", 1)
		expect(given):toBe(0)
		expect(reason):toBe("full")
		expect(inventory:Take(crate, "ammo", 70)):toBe(70) -- the smallest stacks first
		expect(inventory:Count(crate, "ammo")):toBe(60)
		expect(crate.items[3]):toBeNil()
		given, reason = inventory:Give(crate, "brick", 1)
		expect(given):toBe(0)
		expect(reason):toBe("weight")
		expect(inventory:ContainerWeight(crate)):toBeCloseTo(0.6, 1e-9)
		local small = inventory:CreateContainer({ size = 2, maxSize = 1 })
		given, reason = inventory:Give(small, "pistol", 1)
		expect(given):toBe(0)
		expect(reason):toBe("size")
		local picky = inventory:CreateContainer({ size = 2, Accepts = function(_, slot, _, def)
			return slot == 2 and def.category == "weapon"
		end })
		expect(inventory:Give(picky, "rifle", 1)):toBe(1)
		expect(counts(picky)):toBe("- riflex1")
		expect(select(2, inventory:Give(picky, "ammo", 1))):toBe("full")
		expect(server:Errors()):toEqual({})
	end)

	it("move, merge, split and swap stacks between slots and containers", function()
		local server, inventory = boot()
		local a = inventory:CreateContainer({ size = 4 })
		local b = inventory:CreateContainer({ size = 2, maxSize = 2 })
		inventory:Give(a, "bandage", 3)
		inventory:Give(a, "pistol", 1)
		expect(inventory:Transfer(a, 1, b, 1, 2)):toBe(true) -- part of a stack into an empty slot
		expect(counts(a) .. " | " .. counts(b)):toBe("bandagex1 pistolx1 - - | bandagex2 -")
		expect(inventory:Transfer(a, 1, b, 1)):toBe(true) -- onto the same stack
		expect(counts(a) .. " | " .. counts(b)):toBe("- pistolx1 - - | bandagex3 -")
		expect(inventory:Transfer(a, 2, b, 1)):toBe(true) -- different things swap
		expect(counts(a) .. " | " .. counts(b)):toBe("- bandagex3 - - | pistolx1 -")
		expect(select(2, inventory:Transfer(a, 2, a, 2))):toBe("same")
		expect(select(2, inventory:Transfer(a, 1, b, 2))):toBe("empty")
		inventory:Give(a, "rifle", 1)
		expect(select(2, inventory:Transfer(a, 1, b, 2))):toBe("size")
		expect(select(2, inventory:Transfer(b, 1, a, 1))):toBe("size") -- the rifle cannot swap into b
		inventory:Give(a, "bandage", 4) -- 2 onto the stack, 2 into a free slot
		expect(counts(a)):toBe("riflex1 bandagex5 bandagex2 -")
		expect(select(2, inventory:Transfer(a, 3, a, 0))):toBe("same") -- "anywhere" in its own container
		expect(counts(a)):toBe("riflex1 bandagex5 bandagex2 -")
		expect(inventory:Transfer(a, 3, a, 4, 1)):toBe(true)
		expect(counts(a)):toBe("riflex1 bandagex5 bandagex1 bandagex1")
		expect(server:Errors()):toEqual({})
	end)

	it("carry a container inside bags: the weight counts above, no cycles and a limited depth", function()
		local server, inventory = boot()
		local crate = inventory:CreateContainer({ size = 4 })
		inventory:Give(crate, "sack", 3)
		local s1, s2, s3 = crate.items[1], crate.items[2], crate.items[3]
		expect(s1.sub.kind):toBe("bag")
		expect(s1.sub.size):toBe(4)
		expect(s1.sub.title):toBe("items.sack")
		inventory:Give(s1.sub, "ammo", 60)
		expect(inventory:ItemWeight(s1)):toBeCloseTo(1.1, 1e-9)
		expect(inventory:ContainerWeight(crate)):toBeCloseTo(2.1, 1e-9)
		expect(inventory:Transfer(crate, 2, s1.sub, 0)):toBe(true)
		expect(select(2, inventory:Transfer(crate, 1, s2.sub, 0))):toBe("cycle")
		expect(inventory:Transfer(crate, 3, s2.sub, 0)):toBe(true) -- three bags deep
		inventory:Give(crate, "sack", 1)
		local fourth = crate.items[2]
		expect(fourth.id):toBe("sack")
		expect(select(2, inventory:Transfer(crate, 2, s3.sub, 0))):toBe("depth")
		expect(inventory:Root(s3.sub)):toBe(crate)
		expect(inventory:Count(crate, "ammo")):toBe(60)
		expect(#inventory:Inside(crate)):toBe(4)
		local inner = s3.sub.id
		inventory:Destroy(s1)
		expect(inventory:Container(inner)):toBeNil()
		expect(inventory:Instance(s3.uid)):toBeNil()
		expect(counts(crate)):toBe("- sackx1 - -")
		expect(server:Errors()):toEqual({})
	end)
end)

describe("inventory of players", function()
	it("gives a player things into his pockets and bags, counts and takes them back", function()
		local server, inventory = boot()
		local _, ply = join(server, "Bob")
		local pockets = inventory:Pockets(ply)
		expect(pockets.size):toBe(8)
		expect(pockets.maxSize):toBe(1)
		expect(inventory:Give(ply, "pouch", 1)):toBe(1)
		local given, reason = inventory:Give(ply, "ammo", 600)
		expect(given):toBe(540) -- 7 stacks in the pockets, 2 in the pouch
		expect(reason):toBe("full")
		expect(inventory:Count(ply, "ammo")):toBe(540)
		expect(inventory:Take(ply, "ammo", 100)):toBe(100)
		expect(inventory:Count(ply, "ammo")):toBe(440)
		expect(inventory:Load(ply)):toBeCloseTo(4.6, 1e-9)
		expect(#inventory:Own(ply)):toBe(2) -- the pockets and the pouch in them
		given, reason = inventory:Give(ply, "rifle", 1)
		expect(given):toBe(0)
		expect(reason):toBe("size")
		given = inventory:Give(ply, "rifle", 1, { cond = 0.5 }, { drop = true })
		expect(given):toBe(0)
		local ground = groundOf(inventory)
		expect(#ground):toBe(1)
		expect(ground[1].item.id):toBe("rifle")
		expect(ground[1].item.state.cond):toBe(0.5)
		expect(server:Get("NC").Modules:Instance("inventory").ctx.components.ground:Get(ground[1].ent).id):toBe("rifle")
		server:Command("nc_inv", nil, { "Bob" })
		expect(#server:Lines("Bob carries 4.6 kg")):toBe(1)
		expect(#server:Lines("pockets #")):toBe(1)
		server:Command("nc_item", nil, { "Bob", "bandage", "2" })
		expect(#server:Lines("Bob got 2 of bandage")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("empties the containers of a player at his loadout and forgets him when he leaves", function()
		local server, inventory, players = boot()
		local _, ply = join(server, "Bob")
		inventory:Give(ply, "pouch", 1)
		inventory:Give(ply, "bandage", 9)
		expect(inventory:Carries(ply)):toBe(true)
		local pouch = inventory:Pockets(ply).items[1].sub
		players:Deploy(ply)
		expect(inventory:Carries(ply)):toBe(false)
		expect(inventory:Container(pouch.id)):toBeNil()
		local pockets = inventory:Pockets(ply)
		inventory:Give(ply, "bandage", 1)
		Env.Leave(server, ply)
		server:Advance(0.1)
		expect(inventory:Container(pockets.id)):toBeNil()
		expect(inventory.owned[ply]):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("asks where things go first and whether a move is allowed", function()
		local server, inventory, _, NC = boot()
		local client, ply = join(server, "Bob")
		local holster = inventory:CreateContainer({ kind = "equipment", size = 1, maxSize = 3, slotNames = { "primary" } })
		inventory:AddOwned(ply, holster, 10)
		NC.Events:On("inventory.place", function(_, _, def)
			if def.category == "weapon" and holster.items[1] == nil then
				return holster, 1
			end
		end)
		local locked = false
		NC.Events:On("inventory.canMove", function() if locked then return false end end)
		expect(inventory:Give(ply, "rifle", 1)):toBe(1)
		expect(holster.items[1].id):toBe("rifle")
		inventory:Give(ply, "bandage", 1)
		sync(server, client)
		local view = mine(client)
		expect(view:Own()[1].kind):toBe("equipment")
		expect(view:Own()[1].slotNames):toEqual({ "primary" })
		locked = true
		expect(select(2, inventory:Move(ply, holster.id, 1, inventory:Pockets(ply).id, 2))):toBe("denied")
		locked = false
		-- A swap would put the rifle into the pockets.
		expect(select(2, inventory:Move(ply, inventory:Pockets(ply).id, 1, holster.id, 1))):toBe("size")
		expect(server:Errors()):toEqual({})
	end)
end)

describe("inventory in the world", function()
	it("drops things in front of the player and picks them up with the use key", function()
		local server, inventory = boot()
		local client, ply = join(server, "Bob")
		inventory:Give(ply, "bandage", 5)
		local pockets = inventory:Pockets(ply)
		expect(inventory:Act(ply, pockets.id, 1, "drop", 2)):toBe(true)
		expect(pockets.items[1].count):toBe(3)
		local ground = groundOf(inventory)
		expect(#ground):toBe(1)
		local ent = ground[1].ent
		expect(ent:GetModel()):toBe("models/bandage.mdl")
		expect(ent:GetPos()):toEqual(Vector(36, 0, 64))
		expect(inventory.ctx.components.ground:Get(ent).count):toBe(2)
		server:Advance(1)
		expect(Env.UseEntity(server, ply, ent)):toBe(false)
		expect(pockets.items[1].count):toBe(5)
		server:Advance(0.1)
		expect(ent:IsValid()):toBe(false)
		expect(#groundOf(inventory)):toBe(0)
		-- Full pockets: the thing stays and the player hears why.
		inventory:Give(ply, "ammo", 7 * 60)
		inventory:Give(ply, "pistol", 1, nil, { drop = true })
		inventory:Give(pockets, "bandage", 1)
		ent = inventory:SpawnItem(inventory:Create("bandage", 1), Vector(30, 0, 40))
		server:Advance(1)
		Env.UseEntity(server, ply, ent)
		expect(ent:IsValid()):toBe(true)
		expect(inventory:ItemOf(ent).count):toBe(1)
		sync(server, client)
		local notices = client:Get("NC").Modules:Instance("notices"):Active()
		expect(notices[#notices].text):toBe("No room for it")
		expect(server:Errors()):toEqual({})
	end)

	it("keeps at most config.maxGround things on the ground, the oldest go first", function()
		local server, inventory = boot(nil, { patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.inventory = { maxGround = 3 }
			return cfg
		end } })
		local first
		for i = 1, 5 do
			local ent = inventory:SpawnItem(inventory:Create("ammo", i), Vector(i * 10, 0, 0))
			first = first or ent
		end
		local ground = groundOf(inventory)
		expect(#ground):toBe(3)
		expect(ground[1].item.count):toBe(3)
		expect(inventory:ItemOf(first)):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("opens places in reach, gives from them and closes them when the player goes away", function()
		local server, inventory = boot()
		local client, ply = join(server, "Bob")
		local ent, crate = inventory:SpawnPlace(Vector(60, 0, 0), nil, { kind = "crate", size = 6 })
		inventory:Give(crate, "bandage", 5)
		inventory:Give(crate, "ammo", 30)
		inventory:Give(crate, "sack", 1)
		inventory:Give(crate.items[3].sub, "bandage", 2)
		expect(inventory.ctx.components.place:Get(ent).kind):toBe("crate")
		sync(server, client)
		local view = mine(client)
		expect(#view:External()):toBe(0)
		expect(Env.UseEntity(server, ply, ent)):toBe(false)
		sync(server, client)
		expect(#view:External()):toBe(1)
		local seen = view:External()[1]
		expect(seen.id):toBe(crate.id)
		expect(seen.kind):toBe("crate")
		expect(#seen.items):toBe(3)
		expect(seen.bySlot[3].sub):toBe(crate.items[3].sub.id)
		expect(view:IsScreenOpen()):toBe(true)
		-- What the client asks for, the server checks and does.
		view:Act(crate.id, 1, "take")
		sync(server, client)
		expect(inventory:Count(ply, "bandage")):toBe(5)
		expect(view:Count("bandage")):toBe(5)
		expect(view:Get(crate.id).bySlot[1]):toBeNil()
		view:Act(crate.id, 3, "open")
		sync(server, client)
		expect(#view:External()):toBe(2)
		expect(view:External()[2].kind):toBe("bag")
		expect(view:External()[2].parent):toBe(crate.id)
		view:Act(crate.id, 0, "take_all")
		sync(server, client)
		expect(inventory:Count(ply, "ammo")):toBe(30)
		expect(crate.items[3].id):toBe("sack") -- too big for the pockets
		-- Too far: the server closes it.
		ply:SetPos(Vector(400, 0, 0))
		server:Advance(0.6)
		Env.Flush(server, client)
		expect(#view:External()):toBe(0)
		view:Move(crate.id, 3, inventory:Pockets(ply).id, 0, 0)
		sync(server, client)
		expect(crate.items[3]):notToBe(nil)
		server:Advance(1)
		Env.UseEntity(server, ply, ent)
		sync(server, client)
		local notices = client:Get("NC").Modules:Instance("notices"):Active()
		expect(notices[#notices].text):toBe("Too far away")
		-- A removed place takes its things with it.
		local sack = crate.items[3].sub
		ent:Remove()
		server:Advance(0.1)
		expect(inventory:Container(crate.id)):toBeNil()
		expect(inventory:Container(sack.id)):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("leaves the belongings of the dead in a bag that goes away when emptied", function()
		local server, inventory = boot()
		local _, bob = join(server, "Bob")
		local client, al = join(server, "Al", { pos = Vector(40, 0, 0) })
		inventory:Give(bob, "bandage", 3)
		inventory:Give(bob, "pouch", 1)
		Env.Kill(bob)
		expect(inventory:Carries(bob)):toBe(false)
		local places = {}
		for ent, c in pairs(inventory.places) do
			places[#places + 1] = { ent = ent, c = c }
		end
		expect(#places):toBe(1)
		local bag, c = places[1].ent, places[1].c
		expect(c.kind):toBe("corpse")
		expect(c.title):toBe("inventory.kind.remains")
		expect(c.name):toBe("Bob")
		expect(counts(c)):toBe("bandagex3 pouchx1 - - - - - -")
		expect(bag:GetModel()):toBe(inventory.ctx.config.bagModel)
		Env.UseEntity(server, al, bag)
		sync(server, client)
		local view = mine(client)
		expect(view:Title(view:External()[1])):toBe("Belongings of Bob")
		view:Act(c.id, 0, "take_all")
		sync(server, client)
		expect(inventory:Count(al, "bandage")):toBe(3)
		server:Advance(0.1)
		expect(bag:IsValid()):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("puts the belongings of the dead on their body when there is one", function()
		local server, inventory, _, NC = boot({ "players", "notices", "organism", "damage", "ragdoll", "inventory" })
		local ragdoll = NC.Modules:Instance("ragdoll")
		local _, bob = join(server, "Bob")
		local ru = join(server, "Ivan", { language = "ru", pos = Vector(40, 0, 0) })
		inventory:Give(bob, "ammo", 45)
		Env.Kill(bob)
		local corpse = ragdoll:Corpses()[1].ent
		local c = inventory:PlaceOf(corpse)
		expect(c.kind):toBe("corpse")
		expect(c.title):toBe("inventory.kind.corpse")
		expect(inventory:Count(c, "ammo")):toBe(45)
		server:Advance(1)
		Env.Flush(server, ru)
		local place = mine(ru).ctx.components.place:Get(corpse)
		expect(place.kind):toBe("corpse")
		expect(mine(ru):_T(place.title, { name = place.name })):toBe("Тело: Bob")
		expect(server:Errors()):toEqual({})
	end)

	it("sends nothing to bots but lets them carry things", function()
		local server, inventory = boot()
		local robot = bot(server, "Robot")
		expect(inventory:Give(robot, "bandage", 2)):toBe(2)
		sync(server)
		expect(inventory:Watching(robot, inventory:Pockets(robot))):toBeNil()
		expect(server:Errors()):toEqual({})
	end)
end)

describe("inventory screen", function()
	it("opens with the context menu key and moves things by drag and drop", function()
		local server, inventory = boot()
		local client, ply = join(server, "Bob")
		inventory:Give(ply, "bandage", 5)
		inventory:Give(ply, "pouch", 1)
		sync(server, client)
		local view = mine(client)
		local own = view:Own()
		expect(#own):toBe(2)
		expect(own[1].kind):toBe("pockets")
		expect(own[2].kind):toBe("bag")
		expect(view:Count("bandage")):toBe(5)
		expect(view:ScreenLoad()):toBeCloseTo(0.7, 1e-9)
		expect(Env.BindPress(client, "+menu_context")):toBe(true)
		expect(view:IsScreenOpen()):toBe(true)
		expect(view.titleLabel.text):toBe("Inventory · 0.7 kg")
		local pockets, pouch = view:OwnOfKind("pockets"), view:OwnOfKind("bag")
		local from, to = slotButton(client, pockets.id, 1), slotButton(client, pouch.id, 1)
		expect(from.ncItem.id):toBe("bandage")
		expect(from.ncCount):toBe("×5")
		expect(from.tooltip):toContain("0.5 kg")
		to.ncReceive(to, { from }, true)
		sync(server, client)
		expect(counts(inventory:Pockets(ply))):toBe("- pouchx1 - - - - - -")
		expect(view:Get(pouch.id).bySlot[1].count):toBe(5)
		-- Ctrl: one of the stack.
		client.keysDown = { [KEY_LCONTROL] = true }
		from, to = slotButton(client, pouch.id, 1), slotButton(client, pockets.id, 3)
		to.ncReceive(to, { from }, true)
		sync(server, client)
		client.keysDown = nil
		expect(counts(inventory:Pockets(ply))):toBe("- pouchx1 bandagex1 - - - - -")
		-- Onto the empty right side: onto the ground.
		from = slotButton(client, pouch.id, 1)
		view.externalPanel.ncReceive(view.externalPanel, { from }, true)
		sync(server, client)
		expect(#groundOf(inventory)):toBe(1)
		expect(groundOf(inventory)[1].item.count):toBe(4)
		expect(Env.BindPress(client, "+menu_context")):toBe(true)
		expect(view:IsScreenOpen()):toBe(false)
		client:Command("nc_inventory", client.localPlayer, {})
		expect(view:IsScreenOpen()):toBe(true)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("offers the verbs of an item in its menu in the language of the player", function()
		local server, inventory = boot()
		local client, ply = join(server, "Ivan", { language = "ru" })
		inventory:Give(ply, "bandage", 4)
		inventory:Give(ply, "pouch", 1)
		sync(server, client)
		local view = mine(client)
		view:OpenScreen()
		expect(view.titleLabel.text):toBe("Инвентарь · 0.6 кг")
		local menu = view:OpenMenu(slotButton(client, view:OwnOfKind("pockets").id, 1))
		local options = World.FindPanels(client, function(panel) return panel.parent == menu end)
		expect(texts(options)):toEqual({ "Разделить", "Выбросить", "Переложить в" })
		local sub = options[3]
		expect(texts(sub:GetChildren())):toEqual({ "Сумка" })
		expect(view:Title(view:OwnOfKind("bag"))):toBe("Сумка") -- testkit.pouch has no translation
		options[1].func()
		sync(server, client)
		expect(counts(inventory:Pockets(ply))):toBe("bandagex2 pouchx1 bandagex2 - - - - -")
		menu = view:OpenMenu(slotButton(client, view:OwnOfKind("pockets").id, 3))
		World.FindPanels(client, function(panel) return panel.parent == menu end)[3]:GetChildren()[1].func()
		sync(server, client)
		expect(counts(inventory:Pockets(ply))):toBe("bandagex2 pouchx1 - - - - - -")
		expect(inventory:Count(ply, "bandage")):toBe(4)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("searches a place from the screen and closes what was open with it", function()
		local server, inventory = boot()
		local client, ply = join(server, "Bob")
		local ent, crate = inventory:SpawnPlace(Vector(60, 0, 0), nil, { kind = "crate", size = 4 })
		inventory:Give(crate, "bandage", 2)
		inventory:Give(crate, "ammo", 10)
		Env.UseEntity(server, ply, ent)
		sync(server, client)
		local view = mine(client)
		expect(view:IsScreenOpen()):toBe(true)
		local header = World.FindPanels(client, function(panel)
			return panel.class == "DPanel" and panel.ncContainer == crate.id
		end)[1]
		expect(header.ncTitle):toBe("Crate")
		expect(header.ncInfo):toBe("2/4 · 0.3 kg")
		view:QuickUse(slotButton(client, crate.id, 1))
		sync(server, client)
		expect(inventory:Count(ply, "bandage")):toBe(2)
		local takeAll = World.FindPanels(client, function(panel) return panel.ncAction == "take_all" end)[1]
		takeAll.DoClick()
		sync(server, client)
		expect(inventory:Count(ply, "ammo")):toBe(10)
		expect(crate:IsEmpty()):toBe(true)
		view:CloseScreen()
		sync(server, client)
		expect(inventory:Watching(ply, crate)):toBeNil()
		expect(#view:External()):toBe(0)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("names the thing or the place under the crosshair and the key to use it", function()
		local server, inventory = boot()
		local client = join(server, "Bob")
		local ru = join(server, "Ivan", { language = "ru" })
		local thing = inventory:SpawnItem(inventory:Create("ammo", 30), Vector(50, 0, 60))
		local crate = inventory:SpawnPlace(Vector(50, 20, 60), nil, { kind = "crate" })
		server:Advance(1)
		Env.Flush(server, client, ru)
		local function paint(realm, ent)
			realm.traceLine = function(trace)
				return { Hit = true, HitPos = trace.endpos, Entity = ent or World.NULL, Fraction = 0.5 }
			end
			realm.drawn = {}
			realm:Call("HUDPaint")
			return realm.drawn
		end
		local drawn = paint(client, thing)
		expect(drawn):toContain("ammo ×30")
		expect(drawn):toContain("E — pick up")
		drawn = paint(ru, crate)
		expect(drawn):toContain("Ящик")
		expect(drawn):toContain("E — обыскать")
		drawn = paint(client, nil)
		expect(drawn):notToContain("E — pick up")
		expect(client:Errors()):toEqual({})
		expect(ru:Errors()):toEqual({})
		expect(server:Errors()):toEqual({})
	end)
end)

describe("inventory kits", function()
	it("gives the things of a kit in order, warns once about unknown items and lists kits", function()
		local server, inventory = boot()
		local client, ply = join(server, "Bob")
		inventory:RegisterKit("medic", {
			{ "sack" },
			{ "bandage", 7 },
			{ item = "ammo", count = 90 },
			{ "ghost", 2 },
			{ "rifle" },
		})
		expect(inventory:Kit("medic")[2]):toEqual({ item = "bandage", count = 7 })
		expect(inventory:Kits()):toEqual({ "medic" })
		local given, missed = inventory:GiveKit(ply, "medic", { drop = true })
		-- pockets take only small things: the sack and the rifle fall at his feet, ghosts do not exist
		expect(given):toBe(97)
		expect(missed):toBe(4)
		expect(inventory:Count(ply, "bandage")):toBe(7)
		expect(inventory:Count(ply, "ammo")):toBe(90)
		inventory:GiveKit(ply, "medic")
		expect(#server:Lines("kit medic: unknown item ghost")):toBe(1)
		expect(inventory:GiveKit(ply, "nothing")):toBeNil()
		expect(function() inventory:RegisterKit("Bad", {}) end):toFail("lower_snake_case")
		expect(function() inventory:RegisterKit("bad", { { "ammo", 0 } }) end):toFail("count must be")

		local admin = Env.FakePlayer({ name = "Admin", superadmin = true })
		server:Command("nc_kit", admin, { "Bob", "medic" })
		expect(admin.printed[#admin.printed]):toContain("Bob got")
		server:Command("nc_kit", admin, { "Bob", "nothing" })
		expect(admin.printed[#admin.printed]):toBe("unknown kit nothing (nc_kits)")
		server:Command("nc_kits", admin, {})
		expect(admin.printed[#admin.printed]):toContain("medic")
		expect(admin.printed[#admin.printed]):toContain("bandage x7")
		expect(client:Errors()):toEqual({})
	end)
end)
