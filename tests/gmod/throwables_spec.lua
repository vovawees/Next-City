-- Throwables module: the thrown weapons of a content package on the base, with the server
-- and the predicting client of the thrower running the same commands: pulling the pin,
-- overhand and underhand throws, cooking, fuses and impacts, putting it away, the body of
-- the thrower and the console, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN
local ACT = World.Sweps.ACT

local TICK = 1 / 64

-- A content package (times in 1/64 s, so the ticks meet them exactly): a grenade with a
-- fuse, one that goes off on impact, and a rock; what goes off is recorded.
local PACKAGE = {
	["nextcity/modules/bombs/module.lua"] = "return { id = 'bombs', requires = { 'throwables' },"
		.. " files = { sh = { 'sh_bombs.lua' } } }",
	["nextcity/modules/bombs/sh_bombs.lua"] = [[
		local M = NC.Module("bombs")
		M.blasts = {}
		function M:Init(ctx)
			local throwables = ctx:Require("throwables")
			local function record(ent, thrower, pos, def)
				self.blasts[#self.blasts + 1] = { ent = ent, thrower = thrower, pos = pos, class = def.class }
			end
			throwables:Register("test_frag", { model = "models/weapons/w_grenade.mdl", mass = 0.4, energy = 60,
				fuse = 2, pull = 0.25, throwTime = 0.5, draw = 0.25, count = 2, detonate = record,
				sounds = { pin = "Frag.Pin", spoon = "Frag.Spoon", throw = "Frag.Throw", bounce = "Frag.Bounce" } })
			throwables:Register("test_impact", { model = "models/props_junk/glassbottle01a.mdl", mass = 0.5,
				energy = 40, impact = true, arm = 0.25, pull = 0.125, throwTime = 0.25, draw = 0.125, max = 5,
				detonate = function(ent, thrower, pos, def)
					if ent.broken then
						error("the bottle is broken")
					end
					record(ent, thrower, pos, def)
				end })
			throwables:Register("test_rock", { model = "models/props_junk/rock001a.mdl", mass = 1, pull = 0,
				throwTime = 0.25, draw = 0.125 })
		end
		function M:Take()
			local list = self.blasts
			self.blasts = {}
			return list
		end
	]],
	["nextcity/lang/en/throwables.lua"] = "return { test_frag = 'Grenade' }",
	["nextcity/lang/ru/throwables.lua"] = "return { test_frag = 'Граната' }",
}
local RECORDER = {
	["nextcity/modules/recorder/module.lua"] = "return { id = 'recorder', requires = { 'throwables' },"
		.. " files = { sv = { 'sv_recorder.lua' } } }",
	["nextcity/modules/recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.thrown, M.detonated = {}, {}
		function M:Start(ctx)
			ctx:On("throwables.thrown", function(owner, ent, class)
				self.thrown[#self.thrown + 1] = { owner = owner, ent = ent, class = class }
			end)
			ctx:On("throwables.detonated", function(ent, class, thrower, pos)
				self.detonated[#self.detonated + 1] = { ent = ent, class = class, thrower = thrower, pos = pos }
			end)
		end
		function M:Take(what)
			local list = self[what]
			self[what] = {}
			return list
		end
	]],
}

local function merge(...)
	local out = {}
	for _, files in ipairs({ ... }) do
		for path, source in pairs(files) do
			out[path] = source
		end
	end
	return out
end

-- A server and the client of Gordon, alive at the origin and looking along +x. opts:
-- files (default the package and the recorder), language (of the client), settings (of
-- the throwables module), organism (its settings).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ files = opts.files or merge(PACKAGE, RECORDER),
		modules = { "players", "organism", "throwables" }, patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.throwables = opts.settings
			cfg.modules.settings.organism = opts.organism
			return cfg
		end } })
	server.tickInterval = TICK
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC }
	w.organism = NC.Modules:Instance("organism")
	w.organism.Random = function() return 0.5 end
	w.throwables = NC.Modules:Instance("throwables")
	w.players = NC.Modules:Instance("players")
	w.recorder = NC.Modules:Instance("recorder")
	w.bombs = NC.Modules:Instance("bombs")
	w.client, w.ply = Env.Join(server, { name = "Gordon", language = opts.language })
	w.players:Deploy(w.ply)
	w.ply:SetPos(Vector(0, 0, 0))
	w.ply:SetEyeAngles(Angle(0, 0, 0))
	-- One command of Gordon: the server runs it, then his client predicts it.
	function w.use(buttons)
		Env.Use(server, w.ply, buttons or 0)
		Env.Use(w.client, w.ply, buttons or 0)
	end
	-- `seconds` of ticks with a command of Gordon in each.
	function w.hold(buttons, seconds)
		for _ = 1, math.floor(seconds / TICK + 0.5) do
			server:Advance(TICK)
			w.client:Advance(TICK)
			w.use(buttons)
		end
		Env.Flush(server, w.client)
	end
	-- Gives Gordon the throwable `class`, drawn; the client gets the snapshot.
	function w.give(class)
		local weapon = w.ply:Give(class)
		w.ply:SelectWeapon(class)
		Env.Sync(server)
		w.hold(0, 0.5)
		return weapon, w.client.entities[weapon:EntIndex()]
	end
	return w
