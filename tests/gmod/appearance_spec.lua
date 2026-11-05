-- Appearance: the look of every player's character in his profile (newcomers get a random
-- one of the sets for their gender), the checks of a change (the sets of the gender, the
-- cooldown, modes), the clothes put on at a spawn below the answers of modes and changed by
-- modes, looks that follow the gender, the color of the clothes on bodies, the appearance
-- tab of the menu.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local format = string.format

local MODULES = { "players", "storage", "profiles", "identity", "appearance", "wardrobe", "notices", "menu" }
local KLEINER = "models/player/kleiner.mdl"

local function male(n)
	return format("models/player/group01/male_%02d.mdl", n)
end

local function female(n)
	return format("models/player/group01/female_%02d.mdl", n)
end

-- opts: data (DATA of an earlier server), settings of appearance. Random picks the first of
-- everything: identity the first gender (male), appearance the first model and color.
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = MODULES, data = opts.data, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.appearance = opts.settings
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	NC.Modules:Instance("identity").Random = function() return 1 end
	local appearance = NC.Modules:Instance("appearance")
	appearance.Random = function() return 1 end
	return server, NC, appearance
end

-- Lets the server answer and the client learn it.
local function settle(server, client)
	for _ = 1, 2 do
		server:Advance(0.5)
		client.time = server.time
		Env.Flush(server, client)
	end
end

