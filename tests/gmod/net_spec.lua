-- Network service: messages declared in manifests, readiness, validation of client data,
-- client info and autorefresh, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"
local CONFIG = "nextcity/gamemode/config.lua"

local function probeFiles(netSection)
	return {
		[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sh = { 'sh_probe.lua' } }, net = "
			.. (netSection or [[{
				state = { from = "server", fields = {
					{ "phase", "enum", values = { "waiting", "active", "ended" } },
					{ "endsAt", "float" },
					{ "scores", "array", max = 4, of = { "uint", bits = 16 } },
					{ "leader", "player", optional = true },
					{ "where", "vector" },
					{ "tint", "color", alpha = false },
					{ "note", "string", max = 16 },
				} },
				ping = { from = "server" },
				vote = { from = "client", rate = 1, burst = 2, fields = {
					{ "mode", "enum", values = { "tdm", "homicide", "riot" } },
				} },
				chat = { from = "client", fields = { { "text", "string", max = 32 } } },
			}]]) .. " }",
		[MODULES .. "probe/sh_probe.lua"] = [[
			local M = NC.Module("probe")
			M.got = {}
			M.ready = {}
			function M:Init(ctx)
				if SERVER then
					ctx.net:Receive("vote", "OnVote")
					ctx.net:Receive("chat", "OnChat")
				else
					ctx.net:Receive("state", "OnState")
					ctx.net:Receive("ping", function() self.got[#self.got + 1] = { "ping" } end)
				end
			end
			function M:Start(ctx)
				ctx:On("net.ready", "OnReady")
			end
			function M:OnReady(ply) self.ready[#self.ready + 1] = ply or "client" end
			function M:OnVote(data, ply) self.got[#self.got + 1] = { "vote", data.mode, ply } end
			function M:OnChat(data, ply)
				if data.text == "boom" then error("chat exploded") end
				self.got[#self.got + 1] = { "chat", data.text, ply }
			end
			function M:OnState(data) self.got[#self.got + 1] = { "state", data } end
		]],
	}
end

local function probe(env)
	return env:Get("NC").Modules:Instance("probe")
end

local function statsOf(env, name)
	for _, row in ipairs(env:Get("NC").Net:Stats()) do
		if row.name == name then
			return row
		end
	end
	return nil
end

-- A payload written with the schema of a message, then changed by `tamper(entries)`.
local function payload(server, name, data, tamper)
	local schema = server:Get("NC").Net:SchemaOf(name)
	return function(wire)
		schema:Codec(wire).Write(data)
		if tamper then
			tamper(wire.entries)
		end
	end
end

describe("net service", function()
	it("pools a string per message and receives only on the receiving realm", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client = Env.Client(server):Boot()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		local names = { "nc.hello", "nc.info", "nc.probe.state", "nc.probe.ping", "nc.probe.vote", "nc.probe.chat" }
		for _, name in ipairs(names) do
			expect(server.pool.ids[name] ~= nil):toBe(true)
		end
		expect(server.receivers["nc.hello"] ~= nil):toBe(true)
		expect(server.receivers["nc.probe.vote"] ~= nil):toBe(true)
		expect(server.receivers["nc.probe.state"]):toBeNil()
		expect(client.receivers["nc.probe.state"] ~= nil):toBe(true)
		expect(client.receivers["nc.probe.vote"]):toBeNil()
		expect(client.receivers["nc.hello"]):toBeNil()
		expect(server:Get("NC").Net:Count()):toBe(6)
		expect(probe(server).ctx.net:Name("vote")):toBe("nc.probe.vote")
	end)

	it("delivers to ready players only and announces readiness", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local service = server:Get("NC").Net
		local net = probe(server).ctx.net
		expect(net:Broadcast("ping")):toBe(0)

		local alyx, alyxPly = Env.Join(server, { name = "Alyx" })
		expect(probe(server).ready):toEqual({ alyxPly })
		expect(probe(alyx).ready):toEqual({ "client" })
		expect(service:IsReady(alyxPly)):toBe(true)
		expect(alyx:Get("NC").Net:IsReady()):toBe(true)

		-- Barney is still loading: spawned and connected, no hello yet.
		local barneyPly = Env.FakePlayer({ name = "Barney" })
		server:Call("PlayerInitialSpawn", barneyPly, false)
		local barney = Env.Client(server):Boot()
		Env.Connect(server, barney, barneyPly)
		expect(net:Broadcast("ping")):toBe(1)
		expect(net:Send("ping", barneyPly)):toBe(0)
		expect(net:Send("ping", { alyxPly, barneyPly })):toBe(1)
		expect(net:SendOmit("ping", alyxPly)):toBe(0)
		Env.Flush(server, alyx, barney)
		expect(#probe(alyx).got):toBe(2)
		expect(#probe(barney).got):toBe(0)
		expect(statsOf(server, "nc.probe.ping").dropped.notReady):toBe(2)

		barney:Call("InitPostEntity")
		Env.Flush(server, alyx, barney)
		expect(probe(server).ready):toEqual({ alyxPly, barneyPly })
		expect(net:Broadcast("ping")):toBe(2)
		expect(net:SendOmit("ping", alyxPly)):toBe(1)
		expect(net:SendOmit("ping", { alyxPly, barneyPly })):toBe(0)
		Env.Flush(server, alyx, barney)
		expect(#probe(alyx).got):toBe(3)
		expect(#probe(barney).got):toBe(2)

		Env.Leave(server, alyxPly)
		expect(service:IsReady(alyxPly)):toBe(false)
		expect(service:ReadyPlayers()):toEqual({ barneyPly })
		expect(net:Broadcast("ping")):toBe(1)
		local stats = statsOf(server, "nc.probe.ping")
		expect(stats.sent):toBe(5)
		expect(stats.from):toBe("server")
		expect(server:Errors()):toEqual({})
	end)

	it("encodes every field with the schema and coerces bad values", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client, ply = Env.Join(server)
		local G = server.G
		local net = probe(server).ctx.net
		expect(net:Send("state", ply, {
			phase = "active", endsAt = 12.5, scores = { 1, 65535, 70000 }, leader = ply,
			where = G.Vector(1, -2, 3.5), tint = G.Color(10, 300, -5), note = "a very long note, cut",
		})):toBe(1)
		net:Send("state", ply, { phase = "nope", leader = "somebody", where = "here", tint = 5 })
		Env.Flush(server, client)
		expect(client:Errors()):toEqual({})

		local got = probe(client).got
		expect(got[1][1]):toBe("state")
		local data = got[1][2]
		expect(data.phase):toBe("active")
		expect(data.endsAt):toBe(12.5)
		expect(data.scores):toEqual({ 1, 65535, 65535 })
		expect(data.leader):toBe(ply)
		expect({ data.where.x, data.where.y, data.where.z }):toEqual({ 1, -2, 3.5 })
		expect({ data.tint.r, data.tint.g, data.tint.b, data.tint.a }):toEqual({ 10, 255, 0, 255 })
		expect(data.note):toBe("a very long note")

		local coerced = got[2][2]
		expect(coerced.phase):toBe("waiting")
		expect(coerced.endsAt):toBe(0)
		expect(coerced.scores):toEqual({})
		expect(client.G.IsValid(coerced.leader)):toBe(false)
		expect({ coerced.where.x, coerced.where.y, coerced.where.z }):toEqual({ 0, 0, 0 })
		expect({ coerced.tint.r, coerced.tint.g, coerced.tint.b }):toEqual({ 0, 0, 0 })
		expect(coerced.note):toBe("")
	end)

	it("checks client data from cheap to expensive before the handler", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local NC = server:Get("NC")
		local violations = {}
		NC.Events:On("net.violation", function(ply, name, reason)
			violations[#violations + 1] = ply:Nick() .. " " .. name .. " " .. reason
		end)
		local got = probe(server).got
		local client, ply = Env.Join(server, { name = "Eli" })

		-- Not ready: dropped quietly.
		local stranger = Env.FakePlayer({ name = "Stranger" })
		server:Inject("nc.probe.vote", stranger, payload(server, "nc.probe.vote", { mode = "tdm" }))
		server:Pump()
		expect(statsOf(server, "nc.probe.vote").dropped.notReady):toBe(1)

		-- Valid data reaches the handler.
		server:Inject("nc.probe.vote", ply, payload(server, "nc.probe.vote", { mode = "riot" }))
		server:Pump()
		expect(got):toEqual({ { "vote", "riot", ply } })

		-- An enum index out of range is rejected by the decoder.
		server:Inject("nc.probe.vote", ply, payload(server, "nc.probe.vote", { mode = "tdm" }, function(entries)
			entries[1].value = 3
		end))
		server:Pump()
		expect(violations):toEqual({ "Eli nc.probe.vote invalid" })

		-- The bucket is empty now (burst 2): the third vote in a row is too fast.
		server:Inject("nc.probe.vote", ply, payload(server, "nc.probe.vote", { mode = "tdm" }))
		server:Pump()
		expect(violations[2]):toBe("Eli nc.probe.vote rate")
		expect(#got):toBe(1)
		server:Advance(1)
		server:Inject("nc.probe.vote", ply, payload(server, "nc.probe.vote", { mode = "homicide" }))
		server:Pump()
		expect(got[2]):toEqual({ "vote", "homicide", ply })

		-- Size is checked before decoding: too long and too short.
		server:Inject("nc.probe.chat", ply, function(wire)
			wire.WriteString(string.rep("x", 100))
		end)
		server:Inject("nc.probe.chat", ply, function() end)
		server:Pump()
		expect(violations[3]):toBe("Eli nc.probe.chat size")
		expect(violations[4]):toBe("Eli nc.probe.chat size")
		expect(statsOf(server, "nc.probe.chat").dropped.size):toBe(2)

		-- One log line per second per player, however many violations: the invalid vote and
		-- the first oversized chat were logged, the rest only counted.
		local reports = server:Lines("[net] Player [")
		expect(#reports):toBe(2)
		expect(reports[1]):toContain("'nc.probe.vote' rejected (invalid: mode:")
		expect(reports[2]):toContain("'nc.probe.chat' rejected (size: 808 bits), 3 violation(s)")
		server:Advance(1)
		server:Inject("nc.probe.chat", ply, function() end)
		server:Pump()
		reports = server:Lines("[net] Player [")
		expect(#reports):toBe(3)
		expect(reports[3]):toContain("5 violation(s)")

		-- A failing handler is logged; the next message is handled.
		server:Inject("nc.probe.chat", ply, payload(server, "nc.probe.chat", { text = "boom" }))
		server:Inject("nc.probe.chat", ply, payload(server, "nc.probe.chat", { text = "hi" }))
		server:Pump()
		expect(got[3]):toEqual({ "chat", "hi", ply })
		expect(table.concat(server:Errors(), "\n")):toContain("net 'nc.probe.chat' handler failed")
		expect(statsOf(server, "nc.probe.chat").errors):toBe(1)
		expect(client:Errors()):toEqual({})
	end)

	it("reports client info with the hello and on changes", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local NC = server:Get("NC")
		local languageAtReady = {}
		NC.Events:On("net.ready", function(ply)
			languageAtReady[#languageAtReady + 1] = NC.I18n:LanguageOf(ply)
		end)
		local client, ply = Env.Join(server, { language = "ru" })
		expect(languageAtReady):toEqual({ "ru" })
		expect(NC.Net:InfoOf(ply, "language")):toBe("ru")
		expect(#client:Sent("nc.hello")):toBe(1)
		expect(#client:Sent("nc.info")):toBe(0)

		client:SetConVar("nc_language", "en")
		Env.Flush(server, client)
		expect(NC.I18n:LanguageOf(ply)):toBe("en")
		expect(#client:Sent("nc.info")):toBe(1)

		local clientNet = client:Get("NC").Net
		clientNet:SetInfo("favorite_color", "green")
		clientNet:SetInfo("favorite_color", "green")
		Env.Flush(server, client)
		expect(#client:Sent("nc.info")):toBe(2)
		expect(NC.Net:InfoOf(ply, "favorite_color")):toBeNil()
		expect(function() clientNet:SetInfo("Bad Key", "x") end):toFail("snake_case")

		Env.Leave(server, ply)
		expect(NC.Net:InfoOf(ply, "language")):toBeNil()
		expect(NC.I18n:LanguageOf(ply)):toBe("en")
		expect(server:Errors()):toEqual({})
	end)

	it("rejects misuse of ctx.net with clear errors", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client = Env.Client(server):Boot()
		local net = probe(server).ctx.net
		expect(function() net:Send("missing", nil, {}) end):toFail("module 'probe' has no net message 'missing'")
		expect(function() net:Send("vote", {}, {}) end):toFail("goes from the client, Send cannot send it")
		expect(function() net:SendToServer("vote", {}) end):toFail("SendToServer is client-only")
		expect(function() net:Receive("state", "OnState") end):toFail("goes from the server, it cannot be received there")
		expect(function() net:Send("ping", 42) end):toFail("target must be a player or a list of players")

		local clientNet = probe(client).ctx.net
		expect(function() clientNet:Broadcast("ping") end):toFail("Broadcast is server-only")
		-- Before the hello a client message cannot go.
		expect(clientNet:SendToServer("vote", { mode = "tdm" })):toBe(false)
		expect(statsOf(client, "nc.probe.vote").dropped.notReady):toBe(1)

		server:Get("NC").Modules:StopAll()
		expect(function() net:Broadcast("ping") end):toFail("module 'probe' is stopped")
	end)

	it("validates the net section of manifests", function()
		local cases = {
			{ "{ state = { fields = {} } }", "net message 'state': from must be \"server\" or \"client\"" },
			{ "{ state = { from = 'server', size = 3 } }", "net message 'state': unknown key 'size'" },
			{ "{ ['Bad-Name'] = { from = 'server' } }", "net message name Bad-Name must be a snake_case id" },
			{ "{ state = { from = 'server', rate = 2 } }", "rate and burst limit client messages only" },
			{ "{ vote = { from = 'client', rate = 0 } }", "rate must be a positive number" },
			{ "{ vote = { from = 'client', burst = 1.5 } }", "burst must be a positive integer" },
			{ "{ state = { from = 'server', fields = { { 'x', 'uint', bits = 40 } } } }", "x" },
			{ "42", "net must be a table of messages" },
		}
		for _, case in ipairs(cases) do
			local server = Env.Server({ files = probeFiles(case[1]) }):Boot()
			local errors = table.concat(server:Errors(), "\n")
			expect(errors):toContain(case[2])
			expect(server:Get("NC").Modules:State("probe")):toBeNil()
			expect(server:Get("NC").started):toBe(true)
		end
	end)

	it("keeps ready players across autorefresh on both realms", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client, ply = Env.Join(server, { language = "ru" })
		local oldProbe = probe(server)

		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		local fresh = probe(server)
		expect(fresh):notToBe(oldProbe)
		expect(fresh.ready):toEqual({ ply })
		expect(server:Get("NC").Net:IsReady(ply)):toBe(true)
		expect(server:Get("NC").I18n:LanguageOf(ply)):toBe("ru")

		probe(client).ctx.net:SendToServer("vote", { mode = "tdm" })
		Env.Flush(server, client)
		expect(fresh.got):toEqual({ { "vote", "tdm", ply } })
		expect(oldProbe.got):toEqual({})

		-- A client autorefresh sends the hello again: the server resends the state.
		client:Run(Env.ENTRY.client)
		client:Call("OnReloaded")
		Env.Flush(server, client)
		expect(fresh.ready):toEqual({ ply, ply })
		expect(probe(client).ready):toEqual({ "client" })
		expect(#client:Sent("nc.hello")):toBe(2)
		expect(#client:Sent("nc.info")):toBe(0)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})

		server:Call("ShutDown")
		expect(server.receivers["nc.hello"]):toBeNil()
		expect(server.receivers["nc.probe.vote"]):toBeNil()
	end)

	it("reports what cannot be delivered or decoded on the client", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client = Env.Join(server)
		-- The server does not know the message (its module failed there).
		server.pool.ids["nc.probe.vote"] = nil
		expect(probe(client).ctx.net:SendToServer("vote", { mode = "tdm" })):toBe(false)
		expect(table.concat(client:Errors(), "\n")):toContain("net 'nc.probe.vote' is unknown to the server")

		client:Inject("nc.probe.state", nil, function(wire)
			wire.WriteUInt(3, 2)
		end)
		client:Pump()
		expect(table.concat(client:Errors(), "\n")):toContain("net 'nc.probe.state' from the server is invalid")
		expect(probe(client).got):toEqual({})
	end)

	it("checks outgoing data when the config asks for it", function()
		local patch = {
			[CONFIG] = function(cfg)
				cfg.net = { checkOutgoing = true }
				return cfg
			end,
		}
		local server = Env.Server({ files = probeFiles(), patch = patch }):Boot()
		local client, ply = Env.Join(server)
		probe(server).ctx.net:Send("state", ply, { phase = "nope" })
		Env.Flush(server, client)
		expect(#server:Lines("net 'nc.probe.state' sends bad data: phase")):toBe(1)
		expect(#probe(client).got):toBe(1)
	end)

	it("shows message statistics with nc_net", function()
		local server = Env.Server({ files = probeFiles() }):Boot()
		local client, ply = Env.Join(server)
		probe(server).ctx.net:Send("ping", ply)
		probe(client).ctx.net:SendToServer("vote", { mode = "riot" })
		Env.Flush(server, client)
		server:Command("nc_net")
		expect(#server:Lines("Network (server): 6 messages, ready players: 1")):toBe(1)
		local row = server:Lines("  nc.probe.ping ")[1]
		expect(row):toContain("server")
		expect(row:find("%s1%s") ~= nil):toBe(true)
		expect(server:Lines("  nc.probe.vote ")[1]):toContain("client")
		server:Command("nc_net_reset")
		expect(statsOf(server, "nc.probe.ping").sent):toBe(0)
		client:Command("nc_net_cl")
		expect(#client:Lines("Network (client): 6 messages, ready")):toBe(1)
	end)
end)
