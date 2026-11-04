-- Component service: stores declared in manifests, cleanup with entities, replication
-- to the audience, mirrors, autorefresh, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local MODULES = "nextcity/gamemode/modules/"

local SECTION = [[{
	vitals = { replicate = "owner", fields = {
		{ "blood", "quant", min = 0, max = 5000, bits = 12 },
		{ "pulse", "uint", max = 250 },
	}, defaults = { blood = 5000, pulse = 70 } },
	badge = { replicate = "all", rate = 5, fields = {
		{ "rank", "uint", bits = 8 },
		{ "title", "string", max = 16 },
	} },
	notes = { replicate = "all", fields = { { "text", "string", max = 255 } } },
	scratch = { fields = { { "hits", "uint", bits = 16 } } },
}]]

local function probeFiles(section)
	return {
		[MODULES .. "probe/module.lua"] = "return { id = 'probe', files = { sh = { 'sh_probe.lua' } }, "
			.. "net = { note = { from = 'server' } }, components = " .. (section or SECTION) .. " }",
		[MODULES .. "probe/sh_probe.lua"] = [[
			local M = NC.Module("probe")
			M.changes = {}
			M.order = {}
			function M:Init(ctx)
				if CLIENT then
					ctx.components.badge:OnChange("OnBadge")
					ctx.components.vitals:OnChange("OnVitals")
					ctx.net:Receive("note", function() self.order[#self.order + 1] = "note" end)
				end
			end
			function M:Start(ctx)
				if SERVER then
					ctx:On("net.ready", "OnReady")
				end
			end
			function M:OnReady(ply)
				self.ctx.net:Send("note", ply)
			end
			function M:OnBadge(index, data, mask)
				if data and data.title == "boom" then error("badge listener exploded") end
				self.changes[#self.changes + 1] = { "badge", index, data and data.rank, mask }
				self.order[#self.order + 1] = "badge"
			end
			function M:OnVitals(index, data, mask)
				self.changes[#self.changes + 1] = { "vitals", index, data and data.pulse, mask }
			end
		]],
	}
end

local function probe(env)
	return env:Get("NC").Modules:Instance("probe")
end

local function components(env)
	return probe(env).ctx.components
end

-- Runs the flush jobs (the fastest component flushes 10 times a second) and delivers.
local function tick(server, ...)
	server:Advance(0.25)
	Env.Flush(server, ...)
end

local function boot(section)
	local server = Env.Server({ files = probeFiles(section) }):Boot()
	expect(server:Errors()):toEqual({})
	return server
end

describe("component service", function()
	it("declares stores in manifests and keys them by entity", function()
		local server = boot()
		local client = Env.Client(server):Boot()
		expect(client:Errors()):toEqual({})
		for _, name in ipairs({ "nc.probe:vitals", "nc.probe:badge", "nc.probe:notes" }) do
			expect(server.pool.ids[name] ~= nil):toBe(true)
			expect(client.receivers[name] ~= nil):toBe(true)
			expect(server.receivers[name]):toBeNil()
		end
		expect(server.pool.ids["nc.probe:scratch"]):toBeNil()

		local badge = components(server).badge
		expect(server:Get("NC").Components:Store("probe.badge")):toBe(badge)
		local crate = Env.Spawn(server)
		local data = badge:Add(crate, { rank = 2 })
		expect(badge:Get(crate)):toBe(data)
		expect(badge:Get(crate:EntIndex())):toBe(data)
		expect(badge:Set(crate, "title", "crate")):toBe(true)
		expect(data):toEqual({ rank = 2, title = "crate" })
		expect(badge:Get(server:Get("NULL"))):toBeNil()
		expect(function() badge:Set(server:Get("NULL"), "rank", 1) end):toFail("got [NULL Entity]")

		expect(function() return components(server).nope end):toFail("module 'probe' has no component 'nope'")
		expect(server:Get("NC").Scheduler:Has("components:probe.badge")):toBe(true)
		expect(server:Get("NC").Scheduler:Has("components:probe.scratch")):toBe(false)
	end)

	it("removes the data of removed entities", function()
		local server = boot()
		local client, ply = Env.Join(server)
		local store = components(server)
		local crate = Env.Spawn(server)
		store.badge:Add(crate)
		store.scratch:Add(crate)
		store.vitals:Add(ply)
		Env.Remove(server, crate)
		expect(store.badge:Has(crate:EntIndex())):toBe(false)
		expect(store.scratch:Count()):toBe(0)
		Env.Leave(server, ply)
		expect(store.vitals:Count()):toBe(0)
		expect(client:Errors()):toEqual({})
	end)

	it("sends the full state to a ready player, then only changes", function()
		local server = boot()
		local badge = components(server).badge
		local crate = Env.Spawn(server)
		badge:Add(crate, { rank = 3, title = "crate" })

		local alyx = Env.Join(server, { name = "Alyx" })
		local index = crate:EntIndex()
		-- The full state arrives before the messages modules send on net.ready.
		expect(probe(alyx).order):toEqual({ "badge", "note" })
		expect(components(alyx).badge:Get(crate)):toEqual({ rank = 3, title = "crate" })
		expect(probe(alyx).changes):toEqual({ { "badge", index, 3, 3 } })

		-- The pending flush repeats what was added; then only the changed field goes.
		tick(server, alyx)
		badge:Set(crate, "rank", 4)
		local before = #server:Sent("nc.probe:badge")
		tick(server, alyx)
		local sent = server:Sent("nc.probe:badge")
		expect(#sent):toBe(before + 1)
		expect(components(alyx).badge:Get(index)):toEqual({ rank = 4, title = "crate" })
		local changes = probe(alyx).changes
		expect(changes[#changes]):toEqual({ "badge", index, 4, 1 })
		-- Nothing changed: nothing is sent.
		tick(server, alyx)
		expect(#server:Sent("nc.probe:badge")):toBe(before + 1)

		-- A late player gets everything at once; removals reach both.
		local barney = Env.Join(server, { name = "Barney" })
		expect(components(barney).badge:Get(index)):toEqual({ rank = 4, title = "crate" })
		Env.Remove(server, crate)
		tick(server, alyx, barney)
		expect(components(alyx).badge:Count()):toBe(0)
		expect(components(barney).badge:Count()):toBe(0)
		changes = probe(barney).changes
		expect(changes[#changes]):toEqual({ "badge", index, nil, 0 })
		expect(server:Errors()):toEqual({})
		expect(alyx:Errors()):toEqual({})
		expect(barney:Errors()):toEqual({})
	end)

	it("sends owner data only to its player", function()
		local server = boot()
		local vitals = components(server).vitals
		local alyx, alyxPly = Env.Join(server, { name = "Alyx" })
		local barney, barneyPly = Env.Join(server, { name = "Barney" })
		vitals:Add(alyxPly)
		vitals:Add(barneyPly, { pulse = 90 })
		tick(server, alyx, barney)
		local alyxVitals, barneyVitals = components(alyx).vitals, components(barney).vitals
		expect(alyxVitals:Count()):toBe(1)
		expect(alyxVitals:Get(alyxPly)):toEqual({ blood = 5000, pulse = 70 })
		expect(barneyVitals:Count()):toBe(1)
		expect(barneyVitals:Get(barneyPly).pulse):toBe(90)

		vitals:Set(alyxPly, "pulse", 120)
		tick(server, alyx, barney)
		expect(alyxVitals:Get(alyxPly).pulse):toBe(120)
		expect(#probe(barney).changes):toBe(1)
		vitals:Remove(alyxPly)
		tick(server, alyx, barney)
		expect(alyxVitals:Count()):toBe(0)

		local crate = Env.Spawn(server)
		expect(function() vitals:Add(crate) end):toFail("keys must be players")
		-- A player that is still loading gets its data with the full state.
		local gordonPly = Env.FakePlayer({ name = "Gordon" })
		server:Call("PlayerInitialSpawn", gordonPly, false)
		server.entities[gordonPly:EntIndex()] = gordonPly
		vitals:Add(gordonPly, { pulse = 100 })
		tick(server, alyx, barney)
		local gordon = Env.Client(server):Boot()
		Env.Connect(server, gordon, gordonPly)
		gordon:Call("InitPostEntity")
		Env.Flush(server, gordon)
		expect(components(gordon).vitals:Get(gordonPly).pulse):toBe(100)
		expect(server:Errors()):toEqual({})
	end)

	it("keeps mirrors read-only and local stores on their realm", function()
		local server = boot()
		local client, ply = Env.Join(server)
		local mirror = components(client).badge
		expect(function() mirror:Add(ply) end):toFail("component 'badge' is a read-only mirror")
		expect(function() mirror:Set(ply, "rank", 1) end):toFail("read-only mirror")
		expect(function() components(server).badge:OnChange("OnBadge") end):toFail("OnChange is for mirrors")

		local crate = Env.Spawn(server)
		local scratch = components(client).scratch
		scratch:Add(crate, { hits = 2 })
		expect(components(server).scratch:Has(crate)):toBe(false)
		client:Call("EntityRemoved", crate, true)
		expect(scratch:Get(crate).hits):toBe(2)
		Env.Remove(server, crate)
		expect(scratch:Has(crate)):toBe(false)
	end)

	it("logs failing listeners and keeps applying", function()
		local server = boot()
		local client = Env.Join(server)
		local badge = components(server).badge
		local a, b = Env.Spawn(server), Env.Spawn(server)
		badge:Add(a, { title = "boom" })
		badge:Add(b, { rank = 1 })
		tick(server, client)
		expect(components(client).badge:Count()):toBe(2)
		expect(#client:Lines("component 'probe.badge' listener failed")):toBe(1)
		expect(#client:Lines("badge listener exploded")):toBe(1)
	end)

	it("splits large batches into several messages", function()
		local server = boot()
		local client = Env.Join(server)
		local store = components(server)
		local crates = {}
		for i = 1, 150 do
			crates[i] = Env.Spawn(server)
			store.notes:Add(crates[i], { text = "note " .. i })
		end
		local before = #server:Sent("nc.probe:notes")
		tick(server, client)
		-- An update of notes can take 2 KiB, so about 57 fit into 16 KiB.
		expect(#server:Sent("nc.probe:notes") - before):toBe(3)
		expect(components(client).notes:Count()):toBe(150)
		expect(components(client).notes:Get(crates[150]).text):toBe("note 150")

		for i = 1, 1100 do
			store.badge:Add(Env.Spawn(server), { rank = i % 256 })
		end
		tick(server, client)
		expect(components(client).badge:Count()):toBe(1100)
		before = #server:Sent("nc.probe:badge")
		for index, ent in pairs(server.entities) do
			if not ent:IsPlayer() and store.badge:Has(index) then
				Env.Remove(server, ent)
			end
		end
		tick(server, client)
		-- At most 1023 removals per message.
		expect(#server:Sent("nc.probe:badge") - before):toBe(2)
		expect(components(client).badge:Count()):toBe(0)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("keeps data across autorefresh on both realms", function()
		local server = boot()
		local client, ply = Env.Join(server)
		local crate = Env.Spawn(server)
		components(server).badge:Add(crate, { rank = 7 })
		components(server).vitals:Add(ply, { pulse = 99 })
		tick(server, client)

		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		Env.Flush(server, client)
		expect(components(server).badge:Get(crate).rank):toBe(7)
		expect(components(server).vitals:Get(ply).pulse):toBe(99)
		expect(components(client).badge:Get(crate).rank):toBe(7)
		expect(server:Get("NC").Components.previous):toBeNil()
		components(server).badge:Set(crate, "rank", 8)
		tick(server, client)
		expect(components(client).badge:Get(crate).rank):toBe(8)

		-- A client autorefresh keeps the mirror and gets the full state again.
		client:Run(Env.ENTRY.client)
		client:Call("OnReloaded")
		expect(components(client).vitals:Get(ply).pulse):toBe(99)
		Env.Flush(server, client)
		expect(components(client).badge:Get(crate).rank):toBe(8)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})

		-- New fields: the data starts empty.
		local files = probeFiles(SECTION:gsub("{ \"pulse\", \"uint\", max = 250 }", "{ \"pulse\", \"uint\", max = 300 }"))
		for path, source in pairs(files) do
			server.sources[path] = source
		end
		server:Run(Env.ENTRY.server)
		server:Call("OnReloaded")
		expect(#server:Lines("component 'probe.vitals' has new fields: its data starts empty")):toBe(1)
		expect(components(server).vitals:Count()):toBe(0)
		expect(components(server).badge:Get(crate).rank):toBe(8)
	end)

	it("validates the components section of manifests", function()
		local fields = "fields = { { 'a', 'uint', max = 5 } }"
		local cases = {
			{ "{ v = { fields = {} } }", "component 'v': fields must be a non-empty array" },
			{ "{ v = { " .. fields .. ", size = 1 } }", "component 'v': unknown key 'size'" },
			{ "{ v = { " .. fields .. ", replicate = 'team' } }", "replicate must be \"all\" or \"owner\"" },
			{ "{ v = { " .. fields .. ", rate = 5 } }", "component 'v': rate needs replicate" },
			{ "{ v = { " .. fields .. ", replicate = 'all', rate = 0 } }", "rate must be a number of flushes" },
			{ "{ v = { fields = { { 'a', 'uint', bits = 40 } } } }", "component 'v': schema: a: bits must be" },
			{ "{ v = { " .. fields .. ", defaults = { a = 9 } } }", "component 'v': bad default, a: " },
			{ "{ v = { fields = { { 'a', 'uint', max = 5, optional = true } } } }", "field 'a' cannot be optional" },
			{ "{ v = { replicate = 'all', fields = { { 'a', 'array', max = 100, of = { 'string', max = 255 } } } } }",
				"an update can take" },
			{ "{ Bad = { " .. fields .. " } }", "component name Bad must be a snake_case id" },
			{ "42", "components must be a table of components" },
		}
		for _, case in ipairs(cases) do
			local server = Env.Server({ files = probeFiles(case[1]) }):Boot()
			local errors = table.concat(server:Errors(), "\n")
			expect(errors):toContain(case[2])
			expect(server:Get("NC").Modules:State("probe")):toBeNil()
			expect(server:Get("NC").started):toBe(true)
		end
	end)

	it("stops flushing when the module stops", function()
		local server = boot()
		local scheduler = server:Get("NC").Scheduler
		server:Get("NC").Modules:StopAll()
		expect(scheduler:Has("components:probe.badge")):toBe(false)
		expect(scheduler:Has("components:probe.vitals")):toBe(false)
	end)

	it("shows component stores with nc_components", function()
		local server = boot()
		local client, ply = Env.Join(server)
		components(server).vitals:Add(ply)
		tick(server, client)
		server:Command("nc_components")
		expect(#server:Lines("Components (server): 4, 1 entries")):toBe(1)
		local row = server:Lines("  probe.vitals ")[1]
		expect(row):toContain("owner")
		expect(row):toContain("10")
		expect(server:Lines("  probe.scratch ")[1]):toContain("local")
		client:Command("nc_components_cl")
		expect(#client:Lines("Components (client): 4, 1 entries")):toBe(1)
	end)
end)
