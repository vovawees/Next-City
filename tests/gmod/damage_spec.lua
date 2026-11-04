-- Damage module: the engine damage of players becomes hits on the body; pellets, ammo,
-- distance, kinds of damage, rules, falls, stages and the console, with the real
-- gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local DMG = World.DMG

-- Records the hits; can block bullets, protect players and choose the kind of injury.
local RECORDER = {
	[MODULES .. "recorder/module.lua"] = "return { id = 'recorder', files = { sv = { 'sv_recorder.lua' } } }",
	[MODULES .. "recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.hits = {}
		function M:Start(ctx)
			ctx:On("damage.hit", function(ply, hit) self.hits[#self.hits + 1] = hit end)
			ctx:On("gm.ScalePlayerDamage", function() if self.blockBullets then return true end end)
			ctx:On("gm.PlayerShouldTakeDamage", function() if self.protect then return false end end)
			ctx:On("damage.kind", function() return self.kind end)
		end
		function M:Take()
			local hits = self.hits
			self.hits = {}
			return hits
		end
	]],
}

local function boot(settings)
	local server = Env.Server({ files = RECORDER, modules = { "players", "organism", "damage" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.damage = settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local organism = NC.Modules:Instance("organism")
	organism.Random = function() return 0.5 end
	return server, NC.Modules:Instance("damage"), organism, NC.Modules:Instance("players"),
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

-- Bob at the origin facing Al 200 units away.
local function duel(server, players, distance)
	return deploy(server, players, "Bob", Vector(0, 0, 0), 0),
		deploy(server, players, "Al", Vector(distance or 200, 0, 0), 180)
end

describe("damage", function()
	it("keeps the health of the engine and wounds the body with a pistol round instead", function()
		local server, _, organism, players, recorder = boot()
		local victim, shooter = duel(server, players)
		Env.Shoot(shooter, victim, { bone = "Spine2", ammo = "Pistol" })
		expect(victim:Health()):toBe(100)
		expect(#victim.damage):toBe(0)
		local hits = recorder:Take()
		expect(#hits):toBe(1)
		local hit = hits[1]
		expect(hit.kind):toBe("bullet")
		expect(hit.ammo):toBe("Pistol")
		expect(hit.attacker):toBe(shooter)
		expect(hit.region):toBe("chest")
		expect(hit.side):toBe("front")
		expect(hit.segment):toBe("torso")
		expect(hit.distance > 4.5 and hit.distance < 5.5):toBe(true)
		expect(hit.energy > 500 and hit.energy < 518.4):toBe(true)
		expect(hit.pellet .. "/" .. hit.pellets):toBe("1/1")
		expect(hit.report.wounds >= 1):toBe(true)
		expect(#organism:Wounds(victim)):toBe(hit.report.wounds)
		expect(#victim.viewPunches):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("gives every pellet of a shell its own hit and keeps no pellet for later", function()
		local server, _, _, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local pellets = { { bone = "Spine2" }, { bone = "Spine4" }, { bone = "L_UpperArm" },
			{ bone = "Spine2", offset = Vector(0, 3, 0) }, { bone = "Pelvis" } }
		Env.Shoot(shooter, victim, { ammo = "Buckshot", damage = 8, type = DMG.BULLET + DMG.BUCKSHOT,
			pellets = pellets })
		local hits = recorder:Take()
		expect(#hits):toBe(5)
		for i, hit in ipairs(hits) do
			expect(hit.pellet .. "/" .. hit.pellets .. " " .. hit.ammo):toBe(i .. "/5 Buckshot")
			expect(hit.energy < 280):toBe(true)
		end
		expect(hits[3].segment):toBe("upperarm_l")
		expect(#victim.damage):toBe(0)

		-- A blocked bullet leaves nothing behind for the next one of the tick.
		recorder.blockBullets = true
		Env.Shoot(shooter, victim)
		expect(#recorder:Take()):toBe(0)
		recorder.blockBullets = false
		Env.Shoot(shooter, victim)
		expect(#recorder:Take()):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("lets the damage of a kill through and takes nothing in god mode, from drowning or when the rules say no",
		function()
			local server, _, organism, players, recorder = boot()
			local victim, shooter = duel(server, players)
			Env.Hurt(victim, { type = DMG.DROWN, damage = 10 })
			victim:GodEnable()
			Env.Shoot(shooter, victim)
			victim:GodDisable()
			recorder.protect = true
			Env.Shoot(shooter, victim)
			Env.Fall(victim, 900)
			recorder.protect = false
			Env.Hurt(victim, { type = DMG.SLASH, damage = 0, attacker = shooter })
			expect(#recorder:Take()):toBe(0)
			expect(#organism:Wounds(victim)):toBe(0)
			expect(victim:Health()):toBe(100)
			players:Kill(victim, { attacker = shooter })
			expect(victim:Alive()):toBe(false)
			expect(#victim.damage):toBe(1)
			expect(#recorder:Take()):toBe(0)
			Env.Shoot(shooter, victim)
			expect(#recorder:Take()):toBe(0)
			expect(server:Errors()):toEqual({})
		end)

	it("turns the damage types of the engine into kinds of injury and asks modules first", function()
		local server, _, _, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local cases = {
			{ DMG.SLASH, "slash" }, { DMG.CLUB, "blunt" }, { DMG.BURN, "burn" }, { DMG.SLOWBURN, "burn" },
			{ DMG.BLAST, "blast" }, { DMG.CRUSH, "crush" }, { DMG.VEHICLE + DMG.CRUSH, "vehicle" },
			{ DMG.SHOCK, "shock" }, { DMG.SHOCK + DMG.CLUB, "stun" }, { DMG.POISON, "poison" },
			{ DMG.NERVEGAS, "poison" }, { DMG.ACID, "poison" }, { DMG.GENERIC, "generic" },
			{ DMG.SONIC, "blunt" }, { DMG.FALL, "fall" },
		}
		local kinds, expected = {}, {}
		for i, case in ipairs(cases) do
			Env.Hurt(victim, { type = case[1], damage = 3, attacker = shooter })
			local hits = recorder:Take()
			kinds[i] = #hits == 1 and hits[1].kind or tostring(#hits) .. " hits"
			expected[i] = case[2]
			if case[1] == DMG.NERVEGAS then
				expect(hits[1].toxin):toBe(1.5)
			end
		end
		expect(kinds):toEqual(expected)
		victim.pushes = {}
		Env.Hurt(victim, { type = DMG.BLAST, damage = 20, pos = Vector(-100, 0, 30), force = Vector(5000, 0, 0) })
		expect(#victim.pushes):toBe(1)
		expect(victim.pushes[1].x > 0 and victim.pushes[1].z > 0):toBe(true)
		expect(recorder:Take()[1].kind):toBe("blast")

		recorder.kind = "stab"
		Env.Hurt(victim, { type = DMG.SLASH, damage = 5, attacker = shooter })
		expect(recorder:Take()[1].kind):toBe("stab")
		recorder.kind = false
		Env.Hurt(victim, { type = DMG.SLASH, damage = 5, attacker = shooter })
		expect(#recorder:Take()):toBe(0)
		recorder.kind = nil
		Env.Hurt(victim, { type = DMG.DISSOLVE, damage = 5, attacker = shooter })
		expect(recorder:Take()[1].report.fatal):toBe("dissolve")
		server:Advance(0.1)
		expect(victim:Alive()):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("finds the point of a melee hit from its trace", function()
		local server, _, _, players, recorder = boot()
		local victim, shooter = duel(server, players, 40)
		Env.Shoot(shooter, victim, { bone = "L_Forearm", offset = Vector(1, 0, -5), type = DMG.CLUB, damage = 25,
			ammo = "none" })
		local hit = recorder:Take()[1]
		expect(hit.kind):toBe("blunt")
		expect(hit.segment):toBe("forearm_l")
		expect(hit.region):toBe("arm_l")
		expect(server:Errors()):toEqual({})
	end)

	it("takes the energy of a bullet from its ammo, the distance and the settings", function()
		local server, damage, _, players, recorder = boot({ scale = 2 })
		local victim = deploy(server, players, "Bob", Vector(0, 0, 0), 0)
		local near = deploy(server, players, "Near", Vector(200, 0, 0), 180)
		local far = deploy(server, players, "Far", Vector(4000, 50, 0), 180)
		local function energy(shooter, ammo, amount)
			Env.Shoot(shooter, victim, { ammo = ammo, damage = amount })
			return recorder:Take()[1].energy
		end
		local close = energy(near, "Pistol")
		expect(close > 1000 and close < 1037):toBe(true)
		expect(energy(far, "Pistol") < close * 0.75):toBe(true)
		expect(energy(near, "357") > close):toBe(true)
		local unknown = energy(near, "Bogus", 20)
		expect(unknown > 970 and unknown < 1000):toBe(true) -- 20 damage x 25 J x 2, a little slower after 5 m
		damage:RegisterAmmo("Pistol", { mass = 16, velocity = 360, diameter = 9, penetration = 45, range = 540 })
		expect(energy(near, "Pistol")):toBeCloseTo(close * 2, 1e-6)
		expect(function() damage:RegisterAmmo("Broken", { mass = 1 }) end):toFail("velocity of 'Broken'")
		expect(damage:Ammo("Broken")):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("injures landings by their speed instead of the fall damage of the engine", function()
		local server, _, organism, players, recorder = boot()
		local ply = deploy(server, players, "Bob")
		local swimmer = deploy(server, players, "Swimmer", Vector(300, 0, 0))
		Env.Fall(ply, 250)
		Env.Fall(swimmer, 900, true)
		expect(#recorder:Take()):toBe(0)
		Env.Fall(ply, 700)
		local hits = recorder:Take()
		expect(#hits):toBe(1)
		expect(hits[1].kind):toBe("fall")
		expect(hits[1].speed):toBe(700)
		expect(#ply.damage):toBe(0)
		expect(#organism:State(ply).fractureList > 0):toBe(true)
		expect(organism:Capabilities(ply).canSprint):toBe(false)
		expect(#organism:Wounds(swimmer)):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("runs hits through ordered stages that modules add, replace and remove", function()
		local server, damage, organism, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local seen, stop = {}, false
		damage:AddStage("probe", 250, function(ply, hit)
			seen[#seen + 1] = ply:Nick() .. " " .. hit.kind .. " " .. tostring(hit.region)
			if stop then
				return false
			end
		end)
		expect(damage:Stages()):toEqual({ "localize", "probe", "wound", "impulse", "notify" })
		Env.Shoot(shooter, victim)
		expect(seen):toEqual({ "Bob bullet chest" })
		stop = true
		Env.Shoot(shooter, victim)
		expect(#recorder:Take()):toBe(1)
		expect(damage:RemoveStage("probe")):toBe(true)
		expect(damage:RemoveStage("probe")):toBe(false)

		local wounds = #organism:Wounds(victim)
		damage:AddStage("wound", 300, function(_, hit) hit.report = { wounds = 0, bleeding = 0, fractures = 0 } end)
		expect(damage:Stages()):toEqual({ "localize", "wound", "impulse", "notify" })
		Env.Shoot(shooter, victim)
		expect(#organism:Wounds(victim)):toBe(wounds)
		local report = damage:Apply(victim, { kind = "slash", amount = 10 })
		expect(report.wounds):toBe(0)
		expect(#recorder:Take()):toBe(2)
		expect(function() damage:AddStage("bad", "late", print) end):toFail("AddStage")
		expect(server:Errors()):toEqual({})
	end)

	it("inflicts hits of weapons the way engine damage goes: rules, god mode and dead bodies say no", function()
		local server, damage, organism, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local chest = victim:GetBonePosition(victim:LookupBone("ValveBiped.Bip01_Spine2"))
		local function stab()
			return damage:Inflict(victim, { kind = "stab", attacker = shooter, inflictor = shooter, amount = 20,
				pos = chest + Vector(8, 0, 0), dir = Vector(-1, 0, 0), depth = 6 })
		end
		local report = stab()
		expect(report ~= nil and report.wounds >= 1):toBe(true)
		local hits = recorder:Take()
		expect(#hits):toBe(1)
		expect(hits[1].region):toBe("chest")
		recorder.protect = true
		expect(stab()):toBeNil()
		recorder.protect = false
		victim:GodEnable()
		expect(stab()):toBeNil()
		victim:GodDisable()
		-- Without an attacker the world asks; a failing stage is logged.
		expect(damage:Inflict(victim, { kind = "blunt", amount = 5 }) ~= nil):toBe(true)
		damage:AddStage("broken", 150, function() error("stage is broken") end)
		expect(stab()):toBeNil()
		expect(server:Errors()[1]):toContain("stage is broken")
		damage:RemoveStage("broken")
		organism:State(victim).dead = true
		expect(stab()):toBeNil()
		expect(#recorder:Take()):toBe(1)
	end)

	it("blocks the damage even when a stage fails", function()
		local server, damage, _, players = boot()
		local victim, shooter = duel(server, players)
		damage:AddStage("broken", 150, function() error("stage is broken") end)
		Env.Shoot(shooter, victim)
		expect(victim:Health()):toBe(100)
		local errors = server:Errors()
		expect(#errors):toBe(1)
		expect(errors[1]):toContain("stage is broken")
	end)

	it("hurts the player whose body a ragdoll carries and lets the engine push the ragdoll", function()
		local server, _, organism, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local rag = server:Get("ents").Create("prop_ragdoll")
		rag:SetModel(victim:GetModel())
		rag:SetPos(Vector(-60, 0, 0))
		rag:Spawn()
		World.LayRagdoll(rag) -- on its back, the head towards -x
		local chest = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_Spine2"))
		local above = Vector(chest.x, chest.y, 80)
		-- A ragdoll that carries nothing is the engine's.
		Env.Shoot(shooter, rag, { from = above })
		expect(#recorder:Take()):toBe(0)
		expect(#rag.damage):toBe(1)

		organism:SetCarrier(victim, rag)
		Env.Shoot(shooter, rag, { from = above })
		local hits = recorder:Take()
		expect(#hits):toBe(1)
		expect(hits[1].kind .. " " .. hits[1].region .. " " .. hits[1].side):toBe("bullet chest front")
		expect(hits[1].attacker):toBe(shooter)
		expect(hits[1].hitgroup):toBe(0)
		expect(hits[1].pellet .. "/" .. hits[1].pellets):toBe("1/1")
		expect(hits[1].report.wounds >= 1):toBe(true)
		-- The engine took the damage too: it pushes the bone that was hit.
		expect(#rag.damage):toBe(2)
		expect(#rag:GetPhysicsObjectNum(1).forces):toBe(2)
		expect(victim:Health()):toBe(100)
		expect(#victim.damage):toBe(0)

		-- The pellets of a shell come added up: their count from the most damage of one.
		Env.Shoot(shooter, rag, { from = above, ammo = "Buckshot", damage = 8, type = DMG.BULLET + DMG.BUCKSHOT,
			pellets = { { bone = "Pelvis" }, { bone = "L_UpperArm" }, { bone = "Spine4" }, { bone = "Spine2" } } })
		hits = recorder:Take()
		expect(#hits):toBe(4)
		for i, hit in ipairs(hits) do
			expect(hit.pellet .. "/" .. hit.pellets .. " " .. hit.ammo .. " " .. hit.amount):toBe(i .. "/4 Buckshot 8")
			expect(hit.region):toBe("chest")
		end

		-- A blast finds the hidden player as well: only the body takes it, and the engine
		-- pushes the body instead of the player.
		local blast = { type = DMG.BLAST, damage = 40, attacker = shooter, pos = Vector(-60, 120, 0) }
		Env.Hurt(victim, blast)
		expect(#recorder:Take()):toBe(0)
		Env.Hurt(rag, blast)
		hits = recorder:Take()
		expect(#hits):toBe(1)
		expect(hits[1].kind):toBe("blast")
		expect(hits[1].dir.y < -0.9):toBe(true)
		Env.Hurt(victim, { type = DMG.CLUB, damage = 20, attacker = shooter })
		expect(recorder:Take()[1].kind):toBe("blunt")
		expect(#victim.pushes):toBe(0)

		-- Carried no more: the ragdoll is the engine's again.
		organism:SetCarrier(victim, nil)
		Env.Shoot(shooter, rag, { from = above })
		expect(#recorder:Take()):toBe(0)
		expect(#rag.damage):toBe(5)
		expect(server:Errors()):toEqual({})
	end)

	it("lists the latest hits with nc_damage", function()
		local server, _, _, players = boot({ history = 3 })
		local victim, shooter = duel(server, players)
		server:Command("nc_damage")
		expect(server:Lines("nc_damage: no hits yet")[1]):toBeTruthy()
		for _ = 1, 4 do
			Env.Shoot(shooter, victim)
		end
		Env.Hurt(victim, { type = DMG.SLASH, damage = 5, attacker = shooter })
		server:Command("nc_damage", nil, { "2" })
		expect(server:Lines("nc_damage: the latest 2 hits")[1]):toBeTruthy()
		expect(#server:Lines("Bob <- Al: bullet Pistol")):toBe(1)
		expect(#server:Lines("Bob <- Al: slash")):toBe(1)
		server:Command("nc_damage")
		expect(server:Lines("nc_damage: the latest 3 hits")[1]):toBeTruthy()
		expect(server:Errors()):toEqual({})
	end)
end)
