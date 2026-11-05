-- Restraints: tying a player up with the use key and an item over time, what a tied
-- player cannot do (keys, weapons, inventory, speed), untying, broken attempts, the
-- questions of modes and the HUD, with the real gamemode files and test items.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN

local PACKAGE = {
	["nextcity/modules/ties/module.lua"] = "return { id = 'ties', requires = { 'inventory' },"
		.. " files = { sh = { 'sh_ties.lua' } } }",
	["nextcity/modules/ties/sh_ties.lua"] = [[
		local M = NC.Module("ties")
		function M:Init(ctx)
			local inventory = ctx:Require("inventory")
			inventory:RegisterItem("zipties", { weight = 0.02, stack = 10,
				traits = { restraint = { time = 2, untie = 3 } } })
			inventory:RegisterItem("cuffs", { weight = 0.3, traits = { restraint = { time = 1, consume = false } } })
			inventory:RegisterItem("bandage", { weight = 0.05, stack = 5 })
		end
	]],
}

local MODULES = { "players", "notices", "organism", "damage", "actions", "ragdoll", "inventory", "movement",
	"melee", "hands", "restraints" }

-- A shot-mask line of a player in `aims` hits the entity he aims at, on both realms.
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

local function boot()
	local server = Env.Server({ modules = MODULES, files = PACKAGE })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local w = { server = server, NC = NC, aims = {}, log = {} }
	aim(server, w.aims)
	for _, id in ipairs({ "players", "inventory", "actions", "restraints", "organism" }) do
		w[id] = NC.Modules:Instance(id)
	end
	w.organism.Random = function() return 0.5 end
	for _, name in ipairs({ "restraints.tied", "restraints.untied" }) do
		NC.Events:On(name, function(ply, by)
			w.log[#w.log + 1] = name .. " " .. ply:Nick() .. " by " .. (by ~= nil and by:Nick() or "-")
		end)
	end
	function w.join(name, x, language)
		local client, ply = Env.Join(server, { name = name, language = language })
		w.players:Deploy(ply)
		ply:SetPos(Vector(x or 0, 0, 0))
		ply:SetEyeAngles(Angle(0, 0, 0))
		aim(client, w.aims)
		return client, ply
	end
	function w.run(seconds)
		for _ = 1, math.floor(seconds / 0.1 + 0.5) do
			server:Advance(0.1)
		end
	end
	function w.notice(client)
		Env.Flush(server, client)
		local list = client:Get("NC").Modules:Instance("notices"):Active()
		return list[#list] and list[#list].text
	end
	return w
end

local function hud(client, server)
	server:Advance(0.3)
	client.time = server.time
	Env.Flush(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("restraints", function()
	it("ties a player up with the use key, makes him helpless and unties him", function()
		local w = boot()
		local server, restraints, inventory = w.server, w.restraints, w.inventory
		local alyxClient, alyx = w.join("Alyx", 0)
		local barneyClient, barney = w.join("Barney", 40, "ru")
		expect(inventory:Give(alyx, "zipties", 2)):toBe(2)
		local walk = barney:GetWalkSpeed()
		barney:Give("weapon_crowbar")
		barney:SelectWeapon("weapon_crowbar")

		-- The use key on him: an action of the time of the zip ties.
		w.aims[alyx] = barney
		Env.Press(server, alyx, IN.USE)
		expect(w.actions:Current(alyx).id):toBe("restraints.tie")
		expect(w.actions:Current(alyx).duration):toBe(2)
		w.run(1)
		expect(restraints:IsTied(barney)):toBe(false)
		w.run(1.1)
		expect(restraints:IsTied(barney)):toBe(true)
		expect(inventory:Count(alyx, "zipties")):toBe(1)
		expect(w.log):toEqual({ "restraints.tied Barney by Alyx" })

		-- Empty hands that stay empty, no attacks, use, sprint or jump, slower steps.
		expect(barney.selected):toBe("nc_hands")
		barney:SelectWeapon("weapon_crowbar")
		expect(barney.selected):toBe("nc_hands")
		local cmd = Env.RunCommand(server, barney, IN.ATTACK + IN.ATTACK2 + IN.USE + IN.SPEED + IN.JUMP + IN.FORWARD)
		expect(cmd:GetButtons()):toBe(IN.FORWARD)
		expect(barney:GetWalkSpeed()):toBeCloseTo(walk * 0.55, 0.01)
		-- No inventory: no verbs, no moves.
		inventory:Give(barney, "bandage", 1)
		local item = inventory:ItemsOf(barney)[1]
		expect({ inventory:Act(barney, item.container.id, item.slot, "drop", 0) }):toEqual({ false, "denied" })
		-- A tied player cannot tie anybody up.
		inventory:Give(barney, "zipties", 1)
		w.aims[barney] = alyx
		Env.Press(server, barney, IN.USE)
		expect(w.actions:Current(barney)):toBeNil()

		-- What the players see.
		local drawn = hud(barneyClient, server)
		expect(drawn):toContain("Руки связаны")
		expect(w.notice(barneyClient)):toBe("Вас связали")
		drawn = hud(alyxClient, server)
		expect(drawn):toContain("Barney")
		expect(drawn):toContain("Tied up")

		-- The use key on a tied player unties him (the untie time of the zip ties).
		Env.Press(server, alyx, IN.USE)
		expect(w.actions:Current(alyx).id):toBe("restraints.untie")
		expect(w.actions:Current(alyx).duration):toBe(3)
		w.run(3.1)
		expect(restraints:IsTied(barney)):toBe(false)
		expect(barney:GetWalkSpeed()):toBeCloseTo(walk, 0.01)
		barney:SelectWeapon("weapon_crowbar")
		expect(barney.selected):toBe("weapon_crowbar")
		expect(w.notice(barneyClient)):toBe("Вы свободны")
		expect(w.log[2]):toBe("restraints.untied Barney by Alyx")
		expect(server:Errors()):toEqual({})
		expect(alyxClient:Errors()):toEqual({})
		expect(barneyClient:Errors()):toEqual({})
	end)

	it("breaks off when the other walks away, asks modes and frees the dead", function()
		local w = boot()
		local server, restraints, inventory = w.server, w.restraints, w.inventory
		local alyxClient, alyx = w.join("Alyx", 0)
		local _, barney = w.join("Barney", 40)
		w.aims[alyx] = barney

		-- Without a restraint the use key does nothing.
		Env.Press(server, alyx, IN.USE)
		expect(w.actions:Current(alyx)):toBeNil()

		-- Handcuffs are not used up; walking away breaks the action.
		inventory:Give(alyx, "cuffs", 1)
		Env.Press(server, alyx, IN.USE)
		expect(w.actions:Current(alyx).duration):toBe(1)
		barney:SetPos(Vector(400, 0, 0))
		w.run(0.3)
		expect(w.actions:Current(alyx)):toBeNil()
		barney:SetPos(Vector(40, 0, 0))
		Env.Press(server, alyx, IN.USE)
		w.run(1.1)
		expect(restraints:IsTied(barney)):toBe(true)
		expect(inventory:Count(alyx, "cuffs")):toBe(1)
		-- The default untie time.
		Env.Press(server, alyx, IN.USE)
		expect(w.actions:Current(alyx).duration):toBe(3)
		w.actions:Cancel(alyx)

		-- A mode forbids it.
		restraints:Untie(barney)
		local handle = w.NC.Events:On("restraints.canTie", function(ply, target)
			if ply == alyx and target == barney then
				return false
			end
		end)
		Env.Press(server, alyx, IN.USE)
		expect(w.actions:Current(alyx)):toBeNil()
		expect(w.notice(alyxClient)):toBe("You cannot do that now")
		w.NC.Events:Off(handle)

		-- Death frees him.
		expect(restraints:Tie(barney, alyx)):toBe(true)
		expect({ restraints:Tie(barney, alyx) }):toEqual({ false, "tied" })
		Env.Kill(barney, alyx)
		server:Advance(0.1)
		expect(restraints:IsTied(barney)):toBe(false)
		expect(w.log[#w.log]):toBe("restraints.untied Barney by -")
		expect(server:Errors()):toEqual({})
	end)
end)
