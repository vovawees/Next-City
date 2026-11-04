-- Hands module: the hands every deployed player gets, with the server and the predicting
-- client running the same commands: lowered and raised, punches by the arms that work,
-- carrying, dragging and throwing props and bodies, with the real gamemode files in
-- emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN

local TICK = 1 / 64
-- Times in 1/64 s, so the ticks meet them exactly.
local SETTINGS = { raise = 0.25, windup = 0.125, recovery = 0.375 }

-- A recorder of hits and of what the hands do, and a guard of protected props.
local FILES = {
	["nextcity/modules/recorder/module.lua"] = "return { id = 'recorder', requires = { 'hands' },"
		.. " files = { sv = { 'sv_recorder.lua' } } }",
	["nextcity/modules/recorder/sv_recorder.lua"] = [[
		local M = NC.Module("recorder")
		M.hits, M.grabs, M.drops = {}, {}, {}
		function M:Start(ctx)
			ctx:On("damage.hit", function(ply, hit)
				hit.victim = ply
				self.hits[#self.hits + 1] = hit
			end)
			ctx:On("hands.grabbed", function(ply, ent)
				self.grabs[#self.grabs + 1] = { ply = ply, ent = ent }
			end)
			ctx:On("hands.dropped", function(ply, ent, thrown)
				self.drops[#self.drops + 1] = { ply = ply, ent = ent, thrown = thrown }
			end)
			ctx:On("hands.grab", function(_, ent)
				if ent.protected then
					return false
				end
			end)
		end
		function M:Take(what)
			local list = self[what]
			self[what] = {}
			return list
		end
	]],
}

-- Turns `ply` to look at `pos` from his eyes.
local function aim(ply, pos)
	local d = pos - ply:EyePos()
	local pitch = -math.deg(math.atan2(d.z, math.sqrt(d.x * d.x + d.y * d.y)))
	ply:SetEyeAngles(Angle(pitch, math.deg(math.atan2(d.y, d.x)), 0))
end

-- A server and the client of Gordon, alive at the origin and looking along +x, with
-- geometry on both realms. opts: language (of the client), settings (of the hands module,
-- over SETTINGS), organism (its settings).
local function boot(opts)
	opts = opts or {}
	local settings = {}
	for key, value in pairs(SETTINGS) do
		settings[key] = value
	end
	for key, value in pairs(opts.settings or {}) do
		settings[key] = value
	end
	local server = Env.Server({ files = FILES, modules = { "players", "organism", "damage", "melee", "hands" },
		patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.hands = settings
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
	w.hands = NC.Modules:Instance("hands")
	w.players = NC.Modules:Instance("players")
	w.recorder = NC.Modules:Instance("recorder")
	w.client, w.ply = Env.Join(server, { name = "Gordon", language = opts.language })
	w.players:Deploy(w.ply)
	w.ply:SetPos(Vector(0, 0, 0))
	w.ply:SetEyeAngles(Angle(0, 0, 0))
	Env.Geometry(server)
	Env.Geometry(w.client)
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
	-- A bot, alive at `pos`, looking along -x (at Gordon).
	function w.bot(name, pos)
		local bot = Env.Bot(server, { name = name })
		w.hold(0, 0.125)
		w.players:Deploy(bot)
		bot:SetPos(pos)
		bot:SetEyeAngles(Angle(0, 180, 0))
		return bot
	end
	-- A prop of `mass` kg, a cube of `half` units around `pos`, with one physics object.
	function w.prop(pos, mass, half)
		local prop = Env.Spawn(server, { pos = pos })
		half = half or 6
		prop.box = { Vector(-half, -half, -half), Vector(half, half, half) }
		return prop, World.AddPhysics(prop, mass)
	end
	w.weapon = w.ply:GetActiveWeapon()
	w.mirror = w.client.entities[w.weapon:EntIndex()]
	return w
end

-- The predicted state of the hands, to compare the realms.
local function state(hands)
	return table.concat({ tostring(hands:GetRaised()), hands:GetRaiseTime(), hands:GetAttack(), hands:GetSwings(),
		hands:GetStrikeTime(), hands:GetNextPrimaryFire(), hands:GetNextSecondaryFire() }, " ")
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

local function sequences(ply, realm)
	local vm = ply.viewModels and ply.viewModels[realm]
	return vm and table.concat(vm.sequences, " ") or ""
end

describe("hands", function()
	it("every deployed player gets the hands first, lowered: nothing in view, no punch", function()
		local w = boot({ language = "ru" })
		local hands, mirror = w.weapon, w.mirror
		expect(hands:GetClass() .. " " .. tostring(mirror ~= nil and mirror ~= hands)):toBe("nc_hands true")
		expect(w.hands:Active(w.ply) == hands and not w.hands:Raised(w.ply)):toBe(true)
		local stored = w.server:Get("weapons").GetStored("nc_hands")
		expect(stored.Base .. " " .. stored.HoldType .. " " .. stored.Slot .. " " .. stored.ViewModel .. " "
			.. stored.WorldModel .. "|"):toBe("nc_melee normal 0 models/weapons/c_arms.mdl |")
		expect(w.server:Get("weapons").GetStored("nc_hands").PrintName .. " / "
			.. w.client:Get("weapons").GetStored("nc_hands").PrintName):toBe("Hands / Руки")
		expect(w.client:As(function() return mirror:ShouldDrawViewModel() end)):toBe(false)
		-- Lowered hands do not punch.
		w.bot("Bob", Vector(30, 0, 0))
		w.use(IN.ATTACK)
		w.hold(IN.ATTACK, 0.5)
		expect(hands:GetSwings() .. " " .. #w.recorder:Take("hits")):toBe("0 0")
		-- Deployed again: one pair of hands.
		w.players:Deploy(w.ply)
		local pairsOfHands = 0
		for _, weapon in ipairs(w.ply:GetWeapons()) do
			pairsOfHands = pairsOfHands + (weapon:GetClass() == "nc_hands" and 1 or 0)
		end
		expect(pairsOfHands):toBe(1)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})

		local bare = boot({ settings = { give = false } })
		expect(bare.ply:HasWeapon("nc_hands")):toBe(false)
	end)

	it("the reload key raises the fists and lowers them; raised, they punch left and right in turn, predicted",
		function()
		local w = boot()
		local hands, mirror = w.weapon, w.mirror
		local bob = w.bot("Bob", Vector(30, 0, 0))
		aim(w.ply, bob:GetPos() + Vector(0, 0, 50))
		w.use(IN.RELOAD)
		local now = w.server.time
		expect(tostring(hands:GetRaised()) .. " " .. hands:GetRaiseTime() - now .. " " .. hands.holdType):toBe(
			"true 0.25 fist")
		expect(state(mirror)):toBe(state(hands))
		expect(sequences(w.ply, w.server) .. " / " .. sequences(w.ply, w.client)):toBe("fists_draw / fists_draw")
		expect(w.ply.viewModels[w.server].rate):toBe(0.5 / 0.25)
		expect(w.client:As(function() return mirror:ShouldDrawViewModel() end)):toBe(true)
		-- Held, the key does not lower them again; while they rise, no punch.
		w.hold(IN.RELOAD + IN.ATTACK, 0.25 - TICK)
		expect(tostring(hands:GetRaised()) .. " " .. hands:GetSwings()):toBe("true 0")
		w.hold(0, TICK)
		-- The first punch: the left, a blow of the melee base on Bob.
		w.use(IN.ATTACK)
		expect(hands:GetSwings() .. " " .. hands:GetAttack()):toBe("1 1")
		w.hold(0, 0.125)
		local hits = w.recorder:Take("hits")
		expect(#hits .. " " .. hits[1].kind .. " " .. hits[1].energy .. " " .. tostring(hits[1].victim == bob)
			.. " " .. tostring(hits[1].inflictor == hands)):toBe("1 blunt 50 true true")
		expect(count(w.ply.sounds, "WeaponFrag.Throw") .. " " .. count(w.ply.sounds, "Flesh.ImpactHard")):toBe("0 1")
		expect(count(hands.sounds, "WeaponFrag.Throw") .. " " .. count(mirror.sounds, "WeaponFrag.Throw")):toBe("1 1")
		-- The next one: the right.
		w.hold(IN.ATTACK, 0.375)
		w.hold(0, 0.125)
		expect(#w.recorder:Take("hits") .. " " .. hands:GetSwings()):toBe("1 2")
		expect(sequences(w.ply, w.server) .. " / " .. sequences(w.ply, w.client)):toBe(
			"fists_draw fists_left fists_right / fists_draw fists_left fists_right")
		expect(state(mirror)):toBe(state(hands))
		-- Lowered: the holster sequence, in view until it ends.
		w.hold(0, 0.375)
		w.use(IN.RELOAD)
		expect(tostring(hands:GetRaised()) .. " " .. hands.holdType .. " " .. tostring(mirror:GetRaised())):toBe(
			"false normal false")
		expect(w.client:As(function() return mirror:ShouldDrawViewModel() end)):toBe(true)
		w.hold(0, 0.25)
		expect(w.client:As(function() return mirror:ShouldDrawViewModel() end)):toBe(false)
		expect(sequences(w.ply, w.client)):toBe("fists_draw fists_left fists_right fists_holster")
		expect(state(mirror)):toBe(state(hands))
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("a hand without a working arm sits out; without arms or awake, no punch", function()
		-- The bodies stand still (no steps), so the capabilities stay as set.
		local w = boot({ organism = { rate = 0 } })
		local hands = w.weapon
		local bob = w.bot("Bob", Vector(30, 0, 0))
		aim(w.ply, bob:GetPos() + Vector(0, 0, 50))
		local caps = w.organism:Capabilities(w.ply)
		local clientCaps = w.client:As(function() return w.client:Get("NC").Modules:Instance("organism") end)
			:Capabilities(w.ply)
		local function set(field, value)
			caps[field], clientCaps[field] = value, value
		end
		w.use(IN.RELOAD)
		w.hold(0, 0.25)
		set("canUseArmL", false)
		for _ = 1, 2 do
			w.use(IN.ATTACK)
			w.hold(0, 0.5)
		end
		expect(sequences(w.ply, w.server)):toBe("fists_draw fists_right fists_right")
		expect(#w.recorder:Take("hits")):toBe(2)
		set("canUseArmR", false)
		w.use(IN.ATTACK)
		w.hold(0, 0.5)
		expect(hands:GetSwings()):toBe(2)
		set("canUseArmL", true)
		set("canUseArmR", true)
		set("unconscious", true)
		w.use(IN.ATTACK)
		expect(hands:GetSwings()):toBe(2)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("carries a light prop ahead of the eyes while the attack 2 key is held, drags a heavy one", function()
		local w = boot({ organism = { rate = 0 } })
		local hands = w.weapon
		local crate, phys = w.prop(Vector(50, 0, 56), 5)
		aim(w.ply, Vector(50, 0, 56))
		w.hold(IN.ATTACK2, TICK)
		local grabs = w.recorder:Take("grabs")
		expect(#grabs .. " " .. tostring(grabs[1].ent == crate and grabs[1].ply == w.ply)):toBe("1 true")
		expect(w.hands:Carried(w.ply) == crate):toBe(true)
		expect(hands.carry.distance):toBeCloseTo(math.sqrt(50 * 50 + 8 * 8), 1e-9)
		-- Turned to the left, the hands pull it there, at most MAX_SPEED.
		w.ply:SetEyeAngles(Angle(0, 90, 0))
		w.hold(IN.ATTACK2, TICK)
		-- 24000 kg·units/s² in 5 kg: 75 units/s more every tick.
		expect(phys:GetVelocity():Length()):toBeCloseTo(75, 1e-6)
		w.hold(IN.ATTACK2, 3 * TICK)
		local vel = phys:GetVelocity()
		expect(vel:Length()):toBeCloseTo(300, 1e-6)
		expect(vel.y > 0 and vel.x < 0):toBe(true)
		-- Heavy: the strength of the arms bounds the pull.
		phys:SetVelocity(Vector(0, 0, 0))
		phys:SetMass(500)
		w.hold(IN.ATTACK2, TICK)
		expect(phys:GetVelocity():Length()):toBeCloseTo(24000 * TICK / 500, 1e-6)
		local st = w.organism:State(w.ply)
		local before = st.stamina
		w.hold(IN.ATTACK2, TICK)
		expect(before - st.stamina):toBeCloseTo(0.04 * TICK, 1e-9)
		-- More commands of a lagging client in the same tick pull once.
		local pulls = #phys.forces
		w.use(IN.ATTACK2)
		w.use(IN.ATTACK2)
		expect(#phys.forces - pulls):toBe(0)
		w.hold(IN.ATTACK2, TICK)
		expect(#phys.forces - pulls):toBe(1)
		-- One arm: half the strength.
		phys:SetVelocity(Vector(0, 0, 0))
		w.organism:Capabilities(w.ply).canUseArmL = false
		w.hold(IN.ATTACK2, TICK)
		expect(phys:GetVelocity():Length()):toBeCloseTo(12000 * TICK / 500, 1e-6)
		w.organism:Capabilities(w.ply).canUseArmL = true
		-- Letting go of the key drops it.
		w.hold(0, TICK)
		local drops = w.recorder:Take("drops")
		expect(#drops .. " " .. tostring(drops[1].ent == crate) .. " " .. tostring(drops[1].thrown)):toBe("1 true false")
		expect(w.hands:Carried(w.ply)):toBe(nil)
		-- Stuck far from the hands, stood on, the fists raised, the hands put away: dropped.
		phys:SetMass(5)
		aim(w.ply, Vector(50, 0, 56))
		local function regrab()
			phys:SetPos(Vector(50, 0, 56))
			crate:SetPos(Vector(50, 0, 56))
			w.hold(0, TICK)
			w.hold(IN.ATTACK2, TICK)
			expect(#w.recorder:Take("grabs")):toBe(1)
		end
		regrab()
		phys:SetPos(Vector(500, 0, 56))
		w.hold(IN.ATTACK2, TICK)
		expect(#w.recorder:Take("drops")):toBe(1)
		regrab()
		w.ply.groundEntity = crate
		w.hold(IN.ATTACK2, TICK)
		w.ply.groundEntity = nil
		expect(#w.recorder:Take("drops")):toBe(1)
		regrab()
		w.use(IN.ATTACK2 + IN.RELOAD)
		expect(#w.recorder:Take("drops") .. " " .. tostring(hands:GetRaised())):toBe("1 true")
		-- Raised fists do not grab.
		w.hold(IN.ATTACK2, 0.5)
		expect(#w.recorder:Take("grabs")):toBe(0)
		w.use(IN.RELOAD)
		w.hold(0, 0.25)
		-- What a module protects, players and props without motion are not grabbed.
		crate.protected = true
		w.hold(IN.ATTACK2, TICK)
		crate.protected = nil
		phys:EnableMotion(false)
		w.hold(IN.ATTACK2, TICK)
		phys:EnableMotion(true)
		Env.Remove(w.server, crate)
		w.bot("Bob", Vector(30, 0, 0))
		aim(w.ply, Vector(30, 0, 50))
		w.hold(IN.ATTACK2, TICK)
		expect(#w.recorder:Take("grabs")):toBe(0)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)

	it("throws what it carries by the energy of the throw; drags a body by the bone it grabbed", function()
		local w = boot({ organism = { rate = 0 } })
		local crate, phys = w.prop(Vector(50, 0, 56), 5)
		aim(w.ply, Vector(50, 0, 56))
		w.hold(IN.ATTACK2, TICK)
		phys:SetVelocity(Vector(0, 0, 0))
		local st = w.organism:State(w.ply)
		local before = st.stamina
		w.use(IN.ATTACK2 + IN.ATTACK)
		-- E = m·v²/2: 150 J in 5 kg.
		expect(phys:GetVelocity():Length()):toBeCloseTo(math.sqrt(2 * 150 / 5) / 0.0254, 1e-6)
		expect(before - st.stamina):toBeCloseTo(0.03, 1e-9)
		local drops = w.recorder:Take("drops")
		expect(#drops .. " " .. tostring(drops[1].ent == crate) .. " " .. tostring(drops[1].thrown)):toBe("1 true true")
		-- Light things fly at most throwSpeed.
		phys:SetVelocity(Vector(0, 0, 0))
		phys:SetMass(0.2)
		w.hold(0, TICK)
		w.hold(IN.ATTACK2, TICK)
		phys:SetVelocity(Vector(0, 0, 0))
		w.use(IN.ATTACK2 + IN.ATTACK)
		expect(phys:GetVelocity():Length()):toBeCloseTo(600, 1e-6)
		Env.Remove(w.server, crate)
		w.recorder:Take("grabs")
		-- A body on the ground: the bone met is pulled, the throw spreads over the whole body.
		local rag = w.server.G.ents.Create("prop_ragdoll")
		rag:SetModel(w.ply:GetModel())
		rag:SetPos(Vector(40, 0, 0))
		rag:Spawn()
		World.LayRagdoll(rag)
		local chest = rag:GetPhysicsObjectNum(1)
		aim(w.ply, chest:GetPos())
		w.hold(0, TICK)
		w.hold(IN.ATTACK2, TICK)
		expect(#w.recorder:Take("grabs") .. " " .. tostring(w.weapon.carry.phys == chest)):toBe("1 true")
		w.ply:SetEyeAngles(Angle(-30, 0, 0))
		w.hold(IN.ATTACK2, TICK)
		-- The chest is pulled up and forward, within the strength of the arms; the rest follows it.
		local pull = chest.forces[#chest.forces]
		expect(#chest.forces .. " " .. #rag:GetPhysicsObjectNum(0).forces):toBe("2 0")
		expect(pull.z > 0 and pull.x > 0):toBe(true)
		expect(pull:Length()):toBeCloseTo(24000 * TICK, 1e-6)
		expect(w.hands:Carried(w.ply) == rag):toBe(true)
		local total = 0
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			total = total + rag:GetPhysicsObjectNum(i):GetMass()
			rag:GetPhysicsObjectNum(i):SetVelocity(Vector(0, 0, 0))
		end
		w.use(IN.ATTACK2 + IN.ATTACK)
		local speed = math.sqrt(2 * 150 / total) / 0.0254
		expect(rag:GetPhysicsObjectNum(0):GetVelocity():Length()):toBeCloseTo(speed, 1e-6)
		expect(rag:GetPhysicsObjectNum(5):GetVelocity():Length()):toBeCloseTo(speed, 1e-6)
		expect(w.server:Errors()):toEqual({})
		expect(w.client:Errors()):toEqual({})
	end)
end)
