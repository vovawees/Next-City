-- Loot module: tables of loot (weighted draws, counts, tables inside tables), crates, loose
-- things on the ground, the points of a map in storage and the console, the rule of rounds
-- and crates that fill up again, with the real gamemode files and a module of test loot.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

local MODULES = "nextcity/gamemode/modules/"

local KIT = {
	[MODULES .. "lootkit/module.lua"] = [[
		return { id = "lootkit", requires = { "inventory", "loot" },
			files = { sh = { "sh_lootkit.lua" }, sv = { "sv_lootkit.lua" } } }
	]],
	[MODULES .. "lootkit/sh_lootkit.lua"] = [[
		local M = NC.Module("lootkit")
		function M:Init(ctx)
			local inventory = ctx:Require("inventory")
			inventory:RegisterItem("bandage", { weight = 0.1, stack = 5, category = "medical" })
			inventory:RegisterItem("ammo", { weight = 0.01, stack = 60, category = "ammo", model = "models/ammo.mdl" })
			inventory:RegisterItem("canteen", { weight = 0.5 })
			inventory:RegisterItem("pistol", { weight = 1, size = 2, category = "weapon" })
			if SERVER then
				self:Tables(ctx:Require("loot"))
			end
		end
	]],
	[MODULES .. "lootkit/sv_lootkit.lua"] = [[
		local M = NC.Module("lootkit")
		function M:Tables(loot)
			loot:RegisterTable("ammo", { entries = { { item = "ammo", count = { 10, 30 } } } })
			loot:RegisterTable("small", { draws = { 1, 3 }, entries = {
				{ item = "bandage", weight = 3, count = { 1, 2 } },
				{ table = "ammo", weight = 1 },
				{ weight = 1 },
			} })
			loot:RegisterTable("flask", { entries = { { item = "canteen", state = { water = 3 } } } })
			loot:RegisterTable("pile", { entries = { { item = "ammo", count = 150 } } })
			loot:RegisterTable("broken", { draws = 2, entries = { { item = "ghost" }, { table = "nowhere" } } })
			loot:RegisterTable("deep", { entries = { { table = "deep" } } })
			loot:RegisterTable("many", { draws = 100, entries = { { item = "ammo" } } })
			loot:RegisterCrate("kit_crate", { model = "models/kit/crate.mdl", title = "loot.crate", size = 4,
				table = "small" })
			loot:RegisterCrate("kit_refill", { size = 2, table = "ammo", respawn = 3 })
		end
	]],
}

local SPAWNS = {
	{ class = "info_player_start", pos = Vector(0, 0, 0), map = true },
	{ class = "info_player_start", pos = Vector(500, 0, 0), map = true },
}

-- opts: modules (repository modules), data (DATA of an earlier server), settings
-- ({ [module] = settings }), spawns (map spawn points first).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = opts.modules or { "players", "notices", "inventory", "storage", "loot" },
		files = KIT, data = opts.data, patch = { [Env.CONFIG] = function(cfg)
			for id, settings in pairs(opts.settings or {}) do
				cfg.modules.settings[id] = settings
			end
			return cfg
		end } })
	if opts.spawns then
		for _, point in ipairs(SPAWNS) do
			Env.Spawn(server, point)
		end
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC.Modules:Instance("loot"), NC.Modules:Instance("inventory"), NC
end

-- Replaces the dice of the module: values come in order; when they run out, a draw gives
-- 0 and a number between a and b gives a.
local function dice(loot, values)
	local queue = {}
	for i, value in ipairs(values or {}) do
		queue[i] = value
	end
	loot.Random = function(a, b)
		local value = table.remove(queue, 1)
		if a == nil then
			return value or 0
		end
		assert(value == nil or (value >= a and value <= b), "a scripted number outside of the range")
		return value or a
	end
	return queue
end

-- The containers of the loot crates in the world: { [crate id] = count }.
local function crates(inventory)
	local out = {}
	for ent, c in pairs(inventory.places) do
		if ent:IsValid() then
			local id = c.data.loot
			if id ~= nil then
				out[id] = (out[id] or 0) + 1
			end
		end
	end
	return out
end

