-- HUD module: the hidden HL2 elements, the statuses of the body, the armor worn, the screen
-- effects and the black screen of an unconscious player, in the language of the player,
-- with the real gamemode files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local function boot(language)
	local server = Env.Server({ modules = { "players", "organism", "damage", "armor", "hud" } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local client, ply = Env.Join(server, { name = "Gordon", language = language })
	NC.Modules:Instance("players"):Deploy(ply)
	local function sync(seconds) -- the server runs, the client follows its clock and gets the news
		for _ = 1, math.floor((seconds or 0.3) / 0.1 + 0.5) do
			server:Advance(0.1)
		end
		client:Advance(server.time - client.time)
		Env.Flush(server, client)
	end
	sync()
	return server, client, ply, NC.Modules:Instance("organism"), NC.Modules:Instance("armor"), sync
end

local function paint(client)
	client.drawn, client.rects = {}, {}
	client:Call("HUDPaint")
	return client.drawn, client.rects
end

local function has(list, item)
	for _, value in ipairs(list) do
		if value == item then
			return true
		end
	end
	return false
end

describe("hud", function()
	it("hides the health and the suit of HL2, and the weapon elements while unconscious", function()
		local server, client, ply, organism, _, sync = boot()
		expect(client:Call("HUDShouldDraw", "CHudHealth")):toBe(false)
		expect(client:Call("HUDShouldDraw", "CHudBattery")):toBe(false)
		expect(client:Call("HUDShouldDraw", "CHudCrosshair")):toBe(true)
		expect(client:Call("HUDShouldDraw", "CHudAmmo")):toBe(true)
		organism:_Knockout(organism:State(ply), 60)
		sync()
		expect(client:Call("HUDShouldDraw", "CHudCrosshair")):toBe(false)
		expect(client:Call("HUDShouldDraw", "CHudChat")):toBe(true)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("tells what is wrong with the body in the order of the flags, in the language of the player", function()
		local server, client, _, _, _, sync = boot()
		expect(paint(client)):toEqual({})
		server:Command("nc_hurt", nil, { "Gordon", "bullet", "femur_l" })
		sync()
		local drawn = paint(client)
		expect(has(drawn, "Broken left leg")):toBe(true)
		expect(has(drawn, "Bleeding") or has(drawn, "Heavy bleeding")):toBe(true)
		local hud = client:Get("NC").Modules:Instance("hud")
		local lines = hud.statuses
		sync()
		expect(hud.statuses):toBe(lines) -- not rebuilt while nothing changes
		expect(server:Errors()):toEqual({})

		local ruServer, ruClient, _, _, _, ruSync = boot("ru")
		ruServer:Command("nc_hurt", nil, { "Gordon", "bullet", "femur_l" })
		ruSync()
		expect(has(paint(ruClient), "Перелом левой ноги")):toBe(true)
		expect(client:Errors()):toEqual({})
		expect(ruClient:Errors()):toEqual({})
	end)

	it("shows the armor worn and its condition", function()
		local server, client, ply, _, armor, sync = boot("ru")
		armor:Equip(ply, "vest", 0.854)
		armor:Equip(ply, "helmet")
		sync(0.5)
		local drawn = paint(client)
		expect(has(drawn, "Баллистический шлем 100%")):toBe(true)
		expect(has(drawn, "Бронежилет 85%")):toBe(true)
		armor:Strip(ply)
		sync(0.5)
		expect(has(paint(client), "Бронежилет 85%")):toBe(false)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("greys, darkens and blurs the screen with the state of the body", function()
		local server, client, ply, organism, _, sync = boot()
		client.effects = {}
		client:Call("RenderScreenspaceEffects")
		expect(client.effects):toEqual({})
		local st = organism:State(ply)
		st.blood = st.volume * 0.62
		st.concussion = 0.6
		sync(1)
		local vitals = client:Get("NC").Modules:Instance("organism"):Vitals()
		expect(vitals.grey > 0.2 and vitals.blur > 0.2):toBe(true)
		client:Call("RenderScreenspaceEffects")
		local color, blur = client.effects[1], client.effects[2]
		expect(color[1]):toBe("color")
		expect(color[2]["$pp_colour_colour"] < 0.85):toBe(true)
		expect(blur[1]):toBe("blur")
		expect(blur[3]):toBeCloseTo(vitals.blur, 1e-9)
		vitals.dark = 0.5 -- tunnel vision: the oxygen of the brain falls in minutes of shock
		local _, rects = paint(client)
		expect(rects[1][1]):toBe("vgui/gradient-l")
		expect(#rects):toBe(4)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("goes black while unconscious and tells when the player may give up", function()
		local server, client, ply, organism, _, sync = boot()
		organism:_Knockout(organism:State(ply), 60)
		sync()
		local drawn, rects = paint(client)
		expect(rects[1]):toEqual({ 0, 0, 1920, 1080, 0, 0, 0, 255 })
		expect(drawn[1]):toBe("Unconscious")
		expect(drawn[2] == "You can give up in 5 s" or drawn[2] == "You can give up in 4 s"):toBe(true)
		client.effects = {}
		client:Call("RenderScreenspaceEffects")
		expect(client.effects):toEqual({})
		sync(5)
		drawn = paint(client)
		expect(drawn[2]):toBe("Press R to give up")
		client.bindings["+reload"] = nil
		client:Get("NC").Modules:Instance("hud"):Rebuild()
		expect(paint(client)[2]):toBe("Press R to give up")
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
