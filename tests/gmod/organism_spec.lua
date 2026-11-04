-- Organism module: bodies, injuries, physiology, treatments, death, giving up, the
-- schedule of the simulation, replication and the console, with the real gamemode files
-- in emulated realms. Chance is fixed through organism.Random.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

-- Records the events of the organism and of deaths; refuses giving up when asked to.
local RECORDER = {
	[MODULES .. "recorder/module.lua"] = "return { id = 'recorder', files = { sv = { 'sv_recorder.lua' } } }",
	[MODULES .. "recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.log = {}
		M.caps = {}
		local function name(ent)
			return IsValid(ent) and ent:IsPlayer() and ent:Nick() or "-"
		end
		function M:Start(ctx)
			local log = function(text) self.log[#self.log + 1] = text end
			ctx:On("organism.died", function(ply, cause, killer)
				log("died " .. ply:Nick() .. " " .. cause .. " " .. name(killer))
			end)
			ctx:On("organism.unconscious", function(ply, value) log("unconscious " .. ply:Nick() .. " " .. tostring(value)) end)
			ctx:On("organism.wounded", function(ply, hit) log("wounded " .. ply:Nick() .. " " .. hit.kind) end)
			ctx:On("organism.treated", function(ply, kind) log("treated " .. ply:Nick() .. " " .. kind) end)
			ctx:On("organism.capabilities", function(ply, caps) self.caps[ply] = caps.moveSpeedMul end)
			ctx:On("players.died", function(ply, _, attacker) log("players.died " .. ply:Nick() .. " " .. name(attacker)) end)
			ctx:On("organism.canSuccumb", function() if self.refuse then return false end end)
		end
		function M:Take()
			local log = self.log
			self.log = {}
			return log
		end
	]],
}

