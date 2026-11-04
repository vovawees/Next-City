-- Armor, shared part: classes and kinds of armor.
--
-- A kind of armor (RegisterArmor) is one protective layer worn in a slot:
--   slot      "helmet", "vest", "plates", ...: one piece per slot
--   class     1..6, what it stops (M.CLASSES)
--   material  "soft" (aramid and polyethylene fabric) or "hard" (plates and helmets)
--   coverage  { [region] = true | { [side] = true } }: regions of the body (head, face,
--             neck, chest, abdomen, pelvis, arm_l, leg_r, ...) and, for the torso and the
--             head, the sides (front, back, left, right) it covers
--   share     the part of the covered area it really covers (edges, gaps), default 1
--   hits      how many hits at the limit of its class wear it out
--   layer     order from the outside, default 1 (plates go over a vest: 1 and 2)
--   mass      kg
-- The names are translated: "armor.<id>".

local M = NC.Module("armor")

-- The threat a class stops: energy (J) of a 9 mm projectile, other diameters and armor
-- piercing projectiles count more (see M.Threat).
M.CLASSES = {
	{ protection = 350 },  -- 1: small pistol rounds
	{ protection = 600 },  -- 2: 9x19 mm, .40 S&W (NIJ IIA)
	{ protection = 1000 }, -- 3: .357 Magnum (NIJ II)
	{ protection = 1600 }, -- 4: .44 Magnum, 4.6x30 mm (NIJ IIIA)
	{ protection = 3800 }, -- 5: 5.56x45 mm, 7.62x51 mm ball (NIJ III)
	{ protection = 5500 }, -- 6: .30-06 armor piercing (NIJ IV)
}

-- floor: the share of the protection left when worn out; blunt: the share of the energy
-- of a stopped projectile that hits the body behind; melee: what is left of a blow.
M.MATERIALS = {
	soft = { floor = 0.6, blunt = 0.08, melee = 0.7 },
	hard = { floor = 0.35, blunt = 0.03, melee = 0.5 },
}

local FRONT_BACK = { front = true, back = true }

M.ARMOR_DEFAULTS = {
	helmet = { slot = "helmet", class = 4, material = "hard", coverage = { head = true }, share = 0.9, hits = 4,
		mass = 1.4 },
	vest_light = { slot = "vest", class = 2, material = "soft", coverage = { chest = true, abdomen = true }, hits = 6,
		layer = 2, mass = 2 },
	vest = { slot = "vest", class = 4, material = "soft", coverage = { chest = true, abdomen = true }, hits = 6,
		layer = 2, mass = 3.5 },
	plates = { slot = "plates", class = 5, material = "hard", coverage = { chest = FRONT_BACK, abdomen = FRONT_BACK },
		share = 0.8, hits = 4, mass = 6 },
	plates_heavy = { slot = "plates", class = 6, material = "hard",
		coverage = { chest = FRONT_BACK, abdomen = FRONT_BACK }, share = 0.8, hits = 3, mass = 8 },
}

function M:_InitKinds()
	self.kinds = {}
	for id, def in pairs(M.ARMOR_DEFAULTS) do
		self:RegisterArmor(id, def)
	end
end

-- Registers or replaces a kind of armor (see the top of the file).
function M:RegisterArmor(id, def)
	assert(type(id) == "string" and id ~= "", "armor: RegisterArmor(id, def): id must be a string")
	assert(type(def) == "table", "armor: RegisterArmor: def of '" .. id .. "' must be a table")
	assert(type(def.slot) == "string" and def.slot ~= "", "armor: RegisterArmor: slot of '" .. id .. "' is missing")
	assert(M.CLASSES[def.class] ~= nil, "armor: RegisterArmor: class of '" .. id .. "' must be 1.." .. #M.CLASSES)
	assert(M.MATERIALS[def.material] ~= nil, "armor: RegisterArmor: material of '" .. id .. "' must be soft or hard")
	assert(type(def.coverage) == "table", "armor: RegisterArmor: coverage of '" .. id .. "' must be a table")
	assert(type(def.hits) == "number" and def.hits > 0, "armor: RegisterArmor: hits of '" .. id .. "' must be > 0")
	local kind = {}
	for key, value in pairs(def) do
		kind[key] = value
	end
	kind.id = id
	kind.share = def.share or 1
	kind.layer = def.layer or 1
	kind.mass = def.mass or 0
	kind.protection = M.CLASSES[def.class].protection
	self.kinds[id] = kind
end

-- The kind of armor `id` (do not modify), or nil.
function M:Kind(id)
	return self.kinds[id]
end

-- Ids of the kinds of armor, sorted (a new table).
function M:Kinds()
	local ids = {}
	for id in pairs(self.kinds) do
		ids[#ids + 1] = id
	end
	table.sort(ids)
	return ids
end

-- Whether a kind covers a region (and side) of the body.
function M.Covers(kind, region, side)
	local covered = kind.coverage[region]
	if covered == true then
		return true
	end
	return covered ~= nil and side ~= nil and covered[side] == true
end

-- The threat of a projectile with `energy` (J) to armor.
function M.Threat(energy, projectile)
	local diameter = projectile and projectile.diameter or 9
	return energy * math.sqrt(9 / diameter) * (projectile and projectile.ap or 1)
end
