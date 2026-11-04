-- Soak tests: the default gamemode (Team Deathmatch with every repository module) for
-- several minutes of game time under
--   random kills, joins, departures, observer keys and admin commands: the invariants of
--   players, teams and spectating hold (a camera may lag behind a change by a tick or two)
--   random fire, blows, blasts, falls, armor and user commands on a flat floor: the
--   engine's health is never touched, a dead body kills its player, an unconscious one has
--   no input, a player down in its body is hidden inside a ragdoll that carries its
--   organism, ragdolls and grips stay within their limits, the clients draw the HUD and
--   its effects.
-- Nothing may error.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN
local DMG = World.DMG

-- A small deterministic generator, independent of math.random used by the gamemode.
local function generator(seed)
	local state = seed
	return function(n)
		state = (state * 1103515245 + 12345) % 2147483648
		return state % n + 1
	end
end

-- The same with the high bits (Park-Miller): consecutive small rolls are independent.
local function uniform(seed)
	local state = seed
	return function(n)
		state = state * 16807 % 2147483647
		return math.floor(state / 2147483647 * n) + 1
	end
end

-- A flat floor at z = 0: a line hits the world where it crosses it.
local function floor(server)
	server.traceLine = function(trace)
		local a, b = trace.start, trace.endpos
		if a.z >= 0 and b.z <= 0 and a.z ~= b.z then
			local t = a.z / (a.z - b.z)
			return { Hit = true, HitWorld = true, StartSolid = false, Fraction = t, PhysicsBone = 0,
				HitPos = Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0), Entity = World.WORLD }
		end
		return { Hit = false, HitWorld = false, StartSolid = false, Fraction = 1, HitPos = Vector(b), Entity = World.NULL }
	end
end

