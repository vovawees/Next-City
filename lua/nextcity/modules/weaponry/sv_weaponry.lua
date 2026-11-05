-- Weaponry, server part: what the throwables do when they go off and the loot tables of
-- weapons and ammunition (when the loot module runs):
--
--   ammo_pistol, ammo_smg, ammo_rifle, ammo_shotgun   rounds of one kind
--   ammo                                              any of them
--   weapons_melee                                     crowbars, knives, batons, bottles
--   weapons_civil                                     pistols, a revolver, a shotgun or melee
--   weapons_military                                  SMGs, rifles, shotguns, grenades

local M = NC.Module("weaponry")

local IsValid = IsValid

function M:_InitServer(ctx)
	self.explosions = ctx:Require("explosions")
	local loot = ctx:Require("loot")
	if loot ~= nil then
		self:_Loot(loot)
	end
end

-- A throwable went off: a grenade explodes (explosions), a bottle shatters.
function M:Detonate(ent, thrower, pos, spec)
	if spec.blast ~= nil and self.explosions ~= nil then
		self.explosions:Explode(pos, { attacker = IsValid(thrower) and thrower or nil,
			inflictor = IsValid(ent) and ent or nil, charge = spec.blast.charge, casing = spec.blast.casing,
			filter = IsValid(ent) and ent or nil, ammo = "nc_frag" })
	end
	if spec.shatter and IsValid(ent) then
		ent:Fire("Break")
	end
end

function M:_Loot(loot)
	loot:RegisterTable("ammo_pistol", { entries = {
		{ item = "ammo_9x19", weight = 3, count = { 8, 30 } },
		{ item = "ammo_357", weight = 1, count = { 6, 18 } },
	} })
	loot:RegisterTable("ammo_smg", { entries = { { item = "ammo_46x30", count = { 20, 60 } } } })
	loot:RegisterTable("ammo_rifle", { entries = { { item = "ammo_556", count = { 15, 45 } } } })
	loot:RegisterTable("ammo_shotgun", { entries = {
		{ item = "ammo_12g_buck", weight = 3, count = { 4, 12 } },
		{ item = "ammo_12g_slug", weight = 1, count = { 2, 8 } },
	} })
	loot:RegisterTable("ammo", { entries = {
		{ table = "ammo_pistol", weight = 4 },
		{ table = "ammo_smg", weight = 2 },
		{ table = "ammo_rifle", weight = 1 },
		{ table = "ammo_shotgun", weight = 2 },
	} })
	loot:RegisterTable("weapons_melee", { entries = {
		{ item = "crowbar", weight = 3 },
		{ item = "knife", weight = 3 },
		{ item = "stunstick", weight = 1 },
		{ item = "bottle", weight = 3, count = { 1, 2 } },
	} })
	loot:RegisterTable("weapons_civil", { entries = {
		{ item = "usp", weight = 4 },
		{ item = "python", weight = 2 },
		{ item = "spas12", weight = 1 },
		{ table = "weapons_melee", weight = 6 },
	} })
	loot:RegisterTable("weapons_military", { entries = {
		{ item = "mp7", weight = 3 },
		{ item = "ar2", weight = 2 },
		{ item = "spas12", weight = 2 },
		{ item = "usp", weight = 2 },
		{ item = "frag", weight = 3, count = { 1, 2 } },
	} })
end
