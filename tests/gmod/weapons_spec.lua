-- Weapons module: the firearms of a content package on the base, with the server and the
-- predicting client of the shooter running the same commands: fire modes, rate, recoil,
-- spread, sway, sights, reloads from the reserve, the body of the shooter, engine
-- bullets without ballistics, and the console, with the real gamemode files in emulated
-- realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN

local TICK = 1 / 64

-- A content package: rounds, weapons (times in 1/64 s, so the ticks meet them exactly)
-- and their names, and a recorder of the shots.
local FILES = {
	["nextcity/modules/arsenal/module.lua"] = "return { id = 'arsenal', requires = { 'ammo', 'weapons' },"
		.. " files = { sh = { 'sh_arsenal.lua' } } }",
	["nextcity/modules/arsenal/sh_arsenal.lua"] = [[
		local M = NC.Module("arsenal")
		function M:Init(ctx)
			local ammo, weapons = ctx:Require("ammo"), ctx:Require("weapons")
			ammo:Register("545_7n6", { caliber = "5.45x39", mass = 3.4, velocity = 880, diameter = 5.6,
				penetration = 70, range = 900, ap = 1.3 })
			ammo:Register("545_7n10", { caliber = "5.45x39", mass = 3.6, velocity = 880, diameter = 5.6,
				penetration = 75, range = 900, ap = 1.6 })
			ammo:Register("12g_buck", { caliber = "12/70", mass = 3.5, velocity = 400, diameter = 8.4,
				penetration = 30, range = 100, pellets = 9, spread = 1.5 })
			ammo:Register("9x19_fmj", { caliber = "9x19", mass = 8, velocity = 360, diameter = 9, penetration = 60,
				range = 540 })
			weapons:Register("test_rifle", { caliber = "5.45x39", magazine = 30, rpm = 960,
				modes = { "auto", "semi", "burst" }, reload = 2, reloadEmpty = 2.5, draw = 0.5, aimTime = 0.25,
				sights = { pos = Vector(-2, -3, 0.5), fov = 0.75 }, recoil = { up = 1.5, side = 0.5 },
				sounds = { fire = "Test.Fire", reload = "Test.Reload" } })
			weapons:Register("test_shotgun", { caliber = "12/70", magazine = 6, chamber = false, rpm = 120,
				reloadMode = "single", reload = 0.5, reloadStart = 0.25, reloadEnd = 0.375, draw = 0.5 })
			weapons:Register("test_pistol", { caliber = "9x19", magazine = 15, hands = 1, rpm = 480, draw = 0.25 })
		end
	]],
	["nextcity/modules/recorder/module.lua"] = "return { id = 'recorder', requires = { 'weapons' },"
		.. " files = { sv = { 'sv_recorder.lua' } } }",
	["nextcity/modules/recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.shots = {}
		function M:Start(ctx)
			ctx:On("weapons.fired", function(owner, weapon, ammoId)
				self.shots[#self.shots + 1] = { owner = owner, weapon = weapon, ammo = ammoId }
			end)
		end
		function M:Take()
			local shots = self.shots
			self.shots = {}
			return shots
		end
	]],
	["nextcity/lang/en/weapons.lua"] = "return { test_rifle = 'AK-74' }",
	["nextcity/lang/ru/weapons.lua"] = "return { test_rifle = 'АК-74' }",
}

