-- Engine bridge: notifications, questions and replacements of the player, damage, map,
-- HUD and camera hooks, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local Vector = Env.World.Vector
local Angle = Env.World.Angle
local IN = Env.World.IN

local PROBE = {
	[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sh = { 'sh_probe.lua' } } }",
	[MODULES .. "probe/sh_probe.lua"] = [[
		local M = NC.Module("probe")
		M.seen = {}
		M.answers = {}
		local NOTIFY = {
			"gm.PlayerSpawned", "gm.PlayerLoadout", "gm.DoPlayerDeath", "gm.PlayerDeath", "gm.PlayerSilentDeath",
			"gm.KeyPress", "gm.PlayerRequestTeam", "gm.PostCleanupMap", "gm.HUDPaint", "gm.StartCommand",
			"gm.RenderScreenspaceEffects", "gm.WeaponEquip", "gm.OnNPCKilled", "gm.ShowHelp", "gm.ShowTeam",
			"gm.ShowSpare1", "gm.ShowSpare2",
		}
		local ASK = {
			"gm.PlayerSpawn", "gm.PlayerSelectSpawn", "gm.PlayerDeathThink", "gm.PlayerShouldTakeDamage",
			"gm.CanPlayerSuicide", "gm.EntityTakeDamage", "gm.ScalePlayerDamage", "gm.GetFallDamage",
			"gm.OnPlayerHitGround", "gm.HUDShouldDraw", "gm.PlayerBindPress", "gm.PlayerUse",
			"gm.PlayerCanPickupWeapon", "gm.PlayerSay", "gm.PlayerCanSeePlayersChat", "gm.PlayerCanHearPlayersVoice",
			"gm.HUDDrawTargetID",
		}
		function M:Start(ctx)
			for _, name in ipairs(NOTIFY) do
				ctx:On(name, function(...)
					self.seen[#self.seen + 1] = { name, ... }
				end)
			end
			for _, name in ipairs(ASK) do
				ctx:On(name, function(...)
					self.seen[#self.seen + 1] = { name, ... }
					local answer = self.answers[name]
					if type(answer) == "function" then
						return answer(...)
					end
					return answer
				end)
			end
		end
		function M:Names()
			local names = {}
			for i, entry in ipairs(self.seen) do
				names[i] = entry[1]
			end
			self.seen = {}
			return names
		end
	]],
}

local function boot()
	local server = Env.Kernel({ files = PROBE }):Boot()
	return server, server:Get("NC").Modules:Instance("probe")
end

describe("bridge", function()
	it("spawns through the base gamemode unless a module handles the spawn", function()
		local server, probe = boot()
		local start = Env.Spawn(server, { class = "info_player_start", pos = Vector(1, 2, 3) })
		local ply = Env.Bot(server, { name = "Alyx" })
		expect(probe:Names()):toEqual({
			"gm.PlayerSelectSpawn", "gm.PlayerSpawn", "gm.PlayerLoadout", "gm.PlayerSpawned",
		})
		expect(ply.spawnPoint):toBe(start)
		expect(ply:GetPos()):toEqual(start:GetPos())
		expect(ply:Alive()):toBe(true)
		expect(ply:GetModel()):toBe("models/player/kleiner.mdl")
		-- PlayerLoadout replaces the base one: no stock pistol.
		expect(ply:WeaponClasses()):toEqual({})

		probe.answers["gm.PlayerSpawn"] = true
		local other = Env.Spawn(server, { class = "info_player_deathmatch" })
		probe.answers["gm.PlayerSelectSpawn"] = other
		ply:SetModel(nil)
		ply:Spawn()
		expect(probe:Names()):toEqual({ "gm.PlayerSelectSpawn", "gm.PlayerSpawn", "gm.PlayerSpawned" })
		expect(ply.spawnPoint):toBe(other)
		expect(ply:GetModel()):toBeNil()
		expect(server:Errors()):toEqual({})
	end)

	it("lets a module take over respawning", function()
		local server, probe = boot()
		local bot = Env.Bot(server)
		probe:Names()
		bot:Kill()
		expect(probe:Names()):toEqual({ "gm.DoPlayerDeath", "gm.PlayerDeath" })
		expect(bot:Deaths()):toBe(1)
		expect(bot:Frags()):toBe(-1)

		-- Without an answer the base gamemode respawns the bot after its delay.
		server:Advance(1)
		expect(bot:Alive()):toBe(false)
		server:Advance(2)
		expect(bot:Alive()):toBe(true)

		probe.answers["gm.PlayerDeathThink"] = true
		bot:KillSilent()
		server:Advance(5)
		expect(bot:Alive()):toBe(false)
		local names = probe:Names()
		expect(names[#names]):toBe("gm.PlayerDeathThink")
		expect(names[#names - 1]):toBe("gm.PlayerSilentDeath")
	end)

	it("answers damage and suicide questions or falls back to the base gamemode", function()
		local server, probe = boot()
		local victim, attacker = Env.Bot(server), Env.Bot(server)
		local GM = server:Get("GM")
		expect(GM:PlayerShouldTakeDamage(victim, attacker)):toBe(true)
		expect(GM:CanPlayerSuicide(victim)):toBe(true)
		probe.answers["gm.PlayerShouldTakeDamage"] = function(ply, by)
			if ply == victim and by == attacker then
				return false
			end
		end
		probe.answers["gm.CanPlayerSuicide"] = false
		expect(GM:PlayerShouldTakeDamage(victim, attacker)):toBe(false)
		expect(GM:PlayerShouldTakeDamage(attacker, victim)):toBe(true)
		expect(GM:CanPlayerSuicide(victim)):toBe(false)
	end)

	it("forwards key presses, team requests and map cleanups", function()
		local server, probe = boot()
		local client, ply = Env.Join(server, { name = "Eli" })
		local clientProbe = client:Get("NC").Modules:Instance("probe")
		probe:Names()
		Env.Press(server, ply, IN.JUMP)
		expect(probe.seen[1]):toEqual({ "gm.KeyPress", ply, 2 })
		probe:Names()

		local calls = #server.baseCalls
		server:Get("GM"):PlayerRequestTeam(ply, 2)
		expect(probe.seen[1]):toEqual({ "gm.PlayerRequestTeam", ply, 2 })
		for _, key in ipairs({ "ShowHelp", "ShowTeam", "ShowSpare1", "ShowSpare2" }) do
			probe.seen = {}
			server:Call(key, ply)
			expect(probe.seen[1]):toEqual({ "gm." .. key, ply })
		end
		expect(#server.baseCalls):toBe(calls)
		probe:Names()

		local spawn = Env.Spawn(server, { class = "info_player_start", map = true })
		local prop = Env.Spawn(server, { class = "prop_physics" })
		server:Get("game").CleanUpMap()
		expect(probe:Names()):toEqual({ "gm.PostCleanupMap" })
		expect(clientProbe:Names()):toEqual({ "gm.PostCleanupMap" })
		expect(spawn:IsValid()):toBe(false)
		expect(prop:IsValid()):toBe(false)
		local fresh = server:Get("ents").FindByClass("info_player_start")
		expect(#fresh):toBe(1)
		expect(fresh[1]):notToBe(spawn)
	end)

	it("asks modules about damage, lets it through without an answer and never scales hits", function()
		local server, probe = boot()
		local victim, attacker = Env.Bot(server), Env.Bot(server)
		probe:Names()
		local DMG = Env.World.DMG
		Env.Hurt(victim, { damage = 30, type = DMG.CLUB, attacker = attacker })
		expect(probe:Names()):toEqual({ "gm.EntityTakeDamage", "gm.PlayerShouldTakeDamage" })
		expect(victim:Health()):toBe(70)

		-- ScalePlayerDamage keeps the amount: no base head x2 or limbs x0.25.
		local dmginfo = Env.Shoot(attacker, victim, { bone = "Head1", damage = 20 })
		expect(probe.seen[1][1]):toBe("gm.ScalePlayerDamage")
		expect(probe.seen[1][3]):toBe(Env.World.HITGROUP.HEAD)
		expect(dmginfo:GetDamage()):toBe(20)
		expect(victim:Health()):toBe(50)
		probe:Names()

		probe.answers["gm.EntityTakeDamage"] = true
		Env.Hurt(victim, { damage = 500, attacker = attacker })
		expect(probe:Names()):toEqual({ "gm.EntityTakeDamage" })
		expect(victim:Health()):toBe(50)
		expect(victim:Alive()):toBe(true)
		probe.answers["gm.EntityTakeDamage"] = nil

		probe.answers["gm.ScalePlayerDamage"] = true
		Env.Shoot(attacker, victim, { damage = 100 })
		expect(probe:Names()):toEqual({ "gm.ScalePlayerDamage" })
		expect(victim:Health()):toBe(50)
		expect(server:Errors()):toEqual({})
	end)

	it("asks about falls and forwards user commands", function()
		local server, probe = boot()
		local ply = Env.Bot(server)
		probe:Names()
		Env.Fall(ply, 700)
		expect(probe:Names()):toEqual({ "gm.OnPlayerHitGround", "gm.GetFallDamage", "gm.EntityTakeDamage",
			"gm.PlayerShouldTakeDamage" })
		expect(ply:Health()):toBe(90) -- the base fall damage

		probe.answers["gm.GetFallDamage"] = 0
		Env.Fall(ply, 700)
		expect(probe:Names()):toEqual({ "gm.OnPlayerHitGround", "gm.GetFallDamage" })
		probe.answers["gm.OnPlayerHitGround"] = true
		Env.Fall(ply, 900)
		expect(probe:Names()):toEqual({ "gm.OnPlayerHitGround" })
		expect(ply:Health()):toBe(90)

		local cmd = Env.RunCommand(server, ply, IN.ATTACK + IN.JUMP, 200)
		expect(probe.seen[1]):toEqual({ "gm.StartCommand", ply, cmd })
		expect(cmd:KeyDown(IN.ATTACK)):toBe(true)
		expect(server:Errors()):toEqual({})
	end)

	it("asks about using, pickups, chat and voice and forwards weapons and creatures killed", function()
		local server, probe = boot()
		local GM = server:Get("GM")
		local ply, other = Env.Bot(server, { name = "Alyx" }), Env.Bot(server, { name = "Barney" })
		local crate = Env.Spawn(server, { class = "prop_physics" })
		probe:Names()
		expect(Env.UseEntity(server, ply, crate)):toBe(true)
		probe.answers["gm.PlayerUse"] = function(_, ent)
			if ent == crate then
				return false
			end
		end
		expect(Env.UseEntity(server, ply, crate)):toBe(false)
		expect(probe:Names()):toEqual({ "gm.PlayerUse", "gm.PlayerUse" })

		expect(GM:PlayerCanPickupWeapon(ply, crate)):toBe(true)
		probe.answers["gm.PlayerCanPickupWeapon"] = false
		expect(GM:PlayerCanPickupWeapon(ply, crate)):toBe(false)
		GM:WeaponEquip(crate, ply)
		expect(probe.seen[#probe.seen]):toEqual({ "gm.WeaponEquip", crate, ply })
		probe:Names()

		local said, seen = Env.Say(server, ply, "hello")
		expect(said):toBe("hello")
		expect(#seen):toBe(2)
		probe.answers["gm.PlayerSay"] = function(_, text)
			if text:sub(1, 1) == "/" then
				return ""
			end
			return text:upper()
		end
		probe.answers["gm.PlayerCanSeePlayersChat"] = function(_, _, listener)
			if listener == other then
				return false
			end
		end
		said, seen = Env.Say(server, ply, "quiet")
		expect(said):toBe("QUIET")
		expect(seen):toEqual({ ply })
		expect(other.heard[#other.heard].text):toBe("hello")
		said = Env.Say(server, ply, "/job cook")
		expect(said):toBeNil()

		expect({ GM:PlayerCanHearPlayersVoice(ply, other) }):toEqual({ true, false })
		probe.answers["gm.PlayerCanHearPlayersVoice"] = "3d"
		expect({ GM:PlayerCanHearPlayersVoice(ply, other) }):toEqual({ true, true })
		probe.answers["gm.PlayerCanHearPlayersVoice"] = false
		expect({ GM:PlayerCanHearPlayersVoice(ply, other) }):toEqual({ false, false })
		probe:Names()

		local npc = server:Get("ents").Create("npc_combine_s")
		npc:Spawn()
		expect(npc:IsNPC()):toBe(true)
		Env.KillNPC(npc, ply)
		expect(probe.seen[1]):toEqual({ "gm.OnNPCKilled", npc, ply, ply })
		server:Advance(0.1)
		expect(npc:IsValid()):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("asks the client about HUD elements and binds and forwards screen effects", function()
		local server = boot()
		local client = Env.Client(server):Boot()
		local probe = client:Get("NC").Modules:Instance("probe")
		local GM = client:Get("GM")
		expect(GM:HUDShouldDraw("CHudHealth")):toBe(true)
		probe.answers["gm.HUDShouldDraw"] = function(name)
			if name == "CHudHealth" then
				return false
			end
		end
		expect(GM:HUDShouldDraw("CHudHealth")):toBe(false)
		expect(GM:HUDShouldDraw("CHudAmmo")):toBe(true)
		probe:Names()

		expect(GM:PlayerBindPress(nil, "+reload", true, 0)):toBeNil()
		probe.answers["gm.PlayerBindPress"] = true
		expect(GM:PlayerBindPress(nil, "+reload", true, 0)):toBe(true)
		client:Call("RenderScreenspaceEffects")
		expect(probe:Names()):toEqual({ "gm.PlayerBindPress", "gm.PlayerBindPress", "gm.RenderScreenspaceEffects" })

		local calls = #client.baseCalls
		GM:HUDDrawTargetID()
		expect(client.baseCalls[#client.baseCalls]):toBe("HUDDrawTargetID")
		probe.answers["gm.HUDDrawTargetID"] = true
		GM:HUDDrawTargetID()
		expect(#client.baseCalls):toBe(calls + 1)
		expect(client:Errors()):toEqual({})
	end)

	it("builds the camera from the base view and ordered modifiers", function()
		local camera = {
			[MODULES .. "camera/module.lua"] = "return { id = 'camera', files = { cl = { 'cl_camera.lua' } } }",
			[MODULES .. "camera/cl_camera.lua"] = [[
				local M = NC.Module("camera")
				M.order = {}
				function M:Start(ctx)
					ctx:On("gm.CalcView", function(view)
						self.order[#self.order + 1] = "shake"
						view.angles = view.angles + Angle(1, 0, 0)
					end)
					ctx:On("gm.CalcView", function(view, ply)
						self.order[#self.order + 1] = "body"
						view.origin = ply:GetPos() + Vector(0, 0, 10)
						view.angles = Angle(0, 90, 0)
						view.drawviewer = true
					end, { priority = 100 })
				end
			]],
		}
		local server = Env.Kernel({ files = camera }):Boot()
		local client, ply = Env.Join(server)
		ply:SetPos(Vector(5, 0, 0))
		local probe = client:Get("NC").Modules:Instance("camera")
		local view = client:Call("CalcView", ply, Vector(5, 0, 64), Angle(10, 0, 0), 90, 3, 30000)
		expect(probe.order):toEqual({ "body", "shake" })
		expect(view.origin):toEqual(Vector(5, 0, 10))
		expect(view.angles.x):toBe(1)
		expect(view.angles.y):toBe(90)
		expect(view.fov):toBe(90)
		expect(view.drawviewer):toBe(true)
		expect(client.baseCalls[#client.baseCalls]):toBe("CalcView")
		expect(client:Errors()):toEqual({})
	end)

	it("paints the HUD after the base gamemode on the client", function()
		local server = boot()
		local client = Env.Client(server):Boot()
		local probe = client:Get("NC").Modules:Instance("probe")
		client:Call("HUDPaint")
		expect(probe:Names()):toEqual({ "gm.HUDPaint" })
		expect(client.baseCalls[#client.baseCalls]):toBe("HUDPaint")
		expect(client:Errors()):toEqual({})
	end)
end)
