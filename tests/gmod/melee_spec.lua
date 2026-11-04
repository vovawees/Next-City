-- Melee module: the melee weapons of a content package on the base, with the server and
-- the predicting client of the attacker running the same commands: swings, strikes on
-- bodies through the damage pipeline, the hull of the swing, props and the world, the body
-- of the attacker and the console, with the real gamemode files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN
local ACT = World.Sweps.ACT

local TICK = 1 / 64

-- A content package: a one-handed knife and a two-handed bat (times in 1/64 s, so the
-- ticks meet them exactly), their names, and a recorder of hits and strikes.
local ARMORY = {
	["nextcity/modules/armory/module.lua"] = "return { id = 'armory', requires = { 'melee' },"
		.. " files = { sh = { 'sh_armory.lua' } } }",
	["nextcity/modules/armory/sh_armory.lua"] = [[
		local M = NC.Module("armory")
		function M:Init(ctx)
			local melee = ctx:Require("melee")
			melee:Register("test_knife", { hands = 1, draw = 0.25, sounds = { draw = "Knife.Draw" },
				primary = { kind = "slash", energy = 40, reach = 40, windup = 0.125, recovery = 0.25,
					sounds = { swing = "Knife.Swing", hit = "Knife.Hit", world = "Knife.Wall" } },
				secondary = { kind = "stab", energy = 60, depth = 10, reach = 40, windup = 0.25, recovery = 0.5,
					damage = 25, anims = { hit = ACT_VM_HITCENTER } } })
			melee:Register("test_bat", { primary = { kind = "blunt", energy = 120, reach = 56, windup = 0.25,
				recovery = 0.5, stamina = 0.1, sounds = { world = "Bat.Wall" } } })
		end
	]],
	["nextcity/lang/en/melee.lua"] = "return { test_knife = 'Knife' }",
	["nextcity/lang/ru/melee.lua"] = "return { test_knife = 'Нож' }",
}
local RECORDER = {
	["nextcity/modules/recorder/module.lua"] = "return { id = 'recorder', requires = { 'melee' },"
		.. " files = { sv = { 'sv_recorder.lua' } } }",
	["nextcity/modules/recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.hits, M.strikes = {}, {}
		function M:Start(ctx)
			ctx:On("damage.hit", function(ply, hit)
				hit.victim = ply
				self.hits[#self.hits + 1] = hit
			end)
			ctx:On("melee.struck", function(owner, weapon, ent, index)
				self.strikes[#self.strikes + 1] = { owner = owner, weapon = weapon, ent = ent, index = index }
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

-- Turns `ply` to look at `pos` from his eyes.
local function aim(ply, pos)
	local d = pos - ply:EyePos()
	local pitch = -math.deg(math.atan2(d.z, math.sqrt(d.x * d.x + d.y * d.y)))
	ply:SetEyeAngles(Angle(pitch, math.deg(math.atan2(d.y, d.x)), 0))
end

local function bone(ply, name)
	return (ply:GetBonePosition(ply:LookupBone("ValveBiped.Bip01_" .. name)))
end

-- A server and the client of Gordon, alive at the origin and looking along +x, with
-- geometry on both realms. opts: files (the packages, default the armory and the
-- recorder), language (of the client), settings (of the melee module), organism (its
-- settings).
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ files = opts.files or merge(ARMORY, RECORDER),
		modules = { "players", "organism", "damage", "melee" }, patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.melee = opts.settings
			cfg.modules.settings.organism = opts.organism
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC }
	w.organism = NC.Modules:Instance("organism")
	w.organism.Random = function() return 0.5 end
	w.melee = NC.Modules:Instance("melee")
	w.players = NC.Modules:Instance("players")
	w.recorder = NC.Modules:Instance("recorder")
	w.client, w.ply = Env.Join(server, { name = "Gordon", language = opts.language })
	w.players:Deploy(w.ply)
	w.ply:SetPos(Vector(0, 0, 0))
	w.ply:SetEyeAngles(Angle(0, 0, 0))
	Env.Geometry(server)
	Env.Geometry(w.client)
	-- Both realms run `seconds` of ticks, and the client gets the news.
	function w.step(seconds)
		for _ = 1, math.floor(seconds / TICK + 0.5) do
			server:Advance(TICK)
			w.client:Advance(TICK)
		end
		Env.Flush(server, w.client)
	end
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
	-- Gives `ply` (Gordon) the weapon `class`, drawn; the client gets the snapshot.
	function w.give(class, ply)
		ply = ply or w.ply
		local weapon = ply:Give(class)
		ply:SelectWeapon(class)
		Env.Sync(server)
		w.step(0.5)
		return weapon, w.client.entities[weapon:EntIndex()]
	end
	-- A bot, alive at `pos`, looking along -x (at Gordon).
	function w.bot(name, pos, yaw)
		local bot = Env.Bot(server, { name = name })
		w.step(0.125)
		w.players:Deploy(bot)
		bot:SetPos(pos)
		bot:SetEyeAngles(Angle(0, yaw or 180, 0))
		return bot
	end
	return w
end

-- The predicted state of a weapon, to compare the realms.
local function state(weapon)
	return table.concat({ weapon:GetAttack(), weapon:GetSwings(), weapon:GetStrikeTime(),
		weapon:GetNextPrimaryFire(), weapon:GetNextSecondaryFire() }, " ")
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

local function fxNames(realm)
	local names = {}
	for _, fx in ipairs(realm.fx) do
		names[#names + 1] = fx.name
	end
	return table.concat(names, " ")
end

describe("melee", function()
	it("registers the melee weapons of a package as scripted weapons on the base, on both realms", function()
		local w = boot({ language = "ru" })
		local G = w.server:Get("weapons")
		local knife, bat = G.Get("test_knife"), G.Get("test_bat")
		expect(knife.Base .. " " .. knife.HoldType .. " " .. knife.Slot .. " " .. knife.Primary.ClipSize .. " "
			.. knife.Primary.Ammo .. " " .. tostring(knife.Primary.Automatic) .. " " .. tostring(knife.DrawCrosshair))
			:toBe("nc_melee knife 0 -1 none true false")
		expect(bat.HoldType .. " " .. tostring(G.IsBasedOn("test_bat", "weapon_base"))):toBe("melee2 true")
		-- The client knows the classes too, by the names of its language.
		local clientWeapons = w.client:Get("weapons")
		expect(clientWeapons.Get("test_knife").PrintName .. " / " .. clientWeapons.Get("test_bat").PrintName)
			:toBe("Нож / test_bat")
		-- Definitions with the defaults.
		local def = w.melee:Get("test_knife")
		expect(def.hands .. " " .. def.draw .. " " .. def.primary.depth .. " " .. def.secondary.depth .. " "
			.. def.primary.size .. " " .. def.primary.stamina .. " " .. def.primary.anims.swing .. " "
			.. def.secondary.anims.hit):toBe("1 0.25 4 10 4 0.02 195 189")
		local batDef = w.melee:Get("test_bat")
		expect(batDef.hands .. " " .. batDef.draw .. " " .. tostring(batDef.primary.depth) .. " "
			.. tostring(batDef.secondary)):toBe("2 0.5 nil nil")
		expect(table.concat(w.melee:All(), " ")):toBe("test_knife test_bat")
		expect(tostring(w.melee:Get("nope")) .. " " .. tostring(w.melee:Get(nil))):toBe("nil nil")

		local function problem(class, def2)
			local ok, err = pcall(w.melee.Register, w.melee, class, def2)
			return not ok and err:match("Register%('[^']*'%): (.*)$") or "registered"
		end
		local blunt = { kind = "blunt" }
		expect(problem("t1", {})):toBe("primary must be a table")
		expect(problem("t2", { primary = { kind = "pierce" } })):toBe("primary.kind must be blunt, slash or stab")
		expect(problem("t3", { primary = { kind = "blunt", energy = -1 } })):toBe(
			"primary.energy must be a number >= 0")
		expect(problem("t4", { primary = { kind = "blunt", windup = 0, recovery = 0 } })):toBe(
			"primary: windup + recovery must be over 0")
		expect(problem("t5", { primary = { kind = "stab", depth = 0 } })):toBe("primary.depth must be a number > 0")
		expect(problem("t6", { primary = { kind = "blunt", anims = 5 } })):toBe("primary.anims must be a table")
		expect(problem("t7", { primary = blunt, secondary = { kind = "cut" } })):toBe(
			"secondary.kind must be blunt, slash or stab")
		expect(problem("t8", { primary = blunt, hands = 3 })):toBe("hands must be 1 or 2")
		expect(problem("t9", { primary = blunt, draw = -1 })):toBe("draw must be a number >= 0")
		expect(problem("Bad Class", { primary = blunt })):toBe(
			"class must be a string of lowercase letters, digits and _ (not the base)")
		expect(problem("nc_melee", { primary = blunt })):toBe(
			"class must be a string of lowercase letters, digits and _ (not the base)")
		expect(problem("t10", 5)):toBe("def must be a table")
		expect(table.concat(w.melee:All(), " ")):toBe("test_knife test_bat")

		w.server:Command("nc_melee")
		expect(#w.server:Lines("nc_melee: 2 weapons")):toBe(1)
		expect(#w.server:Lines("  test_knife           1 hand(s)  slash 40 J 40u 0.125+0.25 s  "
			.. "stab 60 J 40u 0.25+0.5 s     Knife")):toBe(1)
		expect(#w.server:Lines("  test_bat             2 hand(s)  blunt 120 J 56u 0.25+0.5 s   -")):toBe(1)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})

		-- Without packages the core has no melee weapons.
		local bare = boot({ files = RECORDER })
		bare.server:Command("nc_melee")
		expect(#bare.server:Lines("nc_melee: no melee weapons (packages register them)")):toBe(1)
		expect(bare.server:Errors()):toEqual({})
	end)

	it("swings on the server and the predicting client alike: the windup, the strike on a body, the recovery",
		function()
		local w = boot()
		local bob = w.bot("Bob", Vector(32, 0, 0))
		local weapon, mirror = w.give("test_knife")
		expect(mirror ~= nil and mirror ~= weapon):toBe(true)
		expect(count(weapon.sounds, "Knife.Draw") .. " " .. count(mirror.sounds, "Knife.Draw")):toBe("1 1")
		expect(weapon.holdType):toBe("knife")
		aim(w.ply, bone(bob, "Spine2"))
		-- The press starts the windup on both realms.
		w.use(IN.ATTACK)
		local now = w.server.time
		expect(weapon:GetAttack() .. " " .. weapon:GetSwings()):toBe("1 1")
		expect(weapon:GetStrikeTime() - now .. " " .. weapon:GetNextPrimaryFire() - now):toBe("0.125 0.375")
		expect(state(mirror)):toBe(state(weapon))
		expect(count(weapon.anims, ACT.VM_MISSCENTER) .. " " .. count(mirror.anims, ACT.VM_MISSCENTER)):toBe("1 1")
		expect(count(weapon.sounds, "Knife.Swing") .. " " .. count(mirror.sounds, "Knife.Swing")):toBe("1 1")
		expect(count(w.ply.animations, World.Sweps.PLAYER.ATTACK1)):toBe(2)
		expect(#w.recorder:Take("hits")):toBe(0)
		-- The strike at the end of the windup: a cut of the organism on the chest of Bob.
		w.hold(IN.ATTACK, 0.125 - TICK)
		expect(weapon:GetAttack() .. " " .. #w.recorder:Take("hits")):toBe("1 0")
		w.hold(IN.ATTACK, TICK)
		expect(weapon:GetAttack() .. " " .. mirror:GetAttack()):toBe("0 0")
		local hits = w.recorder:Take("hits")
		expect(#hits):toBe(1)
		local hit = hits[1]
		expect(hit.victim == bob and hit.attacker == w.ply and hit.inflictor == weapon):toBe(true)
		expect(hit.kind .. " " .. hit.energy .. " " .. hit.depth .. " " .. hit.amount .. " " .. hit.type):toBe(
			"slash 40 4 5 " .. World.DMG.SLASH)
		expect(hit.hitgroup):toBe(w.server.G.HITGROUP_CHEST)
		expect(hit.report.wounds >= 1):toBe(true)
		expect(hit.force.x > 0 and hit.dir.x > 0):toBe(true)
		local strikes = w.recorder:Take("strikes")
		expect(#strikes .. " " .. tostring(strikes[1].ent == bob) .. " " .. strikes[1].index):toBe("1 true 1")
		expect(w.ply.lagCompensations .. " " .. tostring(w.ply.lagCompensation)):toBe("1 false")
		expect(fxNames(w.server)):toBe("BloodImpact")
		expect(count(w.ply.sounds, "Knife.Hit")):toBe(1)
		-- The blow comes back into the arms on both realms.
		local punches = w.ply.viewPunches
		expect(#punches .. " " .. punches[1]:Unpack() .. " " .. punches[2]:Unpack()):toBe("2 0.4 0.4")
		expect(state(mirror)):toBe(state(weapon))
		-- The recovery: the held key swings again when it ends.
		w.hold(IN.ATTACK, 0.25 - TICK)
		expect(weapon:GetSwings() .. " " .. mirror:GetSwings()):toBe("1 1")
		w.hold(IN.ATTACK, TICK)
		expect(weapon:GetSwings() .. " " .. weapon:GetAttack() .. " " .. mirror:GetSwings()):toBe("2 1 2")
		w.hold(0, 0.125)
		expect(#w.recorder:Take("hits")):toBe(1)
		expect(state(mirror)):toBe(state(weapon))
		-- The attack 2 key: the stab, deeper, with its anim on a hit.
		w.hold(0, 0.25)
		w.use(IN.ATTACK2)
		expect(weapon:GetAttack() .. " " .. mirror:GetAttack()):toBe("2 2")
		w.hold(0, 0.25)
		hits = w.recorder:Take("hits")
		expect(#hits .. " " .. hits[1].kind .. " " .. hits[1].depth .. " " .. hits[1].energy):toBe("1 stab 10 60")
		expect(count(weapon.anims, ACT.VM_HITCENTER) .. " " .. count(mirror.anims, ACT.VM_HITCENTER)):toBe("1 1")
		expect(w.recorder:Take("strikes")[2].index):toBe(2)
		expect(state(mirror)):toBe(state(weapon))
		-- Holstering drops a swing under way.
		w.hold(0, 0.5)
		w.use(IN.ATTACK)
		expect(weapon:GetAttack()):toBe(1)
		w.ply:Give("test_bat")
		w.ply:SelectWeapon("test_bat")
		expect(weapon:GetAttack() .. " " .. mirror:GetAttack()):toBe("0 0")
		w.hold(0, 0.25)
		expect(#w.recorder:Take("hits")):toBe(0)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("the hull of the swing meets a body beside the line; past the reach it misses", function()
		local w = boot()
		local bob = w.bot("Bob", Vector(30, 19, 0))
		local weapon, mirror = w.give("test_knife")
		-- The line along +x passes by Bob; the swing meets his side and the blow goes at him.
		w.use(IN.ATTACK)
		w.hold(0, 0.125)
		local hits = w.recorder:Take("hits")
		expect(#hits .. " " .. #w.recorder:Take("strikes")):toBe("1 1")
		expect(hits[1].victim == bob and hits[1].dir.y > 0 and hits[1].hitgroup ~= 0):toBe(true)
		expect(#w.ply.viewPunches):toBe(2)
		-- Past the reach: a swing that meets nothing.
		bob:SetPos(Vector(80, 0, 0))
		w.hold(0, 0.25)
		w.use(IN.ATTACK)
		w.hold(0, 0.25)
		expect(weapon:GetSwings() .. " " .. #w.recorder:Take("hits") .. " " .. #w.recorder:Take("strikes")):toBe(
			"2 0 0")
		expect(#w.ply.viewPunches .. " " .. count(weapon.sounds, "Knife.Swing")):toBe("2 2")
		expect(state(mirror)):toBe(state(weapon))
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("props take engine damage, the world the effects; a fallen body takes the hit and the push", function()
		local w = boot()
		local crate = Env.Spawn(w.server, { pos = Vector(30, 0, 0) })
		crate.box = { Vector(-8, -8, 0), Vector(8, 8, 80) }
		local bat = w.give("test_bat")
		w.use(IN.ATTACK)
		w.hold(0, 0.25)
		expect(#crate.damage):toBe(1)
		local dmginfo = crate.damage[1]
		expect(dmginfo:GetDamage() .. " " .. dmginfo:GetDamageType() .. " " .. dmginfo:GetDamageForce().x):toBe(
			"12 " .. World.DMG.CLUB .. " 2400")
		expect(dmginfo:GetAttacker() == w.ply and dmginfo:GetInflictor() == bat):toBe(true)
		expect(fxNames(w.server) .. " " .. count(w.ply.sounds, "Bat.Wall")):toBe("Impact 1")
		expect(w.recorder:Take("strikes")[1].ent == crate):toBe(true)
		-- The damage of the attack, when it has one.
		w.give("test_knife")
		w.use(IN.ATTACK2)
		w.hold(0, 0.25)
		expect(#crate.damage .. " " .. crate.damage[2]:GetDamage()):toBe("2 25")
		expect(#w.recorder:Take("hits") .. " " .. #w.recorder:Take("strikes")):toBe("0 1")
		-- The world: the effects and the sound, no damage.
		Env.Remove(w.server, crate)
		Env.Geometry(w.server):Wall(30, 10)
		w.server.fx = {}
		w.hold(0, 0.5)
		w.use(IN.ATTACK)
		w.hold(0, 0.125)
		local strikes = w.recorder:Take("strikes")
		expect(#strikes .. " " .. strikes[1].ent:GetClass() .. " " .. fxNames(w.server)):toBe("1 worldspawn Impact")
		expect(count(w.ply.sounds, "Knife.Wall")):toBe(1)
		-- A fallen body: the player it carries takes the hit, the body the push.
		local w2 = boot()
		local victim = w2.bot("Bob", Vector(0, 300, 0))
		victim:SetNotSolid(true)
		local rag = w2.server.G.ents.Create("prop_ragdoll")
		rag:SetModel(victim:GetModel())
		rag:SetPos(Vector(30, 0, 0))
		rag:Spawn()
		World.LayRagdoll(rag)
		w2.organism:SetCarrier(victim, rag)
		local bat2 = w2.give("test_bat")
		aim(w2.ply, rag:GetPhysicsObjectNum(1):GetPos())
		w2.use(IN.ATTACK)
		w2.hold(0, 0.25)
		local hits = w2.recorder:Take("hits")
		expect(#hits .. " " .. tostring(hits[1] and hits[1].victim == victim)):toBe("1 true")
		expect(hits[1].kind .. " " .. hits[1].energy):toBe("blunt 120")
		local pushed = 0
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			pushed = pushed + #rag:GetPhysicsObjectNum(i).forces
		end
		expect(pushed >= 1):toBe(true)
		expect(w2.recorder:Take("strikes")[1].weapon == bat2):toBe(true)
		expect(w.server:Errors()):toEqual({})
		expect(w2.server:Errors()):toEqual({})
		expect(w2.client:Errors()):toEqual({})
	end)

	it("the body counts: arms, a two-handed weapon in one arm, consciousness, stamina", function()
		-- The bodies stand still (no steps), so the capabilities stay as set.
		local w = boot({ organism = { rate = 0 } })
		local bob = w.bot("Bob", Vector(40, 0, 0))
		local al = w.bot("Al", Vector(0, 0, 0), 0)
		w.ply:SetPos(Vector(0, 500, 0))
		local bat = al:Give("test_bat")
		al:SelectWeapon("test_bat")
		w.server:Advance(0.5)
		aim(al, bone(bob, "Spine2"))
		local function swing(seconds, buttons)
			Env.Use(w.server, al, buttons or IN.ATTACK)
			for _ = 1, math.floor(seconds / TICK + 0.5) do
				w.server:Advance(TICK)
				Env.Use(w.server, al, 0)
			end
			return w.recorder:Take("hits")
		end
		local st = w.organism:State(al)
		local hits = swing(0.25)
		expect(#hits .. " " .. hits[1].energy):toBe("1 120")
		expect(st.stamina):toBeCloseTo(0.9, 1e-9)
		-- One arm: half again as slow and half the energy of a two-handed weapon.
		local caps = w.organism:Capabilities(al)
		w.server:Advance(0.5)
		caps.canUseArmL = false
		expect(#swing(0.25)):toBe(0)
		hits = swing(0.125, 0)
		expect(#hits .. " " .. hits[1].energy):toBe("1 60")
		-- A one-handed weapon is as good in one arm.
		al:Give("test_knife")
		al:SelectWeapon("test_knife")
		w.server:Advance(0.5)
		hits = swing(0.125)
		expect(#hits .. " " .. hits[1].energy):toBe("1 40")
		al:SelectWeapon("test_bat")
		w.server:Advance(0.5)
		-- No working arm: no swing; a swing under way does not strike.
		caps.canUseArmR = false
		swing(0.5)
		expect(bat:GetSwings()):toBe(2)
		caps.canUseArmL, caps.canUseArmR = true, true
		Env.Use(w.server, al, IN.ATTACK)
		expect(bat:GetSwings()):toBe(3)
		caps.canUseArmL, caps.canUseArmR = false, false
		expect(#swing(0.25, 0)):toBe(0)
		expect(bat:GetAttack()):toBe(0)
		-- Unconscious: no swing.
		caps.canUseArmL, caps.canUseArmR, caps.unconscious = true, true, true
		w.server:Advance(0.5)
		swing(0.25)
		expect(bat:GetSwings()):toBe(3)
		caps.unconscious = false
		-- Without the stamina for it a swing has 60% of its energy.
		st.stamina = 0.05
		hits = swing(0.25)
		expect(#hits .. " " .. hits[1].energy .. " " .. tostring(st.exhausted)):toBe("1 72 true")
		expect(w.server:Errors()):toEqual({})
	end)

	it("strikes see the others where the attacker saw them, unless lag compensation is off", function()
		local w = boot({ settings = { lagCompensation = false, energy = 0.5, push = 0 } })
		local bob = w.bot("Bob", Vector(32, 0, 0))
		w.give("test_knife")
		aim(w.ply, bone(bob, "Spine2"))
		w.use(IN.ATTACK)
		w.hold(0, 0.125)
		local hits = w.recorder:Take("hits")
		expect(#hits .. " " .. hits[1].energy .. " " .. hits[1].force:Length()):toBe("1 20 0")
		expect(tostring(w.ply.lagCompensations)):toBe("nil")
		expect(w.server:Errors()):toEqual({})
	end)
end)
