-- NPCs: kinds and groups of engine creatures, spawning with weapons, health and skill,
-- friends of one tag, the hunt for the nearest player, kills and removals, spots far from
-- the players and the limit, the creatures of the map, the points in storage and the
-- console, with the real gamemode files and a module of test kinds.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local MODULES = "nextcity/gamemode/modules/"

local KIT = {
	[MODULES .. "npckit/module.lua"] = [[
		return { id = "npckit", requires = { "npcs" }, files = { sv = { "sv_npckit.lua" } } }
	]],
	[MODULES .. "npckit/sv_npckit.lua"] = [[
		local M = NC.Module("npckit")
		function M:Init(ctx)
			local npcs = ctx:Require("npcs")
			npcs:RegisterKind("zombie", { class = "npc_zombie" })
			npcs:RegisterKind("soldier", { class = "npc_combine_s", weapons = { "weapon_smg1", "weapon_ar2" },
				health = 80, proficiency = "good", model = "models/combine_super_soldier.mdl", skin = 1,
				keyvalues = { tacticalvariant = 1 }, spawnflags = 256 })
			npcs:RegisterKind("rebel", { class = "npc_citizen", hostile = false })
			npcs:RegisterGroup("mixed", { { kind = "zombie", weight = 3 }, { kind = "soldier", weight = 1 } })
			npcs:RegisterGroup("broken", { { kind = "ghost" } })
		end
	]],
}

