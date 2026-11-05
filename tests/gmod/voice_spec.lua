-- Voice: everybody hears everybody where voices are global (the team in team play), around
-- in 3D as far as the mode carries (whisper, normal, yell) where a mode makes them local;
-- the unconscious and the dead, the rules of rounds first; radios tuned to frequencies and
-- their talk key (+nc_radio) carry voices flat to every radio on the frequency; who hears
-- whom from a matrix rebuilt a few times a second; the HUD with the names others see
-- instead of the base voice panels; the keys of the help (F1).

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local MODULES = { "players", "notices", "menu", "organism", "teams", "inventory", "chat", "voice" }

-- A content package of the test: radios (one reaching 1000 units), names others see and
-- the answers of a mode.
local PROBE = {
	["nextcity/modules/probe/module.lua"] = "return { id = 'probe', requires = { 'inventory' },"
		.. " files = { sh = { 'sh_probe.lua' } } }",
	["nextcity/modules/probe/sh_probe.lua"] = [[
		local M = NC.Module("probe")
		function M:Init(ctx)
			local inventory = ctx:Require("inventory")
			inventory:RegisterItem("radio", { weight = 0.3, category = "gear", traits = { radio = {} } })
			inventory:RegisterItem("walkie", { weight = 0.2, category = "gear", traits = { radio = { range = 1000 } } })
			self.names, self.mute = {}, {}
		end
		function M:Start(ctx)
			ctx:On("players.name", function(name, ply) return self.names[ply] end)
			if CLIENT then
				return
			end
			ctx:On("voice.proximity", function() return self.proximity end)
			ctx:On("voice.canTalk", function(ply) if self.mute[ply] then return false end end)
			-- Like the rule dead_mute of rounds: answered before the voice module.
			ctx:On("gm.PlayerCanHearPlayersVoice", function(listener, talker)
				if self.deadMute and listener:Alive() and not talker:Alive() then
					return false
				end
			end)
			ctx:On("voice.mode", function(ply, mode, old) self.mode = { ply = ply, mode = mode, old = old } end)
			ctx:On("voice.radio", function(ply, frequency, on)
				self.radio = { ply = ply, frequency = frequency, on = on }
			end)
		end
	]],
}

-- opts: settings of the voice.
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = MODULES, files = PROBE, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.voice = opts.settings
		cfg.modules.settings.chat = { rate = 1000, burst = 1000, repeatDelay = 0 }
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC, clients = {} }
	for _, id in ipairs({ "voice", "players", "organism", "teams", "inventory", "probe" }) do
		m[id] = NC.Modules:Instance(id)
	end
	return server, m
end

-- Time goes by (a rebuild of the matrix), the clients get what changed.
local function run(server, m, seconds)
	server:Advance(seconds or 0.3)
	for _, client in ipairs(m.clients) do
		client.time = server.time
	end
	Env.Flush(server, unpack(m.clients))
end

local function settle(server, m)
	for _ = 1, 3 do
		run(server, m, 0.3)
	end
end

