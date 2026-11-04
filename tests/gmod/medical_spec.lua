-- Medical module: treating oneself and the wounded in front (standing or a fallen body)
-- with items over time, the items used up, examinations with their reports and buttons,
-- treatments by hand (compressions, joints, tourniquets) and the reasons it cannot, with
-- the real gamemode files and a content package of test items.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

local PACKAGE = {
	["nextcity/modules/medkit/module.lua"] = "return { id = 'medkit', requires = { 'inventory' },"
		.. " files = { sh = { 'sh_medkit.lua' } } }",
	["nextcity/modules/medkit/sh_medkit.lua"] = [[
		local M = NC.Module("medkit")
		function M:Init(ctx)
			local inventory = ctx:Require("inventory")
			local function item(id, medical, extra)
				local def = { weight = 0.1, stack = 5, category = "medical", traits = { medical = medical } }
				for k, v in pairs(extra or {}) do
					def[k] = v
				end
				inventory:RegisterItem(id, def)
			end
			item("bandage", { treatment = "bandage", time = 2, othersTime = 1.5 })
			item("tourniquet", { treatment = "tourniquet", time = 3 })
			item("kit", { treatment = "bandage", time = 1, uses = 3 })
			item("morphine", { treatment = "morphine", time = 1, others = false, opts = { dose = 1 } })
			item("defib", { treatment = "defib", time = 2, uses = 0, self = false }, { stack = 1 })
			inventory:RegisterItem("oximeter", { weight = 0.1, category = "medical",
				traits = { diagnostic = { spo2 = true, rhythm = true } } })
		end
	]],
	["nextcity/lang/en/items.lua"] = "return { bandage = 'Bandage', tourniquet = 'Tourniquet', defib = 'Defibrillator' }",
	["nextcity/lang/ru/items.lua"] = "return { bandage = 'Бинт', tourniquet = 'Жгут', defib = 'Дефибриллятор' }",
}

local MODULES = { "players", "notices", "organism", "damage", "actions", "ragdoll", "inventory", "medical" }

-- A flat floor at z = 0 for lines; a shot-mask line of a player in `aims` hits the entity
-- he aims at.
local function world(server, aims)
	local shot = server:Get("MASK_SHOT")
	server.traceLine = function(trace)
		local ent = aims[trace.filter]
		if ent ~= nil and trace.mask == shot then
			return { Hit = true, Entity = ent, HitPos = ent:GetPos(), Fraction = 0.5, StartSolid = false }
		end
		local a, b = trace.start, trace.endpos
		if a.z >= 0 and b.z <= 0 and a.z ~= b.z then
			local t = a.z / (a.z - b.z)
			return { Hit = true, HitWorld = true, Entity = World.NULL, Fraction = t, StartSolid = false,
				HitPos = Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0) }
		end
		return { Hit = false, Entity = World.NULL, Fraction = 1, StartSolid = false, HitPos = Vector(b) }
	end
	server.traceHull = function(trace)
		return { Hit = false, Entity = World.NULL, Fraction = 1, StartSolid = false, HitPos = Vector(trace.endpos) }
	end
end

