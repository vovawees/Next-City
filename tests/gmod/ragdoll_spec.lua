-- Ragdoll module: a falling player becomes a ragdoll in its pose and looks out of its
-- eyes, gets up where there is room and leaves a corpse when it dies; the causes of
-- falls, the limits and cleanups of corpses, the camera and the hints of the client and
-- the console, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN
local DMG = World.DMG
local OBS = World.OBS_MODE
local MOVETYPE = World.MOVETYPE
local GROUP = World.COLLISION_GROUP
local HEAD = "ValveBiped.Bip01_Head1"

-- Records what the ragdoll and damage modules tell and answers the ragdoll's questions.
local RECORDER = {
	[MODULES .. "recorder/module.lua"] = "return { id = 'recorder', files = { sv = { 'sv_recorder.lua' } } }",
	[MODULES .. "recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.events = {}
		function M:Start(ctx)
			for _, name in ipairs({ "ragdoll.fell", "ragdoll.stood", "ragdoll.corpse", "damage.hit" }) do
				ctx:On(name, function(ply, a, b) self.events[#self.events + 1] = { name, ply, a, b } end)
			end
			ctx:On("ragdoll.canFall", function() return self.canFall end)
			ctx:On("ragdoll.canGetUp", function() return self.canGetUp end)
		end
		function M:Take(name)
			local out, rest = {}, {}
			for _, entry in ipairs(self.events) do
				if entry[1] == name then
					out[#out + 1] = entry
				else
					rest[#rest + 1] = entry
				end
			end
			self.events = rest
			return out
		end
	]],
}

local function result(hit, pos)
	return { Hit = hit, HitWorld = hit, StartSolid = false, Fraction = hit and 0 or 1, HitPos = pos,
		Entity = World.NULL }
end

-- A flat floor at z = 0: a line hits it where it crosses it; hulls hit nothing unless
-- blocked(trace) says so. Hull traces are recorded in server.hulls.
local function floor(server, blocked)
	server.hulls = {}
	server.traceLine = function(trace)
		local a, b = trace.start, trace.endpos
		if a.z >= 0 and b.z <= 0 and a.z ~= b.z then
			local t = a.z / (a.z - b.z)
			local hit = result(true, Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0))
			hit.Fraction = t
			return hit
		end
		return result(false, Vector(b))
	end
	server.traceHull = function(trace)
		server.hulls[#server.hulls + 1] = { start = Vector(trace.start), mins = trace.mins, maxs = trace.maxs,
			mask = trace.mask, group = trace.collisiongroup, filter = { trace.filter[1], trace.filter[2] } }
		return result(blocked ~= nil and blocked(trace) or false, Vector(trace.endpos))
	end
end

local function nowhere()
	return true
end

local function boot(settings)
	local server = Env.Server({ files = RECORDER, modules = { "players", "organism", "damage", "ragdoll" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.ragdoll = settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	floor(server)
	local NC = server:Get("NC")
	local organism = NC.Modules:Instance("organism")
	organism.Random = function() return 0.5 end
	return server, NC.Modules:Instance("ragdoll"), organism, NC.Modules:Instance("players"),
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

-- The server runs for `seconds` in ticks of 0.1 s.
local function run(server, seconds)
	for _ = 1, math.floor(seconds / 0.1 + 0.5) do
		server:Advance(0.1)
	end
end

local function component(ragdoll, ply)
	local data = ragdoll.ctx.components.body:Get(ply)
	return data and (data.state .. " " .. data.ent .. " " .. data.blocked)
end

local function gone(ent)
	return not ent:IsValid() or ent:IsMarkedForDeletion()
end

local function near(a, b, epsilon)
	return (a - b):Length() <= (epsilon or 1e-6)
end

local function nearAngles(a, b)
	return near(a:Forward(), b:Forward()) and near(a:Up(), b:Up())
end

local function hurtLegs(server, name)
	server:Command("nc_hurt", nil, { name, "bullet", "femur_l" })
	server:Command("nc_hurt", nil, { name, "bullet", "femur_r" })
end

-- A player on a client; sync(seconds) runs the server, then the client follows its clock
-- and gets the news.
local function join(settings, language)
	local server, ragdoll, organism, players, recorder = boot(settings)
	local client, ply = Env.Join(server, { name = "Gordon", language = language })
	players:Deploy(ply)
	local function sync(seconds)
		run(server, seconds or 0.1)
		client:Advance(server.time - client.time)
		Env.Flush(server, client)
	end
	sync()
	return server, client, ply, ragdoll, organism, sync, client:Get("NC").Modules:Instance("ragdoll"), recorder
end

local function view(client, ply, angles)
	return client:Call("CalcView", ply, ply:EyePos(), angles or Angle(10, 20, 0), 90, 3, 30000)
end

local function paint(client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("ragdoll", function()
	it("lays a player into a ragdoll in its pose, hides it inside and keeps it at the head", function()
		local server, ragdoll, organism, players, recorder = boot()
		local ply = deploy(server, players, "Bob", Vector(100, 50, 0), 90)
		local poses = {}
		for _, entry in ipairs(World.PHYS_BONES) do
			poses[entry[1]] = ply:GetBonePosition(ply:LookupBone(entry[1]))
		end
		ply:SetLocalVelocity(Vector(0, 150, 0))
		local setups = ply.setups or 0
		local body, why = ragdoll:Fall(ply)
		expect(why):toBeNil()
		local rag = body.ent
		expect(rag:GetClass()):toBe("prop_ragdoll")
		expect(rag:GetModel()):toBe(ply:GetModel())
		expect(rag:GetCollisionGroup()):toBe(GROUP.WEAPON)
		expect(ply.setups):toBe(setups + 1)
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			expect(phys:GetPos()):toEqual(poses[phys.bone])
			expect(phys:GetVelocity()):toEqual(Vector(0, 150, 0))
		end
		expect(body.head):toBe(rag.physByBone[HEAD])
		expect(body.pelvis):toBe(rag:GetPhysicsObjectNum(0))
		expect(body.phys["ValveBiped.Bip01_L_Hand"]):toBe(rag:GetPhysicsObjectNum(5))
		-- Hidden inside: not drawn, no hull, no movement, the eyes at the origin, no weapon.
		expect(ply:GetNoDraw()):toBe(true)
		expect(ply:IsSolid()):toBe(false)
		expect(ply:GetMoveType()):toBe(MOVETYPE.NONE)
		expect(ply:GetVelocity()):toEqual(Vector(0, 0, 0))
		expect(ply:GetViewOffset()):toEqual(Vector(0, 0, 0))
		expect(ply.viewModelHidden and ply.worldModelHidden):toBe(true)
		expect(ply:GetPos()):toEqual(body.head:GetPos())
		expect(organism:Carrier(ply)):toBe(rag)
		expect(ragdoll:IsDown(ply)):toBe(true)
		expect(ragdoll:Body(ply)):toBe(body)
		expect(ragdoll:Bodies()[ply]):toBe(body)
		expect(component(ragdoll, ply)):toBe("fallen " .. rag:EntIndex() .. " none")
		local fell = recorder:Take("ragdoll.fell")
		expect(#fell):toBe(1)
		expect(fell[1][3]):toBe(rag)
		expect(fell[1][4]):toBe("command")
		-- The body slides on and the player keeps to its head.
		run(server, 0.3)
		expect(body.head:GetPos().y > poses[HEAD].y + 10):toBe(true)
		expect(ply:GetPos()):toEqual(body.head:GetPos())
		expect(select(2, ragdoll:Fall(ply))):toBe("down")
		expect(server:Errors()):toEqual({})
	end)

	it("refuses to lay down the dead, players in vehicles or noclip and when a rule says no", function()
		local server, ragdoll, _, players, recorder = boot()
		local ply = deploy(server, players, "Bob")
		ply.vehicle = World.NewEntity(server, 300, "prop_vehicle_jeep")
		expect(select(2, ragdoll:Fall(ply))):toBe("vehicle")
		ply.vehicle = nil
		ply:SetMoveType(MOVETYPE.NOCLIP)
		expect(select(2, ragdoll:Fall(ply))):toBe("noclip")
		ply:SetMoveType(MOVETYPE.WALK)
		recorder.canFall = false
		expect(select(2, ragdoll:Fall(ply))):toBe("refused")
		recorder.canFall = nil
		Env.Kill(ply)
		expect(select(2, ragdoll:Fall(ply))):toBe("dead")
		expect(#recorder:Take("ragdoll.fell")):toBe(0)
		expect(server:Errors()):toEqual({})
	end)

	it("gets up with the jump key once the body may, where there is room", function()
		local server, ragdoll, organism, players, recorder = boot()
		local ply = deploy(server, players, "Bob", Vector(30, -20, 0))
		local body = ragdoll:Fall(ply)
		local rag = body.ent
		World.LayRagdoll(rag)
		-- The keys go to the body, not to the engine.
		local cmd = Env.RunCommand(server, ply, IN.JUMP + IN.FORWARD + IN.ATTACK, 200, -50)
		expect({ cmd:GetButtons(), cmd:GetForwardMove(), cmd:GetSideMove() }):toEqual({ 0, 0, 0 })
		expect(body.input.buttons):toBe(IN.JUMP + IN.FORWARD + IN.ATTACK)
		expect(body.input.forward .. " " .. body.input.side):toBe("200 -50")
		expect(body.input.jump):toBe(true)
		run(server, 0.1) -- too early: the press is spent
		expect(body.input.jump):toBe(false)
		expect(body.state):toBe("fallen")
		run(server, 1.5)
		Env.RunCommand(server, ply, IN.JUMP) -- still held: not a new press
		run(server, 0.1)
		expect(body.state):toBe("fallen")
		Env.RunCommand(server, ply, 0)
		Env.RunCommand(server, ply, IN.JUMP)
		run(server, 0.1)
		expect(body.state):toBe("getting_up")
		local pelvis = body.pelvis:GetPos()
		local spot = Vector(pelvis.x, pelvis.y, 0)
		expect(ply:GetPos()):toEqual(spot)
		expect(ply:GetViewOffset()):toEqual(Vector(0, 0, 64))
		expect(ply:GetNoDraw()):toBe(true) -- in the body until it is up
		expect(component(ragdoll, ply)):toBe("getting_up " .. rag:EntIndex() .. " none")
		-- The room is looked for as player movement sees the world, the body and the player aside.
		local hull = server.hulls[#server.hulls]
		expect(hull.start):toEqual(Vector(spot.x, spot.y, 1))
		expect({ hull.mins, hull.maxs }):toEqual({ ply:GetHull() })
		expect(hull.mask .. " " .. hull.group):toBe(server:Get("MASK_PLAYERSOLID") .. " " .. GROUP.PLAYER_MOVEMENT)
		expect(hull.filter):toEqual({ ply, rag })
		run(server, 1.2)
		expect(ragdoll:IsDown(ply)):toBe(false)
		expect(gone(rag)):toBe(true)
		expect(ply:GetNoDraw()):toBe(false)
		expect(ply:IsSolid()):toBe(true)
		expect(ply:GetMoveType()):toBe(MOVETYPE.WALK)
		expect(ply.viewModelHidden or ply.worldModelHidden):toBe(false)
		expect(ply:GetPos()):toEqual(spot)
		expect(organism:Carrier(ply)):toBeNil()
		expect(component(ragdoll, ply)):toBe("standing 0 none")
		expect(#recorder:Take("ragdoll.stood")):toBe(1)
		expect(Env.RunCommand(server, ply, IN.JUMP):GetButtons()):toBe(IN.JUMP)
		expect(server:Errors()):toEqual({})
	end)

	it("stands up beside a body that lies where the player does not fit", function()
		local server, ragdoll, _, players = boot()
		local ply = deploy(server, players, "Bob")
		local body = ragdoll:Fall(ply)
		World.LayRagdoll(body.ent)
		local pelvis = body.pelvis:GetPos()
		-- No room right above the pelvis.
		floor(server, function(trace) return near(trace.start, Vector(pelvis.x, pelvis.y, 1), 5) end)
		run(server, 1.6)
		expect(ragdoll:GetUp(ply)):toBe(true)
		expect(near(ply:GetPos(), Vector(pelvis.x + 20, pelvis.y, 0))):toBe(true)
		-- The spot is taken by the time the player is up: back down, and why.
		floor(server, nowhere)
		run(server, 1.3)
		expect(body.state):toBe("fallen")
		expect(body.blocked):toBe("room")
		expect(ply:GetViewOffset()):toEqual(Vector(0, 0, 0))
		expect(ply:GetPos()):toEqual(body.head:GetPos())
		expect(component(ragdoll, ply)):toBe("fallen " .. body.ent:EntIndex() .. " room")
		expect(server:Errors()):toEqual({})
	end)

	it("keeps a body down that may not get up and tells the player why", function()
		local server, ragdoll, _, players, recorder = boot()
		local ply = deploy(server, players, "Bob")
		local body = ragdoll:Fall(ply)
		local rag = body.ent
		local function why()
			return select(2, ragdoll:GetUp(ply))
		end
		expect(why()):toBe("delay")
		run(server, 1.6)
		rag:GetPhysicsObject():SetVelocity(Vector(80, 0, 0))
		expect(why()):toBe("moving")
		expect(component(ragdoll, ply)):toBe("fallen " .. rag:EntIndex() .. " moving")
		run(server, 1.5) -- at rest again
		recorder.canGetUp = false
		expect(why()):toBe("refused")
		recorder.canGetUp = nil
		floor(server, nowhere)
		expect(why()):toBe("room")
		expect(component(ragdoll, ply)):toBe("fallen " .. rag:EntIndex() .. " room")
		server.traceLine = nil -- no floor in reach either
		floor(server)
		server.traceLine = nil
		expect(why()):toBe("room")
		floor(server)
		hurtLegs(server, "Bob")
		expect(why()):toBe("legs")
		expect(body.state):toBe("fallen")
		-- An admin stands it up where there is room; on such legs it falls again.
		server:Command("nc_ragdoll", nil, { "Bob", "up" })
		expect(body.state):toBe("getting_up")
		run(server, 1.5)
		local again = ragdoll:Body(ply)
		expect(again ~= nil and again ~= body):toBe(true)
		expect(again.cause):toBe("weak")
		expect(server:Errors()):toEqual({})
	end)

	it("falls unconscious, wakes up on the ground and then may get up", function()
		local server, ragdoll, organism, players, recorder = boot()
		local ply = deploy(server, players, "Bob")
		organism:_Knockout(organism:State(ply), 5)
		run(server, 0.2)
		local body = ragdoll:Body(ply)
		expect(body.state):toBe("unconscious")
		expect(recorder:Take("ragdoll.fell")[1][4]):toBe("unconscious")
		expect(component(ragdoll, ply)):toBe("unconscious " .. body.ent:EntIndex() .. " none")
		expect(select(2, ragdoll:GetUp(ply))):toBe("unconscious")
		for _ = 1, 600 do
			run(server, 0.1)
			if body.state ~= "unconscious" then
				break
			end
		end
		expect(body.state):toBe("fallen")
		expect(organism:IsUnconscious(ply)):toBe(false)
		for _ = 1, 600 do
			if organism:Capabilities(ply).canStand then
				break
			end
			run(server, 0.1)
		end
		run(server, 1.6)
		expect(ragdoll:GetUp(ply)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("lays down a body whose legs do not hold, unless it should crawl instead", function()
		local server, ragdoll, _, players = boot()
		local ply = deploy(server, players, "Bob")
		hurtLegs(server, "Bob")
		expect(ragdoll:IsDown(ply)):toBe(false) -- at the next think, outside the damage
		run(server, 0.1)
		expect(ragdoll:Body(ply).cause):toBe("weak")
		run(server, 1.6)
		expect(select(2, ragdoll:GetUp(ply))):toBe("legs")

		local crawlServer, crawl, _, crawlPlayers = boot({ fallWhenWeak = false })
		local bob = deploy(crawlServer, crawlPlayers, "Bob")
		hurtLegs(crawlServer, "Bob")
		run(crawlServer, 0.2)
		expect(crawl:IsDown(bob)):toBe(false)
		expect(crawl:Fall(bob)):toBeTruthy()
		run(crawlServer, 1.6)
		expect(crawl:GetUp(bob)):toBe(true) -- and crawls on
		expect(server:Errors()):toEqual({})
		expect(crawlServer:Errors()):toEqual({})
	end)

	it("knocks a player down with a heavy blow or a hard landing, at the next think", function()
		local server, ragdoll, _, players, recorder = boot({ knockdown = 20 })
		local bob = deploy(server, players, "Bob")
		local al = deploy(server, players, "Al", Vector(40, 0, 0), 180)
		Env.Hurt(bob, { damage = 10, type = DMG.CLUB, attacker = al })
		Env.Hurt(bob, { damage = 30, type = DMG.BULLET, attacker = al })
		run(server, 0.2)
		expect(ragdoll:IsDown(bob)):toBe(false)
		Env.Hurt(bob, { damage = 25, type = DMG.CLUB, attacker = al })
		expect(ragdoll:IsDown(bob)):toBe(false)
		run(server, 0.1)
		expect(ragdoll:Body(bob).cause):toBe("hit")

		local cy = deploy(server, players, "Cy", Vector(-100, 0, 0))
		Env.Fall(cy, 500)
		Env.Fall(cy, 800, true) -- into water
		run(server, 0.2)
		expect(ragdoll:IsDown(cy)):toBe(false)
		Env.Fall(cy, 700)
		run(server, 0.1)
		expect(ragdoll:Body(cy).cause):toBe("landing")
		local causes = {}
		for _, entry in ipairs(recorder:Take("ragdoll.fell")) do
			causes[#causes + 1] = entry[4]
		end
		expect(causes):toEqual({ "hit", "landing" })
		expect(server:Errors()):toEqual({})
	end)

	it("falls and gets up at will with nc_fall, not more often than the cooldown allows", function()
		local server, client, ply, ragdoll, _, sync = join({ cooldown = 5 })
		client:Command("nc_fall", ply)
		Env.Flush(server, client)
		local body = ragdoll:Body(ply)
		expect(body.cause):toBe("voluntary")
		sync(1.6)
		client:Command("nc_fall", ply) -- again: get up
		Env.Flush(server, client)
		expect(body.state):toBe("getting_up")
		sync(1.3)
		expect(ragdoll:IsDown(ply)):toBe(false)
		client:Command("nc_fall", ply)
		Env.Flush(server, client)
		expect(ragdoll:IsDown(ply)):toBe(false) -- the cooldown
		sync(2.2)
		client:Command("nc_fall", ply)
		Env.Flush(server, client)
		expect(ragdoll:IsDown(ply)):toBe(true)

		local offServer, offClient, gordon, off = join({ voluntary = false })
		offClient:Command("nc_fall", gordon)
		Env.Flush(offServer, offClient)
		expect(off:IsDown(gordon)):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(offServer:Errors()):toEqual({})
	end)

	it("takes the keys of a fallen player from the prediction of its client too", function()
		local server, client, ply, ragdoll, _, sync = join()
		local function keys()
			local cmd = Env.RunCommand(client, ply, IN.JUMP + IN.ATTACK, 200, 50)
			return { cmd:GetButtons(), cmd:GetForwardMove(), cmd:GetSideMove() }
		end
		expect(keys()):toEqual({ IN.JUMP + IN.ATTACK, 200, 50 })
		ragdoll:Fall(ply)
		sync()
		expect(keys()):toEqual({ 0, 0, 0 })
		ragdoll:GetUp(ply, true)
		sync()
		expect(keys()):toEqual({ 0, 0, 0 }) -- getting up
		sync(1.3)
		expect(keys()):toEqual({ IN.JUMP + IN.ATTACK, 200, 50 })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("leaves the fallen body as the corpse, or a corpse in the pose, instead of the engine's", function()
		local server, ragdoll, organism, players, recorder = boot()
		local bob = deploy(server, players, "Bob")
		local body = ragdoll:Fall(bob)
		local rag = body.ent
		Env.Kill(bob)
		expect(ragdoll:IsDown(bob)):toBe(false)
		local corpses = ragdoll:Corpses()
		expect(#corpses):toBe(1)
		expect(corpses[1].ent):toBe(rag)
		expect(corpses[1].ply):toBe(bob)
		expect(gone(rag)):toBe(false)
		expect(gone(bob.engineRagdoll)):toBe(true)
		expect(organism:Carrier(bob)):toBe(rag) -- the organism reads the dead body from the corpse
		expect(bob:GetNoDraw()):toBe(false)
		expect(bob:GetViewOffset()):toEqual(Vector(0, 0, 64))
		expect(component(ragdoll, bob)):toBe("dead " .. rag:EntIndex() .. " none")
		local corpse = recorder:Take("ragdoll.corpse")
		expect(#corpse):toBe(1)
		expect(corpse[1][3]):toBe(rag)

		local al = deploy(server, players, "Al", Vector(200, 0, 0))
		players:Kill(al, { force = Vector(0, 12000, 0), position = Vector(200, 0, 51.5) })
		local pushed = ragdoll:Corpses()[2].ent
		expect(pushed:GetClass()):toBe("prop_ragdoll")
		expect(pushed:GetPhysicsObjectNum(0):GetPos()):toEqual(Vector(200, 0, 38.5))
		expect(pushed:GetPhysicsObjectNum(1).forces):toEqual({ Vector(0, 12000, 0) }) -- the chest was hit
		expect(gone(al.engineRagdoll)):toBe(true)
		expect(organism:Carrier(al)):toBe(pushed)

		local cy = deploy(server, players, "Cy", Vector(-200, 0, 0))
		ragdoll:Fall(cy)
		players:Kill(cy, { damageType = DMG.REMOVENORAGDOLL })
		expect(#ragdoll:Corpses()):toBe(2)
		expect(ragdoll:IsDown(cy)):toBe(false)
		expect(component(ragdoll, cy)):toBe("dead 0 none")

		players:Deploy(bob)
		expect(component(ragdoll, bob)):toBe("standing 0 none")
		expect(organism:Carrier(bob)):toBeNil()
		-- Spawned again the player has its hull and movement back.
		expect(bob:IsSolid()):toBe(true)
		expect(bob:GetMoveType()):toBe(MOVETYPE.WALK)
		players:Deploy(cy)
		expect(cy:IsSolid()):toBe(true)
		expect(cy:GetMoveType()):toBe(MOVETYPE.WALK)
		expect(#ragdoll:Corpses()):toBe(2) -- the corpse stays
		expect(server:Errors()):toEqual({})
	end)

	it("keeps at most the configured corpses and ragdolls, the oldest corpse going first", function()
		local server, ragdoll, _, players = boot({ corpses = 2, ragdolls = 3 })
		local list = {}
		for i = 1, 7 do
			list[i] = deploy(server, players, "P" .. i, Vector(i * 100, 0, 0))
		end
		Env.Kill(list[1])
		Env.Kill(list[2])
		local first = ragdoll:Corpses()[1].ent
		Env.Kill(list[3])
		expect(#ragdoll:Corpses()):toBe(2)
		expect(gone(first)):toBe(true)
		expect(ragdoll:Corpses()[1].ply):toBe(list[2])
		-- Fallen bodies count too: at the limit the oldest corpse makes room.
		expect(ragdoll:Fall(list[4])):toBeTruthy()
		expect(ragdoll:Fall(list[5])):toBeTruthy()
		expect(#ragdoll:Corpses()):toBe(1)
		expect(ragdoll:Corpses()[1].ply):toBe(list[3])
		expect(ragdoll:Fall(list[6])):toBeTruthy()
		expect(#ragdoll:Corpses()):toBe(0)
		expect(select(2, ragdoll:Fall(list[7]))):toBe("limit")
		-- Beyond the limit a dying player keeps the ragdoll of the engine.
		Env.Kill(list[7])
		expect(#ragdoll:Corpses()):toBe(0)
		expect(gone(list[7].engineRagdoll)):toBe(false)
		-- A fallen body that dies is counted already.
		Env.Kill(list[4])
		expect(#ragdoll:Corpses()):toBe(1)
		expect(ragdoll.fallen):toBe(2)
		expect(server:Errors()):toEqual({})
	end)

	it("lets corpses at rest sleep and clears old ones within the budget", function()
		local server, ragdoll, _, players = boot({ corpseTime = 10, settleTime = 3, cleanupBudget = 1 })
		local list = {}
		for i = 1, 3 do
			list[i] = deploy(server, players, "P" .. i, Vector(i * 100, 0, 0))
		end
		players:Kill(list[1], { force = Vector(0, 20000, 0), position = Vector(100, 0, 51.5) })
		Env.Kill(list[2])
		Env.Kill(list[3])
		local moving, still = ragdoll:Corpses()[1], ragdoll:Corpses()[2]
		run(server, 3.6)
		expect(still.settled):toBe(true)
		expect(still.ent:GetCollisionGroup()):toBe(GROUP.DEBRIS)
		expect(still.ent:GetPhysicsObjectNum(0):IsAsleep()):toBe(true)
		expect(moving.settled):toBe(false) -- at rest later
		expect(moving.ent:GetCollisionGroup()):toBe(GROUP.WEAPON)
		run(server, 1.5)
		expect(moving.settled):toBe(true)
		for _ = 1, 100 do
			if #ragdoll:Corpses() < 3 then
				break
			end
			run(server, 0.1)
		end
		expect(#ragdoll:Corpses()):toBe(2)
		expect(gone(moving.ent)):toBe(true)
		run(server, 0.2)
		expect(#ragdoll:Corpses()):toBe(2) -- one a cleanup
		run(server, 0.5)
		expect(#ragdoll:Corpses()):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("drops the body of a player out of the game and stands up one whose body is removed", function()
		local server, ragdoll, organism, players = boot()
		local list = {}
		for i = 1, 6 do
			list[i] = deploy(server, players, "P" .. i, Vector(i * 100, 0, 0))
		end
		-- Spectating.
		local body = ragdoll:Fall(list[1])
		players:MakeSpectator(list[1])
		expect(ragdoll:IsDown(list[1])):toBe(false)
		expect(gone(body.ent)):toBe(true)
		expect(list[1]:GetNoDraw()):toBe(false)
		expect(component(ragdoll, list[1])):toBe("standing 0 none")
		-- A silent death leaves no corpse.
		body = ragdoll:Fall(list[2])
		list[2]:KillSilent()
		expect(gone(body.ent)):toBe(true)
		expect(#ragdoll:Corpses()):toBe(0)
		expect(component(ragdoll, list[2])):toBe("dead 0 none")
		-- Back in the game, with the hull and the movement.
		for i = 1, 2 do
			players:Deploy(list[i])
			expect(list[i]:IsSolid()):toBe(true)
			expect(list[i]:GetMoveType()):toBe(MOVETYPE.WALK)
			expect(list[i]:GetNoDraw()):toBe(false)
		end
		-- Leaving.
		body = ragdoll:Fall(list[3])
		Env.Leave(server, list[3])
		expect(gone(body.ent)):toBe(true)
		-- A new spawn.
		body = ragdoll:Fall(list[4])
		players:Deploy(list[4])
		expect(gone(body.ent)):toBe(true)
		expect(list[4]:GetMoveType()):toBe(MOVETYPE.WALK)
		expect(component(ragdoll, list[4])):toBe("standing 0 none")
		expect(organism:Carrier(list[4])):toBeNil()
		-- The body removed by something else: the player stands up where it lay.
		body = ragdoll:Fall(list[5])
		World.LayRagdoll(body.ent)
		run(server, 0.1)
		local pelvis = body.pelvis:GetPos()
		body.ent:Remove()
		server:Advance(0.1)
		expect(ragdoll:IsDown(list[5])):toBe(false)
		expect(list[5]:GetPos()):toEqual(Vector(pelvis.x, pelvis.y, 0))
		expect(list[5]:GetNoDraw()):toBe(false)
		expect(component(ragdoll, list[5])):toBe("standing 0 none")
		-- A cleanup of the map: corpses are forgotten, bodies stand up.
		Env.Kill(list[6])
		expect(#ragdoll:Corpses()):toBe(1)
		ragdoll:Fall(list[4])
		server:Get("game").CleanUpMap()
		expect(#ragdoll:Corpses()):toBe(0)
		expect(ragdoll:IsDown(list[4])):toBe(false)
		expect(ragdoll.fallen):toBe(0)
		expect(next(ragdoll.byEnt)):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("hurts a fallen player through its body", function()
		local server, ragdoll, organism, players, recorder = boot()
		local bob = deploy(server, players, "Bob")
		local al = deploy(server, players, "Al", Vector(200, 0, 0), 180)
		local rag = ragdoll:Fall(bob).ent
		World.LayRagdoll(rag)
		local chest = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_Spine2"))
		Env.Shoot(al, rag, { from = Vector(chest.x, chest.y, 80) })
		local hits = recorder:Take("damage.hit")
		expect(#hits):toBe(1)
		expect(hits[1][2]):toBe(bob)
		expect(hits[1][3].region):toBe("chest")
		expect(organism:State(bob).lastPos ~= nil):toBe(true)
		expect(bob:Health()):toBe(100)
		expect(server:Errors()):toEqual({})
	end)

	it("lists the bodies and lets an admin lay a player down and stand it up", function()
		local server, ragdoll, _, players = boot()
		local bob = deploy(server, players, "Bob")
		server:Command("nc_ragdoll", nil, { "Bob", "fall" })
		expect(#server:Lines("nc_ragdoll: Bob fell")):toBe(1)
		server:Command("nc_ragdoll", nil, { "Bob", "fall" })
		expect(#server:Lines("nc_ragdoll: Bob cannot fall: down")):toBe(1)
		server:Command("nc_ragdoll", nil, {})
		expect(#server:Lines("nc_ragdoll: 1 down, 0 corpses; ragdolls 1/64, corpses 0/24")):toBe(1)
		local rag = ragdoll:Body(bob).ent
		expect(#server:Lines("  Bob: fallen for 0.0 s (command), ragdoll #" .. rag:EntIndex())):toBe(1)
		floor(server, nowhere)
		server:Command("nc_ragdoll", nil, { "Bob", "up" })
		expect(#server:Lines("nc_ragdoll: Bob cannot get up: room")):toBe(1)
		server:Command("nc_ragdoll", nil, { "Bob" })
		expect(#server:Lines("ragdoll #" .. rag:EntIndex() .. ", cannot get up: room")):toBe(1)
		floor(server)
		server:Command("nc_ragdoll", nil, { "Bob", "up" })
		expect(#server:Lines("nc_ragdoll: Bob gets up")):toBe(1)
		server:Command("nc_ragdoll", nil, { "Bob", "dance" })
		expect(#server:Lines("nc_ragdoll: [player] [fall | up]")):toBe(1)
		run(server, 1.3)
		server:Command("nc_ragdoll", nil, { "Bob" })
		expect(#server:Lines("nc_ragdoll: Bob is not down")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("looks out of the eyes of the body, then rises to the eyes of the player", function()
		local server, client, ply, ragdoll, _, sync, cl = join()
		local standing = view(client, ply)
		expect(standing.origin):toEqual(ply:EyePos())
		expect(standing.znear):toBe(3)
		local rag = ragdoll:Fall(ply).ent
		World.LayRagdoll(rag)
		sync()
		expect(cl:State()):toBe("fallen")
		expect(cl:IsDown()):toBe(true)
		expect(cl:Ragdoll()):toBe(rag)
		local v = view(client, ply, Angle(10, 20, 0))
		local eyes = rag:GetAttachment(rag:LookupAttachment("eyes"))
		expect(near(v.origin, eyes.Pos)):toBe(true)
		expect(v.angles):toEqual(Angle(10, 20, 0)) -- the player looks around
		expect(v.znear):toBe(1)
		expect(v.drawviewer):toBe(false)
		local head = rag:LookupBone(HEAD)
		expect(rag:GetManipulateBoneScale(head)):toEqual(Vector(0.01, 0.01, 0.01))
		expect((rag.setups or 0) > 0):toBe(true)

		ragdoll:GetUp(ply, true)
		sync()
		expect(cl:State()):toBe("getting_up")
		local since = cl.since
		local target = ply:EyePos()
		client.time = since + 0.6 -- halfway: the eyes are halfway up, the head is back
		v = view(client, ply)
		expect(near(v.origin, (eyes.Pos + target) * 0.5)):toBe(true)
		expect(rag:GetManipulateBoneScale(head)):toEqual(Vector(1, 1, 1))
		client.time = since + 0.1
		v = view(client, ply)
		expect(rag:GetManipulateBoneScale(head)):toEqual(Vector(0.01, 0.01, 0.01))
		sync(1.3)
		expect(cl:State()):toBe("standing")
		expect(view(client, ply).origin):toEqual(ply:EyePos())
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("follows the eyes of an unconscious body and of the corpse until an observer camera", function()
		local server, client, ply, ragdoll, organism, sync, cl = join()
		organism:_Knockout(organism:State(ply), 30)
		sync(0.3)
		expect(cl:State()):toBe("unconscious")
		local rag = cl:Ragdoll()
		expect(rag):toBe(ragdoll:Body(ply).ent)
		World.LayRagdoll(rag)
		local v = view(client, ply, Angle(10, 20, 0))
		local eyes = rag:GetAttachment(rag:LookupAttachment("eyes"))
		expect(near(v.origin, eyes.Pos)):toBe(true)
		expect(nearAngles(v.angles, eyes.Ang)):toBe(true)

		Env.Kill(ply)
		sync()
		expect(cl:State()):toBe("dead")
		expect(cl:Ragdoll()):toBe(rag)
		v = view(client, ply, Angle(10, 20, 0))
		expect(near(v.origin, eyes.Pos)):toBe(true)
		local head = rag:LookupBone(HEAD)
		expect(rag:GetManipulateBoneScale(head)):toEqual(Vector(0.01, 0.01, 0.01))
		ply.observerMode = OBS.ROAMING
		v = view(client, ply, Angle(10, 20, 0))
		expect(v.origin):toEqual(ply:EyePos())
		expect(rag:GetManipulateBoneScale(head)):toEqual(Vector(1, 1, 1))
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("tells a fallen player how to get up, or why not, in the language of the player", function()
		local server, client, ply, ragdoll, _, sync, cl = join()
		expect(client:Call("HUDShouldDraw", "CHudCrosshair")):toBe(true)
		ragdoll:Fall(ply)
		sync()
		expect(paint(client)):toEqual({}) -- too early
		expect(client:Call("HUDShouldDraw", "CHudCrosshair")):toBe(false)
		expect(client:Call("HUDShouldDraw", "CHudAmmo")):toBe(false)
		expect(client:Call("HUDShouldDraw", "CHudChat")):toBe(true)
		sync(1.5)
		expect(paint(client)):toEqual({ "Press SPACE to get up" })
		local hint = cl.hint
		paint(client)
		expect(cl.hint):toBe(hint) -- not rebuilt every frame
		floor(server, nowhere)
		ragdoll:GetUp(ply)
		sync()
		expect(paint(client)):toEqual({ "No room to get up here" })
		floor(server)
		ragdoll:GetUp(ply)
		sync()
		expect(paint(client)):toEqual({ "Getting up…" })
		sync(1.3)
		expect(paint(client)):toEqual({})
		expect(client:Call("HUDShouldDraw", "CHudCrosshair")):toBe(true)
		ragdoll:Fall(ply)
		hurtLegs(server, "Gordon")
		sync(0.5)
		expect(paint(client)):toEqual({ "Your legs give way" })

		local ruServer, ruClient, gordon, ru, _, ruSync = join({ getUpDelay = 0 }, "ru")
		ru:Fall(gordon)
		ruSync()
		expect(paint(ruClient)):toEqual({ "SPACE — встать" })
		ruClient.bindings["+jump"] = "mouse5"
		ruClient:SetConVar("nc_language", "en")
		expect(paint(ruClient)):toEqual({ "Press MOUSE5 to get up" })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(ruServer:Errors()):toEqual({})
		expect(ruClient:Errors()):toEqual({})
	end)
end)