-- A player (a client in his language, or a bot) alive at x on a line.
-- opts: language, bot. Returns the player and his client.
local function person(server, m, name, x, opts)
	opts = opts or {}
	local client, ply
	if opts.bot then
		ply = Env.Bot(server, { name = name })
	else
		client, ply = Env.Join(server, { name = name, language = opts.language })
		m.clients[#m.clients + 1] = client
	end
	server:Advance(0.1)
	m.players:Deploy(ply)
	ply:SetPos(Vector(x, 0, 0))
	settle(server, m)
	return ply, client
end

-- The texts the client draws now.
local function drawn(client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

local function hears(server, listener, talker)
	return { server:Call("PlayerCanHearPlayersVoice", listener, talker) }
end

local function last(ply)
	return ply.printed[#ply.printed]
end

describe("voice", function()
	it("is heard by everybody where voices are global, around in 3D as far as the mode carries where local",
		function()
			local server, m = boot()
			local alyx = person(server, m, "Alyx", 0)
			local barney = person(server, m, "Barney", 300, { language = "ru" })
			local eli = person(server, m, "Eli", 2000, { bot = true })
			expect(m.voice:Proximity(alyx)):toBe(false)
			expect(m.voice:Range(alyx)):toBeNil()
			local heard, around = Env.Voice(server, alyx)
			expect(heard):toEqual({ barney, eli })
			expect({ around[barney], around[eli] }):toEqual({ false, false })
			expect(hears(server, barney, alyx)):toEqual({ true, false })
			expect(hears(server, alyx, eli)):toEqual({ true, false })
			Env.Voice(server, alyx, false)
			server:Command("nc_voice", alyx, {})
			expect(alyx.printed[#alyx.printed - 1]):toBe("voice: everywhere")
			expect(last(alyx)):toBe("your voice: normal (everywhere)")

			-- The mode makes voices local: around in 3D, a yell farther, a whisper right next to him.
			m.probe.proximity = true
			run(server, m)
			expect({ m.voice:Proximity(alyx), m.voice:Range(alyx) }):toEqual({ true, 600 })
			heard, around = Env.Voice(server, alyx)
			expect(heard):toEqual({ barney })
			expect(around[barney]):toBe(true)
			expect(hears(server, barney, alyx)):toEqual({ true, true })
			expect(hears(server, eli, alyx)):toEqual({ false, false })
			server:Command("nc_voice", alyx, { "yell" })
			expect(last(alyx)):toBe("your voice: yell (1400 units)")
			expect(m.probe.mode):toEqual({ ply = alyx, mode = "yell", old = "normal" })
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({ barney })
			eli:SetPos(Vector(1300, 0, 0))
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({ barney, eli })
			server:Command("nc_voice", alyx, { "WHISPER" })
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({})
			barney:SetPos(Vector(100, 0, 0))
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({ barney })
			expect(m.voice:Mode(alyx)):toBe("whisper")
			server:Command("nc_voice", alyx, { "cycle" })
			expect(m.voice:Mode(alyx)):toBe("normal")
			server:Command("nc_voice", alyx, { "cycle" })
			server:Command("nc_voice", alyx, { "cycle" })
			expect(m.voice:Mode(alyx)):toBe("whisper")
			server:Command("nc_voice", alyx, { "sing" })
			expect(last(alyx)):toBe("nc_voice: no such mode: whisper, normal, yell or cycle")
			expect({ m.voice:SetMode(alyx, "sing") }):toEqual({ false, "mode" })
			server:Command("nc_voice", alyx, {})
			expect(alyx.printed[#alyx.printed - 1]):toBe("voice: by distance; whisper 120, normal 600, yell 1400 units")
			Env.Voice(server, alyx, false)
			expect(server:Errors()):toEqual({})

			-- Without an answer of a mode the config decides; the voice of a newcomer too.
			server, m = boot({ settings = { proximity = true, mode = "yell", normalRange = 400 } })
			alyx = person(server, m, "Alyx", 0)
			barney = person(server, m, "Barney", 1000, { bot = true })
			expect({ m.voice:Proximity(alyx), m.voice:Mode(alyx), m.voice:Range(alyx) }):toEqual({ true, "yell", 1400 })
			expect(Env.Voice(server, alyx)):toEqual({ barney })
			m.voice:SetMode(alyx, "normal")
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({})
			m.probe.proximity = false
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({ barney })
			expect(server:Errors()):toEqual({})
		end)

	it("keeps the unconscious silent and deaf, the dead apart where voices are local, rounds and modes first",
		function()
			local server, m = boot()
			m.probe.proximity = true
			local alyx = person(server, m, "Alyx", 0)
			local barney = person(server, m, "Barney", 100)
			local eli = person(server, m, "Eli", 200, { bot = true })
			local kleiner = person(server, m, "Kleiner", 5000, { bot = true })
			expect(Env.Voice(server, alyx)):toEqual({ barney, eli })
			Env.Voice(server, alyx, false)

			-- The unconscious hear nothing and nobody hears them.
			m.organism:_Knockout(m.organism:State(barney), 60)
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({ eli })
			Env.Voice(server, alyx, false)
			expect(Env.Voice(server, barney)):toEqual({})
			Env.Voice(server, barney, false)

			-- The dead talk to those who are not alive, anywhere, flat; the living do not hear them.
			Env.Kill(eli)
			Env.Kill(kleiner)
			run(server, m)
			local heard, around = Env.Voice(server, eli)
			expect(heard):toEqual({ kleiner })
			expect(around[kleiner]):toBe(false)
			Env.Voice(server, eli, false)
			expect(Env.Voice(server, alyx)):toEqual({ eli }) -- a dead one near her hears her
			Env.Voice(server, alyx, false)

			-- Where voices are global the dead are heard by all, unless the round says otherwise.
			m.probe.proximity = false
			run(server, m)
			expect(Env.Voice(server, eli)):toEqual({ alyx, kleiner })
			Env.Voice(server, eli, false)
			m.probe.deadMute = true
			expect(Env.Voice(server, eli)):toEqual({ kleiner })
			Env.Voice(server, eli, false)

			-- A module silences a player (voice.canTalk).
			m.probe.mute[alyx] = true
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({})
			Env.Voice(server, alyx, false)
			m.probe.mute[alyx] = nil
			run(server, m)
			expect(Env.Voice(server, alyx)):toEqual({ eli, kleiner })
			Env.Voice(server, alyx, false)
			expect(server:Errors()):toEqual({})
		end)

	it("keeps global voices in the team during team play unless sv_alltalk", function()
		local server, m = boot()
		local alyx = person(server, m, "Alyx", 0)
		local barney = person(server, m, "Barney", 0, { bot = true })
		local eli = person(server, m, "Eli", 0, { bot = true })
		m.teams:SetCount(2)
		m.teams:Assign(alyx, 1)
		m.teams:Assign(barney, 2)
		m.teams:Assign(eli, 1)
		run(server, m)
		expect(Env.Voice(server, alyx)):toEqual({ eli })
		Env.Voice(server, alyx, false)
		server:Command("nc_voice", alyx, {})
		expect(alyx.printed[#alyx.printed - 1]):toBe("voice: everywhere, in the team")
		server:_CreateConVar("sv_alltalk", "0")
		server:SetConVar("sv_alltalk", "1")
		run(server, m)
		expect(Env.Voice(server, alyx)):toEqual({ barney, eli })
		Env.Voice(server, alyx, false)
		-- Where voices are local the teams do not matter: only the distance.
		server:SetConVar("sv_alltalk", "0")
		m.probe.proximity = true
		run(server, m)
		expect(Env.Voice(server, alyx)):toEqual({ barney, eli })
		expect(server:Errors()):toEqual({})
	end)
	it("carries voices flat over radios on the same frequency while the talk key is held", function()
		local server, m = boot()
		m.probe.proximity = true
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 3000, { language = "ru" })
		local eli = person(server, m, "Eli", 6000, { bot = true })
		local inventory, voice = m.inventory, m.voice

		-- Without a radio the talk key only says so.
		expect(voice:Radio(alyx)):toBeNil()
		Env.BindPress(ac, "+nc_radio", true)
		expect(drawn(ac)):toContain("You carry no radio")
		expect(#ac:Sent("nc.voice.ptt")):toBe(0)
		Env.BindPress(ac, "+nc_radio", false)
		server:Command("nc_radio", alyx, {})
		expect(last(alyx)):toBe("radio: none")
		server:Command("nc_radio", alyx, { "7" })
		expect(last(alyx)):toBe("nc_radio: you carry no radio")

		-- Radios: tuned to the default frequency and on; the screen shows the frequency.
		inventory:Give(alyx, "radio")
		inventory:Give(barney, "radio")
		inventory:Give(eli, "radio")
		settle(server, m)
		local radio = voice:Radio(alyx)
		expect({ radio.id, radio.state.frequency, radio.state.label }):toEqual({ "radio", 1, "1" })
		expect({ voice:Frequency(alyx), voice:Frequency(barney) }):toEqual({ 1, 1 })
		local mine = ac:Get("NC").Modules:Instance("voice")
		expect(mine:Radio()):toEqual({ frequency = 1, on = true })
		expect(Env.Voice(server, alyx)):toEqual({})

		-- The talk key: the microphone goes on, every radio on the frequency hears her, flat.
		Env.BindPress(ac, "+nc_radio", true)
		expect(ac.voiceChat):toBe(true)
		expect(mine:IsTransmitting()):toBe(true)
		Env.Flush(server, ac)
		expect(voice:IsTransmitting(alyx)):toBe(true)
		local heard, around = Env.Voice(server, alyx)
		expect(heard):toEqual({ barney, eli })
		expect({ around[barney], around[eli] }):toEqual({ false, false })
		expect(hears(server, barney, alyx)):toEqual({ true, false })
		-- Other frequencies hear nothing; the radio of a listener counts only when it is on.
		server:Command("nc_radio", eli, { "7" })
		expect(m.probe.radio):toEqual({ ply = eli, frequency = 7, on = true })
		expect(voice:Radio(eli).state.label):toBe("7")
		expect(Env.Voice(server, alyx)):toEqual({ barney })
		server:Command("nc_radio", barney, { "off" })
		expect(last(barney)):toBe("radio: 1, off")
		expect(voice:Radio(barney).state.label):toBe("(1)")
		expect(Env.Voice(server, alyx)):toEqual({})
		server:Command("nc_radio", barney, { "on" })
		server:Command("nc_radio", alyx, { "7" })
		expect(last(alyx)):toBe("radio: 7, on")
		expect(Env.Voice(server, alyx)):toEqual({ eli })
		expect(hears(server, barney, alyx)):toEqual({ false, false })
		-- Those around still hear her voice in 3D.
		barney:SetPos(Vector(200, 0, 0))
		run(server, m)
		heard, around = Env.Voice(server, alyx)
		expect(heard):toEqual({ barney, eli })
		expect({ around[barney], around[eli] }):toEqual({ true, false })
		barney:SetPos(Vector(3000, 0, 0))
		run(server, m)

		-- The key released: the microphone goes off, the radios hear nothing.
		Env.BindPress(ac, "+nc_radio", false)
		expect(ac.voiceChat):toBe(false)
		Env.Flush(server, ac)
		expect(voice:IsTransmitting(alyx)):toBe(false)
		expect(Env.Voice(server, alyx)):toEqual({})
		Env.Voice(server, alyx, false)

		-- Wrong frequencies; a radio switched off neither carries nor lets the key work.
		server:Command("nc_radio", alyx, { "1000" })
		expect(last(alyx)):toBe("nc_radio: frequencies are 1-999")
		server:Command("nc_radio", alyx, { "2.5" })
		expect(last(alyx)):toBe("nc_radio: frequencies are 1-999")
		expect({ voice:Tune(alyx, 0) }):toEqual({ false, "frequency" })
		server:Command("nc_radio", alyx, { "off" })
		expect(m.probe.radio):toEqual({ ply = alyx, frequency = 7, on = false })
		settle(server, m)
		expect(mine:Radio()):toEqual({ frequency = 7, on = false })
		Env.BindPress(ac, "+nc_radio", true)
		expect(drawn(ac)):toContain("Your radio is off: /radio on")
		expect(mine:IsTransmitting()):toBe(false)
		expect({ voice:Transmit(alyx, true) }):toEqual({ false, "off" })
		Env.BindPress(ac, "+nc_radio", false)

		-- The verb of the inventory screen switches it; the chat tunes it.
		local item = voice:Radio(alyx)
		expect(inventory:VerbsFor(item, "own", "pockets")[1].id):toBe("radio")
		expect({ inventory:Act(alyx, item.container.id, item.slot, "radio") }):toEqual({ true })
		expect(voice:Frequency(alyx)):toBe(7)
		expect(drawn(ac)):toContain("Radio on: 7")
		Env.Say(server, alyx, "/radio 1")
		expect(ac.chatLines[#ac.chatLines]):toBe("radio: 1, on")
		expect(voice:Frequency(alyx)):toBe(1)
		expect(drawn(bc)):toContain("Рация включена: 1") -- his own notice of nc_radio on

		-- A radio reaches as far as its trait says; the first radio he carries counts.
		inventory:Give(eli, "walkie")
		inventory:Take(eli, "radio", 1)
		settle(server, m)
		expect(voice:Radio(eli).id):toBe("walkie")
		server:Command("nc_radio", eli, { "1" })
		eli:SetPos(Vector(500, 0, 0))
		run(server, m)
		voice:Transmit(eli, true)
		expect(Env.Voice(server, eli)):toEqual({ alyx })
		Env.Voice(server, eli, false)
		eli:SetPos(Vector(6000, 0, 0))
		run(server, m)
		expect(Env.Voice(server, eli)):toEqual({})
		Env.Voice(server, eli, false)
		voice:Transmit(eli, false)

		-- Without the radio: gone from the client, the key does nothing.
		inventory:Take(alyx, "radio", 1)
		settle(server, m)
		expect({ voice:Radio(alyx), mine:Radio() }):toEqual({})
		expect({ voice:Transmit(alyx, true) }):toEqual({ false, "none" })
		expect(server:Errors()):toEqual({})
		expect(ac:Errors()):toEqual({})
		expect(bc:Errors()):toEqual({})
	end)
	it("shows who talks on the HUD by the names others see instead of the base voice panels", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 100, { language = "ru" })
		local theirs = bc:Get("NC").Modules:Instance("voice")
		Env.Voice(server, alyx)
		expect(theirs:Talkers()):toEqual({ alyx })
		expect(drawn(bc)):toContain("Alyx")
		expect(bc.voicePanels):toBeNil() -- the base panel would show the nick and the avatar
		expect(ac.voicePanels):toBeNil()
		-- Her own client shows her voice while she talks.
		local mine = ac:Get("NC").Modules:Instance("voice")
		expect(mine:IsTalking()):toBe(true)
		expect(drawn(ac)):toContain("Your voice: normal")
		Env.Voice(server, alyx, false)
		expect(theirs:Talkers()):toEqual({})
		expect(mine:IsTalking()):toBe(false)
		expect(drawn(bc)):notToContain("Alyx")
		expect(drawn(ac)):notToContain("Your voice: normal")

		-- A yell and a whisper are marked, so is a radio; the names are those others see.
		bc:Get("NC").Modules:Instance("probe").names[alyx] = "Mrs. Vance"
		server:Command("nc_voice", alyx, { "yell" })
		run(server, m)
		expect(drawn(ac)):toContain("Your voice: yell") -- for a moment after the change
		Env.Voice(server, alyx)
		expect(drawn(bc)):toContain("Mrs. Vance · крик")
		Env.Voice(server, alyx, false)
		server:Command("nc_voice", alyx, { "normal" })
		m.inventory:Give(alyx, "radio")
		m.inventory:Give(barney, "radio")
		settle(server, m)
		Env.BindPress(ac, "+nc_radio", true)
		settle(server, m)
		Env.Voice(server, alyx)
		expect(drawn(bc)):toContain("Mrs. Vance · рация")
		expect(drawn(ac)):toContain("You talk into the radio: 1")
		Env.BindPress(ac, "+nc_radio", false)
		Env.Voice(server, alyx, false)
		run(server, m, 4)
		expect(drawn(ac)):toEqual({})
		server:Command("nc_radio", alyx, { "5" })
		settle(server, m)
		expect(drawn(ac)):toContain("Radio: 5")

		-- Many talkers: the first ones and how many more.
		local bots = {}
		for i = 1, 7 do
			bots[i] = person(server, m, "Bot" .. i, 50, { bot = true })
		end
		for _, bot in ipairs(bots) do
			Env.Voice(server, bot)
		end
		local lines = drawn(bc)
		expect(lines):toContain("Bot6")
		expect(lines):notToContain("Bot7")
		expect(lines):toContain("и ещё 1")
		Env.Leave(server, bots[1])
		expect(#theirs:Talkers()):toBe(6)
		expect(server:Errors()):toEqual({})
		expect(ac:Errors()):toEqual({})
		expect(bc:Errors()):toEqual({})
	end)

	it("answers from a matrix rebuilt every refresh, the column of a talker at once", function()
		local server, m = boot({ settings = { refresh = 1 } })
		m.probe.proximity = true
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney = person(server, m, "Barney", 100, { bot = true })
		run(server, m, 1)
		expect(m.voice:Hears(barney, alyx)):toBe("3d")
		barney:SetPos(Vector(5000, 0, 0))
		expect(m.voice:Hears(barney, alyx)):toBe("3d") -- until the next rebuild
		run(server, m, 1)
		expect(m.voice:Hears(barney, alyx)):toBe(false)
		-- The talk key changes the matrix at once.
		m.inventory:Give(alyx, "radio")
		m.inventory:Give(barney, "radio")
		run(server, m, 1)
		run(server, m, 1)
		Env.BindPress(ac, "+nc_radio", true)
		Env.Flush(server, ac)
		expect(m.voice:Hears(barney, alyx)):toBe(true)
		Env.BindPress(ac, "+nc_radio", false)
		Env.Flush(server, ac)
		expect(m.voice:Hears(barney, alyx)):toBe(false)
		-- Those who leave leave the matrix.
		Env.Leave(server, barney)
		expect(m.voice.matrix[barney]):toBeNil()
		expect(m.voice.matrix[alyx][barney]):toBeNil()
		run(server, m, 1)
		expect(m.voice.facts[barney]):toBeNil()
		-- A client that is not ready is not heard and hears nobody yet.
		local stranger = Env.FakePlayer({ name = "Stranger", server = server })
		expect(m.voice:Hears(stranger, alyx)):toBe(false)
		expect(server:Errors()):toEqual({})
	end)

	it("helps with the keys of the voice on the help tab and keeps the key commands out of the commands", function()
		local server, m = boot()
		local _, ac = person(server, m, "Alyx", 0)
		ac.bindings["+voicerecord"] = "x"
		local menu = ac:Get("NC").Modules:Instance("menu")
		local keys = {}
		for _, key in ipairs(menu:Keys()) do
			if key.id:find("^voice%.") then
				keys[#keys + 1] = { key.id, key.key, key.text }
			end
		end
		expect(keys):toEqual({
			{ "voice.talk", "X", "Talk (your voice: normal)" },
			{ "voice.radio", "not bound",
				"Talk into your radio while held (a key for it: bind b +nc_radio; the frequency: /radio 7)" },
			{ "voice.mode", "not bound",
				"Whisper, normal voice or yell in turn (a key for it: bind n \"nc_voice cycle\"; or /voice yell)" },
		})
		ac.bindings["nc_voice cycle"] = "n"
		expect(menu:Keys()[#menu:Keys()].key ~= nil):toBe(true)
		menu:Open("help")
		settle(server, m)
		local names = {}
		for _, command in ipairs(menu:Commands()) do
			names[command.name] = command.help
		end
		expect(names.nc_voice):toBe("[whisper|normal|yell|cycle] - the mode of your voice")
		expect(names.nc_radio):toBe("[frequency|on|off] - your radio")
		expect({ names["+nc_radio"], names["-nc_radio"] }):toEqual({})
		expect(ac:Errors()):toEqual({})
	end)
end)