local function pick(roll, list)
	if list[1] == nil then
		return nil
	end
	return list[roll(#list)]
end

describe("soak", function()
	it("keeps the invariants of a busy Team Deathmatch server", function()
		math.randomseed(7)
		local roll = generator(12345)
		local server = Env.Server()
		for i = 0, 7 do
			Env.Spawn(server, { class = "info_player_rebel", pos = Vector(0, i * 200, 0), map = true })
			Env.Spawn(server, { class = "info_player_combine", pos = Vector(4000, i * 200, 0), map = true })
		end
		server:Boot()
		server:Call("InitPostEntity")
		local NC = server:Get("NC")
		local players = NC.Modules:Instance("players")
		local teams = NC.Modules:Instance("teams")
		local spectator = NC.Modules:Instance("spectator")
		local rounds = NC.Modules:Instance("rounds")

		local clients = {}
		clients[1] = Env.Join(server, { name = "Gordon", language = "ru", index = 1 })
		clients[2] = Env.Join(server, { name = "Alyx", language = "en", index = 2 })
		local bots = {}
		local used = { [1] = true, [2] = true }
		local function addBot()
			for index = 3, 40 do
				if not used[index] then
					used[index] = true
					bots[#bots + 1] = Env.Bot(server, { name = "Bot" .. index, index = index })
					return
				end
			end
		end
		for _ = 1, 14 do
			addBot()
		end

		local bad = {}     -- ply -> ticks in a row with a wrong camera
		local phases = {}
		local kills = 0
		for tick = 1, 3000 do
			local alive = players:List("alive")
			if roll(10) == 1 and alive[1] ~= nil then
				local victim = pick(roll, alive)
				local attacker = pick(roll, alive)
				Env.Kill(victim, attacker)
				kills = kills + 1
			end
			if roll(100) == 1 and #bots > 6 then
				local index = roll(#bots)
				local ply = table.remove(bots, index)
				used[ply:EntIndex()] = nil
				Env.Leave(server, ply)
			end
			if roll(100) == 1 and #bots < 20 then
				addBot()
			end
			if roll(4) == 1 then
				local observers = {}
				for _, ply in ipairs(players:ReadyPlayers()) do
					if spectator:IsObserving(ply) then
						observers[#observers + 1] = ply
					end
				end
				local ply = pick(roll, observers)
				if ply ~= nil then
					Env.Press(server, ply, ({ IN.ATTACK, IN.ATTACK2, IN.JUMP })[roll(3)])
				end
			end
			if roll(500) == 1 then
				server:Command("nc_round", nil, { ({ "restart", "end", "next" })[roll(3)], "tdm" })
			end
			server:Advance(0.1)
			phases[rounds:Phase()] = true

			-- Players: the state matches the engine.
			for _, ply in ipairs(players:ReadyPlayers()) do
				local state = players:State(ply)
				expect(ply:Alive()):toBe(state == "alive")
				if teams:Count() > 0 and state == "spectator" then
					expect(ply:Team()):toBe(World.TEAM_SPECTATOR)
				end
				if state == "alive" and teams:Count() > 0 then
					expect(teams:IsPlayable(ply:Team())):toBe(true)
				end
			end
			-- Spectating: a follow camera shows an allowed target soon after a change.
			for _, ply in ipairs(players:ReadyPlayers()) do
				local target = spectator:Target(ply)
				local wrong = spectator:IsObserving(ply) and (target ~= nil and not spectator:CanObserve(ply, target)
					or target ~= ply:GetObserverTarget() and not (target == nil and ply:GetObserverTarget() == World.NULL))
				bad[ply] = wrong and (bad[ply] or 0) + 1 or nil
				if (bad[ply] or 0) > 2 then
					error(string.format("tick %d: %s keeps a wrong camera (target %s)", tick, ply:Nick(),
						tostring(target)))
				end
			end
			if tick % 50 == 0 then
				for _, client in ipairs(clients) do
					client.time = server.time
					Env.Flush(server, client)
					client.drawn = {}
					client:Call("HUDPaint")
				end
			end
		end
		expect(kills > 200):toBe(true)
		expect(phases.active and phases.ended and phases.preparing):toBe(true)
		expect(server:Errors()):toEqual({})
		for _, client in ipairs(clients) do
			expect(client:Errors()):toEqual({})
		end
	end)

	it("keeps the bodies consistent under fire, blows, blasts and falls", function()
		math.randomseed(11)
		local roll = uniform(777)
		local server = Env.Server({ patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.rounds = { params = { tdm = { armor = { "vest_light" }, roundTime = 120 } } }
			cfg.modules.settings.organism = { brainDeathTime = 30 } -- bleeding out within a round
			cfg.modules.settings.ragdoll_control = { grabRange = 40 } -- the hands do not move here: hold on from afar
			return cfg
		end } })
		for i = 0, 5 do
			Env.Spawn(server, { class = "info_player_rebel", pos = Vector(0, i * 150, 0), map = true })
			Env.Spawn(server, { class = "info_player_combine", pos = Vector(1500, i * 150, 0), map = true })
		end
		server:Boot()
		server:Call("InitPostEntity")
		floor(server)
		local NC = server:Get("NC")
		local players = NC.Modules:Instance("players")
		local organism = NC.Modules:Instance("organism")
		local movement = NC.Modules:Instance("movement")
		local ragdoll = NC.Modules:Instance("ragdoll")
		local control = NC.Modules:Instance("ragdoll_control")
		local limits = ragdoll.ctx.config
		-- The bodies on their own rolls: the fire and the blows stay as they were.
		local side = uniform(4242)
		local counts = { fell = 0, stood = 0, grabbed = 0 }
		NC.Events:On("ragdoll.fell", function(ply, rag)
			counts.fell = counts.fell + 1
			World.LayRagdoll(rag, ply:EntIndex() % 2 == 0) -- the engine's gravity: the body lies down
		end)
		NC.Events:On("ragdoll.stood", function() counts.stood = counts.stood + 1 end)
		NC.Events:On("ragdoll_control.grabbed", function() counts.grabbed = counts.grabbed + 1 end)
		local deaths = {}
		NC.Events:On("organism.died", function(_, cause) deaths[cause] = (deaths[cause] or 0) + 1 end)
		local hits = 0
		NC.Events:On("damage.hit", function() hits = hits + 1 end)

		local clients = {}
		clients[1] = Env.Join(server, { name = "Gordon", language = "ru", index = 1 })
		clients[2] = Env.Join(server, { name = "Alyx", language = "en", index = 2 })
		for index = 3, 12 do
			Env.Bot(server, { name = "Bot" .. index, index = index })
		end
		local AMMO = { "Pistol", "357", "SMG1", "AR2", "Buckshot", "SniperRound", "XBowBolt", "Unknown" }
		local BONES = { "Head1", "Neck1", "Spine2", "Spine4", "Spine", "Pelvis", "L_UpperArm", "R_Forearm", "L_Thigh",
			"R_Calf", "L_Foot", "R_Hand" }
		local ARMOR = { "helmet", "vest", "plates", "plates_heavy", "strip", "-vest" }
		local function jitter()
			return Vector((roll(9) - 5) * 0.8, (roll(9) - 5) * 0.8, (roll(9) - 5) * 0.8)
		end

		local zombie = {} -- ply -> ticks alive with a dead body
		local shots = 0
		for tick = 1, 1500 do
			local alive = players:List("alive")
			for _ = 1, 3 do
				local shooter, victim = pick(roll, alive), pick(roll, alive)
				if shooter ~= nil and victim ~= shooter and roll(2) == 1 then
					local ammo = pick(roll, AMMO)
					local opts = { bone = pick(roll, BONES), offset = jitter(), ammo = ammo }
					if ammo == "Buckshot" then
						opts.pellets = { { bone = pick(roll, BONES) }, { bone = pick(roll, BONES) },
							{ bone = pick(roll, BONES), offset = jitter() } }
					end
					Env.Shoot(shooter, victim, opts)
					shots = shots + 1
				end
			end
			local victim = pick(roll, alive)
			if victim ~= nil then
				local kind = roll(40)
				if kind <= 2 then
					local other = pick(roll, alive)
					Env.Shoot(other, victim, { bone = pick(roll, BONES), ammo = "none", damage = 5 + roll(40),
						type = ({ DMG.CLUB, DMG.SLASH, DMG.CLUB + DMG.SHOCK })[roll(3)] })
				elseif kind == 3 then
					local pos = victim:GetPos() + Vector(roll(300) - 150, roll(300) - 150, 20)
					Env.Hurt(victim, { type = DMG.BLAST, damage = 10 + roll(200), pos = pos, attacker = pick(roll, alive),
						force = Vector(0, 0, 5000) })
				elseif kind == 4 then
					Env.Fall(victim, 250 + roll(1200), roll(5) == 1)
				elseif kind == 5 then
					server:Command("nc_armor", nil, { victim:Nick(), pick(roll, ARMOR) })
				elseif kind == 6 then
					Env.Hurt(victim, { type = ({ DMG.BURN, DMG.POISON, DMG.CRUSH, DMG.SHOCK, DMG.GENERIC })[roll(5)],
						damage = roll(60), attacker = pick(roll, alive) })
				end
			end
			for _, ply in ipairs(alive) do
				if ply:Alive() and roll(3) == 1 then
					-- Down in its body the player looks around, reaches, crawls and gets up.
					local keys = IN.FORWARD + IN.SPEED + IN.ATTACK
					if ragdoll:IsDown(ply) then
						ply:SetEyeAngles(Angle(side(120) - 30, side(360), 0))
						keys = keys + (side(2) == 1 and IN.JUMP or 0) + (side(2) == 1 and IN.ATTACK2 or 0)
					else
						keys = keys + IN.JUMP
					end
					local buttons = Env.RunCommand(server, ply, keys, 200):GetButtons()
					if organism:IsUnconscious(ply) and ply:GetMoveType() ~= World.MOVETYPE.NOCLIP then
						expect(buttons):toBe(IN.DUCK)
					end
				end
			end
			server:Advance(0.1)

			-- Bodies: a player down is alive, hidden inside a valid ragdoll that carries its
			-- organism; one standing is not hidden; ragdolls, corpses and grips within limits.
			for ply, body in pairs(ragdoll:Bodies()) do
				expect(ply:Alive() and body.ent:IsValid()):toBe(true)
				expect(ply:GetNoDraw() and not ply:IsSolid()):toBe(true)
				expect(ply:GetMoveType()):toBe(World.MOVETYPE.NONE)
				expect(organism:Carrier(ply)):toBe(body.ent)
			end
			local grips = 0
			for _, ply in ipairs(players:ReadyPlayers()) do
				if ply:Alive() and not ragdoll:IsDown(ply) then
					expect(ply:GetNoDraw() or not ply:IsSolid()):toBe(false)
					expect(organism:Carrier(ply)):toBeNil()
				end
				for _, hand in ipairs({ "left", "right" }) do
					if control:Grip(ply, hand) ~= nil then
						expect(ragdoll:IsDown(ply)):toBe(true)
						grips = grips + 1
					end
				end
			end
			local ragdolls = 0
			for _, ent in ipairs(server:Get("ents").FindByClass("prop_ragdoll")) do
				if ent:IsValid() and not ent:IsMarkedForDeletion() then
					ragdolls = ragdolls + 1
				end
			end
			expect(ragdolls <= limits.ragdolls and #ragdoll:Corpses() <= limits.corpses):toBe(true)
			expect(grips <= 2 * ragdoll.fallen):toBe(true)

			for _, ply in ipairs(players:ReadyPlayers()) do
				if ply:Alive() then
					expect(ply:Health()):toBe(100) -- D6: the body decides, not the engine's health
					expect(organism:IsSimulated(ply)):toBe(true)
					zombie[ply] = organism:IsDead(ply) and (zombie[ply] or 0) + 1 or nil
					if (zombie[ply] or 0) > 2 then
						error(string.format("tick %d: %s stays alive with a dead body", tick, ply:Nick()))
					end
				else
					expect(movement:Limit(ply)):toBeNil()
				end
			end
			if tick % 25 == 0 then
				for _, client in ipairs(clients) do
					client:Advance(server.time - client.time)
					Env.Flush(server, client)
					client.drawn, client.rects, client.effects = {}, {}, {}
					client:Call("RenderScreenspaceEffects")
					client:Call("HUDPaint")
					client:Call("HUDShouldDraw", "CHudCrosshair")
				end
			end
		end
		local died = 0
		for _, count in pairs(deaths) do
			died = died + count
		end
		expect(shots > 1000 and hits > 1000):toBe(true)
		expect(died > 20):toBe(true)
		expect((deaths.brain or 0) > 0 and (deaths.head or 0) > 0 and (deaths.fall or 0) > 0):toBe(true)
		expect(counts.fell > 20 and counts.stood > 5 and counts.grabbed > 5):toBe(true)
		expect(server:Errors()):toEqual({})
		for _, client in ipairs(clients) do
			expect(client:Errors()):toEqual({})
		end
	end)
end)
