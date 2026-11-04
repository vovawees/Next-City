-- Ammo module: the registry of the rounds of a package on top of the core, its engine
-- ammo types on both realms, the damage pipeline and the console, with the real gamemode
-- files in emulated realms.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

-- A content package (an addon): its module registers rounds in Init.
local ARSENAL = {
	["nextcity/modules/arsenal/module.lua"] = "return { id = 'arsenal', requires = { 'ammo' },"
		.. " files = { sh = { 'sh_arsenal.lua' } } }",
	["nextcity/modules/arsenal/sh_arsenal.lua"] = [[
		local M = NC.Module("arsenal")
		function M:Init(ctx)
			local ammo = ctx:Require("ammo")
			ammo:Register("9x19_fmj", { caliber = "9x19", mass = 8, velocity = 360, diameter = 9, penetration = 60,
				range = 540 })
			ammo:Register("9x19_hp", { caliber = "9x19", mass = 8, velocity = 370, diameter = 9, penetration = 30,
				expansion = 0.7, range = 500, maxCarry = 120 })
			ammo:Register("12g_buck", { caliber = "12/70", mass = 3.5, velocity = 400, diameter = 8.4,
				penetration = 30, range = 100, pellets = 9, spread = 1.5 })
		end
	]],
}

local function boot(files)
	local server = Env.Server({ files = files or ARSENAL, modules = { "players", "organism", "damage", "ammo" } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC.Modules:Instance("ammo"), NC.Modules:Instance("damage"), NC.Modules:Instance("players")
end

describe("ammo", function()
	it("registers the rounds of a package as engine ammo types on both realms", function()
		local server, ammo = boot()
		local client = Env.Join(server, { name = "Gordon" })
		expect(ammo:All()):toEqual({ "9x19_fmj", "9x19_hp", "12g_buck" })
		expect(ammo:OfCaliber("9x19")):toEqual({ "9x19_fmj", "9x19_hp" })
		expect(ammo:OfCaliber("5.56x45")):toEqual({})
		local fmj = ammo:Get("9x19_fmj")
		expect(fmj.ap == 1 and fmj.pellets == 1 and fmj.spread == 0 and fmj.maxCarry == 9999):toBe(true)
		expect(ammo:Get("12g_buck").pellets):toBe(9)
		expect(ammo:Get("missing")):toBeNil()
		local game = server:Get("game")
		local id = game.GetAmmoID("9x19_hp")
		expect(id > #World.AMMO):toBe(true)
		expect(game.GetAmmoMax(id)):toBe(120)
		expect(client:Get("game").GetAmmoID("9x19_hp")):toBe(id)
		local clientAmmo = client:Get("NC").Modules:Instance("ammo")
		expect(clientAmmo:All()):toEqual(ammo:All())
		-- Velocity and energy after a flight.
		local v, e = ammo:At("9x19_fmj", 0)
		expect(v == 360 and math.abs(e - 518.4) < 1e-9):toBe(true)
		v = ammo:At("9x19_fmj", 540)
		expect(math.abs(v - 360 / math.exp(1)) < 1e-9):toBe(true)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("lets engine bullets of a registered type injure like its projectile", function()
		local server, ammo, damage, players = boot()
		expect(damage:Ammo("9x19_hp")):toBe(ammo:Get("9x19_hp"))
		local victim = Env.Bot(server, { name = "Bob" })
		local shooter = Env.Bot(server, { name = "Al" })
		server:Advance(0.1)
		players:Deploy(victim)
		players:Deploy(shooter)
		victim:SetPos(Vector(0, 0, 0))
		shooter:SetPos(Vector(400, 0, 0))
		Env.Shoot(shooter, victim, { ammo = "9x19_hp", bone = "Spine2" })
		local hit = damage:History(1)[1]
		expect(hit.ammo):toBe("9x19_hp")
		local distance = hit.distance
		local _, energy = ammo:At("9x19_hp", distance)
		expect(math.abs(hit.energy - energy) < 1e-6):toBe(true)
		-- A type registered later reaches the pipeline as well.
		ammo:Register("9x19_ap", { caliber = "9x19", mass = 6, velocity = 450, diameter = 9, penetration = 70,
			range = 600, ap = 1.6 })
		expect(damage:Ammo("9x19_ap").ap):toBe(1.6)
		expect(server:Errors()):toEqual({})
	end)

	it("refuses broken definitions with the reason", function()
		local _, ammo = boot()
		local function register(id, def)
			local ok, err = pcall(ammo.Register, ammo, id, def)
			return ok, tostring(err)
		end
		local ok, err = register("bad id!", { caliber = "x" })
		expect(ok):toBe(false)
		expect(err):toContain("id must be")
		ok, err = register("nocal", { mass = 8, velocity = 360, diameter = 9, penetration = 60, range = 500 })
		expect(err):toContain("caliber must be a string")
		ok, err = register("slow", { caliber = "x", mass = 8, velocity = 0, diameter = 9, penetration = 60, range = 500 })
		expect(err):toContain("velocity must be a positive number")
		ok, err = register("neg", { caliber = "x", mass = 8, velocity = 300, diameter = 9, penetration = 60, range = 500,
			ap = -1 })
		expect(err):toContain("ap must be a number >= 0")
		expect(ok):toBe(false)
		-- Replacing a type moves it to its new caliber.
		ammo:Register("9x19_hp", { caliber = "9x21", mass = 8, velocity = 380, diameter = 9, penetration = 30,
			range = 500 })
		expect(ammo:OfCaliber("9x19")):toEqual({ "9x19_fmj" })
		expect(ammo:OfCaliber("9x21")):toEqual({ "9x19_hp" })
		expect(#ammo:All()):toBe(3)
	end)

	it("lists the ammunition in the console", function()
		local server = boot()
		server:Command("nc_ammo", nil, {})
		expect(#server:Lines("9x19_fmj")):toBe(1)
		expect(server:Lines("12g_buck")[1]):toContain("x9")
		server:Command("nc_ammo", nil, { "12/70" })
		expect(#server:Lines("12g_buck")):toBe(2)
		expect(#server:Lines("9x19_fmj")):toBe(1)
		server:Command("nc_ammo", nil, { "none" })
		expect(#server:Lines("no ammunition of caliber none")):toBe(1)
		expect(server:Errors()):toEqual({})
	end)
end)
