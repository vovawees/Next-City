-- The official package (lua/nextcity): weaponry (rounds, firearms, melee weapons,
-- throwables and their items) and supplies (medicine, armor, bags, loot tables, crates
-- and kits) boot with the default config, refer only to what exists, are translated and
-- work with the systems of the core.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector

local SPAWNS = {
	{ class = "info_player_start", pos = Vector(0, 0, 0), map = true },
	{ class = "info_player_start", pos = Vector(500, 0, 0), map = true },
}

local function boot(files)
	local server = Env.Server({ files = files })
	for _, point in ipairs(SPAWNS) do
		Env.Spawn(server, point)
	end
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = setmetatable({}, { __index = function(_, id) return NC.Modules:Instance(id) end })
	return server, m, NC
end

local function join(server, m, name, language)
	local client, ply = Env.Join(server, { name = name, language = language })
	m.players:Deploy(ply)
	ply:SetPos(Vector(0, 0, 0))
	return client, ply
end

-- Every item of the package: { id, def } of both modules.
local function items(m)
	local out = {}
	for _, list in ipairs({ m.weaponry.ITEMS, m.supplies.ITEMS }) do
		for _, entry in ipairs(list) do
			out[#out + 1] = entry[1]
		end
	end
	return out
end

describe("official package", function()
	it("boots cleanly with everything registered", function()
		local server, m = boot()
		expect(server:Errors()):toEqual({})
		expect(#server:Lines("WARN")):toBe(0)
		expect(m.ammo:All()):toEqual({ "9x19_fmj", "357_jhp", "46x30_ap", "556_m855", "12g_buck", "12g_slug" })
		expect(m.weapons:All()):toEqual({ "nc_usp", "nc_python", "nc_mp7", "nc_ar2", "nc_spas12" })
		expect(m.melee:All()):toEqual({ "nc_crowbar", "nc_stunstick", "nc_knife" })
		expect(m.throwables:All()):toEqual({ "nc_frag", "nc_bottle" })
		expect(#items(m)):toBe(44)
		expect(m.loot:Crates()):toEqual({ "crate_medical", "crate_military", "crate_wood" })
		expect(m.inventory:Kits()):toEqual({ "city_bandit", "city_citizen", "city_gundealer", "city_mayor",
			"city_medic", "city_police", "coop", "defense", "defense_resupply", "dm", "hideseek_seeker",
			"homicide_murderer", "homicide_murderer_wildwest", "homicide_sheriff", "homicide_sheriff_gunfree",
			"homicide_wildwest", "riot_police", "riot_police_armed", "riot_rioter", "tdm" })
		expect(m.npcs:Kinds()):toEqual({ "antlion", "combine", "combine_elite", "combine_shotgun", "headcrab",
			"headcrab_fast", "headcrab_poison", "manhack", "metrocop", "zombie", "zombie_fast", "zombie_poison" })
		expect(m.npcs:Groups()):toEqual({ "antlions", "combine", "combine_elite", "metrocops", "zombies",
			"zombies_fast" })
	end)

	it("refers only to registered rounds, weapons, kinds of armor, treatments, items and tables", function()
		local server, m = boot()
		local problems = {}
		local function problem(text)
			problems[#problems + 1] = text
		end
		local inventory, organism = m.inventory, m.organism
		for _, id in ipairs(items(m)) do
			local def = inventory:Def(id)
			local traits = def.traits
			if traits.weapon ~= nil then
				local class = traits.weapon.class
				if m.weapons:Get(class) == nil and m.melee:Get(class) == nil and m.throwables:Get(class) == nil then
					problem(id .. ": weapon " .. tostring(class))
				end
				if traits.weapon.slot ~= nil and not m.equipment.WEAPON_SLOTS[traits.weapon.slot] then
					problem(id .. ": slot " .. tostring(traits.weapon.slot))
				end
				if m.equipment:SlotFor(def) == nil then
					problem(id .. ": no slot of the equipment")
				end
			end
			if traits.ammo ~= nil and m.ammo:Get(traits.ammo) == nil then
				problem(id .. ": ammo " .. tostring(traits.ammo))
			end
			if traits.armor ~= nil and (m.armor:Kind(traits.armor) == nil or m.equipment:SlotFor(def) == nil) then
				problem(id .. ": armor " .. tostring(traits.armor))
			end
			if traits.medical ~= nil and organism.TREATMENTS[traits.medical.treatment] == nil then
				problem(id .. ": treatment " .. tostring(traits.medical.treatment))
			end
			if traits.wear ~= nil and m.equipment:SlotFor(def) ~= traits.wear then
				problem(id .. ": wear " .. tostring(traits.wear))
			end
		end
		for _, id in ipairs(m.loot:Crates()) do
			if m.loot:Table(m.loot:Crate(id).table) == nil then
				problem("crate " .. id .. ": table " .. tostring(m.loot:Crate(id).table))
			end
		end
		-- Rolls reach every entry sooner or later: unknown items and tables would warn.
		for _, id in ipairs(m.loot:Tables()) do
			for _ = 1, 300 do
				m.loot:Roll(id)
			end
		end
		for _, line in ipairs(server:Lines("WARN")) do
			problem(line)
		end
		for _, kit in ipairs(m.inventory:Kits()) do
			for _, entry in ipairs(m.inventory:Kit(kit)) do
				if inventory:Def(entry.item) == nil then
					problem("kit " .. kit .. ": " .. entry.item)
				end
			end
		end
		for _, group in ipairs(m.npcs:Groups()) do
			for _, entry in ipairs(m.npcs:Group(group).entries) do
				if m.npcs:Kind(entry.kind) == nil then
					problem("group " .. group .. ": " .. entry.kind)
				end
			end
		end
		local city = m.mode_city
		for _, id in ipairs(city:Jobs()) do
			if inventory:Kit(city:Job(id).kit) == nil then
				problem("job " .. id .. ": kit " .. city:Job(id).kit)
			end
		end
		for _, id in ipairs(city:Offers()) do
			local offer = city:Offer(id)
			if inventory:Def(offer.item) == nil then
				problem("offer " .. id .. ": " .. offer.item)
			end
			for _, job in ipairs(offer.jobs or {}) do
				if city:Job(job) == nil then
					problem("offer " .. id .. ": job " .. job)
				end
			end
		end
		expect(problems):toEqual({})
	end)

	it("names and describes every thing in English and Russian", function()
		local server, m, NC = boot()
		local _, bob = join(server, m, "Bob", "en")
		local _, ivan = join(server, m, "Ivan", "ru")
		server:Advance(0.1)
		local i18n = NC.I18n
		local missing = {}
		local function check(key)
			for _, ply in ipairs({ bob, ivan }) do
				if i18n:TFor(ply, key) == key then
					missing[#missing + 1] = key .. " (" .. (ply == bob and "en" or "ru") .. ")"
				end
			end
		end
		for _, id in ipairs(items(m)) do
			local def = m.inventory:Def(id)
			check(def.name)
			check(def.description)
		end
		for _, id in ipairs(m.ammo:All()) do
			check("ammo." .. id)
		end
		for _, class in ipairs(m.weapons:All()) do
			check("weapons." .. class)
		end
		for _, class in ipairs(m.melee:All()) do
			check("melee." .. class)
		end
		for _, class in ipairs(m.throwables:All()) do
			check("throwables." .. class)
		end
		for _, id in ipairs(m.loot:Crates()) do
			check(m.loot:Crate(id).title)
		end
		expect(missing):toEqual({})
		expect(i18n:TFor(ivan, "items.mp7.desc")):toContain("Пистолет-пулемёт")
	end)

	it("arms a player through the equipment: loaded weapons, reloads from ammo items", function()
		local server, m = boot()
		local _, bob = join(server, m, "Bob")
		m.inventory:Give(bob, "usp")
		m.inventory:Give(bob, "ammo_9x19", 30)
		local weapon = bob:GetWeapon("nc_usp")
		expect(weapon:IsValid()):toBe(true)
		expect(weapon:Clip1()):toBe(16)
		expect(m.equipment:CountAmmo(bob, "9x19_fmj")):toBe(30)
		m.inventory:Give(bob, "frag", 2)
		expect(bob:HasWeapon("nc_frag")):toBe(true)
		m.inventory:Give(bob, "backpack")
		m.inventory:Give(bob, "spas12")
		expect(bob:HasWeapon("nc_spas12")):toBe(true)
		expect(m.equipment:Item(bob, "back").id):toBe("backpack")
		m.inventory:Give(bob, "ar2")
		expect(m.inventory:Count(m.equipment:Item(bob, "back").sub, "ar2")):toBe(0) -- too long for a backpack
		expect(server:Errors()):toEqual({})
	end)

	it("sets off grenades with the explosions module and shatters bottles", function()
		local server, m, NC = boot()
		local _, bob = join(server, m, "Bob")
		local blasts = {}
		NC.Events:On("explosions.exploded", function(pos, attacker, inflictor, charge)
			blasts[#blasts + 1] = { pos = pos, attacker = attacker, charge = charge }
		end)
		local frag = m.throwables:Launch(bob, "nc_frag", { pos = Vector(200, 0, 10), velocity = Vector(0, 0, 0) })
		expect(m.throwables:Detonate(frag)):toBe(true)
		expect(#blasts):toBe(1)
		expect(blasts[1].attacker):toBe(bob)
		expect(blasts[1].charge):toBe(0.18)
		local bottle = m.throwables:Launch(bob, "nc_bottle", { pos = Vector(0, 200, 10), velocity = Vector(0, 0, 0) })
		expect(m.throwables:Detonate(bottle)):toBe(true)
		expect(bottle.inputs[1][1]):toBe("Break")
		expect(#blasts):toBe(1)
		expect(server:Errors()):toEqual({})
	end)

	it("fills the crates of the map and treats with its medicine", function()
		local server, m, NC = boot()
		m.loot.Random = function(a)
			return a or 0
		end
		local _, c = m.loot:SpawnCrate("crate_military", Vector(100, 0, 0))
		expect(m.inventory:Count(c, "helmet")):toBe(2)
		local _, box = m.loot:SpawnCrate("crate_medical", Vector(100, 100, 0))
		expect(m.inventory:Count(box, "bandage")):toBe(4)

		local _, bob = join(server, m, "Bob")
		for _, id in ipairs({ "bandage", "tourniquet", "morphine", "splint", "defibrillator", "pulse_oximeter" }) do
			m.inventory:Give(bob, id)
		end
		server:Command("nc_hurt", nil, { "Bob", "slash", "arm_l", "40" })
		local options = {}
		for _, option in ipairs(m.medical:Options(bob, bob, m.organism:Examine(bob))) do
			options[#options + 1] = option.id
		end
		expect(options):toContain("bandage")
		expect(options):toContain("morphine")
		expect(options):notToContain("splint")        -- nothing is broken
		expect(options):notToContain("defibrillator") -- on another only
		local treated = {}
		NC.Events:On("medical.treated", function(_, _, kind, item)
			treated[#treated + 1] = kind .. " " .. item
		end)
		local item
		for _, thing in ipairs(m.inventory:ItemsOf(bob)) do
			if thing.id == "bandage" then
				item = thing
			end
		end
		expect(m.medical:UseItem(bob, bob, item)):toBe(true)
		for _ = 1, 40 do
			server:Advance(0.1)
		end
		expect(treated):toEqual({ "bandage bandage" })
		expect(m.inventory:Count(bob, "bandage")):toBe(0)
		expect(server:Errors()):toEqual({})
	end)
	it("lets a server package add a gun of its own as its README shows", function()
		local server, m = boot({
			["nextcity/modules/my_guns/module.lua"] = [[
				return { id = "my_guns", requires = { "weaponry", "weapons", "inventory" },
					files = { sh = { "sh_my_guns.lua" } } }
			]],
			["nextcity/modules/my_guns/sh_my_guns.lua"] = [[
				local M = NC.Module("my_guns")
				function M:Init(ctx)
					ctx:Require("weapons"):Register("my_glock", { caliber = "9x19", magazine = 17, rpm = 600,
						viewModel = "models/weapons/c_pistol.mdl", worldModel = "models/weapons/w_pistol.mdl",
						useHands = true })
					ctx:Require("inventory"):RegisterItem("glock", { model = "models/weapons/w_pistol.mdl",
						weight = 0.7, category = "weapon",
						traits = { weapon = { class = "my_glock", slot = "secondary" } } })
				end
			]],
		})
		expect(server:Errors()):toEqual({})
		expect(m.weapons:All()):toContain("my_glock")
		local _, bob = join(server, m, "Bob")
		m.inventory:Give(bob, "glock")
		m.inventory:Give(bob, "ammo_9x19", 17)
		expect(bob:GetWeapon("my_glock"):Clip1()):toBe(18)
		expect(m.equipment:CountAmmo(bob, "9x19_fmj")):toBe(17)
		expect(server:Errors()):toEqual({})
	end)
end)
