-- Ragdoll control: the head of a fallen body follows the view within the neck, the body
-- crawls with the movement keys and the hands hold on to the world and to objects with the
-- attack keys, with the real gamemode files in an emulated server.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN
local CHEST = "ValveBiped.Bip01_Spine2"
local L_HAND = "ValveBiped.Bip01_L_Hand"
local R_HAND = "ValveBiped.Bip01_R_Hand"

-- Records what the control tells and answers its question.
local RECORDER = {
	[MODULES .. "recorder/module.lua"] = "return { id = 'recorder', files = { sv = { 'sv_recorder.lua' } } }",
	[MODULES .. "recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.events = {}
		function M:Start(ctx)
			for _, name in ipairs({ "ragdoll_control.grabbed", "ragdoll_control.released" }) do
				ctx:On(name, function(ply, hand, ent) self.events[#self.events + 1] = { name, ply, hand, ent } end)
			end
			ctx:On("ragdoll_control.canGrab", function(ply, ent)
				self.asked = { ply, ent }
				return self.canGrab
			end)
		end
		function M:Take()
			local out = self.events
			self.events = {}
			return out
		end
	]],
}

-- A flat floor at z = 0: a line hits it where it crosses it, as the world, or as `ent`
-- (its physics bone `bone`) lying flat on it. Lines are recorded in server.lines.
local function floor(server, ent, bone)
	server.lines = {}
	server.traceLine = function(trace)
		local a, b = trace.start, trace.endpos
		server.lines[#server.lines + 1] = { start = Vector(a), endpos = Vector(b), mask = trace.mask,
			filter = { trace.filter[1], trace.filter[2] } }
		if a.z >= 0 and b.z <= 0 and a.z ~= b.z then
			local t = a.z / (a.z - b.z)
			return { Hit = true, HitWorld = ent == nil, StartSolid = false, Fraction = t, PhysicsBone = bone or 0,
				HitPos = Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0), Entity = ent or World.WORLD }
		end
		return { Hit = false, HitWorld = false, StartSolid = false, Fraction = 1, HitPos = Vector(b), Entity = World.NULL }
	end
end

-- The server runs for `seconds` in ticks of 0.1 s.
local function run(server, seconds)
	for _ = 1, math.floor(seconds / 0.1 + 0.5) do
		server:Advance(0.1)
	end
end

