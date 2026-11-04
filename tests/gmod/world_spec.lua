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
	it("traces against boxes of the map, props, hitboxes of players and ragdolls", function()
		local server = Env.Kernel():Boot()
		local geometry = Env.Geometry(server)
		local G = server.G
		local util = G.util
		geometry:Wall(100, 4, G.MAT_METAL)
		geometry:Box(Vector(-1000, -1000, -10), Vector(1000, 1000, 0), { mat = G.MAT_DIRT })
		geometry:Box(Vector(-100, -1000, 0), Vector(-50, 1000, 50), { contents = G.CONTENTS_WATER, mat = G.MAT_SLOSH })
		local tr = util.TraceLine({ start = Vector(0, 0, 50), endpos = Vector(200, 0, 50), mask = G.MASK_SHOT })
		expect(tr.Hit and tr.HitWorld):toBe(true)
		expect(near(tr.HitPos, Vector(100, 0, 50))):toBe(true)
		expect(tr.HitNormal):toEqual(Vector(-1, 0, 0))
		expect(tr.MatType):toBe(G.MAT_METAL)
		expect(tr.Fraction):toBe(0.5)
		-- Inside the wall: StartSolid and where the trace leaves it; a trace back finds its far side.
		local out = {}
		tr = util.TraceLine({ start = Vector(101, 0, 50), endpos = Vector(111, 0, 50), mask = G.MASK_SHOT, output = out })
		expect(tr):toBe(out)
		expect(tr.StartSolid and not tr.AllSolid):toBe(true)
		expect(math.abs(tr.FractionLeftSolid - 0.3) < 1e-9):toBe(true)
		tr = util.TraceLine({ start = Vector(110, 0, 50), endpos = Vector(101, 0, 50), mask = G.MASK_SHOT })
		expect(near(tr.HitPos, Vector(104, 0, 50))):toBe(true)
		tr = util.TraceLine({ start = Vector(101, 0, 50), endpos = Vector(101, 0, 50), mask = G.MASK_SHOT })
		expect(tr.AllSolid):toBe(true)
		-- Water only for masks with water, and in the point contents.
		tr = util.TraceLine({ start = Vector(0, 0, 25), endpos = Vector(-200, 0, 25), mask = G.MASK_SHOT })
		expect(tr.Hit):toBe(false)
		tr = util.TraceLine({ start = Vector(0, 0, 25), endpos = Vector(-200, 0, 25), mask = G.MASK_WATER })
		expect(tr.Hit and tr.MatType == G.MAT_SLOSH):toBe(true)
		expect(util.PointContents(Vector(-75, 0, 25))):toBe(G.CONTENTS_WATER)
		-- A player: hitboxes for shots, the hull for solid masks and hulls; filters skip him.
		local ply = Env.Bot(server, { name = "Target" })
		ply:SetPos(Vector(50, 0, 0))
		ply:SetEyeAngles(Angle(0, 90, 0))
		tr = util.TraceLine({ start = Vector(0, 0, 66), endpos = Vector(100, 0, 66), mask = G.MASK_SHOT })
		expect(tr.Entity):toBe(ply)
		expect(tr.HitGroup):toBe(G.HITGROUP_HEAD)
		expect(tr.MatType):toBe(G.MAT_FLESH)
		expect(math.abs(tr.HitPos.x - 46) < 1e-9):toBe(true)
		-- From the side the arm is in the way of the chest; from the front it is not.
		tr = util.TraceLine({ start = Vector(0, 0, 52), endpos = Vector(100, 0, 52), mask = G.MASK_SHOT })
		expect(tr.HitGroup == G.HITGROUP_LEFTARM and math.abs(tr.HitPos.x - 40.5) < 1e-9):toBe(true)
		tr = util.TraceLine({ start = Vector(50, 100, 52), endpos = Vector(50, -100, 52), mask = G.MASK_SHOT })
		expect(tr.HitGroup == G.HITGROUP_CHEST and math.abs(tr.HitPos.y - 6) < 1e-9):toBe(true)
		expect(tr.HitNormal.y > 0.99):toBe(true)
		tr = util.TraceLine({ start = Vector(0, 0, 52), endpos = Vector(100, 0, 52), mask = G.MASK_SHOT, filter = ply })
		expect(tr.HitWorld):toBe(true)
		tr = util.TraceLine({ start = Vector(0, 0, 52), endpos = Vector(100, 0, 52), mask = G.MASK_SHOT,
			filter = function(ent) return ent ~= ply end })
		expect(tr.HitWorld):toBe(true)
		tr = util.TraceLine({ start = Vector(0, 0, 52), endpos = Vector(100, 0, 52), mask = G.MASK_SOLID })
		expect(tr.Entity == ply and tr.HitGroup == G.HITGROUP_GENERIC):toBe(true)
		expect(math.abs(tr.HitPos.x - 34) < 1e-9):toBe(true)
		tr = util.TraceHull({ start = Vector(0, 0, 52), endpos = Vector(100, 0, 52), mins = Vector(-4, -4, -4),
			maxs = Vector(4, 4, 4), mask = G.MASK_SHOT_HULL })
		expect(tr.Entity == ply and math.abs(tr.HitPos.x - 30) < 1e-9):toBe(true)
		-- Above the shoulders only the head is there.
		tr = util.TraceLine({ start = Vector(50, -100, 70.5), endpos = Vector(50, 100, 70.5), mask = G.MASK_SHOT })
		expect(tr.Entity == ply and tr.HitGroup == G.HITGROUP_HEAD):toBe(true)
		ply:SetNotSolid(true)
		tr = util.TraceLine({ start = Vector(0, 0, 52), endpos = Vector(100, 0, 52), mask = G.MASK_SHOT })
		expect(tr.HitWorld):toBe(true)
		-- A prop and a ragdoll.
		local crate = Env.Spawn(server, { pos = Vector(0, 50, 0) })
		crate.box = { Vector(-10, -10, 0), Vector(10, 10, 20) }
		crate.mat = G.MAT_WOOD
		tr = util.TraceLine({ start = Vector(0, 0, 10), endpos = Vector(0, 100, 10), mask = G.MASK_SHOT })
		expect(tr.Entity == crate and tr.MatType == G.MAT_WOOD and tr.HitNonWorld):toBe(true)
		local rag = G.ents.Create("prop_ragdoll")
		rag:SetPos(Vector(0, -50, 0))
		rag:Spawn()
		tr = util.TraceLine({ start = Vector(0, 0, 43), endpos = Vector(0, -100, 43), mask = G.MASK_SHOT })
		expect(tr.Entity):toBe(rag)
		expect(rag:TranslatePhysBoneToBone(tr.PhysicsBone)):toBe(rag:LookupBone("ValveBiped.Bip01_Pelvis"))
		expect(geometry.traces > 10):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("runs scripted weapons on every realm, each with its own state, like the engine", function()
		local server = Env.Kernel():Boot()
		local client, ply = Env.Join(server, { name = "Gordon" })
		local log = {}
		local IN = World.IN
		-- The class of each realm: its code sees the realm it runs in.
		local function class(realm)
			local SWEP = { Base = "weapon_base", Primary = { ClipSize = 6, DefaultClip = 10, Automatic = false,
				Ammo = "Pistol" } }
			function SWEP:SetupDataTables()
				self:NetworkVar("Int", 0, "Shots")
				self:NetworkVar("Bool", "Ready")
			end
			function SWEP:Initialize() self:SetHoldType("revolver") end
			function SWEP:Deploy() log[#log + 1] = realm.realm .. " deploy" return true end
			function SWEP:Holster() log[#log + 1] = realm.realm .. " holster" return not self.keep end
			function SWEP:PrimaryAttack()
				self:SetShots(self:GetShots() + 1)
				self:SetClip1(self:Clip1() - 1)
				self:SetNextPrimaryFire(realm.time + 0.5)
				self:ShootEffects()
				log[#log + 1] = realm.realm .. " fire " .. tostring(realm.G.GetPredictionPlayer() == ply)
			end
			function SWEP:Reload() log[#log + 1] = realm.realm .. " reload" end
			function SWEP:Think() self:SetReady(self:GetOwner():KeyPressed(World.IN.ATTACK2)) end
			function SWEP:OnRemove() log[#log + 1] = realm.realm .. " remove" end
			realm.G.weapons.Register(SWEP, "test_revolver")
		end
		class(server)
		class(client)
		local stored = server.G.weapons.Get("test_revolver")
		expect(stored.Base .. " " .. tostring(stored.Secondary.ClipSize)):toBe("weapon_base -1")
		expect(server.G.weapons.IsBasedOn("test_revolver", "weapon_base")):toBe(true)

		local weapon = ply:Give("test_revolver")
		expect(weapon:Clip1() .. " " .. ply:GetAmmoCount("Pistol")):toBe("6 4")
		expect(weapon:GetHoldType()):toBe("revolver")
		expect(table.concat(log, ", ")):toBe("server deploy, client deploy")
		local mirror = client.entities[weapon:EntIndex()]
		expect(mirror ~= weapon and mirror:GetClass() == "test_revolver"):toBe(true)
		expect(ply:GetActiveWeapon()):toBe(weapon)
		expect(client:As(function() return ply:GetActiveWeapon() end)):toBe(mirror)

		-- One command on both realms: a press fires once; holding does not fire again.
		log = {}
		Env.Use(server, ply, IN.ATTACK)
		Env.Use(client, ply, IN.ATTACK)
		expect(weapon:GetShots() .. " " .. mirror:GetShots() .. " " .. mirror:Clip1()):toBe("1 1 5")
		server:Advance(1)
		client:Advance(1)
		Env.Use(server, ply, IN.ATTACK + IN.RELOAD + IN.ATTACK2)
		expect(weapon:GetShots()):toBe(1)
		expect(weapon:GetReady()):toBe(true)
		Env.Use(server, ply, IN.ATTACK2)
		expect(weapon:GetReady()):toBe(false)
		expect(table.concat(log, ", ")):toBe("server fire true, client fire true, server reload")
		expect(weapon.anims[1]):toBe(World.Sweps.ACT.VM_PRIMARYATTACK)
		expect(ply.animations[1] .. " " .. ply.muzzleFlashes):toBe(World.Sweps.PLAYER.ATTACK1 .. " 2")
		-- What the server alone changed reaches the client with a snapshot.
		weapon:SetShots(7)
		weapon:SetClip1(2)
		expect(mirror:GetShots()):toBe(1)
		Env.Sync(server)
		expect(mirror:GetShots() .. " " .. mirror:Clip1()):toBe("7 2")

		-- Switching: a Holster that answers false keeps the weapon.
		local other = ply:Give("weapon_pistol")
		expect(ply:GetActiveWeapon()):toBe(weapon)
		weapon.keep = true
		log = {}
		ply:SelectWeapon("weapon_pistol")
		expect(table.concat(log, ", ")):toBe("server holster")
		weapon.keep = false
		ply:SelectWeapon("weapon_pistol")
		expect(ply:GetActiveWeapon()):toBe(other)
		ply:SelectWeapon("test_revolver")
		log = {}
		ply:StripWeapons()
		expect(table.concat(log, ", ")):toBe("server holster, client holster, server remove, client remove")
		expect(weapon:IsValid() or mirror:IsValid()):toBe(false)
		expect(client.entities[weapon:EntIndex()]):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("rotates angles, records engine bullets and predicts the reserve and the randomness of commands", function()
		local function angle(a)
			local p, y, r = a:Unpack()
			local function round(v) return string.format("%g", math.floor(v * 10 + 0.5) / 10) end
			return round(p) .. " " .. round(y) .. " " .. round(r)
		end
		-- The right-hand rule: about up a quarter turn looks left, about right it looks up.
		local ang = Angle(0, 0, 0)
		ang:RotateAroundAxis(Vector(0, 0, 1), 90)
		expect(angle(ang)):toBe("0 90 0")
		ang = Angle(0, 0, 0)
		ang:RotateAroundAxis(ang:Right(), 30)
		expect(angle(ang)):toBe("-30 0 0")
		ang:RotateAroundAxis(ang:Forward(), 20)
		expect(angle(ang)):toBe("-30 0 20")

		local server = Env.Kernel():Boot()
		local client, ply = Env.Join(server, { name = "Gordon" })
		-- Bullets of the engine are recorded with the realm that fired them.
		ply:FireBullets({ Num = 1, Damage = 10 })
		client:As(function() ply:FireBullets({ Num = 8 }) end)
		expect(ply.bullets[1].realm .. " " .. ply.bullets[2].realm .. " " .. ply.bullets[2].bullet.Num)
			:toBe("server client 8")
		-- A client predicts its own reserve; a snapshot gives it the server's again.
		ply:GiveAmmo(10, "Pistol")
		local before = ply:GetAmmoCount("Pistol")
		expect(client:As(function()
			ply:RemoveAmmo(3, "Pistol")
			return ply:GetAmmoCount("Pistol")
		end)):toBe(before - 3)
		expect(ply:GetAmmoCount("Pistol")):toBe(before)
		Env.Sync(server)
		expect(client:As(function() return ply:GetAmmoCount("Pistol") end)):toBe(before)

		-- util.SharedRandom agrees on the realms that run the same command and changes
		-- with the next one; a repeated prediction runs the last command again.
		local rolls = {}
		local function class(realm)
			local SWEP = { Base = "weapon_base" }
			function SWEP:Think()
				rolls[#rolls + 1] = realm.G.util.SharedRandom("spread", 0, 1)
			end
			realm.G.weapons.Register(SWEP, "test_dice")
		end
		class(server)
		class(client)
		local weapon = ply:Give("test_dice")
		expect(ply:GetWeapon("test_dice")):toBe(weapon)
		expect(client:As(function() return ply:GetWeapon("test_dice") end)):toBe(client.entities[weapon:EntIndex()])
		Env.Use(server, ply, 0)
		Env.Use(client, ply, 0)
		Env.Use(client, ply, 0, { firstTime = false })
		Env.Use(server, ply, 0)
		expect(#rolls):toBe(4)
		expect(rolls[1] == rolls[2] and rolls[2] == rolls[3] and rolls[4] ~= rolls[1]):toBe(true)
		ply:SetViewPunchAngles(Angle(-2, 1, 0))
		expect(angle(ply:GetViewPunchAngles())):toBe("-2 1 0")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
