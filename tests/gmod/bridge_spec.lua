-- Engine bridge: notifications, questions and replacements of the player, damage, map
-- and HUD hooks, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local Vector = Env.World.Vector
local IN = Env.World.IN

local PROBE = {
	[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sh = { 'sh_probe.lua' } } }",
	[MODULES .. "probe/sh_probe.lua"] = [[
		local M = NC.Module("probe")
		M.seen = {}
		M.answers = {}
		local NOTIFY = {
			"gm.PlayerSpawned", "gm.PlayerLoadout", "gm.DoPlayerDeath", "gm.PlayerDeath", "gm.PlayerSilentDeath",
			"gm.KeyPress", "gm.PlayerRequestTeam", "gm.PostCleanupMap", "gm.HUDPaint",
		}
		local ASK = {
			"gm.PlayerSpawn", "gm.PlayerSelectSpawn", "gm.PlayerDeathThink", "gm.PlayerShouldTakeDamage",
			"gm.CanPlayerSuicide",
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
