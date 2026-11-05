-- Profiles: a record per player in a storage collection across visits and servers (first
-- and last visit, visits, playtime), statistics from deaths, creatures and rounds, module
-- sections, the summary only the owner sees, bots for the session only, nc_profile.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local CLOCK = 1700000000

-- opts: data (DATA of an earlier server), modules, settings of profiles.
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = opts.modules or { "players", "storage", "profiles" }, data = opts.data,
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.profiles = opts.settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local profiles = NC.Modules:Instance("profiles")
	server.clock = CLOCK
	profiles.Now = function() return server.clock end
	return server, NC, profiles
end

local function settle(server, client)
	server:Advance(1)
	Env.Flush(server, client)
	server:Advance(1)
	Env.Flush(server, client)
end

describe("profiles", function()
	it("keep visits, the first and the last visit and the playtime of a player across servers", function()
		local server, NC, profiles = boot()
		local loaded = {}
		NC.Events:On("profiles.loaded", function(ply, record, isNew) loaded[#loaded + 1] = { ply, record, isNew } end)
		local _, bob = Env.Join(server, { name = "Bob" })
		local key = bob:SteamID64()
		local record = profiles:Get(bob)
		expect(record.visits):toBe(1)
		expect(record.first):toBe(CLOCK)
		expect(record.name):toBe("Bob")
		expect(loaded[1][1]):toBe(bob)
		expect(loaded[1][3]):toBe(true)
		server:Advance(30)
		expect(profiles:Playtime(bob)):toBe(30)
		profiles:Section(bob, "identity").name = "John"
		profiles:Touch(bob)
		server.clock = CLOCK + 100
		Env.Leave(server, bob)
		expect(profiles:Get(bob)):toBeNil()
		expect(server.data["nextcity/profiles/" .. key .. ".json"]):toBeTruthy()
		local next, NC2, profiles2 = boot({ data = server.data })
		local again
		NC2.Events:On("profiles.loaded", function(_, r, isNew) again = { r, isNew } end)
		next.clock = CLOCK + 1000
		local _, bob2 = Env.Join(next, { name = "Bobby", index = bob:EntIndex() })
		expect(again[2]):toBe(false)
		record = profiles2:Get(bob2)
		expect(record.visits):toBe(2)
		expect(record.first):toBe(CLOCK)
		expect(record.last):toBe(CLOCK + 1000)
		expect(record.playtime):toBe(30)
		expect(record.name):toBe("Bobby")
		expect(profiles2:Section(bob2, "identity")):toEqual({ name = "John" })
		expect(profiles2:ByKey(key)):toBe(record)
		expect(#next:Errors()):toBe(0)
	end)

	it("count the playtime of everybody every saveInterval and on shutdown", function()
		local server, _, profiles = boot({ settings = { saveInterval = 10 } })
		local _, bob = Env.Join(server, { name = "Bob" })
		local key = bob:SteamID64()
		for _ = 1, 12 do
			server:Advance(1)
		end
		expect(profiles:Get(bob).playtime):toBe(10)
		expect(server.data["nextcity/profiles/" .. key .. ".json"]):toBeTruthy()
		server:Advance(5)
		server:Call("ShutDown")
		local stored = server:Get("util").JSONToTable(server.data["nextcity/profiles/" .. key .. ".json"])
		expect(stored.playtime):toBe(17)
	end)

	it("count deaths, kills, creatures, rounds and wins and show the summary to its owner only", function()
		local server, NC, profiles = boot()
		local client, bob = Env.Join(server, { name = "Bob" })
		local other, ann = Env.Join(server, { name = "Ann" })
		NC.Events:Emit("players.died", ann, nil, bob)
		NC.Events:Emit("players.died", bob, nil, bob)
		NC.Events:Emit("npcs.killed", {}, bob)
		local round = { result = { winner = bob } }
		function round.Participants() return { bob, ann } end
		NC.Events:Emit("rounds.phase", "ended", "active", round)
		bob:SetTeam(2)
		ann:SetTeam(3)
		round.result = { team = 3 }
		NC.Events:Emit("rounds.phase", "ended", "active", round)
		NC.Events:On("profiles.won", function(ply) return ply == bob end)
		round.result = { reason = "mode.cleared" }
		NC.Events:Emit("rounds.phase", "ended", "active", round)
		expect(profiles:Get(bob).stats):toEqual({ kills = 1, deaths = 1, rounds = 3, wins = 2, creatures = 1 })
		expect(profiles:Stat(ann, "wins")):toBe(1)
		expect(profiles:Stat(ann, "deaths")):toBe(1)
		expect(profiles:AddStat(bob, "arrests", 2)):toBe(2)
		expect(function() profiles:AddStat(bob, "Bad Name") end):toFail("counter")
		settle(server, client)
		Env.Flush(server, other)
		local mine = client:Get("NC").Modules:Instance("profiles")
		local summary = mine:Summary(bob)
		expect(summary.kills):toBe(1)
		expect(summary.wins):toBe(2)
		expect(summary.visits):toBe(1)
		expect(summary.first):toBe(CLOCK)
		expect(mine:Summary(ann)):toBeNil()
		expect(other:Get("NC").Modules:Instance("profiles"):Summary(bob)):toBeNil()
		client.time = server.time
		expect(mine:SummaryPlaytime(bob)):toBe(profiles:Playtime(bob))
		expect(#client:Errors()):toBe(0)
	end)

	it("keep bots and servers without storage for the session only", function()
		local server, _, profiles = boot()
		local bot = Env.Bot(server, { name = "Kevin" })
		expect(profiles:Get(bot).visits):toBe(1)
		Env.Leave(server, bot)
		server:Call("ShutDown")
		expect(server.data["nextcity/profiles/bot_5f_4bevin.json"]):toBeNil()
		local bare, _, alone = boot({ modules = { "players", "profiles" } })
		local _, bob = Env.Join(bare, { name = "Bob" })
		alone:AddStat(bob, "kills", 2)
		expect(alone:Stat(bob, "kills")):toBe(2)
		expect(alone:ByKey(bob:SteamID64())):toBe(alone:Get(bob))
		expect(#bare:Errors()):toBe(0)
	end)

	it("answer nc_profile with his own profile for everybody and other profiles for admins", function()
		local server, _, profiles = boot()
		local _, bob = Env.Join(server, { name = "Bob" })
		local _, root = Env.Join(server, { name = "Root", superadmin = true })
		profiles:AddStat(bob, "kills", 3)
		server:Command("nc_profile", bob, {})
		expect(bob.printed[#bob.printed - 3]):toContain("profile " .. bob:SteamID64() .. " (Bob), on the server")
		expect(bob.printed[#bob.printed - 1]):toContain("kills 3")
		server:Command("nc_profile", bob, { "Root" })
		expect(bob.printed[#bob.printed]):toBe("nc_profile: no access")
		local key = bob:SteamID64()
		Env.Leave(server, bob)
		server:Command("nc_profile", root, { key })
		expect(root.printed[#root.printed - 3]):toBe("profile " .. key .. " (Bob)")
		server:Command("nc_profile", nil, { "76561190000000000" })
		expect(#server:Lines("nc_profile: no profile 76561190000000000")):toBe(1)
		server:Command("nc_profile", nil, { "Nobody" })
		expect(#server:Lines("no player matches 'Nobody'")):toBe(1)
	end)
end)
