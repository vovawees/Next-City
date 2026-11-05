-- Doors (the core module with the city of the official package): doors as property sold
-- for money, locks with the keys of owners, co-owners and groups, titles, the settings of
-- the map kept across cleanups and restarts, lockpicks and battering rams.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local IN = World.IN

local DOORS = {
	{ "prop_door_rotating", 1001 }, { "prop_door_rotating", 1002 }, { "func_door", 1003 },
	{ "func_door_rotating", 1004 },
}

-- A shot-mask line of a player in `aims` hits the entity he aims at.
local function aim(realm, aims)
	local shot = realm:Get("MASK_SHOT")
	realm.traceLine = function(trace)
		local ent = aims[trace.filter]
		if ent ~= nil and trace.mask == shot then
			return { Hit = true, Entity = ent, HitPos = ent:GetPos(), Fraction = 0.5, StartSolid = false }
		end
		return { Hit = false, Entity = World.NULL, Fraction = 1, StartSolid = false, HitPos = Vector(trace.endpos) }
	end
end

-- opts: data (DATA of an earlier server).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ data = opts.data, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.rounds = { mode = "city", shuffle = false }
		return cfg
	end } })
	for i = 0, 5 do
		Env.Spawn(server, { class = "info_player_start", pos = Vector(i * 400, 0, 0), map = true })
	end
	for _, entry in ipairs(DOORS) do
		Env.Spawn(server, { class = entry[1], pos = Vector(40, 0, 60), map = true, mapId = entry[2] })
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC, aims = {} }
	aim(server, m.aims)
	for _, id in ipairs({ "rounds", "players", "inventory", "economy", "actions", "doors", "mode_city" }) do
		m[id] = NC.Modules:Instance(id)
	end
	return server, m
end

local function run(server, seconds)
	for _ = 1, math.floor(seconds / 0.1 + 0.5) do
		server:Advance(0.1)
	end
end