-- Bob lies on his back at the origin, his head towards -x and his face up: the left hand
-- at (0.5, 8, 8), the right one at (0.5, -8, 8), the eyes at (-27, 0, 10.1).
local function boot(settings)
	local server = Env.Server({ files = RECORDER,
		modules = { "players", "organism", "damage", "ragdoll", "ragdoll_control" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.ragdoll_control = settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	floor(server)
	local NC = server:Get("NC")
	local s = { server = server, control = NC.Modules:Instance("ragdoll_control"),
		ragdoll = NC.Modules:Instance("ragdoll"), organism = NC.Modules:Instance("organism"),
		players = NC.Modules:Instance("players"), recorder = NC.Modules:Instance("recorder") }
	s.organism.Random = function() return 0.5 end
	s.ply = Env.Bot(server, { name = "Bob" })
	server:Advance(0.1)
	s.players:Deploy(s.ply)
	s.ply:SetPos(Vector(0, 0, 0))
	s.ply:SetEyeAngles(Angle(0, 0, 0))
	s.body = s.ragdoll:Fall(s.ply)
	World.LayRagdoll(s.body.ent)
	return s
end

local function near(a, b, epsilon)
	return (a - b):Length() <= (epsilon or 1e-6)
end

-- The angular velocity of a physics object in the world frame.
local function spin(phys)
	return phys:LocalToWorldVector(phys:GetAngleVelocity())
end

-- `ply` looks from `from` at `to`.
local function lookAt(ply, from, to)
	local dir = (to - from):GetNormalized()
	ply:SetEyeAngles(Angle(math.deg(math.asin(-dir.z)), math.deg(math.atan2(dir.y, dir.x)), 0))
end

local function eyes(body)
	return body.ent:GetAttachment(1).Pos
end

-- The body comes to rest (no keys), then lies `drop` units lower.
local function settle(s, drop)
	Env.RunCommand(s.server, s.ply, 0, 0, 0)
	run(s.server, 1.5)
	World.MoveRagdoll(s.body.ent, Vector(0, 0, -(drop or 0)))
end

-- Bob looks at the floor right below his `bone` and holds the attack keys `keys`.
local function reachDown(s, bone, keys)
	local pos = s.body.phys[bone]:GetPos()
	lookAt(s.ply, eyes(s.body), Vector(pos.x, pos.y, 0))
	Env.RunCommand(s.server, s.ply, keys, 0, 0)
	run(s.server, 0.1)
end

local function names(events)
	local out = {}
	for i, entry in ipairs(events) do
		out[i] = entry[1]:gsub("^ragdoll_control%.", "") .. " " .. entry[3]
	end
	return out
end

describe("ragdoll_control", function()
	it("turns the head where the player looks, within the neck, and holds it there", function()
		local s = boot()
		local server, ply, head = s.server, s.ply, s.body.head
		-- Face up; the player looks 45 degrees towards the feet (+x): about +y, at most 240 degrees/s.
		ply:SetEyeAngles(Angle(-45, 0, 0))
		run(server, 0.1)
		expect(near(spin(head), Vector(0, 240, 0), 1e-6)):toBe(true)
		-- Nearly there it turns slower: 10 degrees off, 80 degrees/s.
		ply:SetEyeAngles(Angle(-80, 0, 0))
		run(server, 0.1)
		expect(near(spin(head), Vector(0, 80, 0), 1e-6)):toBe(true)
		-- Looking there already: it holds still.
		ply:SetEyeAngles(Angle(-90, 0, 0))
		run(server, 0.1)
		expect(near(spin(head), Vector(0, 0, 0), 1e-6)):toBe(true)
		-- The neck: 60 degrees from where the head faced when the body fell (up, as the
		-- chest lies). A head on that edge does not turn further.
		head:SetAngles(Angle(-30, 0, 0))
		ply:SetEyeAngles(Angle(0, 0, 0))
		run(server, 0.1)
		expect(near(spin(head), Vector(0, 0, 0), 1e-6)):toBe(true)
		-- Back within the neck it turns again: from 60 degrees off up to 45, about -y.
		ply:SetEyeAngles(Angle(-45, 0, 0))
		run(server, 0.1)
		expect(near(spin(head), Vector(0, -120, 0), 1e-6)):toBe(true)
		-- The neck turns with the chest: the body rolled onto its side faces +y.
		head:SetAngles(Angle(-90, 0, 0))
		World.TurnRagdoll(s.body.ent, Angle(-90, 0, 0), Angle(0, 90, 0))
		ply:SetEyeAngles(Angle(0, 0, 0)) -- +x: 90 degrees off, to 60 of it
		run(server, 0.1)
		local gaze = s.body.ent:GetAttachment(1).Ang:Forward()
		expect(near(gaze, Vector(0, 1, 0), 1e-6)):toBe(true)
		expect(near(spin(head), Vector(0, 0, -240), 1e-6)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("crawls along the ground where the player looks, slower with fewer arms, not in the air", function()
		local s = boot()
		local server, ply, body = s.server, s.ply, s.body
		local chest, pelvis = body.phys[CHEST], body.pelvis
		ply:SetEyeAngles(Angle(20, 90, 0)) -- towards +y, a little down
		Env.RunCommand(server, ply, IN.FORWARD, 200, 0)
		run(server, 0.1)
		expect(near(chest:GetVelocity(), Vector(0, 40, 0))):toBe(true)
		expect(near(pelvis:GetVelocity(), Vector(0, 40, 0))):toBe(true)
		-- The chest lies on something: a line 24 units down, past the body and its player.
		local line = server.lines[#server.lines]
		expect(line.start):toEqual(chest:GetPos())
		expect(line.endpos - line.start):toEqual(Vector(0, 0, -24))
		expect(line.mask):toBe(server:Get("MASK_SOLID"))
		expect(line.filter):toEqual({ ply, body.ent })
		local start = body.ent:GetPos()
		run(server, 1)
		local moved = body.ent:GetPos() - start
		expect(moved.y > 10 and math.abs(moved.x) < 1e-6 and moved.z == 0):toBe(true)
		-- Forward and to the right (+x) at the same speed.
		Env.RunCommand(server, ply, IN.FORWARD + IN.MOVERIGHT, 200, 200)
		run(server, 0.1)
		local diagonal = 40 / math.sqrt(2)
		expect(near(chest:GetVelocity(), Vector(diagonal, diagonal, 0))):toBe(true)
		-- Backwards with one arm: 0.65 of the speed; with none: 0.3.
		server:Command("nc_hurt", nil, { "Bob", "bullet", "humerus_l" })
		Env.RunCommand(server, ply, IN.BACK, -200, 0)
		run(server, 0.1)
		expect(near(chest:GetVelocity(), Vector(0, -26, 0))):toBe(true)
		server:Command("nc_hurt", nil, { "Bob", "bullet", "humerus_r" })
		run(server, 0.1)
		expect(near(chest:GetVelocity(), Vector(0, -12, 0))):toBe(true)
		-- In the air there is nothing to crawl on.
		settle(s, -100)
		Env.RunCommand(server, ply, IN.FORWARD, 200, 0)
		run(server, 0.1)
		expect(chest:GetVelocity()):toEqual(Vector(0, 0, 0))
		expect(server:Errors()):toEqual({})
	end)

	it("reaches a hand where the player looks and holds on to the world until the key goes up", function()
		local s = boot()
		local server, ply, body, control, recorder = s.server, s.ply, s.body, s.control, s.recorder
		local hand = body.phys[L_HAND]
		-- The floor 22 units beyond the left hand: it reaches there, 12 times the distance per second.
		local spot = Vector(0.5, 30, 0)
		lookAt(ply, eyes(body), spot)
		Env.RunCommand(server, ply, IN.ATTACK, 0, 0)
		run(server, 0.1)
		local line = server.lines[#server.lines]
		expect(line.start):toEqual(eyes(body))
		expect(near(line.endpos - line.start, ply:GetAimVector() * 48)):toBe(true)
		expect(line.filter):toEqual({ ply, body.ent })
		expect(near(hand:GetVelocity(), (spot - hand:GetPos()) * 12, 1e-3)):toBe(true)
		expect(body.phys[R_HAND]:GetVelocity():Length() < 5):toBe(true)
		expect(#server.welds):toBe(0)
		-- Not faster than 300 units/s: the floor out of reach, the hand goes for the end of the line.
		lookAt(ply, eyes(body), Vector(-27, 100, 0))
		run(server, 0.1)
		line = server.lines[#server.lines]
		expect(near(hand:GetVelocity(), (line.endpos - hand:GetPos()):GetNormalized() * 300, 1e-3)):toBe(true)
		-- Within 8 units of the floor below it the hand holds on.
		settle(s, 4)
		reachDown(s, L_HAND, IN.ATTACK)
		expect(#server.welds):toBe(1)
		local weld = server.welds[1]
		expect({ weld[1], weld[2], weld[3], weld[4], weld.forceLimit }):toEqual({ body.ent, World.WORLD, 5, 0, 0 })
		expect(recorder.asked):toEqual({ ply, World.WORLD })
		expect(names(recorder:Take())):toEqual({ "grabbed left" })
		expect(control:Grip(ply, "left")):toBe(World.WORLD)
		expect(control:Grip(ply, "right")):toBeNil()
		-- Holding on it neither reaches nor welds again.
		local before = hand:GetVelocity()
		run(server, 0.3)
		expect(#server.welds):toBe(1)
		expect(hand:GetVelocity():Length() <= before:Length()):toBe(true)
		-- The key goes up: the hand lets go.
		Env.RunCommand(server, ply, 0, 0, 0)
		run(server, 0.1)
		expect(weld[5]:IsMarkedForDeletion() or not weld[5]:IsValid()):toBe(true)
		expect(names(recorder:Take())):toEqual({ "released left" })
		expect(control:Grip(ply, "left")):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("holds on to what physics moves, not to players or what it does not move, and asks first", function()
		local s = boot()
		local server, ply, body, control, recorder = s.server, s.ply, s.body, s.control, s.recorder
		settle(s, 4)
		-- A board on the floor; a rule says no first: the hand keeps reaching.
		local board = Env.Spawn(server, { class = "prop_physics", pos = Vector(0, 0, 0) })
		World.AddPhysics(board)
		floor(server, board)
		s.recorder.canGrab = false
		reachDown(s, R_HAND, IN.ATTACK2)
		expect(recorder.asked):toEqual({ ply, board })
		expect(#server.welds):toBe(0)
		expect(body.phys[R_HAND]:GetVelocity():Length() > 0):toBe(true)
		recorder.canGrab = nil
		run(server, 0.1)
		expect(#server.welds):toBe(1)
		local weld = server.welds[1]
		expect({ weld[1], weld[2], weld[3], weld[4] }):toEqual({ body.ent, board, 7, 0 })
		expect(recorder:Take()[1]):toEqual({ "ragdoll_control.grabbed", ply, "right", board })
		expect(control:Grip(ply, "right")):toBe(board)
		Env.RunCommand(server, ply, 0, 0, 0)
		run(server, 0.1)
		-- Another body by the physics bone the line hit.
		local other = server:Get("ents").Create("prop_ragdoll")
		other:SetPos(Vector(50, 50, 0))
		other:Spawn()
		floor(server, other, 3)
		reachDown(s, R_HAND, IN.ATTACK2)
		expect(#server.welds):toBe(2)
		expect({ server.welds[2][2], server.welds[2][4] }):toEqual({ other, 3 })
		-- What it holds goes: the hand lets go and waits for another press.
		other:Remove()
		run(server, 0.2)
		expect(names(recorder:Take())):toEqual({ "released right", "grabbed right", "released right" })
		expect(control:Grip(ply, "right")):toBeNil()
		expect(#server.welds):toBe(2)
		Env.RunCommand(server, ply, 0, 0, 0)
		run(server, 0.1)
		-- A player, something physics does not move, a physics bone that is not there: no.
		local alice = Env.Bot(server, { name = "Alice" })
		local npc = Env.Spawn(server, { class = "npc_citizen" })
		for _, case in ipairs({ { alice, 0 }, { npc, 0 }, { board, 1 } }) do
			recorder.asked = nil
			floor(server, case[1], case[2])
			reachDown(s, R_HAND, IN.ATTACK2)
			expect(recorder.asked):toBeNil()
			Env.RunCommand(server, ply, 0, 0, 0)
			run(server, 0.1)
		end
		expect(#server.welds):toBe(2)
		expect(recorder:Take()):toEqual({})
		expect(server:Errors()):toEqual({})
	end)

	it("lets go when the arm fails or the grip breaks, and waits for another press", function()
		local s = boot({ grabRange = 12 })
		local server, ply, body, control, recorder = s.server, s.ply, s.body, s.control, s.recorder
		settle(s, 4)
		-- Between the hands both hold on.
		lookAt(ply, eyes(body), Vector(0.5, 0, 0))
		Env.RunCommand(server, ply, IN.ATTACK + IN.ATTACK2, 0, 0)
		run(server, 0.1)
		expect(names(recorder:Take())):toEqual({ "grabbed left", "grabbed right" })
		local left, right = server.welds[1][5], server.welds[2][5]
		-- A broken left arm lets go.
		server:Command("nc_hurt", nil, { "Bob", "bullet", "humerus_l" })
		run(server, 0.1)
		expect(names(recorder:Take())):toEqual({ "released left" })
		expect(left:IsMarkedForDeletion() or not left:IsValid()):toBe(true)
		expect(control:Grip(ply, "right")):toBe(World.WORLD)
		-- The right grip breaks: the hand waits for another press.
		right:Remove()
		run(server, 0.3)
		expect(names(recorder:Take())):toEqual({ "released right" })
		expect(#server.welds):toBe(2)
		Env.RunCommand(server, ply, 0, 0, 0)
		run(server, 0.1)
		Env.RunCommand(server, ply, IN.ATTACK + IN.ATTACK2, 0, 0)
		run(server, 0.1)
		expect(#server.welds):toBe(3)
		expect(server.welds[3][3]):toBe(7)
		expect(names(recorder:Take())):toEqual({ "grabbed right" })
		expect(server:Errors()):toEqual({})
	end)

	it("lets go when the body passes out, gets up or dies, and controls only a conscious fallen body", function()
		local s = boot()
		local server, ply, body, control, recorder, organism = s.server, s.ply, s.body, s.control, s.recorder,
			s.organism
		settle(s, 4)
		reachDown(s, L_HAND, IN.ATTACK)
		expect(names(recorder:Take())):toEqual({ "grabbed left" })
		-- Unconscious: the hand lets go, the head and the body are left alone.
		organism:_Knockout(organism:State(ply), 5)
		run(server, 0.1)
		expect(body.state):toBe("unconscious")
		expect(names(recorder:Take())):toEqual({ "released left" })
		body.head:AddAngleVelocity(-body.head:GetAngleVelocity())
		ply:SetEyeAngles(Angle(-45, 0, 0))
		Env.RunCommand(server, ply, IN.FORWARD + IN.ATTACK, 200, 0)
		run(server, 0.3)
		expect(spin(body.head)):toEqual(Vector(0, 0, 0))
		expect(body.phys[CHEST]:GetVelocity()):toEqual(Vector(0, 0, 0))
		expect(#server.welds):toBe(1)
		-- Awake again it holds on; getting up, it lets go.
		Env.RunCommand(server, ply, 0, 0, 0)
		for _ = 1, 600 do
			run(server, 0.1)
			if body.state == "fallen" and organism:Capabilities(ply).canStand then
				break
			end
		end
		reachDown(s, L_HAND, IN.ATTACK)
		expect(names(recorder:Take())):toEqual({ "grabbed left" })
		run(server, 1.6)
		expect(s.ragdoll:GetUp(ply)):toBe(true)
		run(server, 0.1)
		expect(names(recorder:Take())):toEqual({ "released left" })
		run(server, 1.3)
		expect(s.ragdoll:IsDown(ply)):toBe(false)
		expect(control.states[ply]):toBeNil()
		-- Down again in a new body, holding on, then dead: the corpse lets go.
		local again = s.ragdoll:Fall(ply)
		s.body = again
		World.LayRagdoll(again.ent)
		World.MoveRagdoll(again.ent, Vector(0, 0, -4))
		reachDown(s, L_HAND, IN.ATTACK)
		local weld = server.welds[#server.welds]
		expect(weld[1]):toBe(again.ent)
		expect(names(recorder:Take())):toEqual({ "grabbed left" })
		Env.Kill(ply)
		expect(names(recorder:Take())):toEqual({ "released left" })
		expect(weld[5]:IsMarkedForDeletion()):toBe(true)
		run(server, 0.3)
		expect(control.states[ply]):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("turns no head with look off and lets every hand go when it stops", function()
		local s = boot({ look = false, crawl = 0 })
		local server, ply, body, recorder = s.server, s.ply, s.body, s.recorder
		ply:SetEyeAngles(Angle(-45, 0, 0))
		Env.RunCommand(server, ply, IN.FORWARD, 200, 0)
		run(server, 0.2)
		expect(spin(body.head)):toEqual(Vector(0, 0, 0))
		expect(body.phys[CHEST]:GetVelocity()):toEqual(Vector(0, 0, 0))
		settle(s, 4)
		reachDown(s, L_HAND, IN.ATTACK)
		expect(names(recorder:Take())):toEqual({ "grabbed left" })
		local weld = server.welds[1][5]
		s.control:Stop(s.control.ctx)
		expect(names(recorder:Take())):toEqual({ "released left" })
		expect(weld:IsMarkedForDeletion()):toBe(true)
		expect(server:Errors()):toEqual({})
	end)
end)
