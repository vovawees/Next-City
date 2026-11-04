-- Services of the gameplay modules: notices (translated toasts and chat lines), storage
-- (JSON files in DATA) and actions (timed actions with a progress bar), with the real
-- gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local function boot(modules, opts)
	opts = opts or {}
	local server = Env.Server({ modules = modules, data = opts.data, patch = opts.patch })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC
end

local function clientModule(client, id)
	return client:Get("NC").Modules:Instance(id)
end

describe("notices", function()
	it("are translated by every client in its own language, with numbers and keys as params", function()
		local server, NC = boot({ "notices" })
		local notices = NC.Modules:Instance("notices")
		local en, bob = Env.Join(server, { name = "Bob" })
		local ru, ivan = Env.Join(server, { name = "Ivan", language = "ru" })
		notices:Send({ bob, ivan }, "common.time.seconds", { count = 3 }, "good")
		notices:Send(ivan, "common.language.changed", { language = { key = "common.yes" } }, "warn", { chat = true })
		Env.Flush(server, en, ru)
		local enList, ruList = clientModule(en, "notices"):Active(), clientModule(ru, "notices"):Active()
		expect(#enList):toBe(1)
		expect(enList[1].text):toBe("3 seconds")
		expect(enList[1].kind):toBe("good")
		expect(#ruList):toBe(2)
		expect(ruList[1].text):toBe("3 секунды")
		expect(ruList[2].text):toBe("Язык: Да")
		expect(#ru.chatLines):toBe(1)
		expect(#en.chatLines):toBe(0)
	end)

	it("show as toasts until they expire, at most config.max of them, and follow the language", function()
		local server, NC = boot({ "notices" })
		local notices = NC.Modules:Instance("notices")
		local client = Env.Join(server, { name = "Bob" })
		for i = 1, 7 do
			notices:Broadcast("common.time.minutes", { count = i })
		end
		Env.Flush(server, client)
		local mine = clientModule(client, "notices")
		expect(#mine:Active()):toBe(5)
		expect(mine:Active()[1].text):toBe("3 minutes")
		client:Call("HUDPaint")
		expect(client.drawn):toContain("7 minutes")
		client:SetConVar("gmod_language", "ru")
		expect(mine:Active()[5].text):toBe("7 минут")
		client:Advance(7)
		expect(#mine:Active()):toBe(0)
		expect(#client:Errors()):toBe(0)
	end)

	it("cut long values without breaking characters and show unknown keys as text", function()
		local server, NC = boot({ "notices" })
		local notices = NC.Modules:Instance("notices")
		local list = notices:Encode({ text = string.rep("я", 100), n = 5, item = { key = "common.ok" } })
		expect(#list):toBe(3)
		expect(list[1].name):toBe("item")
		expect(list[1].kind):toBe("key")
		expect(list[2].kind):toBe("number")
		expect(#list[3].value):toBe(128)
		local client = Env.Join(server, { name = "Bob" })
		notices:Send(server:Get("player").GetAll()[1], "Hello there")
		Env.Flush(server, client)
		expect(clientModule(client, "notices"):Active()[1].text):toBe("Hello there")
	end)
end)

describe("storage", function()
	it("keeps data in JSON files of DATA, written a moment after a change and read by the next server", function()
		local server, NC = boot({ "storage" })
		local storage = NC.Modules:Instance("storage")
		local bank = storage:Open("bank")
		bank:Set("765611980001", { cash = 500, items = { "a", "b" } })
		bank:Set("765611980002", { cash = 10 })
		expect(server.data["nextcity/bank.json"]):toBeNil()
		server:Advance(1)
		bank:Get("765611980002").cash = 20
		bank:Touch()
		server:Advance(1.5)
		expect(server.data["nextcity/bank.json"]):toBeTruthy()
		bank:Delete("765611980001")
		server:Call("ShutDown")
		local next, NC2 = boot({ "storage" }, { data = server.data })
		local again = NC2.Modules:Instance("storage"):Open("bank")
		expect(again:Keys()):toEqual({ "765611980002" })
		expect(again:Get("765611980002")):toEqual({ cash = 20 })
		expect(again:Count()):toBe(1)
		expect(#next:Errors()):toBe(0)
	end)

	it("keeps string keys as strings and puts a broken file aside", function()
		local data = { ["nextcity/doors.json"] = "{ not json", ["nextcity/marks.json"] = "{\"12\":{\"1\":true}}" }
		local server, NC = boot({ "storage" }, { data = data })
		local storage = NC.Modules:Instance("storage")
		expect(storage:Open("doors"):Count()):toBe(0)
		expect(server.data["nextcity/doors_corrupt.txt"]):toBe("{ not json")
		expect(#server:Lines("not valid JSON")):toBe(1)
		expect(storage:Open("marks"):Get("12")):toEqual({ ["1"] = true })
		expect(function() storage:Open("Bad Name") end):toFail("namespace")
		expect(function() storage:Open("marks"):Set(12, true) end):toFail("keys")
		server:Command("nc_storage", nil, {})
		expect(#server:Lines("doors: 0 keys")):toBe(1)
	end)

	it("gives players stable keys", function()
		local server, NC = boot({ "players", "storage" })
		local storage = NC.Modules:Instance("storage")
		local bot = Env.Bot(server, { name = "Kevin" })
		local _, bob = Env.Join(server, { name = "Bob" })
		expect(storage:PlayerKey(bot)):toBe("bot_Kevin")
		expect(storage:PlayerKey(bob)):toBe(bob:SteamID64())
	end)
end)

describe("actions", function()
	local function bootActions()
		local server, NC = boot({ "players", "notices", "actions" })
		return server, NC.Modules:Instance("actions"), NC
	end

	-- A player joins and enters the game.
	local function join(server, NC, name)
		local client, ply = Env.Join(server, { name = name })
		NC.Modules:Instance("players"):Deploy(ply)
		return client, ply
	end

	it("complete after their duration and show the progress to the player only", function()
		local server, actions, NC = bootActions()
		local client, bob = join(server, NC, "Bob")
		local other = join(server, NC, "Alice")
		local done = {}
		expect(actions:Begin(bob, { id = "bandage", label = "actions.working", duration = 2,
			OnComplete = function(ply) done[#done + 1] = ply end })):toBe(true)
		expect(actions:IsBusy(bob)):toBe(true)
		expect(select(2, actions:Begin(bob, { duration = 1 }))):toBe("busy")
		server:Advance(1)
		Env.Flush(server, client, other)
		local mine = clientModule(client, "actions")
		expect(mine:Current().label):toBe("actions.working")
		expect(mine:Progress(server.time)):toBeCloseTo(0.5, 0.06)
		expect(clientModule(other, "actions"):Current()):toBeNil()
		client:Call("HUDPaint")
		expect(client.drawn[1]):toContain("Working...")
		server:Advance(1.05)
		server:Advance(0.1)
		Env.Flush(server, client, other)
		expect(done):toEqual({ bob })
		expect(mine:Current()):toBeNil()
		expect(actions:IsBusy(bob)):toBe(false)
	end)

	it("stop when the player moves, is hurt, dies or the target goes away, and tell him why", function()
		local server, actions, NC = bootActions()
		local client, bob = join(server, NC, "Bob")
		local cancelled = {}
		local function track(ply, reason) cancelled[#cancelled + 1] = reason end
		actions:Begin(bob, { duration = 5, OnCancel = track })
		bob:SetPos(bob:GetPos() + Vector(100, 0, 0))
		server:Advance(0.2)
		actions:Begin(bob, { duration = 5, OnCancel = track })
		NC.Events:Emit("damage.hit", bob, {})
		local crate = Env.Spawn(server, { class = "prop_physics", pos = bob:GetShootPos() + Vector(40, 0, 0) })
		actions:Begin(bob, { duration = 5, target = crate, OnCancel = track })
		Env.Remove(server, crate)
		server:Advance(0.2)
		actions:Begin(bob, { duration = 5, allowMove = true, Check = function() return true end, OnCancel = track })
		Env.Kill(bob)
		expect(cancelled):toEqual({ "moved", "hurt", "target", "dead" })
		Env.Flush(server, client)
		local texts = {}
		for i, entry in ipairs(clientModule(client, "notices"):Active()) do
			texts[i] = entry.text
		end
		expect(texts):toEqual({ "Interrupted: you moved", "Interrupted: you were hurt",
			"Interrupted: the target is gone" })
	end)

	it("refuse to start for the dead, out of range or when the check says no", function()
		local server, actions, NC = bootActions()
		local _, bob = join(server, NC, "Bob")
		local far = Env.Spawn(server, { class = "prop_physics", pos = bob:GetPos() + Vector(500, 0, 0) })
		expect(select(2, actions:Begin(bob, { duration = 1, target = far }))):toBe("range")
		expect(select(2, actions:Begin(bob, { duration = 1, Check = function() return false, "locked" end })))
			:toBe("locked")
		local instant = 0
		expect(actions:Begin(bob, { duration = 0, OnComplete = function() instant = instant + 1 end })):toBe(true)
		expect(instant):toBe(1)
		Env.Kill(bob)
		expect(select(2, actions:Begin(bob, { duration = 1 }))):toBe("dead")
		expect(#server:Errors()):toBe(0)
	end)
end)
