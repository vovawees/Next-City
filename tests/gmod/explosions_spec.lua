-- Explosions module: the blast wave by the scaled distance on bodies through the damage
-- pipeline, behind the world and on the ground, the casing as fragments of ballistics (or
-- the hits expected without it), the engine blast that spares players, the effects, the
-- event and the console, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

local UNIT_M = 0.0254
local TICK = 1 / 66

-- A recorder of hits and explosions.
local FILES = {
	["nextcity/modules/recorder/module.lua"] = "return { id = 'recorder', requires = { 'damage' },"
		.. " files = { sv = { 'sv_recorder.lua' } } }",
	["nextcity/modules/recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.hits, M.explosions = {}, {}
		function M:Start(ctx)
			ctx:On("damage.hit", function(ply, hit)
				hit.victim = ply
				self.hits[#self.hits + 1] = hit
			end)
			ctx:On("explosions.exploded", function(pos, attacker, inflictor, charge)
				self.explosions[#self.explosions + 1] = { pos = pos, attacker = attacker, inflictor = inflictor,
					charge = charge }
			end)
		end
		function M:Take(what)
			local list = self[what]
			self[what] = {}
			return list
		end
	]],
}

-- A server; opts: ballistics (false: without it), settings (of the explosions module).
local function boot(opts)
	opts = opts or {}
	local modules = { "players", "organism", "damage", "explosions" }
	if opts.ballistics ~= false then
		table.insert(modules, 4, "ammo")
		table.insert(modules, 5, "ballistics")
	end
	local server = Env.Server({ files = FILES, modules = modules, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.explosions = opts.settings
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server }
	w.organism = NC.Modules:Instance("organism")
	w.organism.Random = function() return 0.5 end
	w.explosions = NC.Modules:Instance("explosions")
	w.explosions.Random = function() return 0.5 end
	w.players = NC.Modules:Instance("players")
	w.recorder = NC.Modules:Instance("recorder")
	w.ballistics = NC.Modules:Instance("ballistics")
	return w
end

local function deploy(w, name, pos)
	local ply = Env.Bot(w.server, { name = name })
	w.server:Advance(0.1)
	w.players:Deploy(ply)
	ply:SetPos(pos)
	ply:SetEyeAngles(Angle(0, 180, 0))
	return ply
end

local function fly(server, seconds)
	for _ = 1, math.floor(seconds / TICK + 0.5) do
		server:Advance(TICK)
	end
end

local function near(a, b, tolerance)
	return math.abs(a - b) <= (tolerance or 1e-6) * math.max(1, math.abs(b))
end

-- The amount of the blast at `units` from `charge` kg.
local function amount(explosions, units, charge)
	return explosions.Overpressure(units * UNIT_M / charge ^ (1 / 3)) * 0.5
end

-- Hits of the list by victim.
local function byVictim(hits)
	local out = {}
	for _, hit in ipairs(hits) do
		out[hit.victim] = out[hit.victim] or {}
		table.insert(out[hit.victim], hit)
	end
	return out
end

describe("explosions", function()
	it("hits bodies with the wave of the scaled distance, less behind the world, more on the ground", function()
		local w = boot({ ballistics = false })
		local explosions, recorder = w.explosions, w.recorder
		-- Kinney–Graham: about 1 MPa at Z = 1, about 8 kPa at Z = 12.
		expect(near(explosions.Overpressure(1), 1009, 0.01)):toBe(true)
		expect(near(explosions.Overpressure(12), 7.8, 0.02)):toBe(true)
		local a = deploy(w, "Al", Vector(40, 0, 0))
		local b = deploy(w, "Bob", Vector(120, 0, 0))
		local c = deploy(w, "Cid", Vector(240, 0, 0))
		local d = deploy(w, "Dan", Vector(1000, 0, 0))
		local origin = Vector(0, 0, 36)
		local bodies, fragments = explosions:Explode(origin, { charge = 0.2 })
		expect(bodies .. " " .. fragments):toBe("3 0")
		local hits = byVictim(recorder:Take("hits"))
		expect(hits[d]):toBeNil()
		for ply, units in pairs({ [a] = 40, [b] = 120, [c] = 240 }) do
			local hit = hits[ply][1]
			expect(#hits[ply]):toBe(1)
			expect(hit.kind .. " " .. hit.fragments .. " " .. tostring(hit.attacker == w.server.G.game.GetWorld()))
				:toBe("blast 0 true")
			expect(near(hit.amount, amount(explosions, units, 0.2))):toBe(true)
			expect(hit.dir:Distance(Vector(1, 0, 0)) < 1e-6):toBe(true)
		end
		expect(hits[a][1].amount > 100 and hits[c][1].amount < 10):toBe(true)
		expect(hits[a][1].report ~= nil and hits[a][1].report.energy > 0):toBe(true)

		-- Behind a wall a quarter of it bends around.
		local geometry = Env.Geometry(w.server)
		geometry:Wall(80, 10)
		explosions:Explode(origin, { charge = 0.2 })
		hits = byVictim(recorder:Take("hits"))
		expect(near(hits[a][1].amount, amount(explosions, 40, 0.2))):toBe(true)
		expect(near(hits[b][1].amount, amount(explosions, 120, 0.2) * 0.25)):toBe(true)
		-- On the ground the wave reflects: the charge counts 1.8 times.
		local w2 = boot({ ballistics = false })
		local e = deploy(w2, "Eve", Vector(40, 0, 0))
		Env.Geometry(w2.server):Box(Vector(-2000, -2000, -10), Vector(2000, 2000, 0))
		w2.explosions:Explode(Vector(0, 0, 4), { charge = 0.2 })
		local hit = w2.recorder:Take("hits")[1]
		expect(hit.victim):toBe(e)
		expect(near(hit.amount, amount(w2.explosions, Vector(40, 0, 32):Length(), 0.36))):toBe(true)
		expect(w.server:Errors()):toEqual({})
		expect(w2.server:Errors()):toEqual({})
	end)

	it("breaks the casing into fragments that fly every way or in a cone and hit their owner too", function()
		local w = boot()
		local explosions, ballistics, recorder = w.explosions, w.ballistics, w.recorder
		local thrower = deploy(w, "Al", Vector(60, 0, 0))
		Env.Geometry(w.server)
		-- Gurney's speed of 0.2 kg of casing around 0.2 kg of TNT; a gram each.
		expect(near(explosions.FragmentSpeed(0.2, 0.2), 2440 / math.sqrt(1.6))):toBe(true)
		local _, launched = explosions:Explode(Vector(0, 0, 36), { attacker = thrower, charge = 0.2, casing = 0.2 })
		expect(launched):toBe(200)
		expect(ballistics:Count()):toBe(200)
		local sum = Vector(0, 0, 0)
		local up, down = 0, 0
		for i = 1, 200 do
			local v = Vector(ballistics.vx[i], ballistics.vy[i], ballistics.vz[i])
			expect(near(v:Length() * UNIT_M, 2440 / math.sqrt(1.6))):toBe(true)
			expect(ballistics.def[i].mass):toBe(1)
			sum = sum + v:GetNormalized()
			if v.z > 0 then up = up + 1 else down = down + 1 end
		end
		-- Even over the sphere.
		expect(sum:Length() / 200 < 0.02 and up == 100 and down == 100):toBe(true)
		local diameter, range, penetration = explosions.Chunk(1)
		expect(ballistics.def[1].diameter .. " " .. ballistics.def[1].range):toBe(diameter .. " " .. range)
		expect(diameter > 5 and diameter < 7 and range > 30 and range < 60 and near(penetration, 15)):toBe(true)
		fly(w.server, 0.05)
		local own = 0
		for _, hit in ipairs(recorder:Take("hits")) do
			if hit.kind == "fragment" then
				expect(hit.victim == thrower and hit.attacker == thrower):toBe(true)
				own = own + 1
			end
		end
		expect(own >= 1):toBe(true)
		ballistics:Clear()

		-- A directional charge: every fragment in its cone, given fragments as they are.
		explosions:Explode(Vector(0, 0, 500), { charge = 0.05, fragments = 50, dir = Vector(0, 1, 0), cone = 30,
			fragment = { mass = 0.7, velocity = 1200 } })
		expect(ballistics:Count()):toBe(50)
		local widest = 0
		for i = 1, 50 do
			local v = Vector(ballistics.vx[i], ballistics.vy[i], ballistics.vz[i])
			widest = math.max(widest, math.deg(math.acos(math.min(1, v:GetNormalized().y))))
			expect(near(v:Length() * UNIT_M, 1200)):toBe(true)
			expect(ballistics.def[i].mass):toBe(0.7)
		end
		expect(widest <= 30 and widest > 25):toBe(true)
		ballistics:Clear()
		-- The settings launch a share of them, at most maxFragments.
		explosions.ctx.config.fragments = 0.5
		expect(select(2, explosions:Explode(Vector(0, 0, 500), { charge = 0.2, casing = 0.2 }))):toBe(100)
		ballistics:Clear()
		explosions.ctx.config.fragments = 1
		expect(select(2, explosions:Explode(Vector(0, 0, 500), { charge = 1, casing = 1 }))):toBe(300)
		ballistics:Clear()
		expect(select(2, explosions:Explode(Vector(0, 0, 500), { charge = 1 }))):toBe(0)
		expect(w.server:Errors()):toEqual({})
	end)

	it("gives a body the fragments expected for its size without ballistics", function()
		local w = boot({ ballistics = false })
		local a = deploy(w, "Al", Vector(79, 0, 0))
		local b = deploy(w, "Bob", Vector(-200, 0, 0))
		Env.Geometry(w.server):Wall(-100, 10)
		local bodies, launched = w.explosions:Explode(Vector(0, 0, 36), { charge = 0.2, casing = 0.2 })
		expect(bodies .. " " .. launched):toBe("2 0")
		local hits = byVictim(w.recorder:Take("hits"))
		-- 200 fragments over a sphere of 2 m: 0.5 m² of a body takes about 2.
		local mean = 200 * 0.5 / (4 * math.pi * (79 * UNIT_M) ^ 2)
		expect(hits[a][1].fragments):toBe(math.floor(mean + 0.5))
		expect(hits[a][1].fragments):toBe(2)
		-- None through the world.
		expect(hits[b][1].fragments):toBe(0)
		expect(w.server:Errors()):toEqual({})
	end)

	it("pushes props with the engine blast but spares players, shows itself and answers the console", function()
		local w = boot({ ballistics = false })
		local server, explosions, recorder = w.server, w.explosions, w.recorder
		local G = server.G
		local a = deploy(w, "Al", Vector(60, 0, 0))
		local god = deploy(w, "Bob", Vector(-60, 0, 0))
		god:GodEnable()
		local prop = Env.Spawn(server, { pos = Vector(0, 80, 0) })
		local grenade = Env.Spawn(server, { pos = Vector(0, 0, 4), class = "nc_test_grenade" })
		local bodies = explosions:Explode(Vector(0, 0, 4), { attacker = a, inflictor = grenade, charge = 0.2 })
		expect(bodies):toBe(1)
		-- The engine blast: the prop takes it, the players' bodies only take their own wave.
		local blast = server.blasts[1]
		expect(#server.blasts):toBe(1)
		expect(blast.type .. " " .. tostring(blast.attacker == a) .. " " .. tostring(blast.inflictor == grenade))
			:toBe(G.DMG_BLAST .. " true true")
		expect(near(blast.radius, 12 * 0.2 ^ (1 / 3) / UNIT_M)):toBe(true)
		expect(near(blast.damage, 200 * 0.2 ^ (1 / 3))):toBe(true)
		expect(#prop.damage):toBe(1)
		expect(prop.damage[1]:GetDamageForce().y > 0):toBe(true)
		expect(#a.damage + #god.damage):toBe(0)
		local hits = recorder:Take("hits")
		expect(#hits):toBe(1)
		expect(hits[1].victim == a and hits[1].inflictor == grenade):toBe(true)
		-- The effects and the event.
		expect(server.fx[#server.fx].name):toBe("Explosion")
		expect(server.decals[#server.decals].name):toBe("Scorch")
		expect(#server.shakes):toBe(1)
		local event = recorder:Take("explosions")[1]
		expect(event.attacker == a and event.inflictor == grenade and event.charge == 0.2):toBe(true)
		-- Without the engine blast and the effects.
		explosions.ctx.config.engine = false
		explosions:Explode(Vector(0, 0, 4), { charge = 0.2, effects = false })
		expect(#server.blasts .. " " .. #server.shakes):toBe("1 1")
		-- The console: at the feet of a player.
		recorder:Take("hits")
		server:Command("nc_explode", nil, { "0.5", "0", "Al" })
		expect(#server:Lines("nc_explode: 0.50 kg at 60 0 4: 1 bodies, 0 fragments")):toBe(1)
		server:Command("nc_explode", nil, {})
		expect(#server:Lines("nc_explode: from the server console give a player")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)
end)
