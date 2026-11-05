-- Chat: lines in character heard everywhere or around the speaker as the mode answers,
-- whisper and yell, /me and /it, OOC for everybody and LOOC around, private messages by
-- the names others see, chat commands (an answer of a module or a console command of one),
-- the antispam, the unconscious only out of character, the dead and the rules of rounds,
-- team lines, the lines in the chat box in the language of each player and the chat of the
-- help (F1).

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local MODULES = { "players", "notices", "menu", "organism", "teams", "chat" }
local FAST = { rate = 1000, burst = 1000, repeatDelay = 0 } -- no antispam in the way

-- A module of the test: commands, answers of the chat and the names others see.
local PROBE = {
	["nextcity/gamemode/modules/probe/module.lua"] = "return { id = 'probe', files = { sv = { 'sv_probe.lua' } } }",
	["nextcity/gamemode/modules/probe/sv_probe.lua"] = [[
		local M = NC.Module("probe")
		function M:Init(ctx)
			self.names, self.muted, self.blind = {}, {}, {}
			ctx.commands:Add("nc_job", { help = "a job", admin = false }, function(ply, args)
				return "job " .. tostring(args[1]) .. " for " .. ply:Nick()
			end)
			ctx.commands:Add("nc_secret", { help = "for admins" }, function() return "the secret" end)
			ctx.commands:Add("nc_long", { help = "many lines", admin = false }, function()
				local lines = {}
				for i = 1, 15 do
					lines[i] = "line " .. i
				end
				return lines
			end)
		end
		function M:Start(ctx)
			ctx:On("players.name", function(name, ply) return self.names[ply] end)
			ctx:On("chat.proximity", function() return self.proximity end)
			ctx:On("chat.canSpeak", function(ply) if self.muted[ply] then return false end end)
			ctx:On("gm.PlayerCanSeePlayersChat", function(_, _, listener) if self.blind[listener] then return false end end)
			ctx:On("chat.command", function(ply, word, args, rest)
				if word == "roll" then
					return { "rolled " .. tostring(args[1]), rest }
				elseif word == "nope" then
					return false
				elseif word == "quiet" then
					self.quiet = rest
					return true
				end
			end)
			ctx:On("chat.said", function(ply, channel, text, audience)
				self.said = { ply = ply, channel = channel, text = text, audience = audience }
			end)
		end
	]],
}

-- opts: settings of the chat (default FAST).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = MODULES, files = PROBE, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.chat = opts.settings or FAST
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC }
	for _, id in ipairs({ "chat", "players", "organism", "teams", "probe" }) do
		m[id] = NC.Modules:Instance(id)
	end
	return server, m
end

-- A player (a client in his language, or a bot) alive at x on a line.
-- opts: language, superadmin, bot. Returns the player and his client.
local function person(server, m, name, x, opts)
	opts = opts or {}
	local client, ply
	if opts.bot then
		ply = Env.Bot(server, { name = name })
	else
		client, ply = Env.Join(server, { name = name, language = opts.language, superadmin = opts.superadmin })
	end
	server:Advance(0.1)
	m.players:Deploy(ply)
	ply:SetPos(Vector(x, 0, 0))
	if client ~= nil then
		client.time = server.time
		Env.Flush(server, client)
	end
	return ply, client
end

