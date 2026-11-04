-- Ballistics module: projectiles of the rounds of a content package fly with drag and
-- gravity, hit bodies through the damage pipeline, go through materials or glance off
-- them, slow down in water, push fallen bodies, damage props and creatures, catch up with
-- the latency of their shooter and keep their limits, with the real gamemode files in
-- emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

local UNIT_M = 0.0254
local TICK = 1 / 66

-- A content package with rounds, and a recorder of hits and impacts that can stop
-- projectiles in a plate (as armor does).
local FILES = {
	["nextcity/modules/arsenal/module.lua"] = "return { id = 'arsenal', requires = { 'ammo' },"
		.. " files = { sh = { 'sh_arsenal.lua' } } }",
	["nextcity/modules/arsenal/sh_arsenal.lua"] = [[
		local M = NC.Module("arsenal")
		function M:Init(ctx)
			local ammo = ctx:Require("ammo")
			ammo:Register("9x19_fmj", { caliber = "9x19", mass = 8, velocity = 360, diameter = 9, penetration = 60,
				range = 540 })
			ammo:Register("545_7n6", { caliber = "5.45x39", mass = 3.4, velocity = 880, diameter = 5.6,
				penetration = 70, range = 900, ap = 1.3 })
			ammo:Register("12g_buck", { caliber = "12/70", mass = 3.5, velocity = 400, diameter = 8.4,
				penetration = 30, range = 100, pellets = 9, spread = 1.5 })
		end
	]],
	["nextcity/modules/recorder/module.lua"] = "return { id = 'recorder', requires = { 'damage' },"
		.. " files = { sv = { 'sv_recorder.lua' } } }",
	["nextcity/modules/recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.hits, M.impacts = {}, {}
		function M:Init(ctx)
			ctx:Require("damage"):AddStage("plate", 250, function(ply, hit)
				if ply.plate and hit.kind == "bullet" then
					hit.kind, hit.energy, hit.projectile, hit.stopped = "blunt", hit.energy * 0.1, nil, true
				end
			end)
		end
		function M:Start(ctx)
			ctx:On("damage.hit", function(ply, hit)
				hit.victim = ply
				self.hits[#self.hits + 1] = hit
			end)
			ctx:On("ballistics.impact", function(owner, ent, pos, dir, energy, outcome)
				self.impacts[#self.impacts + 1] = { owner = owner, ent = ent, pos = pos, dir = dir, energy = energy,
					outcome = outcome }
			end)
		end
		function M:Take(what)
			local list = self[what]
			self[what] = {}
			return list
		end
		function M:Outcomes()
			local out = {}
			for _, impact in ipairs(self:Take("impacts")) do
				out[#out + 1] = impact.outcome
			end
			return table.concat(out, " ")
		end
	]],
}

local function boot(settings)
	local server = Env.Server({ files = FILES, modules = { "players", "organism", "damage", "ammo", "ballistics" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.ballistics = settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local organism = NC.Modules:Instance("organism")
	organism.Random = function() return 0.5 end
	local ballistics = NC.Modules:Instance("ballistics")
	ballistics.Random = function() return 0.5 end
	return server, ballistics, NC.Modules:Instance("players"), NC.Modules:Instance("recorder"),
		NC.Modules:Instance("ammo"), organism
end

local function deploy(server, players, name, pos, yaw)
	local ply = Env.Bot(server, { name = name })
	server:Advance(0.1)
	players:Deploy(ply)
	ply:SetPos(pos)
	ply:SetEyeAngles(Angle(0, yaw or 0, 0))
	return ply
end

local function fly(server, seconds)
	for _ = 1, math.floor(seconds / TICK + 0.5) do
		server:Advance(TICK)
	end
end

local function bone(ent, name)
	return ent:GetBonePosition(ent:LookupBone("ValveBiped.Bip01_" .. name))
end

local function near(a, b, tolerance)
	return math.abs(a - b) <= (tolerance or 1e-6) * math.max(1, math.abs(b))
end

-- The speed of projectile i, m/s.
local function speed(ballistics, i)
	return Vector(ballistics.vx[i], ballistics.vy[i], ballistics.vz[i]):Length() * UNIT_M
end

local function count(list, name)
	local n = 0
	for _, entry in ipairs(list) do
		if entry.name == name then
			n = n + 1
		end
	end
	return n
end

describe("ballistics", function()
	it("flies a round with the drag of its range and real gravity", function()
		local server, ballistics, _, _, ammo = boot({ gravity = 0 })
		server:Advance(TICK)
		local start = server.time
		expect(ballistics:Fire(nil, Vector(0, 0, 1000), Vector(1, 0, 0), "9x19_fmj")):toBe(1)
		fly(server, 0.3)
		-- Quadratic drag: x(t) = ln(1 + k·v0·t) / k, k = 1 / range; the velocity of the round there.
		local distance = 540 * math.log(1 + 360 * (server.time - start) / 540)
		expect(near(ballistics.dist[1], distance)):toBe(true)
		expect(near(ballistics.x[1] * UNIT_M, distance)):toBe(true)
		local velocity = ammo:At("9x19_fmj", distance)
		expect(near(speed(ballistics, 1), velocity)):toBe(true)
		expect(ballistics.z[1]):toBe(1000)
		-- Real gravity: it drops a little less than in a vacuum (the drag slows the fall too).
		ballistics:Clear()
		ballistics.ctx.config.gravity = 1
		ballistics:Fire(nil, Vector(0, 0, 1000), Vector(1, 0, 0), "9x19_fmj")
		fly(server, 0.5)
		local drop = (1000 - ballistics.z[1]) * UNIT_M
		local vacuum = 0.5 * 9.81 * 0.5 * 0.5
		expect(drop > 0.8 * vacuum and drop < vacuum):toBe(true)
		expect(ballistics.vz[1] < 0):toBe(true)
		-- The longest flight.
		fly(server, 3.4)
		expect(ballistics:Count()):toBe(1)
		fly(server, 0.2)
		expect(ballistics:Count()):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("hits players through the damage pipeline and flies on out of them", function()
		local server, ballistics, players, recorder, ammo = boot({ gravity = 0 })
		local G = server.G
		local shooter = deploy(server, players, "Al", Vector(0, 0, 0), 0)
		local victim = deploy(server, players, "Bob", Vector(1000, 0, 0), 180)
		local behind = deploy(server, players, "Cid", Vector(1100, 0, 0), 180)
		Env.Geometry(server)
		local origin = shooter:GetShootPos()
		ballistics:Fire(shooter, origin, bone(victim, "Spine2") - origin, "9x19_fmj")
		fly(server, 0.2)
		local hits = recorder:Take("hits")
		expect(#hits >= 1):toBe(true)
		local hit = hits[1]
		expect(hit.victim):toBe(victim)
		expect(hit.kind .. " " .. hit.ammo .. " " .. hit.region .. " " .. hit.side):toBe("bullet 9x19_fmj chest front")
		expect(hit.attacker == shooter and hit.inflictor == shooter):toBe(true)
		expect(hit.hitgroup):toBe(G.HITGROUP_CHEST)
		expect(hit.pellet .. "/" .. hit.pellets):toBe("1/1")
		expect(near(hit.distance, hit.pos:Distance(origin) * UNIT_M)):toBe(true)
		local _, energy = ammo:At("9x19_fmj", hit.distance)
		expect(near(hit.energy, energy)):toBe(true)
		expect(hit.projectile.velocity < 360 and hit.projectile.penetration < 60):toBe(true)
		expect(hit.report.wounds >= 1):toBe(true)
		expect(victim:Health()):toBe(100)
		-- A rifle round goes through the body into the one behind it, with what the first left.
		recorder:Take("impacts")
		ballistics:Fire(shooter, origin, bone(victim, "Spine2") - origin, "545_7n6")
		fly(server, 0.1)
		hits = recorder:Take("hits")
		expect(#hits):toBe(2)
		expect(hits[1].victim == victim and hits[2].victim == behind):toBe(true)
		expect(hits[2].energy < hits[1].energy - hits[1].report.energy + 1e-6):toBe(true)
		expect(hits[2].energy > 0):toBe(true)
		expect(recorder:Outcomes()):toBe("body body")
		expect(#server.decals >= 2):toBe(true)
		expect(count(server.fx, "BloodImpact") >= 2):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("stops in what the pipeline stopped and passes players the rules keep out of harm", function()
		local server, ballistics, players, recorder, ammo = boot({ gravity = 0 })
		local shooter = deploy(server, players, "Al", Vector(0, 0, 0), 0)
		local victim = deploy(server, players, "Bob", Vector(1000, 0, 0), 180)
		local behind = deploy(server, players, "Cid", Vector(1100, 0, 0), 180)
		Env.Geometry(server)
		local origin = shooter:GetShootPos()
		victim.plate = true
		ballistics:Fire(shooter, origin, bone(victim, "Spine2") - origin, "545_7n6")
		fly(server, 0.1)
		local hits = recorder:Take("hits")
		expect(#hits):toBe(1)
		expect(hits[1].kind .. " " .. tostring(hits[1].stopped)):toBe("blunt true")
		expect(ballistics:Count()):toBe(0)
		-- God mode: as if he was not there.
		victim.plate = nil
		victim:GodEnable()
		ballistics:Fire(shooter, origin, bone(victim, "Spine2") - origin, "545_7n6")
		fly(server, 0.1)
		hits = recorder:Take("hits")
		expect(#hits):toBe(1)
		expect(hits[1].victim):toBe(behind)
		local _, energy = ammo:At("545_7n6", hits[1].distance)
		expect(near(hits[1].energy, energy)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("goes through thin wood, stops in concrete and the ground and glances off metal", function()
		local server, ballistics, players, recorder = boot({ gravity = 0 })
		local G = server.G
		local shooter = deploy(server, players, "Al", Vector(0, 0, 0), 0)
		local geometry = Env.Geometry(server)
		geometry:Wall(200, 1, G.MAT_WOOD)
		geometry:Wall(400, 16, G.MAT_CONCRETE)
		local origin = shooter:GetShootPos()
		ballistics:Fire(shooter, origin, Vector(1, 0, 0), "9x19_fmj")
		fly(server, 0.1)
		local impacts = recorder:Take("impacts")
		expect(#impacts):toBe(2)
		expect(impacts[1].outcome .. " " .. impacts[2].outcome):toBe("through stop")
		expect(impacts[1].ent):toBe(G.game.GetWorld())
		expect(near(impacts[1].pos.x, 200)):toBe(true)
		-- 2.54 cm of wood takes 50 J a cm of a 9 mm round.
		local left = (impacts[1].energy - 127) * math.exp(-2 * 199 * UNIT_M / 540)
		expect(near(impacts[2].energy, left, 0.01)):toBe(true)
		expect(ballistics:Count()):toBe(0)
		expect(count(server.fx, "Impact")):toBe(3)
		-- The ground of a displacement: nothing goes through, however thin.
		local ground = geometry:Box(Vector(-2000, -1000, -4), Vector(-1000, 1000, 0), { mat = G.MAT_DIRT,
			displacement = true })
		local above = Vector(-1500, 0, 100)
		ballistics:Fire(shooter, above, Vector(0, 0, -1), "9x19_fmj")
		fly(server, 0.1)
		expect(recorder:Outcomes()):toBe("stop")
		ground.displacement = false
		ballistics:Fire(shooter, above, Vector(0, 0, -1), "9x19_fmj")
		fly(server, 0.1)
		expect(recorder:Outcomes()):toBe("through")
		ballistics:Clear()
		-- Metal at a grazing angle: a ricochet, slower and flatter; its shooter is fair game after it.
		geometry:Box(Vector(-1000, -1000, -1010), Vector(0, 1000, -1000), { mat = G.MAT_METAL })
		ballistics:Fire(shooter, Vector(-100, 0, -980), Vector(-400, 0, -20), "9x19_fmj")
		fly(server, 0.05)
		impacts = recorder:Take("impacts")
		expect(#impacts):toBe(1)
		expect(impacts[1].outcome):toBe("ricochet")
		expect(ballistics.rico[1]):toBe(1)
		expect(ballistics.vz[1] > 0 and ballistics.vx[1] < 0):toBe(true)
		local v = math.sqrt(impacts[1].energy * 2 / 0.008)
		expect(speed(ballistics, 1) < 0.75 * v):toBe(true)
		expect(#ballistics.filter[1]):toBe(0)
		-- A steep shot goes into the metal and stops.
		ballistics:Fire(shooter, Vector(-100, 0, -980), Vector(0, 0, -1), "9x19_fmj")
		fly(server, 0.05)
		expect(recorder:Outcomes()):toBe("stop")
		expect(server:Errors()):toEqual({})
	end)

	it("slows down in water and glances off its surface at a low angle", function()
		local server, ballistics, players, recorder = boot({ gravity = 0 })
		local G = server.G
		local shooter = deploy(server, players, "Al", Vector(0, 0, 1000), 0)
		local geometry = Env.Geometry(server)
		geometry:Box(Vector(-1000, -1000, -200), Vector(1000, 1000, 0), { contents = G.CONTENTS_WATER,
			mat = G.MAT_SLOSH })
		geometry:Box(Vector(-1000, -1000, -210), Vector(1000, 1000, -200))
		ballistics:Fire(shooter, Vector(0, 0, 20), Vector(400, 0, -20), "9x19_fmj")
		fly(server, 0.05)
		expect(recorder:Outcomes()):toBe("ricochet")
		expect(ballistics.vz[1] > 0):toBe(true)
		expect(count(server.fx, "gunshotsplash")):toBe(1)
		ballistics:Clear()
		-- Steeper: into the water, where it stops long before the bottom.
		ballistics:Fire(shooter, Vector(0, 0, 100), Vector(1, 0, -1), "9x19_fmj")
		fly(server, 0.02)
		expect(recorder:Outcomes()):toBe("water")
		expect(ballistics:Count()):toBe(1)
		-- Less than a metre into it, most of its speed is gone.
		expect(ballistics.z[1] < 0 and ballistics.z[1] > -40):toBe(true)
		expect(speed(ballistics, 1) < 0.3 * 360):toBe(true)
		fly(server, 0.1)
		expect(ballistics:Count()):toBe(0)
		expect(recorder:Outcomes()):toBe("")
		expect(server:Errors()):toEqual({})
	end)

	it("wounds the player a fallen body carries and pushes the body; a dead body is flesh in the way", function()
		local server, ballistics, players, recorder, _, organism = boot({ gravity = 0 })
		local G = server.G
		local shooter = deploy(server, players, "Al", Vector(500, 0, 0), 0)
		local victim = deploy(server, players, "Bob", Vector(0, 300, 0), 0)
		victim:SetNotSolid(true) -- the player of a fallen body is hidden
		local geometry = Env.Geometry(server)
		geometry:Box(Vector(-1000, -1000, -10), Vector(1000, 1000, 0))
		local rag = G.ents.Create("prop_ragdoll")
		rag:SetModel(victim:GetModel())
		rag:SetPos(Vector(0, 0, 0))
		rag:Spawn()
		World.LayRagdoll(rag)
		organism:SetCarrier(victim, rag)
		local chest = bone(rag, "Spine2")
		local above = Vector(chest.x, chest.y, 200)
		ballistics:Fire(shooter, above, Vector(0, 0, -1), "9x19_fmj")
		fly(server, 0.1)
		local hits = recorder:Take("hits")
		expect(#hits):toBe(1)
		expect(hits[1].victim == victim and hits[1].region == "chest"):toBe(true)
		expect(hits[1].hitgroup):toBe(G.HITGROUP_GENERIC)
		expect(hits[1].report.wounds >= 1):toBe(true)
		local impacts = recorder:Take("impacts")
		expect(impacts[1].outcome .. " " .. tostring(impacts[1].ent == rag)):toBe("body true")
		local pushed = 0
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			for _, force in ipairs(rag:GetPhysicsObjectNum(i).forces) do
				expect(force.z < 0):toBe(true)
				pushed = pushed + 1
			end
		end
		expect(pushed):toBe(1)
		-- Out of harm (dead, or kept out by the rules): 25 cm of flesh, then the ground.
		victim:GodEnable()
		ballistics:Fire(shooter, above, Vector(0, 0, -1), "9x19_fmj")
		fly(server, 0.1)
		expect(#recorder:Take("hits")):toBe(0)
		impacts = recorder:Take("impacts")
		expect(#impacts):toBe(2)
		expect(impacts[1].outcome .. " " .. impacts[2].outcome):toBe("body stop")
		expect(near(impacts[2].energy, impacts[1].energy - 250, 0.01)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("deals engine damage to props and creatures and flies on through them", function()
		local server, ballistics, players, recorder = boot({ gravity = 0 })
		local G = server.G
		local shooter = deploy(server, players, "Al", Vector(0, 0, 0), 0)
		Env.Geometry(server)
		local crate = Env.Spawn(server, { pos = Vector(300, 0, 0) })
		crate.box = { Vector(-1, -50, 0), Vector(1, 50, 100) }
		crate.mat = G.MAT_WOOD
		local npc = Env.Spawn(server, { pos = Vector(600, 0, 0), class = "npc_citizen" })
		npc.npc = true
		npc.box = { Vector(-8, -8, 0), Vector(8, 8, 72) }
		ballistics:Fire(shooter, shooter:GetShootPos(), Vector(1, 0, 0), "9x19_fmj")
		fly(server, 0.1)
		local impacts = recorder:Take("impacts")
		expect(#impacts):toBe(2)
		expect(impacts[1].outcome .. " " .. impacts[2].outcome):toBe("through body")
		expect(impacts[1].ent == crate and impacts[2].ent == npc):toBe(true)
		expect(#crate.damage):toBe(1)
		local dmginfo = crate.damage[1]
		-- What the wood took: 5.08 cm of it, 50 J a cm.
		expect(near(dmginfo:GetDamage(), 254 * 0.04)):toBe(true)
		expect(dmginfo:GetDamageType()):toBe(G.DMG_BULLET)
		expect(dmginfo:GetAttacker()):toBe(shooter)
		expect(dmginfo:GetAmmoType()):toBe(G.game.GetAmmoID("9x19_fmj"))
		expect(dmginfo:GetDamageForce().x > 0):toBe(true)
		-- The creature stops what is left (less than 25 cm of flesh takes) and takes all of it.
		expect(#npc.damage):toBe(1)
		expect(near(npc.damage[1]:GetDamage(), impacts[2].energy * 0.04)):toBe(true)
		expect(ballistics:Count()):toBe(0)
		expect(#recorder:Take("hits")):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("catches up with the latency of its shooter under lag compensation", function()
		local server, ballistics, players, recorder = boot({ gravity = 0 })
		local shooter = deploy(server, players, "Al", Vector(0, 0, 0), 0)
		local victim = deploy(server, players, "Bob", Vector(600, 0, 0), 180)
		Env.Geometry(server)
		local origin = shooter:GetShootPos()
		shooter.ping = 100
		-- Not in a command of his: no lag compensation, the flight starts at the next tick.
		ballistics:Fire(shooter, origin, bone(victim, "Spine2") - origin, "9x19_fmj")
		expect(shooter.lagCompensations == nil and ballistics.dist[1] == 0):toBe(true)
		ballistics:Clear()
		-- In his command, 15 m away: hit at once, where the shooter saw him.
		server.predictionPlayer = shooter
		ballistics:Fire(shooter, origin, bone(victim, "Spine2") - origin, "9x19_fmj")
		expect(#recorder:Take("hits")):toBe(1)
		expect(shooter.lagCompensations):toBe(1)
		expect(shooter.lagCompensation):toBe(false)
		ballistics:Clear()
		-- At most maxCatchUp of the flight.
		shooter.ping = 1000
		ballistics:Fire(shooter, origin, Vector(-1, 0, 0), "9x19_fmj")
		expect(near(ballistics.dist[1], 540 * math.log(1 + 360 * 0.25 / 540))):toBe(true)
		expect(shooter.lagCompensations):toBe(2)
		ballistics:Fire(shooter, origin, Vector(-1, 0, 0), "9x19_fmj", { lagCompensate = false })
		expect(ballistics.dist[2]):toBe(0)
		expect(shooter.lagCompensations):toBe(2)
		expect(server:Errors()):toEqual({})
	end)

	it("fires the pellets of a shell in a cone, launches fragments and keeps its limits", function()
		local server, ballistics, players, recorder = boot({ gravity = 0, maxProjectiles = 12 })
		local shooter = deploy(server, players, "Al", Vector(0, 0, 0), 0)
		local victim = deploy(server, players, "Bob", Vector(300, 0, 0), 180)
		Env.Geometry(server)
		ballistics.Random = math.random
		local origin = shooter:GetShootPos()
		expect(ballistics:Fire(shooter, origin, Vector(0, 1, 0), "12g_buck")):toBe(9)
		local directions = {}
		for i = 1, 9 do
			local dir = Vector(ballistics.vx[i], ballistics.vy[i], ballistics.vz[i]):GetNormalized()
			expect(math.deg(math.acos(math.min(1, dir.y))) <= 1.5 + 1e-9):toBe(true)
			expect(ballistics.pellet[i] .. "/" .. ballistics.pellets[i]):toBe(i .. "/9")
			directions[string.format("%.6f %.6f", dir.x, dir.z)] = true
		end
		local distinct = 0
		for _ in pairs(directions) do
			distinct = distinct + 1
		end
		expect(distinct):toBe(9)
		-- A new one replaces the oldest.
		ballistics:Fire(shooter, origin, Vector(0, 1, 0), "12g_buck")
		expect(ballistics:Count()):toBe(12)
		for i = 1, 12 do
			expect(ballistics.born[i]):toBe(server.time)
		end
		ballistics:Clear()
		expect(ballistics:Count()):toBe(0)
		-- A fragment of nobody's: its own kind, the world attacks.
		ballistics:Launch(nil, Vector(0, 0, 52), Vector(1500 / UNIT_M, 0, 0), { mass = 0.2, diameter = 3,
			penetration = 15, range = 60 })
		fly(server, 0.05)
		local hits = recorder:Take("hits")
		expect(#hits):toBe(1)
		expect(hits[1].victim == victim and hits[1].kind == "fragment" and hits[1].ammo == nil):toBe(true)
		expect(hits[1].attacker):toBe(server.G.game.GetWorld())
		-- A fragment of the shooter's own misses him, unless it may hit its owner.
		local fragment = { mass = 0.2, diameter = 3, penetration = 15, range = 60 }
		local below = victim:GetPos() + Vector(-40, 0, 52)
		ballistics:Launch(victim, below, Vector(1500 / UNIT_M, 0, 0), fragment)
		fly(server, 0.05)
		expect(#recorder:Take("hits")):toBe(0)
		ballistics:Launch(victim, below, Vector(1500 / UNIT_M, 0, 0), fragment, { hitsOwner = true })
		fly(server, 0.05)
		hits = recorder:Take("hits")
		expect(#hits == 1 and hits[1].victim == victim and hits[1].attacker == victim):toBe(true)
		ballistics:Clear()
		local ok, err = pcall(ballistics.Fire, ballistics, shooter, origin, Vector(1, 0, 0), "nope")
		expect(ok):toBe(false)
		expect(tostring(err)):toContain("unknown ammo 'nope'")
		server:Command("nc_ballistics", nil, {})
		expect(#server:Lines("nc_ballistics: 0 in flight (at most 12), 21 fired")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)
end)
