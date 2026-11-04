-- Soak test: the default gamemode (Team Deathmatch with every repository module) under
-- random kills, joins, departures, observer keys and admin commands for several minutes
-- of game time. Checks that nothing errors and that the invariants of players, teams and
-- spectating hold (a camera may lag behind a change by a tick or two, not longer).

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local IN = World.IN

-- A small deterministic generator, independent of math.random used by the gamemode.
local function generator(seed)
	local state = seed
	return function(n)
		state = (state * 1103515245 + 12345) % 2147483648
		return state % n + 1
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
end)