local function last(client)
	return client.chatLines[#client.chatLines]
end

-- The texts the client draws now (the notices among them).
local function drawn(client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("chat", function()
	it("says lines in character to everybody, or around the speaker where the mode makes the chat local", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 200, { language = "ru" })
		local eli = person(server, m, "Eli", 2000, { bot = true })
		expect(m.chat:Proximity(alyx)):toBe(false)
		local said, seen = Env.Say(server, alyx, "  hello\tthere ")
		expect(said):toBe("hello there")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(ac)):toBe("Alyx: hello there")
		expect(last(bc)):toBe("Alyx: hello there")
		expect(eli.heard[#eli.heard]):toEqual({ speaker = alyx, text = "hello there", team = false, channel = "say" })
		expect(#server:Lines("say Alyx: hello there")):toBe(1)

		-- A whisper is always heard only right next to the speaker; a yell and the actions everywhere.
		_, seen = Env.Say(server, alyx, "/w psst")
		expect(seen):toEqual({ alyx })
		expect(last(ac)):toBe("Alyx whispers: psst")
		barney:SetPos(Vector(80, 0, 0))
		_, seen = Env.Say(server, alyx, "/W psst")
		expect(seen):toEqual({ alyx, barney })
		expect(last(bc)):toBe("Alyx шепчет: psst")
		_, seen = Env.Say(server, alyx, "/y RUN")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(bc)):toBe("Alyx кричит: RUN")
		Env.Say(server, alyx, "/me waves")
		expect(last(bc)):toBe("* Alyx waves")
		_, seen = Env.Say(server, alyx, "/it The door creaks")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(bc)):toBe("** The door creaks")
		expect(m.probe.said):toEqual({ ply = alyx, channel = "it", text = "The door creaks",
			audience = { alyx, barney, eli } })

		-- The mode makes the chat local: what is said is heard around, a yell farther.
		m.probe.proximity = true
		expect(m.chat:Proximity(alyx)):toBe(true)
		expect({ m.chat:Range(alyx, "whisper"), m.chat:Range(alyx, "say"), m.chat:Range(alyx, "yell"),
			m.chat:Range(alyx, "ooc") }):toEqual({ 100, 350, 900 })
		_, seen = Env.Say(server, alyx, "hello again")
		expect(seen):toEqual({ alyx, barney })
		_, seen = Env.Say(server, alyx, "/y RUN")
		expect(seen):toEqual({ alyx, barney })
		eli:SetPos(Vector(800, 0, 0))
		_, seen = Env.Say(server, alyx, "/y RUN")
		expect(seen):toEqual({ alyx, barney, eli })
		_, seen = Env.Say(server, alyx, "/me waves")
		expect(seen):toEqual({ alyx, barney })
		_, seen = Env.Say(server, alyx, "/it The door creaks")
		expect(seen):toEqual({ alyx, barney })
		Env.Say(server, alyx, "/chat")
		expect(ac.chatLines):toContain("chat: local; whisper 100, say 350, yell 900, looc 350 units")
		expect(last(ac)):toBe("/w /y /me /it // .// /pm /r /<command>")
		expect(server:Errors()):toEqual({})
		expect(ac:Errors()):toEqual({})
		expect(bc:Errors()):toEqual({})

		-- Without an answer of a mode the config decides.
		server, m = boot({ settings = { proximity = true } })
		alyx = person(server, m, "Alyx", 0)
		barney = person(server, m, "Barney", 1000, { bot = true })
		_, seen = Env.Say(server, alyx, "hello")
		expect(seen):toEqual({ alyx })
		m.probe.proximity = false
		_, seen = Env.Say(server, alyx, "hello all")
		expect(seen):toEqual({ alyx, barney })
	end)

	it("keeps OOC for everybody and LOOC around; the unconscious speak and hear only out of character", function()
		local server, m = boot()
		m.probe.proximity = true
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 100, { language = "ru" })
		local eli = person(server, m, "Eli", 2000, { bot = true })
		local said, seen = Env.Say(server, alyx, "// brb")
		expect(said):toBe("brb")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(ac)):toBe("[OOC] Alyx: brb")
		expect(last(bc)):toBe("[OOC] Alyx: brb")
		_, seen = Env.Say(server, alyx, ".//lag?")
		expect(seen):toEqual({ alyx, barney })
		expect(last(bc)):toBe("[LOOC] Alyx: lag?")
		_, seen = Env.Say(server, alyx, "/ooc same as //")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(Env.Say(server, alyx, "//")):toBeNil()
		expect(drawn(ac)):toContain("Write the text after /ooc")

		m.organism:_Knockout(m.organism:State(barney), 60)
		expect(m.organism:IsUnconscious(barney)):toBe(true)
		said, seen = Env.Say(server, barney, "help me")
		expect(said):toBeNil()
		expect(seen):toEqual({})
		expect(drawn(bc)):toContain("Вы без сознания: только вне роли (// текст)")
		expect(Env.Say(server, barney, "/me moans")):toBeNil()
		expect({ m.chat:Send(barney, "whisper", "psst") }):toEqual({ false, "unconscious" })
		_, seen = Env.Say(server, alyx, "are you ok?")
		expect(seen):toEqual({ alyx })
		_, seen = Env.Say(server, barney, "// knocked out, wait")
		expect(seen):toEqual({ alyx, barney, eli })
		_, seen = Env.Say(server, alyx, ".// ok")
		expect(seen):toEqual({ alyx, barney })
		expect(last(bc)):toBe("[LOOC] Alyx: ok")
		expect(server:Errors()):toEqual({})
	end)

	it("sends private messages by the names others see and replies to the last one", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 5000, { language = "ru" })
		local eli = person(server, m, "Eli Vance", 0, { bot = true })
		local eliza = person(server, m, "Eliza", 0, { bot = true })
		local gman = person(server, m, "Gman", 0, { bot = true })
		m.probe.names[barney], m.probe.names[gman] = "Bravo", "Григорий Ёлкин"

		local said, seen = Env.Say(server, alyx, "/pm bravo hi there")
		expect(said):toBe("hi there")
		expect(seen):toEqual({ alyx, barney })
		expect(last(bc)):toBe("[ЛС] Alyx: hi there")
		expect(last(ac)):toBe("[PM] → Bravo: hi there")
		expect(#server:Lines("pm Alyx -> Bravo: hi there")):toBe(1)
		expect(Env.Say(server, barney, "/r спасибо")):toBe("спасибо")
		expect(last(ac)):toBe("[PM] Bravo: спасибо")
		expect(last(bc)):toBe("[ЛС] → Alyx: спасибо")

		-- Only the names others see count; several words, quotes, any case, a part of one name.
		expect(Env.Say(server, alyx, "/pm barney hi")):toBeNil()
		expect(drawn(ac)):toContain("No such player: /pm <name> <text>")
		_, seen = Env.Say(server, alyx, "/pm Eli Vance come here")
		expect(seen):toEqual({ alyx, eli })
		expect(m.probe.said.text):toBe("come here")
		_, seen = Env.Say(server, alyx, "/pm \"eli vance\" again")
		expect(seen):toEqual({ alyx, eli })
		expect(Env.Say(server, alyx, "/pm eli hi")):toBeNil()
		expect(drawn(ac)):toContain("Several players match: write more of the name")
		_, seen = Env.Say(server, alyx, "/pm liz hi")
		expect(seen):toEqual({ alyx, eliza })
		_, seen = Env.Say(server, alyx, "/pm григорий ёлкин привет")
		expect(seen):toEqual({ alyx, gman })
		_, seen = Env.Say(server, alyx, "/pm ЁЛКИН ещё")
		expect(seen):toEqual({ alyx, gman })
		expect(m.chat:Find("BRAVO")):toBe(barney)
		expect({ m.chat:Find("eli", alyx) }):toEqual({ nil, "many" })
		expect({ m.chat:Find("zzz", alyx) }):toEqual({ nil, "target" })

		-- The reply goes to the last one; nobody to reply to when he left.
		_, seen = Env.Say(server, alyx, "/r bye")
		expect(seen):toEqual({ alyx, gman })
		Env.Leave(server, gman)
		expect(Env.Say(server, alyx, "/r bye")):toBeNil()
		expect(drawn(ac)):toContain("Nobody to reply to yet: /pm <name> <text>")
		expect(Env.Say(server, alyx, "/pm alyx hi")):toBeNil()
		expect(drawn(ac)):toContain("You cannot write to yourself")
		expect(Env.Say(server, alyx, "/pm bravo")):toBeNil()
		expect(drawn(ac)):toContain("Write the text after /pm")
		m.probe.muted[alyx] = true
		expect(Env.Say(server, alyx, "/pm bravo hi")):toBeNil()
		expect(drawn(ac)):toContain("You cannot say that now")
		m.probe.muted[alyx] = nil
		m.probe.blind[barney] = true
		expect(Env.Say(server, alyx, "/pm bravo hi")):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(ac:Errors()):toEqual({})
		expect(bc:Errors()):toEqual({})
	end)

	it("runs chat commands: an answer of a module or a console command of one with its privilege", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 0, { language = "ru" })
		local said, seen = Env.Say(server, alyx, "/job police")
		expect(said):toBeNil()
		expect(seen):toEqual({})
		expect(last(ac)):toBe("job police for Alyx")
		expect(alyx.printed):toContain("job police for Alyx")
		Env.Say(server, alyx, "/JOB \"night guard\"")
		expect(last(ac)):toBe("job night guard for Alyx")
		Env.Say(server, alyx, "/secret")
		expect(last(ac)):toBe("nc_secret: no access")
		local gordon, gc = person(server, m, "Gordon", 0, { superadmin = true })
		Env.Say(server, gordon, "/secret")
		expect(last(gc)):toBe("the secret")

		-- A long reply: the first lines in the chat, all of them in the console.
		Env.Say(server, alyx, "/long")
		expect(last(ac)):toBe("line 12")
		expect(alyx.printed):toContain("line 15")
		expect(drawn(ac)):toContain("3 more lines in the console (~)")

		-- A module answers its words: lines, done, or no.
		Env.Say(server, alyx, "/roll 20 fast")
		expect({ ac.chatLines[#ac.chatLines - 1], last(ac) }):toEqual({ "rolled 20", "20 fast" })
		Env.Say(server, alyx, "/quiet a  b")
		expect(m.probe.quiet):toBe("a  b")
		Env.Say(server, alyx, "/nope")
		expect(drawn(ac)):toContain("You cannot say that now")
		Env.Say(server, alyx, "/xyz")
		expect(drawn(ac)):toContain("Unknown command /xyz: see the help (F1)")
		Env.Say(server, barney, "/xyz")
		expect(drawn(bc)):toContain("Нет команды /xyz: см. справку (F1)")
		Env.Say(server, alyx, "/chat")
		expect(ac.chatLines):toContain("chat: global; whisper 100, say everywhere, yell everywhere, looc 350 units")

		-- Commands are nobody else's business.
		expect(bc.chatLines):notToContain("job police for Alyx")
		expect(m.probe.said):toBeNil()
		expect(server:Errors()):toEqual({})
		expect(ac:Errors()):toEqual({})
	end)

	it("holds back floods: long lines, too many in a row, the same line again", function()
		local server, m = boot({ settings = {} })
		local alyx, ac = person(server, m, "Alyx", 0)
		expect(Env.Say(server, alyx, string.rep("a", 201))):toBeNil()
		expect(drawn(ac)):toContain("A line is at most 200 characters")
		local cyrillic = string.rep("я", 200) -- 400 bytes
		expect(Env.Say(server, alyx, cyrillic)):toBe(cyrillic)
		for i = 1, 4 do
			expect(Env.Say(server, alyx, "line " .. i)):toBe("line " .. i)
		end
		expect(Env.Say(server, alyx, "one more")):toBeNil()
		expect(drawn(ac)):toContain("Not so fast: wait a moment")
		server:Advance(1)
		expect(Env.Say(server, alyx, "one more")):toBe("one more")
		server:Advance(1)
		expect(Env.Say(server, alyx, "one more")):toBeNil()
		expect(drawn(ac)):toContain("You have just said that")
		server:Advance(1.5)
		expect(Env.Say(server, alyx, "one more")):toBe("one more")
		expect({ Env.Say(server, alyx, " \t ") }):toEqual({ nil, {} })
		-- Modules send lines without the antispam.
		for _ = 1, 10 do
			expect(m.chat:Send(alyx, "it", "The wind howls")):toBe(true)
		end
		expect(server:Errors()):toEqual({})
	end)

	it("keeps the dead apart where the chat is local and the rules of the round everywhere", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 3000, { language = "ru" })
		local eli = person(server, m, "Eli", 6000, { bot = true })
		Env.Kill(eli)
		local _, seen = Env.Say(server, eli, "boo")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(ac)):toBe("*DEAD* Eli: boo")
		expect(last(bc)):toBe("*МЁРТВ* Eli: boo")

		-- Where the chat is local the dead talk to those who are not alive, wherever they are.
		m.probe.proximity = true
		_, seen = Env.Say(server, eli, "boo again")
		expect(seen):toEqual({ eli })
		Env.Kill(barney)
		_, seen = Env.Say(server, eli, "hi Barney")
		expect(seen):toEqual({ barney, eli })
		_, seen = Env.Say(server, eli, "// gg")
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(ac)):toBe("[OOC] Eli: gg")

		-- gm.PlayerCanSeePlayersChat decides last (the rule dead_mute of rounds answers it).
		m.probe.proximity = nil
		m.probe.blind[barney] = true
		_, seen = Env.Say(server, alyx, "anyone?")
		expect(seen):toEqual({ alyx, eli })
		m.probe.muted[alyx] = true
		expect(Env.Say(server, alyx, "anyone?")):toBeNil()
		expect(drawn(ac)):toContain("You cannot say that now")
		expect(server:Errors()):toEqual({})
	end)

	it("keeps team lines in the team during team play", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local barney, bc = person(server, m, "Barney", 0, { language = "ru" })
		local eli = person(server, m, "Eli", 0, { bot = true })
		local _, seen = Env.Say(server, alyx, "push", true)
		expect(seen):toEqual({ alyx, barney, eli })
		expect(last(bc)):toBe("Alyx: push")
		m.teams:SetCount(2)
		m.teams:Assign(alyx, 1)
		m.teams:Assign(barney, 2)
		m.teams:Assign(eli, 1)
		_, seen = Env.Say(server, alyx, "push", true)
		expect(seen):toEqual({ alyx, eli })
		expect(last(ac)):toBe("(TEAM) Alyx: push")
		expect(eli.heard[#eli.heard].team):toBe(true)
		_, seen = Env.Say(server, barney, "защищаем", true)
		expect(seen):toEqual({ barney })
		expect(last(bc)):toBe("(КОМАНДА) Barney: защищаем")
		_, seen = Env.Say(server, barney, "/y все сюда", true)
		expect(seen):toEqual({ alyx, barney, eli })
		expect(server:Errors()):toEqual({})
	end)

	it("filters the lines like the base chat and helps with the chat on the help tab", function()
		local server, m = boot()
		local alyx, ac = person(server, m, "Alyx", 0)
		local filtered = {}
		ac.textFilter = function(text, context, ply)
			filtered[#filtered + 1] = { context, ply }
			return (text:gsub("darn", "****"))
		end
		Env.Say(server, alyx, "darn it")
		expect(last(ac)):toBe("Alyx: **** it")
		expect(filtered):toEqual({ { 1, alyx } })
		Env.Say(server, alyx, "/job darn")
		expect(last(ac)):toBe("job darn for Alyx") -- replies of the server are not filtered

		local menu = ac:Get("NC").Modules:Instance("menu")
		local keys, texts = {}, {}
		for i, key in ipairs(menu:Keys("chat")) do
			keys[i], texts[i] = key.key, key.text
		end
		expect(keys):toEqual({ "/w", "/y", "/me", "/it", "//", ".//", "/pm", "/r", "/..." })
		expect(texts[3]):toBe("an action of your character: * Name opens the door")
		for _, key in ipairs(menu:Keys()) do
			expect(key.id:find("^chat%.") == nil):toBe(true)
		end
		menu:Open("help")
		expect(#World.FindPanels(ac, function(panel)
			return panel.class == "DLabel" and panel:GetText() == "Chat — type it in the chat box (Y)"
		end)):toBe(1)
		expect(#World.FindPanels(ac, function(panel)
			return rawget(panel, "ncHelp") == "chat.pm"
		end)):toBe(1)
		expect(m.chat.ctx ~= nil):toBe(true)
		expect(ac:Errors()):toEqual({})
	end)
end)
