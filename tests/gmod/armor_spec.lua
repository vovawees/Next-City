-- Armor module: classes against projectiles, the blow behind armor, coverage of regions
-- and sides, blades and blows, fragments of a blast, wear, taking armor off, replication,
-- the console and the armor of Team Deathmatch, with the real gamemode files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local DMG = World.DMG

-- Records the hits and what armor did with them.
local RECORDER = {
	[MODULES .. "recorder/module.lua"] = "return { id = 'recorder', files = { sv = { 'sv_recorder.lua' } } }",
	[MODULES .. "recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.hits, M.meets = {}, {}
		function M:Start(ctx)
			ctx:On("damage.hit", function(ply, hit) self.hits[#self.hits + 1] = hit end)
			ctx:On("armor.hit", function(ply, hit, kind, stopped)
				self.meets[#self.meets + 1] = kind .. (stopped and " stopped " or " through ") .. hit.kind
			end)
		end
		function M:Take()
			local hits, meets = self.hits, self.meets
			self.hits, self.meets = {}, {}
			return hits, meets
		end
	]],
}

local function boot(patch)
	local server = Env.Server({ files = RECORDER, modules = { "players", "organism", "damage", "armor" },
		patch = patch })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local organism = NC.Modules:Instance("organism")
	organism.Random = function() return 0.5 end
	return server, NC.Modules:Instance("armor"), organism, NC.Modules:Instance("players"),
		NC.Modules:Instance("recorder")
end

local function deploy(server, players, name, pos, yaw)
	local ply = Env.Bot(server, { name = name })
	server:Advance(0.1)
	players:Deploy(ply)
	ply:SetPos(pos or Vector(0, 0, 0))
	ply:SetEyeAngles(Angle(0, yaw or 0, 0))
	return ply
end

local function duel(server, players)
	return deploy(server, players, "Bob", Vector(0, 0, 0), 0), deploy(server, players, "Al", Vector(200, 0, 0), 180)
end

-- A melee hit of `kind` (DMG_*) from `attacker` at a bone of `victim`, with its trace.
local function strike(attacker, victim, bone, dtype, damage)
	return Env.Shoot(attacker, victim, { bone = bone, type = dtype, damage = damage, ammo = "none", force = 100 })
end

local function has(list, item)
	for _, value in ipairs(list) do
		if value == item then
			return true
		end
	end
	return false
end

describe("armor", function()
	it("stops a pistol round with a vest: only the blow behind it hurts, and the vest wears", function()
		local server, armor, organism, players, recorder = boot()
		local client, gordon = Env.Join(server, { name = "Gordon" })
		gordon:SetPos(Vector(0, 0, 0))
		players:Deploy(gordon)
		gordon:SetPos(Vector(0, 0, 0))
		gordon:SetEyeAngles(Angle(0, 0, 0))
		local shooter = deploy(server, players, "Al", Vector(200, 0, 0), 180)
		expect(armor:Equip(gordon, "vest")):toBe(true)
		expect({ armor:Equip(gordon, "bogus") }):toEqual({ false, "unknown" })
		Env.Shoot(shooter, gordon, { bone = "Spine2", ammo = "Pistol" })
		local hits, meets = recorder:Take()
		expect(meets):toEqual({ "vest stopped blunt" })
		local hit = hits[1]
		expect(hit.kind):toBe("blunt")
		expect(hit.armor):toBe("vest")
		expect(hit.stopped):toBe(true)
		expect(hit.energy > 35 and hit.energy < 45):toBe(true)
		expect(hit.absorbed > 450):toBe(true)
		expect(has(hit.report.structures, "lung_r")):toBe(false)
		expect(organism:State(gordon).leak.r):toBe(0)
		local worn = armor:Worn(gordon)
		expect(#worn):toBe(1)
		expect(worn[1].condition > 0.9 and worn[1].condition < 0.97):toBe(true)

		client.time = server.time
		server:Advance(0.5)
		Env.Flush(server, client)
		local mine = client:Get("NC").Modules:Instance("armor"):Worn()
		expect(mine[1].id):toBe("vest")
		expect(mine[1].condition):toBeCloseTo(worn[1].condition, 0.01)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("lets a rifle round through a soft vest; plates stop it until they wear out", function()
		local server, armor, _, players, recorder = boot()
		local victim, shooter = duel(server, players)
		armor:Equip(victim, "vest")
		Env.Shoot(shooter, victim, { ammo = "AR2" })
		local hits, meets = recorder:Take()
		expect(meets):toEqual({ "vest through bullet" })
		expect(hits[1].kind):toBe("bullet")
		expect(hits[1].energy < 600 and hits[1].absorbed > 1100):toBe(true)

		armor:Equip(victim, "plates")
		expect(#armor:Worn(victim)):toBe(2)
		expect(armor:Worn(victim)[1].id):toBe("plates")
		local through = 0
		for i = 1, 6 do
			Env.Shoot(shooter, victim, { ammo = "AR2" })
			local _, seen = recorder:Take()
			if i == 1 then
				expect(seen):toEqual({ "plates stopped blunt" })
			end
			if seen[1] == "plates through bullet" then
				through = through + 1
			end
		end
		expect(through >= 1):toBe(true)
		expect(armor:Worn(victim)[1].condition < 0.3):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("covers only its regions and sides, and the share of them", function()
		local server, armor, organism, players, recorder = boot()
		local victim = deploy(server, players, "Bob", Vector(0, 0, 0), 0)
		local side = deploy(server, players, "Side", Vector(0, 200, 0), -90)
		local front = deploy(server, players, "Front", Vector(200, 0, 0), 180)
		armor:Equip(victim, "plates")
		armor:Equip(victim, "helmet")
		Env.Shoot(side, victim, { ammo = "Pistol" }) -- from the left: the arm is in the way
		local hits, meets = recorder:Take()
		expect(hits[1].region):toBe("arm_l")
		expect(meets):toEqual({})
		local damage = server:Get("NC").Modules:Instance("damage")
		local function round(region, from)
			return { kind = "bullet", attacker = side, region = region, side = from, energy = 500,
				projectile = { mass = 8, velocity = 360, diameter = 9, penetration = 45 } }
		end
		for _, case in ipairs({ { "chest", "left", {} }, { "chest", "back", { "plates stopped blunt" } },
			{ "abdomen", "front", { "plates stopped blunt" } }, { "pelvis", "front", {} } }) do
			damage:Apply(victim, round(case[1], case[2]))
			_, meets = recorder:Take()
			expect(meets):toEqual(case[3])
		end
		Env.Shoot(front, victim, { bone = "Head1", offset = Vector(0, 0, 3), ammo = "Pistol" })
		hits, meets = recorder:Take()
		expect(hits[1].region):toBe("head")
		expect(meets):toEqual({ "helmet stopped blunt" })
		expect(victim:Alive()):toBe(true)
		organism.Random = function() return 0.95 end -- past the edge of the helmet
		Env.Shoot(front, victim, { bone = "Head1", offset = Vector(0, 0, 3), ammo = "Pistol" })
		hits, meets = recorder:Take()
		expect(meets):toEqual({})
		expect(hits[1].report.fatal):toBe("head")
		expect(server:Errors()):toEqual({})
	end)

	it("stops blades and spreads blows", function()
		local server, armor, _, players, recorder = boot()
		local victim = deploy(server, players, "Bob", Vector(0, 0, 0), 0)
		local attacker = deploy(server, players, "Al", Vector(40, 0, 0), 180)
		armor:Equip(victim, "vest_light")
		strike(attacker, victim, "Spine2", DMG.SLASH, 20)
		local hits, meets = recorder:Take()
		expect(meets):toEqual({ "vest_light stopped blunt" })
		expect(hits[1].kind):toBe("blunt")
		local damage = server:Get("NC").Modules:Instance("damage")
		local hit = { kind = "stab", attacker = attacker, amount = 20, region = "chest", side = "front" }
		damage:Apply(victim, hit)
		expect(hit.kind):toBe("stab")
		expect(hit.depth):toBeCloseTo(4.8, 1e-9)
		armor:Equip(victim, "vest")
		hit = { kind = "stab", attacker = attacker, amount = 20 } -- no point: the front of the chest
		damage:Apply(victim, hit)
		expect(hit.kind):toBe("blunt")
		strike(attacker, victim, "Spine2", DMG.CLUB, 20)
		hits = recorder:Take()
		local blow = hits[#hits]
		expect(blow.kind):toBe("blunt")
		expect(blow.amount):toBeCloseTo(14, 1e-9)
		expect(server:Errors()):toEqual({})
	end)

	it("meets the fragments of a blast one by one", function()
		local server, armor, organism, players, recorder = boot()
		local seed = 20240601
		local function sequence() -- the same fragments for both
			seed = 20240601
			organism.Random = function()
				seed = seed * 16807 % 2147483647
				return seed / 2147483647
			end
		end
		local bare = deploy(server, players, "Bare", Vector(0, 0, 0), 0)
		local armored = deploy(server, players, "Armored", Vector(0, 300, 0), 0)
		for _, id in ipairs({ "plates", "vest", "helmet" }) do
			armor:Equip(armored, id)
		end
		local function blast(ply)
			local pos = ply:GetPos() + Vector(150, 0, 30)
			Env.Hurt(ply, { type = DMG.BLAST, damage = 120, pos = pos, force = Vector(-8000, 0, 0) })
		end
		sequence()
		blast(bare)
		local _, bareMeets = recorder:Take()
		sequence()
		blast(armored)
		local _, meets = recorder:Take()
		expect(#bareMeets):toBe(0)
		expect(#meets >= 1):toBe(true)
		local external = function(ply)
			local n = 0
			for _, w in ipairs(organism:Wounds(ply)) do
				if w.cavity == "external" and w.kind == "fragment" then
					n = n + 1
				end
			end
			return n
		end
		expect(external(armored) < external(bare)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("comes off at every loadout and at death, and works from the console", function()
		local server, armor, _, players = boot()
		local ply = deploy(server, players, "Bob")
		armor:Equip(ply, "vest")
		armor:Equip(ply, "vest_light")
		expect(#armor:Worn(ply)):toBe(1)
		players:Deploy(ply)
		expect(#armor:Worn(ply)):toBe(0)
		armor:Equip(ply, "helmet")
		expect(armor:Unequip(ply, "helmet")):toBe(true)
		expect(armor:Unequip(ply, "helmet")):toBe(false)
		armor:Equip(ply, "helmet")
		Env.Kill(ply)
		expect(#armor:Worn(ply)):toBe(0)
		expect({ armor:Equip(ply, "vest") }):toEqual({ false, "dead" })
		players:Deploy(ply)
		server:Command("nc_armor", nil, { "Bob", "plates" })
		expect(server:Lines("plates")[1]):toContain("class 5 hard, condition 100%")
		server:Command("nc_armor", nil, { "Bob", "-plates" })
		expect(server:Lines("nc_armor: Bob wears no armor")[1]):toBeTruthy()
		server:Command("nc_armor", nil, { "Bob", "cardboard" })
		expect(server:Lines("nc_armor: cardboard: unknown; kinds: helmet, plates, plates_heavy, vest, vest_light")[1])
			:toBeTruthy()
		expect(server:Errors()):toEqual({})
	end)

	it("dresses the players of Team Deathmatch by the parameter armor without a kit", function()
		local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.rounds = { params = { tdm = { armor = { "vest", "helmet", "cardboard" }, kit = "" } } }
			return cfg
		end } })
		server:Boot()
		server:Call("InitPostEntity")
		local NC = server:Get("NC")
		local armor = NC.Modules:Instance("armor")
		local a, b = Env.Bot(server, { name = "A" }), Env.Bot(server, { name = "B" })
		server:Advance(1)
		expect(NC.Modules:Instance("rounds"):Phase()):toBe("preparing")
		local worn = armor:Worn(a)
		expect(#worn):toBe(2)
		expect(worn[1].id .. " " .. worn[2].id):toBe("helmet vest")
		expect(#armor:Worn(b)):toBe(2)
		local warnings = server:Lines("unknown kind of armor 'cardboard'")
		expect(#warnings):toBe(1)
		-- The weapons of the parameter loadout, the last one in the hands, magazines in reserve.
		expect(a:WeaponClasses()):toEqual({ "nc_hands", "weapon_crowbar", "weapon_pistol", "weapon_smg1" })
		expect(a:GetAmmoCount(3)):toBe(54)
		expect(a:GetAmmoCount(4)):toBe(135)
		expect(a.selected):toBe("weapon_smg1")
		expect(server:Errors()):toEqual({})
	end)
end)