-- opts: settings of npcs, spawns (map entities first), data (DATA of an earlier server).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = { "players", "storage", "npcs" }, files = KIT, data = opts.data,
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.npcs = opts.settings
			return cfg
		end } })
	for _, spawn in ipairs(opts.spawns or {}) do
		Env.Spawn(server, spawn)
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC, npcs = NC.Modules:Instance("npcs"), log = {},
		players = NC.Modules:Instance("players") }
	-- Dice: Random() gives `w.draw`, Random(n) the first choice.
	w.draw = 0
	w.npcs.Random = function(n)
		if n ~= nil then
			return 1
		end
		return w.draw
	end
	local function name(ent)
		if ent == nil or not ent:IsValid() then
			return "-"
		end
		return ent:IsPlayer() and ent:Nick() or ent:GetClass()
	end
	NC.Events:On("npcs.spawned", function(ent, kind, tag)
		w.log[#w.log + 1] = "spawned " .. kind .. " " .. tostring(tag)
	end)
	NC.Events:On("npcs.killed", function(ent, attacker, _, tag, kind)
		w.log[#w.log + 1] = "killed " .. tostring(kind) .. " " .. tostring(tag) .. " by " .. name(attacker)
	end)
	NC.Events:On("npcs.removed", function(ent, tag)
		w.log[#w.log + 1] = "removed " .. ent:GetClass() .. " " .. tostring(tag)
	end)
	function w.join(nick, pos)
		local client, ply = Env.Join(server, { name = nick, superadmin = true })
		w.players:Deploy(ply)
		ply:SetPos(pos)
		return client, ply
	end
	function w.run(seconds)
		for _ = 1, math.floor(seconds / 0.1 + 0.5) do
			server:Advance(0.1)
		end
	end
	return w
end

local function classes(list)
	local out = {}
	for i, ent in ipairs(list) do
		out[i] = ent:GetClass()
	end
	return out
end

describe("npcs", function()
	it("spawns kinds with weapons, health and skill, befriends one tag and hunts the nearest player", function()
		local w = boot()
		local npcs = w.npcs
		local _, alyx = w.join("Alyx", Vector(1000, 0, 0))
		local _, barney = w.join("Barney", Vector(3000, 0, 0))

		local soldier = npcs:Spawn("soldier", Vector(0, 0, 0), { tag = "wave" })
		expect(soldier:GetClass()):toBe("npc_combine_s")
		expect(soldier:GetKeyValues()):toEqual({ additionalequipment = "weapon_smg1", tacticalvariant = "1",
			spawnflags = "256" })
		expect({ soldier.model, soldier.skin, soldier:Health(), soldier.maxHealth }):toEqual({
			"models/combine_super_soldier.mdl", 1, 80, 80 })
		expect(soldier.proficiency):toBe(2)
		expect(soldier.relationText):toBe("player D_HT 99")
		-- At once on its way to the nearest player, who it remembers as an enemy.
		expect(soldier.schedule):toBe(72)
		expect(soldier.lastPosition):toEqual(Vector(1000, 0, 0))
		expect(soldier.enemyMemory[1]):toBe(alyx)

		local zombie = npcs:Spawn("zombie", Vector(2900, 0, 0), { tag = "wave" })
		expect(zombie.relationships[soldier]):toEqual({ 3, 99 })
		expect(soldier.relationships[zombie]):toEqual({ 3, 99 })
		expect(zombie.lastPosition):toEqual(Vector(3000, 0, 0))
		local rebel = npcs:Spawn("rebel", Vector(0, 500, 0), { tag = "other", hunt = false })
		expect(rebel.relationText):toBeNil()
		expect(rebel.schedule):toBeNil()
		expect(rebel.relationships[soldier]):toBeNil()
		expect({ npcs:Count("wave"), npcs:Count() }):toEqual({ 2, 3 })
		expect(npcs:List("wave")):toEqual({ soldier, zombie })
		expect(npcs:TagOf(rebel)):toBe("other")
		expect({ npcs:Spawn("ghost", Vector(0, 0, 0)) }):toEqual({ nil, "unknown kind ghost" })

		-- The hunt: one without an enemy runs to the nearest player, one with an enemy fights.
		soldier:SetEnemy(barney)
		soldier.schedule, zombie.schedule = nil, nil
		zombie:SetPos(Vector(1200, 0, 0))
		w.run(5.1)
		expect(soldier.schedule):toBeNil()
		expect(zombie.schedule):toBe(72)
		expect(zombie.lastPosition):toEqual(Vector(1000, 0, 0))
		expect(rebel.schedule):toBeNil()

		-- A kill: the event with the tag and the kind, a frag; a removal without a death.
		Env.KillNPC(zombie, alyx)
		expect(alyx:Frags()):toBe(1)
		soldier:Remove()
		w.server:Advance(0.1)
		expect(w.log):toEqual({ "spawned soldier wave", "spawned zombie wave", "spawned rebel other",
			"killed zombie wave by Alyx", "removed npc_combine_s wave" })
		expect({ npcs:Count("wave"), npcs:Count() }):toEqual({ 0, 1 })
		npcs:Clear()
		w.server:Advance(0.1)
		expect(rebel:IsValid()):toBe(false)
		expect(npcs:Count()):toBe(0)
		expect(w.server:Errors()):toEqual({})
	end)

	it("spawns groups by weight round the far points, within the limit", function()
		local w = boot({ settings = { maxAlive = 5, clearance = 500 },
			spawns = { { class = "info_player_start", pos = Vector(0, 0, 0), map = true },
				{ class = "info_player_combine", pos = Vector(2000, 0, 0), map = true } } })
		local npcs = w.npcs
		w.join("Alyx", Vector(0, 0, 0))
		w.draw = 0.8
		expect(npcs:Roll("mixed")):toBe("soldier")
		w.draw = 0.5
		expect(npcs:Roll("mixed")):toBe("zombie")
		expect(npcs:Roll("nothing")):toBeNil()

		-- Without points: the spawns of side b, a ring around for the next one.
		local spots = npcs:Spots(2)
		expect(spots[1]):toEqual(Vector(2000, 0, 0))
		expect(spots[2]:Distance(Vector(2000, 0, 0))):toBeCloseTo(48, 0.01)

		-- Points: not the one next to the player, the farther half of the rest, farthest first.
		npcs:AddPoint(Vector(100, 0, 0), 0)
		npcs:AddPoint(Vector(2000, 0, 0), 0)
		npcs:AddPoint(Vector(-3000, 0, 0), 0)
		npcs:AddPoint(Vector(0, 4000, 0), 90)
		spots = npcs:Spots(4)
		expect(spots[1]):toEqual(Vector(0, 4000, 0))
		expect(spots[2]):toEqual(Vector(-3000, 0, 0))
		expect(spots[3]:Distance(Vector(0, 4000, 0))):toBeCloseTo(48, 0.01)
		expect(spots[4]:Distance(Vector(-3000, 0, 0))):toBeCloseTo(48, 0.01)

		-- No more than the limit.
		expect(npcs:SpawnGroup("mixed", 8, { tag = "wave" })):toBe(5)
		expect(classes(npcs:List("wave"))):toEqual({ "npc_zombie", "npc_zombie", "npc_zombie", "npc_zombie",
			"npc_zombie" })
		expect(npcs:SpawnGroup("mixed", 2, { tag = "wave" })):toBe(0)
		npcs:Clear("wave")
		w.server:Advance(0.1)
		expect(npcs:SpawnGroup("nothing", 2)):toBe(0)
		expect(npcs:SpawnGroup("broken", 2)):toBe(0)
		expect(npcs:SpawnGroup("broken", 2)):toBe(0)
		expect(w.server:Lines("WARN")):toEqual({ "[NC] WARN  [npcs] unknown group nothing",
			"[NC] WARN  [npcs] group broken: unknown kind ghost" })
		expect(w.server:Errors()):toEqual({})
	end)

	it("takes over the creatures of the map but friends, keeps points in storage and has a console", function()
		local w = boot({ spawns = {
			{ class = "npc_combine_s", pos = Vector(500, 0, 0), map = true },
			{ class = "npc_citizen", pos = Vector(600, 0, 0), map = true },
			{ class = "npc_crow", pos = Vector(700, 0, 0), map = true },
		} })
		local npcs, server = w.npcs, w.server
		local _, admin = w.join("Admin", Vector(0, 0, 0))
		expect(npcs:Adopt("map")):toBe(1)
		local combine = npcs:List("map")[1]
		expect(combine:GetClass()):toBe("npc_combine_s")
		expect(npcs:Adopt("map")):toBe(0)
		-- They keep their places.
		w.run(5.1)
		expect(combine.schedule):toBeNil()
		-- A cleanup of the map makes new ones: the old one is gone.
		server:Get("game").CleanUpMap()
		server:Advance(0.1)
		expect(w.log):toEqual({ "removed npc_combine_s map" })
		expect(npcs:Adopt("map", { hunt = true })):toBe(1)
		w.run(5.1)
		expect(npcs:List("map")[1].schedule):toBe(72)

		local aim = Vector(300, 40, 0)
		server.traceLine = function(trace)
			if trace.filter == admin and trace.mask == server:Get("MASK_SOLID") then
				return { Hit = true, HitPos = aim, Fraction = 0.5 }
			end
			return { Hit = false, HitPos = trace.endpos, Fraction = 1 }
		end
		local function run(...)
			admin.printed = {}
			server:Command("nc_npcs", admin, { ... })
			return admin.printed
		end
		expect(run("add")[1]):toContain("added   1. at (300, 40, 0)")
		aim = Vector(-2000, 0, 16)
		run("add")
		local list = run("list")
		expect(list[1]):toBe("nc_npcs: 2 points on gm_test, 1 creatures")
		expect(list[3]):toContain("at (-2000, 0, 16)")
		expect(run("kinds")):toEqual({ "kinds: rebel(npc_citizen), soldier(npc_combine_s), zombie(npc_zombie)",
			"groups:", "  broken: ghost 1", "  mixed: zombie 3, soldier 1" })
		expect(run("spawn", "zombie", "2")[1]):toBe("nc_npcs: 2 of zombie spawned")
		expect(run("spawn", "mixed", "3")[1]):toBe("nc_npcs: 3 of mixed spawned")
		expect(run("spawn", "ghost")[1]):toContain("unknown kind or group ghost")
		expect(npcs:Count("admin")):toBe(5)
		expect(run("clear")[1]):toBe("nc_npcs: 6 creatures removed")
		aim = Vector(290, 40, 0)
		expect(run("remove")[1]):toContain("removed   1. at (300, 40, 0)")
		expect(run("remove")[1]):toBe("nc_npcs remove: no point within 128 units")

		-- The next server on the same disk has the point.
		server:Advance(3)
		expect(server.data["nextcity/npcs.json"]):toBeTruthy()
		local again = boot({ data = server.data })
		expect(#again.npcs:Points()):toBe(1)
		expect(server:Errors()):toEqual({})
		expect(again.server:Errors()):toEqual({})
	end)
end)