local function ground(inventory)
	local out = {}
	for ent, item in pairs(inventory.ground) do
		if ent:IsValid() then
			out[#out + 1] = { id = item.id, count = item.count }
		end
	end
	table.sort(out, function(a, b) return a.count > b.count end)
	return out
end

describe("loot", function()
	it("rolls weighted draws with counts, tables inside tables and nothing", function()
		local server, loot, _, NC = boot()
		expect(server:Errors()):toEqual({})
		expect(loot:Tables()):toEqual({ "ammo", "broken", "deep", "flask", "many", "pile", "small" })
		expect(loot:Crates()):toEqual({ "kit_crate", "kit_refill" })

		-- 3 draws: a bandage (x2), the table ammo (25), nothing.
		dice(loot, { 3, 0.1, 2, 0.7, 0, 25, 0.95 })
		expect(loot:Roll("small")):toEqual({ { id = "bandage", count = 2 }, { id = "ammo", count = 25 } })
		-- The same item adds up.
		dice(loot, { 2, 0, 1, 0.5, 2 })
		expect(loot:Roll("small")):toEqual({ { id = "bandage", count = 3 } })
		-- Things with a state get a copy of it each.
		dice(loot)
		local a, b = loot:Roll("flask"), loot:Roll("flask")
		expect(a):toEqual({ { id = "canteen", count = 1, state = { water = 3 } } })
		a[1].state.water = 0
		expect(b[1].state.water):toBe(3)
		expect(loot:Roll("flask")[1].state.water):toBe(3)
		-- A roll has a budget of draws.
		expect(loot:Roll("many")):toEqual({ { id = "ammo", count = 32 } })

		-- A mode keeps things out of the loot: loot.allow (id, def) -> false.
		local asked = {}
		NC.Events:On("loot.allow", function(id, def)
			asked[#asked + 1] = id .. ":" .. tostring(def.category)
			if def.category == "ammo" then
				return false
			end
		end)
		dice(loot, { 3, 0.1, 2, 0.7, 0, 25, 0.95 })
		expect(loot:Roll("small")):toEqual({ { id = "bandage", count = 2 } })
		expect(asked):toEqual({ "bandage:medical", "ammo:ammo" })
		expect(server:Errors()):toEqual({})
	end)

	it("warns once about unknown items, tables and nesting too deep, and checks what is registered", function()
		local server, loot = boot()
		dice(loot, { 0, 0.9, 0, 0.9 })
		expect(loot:Roll("broken")):toEqual({})
		expect(loot:Roll("broken")):toEqual({})
		expect(#server:Lines("table broken: unknown item ghost")):toBe(1)
		expect(#server:Lines("table broken: unknown table nowhere")):toBe(1)
		expect(loot:Roll("deep")):toEqual({})
		expect(#server:Lines("table deep: tables nested deeper than 4")):toBe(1)
		expect(loot:Roll("nope")):toEqual({})
		expect(#server:Lines("loot: unknown table nope")):toBe(1)

		expect(function() loot:RegisterTable("Bad", { entries = { { item = "ammo" } } }) end):toFail("lower_snake_case")
		expect(function() loot:RegisterTable("empty", { entries = {} }) end):toFail("non-empty")
		expect(function() loot:RegisterTable("bad", { entries = { { item = "ammo", count = { 3, 1 } } } }) end)
			:toFail("{ min, max }")
		expect(function() loot:RegisterTable("bad", { entries = { { item = "ammo", weight = -1 } } }) end)
			:toFail("bad weight")
		expect(function() loot:RegisterCrate("Crate", {}) end):toFail("lower_snake_case")
		expect(loot:Table("bad")):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("fills crates, scatters loose things in stacks and clears what it made", function()
		local server, loot, inventory = boot()
		dice(loot, { 1, 0 })
		local ent, c = loot:SpawnCrate("kit_crate", Vector(100, 0, 0), Angle(0, 90, 0))
		expect(inventory:PlaceOf(ent)):toBe(c)
		expect(ent:GetModel()):toBe("models/kit/crate.mdl")
		expect(ent:GetPhysicsObject():IsMotionEnabled()):toBe(false)
		expect(c.kind):toBe("crate")
		expect(c.title):toBe("loot.crate")
		expect(c.size):toBe(4)
		expect(c.data.loot):toBe("kit_crate")
		expect(inventory:Count(c, "bandage")):toBe(1)

		-- A container takes what fits.
		local box = inventory:CreateContainer({ kind = "crate", size = 1 })
		dice(loot, { 2, 0, 2, 0.7, 0, 20 })
		expect(loot:Fill(box, "small")):toBe(2)
		expect(inventory:Count(box, "bandage")):toBe(2)
		expect(inventory:Count(box, "ammo")):toBe(0)

		dice(loot)
		local loose = loot:SpawnLoose("pile", Vector(0, 300, 0))
		expect(#loose):toBe(3)
		expect(ground(inventory)):toEqual({ { id = "ammo", count = 60 }, { id = "ammo", count = 60 },
			{ id = "ammo", count = 30 } })
		expect(loot:SpawnCrate("nothing", Vector(0, 0, 0))):toBeNil()
		expect(#server:Lines("loot: unknown crate nothing")):toBe(1)

		loot:ClearAll()
		server:Advance(0.1)
		expect(ent:IsValid()):toBe(false)
		expect(c.removed):toBe(true)
		expect(ground(inventory)):toEqual({})
		expect(crates(inventory)):toEqual({})
		expect(server:Errors()):toEqual({})
	end)

	it("keeps the points of a map in storage and manages them with nc_loot", function()
		local server, loot, inventory = boot()
		local client, admin = Env.Join(server, { name = "Admin", superadmin = true })
		server:Get("NC").Modules:Instance("players"):Deploy(admin)
		local aim = Vector(300, 40, 0)
		server.traceLine = function(trace)
			if trace.filter == admin and trace.mask == server:Get("MASK_SOLID") then
				return { Hit = true, HitPos = aim, Fraction = 0.5 }
			end
			return { Hit = false, HitPos = trace.endpos, Fraction = 1 }
		end
		local function run(...)
			admin.printed = {}
			server:Command("nc_loot", admin, { ... })
			return admin.printed
		end

		expect(run("add", "kit_crate")[1]):toContain("added   1. crate kit_crate")
		aim = Vector(-200, 0, 16)
		expect(run("add", "small")[1]):toContain("added   2. items small")
		expect(run("add", "nothing")[1]):toContain("unknown crate or table nothing")
		local list = run("list")
		expect(list[1]):toBe("nc_loot: 2 points on gm_test")
		expect(list[2]):toContain("at (300, 40, 0)")
		expect(list[3]):toContain("at (-200, 0, 16)")
		expect(#loot:Points()):toBe(2)

		dice(loot)
		expect(run("spawn")[1]):toBe("nc_loot: 2 points spawned")
		expect(crates(inventory)):toEqual({ kit_crate = 1 })
		expect(#ground(inventory)):toBe(1)
		-- Again: what the points gave before goes first.
		run("spawn")
		server:Advance(0.1)
		expect(crates(inventory)):toEqual({ kit_crate = 1 })
		expect(#ground(inventory)):toBe(1)

		local roll = run("roll", "ammo", "4")
		expect(roll[1]):toBe("nc_loot: ammo x4")
		expect(roll[2]):toContain("ammo")
		expect(roll[2]):toContain("40")
		expect(run("tables")):toEqual({ "tables: ammo, broken, deep, flask, many, pile, small",
			"crates: kit_crate(small), kit_refill(ammo)" })

		aim = Vector(290, 40, 0)
		expect(run("remove")[1]):toContain("removed   1. crate kit_crate")
		expect(run("remove")[1]):toBe("nc_loot remove: no point within 128 units")
		run("clear")
		server:Advance(0.1)
		expect(crates(inventory)):toEqual({})
		expect(#ground(inventory)):toBe(0)

		-- The next server on the same disk has the point.
		server:Advance(3)
		expect(server.data["nextcity/loot.json"]):toBeTruthy()
		local again, loot2 = boot({ data = server.data })
		expect(#loot2:Points()):toBe(1)
		expect(loot2:Points()[1]):toEqual({ kind = "items", id = "small", x = -200, y = 0, z = 16,
			yaw = loot2:Points()[1].yaw })
		expect(again:Errors()):toEqual({})
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("keeps points in memory without storage", function()
		local server, loot = boot({ modules = { "players", "notices", "inventory", "loot" } })
		expect(loot:AddPoint("crate", "kit_crate", Vector(10.4, 20.6, 0), 450)):toBe(1)
		expect(loot:Points()):toEqual({ { kind = "crate", id = "kit_crate", x = 10, y = 21, z = 0, yaw = 90 } })
		expect(select(2, loot:AddPoint("crate", "small", Vector(0, 0, 0)))):toBe("unknown crate small")
		expect(select(2, loot:AddPoint("items", "kit_crate", Vector(0, 0, 0)))):toBe("unknown table kit_crate")
		expect(select(2, loot:AddPoint("other", "small", Vector(0, 0, 0)))):toBe("kind must be crate or items")
		expect(loot:Nearest(Vector(0, 0, 0), 10)):toBeNil()
		expect(loot:Nearest(Vector(0, 0, 0), 30)):toBe(1)
		expect(loot:RemovePoint(1)):toBe(true)
		expect(loot:RemovePoint(1)):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("gives every round of a mode with the rule loot what the points give", function()
		local server, loot, inventory, NC = boot({ spawns = true,
			modules = { "players", "notices", "inventory", "storage", "rounds", "loot" },
			settings = { rounds = { mode = "test", shuffle = false } } })
		local rounds = NC.Modules:Instance("rounds")
		rounds:RegisterMode({ id = "test", name = "Test", minPlayers = 1, rules = { "loot" } })
		loot:AddPoint("crate", "kit_crate", Vector(100, 0, 0), 90)
		loot:AddPoint("items", "pile", Vector(200, 0, 0))
		dice(loot)
		Env.Bot(server, { name = "A" })
		server:Advance(0.1)
		expect(rounds:Phase()):toBe("preparing")
		-- The loot appears on the tick after the Setup of the round.
		expect(crates(inventory)):toEqual({})
		server:Advance(0.1)
		expect(crates(inventory)):toEqual({ kit_crate = 1 })
		expect(#ground(inventory)):toBe(3)

		server:Command("nc_round", nil, { "restart" })
		server:Advance(0.1)
		server:Advance(0.1)
		expect(rounds:Round().number):toBe(2)
		expect(crates(inventory)):toEqual({ kit_crate = 1 })
		expect(#ground(inventory)):toBe(3)

		server:Command("nc_round", nil, { "param", "test", "loot", "false" })
		server:Command("nc_round", nil, { "restart" })
		server:Advance(0.1)
		server:Advance(0.1)
		expect(rounds:Round().number):toBe(3)
		expect(crates(inventory)):toEqual({})
		expect(#ground(inventory)):toBe(0)

		server:Command("nc_round", nil, { "param", "test", "loot", "true" })
		server:Command("nc_round", nil, { "param", "test", "lootShare", "0.5" })
		dice(loot, { 0.7, 0.2 })
		server:Command("nc_round", nil, { "restart" })
		server:Advance(0.1)
		server:Advance(0.1)
		expect(crates(inventory)):toEqual({})
		expect(#ground(inventory)):toBe(3)
		expect(server:Errors()):toEqual({})
	end)

	it("fills an emptied crate again after its time when nobody looks into it", function()
		local server, loot, inventory, NC = boot({ settings = { loot = { refill = 1 } } })
		local client, ply = Env.Join(server, { name = "Looter" })
		NC.Modules:Instance("players"):Deploy(ply)
		ply:SetPos(Vector(0, 0, 0))
		local function wait(seconds)
			for _ = 1, seconds * 2 do
				server:Advance(0.5)
			end
		end
		dice(loot, { 0, 12, 0, 20, 0, 10 })
		local _, c = loot:SpawnCrate("kit_refill", Vector(40, 0, 0))
		expect(inventory:Count(c, "ammo")):toBe(12)
		expect(inventory:Open(ply, c)):toBe(true)
		inventory:Take(c, "ammo", 12)
		wait(5)
		expect(inventory:Count(c, "ammo")):toBe(0) -- he is looking
		inventory:Close(ply, c)
		wait(1.5)
		expect(inventory:Count(c, "ammo")):toBe(20)
		inventory:Take(c, "ammo", 5)
		wait(5)
		expect(inventory:Count(c, "ammo")):toBe(15) -- not empty: stays as it is
		inventory:Take(c, "ammo", 15)
		wait(1.5)
		expect(inventory:Count(c, "ammo")):toBe(0) -- the time is not up yet
		wait(3)
		expect(inventory:Count(c, "ammo")):toBe(10)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
