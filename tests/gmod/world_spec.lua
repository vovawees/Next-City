-- The emulated world itself: entities of the gamemode, ragdolls with their physics
-- objects, bones and eyes, the simple physics, deferred removal, the engine's ragdoll
-- of a dead player and welds.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

local function near(a, b)
	return a:Distance(b) < 1e-6
end

describe("world", function()
	it("creates ragdolls with the physics objects of a player model", function()
		local server = Env.Kernel():Boot()
		local client = Env.Join(server)
		local ents = server:Get("ents")
		local rag = ents.Create("prop_ragdoll")
		expect(rag:IsValid()):toBe(true)
		expect(rag:IsRagdoll()):toBe(true)
		expect(rag:GetPhysicsObjectCount()):toBe(0)
		expect(client:Get("Entity")(rag:EntIndex())):toBe(server:Get("NULL"))
		rag:SetModel("models/player/kleiner.mdl")
		rag:SetPos(Vector(100, 0, 0))
		rag:SetAngles(Angle(0, 90, 0))
		rag:Spawn()
		rag:Activate()
		expect(client:Get("Entity")(rag:EntIndex())):toBe(rag)
		expect(rag:GetPhysicsObjectCount()):toBe(15)
		local pelvis = rag:GetPhysicsObjectNum(0)
		expect(pelvis:IsValid()):toBe(true)
		expect(rag:TranslatePhysBoneToBone(0)):toBe(rag:LookupBone("ValveBiped.Bip01_Pelvis"))
		expect(rag:GetPos()):toEqual(Vector(100, 0, 38.5))
		-- Facing +y: the left hand is at -x.
		local hand = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_L_Hand"))
		expect(near(hand, Vector(100 - 8, 2, 38))):toBe(true)
		-- A bone without its own object hangs on the one it belongs to.
		local neck = rag:LookupBone("ValveBiped.Bip01_Neck1")
		expect(rag:TranslateBoneToPhysBone(neck)):toBe(1)
		local eyes = rag:GetAttachment(rag:LookupAttachment("eyes"))
		expect(near(eyes.Pos, Vector(100, 0.6 + 3.5, 65.5))):toBe(true)
		expect(eyes.Ang.y):toBe(90)
		expect(rag:GetPhysicsObjectNum(15):IsValid()):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("poses ragdolls on their back and on their face", function()
		local server = Env.Kernel():Boot()
		local rag = server:Get("ents").Create("prop_ragdoll")
		rag:Spawn()
		World.LayRagdoll(rag)
		expect(rag:GetPos()):toEqual(Vector(0, 0, 6))
		local head = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_Head1"))
		expect(head.x < -20 and math.abs(head.z - 6) < 1):toBe(true)
		local eyes = rag:GetAttachment(1)
		expect(eyes.Ang:Forward().z):toBeCloseTo(1, 1e-6)
		-- The neck still hangs between the chest and the head.
		local neck = rag:GetBonePosition(rag:LookupBone("ValveBiped.Bip01_Neck1"))
		expect(neck.x < -18 and neck.x > head.x):toBe(true)

		local prone = server:Get("ents").Create("prop_ragdoll")
		prone:SetAngles(Angle(0, 90, 0))
		prone:Spawn()
		World.LayRagdoll(prone, true)
		head = prone:GetBonePosition(prone:LookupBone("ValveBiped.Bip01_Head1"))
		expect(head.y > 20):toBe(true)
		expect(prone:GetAttachment(1).Ang:Forward().z):toBeCloseTo(-1, 1e-6)
	end)

	it("moves bodies with their objects and lets them come to rest", function()
		local server = Env.Kernel():Boot()
		local rag = server:Get("ents").Create("prop_ragdoll")
		rag:Spawn()
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			rag:GetPhysicsObjectNum(i):SetVelocity(Vector(100, 0, 0))
		end
		server:Advance(0.2)
		expect(rag:GetPos().x):toBeCloseTo(20, 1e-6)
		expect(rag:GetVelocity().x):toBeCloseTo(50, 1e-6)
		-- A push on one object moves the whole body, slower by its share of the mass.
		local head = rag:GetPhysicsObjectNum(10)
		head:ApplyForceCenter(Vector(0, head:GetMass() * 500, 0))
		expect(#head.forces):toBe(1)
		server:Advance(0.1)
		expect(rag:GetVelocity().y > 0):toBe(true)
		for _ = 1, 30 do
			server:Advance(0.1)
		end
		expect(rag:GetVelocity():Length()):toBe(0)
		local pos = rag:GetPos()
		rag:GetPhysicsObjectNum(0):Sleep()
		expect(rag:GetPhysicsObjectNum(0):IsAsleep()):toBe(true)
		rag:SetPos(pos + Vector(0, 0, 10))
		expect(rag:GetPos()):toEqual(pos + Vector(0, 0, 10))
	end)

	it("removes entities at the next tick and gives the dead their engine ragdoll", function()
		local server = Env.Kernel():Boot()
		local client, ply = Env.Join(server)
		local removed = {}
		local GM = server:Get("GM")
		local old = GM.EntityRemoved
		GM.EntityRemoved = function(gm, ent, ...)
			removed[#removed + 1] = ent
			return old(gm, ent, ...)
		end
		local rag = server:Get("ents").Create("prop_ragdoll")
		rag:Spawn()
		rag:Remove()
		expect(rag:IsValid()):toBe(true)
		expect(rag:IsMarkedForDeletion()):toBe(true)
		server:Advance(0.01)
		expect(rag:IsValid()):toBe(false)
		expect(removed):toEqual({ rag })
		expect(client:Get("Entity")(rag:EntIndex())):toBe(server:Get("NULL"))

		ply:SetPos(Vector(5, 6, 0))
		ply:Kill()
		local body = ply:GetRagdollEntity()
		expect(body:GetClass()):toBe("hl2mp_ragdoll")
		expect(body:GetPos()):toEqual(Vector(5, 6, 0))
		expect(body:GetOwner()):toBe(ply)
		ply:Spawn()
		ply:Kill()
		expect(ply:GetRagdollEntity()):notToBe(body)
		server:Advance(0.01)
		expect(body:IsValid()):toBe(false)

		-- A damage that removes the ragdoll leaves none.
		ply:Spawn()
		local dmginfo = World.DamageInfo()
		dmginfo:SetDamage(500)
		dmginfo:SetDamageType(World.DMG.REMOVENORAGDOLL)
		local last = ply:GetRagdollEntity()
		ply:TakeDamageInfo(dmginfo)
		expect(ply:Alive()):toBe(false)
		expect(ply:GetRagdollEntity()):toBe(last)
		expect(server:Errors()):toEqual({})
	end)

	it("welds entities with constraints", function()
		local server = Env.Kernel():Boot()
		local rag = server:Get("ents").Create("prop_ragdoll")
		rag:Spawn()
		local world = server:Get("game").GetWorld()
		local weld = server:Get("constraint").Weld(rag, world, 5, 0, 3000)
		expect(weld:IsValid()):toBe(true)
		expect(server.welds[1][1]):toBe(rag)
		expect(server.welds[1][3]):toBe(5)
		weld:Remove()
		server:Advance(0.01)
		expect(weld:IsValid()):toBe(false)
	end)
end)