local function hud(server, client)
	server:Advance(0.3)
	client.time = server.time
	Env.Flush(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

-- A player at the origin looking at the door (both stay in reach of each other).
local function face(m, ply, door)
	ply:SetPos(Vector(0, 0, 0))
	ply:SetEyeAngles(World.Angle(0, 0, 0))
	m.aims[ply] = door
end

-- The use key, with the walk key held when `alt`.
local function use(server, ply, alt)
	ply.keys[IN.WALK] = alt == true or nil
	Env.Press(server, ply, IN.USE)
	ply.keys[IN.WALK] = nil
end

local function byMapId(m, id)
	for _, ent in ipairs(m.doors:All()) do
		if ent:MapCreationID() == id then
			return ent
		end
	end
	return nil
end

-- Door `i` of DOORS now (a cleanup at the start of a round makes new entities).
local function door(m, i)
	return byMapId(m, DOORS[i][2])
end

describe("doors", function()
	it("sells the doors of the city; the owner locks them, gives keys, titles and sells them", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local doors, economy = m.doors, m.economy
		run(server, 5.3)
		local shut = m.NC.Events:On("doors.property", function() return false end, { priority = 100 })
		expect({ doors:Buy(gordon, door(m, 1)) }):toEqual({ false, "closed" })
		shut:Off()
		local front, back = door(m, 1), door(m, 2)
		expect(#doors:All()):toBe(4)
		expect({ doors:IsDoor(front), doors:IsDoor(gordon), doors:ForSale(front) }):toEqual({ true, false, true })

		-- Buying: the money, the owner everybody sees.
		expect({ doors:Buy(gordon, front) }):toEqual({ true, 100 })
		expect({ economy:Balance(gordon), doors:Owner(front) }):toEqual({ 400, gordon })
		expect({ doors:Buy(gordon, front) }):toEqual({ false, "yours" })
		expect({ doors:Buy(alyx, front) }):toEqual({ false, "owned" })
		expect({ doors:Buy(gordon, gordon) }):toEqual({ false, "door" })
		hud(server, client)
		local cl = client:Get("NC").Modules:Instance("doors")
		expect({ cl:Owner(front), cl:ForSale(front), cl:ForSale(back) }):toEqual({ gordon, false, true })

		-- The keys: Alt + E locks and unlocks, the others cannot.
		face(m, gordon, front)
		use(server, gordon, true)
		expect(front.locked):toBe(true)
		expect(doors:IsLocked(front)):toBe(true)
		expect(hud(server, client)):toContain("Locked")
		expect(cl:Info(front).locked):toBe(true)
		face(m, alyx, front)
		use(server, alyx, true)
		expect(front.locked):toBe(true)
		expect({ doors:Lock(alyx, front, false) }):toEqual({ false, "keys" })

		-- Co-owners hold the keys too; one gives them back.
		expect(doors:AddCoowner(gordon, front, alyx)):toBe(true)
		expect({ doors:AddCoowner(gordon, front, alyx) }):toEqual({ false, "already" })
		expect({ doors:AddCoowner(alyx, front, gordon) }):toEqual({ false, "owner" })
		expect({ doors:AddCoowner(gordon, front, gordon) }):toEqual({ false, "target" })
		expect(doors:HasKeys(alyx, front)):toBe(true)
		use(server, alyx, true)
		expect(front.locked):toBe(false)
		expect(doors:RemoveCoowner(alyx, front, alyx)):toBe(true)
		expect(doors:HasKeys(alyx, front)):toBe(false)

		-- The owner names his door.
		expect(doors:SetTitle(gordon, front, "  Gordon's   place ")):toBe(true)
		expect(doors:Title(front)):toBe("Gordon's place")
		expect({ doors:SetTitle(gordon, front, string.rep("x", 49)) }):toEqual({ false, "long" })
		expect({ doors:SetTitle(gordon, front, "<b>mine") }):toEqual({ false, "chars" })
		expect({ doors:SetTitle(alyx, front, "Alyx") }):toEqual({ false, "owner" })

		-- The menu over the net and the command.
		face(m, gordon, back)
		cl:Ask("buy", back)
		hud(server, client)
		expect({ doors:Owner(back), economy:Balance(gordon) }):toEqual({ gordon, 300 })
		cl:Ask("add", back, alyx)
		cl:Ask("title", back, "Back door")
		hud(server, client)
		expect({ doors:IsCoowner(alyx, back), doors:Title(back) }):toEqual({ true, "Back door" })
		gordon.printed = {}
		server:Command("nc_door", gordon, {})
		expect(gordon.printed[1]):toBe("door " .. back:EntIndex() .. " (map 1002), owner Gordon, co-owners Alyx, "
			.. "title \"Back door\", unlocked")
		server:Command("nc_door", gordon, { "lock" })
		expect(back.locked):toBe(true)

		-- Selling: half of the price back, the door clean and unlocked.
		expect({ doors:Sell(alyx, front) }):toEqual({ false, "owner" })
		expect({ doors:Sell(gordon, back) }):toEqual({ true, 50 })
		expect({ economy:Balance(gordon), back.locked, doors:Info(back) }):toEqual({ 350, false, nil })
		expect(doors:Owned(gordon)):toEqual({ front })

		-- A player who leaves loses his doors and his keys.
		expect(doors:Buy(alyx, back)):toBe(true)
		doors:AddCoowner(gordon, front, alyx)
		Env.Leave(server, alyx)
		expect({ doors:Owner(back), doors:IsCoowner(alyx, front), doors:ForSale(back) }):toEqual({ nil, false, true })

		-- The end of the city puts every door back on the market.
		m.rounds:Round():End({ reason = "test" })
		run(server, 8.2)
		expect({ doors:Owner(front), doors:Info(front), doors:Owned(gordon) }):toEqual({ nil, nil, {} })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("keeps the doors of the map for groups, titles and off the market, across cleanups and restarts", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru", superadmin = true })
		local alyx = Env.Bot(server, { name = "Alyx" })
		run(server, 5.3)
		local doors, city = m.doors, m.mode_city
		local station, hall = door(m, 3), door(m, 4)
		face(m, gordon, station)
		gordon.printed = {}
		server:Command("nc_doormap", gordon, { "group", "police" })
		server:Command("nc_doormap", gordon, { "title", "Police", "station" })
		face(m, gordon, hall)
		server:Command("nc_doormap", gordon, { "closed", "yes" })
		expect(gordon.printed[3]):toBe("door " .. hall:EntIndex() .. " (map 1004), not for sale, unlocked")
		expect({ doors:Group(station), doors:Title(station), doors:ForSale(station), doors:ForSale(hall) })
			:toEqual({ "police", "Police station", false, false })
		expect({ doors:Buy(gordon, station) }):toEqual({ false, "sale" })
		expect({ doors:Buy(gordon, hall) }):toEqual({ false, "sale" })

		-- The police and the mayor hold the keys of the police doors.
		expect(doors:HasKeys(gordon, station)):toBe(false)
		city:SetJob(gordon, "police", true)
		city:SetJob(alyx, "mayor", true)
		expect({ doors:HasKeys(gordon, station), doors:HasKeys(alyx, station) }):toEqual({ true, true })
		face(m, gordon, station)
		use(server, gordon, true)
		expect(station.locked):toBe(true)
		hud(server, client)
		local cl = client:Get("NC").Modules:Instance("doors")
		expect({ cl:Group(station), cl:Title(station), cl:HasKeys(gordon, station) }):toEqual({ "police",
			"Police station", true })
		expect(hud(server, client)):toContain("Заперто")

		-- A cleanup makes new doors: the map settings come back on them.
		server.G.game.CleanUpMap()
		local again = byMapId(m, 1003)
		expect(again ~= station and doors:Group(again)):toBe("police")
		expect(doors:Title(again)):toBe("Police station")
		expect(doors:ForSale(byMapId(m, 1004))):toBe(false)

		-- So does the next server on the same disk.
		server:Advance(3)
		local next, m2 = boot({ data = server.data })
		expect({ m2.doors:Group(door(m2, 3)), m2.doors:ForSale(door(m2, 4)), m2.doors:ForSale(door(m2, 1)) })
			:toEqual({ "police", false, true })
		face(m, gordon, again)
		server:Command("nc_doormap", gordon, { "group", "none" })
		server:Command("nc_doormap", gordon, { "title", "none" })
		expect({ doors:Group(again), doors:Info(again), doors:ForSale(again) }):toEqual({ nil, nil, true })
		expect(next:Errors()):toEqual({})
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("opens locked doors with a lockpick after a while; the police ram them with a warrant", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		local barney = Env.Bot(server, { name = "Barney" })
		local kleiner = Env.Bot(server, { name = "Kleiner" })
		run(server, 5.3)
		local doors, city, inventory = m.doors, m.mode_city, m.inventory
		local front = door(m, 1)
		doors:Buy(alyx, front)
		doors:Lock(alyx, front, true)
		local picked, rammed = {}, {}
		m.NC.Events:On("doors.picked", function(ply, which)
			picked[#picked + 1] = { ply, which }
		end)
		m.NC.Events:On("doors.rammed", function(ply, which)
			rammed[#rammed + 1] = { ply, which }
		end)

		-- Nothing to open it with: the use key does nothing.
		face(m, gordon, front)
		use(server, gordon)
		expect(m.actions:IsBusy(gordon)):toBe(false)

		-- The bandit picks the lock.
		city:SetJob(gordon, "bandit", true)
		expect(inventory:Count(gordon, "lockpick")):toBe(1)
		use(server, gordon)
		expect(m.actions:IsBusy(gordon)):toBe(true)
		expect(table.concat(hud(server, client), "\n")):toContain("Picking the lock")
		run(server, 10.2)
		expect({ front.locked, doors:IsLocked(front), picked[1] }):toEqual({ false, false, { gordon, front } })
		expect({ doors:BeginPick(gordon, front) }):toEqual({ false, "unlocked" })

		-- A ram breaks the door in, only in the hands of the police with a warrant for the owner.
		doors:Lock(alyx, front, true)
		inventory:Give(kleiner, "ram", 1)
		face(m, kleiner, front)
		expect({ doors:BeginRam(kleiner, front) }):toEqual({ false, "denied" })
		city:SetJob(barney, "police", true)
		expect(inventory:Count(barney, "ram")):toBe(1)
		face(m, barney, front)
		expect({ doors:BeginRam(barney, front) }):toEqual({ false, "denied" })
		expect(m.NC.Modules:Instance("law"):IssueWarrant(barney, alyx, "Stolen goods")):toBe(true)
		use(server, barney)
		run(server, 3.2)
		expect({ front.locked, front.open, rammed[1] }):toEqual({ false, true, { barney, front } })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("hints at the door in front: the sign, owner, price, lock and keys; F2 opens its menu", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en", superadmin = true })
		local client2, alyx = Env.Join(server, { name = "Alyx", language = "ru" })
		aim(client, m.aims)
		aim(client2, m.aims)
		run(server, 5.3)
		local doors = m.doors
		local cl = client:Get("NC").Modules:Instance("doors")
		local cl2 = client2:Get("NC").Modules:Instance("doors")
		local front = door(m, 1)
		local function hint(module, ent)
			local out = {}
			for i, line in ipairs(module:HintLines(ent)) do
				out[i] = line.text
			end
			return out
		end
		local function options(menu)
			local out = {}
			for i, option in ipairs(menu.children) do
				out[i] = option.text
			end
			return out
		end
		-- The server answers, both clients learn it.
		local function settle()
			for _ = 1, 2 do
				hud(server, client)
				Env.Flush(server, client2)
			end
			return hud(server, client)
		end
		-- F2, then the option `i` of the menu (in a submenu: `sub`).
		local function choose(i, sub)
			expect(Env.BindPress(client, "gm_showteam")):toBe(true)
			local option = cl.menu.children[i]
			if sub ~= nil then
				option = option.children[sub]
			end
			option.func()
			return settle()
		end

		-- Nothing in front: no hint, F2 is not taken.
		expect(Env.BindPress(client, "gm_showteam")):toBe(nil)

		-- A door for sale: its price and the key of its menu; buying from the menu.
		face(m, gordon, front)
		expect(hint(cl, front)):toEqual({ "For sale: $100 · F2" })
		expect(hud(server, client)):toContain("For sale: $100 · F2")
		expect(Env.BindPress(client, "gm_showteam")):toBe(true)
		expect(options(cl.menu)):toEqual({ "Buy for $100" })
		choose(1)
		expect(doors:Owner(front)):toBe(gordon)
		expect(hint(cl, front)):toEqual({ "Your door", "ALT + E: lock" })

		-- The owner locks it, gives the keys, puts up a sign; the co-owner sees it all.
		expect(Env.BindPress(client, "gm_showteam")):toBe(true)
		expect(options(cl.menu)):toEqual({ "Lock", "Give the keys", "Take the keys back", "The sign...", "Sell" })
		expect({ options(cl.menu.children[2]), options(cl.menu.children[3]) }):toEqual({ { "Alyx" }, {} })
		choose(1)
		expect(front.locked):toBe(true)
		expect(hint(cl, front)):toEqual({ "Your door", "Locked", "ALT + E: unlock" })
		choose(2, 1)
		expect(doors:IsCoowner(alyx, front)):toBe(true)
		choose(4)
		local entry = World.FindPanels(client, function(panel) return rawget(panel, "ncTitle") ~= nil end)[1]
		expect(entry:GetValue()):toBe("")
		entry:SetValue("Gordon's flat")
		local save = World.FindPanels(client, function(panel) return rawget(panel, "ncSave") ~= nil end)[1]
		save.DoClick(save)
		local drawn = settle()
		expect(doors:Title(front)):toBe("Gordon's flat")
		expect(drawn):toContain("Gordon's flat")
		expect(#World.FindPanels(client, function(panel) return rawget(panel, "ncSave") ~= nil end)):toBe(0)
		expect(hint(cl2, front)):toEqual({ "Gordon's flat", "Владелец: Gordon", "У вас есть ключи", "Заперто",
			"ALT + E: отпереть" })
		m.aims[alyx] = front
		expect(Env.BindPress(client2, "gm_showteam")):toBe(true)
		expect(options(cl2.menu)):toEqual({ "Отпереть", "Вернуть ключи" })

		-- The keys taken back, the door sold: on the market again, unlocked, without the sign.
		choose(3, 1)
		expect(doors:IsCoowner(alyx, front)):toBe(false)
		expect(hint(cl2, front)):toEqual({ "Gordon's flat", "Владелец: Gordon", "Заперто" })
		choose(5)
		expect(doors:Owner(front)):toBe(nil)
		expect(hint(cl, front)):toEqual({ "For sale: $100 · F2" })
		expect(hint(cl2, front)):toEqual({ "Продаётся: $100 · F2" })

		-- A door of a group shows the group by the name of its job, a door off the market says so.
		local station, hall = door(m, 3), door(m, 4)
		face(m, gordon, station)
		server:Command("nc_doormap", gordon, { "group", "police" })
		settle()
		expect(hint(cl, station)):toEqual({ "Police officer" })
		expect(Env.BindPress(client, "gm_showteam")):toBe(true)
		expect(options(cl.menu)):toEqual({ "Nothing to do here" })
		face(m, gordon, hall)
		server:Command("nc_doormap", gordon, { "closed", "yes" })
		settle()
		expect(hint(cl, hall)):toEqual({ "Not for sale" })

		-- While doors are nobody's property (out of the city) there are no prices.
		local shut = client:Get("NC").Events:On("doors.property", function() return false end, { priority = 100 })
		expect({ hint(cl, door(m, 2)), hint(cl, hall) }):toEqual({ {}, {} })
		shut:Off()
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
		expect(client2:Errors()):toEqual({})
	end)
end)