local function boot()
	local server = Env.Server({ modules = MODULES, files = PACKAGE })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC, aims = {}, treated = {} }
	world(server, w.aims)
	for _, id in ipairs({ "players", "inventory", "organism", "actions", "medical", "ragdoll" }) do
		w[id] = NC.Modules:Instance(id)
	end
	w.organism.Random = function() return 0.5 end
	NC.Events:On("medical.treated", function(ply, patient, kind, item)
		w.treated[#w.treated + 1] = string.format("%s>%s %s %s", ply:Nick(), patient:Nick(), kind, tostring(item))
	end)
	function w.join(name, opts)
		opts = opts or {}
		local client, ply = Env.Join(server, { name = name, language = opts.language })
		w.players:Deploy(ply)
		ply:SetPos(opts.pos or Vector(0, 0, 0))
		ply:SetEyeAngles(Angle(0, opts.yaw or 0, 0))
		return client, ply
	end
	function w.run(seconds)
		for _ = 1, math.floor(seconds / 0.1 + 0.5) do
			server:Advance(0.1)
		end
	end
	function w.slot(ply, id)
		for _, item in ipairs(w.inventory:ItemsOf(ply)) do
			if item.id == id then
				return item.container.id, item.slot, item
			end
		end
	end
	function w.act(ply, id, verb)
		local container, slot = w.slot(ply, id)
		return w.inventory:Act(ply, container, slot, verb, 0)
	end
	function w.notice(client)
		Env.Flush(server, client)
		local list = client:Get("NC").Modules:Instance("notices"):Active()
		return list[#list] and list[#list].text
	end
	return w
end

local function wound(organism, ply, structure)
	for _, w in ipairs(organism:Wounds(ply)) do
		if w.structure == structure then
			return w
		end
	end
end

local function keys(list, field)
	local out = {}
	for i, entry in ipairs(list) do
		out[i] = entry[field or "key"] .. ((entry.part or "") ~= "" and "@" .. entry.part or "")
	end
	return table.concat(out, " ")
end

describe("medical", function()
	it("treats oneself with items over time and uses them up", function()
		local w = boot()
		local client, bob = w.join("Bob")
		local inventory, organism, actions = w.inventory, w.organism, w.actions
		w.server:Command("nc_hurt", nil, { "Bob", "slash", "arm_l", "40" })
		w.run(0.5)
		expect(inventory:Give(bob, "bandage", 2)):toBe(2)
		-- Use: an action of the time of the item; the dressing goes on when it ends.
		expect(w.act(bob, "bandage", "use")):toBe(true)
		expect(actions:Current(bob).id):toBe("medical")
		expect(actions:Current(bob).duration):toBe(2)
		w.run(1)
		expect(inventory:Count(bob, "bandage")):toBe(2)
		w.run(1.1)
		expect(inventory:Count(bob, "bandage")):toBe(1)
		local dressed = 0
		for _, wd in ipairs(organism:Wounds(bob)) do
			if wd.bandage > 0 then
				dressed = dressed + 1
			end
		end
		expect(dressed > 0):toBe(true)
		expect(w.treated):toEqual({ "Bob>Bob bandage bandage" })
		expect(w.notice(client)):toBe("Used: Bandage")
		-- Only the worst wound at a time; when nothing bleeds the item stays.
		while organism:CanTreat(bob, "bandage") do
			organism:ApplyTreatment(bob, "bandage")
		end
		expect(w.act(bob, "bandage", "use")):toBe(false)
		expect(w.notice(client)):toBe("Nothing to treat with it")
		expect(actions:IsBusy(bob)):toBe(false)
		-- Moving away cancels: nothing is used.
		expect(inventory:Give(bob, "morphine", 1)):toBe(1)
		expect(w.act(bob, "morphine", "use")):toBe(true)
		bob:SetPos(Vector(100, 0, 0))
		w.run(0.3)
		expect(actions:IsBusy(bob)):toBe(false)
		expect(inventory:Count(bob, "morphine")):toBe(1)
		expect(organism:State(bob).depot.morphine):toBe(0)
		expect(w.act(bob, "morphine", "use")):toBe(true)
		w.run(1.2)
		expect(inventory:Count(bob, "morphine")):toBe(0)
		expect(organism:State(bob).depot.morphine > 0):toBe(true)
		-- A kit of three uses: one comes off the stack with its charges counted down.
		w.server:Command("nc_hurt", nil, { "Bob", "slash", "leg_r", "40" })
		w.server:Command("nc_hurt", nil, { "Bob", "slash", "arm_r", "40" })
		w.run(0.2)
		expect(inventory:Give(bob, "kit", 2)):toBe(2)
		expect(w.act(bob, "kit", "use")):toBe(true)
		w.run(1.2)
		local kits = {}
		for _, item in ipairs(inventory:ItemsOf(bob)) do
			if item.id == "kit" then
				kits[#kits + 1] = item.count .. ":" .. tostring(item.state.charge)
			end
		end
		table.sort(kits)
		expect(kits):toEqual({ "1:2", "1:nil" })
		-- The client sees the verbs of medical items.
		Env.Flush(w.server, client)
		local view = client:Get("NC").Modules:Instance("inventory")
		expect(view:VerbApplies("use", { id = "bandage", count = 1 }, "own", "pockets")):toBe(true)
		expect(view:VerbApplies("treat", { id = "morphine", count = 1 }, "own", "pockets")):toBe(false)
		expect(view:VerbApplies("use", { id = "defib", count = 1 }, "own", "pockets")):toBe(false)
		expect(view:VerbApplies("use", { id = "bandage", count = 1 }, "external", "crate")):toBe(false)
		expect(w.server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("examines the wounded in front and treats him from the buttons of the report", function()
		local w = boot()
		local medicClient, al = w.join("Al", { language = "ru" })
		local client, bob = w.join("Bob", { pos = Vector(50, 0, 0) })
		local inventory, organism, actions, medical = w.inventory, w.organism, w.actions, w.medical
		w.server:Command("nc_hurt", nil, { "Bob", "bullet", "femoral_artery_l" })
		w.run(0.5)
		inventory:Give(al, "tourniquet", 1)
		inventory:Give(al, "bandage", 3)
		inventory:Give(al, "morphine", 1)
		inventory:Give(al, "oximeter", 1)
		-- Nobody in front: the treat verb has no patient; F3 examines oneself.
		expect(w.act(al, "bandage", "treat")):toBe(false)
		expect(w.notice(medicClient)):toBe("Перед вами нет раненого")
		w.aims[al] = bob
		expect(select(1, medical:Aimed(al))):toBe(bob)
		w.server:Call("ShowSpare1", al)
		expect(actions:Current(al).id):toBe("examine")
		expect(actions:Current(al).duration):toBe(2)
		w.run(2.1)
		Env.Flush(w.server, medicClient)
		local view = medicClient:Get("NC").Modules:Instance("medical")
		local report = view.report
		expect(report.patient):toBe("Bob")
		expect(report.self):toBe(false)
		local found = keys(report.findings)
		expect(found:find("awake", 1, true) ~= nil):toBe(true)
		expect(found:find("bleed.arterial@leg_l", 1, true) ~= nil):toBe(true)
		expect(found:find("spo2", 1, true) ~= nil):toBe(true)
		expect(found:find("rhythm.sinus", 1, true) ~= nil):toBe(true)
		-- Morphine is for oneself only: not offered for another.
		expect(keys(report.options, "id")):toBe("tourniquet bandage")
		-- The panel: translated lines (red for an artery) and a button per option.
		local frame = view.frame
		expect(frame ~= nil and frame:IsValid()):toBe(true)
		local lines, buttons = {}, {}
		for _, panel in ipairs(World.FindPanels(medicClient, function(p) return p.ncFinding ~= nil end)) do
			lines[#lines + 1] = panel:GetText()
		end
		for _, panel in ipairs(World.FindPanels(medicClient, function(p) return p.ncOption ~= nil end)) do
			buttons[#buttons + 1] = panel
		end
		expect(table.concat(lines, "|"):find("Левая нога: артериальное кровотечение", 1, true) ~= nil):toBe(true)
		expect(#buttons):toBe(2)
		expect(buttons[1]:GetText()):toBe("Жгут")
		expect(buttons[2]:GetText()):toBe("Бинт ×3")
		-- The tourniquet button: the action on Bob, then the tourniquet on his left leg.
		medicClient:As(function() buttons[1].DoClick() end)
		expect(view.frame):toBeNil()
		Env.Flush(w.server, medicClient)
		expect(actions:Current(al).id):toBe("medical")
		expect(actions:Current(al).target):toBe(bob)
		w.run(3.1)
		expect(organism:State(bob).tourniquets.leg_l ~= nil):toBe(true)
		expect(inventory:Count(al, "tourniquet")):toBe(0)
		expect(w.treated):toEqual({ "Al>Bob tourniquet tourniquet" })
		expect(w.notice(client)):toBe("Al treats you: Tourniquet")
		-- The report now shows the tourniquet and offers to take it off.
		w.server:Call("ShowSpare1", al)
		w.run(2.1)
		Env.Flush(w.server, medicClient)
		report = view.report
		expect(keys(report.findings):find("tourniquet@leg_l", 1, true) ~= nil):toBe(true)
		expect(keys(report.options, "id")):toBe("bandage tourniquet_off@leg_l")
		-- The treat verb goes to the one in front: the faster time on another.
		expect(w.act(al, "bandage", "treat")):toBe(true)
		expect(actions:Current(al).duration):toBe(1.5)
		w.run(1.6)
		expect(wound(organism, bob, "femoral_artery_l").bandage > 0):toBe(true)
		expect(inventory:Count(al, "bandage")):toBe(2)
		-- Out of reach nothing starts; a question can forbid treating.
		bob:SetPos(Vector(400, 0, 0))
		expect({ medical:UseItem(al, bob, select(3, w.slot(al, "bandage"))) }):toEqual({ false, "reach" })
		bob:SetPos(Vector(50, 0, 0))
		w.NC.Events:On("medical.canTreat", function() return false end)
		expect({ medical:UseItem(al, bob, select(3, w.slot(al, "bandage"))) }):toEqual({ false, "denied" })
		expect(w.server:Errors()):toEqual({})
		expect(medicClient:Errors()):toEqual({})
	end)

	it("restarts a heart on a fallen body with compressions and a shock; the dead are beyond help", function()
		local w = boot()
		local medicClient, al = w.join("Al")
		local _, bob = w.join("Bob", { pos = Vector(40, 0, 0) })
		local organism, actions, medical, inventory = w.organism, w.actions, w.medical, w.inventory
		inventory:Give(al, "defib", 1)
		local st = organism:State(bob)
		organism:_Arrest(st, "vf")
		w.run(0.5)
		local body = w.ragdoll:Fall(bob)
		local rag = body and body.ent or organism:BodyEntity(bob)
		expect(organism:BodyEntity(bob)):toBe(rag)
		w.aims[al] = rag
		expect(select(1, medical:Aimed(al))):toBe(bob)
		expect(medical:ExamineAimed(al)):toBe(true)
		w.run(2.1)
		Env.Flush(w.server, medicClient)
		local report = medicClient:Get("NC").Modules:Instance("medical").report
		-- Gasps without a pulse are not breathing.
		expect(keys(report.findings):find("unconscious pulse.none breath.agonal", 1, true) ~= nil):toBe(true)
		expect(keys(report.options, "id")):toBe("defib cpr")
		-- Compressions with breaths all along; a beating heart ends them.
		expect(medical:UseHands(al, bob, "cpr")):toBe(true)
		expect(actions:Current(al).duration):toBe(30)
		w.run(1.5)
		expect(st.cprUntil > 0):toBe(true)
		expect(st.ventUntil > 0):toBe(true)
		organism:_Rosc(st)
		w.run(1.1)
		expect(actions:IsBusy(al)):toBe(false)
		expect(w.notice(medicClient)):toBe("Bob's heart beats again!")
		expect({ medical:UseHands(al, bob, "cpr") }):toEqual({ false, "pulse" })
		-- The shock of a defibrillator, which is never used up.
		organism:_Arrest(st, "vf")
		organism.Random = function() return 0 end
		expect(medical:UseItem(al, bob, select(3, w.slot(al, "defib")))):toBe(true)
		w.run(2.1)
		expect(st.rhythm):toBe("sinus")
		expect(inventory:Count(al, "defib")):toBe(1)
		expect({ medical:UseItem(al, al, select(3, w.slot(al, "defib"))) }):toEqual({ false, "self" })
		-- Dead: the examination says so and nothing is offered.
		organism:Injure(bob, { kind = "lethal", cause = "head" })
		w.run(0.5)
		expect(organism:IsDead(bob)):toBe(true)
		local corpse = organism:BodyEntity(bob)
		w.aims[al] = corpse
		expect(medical:ExamineAimed(al)):toBe(true)
		w.run(2.1)
		Env.Flush(w.server, medicClient)
		report = medicClient:Get("NC").Modules:Instance("medical").report
		expect(keys(report.findings)):toBe("dead")
		expect(#report.options):toBe(0)
		expect({ medical:UseItem(al, bob, select(3, w.slot(al, "defib"))) }):toEqual({ false, "dead" })
		expect(w.server:Errors()):toEqual({})
		expect(medicClient:Errors()):toEqual({})
	end)

	it("puts joints back and takes tourniquets off by hand; arms decide how fast", function()
		local w = boot()
		local client, bob = w.join("Bob")
		local organism, actions, medical = w.organism, w.actions, w.medical
		local st = organism:State(bob)
		organism:_Dislocate(st, "arm_l")
		organism:_Fracture(st, { kind = "blunt" }, organism.body.byId.humerus_r, 1, false,
			{ fractures = 0, wounds = 0, bleeding = 0 })
		expect(organism:ApplyTreatment(bob, "tourniquet", { limb = "leg_r" })):toBe(true)
		w.run(0.2)
		-- His own report offers both (no splint with him for the broken arm).
		expect(medical:ExamineAimed(bob)):toBe(true)
		expect(actions:Current(bob).duration):toBe(1)
		w.run(1.1)
		Env.Flush(w.server, client)
		local view = client:Get("NC").Modules:Instance("medical")
		expect(view.report.self):toBe(true)
		expect(keys(view.report.options, "id")):toBe("reduce@arm_l tourniquet_off@leg_r")
		local found = keys(view.report.findings)
		expect(found:find("dislocation@arm_l", 1, true) ~= nil):toBe(true)
		expect(found:find("tourniquet@leg_r", 1, true) ~= nil):toBe(true)
		expect(found:find("fracture@arm_r", 1, true) ~= nil):toBe(true)
		-- With one working arm (the other broken) it takes longer.
		local buttons = World.FindPanels(client, function(p) return p.ncOption ~= nil end)
		expect(buttons[1]:GetText()):toBe("Reduce the dislocation: Left arm")
		client:As(function() buttons[2].DoClick() end)
		Env.Flush(w.server, client)
		expect(actions:Current(bob).duration):toBe(4 * 1.6)
		w.run(6.5)
		expect(st.tourniquets.leg_r):toBeNil()
		expect(medical:UseHands(bob, bob, "reduce", "arm_l")):toBe(true)
		w.run(9 * 1.6 + 0.2)
		expect(st.dislocated.arm_l):toBeNil()
		expect({ medical:UseHands(bob, bob, "cpr") }):toEqual({ false, "self" })
		expect({ medical:UseHands(bob, bob, "reduce", "wing") }):toEqual({ false, "target" })
		-- Healthy: nothing found; the panel goes by itself.
		expect(view:IsOpen()):toBe(false)
		organism:ApplyTreatment(bob, "heal")
		w.run(0.2)
		expect(medical:ExamineAimed(bob)):toBe(true)
		w.run(1.1)
		Env.Flush(w.server, client)
		expect(view:IsOpen()):toBe(true)
		expect(keys(view.report.findings)):toBe("awake pulse.normal breath.normal ok")
		client:Advance(21)
		expect(view:IsOpen()):toBe(false)
		expect(w.server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