local function boot(settings)
	local server = Env.Server({ files = RECORDER, modules = { "players", "organism" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.organism = settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local organism = NC.Modules:Instance("organism")
	organism.Random = function() return 0.99 end -- rolls of bad luck fail
	return server, organism, NC.Modules:Instance("players"), NC.Modules:Instance("recorder")
end

-- Advances game time in ticks of 0.1 s.
local function run(server, seconds)
	for _ = 1, math.floor(seconds * 10 + 0.5) do
		server:Advance(0.1)
	end
end

-- Puts a player into the game at `pos` facing along x (yaw 0) or back (yaw 180).
local function place(server, players, ply, pos, yaw)
	server:Advance(0.1)
	players:Deploy(ply)
	ply:SetPos(pos or Vector(0, 0, 0))
	ply:SetEyeAngles(Angle(0, yaw or 0, 0))
	return ply
end

local function deploy(server, players, name, pos, yaw)
	return place(server, players, Env.Bot(server, { name = name }), pos, yaw)
end

-- A bullet from the eyes of `shooter` at a bone of `victim` (plus `offset`).
local function shot(shooter, victim, bone, offset)
	local aim = victim:GetBonePosition(victim:LookupBone("ValveBiped.Bip01_" .. bone))
	if offset ~= nil then
		aim = aim + offset
	end
	local dir = (aim - shooter:EyePos()):GetNormalized()
	return { kind = "bullet", attacker = shooter, inflictor = shooter, pos = aim - dir * 8, dir = dir,
		force = dir * 1000 }
end

local function has(list, item)
	for _, value in ipairs(list) do
		if value == item then
			return true
		end
	end
	return false
end

-- Two players 200 units apart, facing each other.
local function duel(server, players)
	local victim = deploy(server, players, "Bob", Vector(0, 0, 0), 0)
	local shooter = deploy(server, players, "Al", Vector(200, 0, 0), 180)
	return victim, shooter
end

describe("organism", function()
	it("gives every deployed player a healthy body and only its owner the vitals", function()
		local server, organism, players = boot()
		local client, gordon = Env.Join(server, { name = "Gordon" })
		local other = Env.Join(server, { name = "Alyx" })
		place(server, players, gordon)
		server:Advance(0.2)
		Env.Flush(server, client, other)
		expect(organism:IsSimulated(gordon)):toBe(true)
		local caps = organism:Capabilities(gordon)
		expect(caps.alive and caps.canStand and caps.canJump and caps.canSprint):toBe(true)
		expect(caps.moveSpeedMul):toBe(1)
		local vitals = organism:Vitals(gordon)
		expect(vitals.blood):toBe(1)
		expect(vitals.pulse):toBe(72)
		expect(vitals.spo2):toBe(98)
		expect(vitals.caps):toBe(63)

		local mine = client:Get("NC").Modules:Instance("organism")
		expect(mine:Vitals().pulse):toBe(72)
		expect(mine:Capabilities().canSprint):toBe(true)
		expect(mine:IsUnconscious()):toBe(false)
		expect(mine:SuccumbIn()):toBeNil()
		expect(other:Get("NC").Modules:Instance("organism"):Vitals()):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("wounds and bleeds from a pistol round through the chest without killing at once", function()
		local server, organism, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local report = organism:Injure(victim, shot(shooter, victim, "Spine2", Vector(0, -3, 3)))
		expect(report.fatal):toBeNil()
		expect(has(report.structures, "lung_r")):toBe(true)
		expect(report.wounds >= 3):toBe(true)
		expect(recorder:Take()):toEqual({ "wounded Bob bullet" })
		local st = organism:State(victim)
		expect(st.leak.r > 0):toBe(true)
		expect(st.leak.l):toBe(0)
		run(server, 90)
		expect(victim:Alive()):toBe(true)
		expect(st.pneumo.r > 0.5):toBe(true)
		expect(st.blood < st.volume):toBe(true)
		expect(organism.HasStatus(organism:Vitals(victim), "breathless")):toBe(true)
		expect(organism:Capabilities(victim).canStand):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("kills at once with a shot through the head and credits the shooter", function()
		local server, organism, players, recorder = boot()
		local victim, shooter = duel(server, players)
		local report = organism:Injure(victim, shot(shooter, victim, "Head1", Vector(0, 0, 2)))
		expect(report.fatal):toBe("head")
		expect(organism:IsDead(victim)):toBe(true)
		expect(organism:Capabilities(victim).alive):toBe(false)
		expect(organism:Vitals(victim).pulse):toBe(0)
		server:Advance(0.1)
		expect(victim:Alive()):toBe(false)
		expect(players:State(victim)):toBe("dead")
		expect(recorder:Take()):toEqual({ "wounded Bob bullet", "died Bob head Al", "players.died Bob Al" })
		expect(organism:Injure(victim, shot(shooter, victim, "Spine2"))):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("bleeds out from a femoral artery unless a tourniquet goes on", function()
		local server, organism, players = boot()
		local left = deploy(server, players, "Left", Vector(0, 0, 0))
		local right = deploy(server, players, "Right", Vector(0, 300, 0))
		for _, ply in ipairs({ left, right }) do
			server:Command("nc_hurt", nil, { ply:Nick(), "bullet", "femoral_artery_l" })
		end
		server:Advance(0.1)
		expect(organism:State(left).external > 900):toBe(true)
		run(server, 20)
		expect(organism:ApplyTreatment(right, "tourniquet", { limb = "leg_l" })):toBe(true)
		expect({ organism:ApplyTreatment(right, "tourniquet", { limb = "leg_l" }) }):toEqual({ false, "already" })
		run(server, 220)
		local bled, saved = organism:State(left), organism:State(right)
		expect(bled.unconscious):toBe(true)
		expect(bled.blood < 0.55 * bled.volume):toBe(true)
		expect(saved.unconscious):toBe(false)
		expect(saved.external):toBe(0)
		expect(saved.blood > 0.85 * saved.volume):toBe(true)
		expect(organism.HasStatus(organism:Vitals(right), "tourniquet")):toBe(true)
		expect(organism:Capabilities(right).canSprint):toBe(false)

		-- Packed and pressed, the wound stays almost dry when the tourniquet comes off.
		expect(organism:ApplyTreatment(right, "hemostatic", { limb = "leg_l" })):toBe(true)
		expect(organism:ApplyTreatment(right, "tourniquet_off", { limb = "leg_l" })):toBe(true)
		run(server, 5)
		local artery
		for _, w in ipairs(organism:Wounds(right)) do
			if w.structure == "femoral_artery_l" then
				artery = w
			end
		end
		expect(artery.bandage):toBe(0.9)
		expect(artery.flow < 60):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("drowns: loses consciousness, then the heart stops and the brain dies", function()
		local server, organism, players, recorder = boot({ brainDeathTime = 60 })
		local ply = deploy(server, players, "Bob")
		ply.waterLevel = 3
		run(server, 40)
		expect(organism:IsUnconscious(ply)):toBe(false)
		run(server, 60)
		expect(organism:IsUnconscious(ply)):toBe(true)
		expect(recorder:Take()):toEqual({ "unconscious Bob true" })
		run(server, 30)
		expect(organism:State(ply).rhythm):notToBe("sinus")
		run(server, 120)
		expect(ply:Alive()):toBe(false)
		expect(recorder:Take()):toEqual({ "died Bob brain -", "players.died Bob -" })
		expect(server:Errors()):toEqual({})
	end)

	it("builds tension in a chest that leaks through a valve and lets it out with a needle", function()
		local server, organism, players = boot()
		local victim, shooter = duel(server, players)
		organism:Injure(victim, shot(shooter, victim, "Spine2", Vector(0, -3, 3)))
		local st = organism:State(victim)
		st.valve.r = true
		run(server, 240)
		expect(st.tension.r > 0.5):toBe(true)
		expect(st.map < 60):toBe(true)
		expect({ organism:ApplyTreatment(victim, "needle", { side = "x" }) }):toEqual({ false, "target" })
		expect({ organism:ApplyTreatment(victim, "needle", { side = "l" }) }):toEqual({ false, "nothing" })
		expect(organism:ApplyTreatment(victim, "needle")):toBe(true)
		expect(st.tension.r):toBe(0)
		run(server, 30)
		expect(st.map > 80):toBe(true)
		expect(organism:ApplyTreatment(victim, "chest_tube", { side = "r" })):toBe(true)
		expect({ organism:ApplyTreatment(victim, "chest_tube", { side = "r" }) }):toEqual({ false, "already" })
		run(server, 120)
		expect(st.pneumo.r < 0.2):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("takes running and jumping away with a broken leg; a splint gives some back", function()
		local server, organism, players, recorder = boot()
		local ply = deploy(server, players, "Bob")
		run(server, 0.5)
		expect(recorder.caps[ply]):toBe(1)
		server:Command("nc_hurt", nil, { "Bob", "bullet", "femur_l" })
		local caps = organism:Capabilities(ply)
		expect(caps.canStand):toBe(true)
		expect(caps.canSprint):toBe(false)
		expect(caps.canJump):toBe(false)
		expect(caps.moveSpeedMul < 0.5):toBe(true)
		expect(recorder.caps[ply]):toBe(caps.moveSpeedMul)
		expect(organism.HasStatus(organism:Vitals(ply), "fractureLegL")):toBe(true)
		local before = caps.moveSpeedMul
		expect(organism:ApplyTreatment(ply, "splint", { limb = "leg_l" })):toBe(true)
		expect({ organism:ApplyTreatment(ply, "splint", { limb = "leg_l" }) }):toEqual({ false, "already" })
		expect({ organism:ApplyTreatment(ply, "splint", { limb = "arm_r" }) }):toEqual({ false, "nothing" })
		expect(caps.moveSpeedMul > before):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("breaks bones by the speed of a fall and dies of a very high one", function()
		local server, organism, players, recorder = boot()
		organism.Random = function() return 0.5 end
		local low, high, deadly = deploy(server, players, "Low"), deploy(server, players, "High"),
			deploy(server, players, "Deadly")
		expect(organism:Injure(low, { kind = "fall", speed = 300 }).wounds):toBe(0)
		local report = organism:Injure(high, { kind = "fall", speed = 600 })
		expect(report.fractures):toBe(5)
		expect(report.fatal):toBeNil()
		local st = organism:State(high)
		expect(st.fractures.foot_bones_l ~= nil and st.fractures.tibia_r ~= nil and st.fractures.pelvis ~= nil)
			:toBe(true)
		expect(st.fractures.tibia_r.severity):toBe(2)
		expect(organism:Capabilities(high).canStand):toBe(false)
		expect(organism:Injure(deadly, { kind = "fall", speed = 1500 }).fatal):toBe("fall")
		server:Advance(0.1)
		expect(deadly:Alive()):toBe(false)
		expect(has(recorder:Take(), "died Deadly fall -")):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("sends the fragments of a blast through the shield, or none when they fly on their own", function()
		local server, organism, players = boot()
		organism.Random = function() return 0.5 end
		local near, far = deploy(server, players, "Near"), deploy(server, players, "Far", Vector(0, 300, 0))
		local met = 0
		local function shield()
			met = met + 1
		end
		local pos = near:GetPos() + Vector(150, 0, 30)
		organism:Injure(near, { kind = "blast", amount = 150, pos = pos, dir = Vector(-1, 0, 0), shield = shield })
		expect(met):toBe(8)
		met = 0
		organism:Injure(far, { kind = "blast", amount = 150, pos = far:GetPos() + Vector(150, 0, 30),
			dir = Vector(-1, 0, 0), shield = shield, fragments = 0 })
		expect(met):toBe(0)
		expect(organism:State(far).concussion > 0):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("lets an unconscious player give up after the delay unless the mode forbids it", function()
		local server, organism, players, recorder = boot()
		local client, gordon = Env.Join(server, { name = "Gordon" })
		place(server, players, gordon)
		local mine = client:Get("NC").Modules:Instance("organism")
		local function sync() -- the clock of the client follows the server
			client:Advance(server.time - client.time)
			Env.Flush(server, client)
		end
		local function press()
			local blocked = client:Call("PlayerBindPress", gordon, "+reload", true, 0)
			Env.Flush(server, client)
			return blocked
		end
		expect(press()):toBeNil()
		organism:_Knockout(organism:State(gordon), 60)
		run(server, 1)
		sync()
		expect(mine:IsUnconscious()):toBe(true)
		expect(mine:SuccumbIn() > 3 and mine:SuccumbIn() < 5):toBe(true)
		expect(press()):toBe(true)
		expect(gordon:Alive()):toBe(true)
		run(server, 5)
		sync()
		expect(mine:SuccumbIn()):toBe(0)
		recorder.refuse = true
		press()
		expect(organism:IsDead(gordon)):toBe(false)
		recorder.refuse = false
		press()
		expect(organism:IsDead(gordon)):toBe(true)
		server:Advance(0.1)
		expect(gordon:Alive()):toBe(false)
		expect(has(recorder:Take(), "died Gordon succumb -")):toBe(true)
		expect(organism:Succumb(gordon)):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("credits the death to whoever caused most of the injuries", function()
		local server, organism, players, recorder = boot({ brainDeathTime = 30 })
		local victim = deploy(server, players, "Bob")
		local light = deploy(server, players, "Light", Vector(200, 0, 0), 180)
		local heavy = deploy(server, players, "Heavy", Vector(200, 50, 0), 180)
		organism:Injure(victim, shot(light, victim, "L_UpperArm", Vector(0, 1, -5)))
		local hit = shot(heavy, victim, "Spine2", Vector(0, 0.8, 4))
		organism:Injure(victim, hit)
		recorder:Take()
		run(server, 240)
		expect(victim:Alive()):toBe(false)
		expect(recorder:Take()):toEqual({ "unconscious Bob true", "died Bob brain Heavy", "players.died Bob Heavy" })
		expect(server:Errors()):toEqual({})
	end)

	it("marks the body dead when something else kills the player and forgets bodies outside the game", function()
		local server, organism, players, recorder = boot()
		local a, b, c = deploy(server, players, "A"), deploy(server, players, "B"), deploy(server, players, "C")
		Env.Kill(a)
		expect(organism:IsDead(a)):toBe(true)
		expect(organism:State(a).cause):toBe("killed")
		expect(recorder:Take()):toEqual({ "players.died A A" })
		players:MakeSpectator(b)
		expect(organism:IsSimulated(b)):toBe(false)
		expect(organism:Vitals(b)):toBeNil()
		Env.Leave(server, c)
		expect(organism:IsSimulated(c)):toBe(false)
		players:Deploy(a)
		expect(organism:IsDead(a)):toBe(false)
		expect(organism:Capabilities(a).alive):toBe(true)
		run(server, 1)
		expect(#organism.list):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("treats: dressings, drugs, fluids, resuscitation and the reasons it cannot", function()
		local server, organism, players = boot()
		local ply = deploy(server, players, "Bob")
		local function try(kind, opts)
			return { organism:ApplyTreatment(ply, kind, opts) }
		end
		expect(try("bogus")):toEqual({ false, "unknown" })
		expect(try("bandage")):toEqual({ false, "nothing" })
		expect(try("tourniquet")):toEqual({ false, "target" })
		expect(try("cpr")):toEqual({ false, "pulse" })
		expect(try("defib")):toEqual({ false, "pulse" })
		expect(try("suction")):toEqual({ false, "nothing" })

		server:Command("nc_hurt", nil, { "Bob", "bullet", "femur_l" })
		local st = organism:State(ply)
		run(server, 10)
		local pain = st.pain
		expect(try("morphine")):toEqual({ true })
		run(server, 120)
		expect(st.pain < pain * 0.8):toBe(true)
		local blood = st.blood
		expect(try("blood", { ml = 500, seconds = 10 })):toEqual({ true })
		run(server, 12)
		expect(st.blood > blood + 300):toBe(true)

		-- A fibrillating heart: compressions move some blood, a shock may restart it.
		organism:_Arrest(st, "vf")
		expect(try("cpr")):toEqual({ true })
		server:Advance(0.1)
		expect(st.map > 10):toBe(true)
		expect(try("defib")):toEqual({ true })
		expect(st.rhythm):toBe("vf")
		organism.Random = function() return 0 end
		expect(try("defib")):toEqual({ true })
		expect(st.rhythm):toBe("sinus")
		organism:_Arrest(st, "asystole")
		expect(try("defib")):toEqual({ false, "not_shockable" })

		expect(try("heal")):toEqual({ true })
		local fresh = organism:State(ply)
		expect(fresh):notToBe(st)
		expect(#fresh.wounds):toBe(0)
		expect(fresh.rhythm):toBe("sinus")
		Env.Kill(ply)
		expect(try("bandage")):toEqual({ false, "dead" })
		expect(server:Errors()):toEqual({})
	end)

	it("simulates every body config.rate times a second, spread over the ticks", function()
		local server, organism, players = boot()
		local bodies = {}
		for i = 1, 20 do
			bodies[i] = deploy(server, players, "Bot" .. i)
		end
		local counts = {}
		organism:SetStep("count", function(_, st) counts[st.ply] = (counts[st.ply] or 0) + 1 end)
		expect(organism:Steps()[#organism:Steps()]):toBe("count")
		local busiest = 0
		for _ = 1, 66 do
			local before = 0
			for _, n in pairs(counts) do
				before = before + n
			end
			server:Advance(1 / 66)
			local after = 0
			for _, n in pairs(counts) do
				after = after + n
			end
			busiest = math.max(busiest, after - before)
		end
		for _, ply in ipairs(bodies) do
			expect(counts[ply] >= 9 and counts[ply] <= 11):toBe(true)
		end
		expect(busiest <= 5):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("describes, hurts, treats and heals bodies from the console", function()
		local server, organism, players = boot()
		deploy(server, players, "Bob")
		local function command(name, args)
			local before = #server.console
			server:Command(name, nil, args)
			local lines = {}
			for i = before + 1, #server.console do
				lines[#lines + 1] = server.console[i]
			end
			return table.concat(lines, "\n")
		end
		expect(command("nc_organism", { "Bob" })):toContain("Bob: alive")
		expect(command("nc_hurt", { "Bob", "slash", "arm_l" })):toContain("nc_hurt: slash Bob: 1 wounds")
		expect(command("nc_hurt", { "Bob", "bogus" })):toContain("unknown kind 'bogus'")
		expect(command("nc_hurt", { "Bob", "bullet", "elbow" })):toContain("unknown part 'elbow'")
		expect(command("nc_hurt", { "Nobody" })):toContain("no player matches 'Nobody'")
		expect(command("nc_organism", { "bob" })):toContain("slash arm_l")
		expect(command("nc_treat", { "Bob", "bandage", "arm_l" })):toContain("nc_treat: bandage Bob: done")
		expect(command("nc_treat", { "Bob", "bandage", "leg_r" })):toContain("nc_treat: bandage Bob: nothing")
		expect(command("nc_treat", { "Bob" })):toContain("nc_treat: kinds:")
		expect(command("nc_heal", { "#" .. organism.list[1].ply:EntIndex() })):toContain("nc_heal: Bob is healthy")
		expect(#organism:Wounds(organism.list[1].ply)):toBe(0)
		expect(server:Errors()):toEqual({})
	end)
	it("reads hits, bones and breathing from the carrier of a body", function()
		local server, organism, players = boot()
		local victim = deploy(server, players, "Bob", Vector(0, 0, 0), 0)
		local rag = server:Get("ents").Create("prop_ragdoll")
		rag:SetModel(victim:GetModel())
		rag:SetPos(Vector(-60, 0, 0))
		rag:Spawn()
		World.LayRagdoll(rag) -- on its back, the head towards -x
		expect(organism:Carrier(victim)):toBeNil()
		expect(organism:BodyEntity(victim)):toBe(victim)
		expect(organism:PlayerOf(rag)):toBeNil()
		expect(organism:SetCarrier(victim, rag)):toBe(true)
		expect(organism:Carrier(victim)):toBe(rag)
		expect(organism:BodyEntity(victim)):toBe(rag)
		expect(organism:PlayerOf(rag)):toBe(victim)
		expect(organism:PlayerOf(victim)):toBeNil()

		-- From above into the lying chest and face; the back of a body on its face.
		local chest = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_Spine2"))
		local s, region, side = organism:Locate(victim, chest.x, chest.y, chest.z + 40, 0, 0, -1)
		expect(s.seg):toBe("torso")
		expect(region):toBe("chest")
		expect(side):toBe("front")
		local head = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_Head1"))
		s, region = organism:Locate(victim, head.x + 1, head.y, head.z + 40, 0, 0, -1)
		expect(s.seg):toBe("head")
		expect(region):toBe("face")
		-- The head turned to the side: the face is where its eyes look.
		rag:GetPhysicsObjectNum(10):SetAngles(Angle(0, 90, -90))
		server:Advance(0.01)
		s, region = organism:Locate(victim, head.x + 1, head.y + 40, head.z, 0, -1, 0)
		expect(region):toBe("face")
		s, region, side = organism:Locate(victim, head.x - 1, head.y, head.z + 40, 0, 0, -1)
		expect(region):toBe("head")
		expect(side):toBe("right")
		-- Where the player stands there is no body any more.
		expect(organism:Locate(victim, -40, 0, 51.5, 1, 0, 0)):toBeNil()
		-- A hit without a point lands on the middle of the carrier.
		local px, py, pz = organism._Ray(organism:State(victim), { kind = "blunt" })
		expect({ px, py, pz }):toEqual({ -60, 0, 6 })

		-- Breathing: the head of the carrier under water drowns the body.
		server.pointContents = function(pos)
			return pos.z < 10 and server:Get("CONTENTS_WATER") or 0
		end
		run(server, 0.5)
		expect(organism:State(victim).water):toBe(3)
		expect(organism:State(victim).drowning):toBe(true)
		organism:SetCarrier(victim, nil)
		expect(organism:PlayerOf(rag)):toBeNil()
		run(server, 0.5)
		expect(organism:State(victim).water):toBe(0)

		local prone = server:Get("ents").Create("prop_ragdoll")
		prone:SetModel(victim:GetModel())
		prone:Spawn()
		World.LayRagdoll(prone, true)
		organism:SetCarrier(victim, prone)
		expect(organism:PlayerOf(prone)):toBe(victim)
		chest = prone:GetBonePosition(prone:LookupBone("ValveBiped.Bip01_Spine2"))
		s, region, side = organism:Locate(victim, chest.x, chest.y, chest.z + 40, 0, 0, -1)
		expect(region):toBe("chest")
		expect(side):toBe("back")
		-- A carrier that is gone, or a new body, carries nothing.
		Env.Remove(server, prone)
		expect(organism:Carrier(victim)):toBeNil()
		expect(organism:PlayerOf(prone)):toBeNil()
		organism:SetCarrier(victim, rag)
		players:Deploy(victim)
		expect(organism:Carrier(victim)):toBeNil()
		expect(organism:PlayerOf(rag)):toBeNil()
		expect(function() organism:SetCarrier(victim, World.NULL) end):toFail("valid entity")
		expect(server:Errors()):toEqual({})
	end)

	it("traces rays and measures distances in agreement with the point test of the shapes", function()
		local server, organism, players = boot()
		local ply = deploy(server, players, "Bob", Vector(0, 0, 0), 30)
		local structures = organism.body.structures
		local seed = 4242
		local function random() -- Park-Miller: the same rays on every run
			seed = seed * 16807 % 2147483647
			return seed / 2147483647
		end
		local function within(s, x, y, z, limit)
			return organism:_Distance(s, x, y, z) <= limit
		end
		local inside = 0
		for _ = 1, 150 do
			-- A ray from 100 units away through a point of the body.
			local tx, ty, tz = (random() - 0.5) * 24, (random() - 0.5) * 24, 2 + random() * 66
			local yaw, pitch = random() * 2 * math.pi, (random() - 0.5) * math.pi
			local dx, dy, dz = math.cos(pitch) * math.cos(yaw), math.cos(pitch) * math.sin(yaw), math.sin(pitch)
			local ox, oy, oz = tx - dx * 100, ty - dy * 100, tz - dz * 100
			local n = organism:Cast(ply, ox, oy, oz, dx, dy, dz, 0)
			local trace = organism.trace
			for t = 60, 140, 0.25 do
				local x, y, z = ox + dx * t, oy + dy * t, oz + dz * t
				local pass
				for i = 1, n do
					if t > trace.t0[i] and t < trace.t1[i] then
						pass = trace.structure[i]
					end
				end
				-- A point in a pass is in its structure; a point deep in a solid one is in a pass.
				if pass ~= nil then
					expect(within(pass, x, y, z, 1e-6)):toBe(true)
				end
				for _, s in ipairs(structures) do
					if s.shell == nil and within(s, x, y, z, -1e-3) then
						expect(pass ~= nil):toBe(true)
						inside = inside + 1
						break
					end
				end
			end
		end
		expect(inside > 1000):toBe(true)

		-- The distance from a path to a structure is the nearest of its points (spheres too).
		local worst = 0
		for _, s in ipairs(structures) do
			for _ = 1, 4 do
				local px, py, pz = (random() - 0.5) * 40, (random() - 0.5) * 40, random() * 70
				local qx, qy, qz = (random() - 0.5) * 40, (random() - 0.5) * 40, random() * 70
				local steps = 400
				local nearest = math.huge
				for i = 0, steps do
					local f = i / steps
					local x, y, z = px + (qx - px) * f, py + (qy - py) * f, pz + (qz - pz) * f
					nearest = math.min(nearest, organism:_Distance(s, x, y, z))
				end
				local length = math.sqrt((qx - px) ^ 2 + (qy - py) ^ 2 + (qz - pz) ^ 2)
				local d = organism:_PathDistance(s, px, py, pz, qx, qy, qz)
				expect(d <= nearest + 1e-6):toBe(true)
				worst = math.max(worst, (nearest - d) / (length / steps))
			end
		end
		expect(worst <= 0.5 + 1e-6):toBe(true)
		expect(server:Errors()):toEqual({})
	end)
end)