-- The texts the client draws (the notices among them).
local function hud(server, client)
	settle(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

local function panels(client, field, value)
	return World.FindPanels(client, function(panel)
		return rawget(panel, field) ~= nil and (value == nil or rawget(panel, field) == value)
	end)
end

local function click(client, field, value)
	local button = panels(client, field, value)[1]
	assert(button ~= nil, "no panel with " .. field .. " = " .. tostring(value))
	button.DoClick(button)
end

local function step(client, id, dir)
	local button = World.FindPanels(client, function(panel)
		return rawget(panel, "ncStep") == id and rawget(panel, "ncDir") == dir
	end)[1]
	assert(button ~= nil, "no step " .. id)
	button.DoClick(button)
end

-- The values of the steppers of the tab: { [id] = "2 / 3" }.
local function values(client)
	local out = {}
	for _, panel in ipairs(panels(client, "ncValue")) do
		out[panel.ncValue] = panel:GetText()
	end
	return out
end

local function sets(client)
	local out = {}
	for _, panel in ipairs(panels(client, "ncSet")) do
		out[#out + 1] = panel.ncSet
	end
	return out
end

local function labels(client)
	local out = {}
	for _, panel in ipairs(World.FindPanels(client, function(panel) return panel.class == "DLabel" end)) do
		out[#out + 1] = panel:GetText()
	end
	return out
end

local function ids(list)
	local out = {}
	for i, set in ipairs(list) do
		out[i] = set.id
	end
	return out
end

describe("appearance", function()
	it("gives a newcomer a random look of the sets for his gender and keeps it in his profile", function()
		local server, NC, appearance = boot()
		expect(ids(appearance:Sets())):toEqual({ "citizens_male", "citizens_female", "refugees" })
		expect(ids(appearance:Sets("male"))):toEqual({ "citizens_male", "refugees" })
		expect(ids(appearance:Sets("female"))):toEqual({ "citizens_female" })
		expect(appearance:SetOf("Models\\Player\\Group01\\Male_05.mdl").id):toBe("citizens_male")
		expect(appearance:Allows(female(2), "male")):toBe(false)
		expect(#appearance:Models("male")):toBe(13)

		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local look = appearance:Look(gordon)
		expect({ look.model, look.skin, look.bodygroups, look.color, look.random })
			:toEqual({ male(1), 0, {}, 0x3E586A, true })
		local players = NC.Modules:Instance("players")
		players:Deploy(gordon)
		expect(gordon:GetModel()):toBe(male(1))
		expect(appearance.FromVector(gordon:GetPlayerColor())):toBe(0x3E586A)
		settle(server, client)
		local mine = client:Get("NC").Modules:Instance("appearance")
		expect(mine:Look().model):toBe(male(1))
		expect(mine:Wait()):toBe(0)
		gordon.printed = {}
		server:Command("nc_look", gordon, {})
		expect(gordon.printed[1])
			:toBe("nc_look: models/player/group01/male_01.mdl, skin 0, bodygroups [], color 62 88 106 (given at random)")
		server:Command("nc_looks", gordon, {})
		expect(gordon.printed[2])
			:toBe("citizens_male (male): 9 models\ncitizens_female (female): 6 models\nrefugees (male): 4 models")

		-- The profile keeps it for the next visit.
		expect(NC.Modules:Instance("profiles"):Section(gordon, "appearance").model):toBe(male(1))
		Env.Leave(server, gordon)
		server:Advance(3)
		local again, NC2, appearance2 = boot({ data = server.data })
		local _, back = Env.Join(again, { name = "Gordon", index = gordon:EntIndex(), language = "en" })
		expect({ appearance2:Look(back).model, appearance2:Look(back).random }):toEqual({ male(1), true })
		NC2.Modules:Instance("players"):Deploy(back)
		expect(back:GetModel()):toBe(male(1))

		-- Without random looks a newcomer wears the model of the game until he chooses one.
		local plain, NC3, appearance3 = boot({ settings = { random = false } })
		local _, eli = Env.Join(plain, { name = "Eli", language = "en" })
		expect(appearance3:Look(eli)):toBe(nil)
		NC3.Modules:Instance("players"):Deploy(eli)
		expect(eli:GetModel()):toBe(KLEINER)
		expect(server:Errors()):toEqual({})
		expect(again:Errors()):toEqual({})
		expect(plain:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("changes a look within the sets of the gender once in a cooldown; modes may forbid it", function()
		local server, NC, appearance = boot()
		World.MODELS[male(3)] = { skins = 2, bodygroups = { { "studio", 1 }, { "hat", 3 }, { "glasses", 2 } } }
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		NC.Modules:Instance("players"):Deploy(gordon)
		local changes = {}
		NC.Events:On("appearance.changed", function(ply, look, old)
			changes[#changes + 1] = { ply == gordon, look.model, old ~= nil and old.model or "none" }
		end)
		expect({ appearance:Change(gordon, { model = female(1) }) }):toEqual({ false, "model" })
		expect({ appearance:Change(gordon, { model = KLEINER }) }):toEqual({ false, "model" })
		expect({ appearance:Change(gordon, { model = male(1), color = 0x3E586A }) }):toEqual({ false, "same" })

		-- The skin and the bodygroups are kept as chosen and put on as far as the model has them.
		expect(appearance:Request(gordon, { model = "Models\\Player\\Group01\\Male_03.mdl", skin = 5,
			bodygroups = { 0, 2, 7, 0 }, color = 0x7A2E2E })):toBe(true)
		expect(gordon:GetModel()):toBe(male(3))
		expect({ gordon:GetSkin(), gordon:GetBodygroup(1), gordon:GetBodygroup(2) }):toEqual({ 1, 2, 1 })
		expect(appearance.FromVector(gordon:GetPlayerColor())):toBe(0x7A2E2E)
		local look = appearance:Look(gordon)
		expect({ look.model, look.skin, look.bodygroups, look.color, look.random })
			:toEqual({ male(3), 5, { 0, 2, 7 }, 0x7A2E2E, false })
		expect({ appearance:Change(gordon, { model = male(4) }) }):toEqual({ false, "cooldown", 10 })
		expect(hud(server, client)):toContain("Your look is saved")
		expect(appearance:Request(gordon, { model = male(4) })):toBe(false)
		expect(hud(server, client)):toContain("You can change the look in 9 seconds")

		-- After the cooldown; a mode may forbid changes, admins and modules force them.
		server:Advance(8)
		local deny = NC.Events:On("appearance.canChange", function() return false end)
		expect({ appearance:Change(gordon, { model = male(4) }) }):toEqual({ false, "denied" })
		expect(appearance:Change(gordon, { model = male(4) }, true)):toBe(true)
		deny:Off()
		gordon.printed = {}
		server:Command("nc_look", gordon, { "random" })
		expect(gordon.printed[1]):toBe("nc_look: models/player/group01/male_01.mdl, skin 0, bodygroups [], "
			.. "color 62 88 106 (given at random)")
		appearance.Random = function(n) return n end
		server:Command("nc_look", gordon, { "random" })
		expect(gordon.printed[2]):toBe("nc_look: cooldown (10 s)")
		expect(changes):toEqual({ { true, male(3), male(1) }, { true, male(4), male(3) }, { true, male(1), male(4) } })
		World.MODELS[male(3)] = nil
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("a random look follows the gender of the character; an own one stays while the gender may wear it", function()
		local server, NC, appearance = boot()
		local _, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local identity = NC.Modules:Instance("identity")
		NC.Modules:Instance("players"):Deploy(gordon)
		expect(appearance:Look(gordon).model):toBe(male(1))
		expect(identity:Change(gordon, nil, "female", true)):toBe(true)
		expect({ appearance:Look(gordon).model, appearance:Look(gordon).random }):toEqual({ female(1), true })
		expect(gordon:GetModel()):toBe(female(1))

		-- A look of a set for everybody stays with any gender.
		appearance:AddSet("science", { models = { KLEINER } })
		expect(appearance:Change(gordon, { model = KLEINER }, true)):toBe(true)
		expect(identity:Change(gordon, nil, "male", true)):toBe(true)
		expect({ appearance:Look(gordon).model, appearance:Look(gordon).random }):toEqual({ KLEINER, false })

		-- One the new gender may not wear goes: a random one of the new gender comes.
		expect(appearance:Change(gordon, { model = male(2) }, true)):toBe(true)
		expect(identity:Change(gordon, nil, "female", true)):toBe(true)
		expect({ appearance:Look(gordon).model, appearance:Look(gordon).random }):toEqual({ female(1), true })

		-- A look of a set that went away goes at the next visit.
		expect(appearance:Change(gordon, { model = KLEINER }, true)):toBe(true)
		Env.Leave(server, gordon)
		server:Advance(3)
		local again, _, appearance2 = boot({ data = server.data })
		local _, back = Env.Join(again, { name = "Gordon", index = gordon:EntIndex(), language = "en" })
		expect({ appearance2:Look(back).model, appearance2:Look(back).random }):toEqual({ female(1), true })
		expect(server:Errors()):toEqual({})
		expect(again:Errors()):toEqual({})
	end)

	it("lets modes dress players first and change looks; bodies keep the color of the clothes", function()
		local server, NC, appearance = boot()
		World.MODELS[male(1)] = { skins = 3, bodygroups = { { "studio", 1 }, { "hat", 2 } } }
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local players = NC.Modules:Instance("players")
		expect(appearance:Change(gordon, { model = male(1), skin = 2, bodygroups = { 0, 1 }, color = 0x2E6B6B }, true))
			:toBe(true)

		-- A uniform of a mode wins; the color of the clothes still goes on.
		local uniform = NC.Events:On("gm.PlayerSetModel", function() return "models/player/police.mdl" end)
		players:Deploy(gordon)
		expect({ gordon:GetModel(), gordon:GetSkin() }):toEqual({ "models/player/police.mdl", 0 })
		expect(appearance.FromVector(gordon:GetPlayerColor())):toBe(0x2E6B6B)
		uniform:Off()
		expect(appearance:Dress(gordon)):toBe(true)
		expect({ gordon:GetModel(), gordon:GetSkin(), gordon:GetBodygroup(1) }):toEqual({ male(1), 2, 1 })

		-- A mode changes the look he wears, his own stays in the profile.
		local masks = NC.Events:On("appearance.look", function(look)
			look.model, look.color = KLEINER, 0xFF0000
			return look
		end)
		players:Deploy(gordon)
		expect(gordon:GetModel()):toBe(KLEINER)
		expect(appearance.FromVector(gordon:GetPlayerColor())):toBe(0xFF0000)
		expect(appearance:Effective(gordon).model):toBe(KLEINER)
		expect(appearance:Look(gordon).model):toBe(male(1))
		masks:Off()
		appearance:Dress(gordon)
		expect(gordon:GetModel()):toBe(male(1))

		-- A body and a corpse keep the color he wore (a prop_ragdoll has no owner).
		local rag = Env.Spawn(server, { class = "prop_ragdoll" })
		NC.Events:Emit("ragdoll.fell", gordon, rag, "command")
		settle(server, client)
		expect(appearance.FromVector(rag:GetPlayerColor())):toBe(0x2E6B6B)
		World.MODELS[male(1)] = nil
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("has a tab in the menu: the preview, the sets of the gender, models, skins, bodygroups, colors", function()
		local server, NC, appearance = boot()
		World.MODELS[male(3)] = { skins = 3, bodygroups = { { "studio", 1 }, { "hat", 3 } } }
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		settle(server, client)
		local menu = client:Get("NC").Modules:Instance("menu")
		local mine = client:Get("NC").Modules:Instance("appearance")
		mine.Random = function() return 2 end
		menu:Open("appearance")
		expect(menu:Tab()):toBe("appearance")
		expect(panels(client, "ncTab", "appearance")[1]:GetText()):toBe("Appearance")
		local texts = labels(client)
		expect(texts):toContain("Your look")
		expect(texts):toContain("The look was given at random: choose your own")
		expect(sets(client)):toEqual({ "citizens_male", "refugees" })
		expect(panels(client, "ncSet", "citizens_male")[1].ncActive):toBe(true)
		expect(#panels(client, "ncModel")):toBe(9)
		expect(panels(client, "ncModel", male(1))[1].ncActive):toBe(true)
		expect(panels(client, "ncPreview")[1]:GetModel()):toBe(male(1))
		expect(values(client)):toEqual({})

		-- A model with skins and a hat, a color of the palette and one of the mixer.
		click(client, "ncModel", male(3))
		expect(panels(client, "ncPreview")[1]:GetModel()):toBe(male(3))
		expect(values(client)):toEqual({ skin = "1 / 3", bodygroup1 = "1 / 3" })
		step(client, "skin", 1)
		step(client, "skin", 1)
		step(client, "bodygroup1", -1)
		expect(values(client)):toEqual({ skin = "3 / 3", bodygroup1 = "3 / 3" })
		local color = appearance.PALETTE[5]
		click(client, "ncColor", color)
		expect(panels(client, "ncColor", color)[1].ncActive):toBe(true)
		local preview = panels(client, "ncPreview")[1]
		expect({ preview.Entity:GetSkin(), preview.Entity:GetBodygroup(1) }):toEqual({ 2, 2 })
		expect(appearance.FromVector(preview.Entity:GetPlayerColor())):toBe(color)
		expect(labels(client)):toContain("The look is not saved yet")
		local mixer = panels(client, "ncMixer")[1]
		mixer.ValueChanged(mixer, { r = 10, g = 20, b = 30 })
		expect(appearance.FromVector(preview.Entity:GetPlayerColor())):toBe(appearance.Pack(10, 20, 30))
		click(client, "ncAction", "save")
		expect(#client:Sent("nc.appearance.change")):toBe(1)
		expect(hud(server, client)):toContain("Your look is saved")
		local look = appearance:Look(gordon)
		expect({ look.model, look.skin, look.bodygroups, look.color, look.random })
			:toEqual({ male(3), 2, { 0, 2 }, appearance.Pack(10, 20, 30), false })
		menu:Refresh(false)
		expect(panels(client, "ncWait")[1]:GetText()):toBe("You can change the look again in 10 seconds")
		expect({ #panels(client, "ncUnsaved"), #panels(client, "ncGiven") }):toEqual({ 0, 0 })
		expect(mine:Draft()):toBe(nil)

		-- Another set, undone; a random look.
		click(client, "ncSet", "refugees")
		expect(panels(client, "ncPreview")[1]:GetModel()):toBe("models/player/group02/male_02.mdl")
		expect(panels(client, "ncSet", "refugees")[1].ncActive):toBe(true)
		click(client, "ncAction", "undo")
		expect(panels(client, "ncPreview")[1]:GetModel()):toBe(male(3))
		click(client, "ncAction", "random")
		expect(mine:Draft()):toEqual({ model = male(2), skin = 0, bodygroups = {}, color = appearance.PALETTE[2] })

		-- A female character sees her sets; the draft of a man goes. A uniform: the tab says so.
		NC.Modules:Instance("identity"):Change(gordon, nil, "female", true)
		settle(server, client)
		menu:Refresh(false)
		expect(sets(client)):toEqual({ "citizens_female" })
		expect(mine:Draft()):toBe(nil)
		NC.Events:On("gm.PlayerSetModel", function() return "models/player/police_fem.mdl" end)
		NC.Modules:Instance("players"):Deploy(gordon)
		settle(server, client)
		menu:Refresh(false)
		expect(panels(client, "ncDressed")[1]:GetText())
			:toBe("A mode dresses you in its own way now: your look comes back when it stops")
		World.MODELS[male(3)] = nil
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