-- A server and the client of Gordon, alive. opts: ballistics (false: without the module),
-- language (of the client), settings (of the weapons module).
local function boot(opts)
	opts = opts or {}
	local modules = { "players", "organism", "damage", "ammo", "weapons" }
	if opts.ballistics ~= false then
		modules[#modules + 1] = "ballistics"
	end
	local server = Env.Server({ files = FILES, modules = modules, patch = { [Env.CONFIG] = function(cfg)
		cfg.modules.settings.weapons = opts.settings
		return cfg
	end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC }
	w.organism = NC.Modules:Instance("organism")
	w.organism.Random = function() return 0.5 end
	w.weapons = NC.Modules:Instance("weapons")
	w.players = NC.Modules:Instance("players")
	w.recorder = NC.Modules:Instance("recorder")
	w.client, w.ply = Env.Join(server, { name = "Gordon", language = opts.language })
	w.players:Deploy(w.ply)
	-- Both realms run `seconds` of ticks, and the client gets the news.
	function w.step(seconds)
		for _ = 1, math.floor(seconds / TICK + 0.5) do
			server:Advance(TICK)
			w.client:Advance(TICK)
		end
		Env.Flush(server, w.client)
	end
	-- One command of Gordon: the server runs it, then his client predicts it (the angles
	-- the client turns go with the next command).
	function w.use(buttons, useOpts)
		Env.Use(server, w.ply, buttons or 0, useOpts)
		Env.Use(w.client, w.ply, buttons or 0, useOpts)
	end
	-- Gives Gordon a weapon of the registry; the client gets the snapshot.
	function w.give(class, giveOpts)
		local weapon = assert(w.weapons:Give(w.ply, class, giveOpts))
		w.ply:SelectWeapon(class)
		Env.Sync(server)
		return weapon, w.client.entities[weapon:EntIndex()]
	end
	w.step(0.25)
	return w
end

-- The predicted state of a weapon, to compare the realms.
local function state(weapon)
	return table.concat({ weapon:Clip1(), weapon:GetState(), weapon:GetMode(), weapon:GetBurst(),
		tostring(weapon:GetFired()), weapon:GetNextPrimaryFire(), string.format("%.6f", weapon:GetHeat()),
		tostring(weapon:GetAiming()), weapon:GetLoaded() }, " ")
end

local function count(list, value)
	local n = 0
	for _, item in ipairs(list) do
		if item == value then
			n = n + 1
		end
	end
	return n
end

describe("weapons", function()
	it("registers the weapons of a package as scripted weapons on the base, on both realms", function()
		local w = boot({ language = "ru" })
		local stored = w.server:Get("weapons").Get("test_rifle")
		expect(stored.Base .. " " .. stored.Primary.ClipSize .. " " .. stored.Primary.DefaultClip .. " "
			.. stored.Primary.Ammo .. " " .. tostring(stored.Primary.Automatic)):toBe("nc_firearm 31 31 545_7n6 true")
		expect(stored.HoldType .. " " .. stored.Slot .. " " .. tostring(stored.DrawCrosshair) .. " "
			.. tostring(stored.DrawAmmo)):toBe("ar2 2 false false")
		expect(w.server:Get("weapons").IsBasedOn("test_rifle", "weapon_base")):toBe(true)
		local shotgun, pistol = w.server:Get("weapons").Get("test_shotgun"), w.server:Get("weapons").Get("test_pistol")
		expect(shotgun.Primary.ClipSize .. " " .. pistol.Primary.ClipSize .. " " .. pistol.HoldType .. " "
			.. pistol.Slot):toBe("6 16 pistol 1")
		-- The client knows the classes too, by the names of its language.
		local clientWeapons = w.client:Get("weapons")
		expect(clientWeapons.Get("test_rifle").PrintName .. " / " .. clientWeapons.Get("test_shotgun").PrintName)
			:toBe("АК-74 / test_shotgun")
		local def = w.weapons:Get("test_rifle")
		expect(def.capacity .. " " .. def.interval .. " " .. table.concat(def.modes, "/") .. " " .. def.recoil.up
			.. " " .. def.recoil.bloom .. " " .. def.hipSpread):toBe("31 0.0625 auto/semi/burst 1.5 0.25 3")
		expect(table.concat(w.weapons:All(), " ")):toBe("test_rifle test_shotgun test_pistol")

		local function problem(class, def2)
			local ok, err = pcall(w.weapons.Register, w.weapons, class, def2)
			return not ok and err:match("Register%('[^']*'%): (.*)$") or "registered"
		end
		expect(problem("t1", { caliber = "7.62x39", magazine = 30 })):toBe(
			"caliber 7.62x39 has no rounds (ammo:Register them first)")
		expect(problem("t2", { caliber = "5.45x39", ammo = "12g_buck", magazine = 30 })):toBe(
			"ammo 12g_buck is not a round of caliber 5.45x39")
		expect(problem("t3", { caliber = "5.45x39", magazine = 0 })):toBe("magazine must be a whole number >= 1")
		expect(problem("t4", { caliber = "5.45x39", magazine = 30, modes = { "auto", "auto" } })):toBe(
			"modes must be a list of semi, burst, auto, each once")
		expect(problem("t5", { caliber = "5.45x39", magazine = 30, hands = 3 })):toBe("hands must be 1 or 2")
		expect(problem("t6", { caliber = "5.45x39", magazine = 30, recoil = { up = -1 } })):toBe(
			"recoil.up must be a number >= 0")
		expect(problem("t7", { caliber = "5.45x39", magazine = 30, sights = { fov = 2 } })):toBe(
			"sights.fov must be a number over 0 and up to 1")
		expect(problem("Bad Class", { caliber = "5.45x39", magazine = 30 })):toBe(
			"class must be a string of lowercase letters, digits and _ (not the base)")
		expect(problem("t8", { caliber = "5.45x39", magazine = 30, rpm = 0 })):toBe("rpm must be a number > 0")

		w.server:Command("nc_weapons")
		expect(#w.server:Lines("nc_weapons: 3 weapons")):toBe(1)
		expect(#w.server:Lines("test_rifle           5.45x39     30+1   960 rpm  auto/semi/burst magazine 2.0 / 2.5 s"))
			:toBe(1)
		expect(#w.server:Lines("test_shotgun         12/70        6     120 rpm  semi            single")):toBe(1)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("fires on the server and the predicting client alike: auto at its rate, semi on a press, bursts", function()
		local w = boot()
		local weapon, mirror = w.give("test_rifle", { reserve = 60 })
		expect(mirror ~= nil and mirror ~= weapon):toBe(true)
		expect(weapon:Clip1() .. " " .. mirror:Clip1() .. " " .. weapon:GetState()):toBe("31 31 1")
		-- Drawing: no shot yet.
		w.use(IN.ATTACK)
		expect(weapon:Clip1()):toBe(31)
		w.step(0.5)
		-- Auto: a shot at once, then one every 1/16 s while the trigger is held.
		w.use(IN.ATTACK)
		expect(weapon:Clip1() .. " " .. weapon:GetState()):toBe("30 0")
		expect(state(mirror)):toBe(state(weapon))
		w.step(TICK * 2)
		w.use(IN.ATTACK)
		expect(weapon:Clip1()):toBe(30)
		w.step(TICK * 2)
		w.use(IN.ATTACK)
		expect(weapon:Clip1()):toBe(29)
		expect(state(mirror)):toBe(state(weapon))
		local shots = w.recorder:Take()
		expect(#shots .. " " .. shots[1].ammo .. " " .. tostring(shots[1].weapon == weapon)):toBe("2 545_7n6 true")
		expect(count(weapon.sounds, "Test.Fire") .. " " .. count(mirror.sounds, "Test.Fire")):toBe("2 2")
		expect(count(weapon.anims, World.Sweps.ACT.VM_PRIMARYATTACK)):toBe(2)
		expect(count(w.ply.animations, World.Sweps.PLAYER.ATTACK1)):toBe(4)
		-- The recoil punches the view on both realms; the client of the shooter climbs it.
		expect(#w.ply.viewPunches):toBe(4)
		local pitch = w.ply:EyeAngles():Unpack()
		expect(pitch):toBeCloseTo(-3, 1e-9)

		-- Use + reload: the next mode (semi) on both realms, shown by the client.
		w.step(0.25)
		w.use(IN.USE + IN.RELOAD)
		expect(weapon:FireMode() .. " " .. mirror:FireMode() .. " " .. weapon:GetState()):toBe("semi semi 0")
		w.client.drawn = {}
		w.client:As(function() mirror:DrawHUD() end)
		expect(w.client.drawn):toEqual({ "Semi-auto" })
		-- Semi: one shot a press, held or not.
		w.use(0)
		w.use(IN.ATTACK)
		w.step(0.25)
		w.use(IN.ATTACK)
		expect(weapon:Clip1()):toBe(28)
		w.use(0)
		w.use(IN.ATTACK)
		expect(weapon:Clip1()):toBe(27)
		expect(state(mirror)):toBe(state(weapon))

		-- Burst: three shots while held, then the trigger must be released.
		w.step(0.25)
		w.use(IN.USE + IN.RELOAD)
		w.use(0)
		expect(weapon:FireMode()):toBe("burst")
		for _ = 1, 6 do
			w.use(IN.ATTACK)
			w.step(1 / 16)
		end
		expect(weapon:Clip1()):toBe(24)
		w.use(0)
		w.use(IN.ATTACK)
		expect(weapon:Clip1()):toBe(23)
		expect(state(mirror)):toBe(state(weapon))
		expect(#w.recorder:Take()):toBe(6)

		-- Empty: one click a press, no shot.
		weapon:SetClip1(0)
		Env.Sync(w.server)
		w.step(0.25)
		w.use(0)
		w.use(IN.ATTACK)
		w.step(0.25)
		w.use(IN.ATTACK)
		expect(count(weapon.sounds, "Weapon_Pistol.Empty") .. " " .. count(mirror.sounds, "Weapon_Pistol.Empty"))
			:toBe("1 1")
		expect(count(weapon.anims, World.Sweps.ACT.VM_DRYFIRE)):toBe(1)
		expect(#w.recorder:Take()):toBe(0)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("reloads from the reserve: a magazine and the chamber, longer when empty, another type only when empty",
		function()
		local w = boot()
		local weapon, mirror = w.give("test_rifle", { reserve = 60 })
		w.step(0.5)
		w.use(IN.ATTACK)
		w.use(0)
		-- A magazine change with a round in the chamber: 30 + 1 after 2 s.
		w.use(IN.RELOAD)
		expect(weapon:GetState() .. " " .. mirror:GetState()):toBe("2 2")
		expect(count(weapon.sounds, "Test.Reload")):toBe(1)
		w.step(1.875)
		w.use(0)
		expect(weapon:Clip1() .. " " .. w.ply:GetAmmoCount("545_7n6")):toBe("30 60")
		w.step(0.125)
		w.use(0)
		expect(weapon:Clip1() .. " " .. weapon:GetState() .. " " .. w.ply:GetAmmoCount("545_7n6")):toBe("31 0 59")
		expect(state(mirror)):toBe(state(weapon))
		expect(w.client:As(function() return w.ply:GetAmmoCount("545_7n6") end)):toBe(59)
		-- Full: no reload.
		w.use(IN.RELOAD)
		expect(weapon:GetState()):toBe(0)
		-- Empty: 2.5 s and 30 rounds, the bolt closed on the first of them.
		weapon:SetClip1(0)
		Env.Sync(w.server)
		w.use(IN.RELOAD)
		w.step(2.375)
		w.use(0)
		expect(weapon:Clip1()):toBe(0)
		w.step(0.125)
		w.use(0)
		expect(weapon:Clip1() .. " " .. w.ply:GetAmmoCount("545_7n6")):toBe("30 29")
		expect(state(mirror)):toBe(state(weapon))

		-- Rounds of another type of the caliber go in only when the weapon is empty.
		w.ply:SetAmmo(0, "545_7n6")
		w.ply:GiveAmmo(40, "545_7n10")
		Env.Sync(w.server)
		w.use(IN.ATTACK)
		w.use(0)
		w.use(IN.RELOAD)
		expect(weapon:GetState()):toBe(0)
		weapon:SetClip1(0)
		Env.Sync(w.server)
		w.use(IN.RELOAD)
		w.step(2.5)
		w.use(0)
		expect(weapon:Clip1() .. " " .. weapon:LoadedAmmo() .. " " .. mirror:LoadedAmmo()):toBe(
			"30 545_7n10 545_7n10")
		w.recorder:Take()
		w.use(IN.ATTACK)
		expect(w.recorder:Take()[1].ammo):toBe("545_7n10")

		-- Holstering drops the reload under way, its rounds stay in the reserve.
		w.give("test_pistol", { reserve = 30 })
		w.ply:SelectWeapon("test_rifle")
		w.step(0.5)
		w.use(0)
		w.use(IN.RELOAD)
		expect(weapon:GetState()):toBe(2)
		w.ply:SelectWeapon("test_pistol")
		expect(weapon:GetState() .. " " .. w.ply:GetAmmoCount("545_7n10")):toBe("0 10")
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("loads single rounds one by one, and an attack stops after the round in hand", function()
		local w = boot()
		local weapon, mirror = w.give("test_shotgun", { reserve = 10 })
		w.step(0.5)
		for _ = 1, 3 do
			w.use(IN.ATTACK)
			w.use(0)
			w.step(0.5)
		end
		expect(weapon:Clip1()):toBe(3)
		w.use(IN.RELOAD)
		expect(weapon:GetState()):toBe(3)
		w.step(0.25)
		w.use(0)
		expect(weapon:GetState() .. " " .. weapon:Clip1()):toBe("4 3")
		w.step(0.5)
		w.use(0)
		expect(weapon:Clip1() .. " " .. w.ply:GetAmmoCount("12g_buck")):toBe("4 9")
		w.use(IN.ATTACK)
		expect(weapon:Clip1() .. " " .. tostring(weapon:GetStop())):toBe("4 true")
		w.step(0.5)
		w.use(0)
		expect(weapon:Clip1() .. " " .. weapon:GetState()):toBe("5 5")
		w.step(0.375)
		w.use(0)
		expect(weapon:Clip1() .. " " .. weapon:GetState() .. " " .. w.ply:GetAmmoCount("12g_buck")):toBe("5 0 8")
		expect(state(mirror)):toBe(state(weapon))
		-- Without a stop it fills up.
		w.use(IN.RELOAD)
		w.step(0.25 + 0.5)
		w.use(0)
		expect(weapon:Clip1() .. " " .. weapon:GetState()):toBe("6 5")
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("raises the sights over aimTime: less spread, a narrower view and slower mouse; reloads put them down",
		function()
		local w = boot()
		local weapon, mirror = w.give("test_rifle", { reserve = 60 })
		w.step(0.5)
		w.use(0)
		local function now() return w.server.time end
		expect(weapon:Spread(w.ply, now(), nil, 0)):toBeCloseTo(2 / 60 + 3, 1e-9)
		w.use(IN.ATTACK2)
		expect(tostring(weapon:GetAiming()) .. " " .. weapon:AimFraction(now())):toBe("true 0")
		w.step(0.125)
		w.use(IN.ATTACK2)
		expect(weapon:AimFraction(now())):toBeCloseTo(0.5, 1e-9)
		w.step(0.125)
		w.use(IN.ATTACK2)
		expect(weapon:AimFraction(now()) .. " " .. mirror:AimFraction(now())):toBe("1 1")
		expect(weapon:Spread(w.ply, now(), nil, 0)):toBeCloseTo(2 / 60, 1e-9)
		expect(weapon:Spread(w.ply, now(), nil, 2)):toBeCloseTo(2 / 60 + 0.5, 1e-9)
		w.ply.crouching = true
		expect(weapon:Spread(w.ply, now(), nil, 0)):toBeCloseTo(2 / 60 * 0.8, 1e-9)
		w.ply.crouching = false
		w.ply.velocity = Vector(200, 0, 0)
		expect(weapon:Spread(w.ply, now(), nil, 0)):toBeCloseTo(2 / 60 + 2, 1e-9)
		w.ply.velocity = Vector(0, 0, 0)

		-- The client: the view at 3/4, the mouse with it, the viewmodel at the sights.
		local zoomed = w.client:As(function() return mirror:TranslateFOV(80) end)
		expect(zoomed .. " " .. w.client:As(function() return mirror:AdjustMouseSensitivity() end)):toBe("60 0.75")
		local eyes, view = Vector(0, 0, 64), Angle(0, 0, 0)
		local pos = w.client:As(function() return mirror:GetViewModelPosition(Vector(eyes), Angle(view)) end)
		expect((pos - eyes):Length()):toBeCloseTo(Vector(-2, -3, 0.5):Length(), 0.05)
		expect(mirror.SwayScale):toBeCloseTo(0.15, 1e-9)

		-- Letting go lowers them over the same time; a reload puts them down at once.
		w.use(0)
		w.step(0.125)
		w.use(0)
		expect(weapon:AimFraction(now())):toBeCloseTo(0.5, 1e-9)
		w.step(0.25)
		w.use(IN.ATTACK2)
		w.step(0.25)
		w.use(IN.ATTACK)
		w.use(IN.ATTACK2 + IN.RELOAD)
		expect(tostring(weapon:GetAiming()) .. " " .. weapon:GetState()):toBe("false 2")
		w.step(0.25)
		w.use(IN.ATTACK2)
		expect(tostring(weapon:GetAiming()) .. " " .. tostring(mirror:GetAiming())):toBe("false false")
		expect(w.client:As(function() return mirror:TranslateFOV(80) end)):toBe(80)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("the body of the shooter counts: arms, sprint, recoilMul, crouching; bots climb on the server", function()
		local w = boot()
		local bot = Env.Bot(w.server, { name = "Bot" })
		w.server:Advance(0.1)
		w.players:Deploy(bot)
		local weapon = assert(w.weapons:Give(bot, "test_rifle", { reserve = 60 }))
		bot:SelectWeapon("test_rifle")
		w.server:Advance(0.5)
		local function fire(buttons)
			Env.Use(w.server, bot, 0)
			Env.Use(w.server, bot, buttons or IN.ATTACK)
			w.server:Advance(0.25)
		end
		fire()
		expect(weapon:Clip1()):toBe(30)
		expect(bot:EyeAngles():Unpack()):toBeCloseTo(-1.5, 1e-9)
		-- Crouching: 0.8 of the recoil; the body: recoilMul.
		bot.crouching = true
		fire()
		expect(bot:EyeAngles():Unpack()):toBeCloseTo(-1.5 - 1.2, 1e-9)
		bot.crouching = false
		local caps = w.organism:Capabilities(bot)
		caps.recoilMul = 2
		fire()
		expect(bot:EyeAngles():Unpack()):toBeCloseTo(-2.7 - 3, 1e-9)
		-- No working arm: no shot, no reload; one arm: twice the spread of a two-handed weapon.
		caps = w.organism:Capabilities(bot)
		caps.canUseArmL, caps.canUseArmR, caps.recoilMul = false, false, 1
		Env.Use(w.server, bot, 0)
		Env.Use(w.server, bot, IN.ATTACK)
		expect(weapon:Clip1()):toBe(28)
		expect(weapon:StartReload()):toBe(false)
		caps.canUseArmR = true
		local now = w.server.time
		expect(weapon:Spread(bot, now, caps, 0)):toBeCloseTo((2 / 60 + 3) * 2, 1e-9)
		local p1, y1 = weapon:SwayAt(bot, now, nil)
		local p2, y2 = weapon:SwayAt(bot, now, caps)
		expect(p2 / p1 .. " " .. y2 / y1):toBe("2 2")
		-- Sprinting lowers the weapon: no shot.
		caps.canUseArmL = true
		bot.velocity = Vector(300, 0, 0)
		Env.Use(w.server, bot, 0)
		Env.Use(w.server, bot, IN.ATTACK + IN.SPEED)
		expect(weapon:Clip1()):toBe(28)
		bot.velocity = Vector(0, 0, 0)
		Env.Use(w.server, bot, IN.ATTACK + IN.SPEED)
		expect(weapon:Clip1()):toBe(27)
		expect(w.server:Errors()):toEqual({})
	end)

	it("without ballistics the shots are engine bullets of the round on both realms", function()
		local w = boot({ ballistics = false })
		w.give("test_shotgun", { reserve = 10 })
		w.step(0.5)
		w.use(IN.ATTACK)
		local bullets = w.ply.bullets
		expect(#bullets .. " " .. bullets[1].realm .. " " .. bullets[2].realm):toBe("2 server client")
		local bullet = bullets[1].bullet
		expect(bullet.AmmoType .. " " .. bullet.Num .. " " .. bullet.Tracer):toBe("12g_buck 9 0")
		expect(bullet.Damage):toBeCloseTo(0.5 * 0.0035 * 400 * 400 * 0.04, 1e-9)
		expect(bullet.Spread.x > 0.02):toBe(true)
		expect(#w.recorder:Take()):toBe(1)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("gives loaded weapons from the console and lists the registry", function()
		local w = boot()
		w.server:Command("nc_give", nil, { "Gordon", "test_rifle", "45" })
		expect(#w.server:Lines("nc_give: Gordon got test_rifle and 45 rounds of 545_7n6")):toBe(1)
		local weapon = w.ply:GetWeapon("test_rifle")
		expect(weapon:Clip1() .. " " .. w.ply:GetAmmoCount("545_7n6") .. " " .. w.ply:GetActiveWeapon():GetClass())
			:toBe("31 45 test_rifle")
		w.server:Command("nc_give", nil, { "Gordon", "test_pistol" })
		expect(w.ply:GetAmmoCount("9x19_fmj")):toBe(30)
		w.server:Command("nc_give", nil, { "Gordon", "nope" })
		expect(#w.server:Lines("nc_give: unknown weapon 'nope'; firearms: test_rifle, test_shotgun, test_pistol"))
			:toBe(1)
		-- Any other scripted weapon, as the engine gives it.
		for _, realm in ipairs({ w.server, w.client }) do
			realm.G.weapons.Register({ Base = "weapon_base" }, "test_tool")
		end
		w.server:Command("nc_give", nil, { "Gordon", "test_tool" })
		expect(#w.server:Lines("nc_give: Gordon got test_tool")):toBe(1)
		expect(w.ply:GetActiveWeapon():GetClass()):toBe("test_tool")
		w.server:Command("nc_give", nil, { "Nobody", "test_rifle" })
		expect(#w.server:Lines("nc_give: no player")):toBe(1)
		local _, why = w.weapons:Give(w.ply, "test_rifle", { ammo = "9x19_fmj" })
		expect(why):toBe("9x19_fmj does not fit test_rifle (caliber 5.45x39)")
		expect(w.server:Errors()):toEqual({})
	end)
end)