end

-- The predicted state of a throwable, to compare the realms.
local function state(weapon)
	return table.concat({ weapon:GetStep(), weapon:GetThrow(), weapon:GetStepTime(), weapon:GetFuse() }, " ")
end

local function count(list, value)
	local n = 0
	for _, item in ipairs(list or {}) do
		if item == value then
			n = n + 1
		end
	end
	return n
end

-- Every PhysicsCollide callback of `ent` with a hit of `speed` units/s.
local function collide(ent, speed)
	for _, fn in ipairs(ent:GetCallbacks("PhysicsCollide")) do
		fn(ent, { Speed = speed, HitPos = ent:GetPos(), HitEntity = World.WORLD })
	end
end

describe("throwables", function()
	it("registers the throwables of a package as scripted weapons and ammo types, on both realms", function()
		local w = boot({ language = "ru" })
		local G = w.server:Get("weapons")
		local frag = G.Get("test_frag")
		expect(frag.Base .. " " .. frag.HoldType .. " " .. frag.Slot .. " " .. frag.Primary.Ammo .. " "
			.. frag.Primary.DefaultClip .. " " .. frag.Primary.ClipSize .. " " .. frag.WorldModel):toBe(
			"nc_throwable grenade 4 test_frag 2 -1 models/weapons/w_grenade.mdl")
		expect(tostring(G.IsBasedOn("test_rock", "weapon_base"))):toBe("true")
		expect(w.server:Get("game").GetAmmoID("test_frag") ~= -1 and w.client:Get("game").GetAmmoID("test_frag") ~= -1)
			:toBe(true)
		local clientWeapons = w.client:Get("weapons")
		expect(clientWeapons.Get("test_frag").PrintName .. " / " .. clientWeapons.Get("test_rock").PrintName)
			:toBe("Граната / test_rock")
		local def = w.throwables:Get("test_impact")
		expect(def.fuse == nil and def.impact and def.anims.pull == ACT.VM_PULLPIN and def.anims.lob == ACT.VM_THROW)
			:toBe(true)
		expect(def.entity .. " " .. tostring(def.remove) .. " " .. def.stamina .. " " .. def.max .. " " .. def.count)
			:toBe("prop_physics true 0.03 5 1")
		expect(table.concat(w.throwables:All(), " ")):toBe("test_frag test_impact test_rock")
		expect(w.throwables.Speed(60, 0.4)):toBeCloseTo(math.sqrt(300) / 0.0254, 1e-9)

		local function problem(class, def2)
			local ok, err = pcall(w.throwables.Register, w.throwables, class, def2)
			return not ok and err:match("Register%('[^']*'%): (.*)$") or "registered"
		end
		local model = "models/x.mdl"
		expect(problem("t1", {})):toBe("model must be a model path")
		expect(problem("t2", { model = model, mass = 0 })):toBe("mass must be a number > 0")
		expect(problem("t3", { model = model, energy = -1 })):toBe("energy must be a number >= 0")
		expect(problem("t4", { model = model, fuse = "4" })):toBe("fuse must be a number >= 0 or nil")
		expect(problem("t5", { model = model, detonate = function() end })):toBe(
			"a thing that goes off needs a fuse or impact")
		expect(problem("t6", { model = model, fuse = 3, detonate = 5 })):toBe("detonate must be a function")
		expect(problem("t7", { model = model, count = 1.5 })):toBe("count must be a whole number >= 1")
		expect(problem("t8", { model = model, sounds = 1 })):toBe("sounds must be a table")
		expect(problem("Bad", { model = model })):toBe(
			"class must be a string of lowercase letters, digits and _ (not the base)")
		expect(problem("nc_throwable", { model = model })):toBe(
			"class must be a string of lowercase letters, digits and _ (not the base)")

		w.server:Command("nc_throwables")
		expect(#w.server:Lines("nc_throwables: 3 throwables")):toBe(1)
		expect(#w.server:Lines("  test_frag            0.4 kg 60 J  682 u/s  fuse 2 s           x3  Grenade")):toBe(1)
		expect(#w.server:Lines("  test_impact          0.5 kg 40 J  498 u/s  impact             x5  test_impact"))
			:toBe(1)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})

		local bare = boot({ files = RECORDER })
		bare.server:Command("nc_throwables")
		expect(#bare.server:Lines("nc_throwables: no throwables (packages register them)")):toBe(1)
	end)

	it("pulls the pin on a press and throws on letting go, predicted; the fuse sets it off", function()
		local w = boot()
		local weapon, mirror = w.give("test_frag")
		expect(w.ply:GetAmmoCount("test_frag") .. " " .. weapon:GetStep()):toBe("2 0")
		w.ply.velocity = Vector(0, 50, 0)
		-- The press: the pin, on both realms.
		w.use(IN.ATTACK)
		local now = w.server.time
		expect(weapon:GetStep() .. " " .. weapon:GetStepTime() - now):toBe("1 0.25")
		expect(state(mirror)):toBe(state(weapon))
		expect(count(weapon.anims, ACT.VM_PULLPIN) .. " " .. count(mirror.anims, ACT.VM_PULLPIN)):toBe("1 1")
		expect(count(weapon.sounds, "Frag.Pin") .. " " .. count(mirror.sounds, "Frag.Pin")):toBe("1 1")
		-- Held: the pin is out, nothing is thrown.
		w.hold(IN.ATTACK, 0.5)
		expect(weapon:GetStep() .. " " .. #w.recorder:Take("thrown")):toBe("2 0")
		expect(state(mirror)):toBe(state(weapon))
		-- Let go: the throw.
		w.use(0)
		local thrown = w.recorder:Take("thrown")
		expect(#thrown .. " " .. thrown[1].class .. " " .. tostring(thrown[1].owner == w.ply)):toBe(
			"1 test_frag true")
		expect(weapon:GetStep() .. " " .. w.ply:GetAmmoCount("test_frag")):toBe("3 1")
		expect(count(weapon.anims, ACT.VM_THROW) .. " " .. count(mirror.anims, ACT.VM_THROW)):toBe("1 1")
		expect(count(w.ply.animations, World.Sweps.PLAYER.ATTACK1)):toBe(2)
		expect(state(mirror)):toBe(state(weapon))
		local ent = thrown[1].ent
		expect(ent:GetClass() .. " " .. ent:GetModel() .. " " .. tostring(ent:GetOwner() == w.ply)):toBe(
			"prop_physics models/weapons/w_grenade.mdl true")
		local phys = ent:GetPhysicsObject()
		local vel = phys:GetVelocity()
		expect(phys:GetMass() .. " " .. vel.y):toBe("0.4 50")
		expect(vel.x):toBeCloseTo(w.throwables.Speed(60, 0.4), 1e-9)
		-- From the hand: ahead of the eyes, to the right and below.
		local pos = ent:GetPos()
		expect(pos.x .. " " .. pos.y .. " " .. pos.z):toBe("16 -6 60")
		expect(w.throwables:IsLive(ent) and w.throwables:Thrower(ent) == w.ply):toBe(true)
		-- The next one is drawn after the throw.
		w.hold(0, 0.5)
		expect(weapon:GetStep() .. " " .. count(weapon.anims, ACT.VM_DRAW)):toBe("0 2")
		expect(state(mirror)):toBe(state(weapon))
		-- The fuse: 2 s after the throw it goes off where it is, once.
		w.hold(0, 1.5 - TICK)
		expect(#w.bombs:Take()):toBe(0)
		w.hold(0, TICK)
		local blasts = w.bombs:Take()
		expect(#blasts .. " " .. tostring(blasts[1].ent == ent) .. " " .. tostring(blasts[1].thrower == w.ply)):toBe(
			"1 true true")
		local detonated = w.recorder:Take("detonated")
		expect(#detonated .. " " .. detonated[1].class .. " " .. tostring(w.throwables:IsLive(ent))):toBe(
			"1 test_frag false")
		w.hold(0, 0.25)
		expect(tostring(ent:IsValid()) .. " " .. #w.bombs:Take()):toBe("false 0")
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("throws underhand with the attack 2 key; the last one takes the weapon", function()
		local w = boot()
		local weapon = w.give("test_frag")
		w.ply:RemoveAmmo(1, "test_frag")
		w.use(IN.ATTACK2)
		w.hold(IN.ATTACK2, 0.25)
		w.use(0)
		local thrown = w.recorder:Take("thrown")
		expect(#thrown):toBe(1)
		expect(thrown[1].ent:GetPhysicsObject():GetVelocity().x):toBeCloseTo(w.throwables.Speed(60 * 0.3, 0.4), 1e-9)
		expect(w.ply:GetAmmoCount("test_frag") .. " " .. tostring(w.ply:HasWeapon("test_frag"))):toBe("0 true")
		w.hold(0, 0.5)
		expect(tostring(w.ply:HasWeapon("test_frag")) .. " " .. weapon:GetStep()):toBe("false 0")
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("cooks with the reload key; held past the fuse it goes off in the hand; put away it drops or keeps the pin",
		function()
		local w = boot({ settings = { energy = 2 } })
		local weapon, mirror = w.give("test_frag")
		w.ply:GiveAmmo(1, "test_frag")
		-- The spoon flies off: the fuse runs in the hand, 1 s of it before the throw.
		w.use(IN.ATTACK)
		w.hold(IN.ATTACK, 0.25)
		w.use(IN.ATTACK + IN.RELOAD)
		local fuse = weapon:GetFuse()
		expect(fuse - w.server.time .. " " .. count(weapon.sounds, "Frag.Spoon")):toBe("2 1")
		expect(state(mirror)):toBe(state(weapon))
		w.hold(IN.ATTACK + IN.RELOAD, 1)
		expect(weapon:GetFuse()):toBe(fuse)
		w.use(0)
		local ent = w.recorder:Take("thrown")[1].ent
		expect(ent:GetPhysicsObject():GetVelocity().x):toBeCloseTo(w.throwables.Speed(120, 0.4), 1e-9)
		w.hold(0, 1 - TICK)
		expect(#w.bombs:Take()):toBe(0)
		w.hold(0, TICK)
		expect(#w.bombs:Take()):toBe(1)
		-- Held too long: it goes off in the hand.
		w.hold(0, 0.25)
		w.use(IN.ATTACK)
		w.hold(IN.ATTACK, 0.25)
		w.use(IN.ATTACK + IN.RELOAD)
		w.hold(IN.ATTACK, 2)
		local blasts = w.bombs:Take()
		expect(#blasts .. " " .. weapon:GetStep() .. " " .. w.ply:GetAmmoCount("test_frag")):toBe("1 3 1")
		expect(blasts[1].pos.x .. " " .. blasts[1].pos.z):toBe("16 60")
		expect(#w.recorder:Take("thrown") .. " " .. #w.recorder:Take("detonated")):toBe("1 2")
		expect(state(mirror)):toBe(state(weapon))
		-- Put away with the pin out: the pin goes back.
		w.ply:Give("test_rock")
		w.hold(0, 0.75)
		w.use(IN.ATTACK)
		w.hold(IN.ATTACK, 0.25)
		expect(weapon:GetStep()):toBe(2)
		w.ply:SelectWeapon("test_rock")
		expect(weapon:GetStep() .. " " .. w.ply:GetAmmoCount("test_frag") .. " " .. #w.recorder:Take("thrown")):toBe(
			"0 1 0")
		-- Put away cooking: it drops from the hand with its fuse.
		w.ply:SelectWeapon("test_frag")
		w.hold(0, 0.5)
		w.use(IN.ATTACK)
		w.hold(IN.ATTACK, 0.25)
		w.use(IN.ATTACK + IN.RELOAD)
		w.ply:SelectWeapon("test_rock")
		local dropped = w.recorder:Take("thrown")
		expect(#dropped .. " " .. w.ply:GetAmmoCount("test_frag")):toBe("1 0")
		expect(dropped[1].ent:GetPhysicsObject():GetVelocity().z):toBe(-40)
		w.hold(0, 2)
		expect(#w.bombs:Take()):toBe(1)
		-- None left: taken out again, the weapon goes.
		expect(tostring(w.ply:HasWeapon("test_frag"))):toBe("true")
		w.ply:SelectWeapon("test_frag")
		w.hold(0, TICK)
		expect(tostring(w.ply:HasWeapon("test_frag"))):toBe("false")
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("an impact fuse goes off on a hard hit after it is armed, at the next tick; bounces sound", function()
		local w = boot({ settings = { maxLive = 2 } })
		local bottle = w.throwables:Launch(w.ply, "test_impact", { velocity = Vector(300, 0, 0) })
		local frag = w.throwables:Launch(nil, "test_frag", { pos = Vector(0, 100, 0) })
		expect(w.throwables:Thrower(frag)):toBe(nil)
		collide(bottle, 400)
		w.server:Advance(TICK)
		expect(#w.bombs:Take()):toBe(0)
		w.server:Advance(0.25)
		collide(bottle, 100)
		w.server:Advance(TICK)
		expect(#w.bombs:Take()):toBe(0)
		collide(bottle, 400)
		expect(#w.bombs:Take()):toBe(0)
		w.server:Advance(TICK)
		local blasts = w.bombs:Take()
		expect(#blasts .. " " .. blasts[1].class .. " " .. tostring(blasts[1].thrower == w.ply)):toBe(
			"1 test_impact true")
		-- Bounces of the grenade sound, not too often.
		collide(frag, 100)
		collide(frag, 100)
		collide(frag, 30)
		w.server:Advance(0.25)
		collide(frag, 100)
		expect(count(frag.sounds, "Frag.Bounce")):toBe(2)
		-- An error of the package is logged; the thing goes off all the same.
		local broken = w.throwables:Launch(w.ply, "test_impact", {})
		broken.broken = true
		w.server:Advance(0.5)
		collide(broken, 400)
		w.server:Advance(TICK)
		expect(#w.recorder:Take("detonated") .. " " .. tostring(broken:IsValid())):toBe("2 true")
		expect(#w.server:Errors()):toBe(1)
		expect(w.server:Errors()[1]):toContain("the bottle is broken")
		-- Beyond maxLive the oldest goes out as a dud.
		local rocks = {}
		for i = 1, 3 do
			rocks[i] = w.throwables:Launch(w.ply, "test_rock", {})
		end
		w.server:Advance(TICK)
		expect(tostring(w.throwables:IsLive(frag)) .. " " .. tostring(w.throwables:IsLive(rocks[1])) .. " "
			.. tostring(w.throwables:IsLive(rocks[3])) .. " " .. tostring(frag:IsValid())):toBe("false false true false")
		expect(#w.bombs:Take()):toBe(0)
		-- Broken by the engine on the hit that sets it off, it goes off where it broke; a
		-- thing removed otherwise is gone without going off.
		local glass = w.throwables:Launch(w.ply, "test_impact", { pos = Vector(50, 0, 10) })
		local gone = w.throwables:Launch(w.ply, "test_frag", { fuse = w.server.time + 0.5 })
		w.server:Advance(0.25)
		collide(glass, 400)
		glass:Remove()
		gone:Remove()
		w.server:Advance(TICK)
		w.server:Advance(0.5)
		blasts = w.bombs:Take()
		expect(#blasts .. " " .. blasts[1].class .. " " .. blasts[1].pos.x .. " " .. tostring(glass:IsValid()))
			:toBe("1 test_impact 50 false")
		expect(tostring(w.throwables:IsLive(glass)) .. " " .. tostring(w.throwables:IsLive(gone))):toBe("false false")
	end)

	it("the body counts: no pin without a working arm or awake, one arm pulls slow, tired throws are weak", function()
		local w = boot({ organism = { rate = 0 } })
		local weapon = w.give("test_frag")
		w.ply:GiveAmmo(1, "test_frag")
		local caps = w.organism:Capabilities(w.ply)
		local clientCaps = w.client:Get("NC").Modules:Instance("organism"):Capabilities(w.ply)
		local function set(field, value)
			caps[field], clientCaps[field] = value, value
		end
		set("canUseArmL", false)
		set("canUseArmR", false)
		w.use(IN.ATTACK)
		expect(weapon:GetStep()):toBe(0)
		set("canUseArmR", true)
		w.hold(0, TICK)
		w.use(IN.ATTACK)
		expect(weapon:GetStepTime() - w.server.time):toBe(0.5)
		w.hold(IN.ATTACK, 0.5)
		w.organism:State(w.ply).stamina = 0.01
		w.use(0)
		local ent = w.recorder:Take("thrown")[1].ent
		expect(ent:GetPhysicsObject():GetVelocity().x):toBeCloseTo(w.throwables.Speed(36, 0.4), 1e-9)
		set("canUseArmL", true)
		set("unconscious", true)
		w.hold(0, 0.75)
		w.use(IN.ATTACK)
		expect(weapon:GetStep()):toBe(0)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)
end)
