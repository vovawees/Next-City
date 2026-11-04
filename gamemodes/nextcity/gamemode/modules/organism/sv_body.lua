-- Organism, server part: the body schema and the geometry of hits.
--
-- The body is data (M.BODY): segments with frames built from bones of the ValveBiped
-- skeleton, and structures (organs, bones, vessels, nerves, the airway and soft tissue)
-- made of capsules and spheres in the frame of their segment. A projectile is a ray
-- through the structures: where shapes overlap, the structure with the highest priority
-- takes the path. Models without these bones use a standing reference skeleton turned
-- by the yaw of the player.
--
-- Units: 1 unit = 2.54 cm, sizes scale with the torso of the model. Torso, neck and head
-- frames: x forward, y left, z up. Limb frames: x anterior, y medial, z along the limb
-- from the proximal joint (0) to the distal one (1).
--
-- Structure fields: id, seg, kind (organ, bone, vessel, nerve, airway, soft), shapes,
-- prio (where shapes overlap the higher wins; default by kind), hp (energy, J, that
-- destroys an organ or breaks a bone), fragility (damage per J relative to hp), bleed
-- (ml/min at normal pressure when cut or destroyed; for bones when broken), cavity (where
-- blood goes: external, chest_l, chest_r, chest (the side of the hit), pericardium,
-- abdomen, skull, airway, tissue), arterial, junctional (no tourniquet stops it), density
-- (energy loss relative to soft tissue), shell (hollow, wall thickness), coverage (share
-- of a shell that is bone: the ribs), region (body region for armor and the HUD), pain
-- (of a broken bone), use ({ broken, splinted }: function of the limb with the bone
-- broken), cord (level of a spinal cord segment: 1 lumbar .. 4 high cervical).

local M = NC.Module("organism")

local sqrt = math.sqrt
local min = math.min
local max = math.max
local cos = math.cos
local sin = math.sin
local rad = math.rad
local sort = table.sort
local IsValid = IsValid
local CurTime = CurTime

local FAR = 400        -- the exit of a shape is searched from this far along the ray, units
local REF_TORSO = 23.5 -- pelvis to neck of the reference skeleton, units
local MIN_TORSO, MAX_TORSO = 8, 60 -- bone positions with a torso outside this are not trusted
local HEAD_PITCH = 50  -- the head follows the eyes at most this far up and down, degrees
local EPSILON = 1e-4

M.UNIT_CM = 2.54

-- Source of chance for every roll of the model (tests replace it): a number in [0, 1).
M.Random = math.random

-- Bones of the frames.
local BONES = {
	pelvis = "ValveBiped.Bip01_Pelvis", neck = "ValveBiped.Bip01_Neck1", head = "ValveBiped.Bip01_Head1",
	upperarmL = "ValveBiped.Bip01_L_UpperArm", upperarmR = "ValveBiped.Bip01_R_UpperArm",
	forearmL = "ValveBiped.Bip01_L_Forearm", forearmR = "ValveBiped.Bip01_R_Forearm",
	handL = "ValveBiped.Bip01_L_Hand", handR = "ValveBiped.Bip01_R_Hand",
	thighL = "ValveBiped.Bip01_L_Thigh", thighR = "ValveBiped.Bip01_R_Thigh",
	calfL = "ValveBiped.Bip01_L_Calf", calfR = "ValveBiped.Bip01_R_Calf",
	footL = "ValveBiped.Bip01_L_Foot", footR = "ValveBiped.Bip01_R_Foot",
	toeL = "ValveBiped.Bip01_L_Toe0", toeR = "ValveBiped.Bip01_R_Toe0",
}
local BONE_KEYS = {}
for key in pairs(BONES) do
	BONE_KEYS[#BONE_KEYS + 1] = key
end
sort(BONE_KEYS)

-- Standing reference skeleton facing +x, relative to the feet.
local REFERENCE = {
	pelvis = { 0, 0, 38.5 }, neck = { 0.3, 0, 62 }, head = { 0.6, 0, 65.5 },
	upperarmL = { 0, 7, 59 }, upperarmR = { 0, -7, 59 }, forearmL = { 0, 8, 48 }, forearmR = { 0, -8, 48 },
	handL = { 2, 8, 38 }, handR = { 2, -8, 38 }, thighL = { 0, 3.8, 37.5 }, thighR = { 0, -3.8, 37.5 },
	calfL = { 0.5, 3.8, 20.5 }, calfR = { 0.5, -3.8, 20.5 }, footL = { -0.5, 3.8, 3.5 },
	footR = { -0.5, -3.8, 3.5 }, toeL = { 4.5, 3.8, 0.8 }, toeR = { 4.5, -3.8, 0.8 },
}

-- Schema ---------------------------------------------------------------------------------

local function capsule(x1, y1, z1, x2, y2, z2, r)
	return { capsule = true, x1, y1, z1, x2, y2, z2, r }
end

local function sphere(x, y, z, r)
	return { capsule = false, x, y, z, x, y, z, r }
end

local KIND_PRIO = { soft = 10, bone = 20, organ = 30, airway = 35, vessel = 40, nerve = 45 }
local KIND_DENSITY = { soft = 1, bone = 5, organ = 1, airway = 0.5, vessel = 1, nerve = 1 }

local structures = {}

local function add(id, seg, kind, shapes, props)
	local s = { id = id, seg = seg, kind = kind, shapes = shapes }
	for key, value in pairs(props or {}) do
		s[key] = value
	end
	structures[#structures + 1] = s
	return s
end

-- A left and a right structure: torso, neck and head shapes are mirrored (y), limb
-- shapes are the same (their y is medial on both sides). The cavity "chest" becomes
-- chest_l and chest_r.
local function pair(id, seg, kind, shapes, props)
	local limb = seg ~= "torso" and seg ~= "neck" and seg ~= "head"
	for _, side in ipairs({ "l", "r" }) do
		local list = {}
		for i, shape in ipairs(shapes) do
			local copy = { capsule = shape.capsule }
			for k = 1, 7 do
				copy[k] = shape[k]
			end
			if side == "r" and not limb then
				copy[2], copy[5] = -copy[2], -copy[5]
			end
			list[i] = copy
		end
		local copyProps = {}
		for key, value in pairs(props or {}) do
			copyProps[key] = value
		end
		if copyProps.cavity == "chest" then
			copyProps.cavity = "chest_" .. side
		end
		if copyProps.region == "arm" or copyProps.region == "leg" then
			copyProps.region = copyProps.region .. "_" .. side
		end
		copyProps.side = side
		add(id .. "_" .. side, limb and seg .. "_" .. side or seg, kind, list, copyProps)
	end
end

-- Torso: chest, abdomen and pelvis.
add("torso_soft", "torso", "soft", {
	capsule(0.25, 1.75, 1.5, 0.25, 1.75, 19, 4.75), capsule(0.25, -1.75, 1.5, 0.25, -1.75, 19, 4.75),
}, { bleed = 40 })
add("ribcage", "torso", "bone", {
	capsule(0.2, 1.4, 12.5, 0.2, 1.4, 19, 4.2), capsule(0.2, -1.4, 12.5, 0.2, -1.4, 19, 4.2),
}, { shell = 0.8, coverage = 0.65, hp = 25, density = 4, bleed = 40, cavity = "chest", pain = 0.35,
	region = "chest" })
add("sternum", "torso", "bone", { capsule(4, 0, 13.5, 4, 0, 21, 0.5) }, { hp = 60, density = 4, prio = 25,
	bleed = 20, pain = 0.35, region = "chest" })
pair("clavicle", "torso", "bone", { capsule(3.6, 0.8, 21.8, 1.2, 6, 22.3, 0.45) }, { hp = 40, prio = 25,
	bleed = 20, pain = 0.35, region = "chest" })
pair("scapula", "torso", "bone", { capsule(-3.4, 2.5, 16.5, -3, 4.5, 21, 0.6) }, { hp = 60, prio = 25,
	bleed = 30, pain = 0.3, region = "chest" })
add("spine", "torso", "bone", { capsule(-2, 0, -0.5, -2, 0, 23.5, 1.1) }, { hp = 80, density = 4, prio = 22,
	bleed = 50, pain = 0.5 })
add("cord_thoracic", "torso", "nerve", { capsule(-2.5, 0, 12, -2.6, 0, 23.5, 0.35) }, { cord = 2,
	region = "chest" })
add("cord_lumbar", "torso", "nerve", { capsule(-2.4, 0, 6, -2.5, 0, 12, 0.35) }, { cord = 1, region = "abdomen" })
add("heart", "torso", "organ", { sphere(2, 0.8, 16.8, 1.8) }, { hp = 50, fragility = 1.2, bleed = 1500,
	cavity = "pericardium", cavitation = 1, region = "chest" })
pair("lung", "torso", "organ", { capsule(0.2, 2.6, 13.5, 0.2, 2.4, 20, 2) }, { hp = 200, fragility = 0.5,
	bleed = 150, cavity = "chest", density = 0.3, region = "chest" })
add("aorta", "torso", "vessel", {
	capsule(1.6, 0.3, 17.5, 0.6, 0.5, 20.6, 0.55), capsule(0, 0.7, 20.4, -0.6, 0.6, 12, 0.5),
}, { bleed = 6000, cavity = "chest_l", arterial = true, region = "chest" })
add("aorta_abdominal", "torso", "vessel", { capsule(-0.6, 0.6, 12, -0.6, 0.5, 6.2, 0.5) }, { bleed = 5000,
	cavity = "abdomen", arterial = true, region = "abdomen" })
add("vena_cava", "torso", "vessel", {
	capsule(0.4, -0.9, 6, 1, -0.8, 15.5, 0.55), capsule(1.2, -0.7, 17.5, 0.9, -0.7, 21, 0.45),
}, { bleed = 2500, cavity = "abdomen", region = "abdomen" })
pair("subclavian", "torso", "vessel", { capsule(0.6, 1.2, 20.8, 0.8, 6, 20.2, 0.3) }, { bleed = 900,
	cavity = "external", arterial = true, junctional = true, region = "chest" })
add("liver", "torso", "organ", { capsule(1.2, -3, 11.8, 1.6, 0.8, 12.6, 2.2) }, { hp = 60, fragility = 2,
	bleed = 450, cavity = "abdomen", cavitation = 1, region = "abdomen" })
add("spleen", "torso", "organ", { sphere(-1.2, 3.7, 12, 1.2) }, { hp = 30, fragility = 2, bleed = 450,
	cavity = "abdomen", cavitation = 1, region = "abdomen" })
add("stomach", "torso", "organ", { sphere(2.2, 2.2, 11.5, 1.6) }, { hp = 80, fragility = 0.8, bleed = 60,
	cavity = "abdomen", region = "abdomen" })
pair("kidney", "torso", "organ", { capsule(-1.8, 2.5, 7.7, -1.8, 2.4, 10.5, 1) }, { hp = 40, fragility = 1.5,
	bleed = 300, cavity = "abdomen", cavitation = 1, region = "abdomen" })
add("bowel", "torso", "organ", {
	capsule(2, -3, 6, 2, 3, 6, 2.4), capsule(1.8, -2.8, 2.2, 1.8, 2.8, 2.2, 2),
}, { hp = 150, fragility = 0.6, bleed = 100, cavity = "abdomen", region = "abdomen" })
add("bladder", "torso", "organ", { sphere(2.6, 0, 0, 1.1) }, { hp = 60, bleed = 40, cavity = "abdomen",
	region = "pelvis" })
pair("iliac", "torso", "vessel", { capsule(-0.2, 0.6, 6, 2, 3.2, -0.8, 0.32) }, { bleed = 1500, cavity = "abdomen",
	arterial = true, region = "pelvis" })
add("pelvis", "torso", "bone", {
	capsule(-0.6, 3.8, 1, -0.2, 4.2, 4.4, 1), capsule(-0.6, -3.8, 1, -0.2, -4.2, 4.4, 1),
	capsule(-2.6, 0, -0.5, -2.4, 0, 3.2, 1.1), capsule(2.6, -2.2, -1.4, 2.6, 2.2, -1.4, 0.6),
}, { hp = 120, density = 4, bleed = 350, pain = 0.6, use = { 0.2, 0.45 }, region = "pelvis" })

-- Neck.
add("neck_soft", "neck", "soft", { capsule(0.3, 0, -1, 0.4, 0, 3, 2.2) }, { bleed = 60, region = "neck" })
add("cervical_spine", "neck", "bone", { capsule(-0.9, 0, -1.2, -0.7, 0, 3.2, 0.75) }, { hp = 50, density = 4,
	bleed = 30, pain = 0.5, region = "neck" })
add("cord_cervical_low", "neck", "nerve", { capsule(-1, 0, -1.2, -0.9, 0, 1.4, 0.35) }, { cord = 3,
	region = "neck" })
add("cord_cervical_high", "neck", "nerve", { capsule(-0.9, 0, 1.4, -0.7, 0, 3.4, 0.35) }, { cord = 4,
	region = "neck" })
pair("carotid", "neck", "vessel", { capsule(0.9, 1, -1, 0.9, 1.1, 3.4, 0.28) }, { bleed = 1400, cavity = "external",
	arterial = true, junctional = true, region = "neck" })
pair("jugular", "neck", "vessel", { capsule(0.6, 1.6, -1, 0.5, 1.6, 3.4, 0.35) }, { bleed = 600,
	cavity = "external", junctional = true, region = "neck" })
add("trachea", "neck", "airway", { capsule(1.5, 0, -1.2, 1.4, 0, 2.8, 0.45) }, { hp = 30, region = "neck" })

-- Head.
add("skull", "head", "bone", { capsule(-0.7, 0, 3, 1.7, 0, 3, 2.9) }, { shell = 0.4, hp = 60, density = 5,
	bleed = 30, cavity = "external", pain = 0.4, region = "head" })
add("brain", "head", "organ", { capsule(-0.6, 0, 3, 1.6, 0, 3, 2.45) }, { hp = 40, fragility = 1.5, bleed = 200,
	cavity = "skull", cavitation = 1, region = "head" })
add("brainstem", "head", "nerve", { capsule(-0.3, 0, 0.6, 0, 0, 2.2, 0.45) }, { region = "head" })
add("face", "head", "soft", {
	capsule(2.4, 0.9, -0.6, 2.8, 0.9, 2.4, 1.5), capsule(2.4, -0.9, -0.6, 2.8, -0.9, 2.4, 1.5),
}, { bleed = 80, cavity = "airway", region = "face" })

-- Arms.
pair("upperarm_soft", "upperarm", "soft", { capsule(0, 0, 0, 0, 0, 1, 1.7) }, { bleed = 30, region = "arm" })
pair("humerus", "upperarm", "bone", { capsule(0, 0, 0.05, 0, 0, 0.95, 0.45) }, { hp = 70, bleed = 60, pain = 0.5,
	use = { 0.1, 0.45 }, region = "arm" })
pair("brachial", "upperarm", "vessel", { capsule(0.2, 0.9, 0.1, 0.6, 0.6, 0.95, 0.22) }, { bleed = 450,
	cavity = "external", arterial = true, region = "arm" })
pair("forearm_soft", "forearm", "soft", { capsule(0, 0, 0, 0, 0, 1, 1.25) }, { bleed = 20, region = "arm" })
pair("forearm_bones", "forearm", "bone", { capsule(0, 0, 0.05, 0, 0, 0.95, 0.55) }, { hp = 45, bleed = 30,
	pain = 0.45, use = { 0.15, 0.55 }, region = "arm" })
pair("forearm_arteries", "forearm", "vessel", { capsule(0.6, 0.4, 0.1, 0.7, 0.3, 0.95, 0.2) }, { bleed = 180,
	cavity = "external", arterial = true, region = "arm" })
pair("hand_soft", "hand", "soft", { capsule(0, 0, 0, 0, 0, 1, 1) }, { bleed = 15, region = "arm" })
pair("hand_bones", "hand", "bone", { capsule(0, 0, 0.1, 0, 0, 0.9, 0.6) }, { hp = 30, bleed = 10, pain = 0.3,
	use = { 0.35, 0.65 }, region = "arm" })

-- Legs.
pair("thigh_soft", "thigh", "soft", { capsule(0, 0, 0, 0, 0, 0.98, 2.6) }, { bleed = 40, region = "leg" })
pair("femur", "thigh", "bone", { capsule(0, 0, 0.03, 0, 0, 0.96, 0.6) }, { hp = 160, bleed = 150, pain = 0.55,
	use = { 0.1, 0.45 }, region = "leg" })
pair("femoral_artery", "thigh", "vessel", { capsule(0.9, 1, 0.03, 0.3, 0.6, 0.75, 0.28) }, { bleed = 1000,
	cavity = "external", arterial = true, region = "leg" })
pair("femoral_vein", "thigh", "vessel", { capsule(0.6, 1.3, 0.03, 0.1, 0.9, 0.75, 0.3) }, { bleed = 400,
	cavity = "external", region = "leg" })
pair("popliteal", "thigh", "vessel", { capsule(-0.6, 0.2, 0.75, -0.8, 0, 1, 0.25) }, { bleed = 600,
	cavity = "external", arterial = true, region = "leg" })
pair("calf_soft", "calf", "soft", { capsule(0, 0, 0, 0, 0, 0.97, 1.7) }, { bleed = 25, region = "leg" })
pair("tibia", "calf", "bone", { capsule(0.5, 0.2, 0.03, 0.5, 0.2, 0.95, 0.55) }, { hp = 110, bleed = 50,
	pain = 0.5, use = { 0.15, 0.5 }, region = "leg" })
pair("tibial_arteries", "calf", "vessel", { capsule(-0.2, 0.3, 0.05, 0.1, 0.3, 0.95, 0.2) }, { bleed = 200,
	cavity = "external", arterial = true, region = "leg" })
pair("foot_soft", "foot", "soft", { capsule(0, 0, 0, 0, 0, 1, 1.1) }, { bleed = 15, region = "leg" })
pair("foot_bones", "foot", "bone", { capsule(0, 0, 0.05, 0, 0, 0.95, 0.6) }, { hp = 50, bleed = 10, pain = 0.35,
	use = { 0.4, 0.7 }, region = "leg" })

-- Segments: how frames are built. Limbs go from one joint to the next (hands extend
-- along the forearm); side 1 is left, -1 right.
local segments = {
	{ id = "torso", type = "torso" },
	{ id = "neck", type = "neck" },
	{ id = "head", type = "head" },
}
for _, side in ipairs({ { "l", "L", 1 }, { "r", "R", -1 } }) do
	local s, B, sign = side[1], side[2], side[3]
	local limb = {
		{ "upperarm", "upperarm" .. B, "forearm" .. B, "arm" }, { "forearm", "forearm" .. B, "hand" .. B, "arm" },
		{ "hand", "hand" .. B, nil, "arm", "forearm" .. B, 3.2 }, { "thigh", "thigh" .. B, "calf" .. B, "leg" },
		{ "calf", "calf" .. B, "foot" .. B, "leg" }, { "foot", "foot" .. B, "toe" .. B, "leg" },
	}
	for _, def in ipairs(limb) do
		segments[#segments + 1] = { id = def[1] .. "_" .. s, type = "limb", from = def[2], to = def[3], side = sign,
			limb = def[4] .. "_" .. s, back = def[5], extend = def[6] }
	end
end

M.BODY = { segments = segments, structures = structures }

-- Prepares a body schema for tracing: indexes, priorities, densities, frames per
-- segment and scratch fields for the world shapes. Returns the body.
function M:CompileBody(body)
	local bySeg, byId = {}, {}
	for i, seg in ipairs(body.segments) do
		seg.index = i
		seg.frame = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
		bySeg[seg.id] = seg
	end
	for i, s in ipairs(body.structures) do
		assert(byId[s.id] == nil, "organism: duplicate structure " .. tostring(s.id))
		local seg = bySeg[s.seg]
		assert(seg ~= nil, "organism: structure " .. s.id .. " has an unknown segment " .. tostring(s.seg))
		assert(KIND_PRIO[s.kind] ~= nil, "organism: structure " .. s.id .. " has an unknown kind " .. tostring(s.kind))
		s.index = i
		s.segment = seg
		s.prio = s.prio or KIND_PRIO[s.kind]
		s.density = s.density or KIND_DENSITY[s.kind]
		s.fragility = s.fragility or 1
		s.region = s.region or seg.limb or s.seg
		s.limb = seg.limb
		s.base = s.side ~= nil and s.id:sub(1, -3) or s.id -- the id without the side
		s.cavity = s.cavity or (s.kind == "soft" and "external" or "tissue")
		s.iv = {} -- intervals along the current ray: a1, b1, a2, b2, ...
		s.ivn = 0
		for _, shape in ipairs(s.shapes) do
			shape.world = { 0, 0, 0, 0, 0, 0, 0 }
		end
		byId[s.id] = s
	end
	body.byId = byId
	body.bySeg = bySeg
	body.cache = { ply = nil, time = -1 }
	return body
end

-- Frames -----------------------------------------------------------------------------------

local bonePos = {} -- key -> { x, y, z } of the current player
for _, key in ipairs(BONE_KEYS) do
	bonePos[key] = { 0, 0, 0 }
end
local boneIds = {} -- model -> { key -> bone id } or false without the skeleton

-- Yaw of a player in radians.
local function yawOf(ply)
	local _, yaw = ply:GetAngles():Unpack()
	return rad(yaw)
end

local function lookupBones(ply)
	local model = ply:GetModel() or ""
	local ids = boneIds[model]
	if ids == nil then
		ids = {}
		for _, key in ipairs(BONE_KEYS) do
			local id = ply:LookupBone(BONES[key])
			if id == nil then
				ids = false
				break
			end
			ids[key] = id
		end
		boneIds[model] = ids
	end
	return ids
end

-- Reads the bone positions of `ply` into bonePos (the reference skeleton without bones).
local function readBones(ply)
	local ids = lookupBones(ply)
	if ids then
		for i = 1, #BONE_KEYS do
			local key = BONE_KEYS[i]
			local pos = ply:GetBonePosition(ids[key])
			if pos == nil then
				ids = false
				break
			end
			local p = bonePos[key]
			p[1], p[2], p[3] = pos:Unpack()
		end
		if ids then
			-- Bones that were never set up sit at the origin of the entity: keep the
			-- skeleton only if the torso has a sane length.
			local p, n = bonePos.pelvis, bonePos.neck
			local dx, dy, dz = n[1] - p[1], n[2] - p[2], n[3] - p[3]
			local length = dx * dx + dy * dy + dz * dz
			if length >= MIN_TORSO * MIN_TORSO and length <= MAX_TORSO * MAX_TORSO then
				return
			end
		end
	end
	local ox, oy, oz = ply:GetPos():Unpack()
	local yaw = yawOf(ply)
	local c, s = cos(yaw), sin(yaw)
	local crouch = ply:Crouching()
	for i = 1, #BONE_KEYS do
		local key = BONE_KEYS[i]
		local ref, p = REFERENCE[key], bonePos[key]
		local z = ref[3]
		if crouch then
			z = z > 38.5 and z - 20 or z * 0.65
		end
		p[1], p[2], p[3] = ox + ref[1] * c - ref[2] * s, oy + ref[1] * s + ref[2] * c, oz + z
	end
end

local function normalize(x, y, z)
	local length = sqrt(x * x + y * y + z * z)
	if length < EPSILON then
		return 0, 0, 0, 0
	end
	return x / length, y / length, z / length, length
end

-- Removes from (x, y, z) its part along the unit vector (ux, uy, uz) and normalizes.
local function orthogonal(x, y, z, ux, uy, uz)
	local d = x * ux + y * uy + z * uz
	return normalize(x - ux * d, y - uy * d, z - uz * d)
end

local function cross(ax, ay, az, bx, by, bz)
	return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function setFrame(f, ox, oy, oz, xx, xy, xz, yx, yy, yz, zx, zy, zz)
	f[1], f[2], f[3] = ox, oy, oz
	f[4], f[5], f[6] = xx, xy, xz
	f[7], f[8], f[9] = yx, yy, yz
	f[10], f[11], f[12] = zx, zy, zz
end

-- Builds the frames of every segment of `body` for `ply` (cached for the tick).
function M:_Frames(body, ply)
	local cache = body.cache
	local now = CurTime()
	if cache.ply == ply and cache.time == now then
		return cache.scale
	end
	readBones(ply)
	local p, n, h = bonePos.pelvis, bonePos.neck, bonePos.head
	local ux, uy, uz, torso = normalize(n[1] - p[1], n[2] - p[2], n[3] - p[3])
	if torso < EPSILON then
		ux, uy, uz, torso = 0, 0, 1, REF_TORSO
	end
	local scale = torso / REF_TORSO
	local al, ar = bonePos.upperarmL, bonePos.upperarmR
	local lx, ly, lz = orthogonal(al[1] - ar[1], al[2] - ar[2], al[3] - ar[3], ux, uy, uz)
	if lx == 0 and ly == 0 and lz == 0 then
		local yaw = yawOf(ply)
		lx, ly, lz = orthogonal(-sin(yaw), cos(yaw), 0, ux, uy, uz)
	end
	local fx, fy, fz = cross(lx, ly, lz, ux, uy, uz) -- forward = left x up
	local bySeg = body.bySeg
	setFrame(bySeg.torso.frame, p[1], p[2], p[3], fx * scale, fy * scale, fz * scale, lx * scale, ly * scale,
		lz * scale, ux * scale, uy * scale, uz * scale)

	-- Neck: up towards the head, forward of the torso.
	local nx, ny, nz = normalize(h[1] - n[1], h[2] - n[2], h[3] - n[3])
	if nx == 0 and ny == 0 and nz == 0 then
		nx, ny, nz = ux, uy, uz
	end
	local nfx, nfy, nfz = orthogonal(fx, fy, fz, nx, ny, nz)
	local nlx, nly, nlz = cross(nx, ny, nz, nfx, nfy, nfz) -- left = up x forward
	setFrame(bySeg.neck.frame, n[1], n[2], n[3], nfx * scale, nfy * scale, nfz * scale, nlx * scale, nly * scale,
		nlz * scale, nx * scale, ny * scale, nz * scale)

	-- Head: forward where the eyes look (pitch limited), up along the neck.
	local pitch, yaw = ply:EyeAngles():Unpack()
	if pitch > 180 then
		pitch = pitch - 360
	end
	pitch = rad(max(-HEAD_PITCH, min(HEAD_PITCH, pitch)))
	yaw = rad(yaw)
	local hfx, hfy, hfz = cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), -sin(pitch)
	local hux, huy, huz = orthogonal(nx, ny, nz, hfx, hfy, hfz)
	if hux == 0 and huy == 0 and huz == 0 then
		hux, huy, huz = orthogonal(ux, uy, uz, hfx, hfy, hfz)
	end
	local hlx, hly, hlz = cross(hux, huy, huz, hfx, hfy, hfz)
	setFrame(bySeg.head.frame, h[1], h[2], h[3], hfx * scale, hfy * scale, hfz * scale, hlx * scale, hly * scale,
		hlz * scale, hux * scale, huy * scale, huz * scale)

	-- Limbs: z from joint to joint, y medial (towards the other side), x anterior.
	local segs = body.segments
	for i = 1, #segs do
		local seg = segs[i]
		if seg.type == "limb" then
			local a = bonePos[seg.from]
			local zx, zy, zz
			if seg.to ~= nil then
				local b = bonePos[seg.to]
				zx, zy, zz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
			else
				local back = bonePos[seg.back]
				local dx, dy, dz = normalize(a[1] - back[1], a[2] - back[2], a[3] - back[3])
				local length = seg.extend * scale
				zx, zy, zz = dx * length, dy * length, dz * length
			end
			local dx, dy, dz = normalize(zx, zy, zz)
			local sign = seg.side
			local mx, my, mz = orthogonal(-sign * lx, -sign * ly, -sign * lz, dx, dy, dz)
			if mx == 0 and my == 0 and mz == 0 then
				mx, my, mz = orthogonal(fx, fy, fz, dx, dy, dz)
			end
			local ax, ay, az
			if sign > 0 then
				ax, ay, az = cross(mx, my, mz, dx, dy, dz)
			else
				ax, ay, az = cross(dx, dy, dz, mx, my, mz)
			end
			setFrame(seg.frame, a[1], a[2], a[3], ax * scale, ay * scale, az * scale, mx * scale, my * scale,
				mz * scale, zx, zy, zz)
		end
	end

	-- World shapes.
	local list = body.structures
	for i = 1, #list do
		local s = list[i]
		local f = s.segment.frame
		local ox, oy, oz = f[1], f[2], f[3]
		local xx, xy, xz, yx, yy, yz, zx, zy, zz = f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12]
		local shapes = s.shapes
		for k = 1, #shapes do
			local shape = shapes[k]
			local w = shape.world
			local a, b, c = shape[1], shape[2], shape[3]
			w[1], w[2], w[3] = ox + xx * a + yx * b + zx * c, oy + xy * a + yy * b + zy * c, oz + xz * a + yz * b + zz * c
			a, b, c = shape[4], shape[5], shape[6]
			w[4], w[5], w[6] = ox + xx * a + yx * b + zx * c, oy + xy * a + yy * b + zy * c, oz + xz * a + yz * b + zz * c
			w[7] = shape[7] * scale
		end
	end
	cache.ply, cache.time, cache.scale = ply, now, scale
	return scale
end

-- Local coordinates of a world point in the frame of a segment.
function M:_ToLocal(seg, x, y, z)
	local f = seg.frame
	local dx, dy, dz = x - f[1], y - f[2], z - f[3]
	local a = (dx * f[4] + dy * f[5] + dz * f[6]) / (f[4] * f[4] + f[5] * f[5] + f[6] * f[6])
	local b = (dx * f[7] + dy * f[8] + dz * f[9]) / (f[7] * f[7] + f[8] * f[8] + f[9] * f[9])
	local c = (dx * f[10] + dy * f[11] + dz * f[12]) / (f[10] * f[10] + f[11] * f[11] + f[12] * f[12])
	return a, b, c
end

-- Ray tests -----------------------------------------------------------------------------

-- Distance along the ray (o, unit d) to the entry into a sphere; nil if it misses.
local function sphereEntry(ox, oy, oz, dx, dy, dz, cx, cy, cz, r)
	local px, py, pz = ox - cx, oy - cy, oz - cz
	local b = px * dx + py * dy + pz * dz
	local h = b * b - (px * px + py * py + pz * pz - r * r)
	if h < 0 then
		return nil
	end
	return -b - sqrt(h)
end

-- Distance along the ray to the entry into a capsule (segment a-b, radius r); nil if it
-- misses. Negative when the ray starts inside.
local function capsuleEntry(ox, oy, oz, dx, dy, dz, ax, ay, az, bx, by, bz, r)
	local bax, bay, baz = bx - ax, by - ay, bz - az
	local oax, oay, oaz = ox - ax, oy - ay, oz - az
	local baba = bax * bax + bay * bay + baz * baz
	local bard = bax * dx + bay * dy + baz * dz
	local baoa = bax * oax + bay * oay + baz * oaz
	local a = baba - bard * bard
	if a < EPSILON * baba then
		-- Along the axis: the nearer cap.
		local ta = sphereEntry(ox, oy, oz, dx, dy, dz, ax, ay, az, r)
		local tb = sphereEntry(ox, oy, oz, dx, dy, dz, bx, by, bz, r)
		if ta == nil then
			return tb
		end
		if tb == nil or ta < tb then
			return ta
		end
		return tb
	end
	local rdoa = dx * oax + dy * oay + dz * oaz
	local oaoa = oax * oax + oay * oay + oaz * oaz
	local b = baba * rdoa - baoa * bard
	local c = baba * oaoa - baoa * baoa - r * r * baba
	local h = b * b - a * c
	if h < 0 then
		return nil
	end
	local t = (-b - sqrt(h)) / a
	local y = baoa + t * bard
	if y > 0 and y < baba then
		return t
	end
	if y <= 0 then
		return sphereEntry(ox, oy, oz, dx, dy, dz, ax, ay, az, r)
	end
	return sphereEntry(ox, oy, oz, dx, dy, dz, bx, by, bz, r)
end

-- Interval [t0, t1] of the ray inside a shape grown by `grow`; nil if it misses.
local function shapeInterval(shape, ox, oy, oz, dx, dy, dz, grow)
	local w = shape.world
	local r = w[7] + grow
	if r <= 0 then
		return nil
	end
	if not shape.capsule then
		local px, py, pz = ox - w[1], oy - w[2], oz - w[3]
		local b = px * dx + py * dy + pz * dz
		local h = b * b - (px * px + py * py + pz * pz - r * r)
		if h < 0 then
			return nil
		end
		h = sqrt(h)
		return -b - h, -b + h
	end
	local t0 = capsuleEntry(ox, oy, oz, dx, dy, dz, w[1], w[2], w[3], w[4], w[5], w[6], r)
	if t0 == nil then
		return nil
	end
	local back = capsuleEntry(ox + dx * FAR, oy + dy * FAR, oz + dz * FAR, -dx, -dy, -dz, w[1], w[2], w[3], w[4], w[5],
		w[6], r)
	if back == nil then
		return nil
	end
	return t0, FAR - back
end

-- Adds [a, b] to the sorted, disjoint intervals of `s` (merging overlaps).
local function addInterval(s, a, b)
	local iv, n = s.iv, s.ivn
	local i = 1
	while i <= n do
		local ia, ib = iv[2 * i - 1], iv[2 * i]
		if b < ia then
			break
		end
		if a <= ib then
			-- Overlap: merge into [a, b] and drop the old one.
			if ia < a then
				a = ia
			end
			if ib > b then
				b = ib
			end
			for k = i, n - 1 do
				iv[2 * k - 1], iv[2 * k] = iv[2 * k + 1], iv[2 * k + 2]
			end
			n = n - 1
		else
			i = i + 1
		end
	end
	for k = n, i, -1 do
		iv[2 * k + 1], iv[2 * k + 2] = iv[2 * k - 1], iv[2 * k]
	end
	iv[2 * i - 1], iv[2 * i] = a, b
	s.ivn = n + 1
end

-- Removes [a, b] from the intervals of `s`.
local function cutInterval(s, a, b)
	local iv, n = s.iv, s.ivn
	local out = s.cut or {}
	s.cut = out
	local m = 0
	for i = 1, n do
		local ia, ib = iv[2 * i - 1], iv[2 * i]
		if b <= ia or a >= ib then
			out[2 * m + 1], out[2 * m + 2] = ia, ib
			m = m + 1
		else
			if ia < a then
				out[2 * m + 1], out[2 * m + 2] = ia, a
				m = m + 1
			end
			if ib > b then
				out[2 * m + 1], out[2 * m + 2] = b, ib
				m = m + 1
			end
		end
	end
	for i = 1, 2 * m do
		iv[i] = out[i]
	end
	s.ivn = m
end

local hits = {}     -- structures the current ray touches
local cuts = {}     -- boundaries of their intervals
local inner = { iv = {}, ivn = 0 }

-- Intervals of every structure along the ray; vessels and nerves are grown by `grow`.
local function castStructures(body, ox, oy, oz, dx, dy, dz, grow)
	local list = body.structures
	local count = 0
	for i = 1, #list do
		local s = list[i]
		s.ivn = 0
		local g = (s.kind == "vessel" or s.kind == "nerve") and grow or 0
		local shapes = s.shapes
		for k = 1, #shapes do
			local t0, t1 = shapeInterval(shapes[k], ox, oy, oz, dx, dy, dz, g)
			if t0 ~= nil and t1 > 0 and t1 > t0 then
				addInterval(s, max(t0, 0), t1)
			end
		end
		if s.ivn > 0 and s.shell ~= nil then
			-- Hollow: remove the inside, then keep each crossing of the wall by coverage.
			inner.ivn = 0
			for k = 1, #shapes do
				local shape = shapes[k]
				local t0, t1 = shapeInterval(shape, ox, oy, oz, dx, dy, dz, -s.shell * (shape.world[7] / shape[7]))
				if t0 ~= nil and t1 > 0 and t1 > t0 then
					addInterval(inner, max(t0, 0), t1)
				end
			end
			for k = 1, inner.ivn do
				cutInterval(s, inner.iv[2 * k - 1], inner.iv[2 * k])
			end
			if s.coverage ~= nil then
				local iv, kept = s.iv, 0
				for k = 1, s.ivn do
					if M.Random() < s.coverage then
						kept = kept + 1
						iv[2 * kept - 1], iv[2 * kept] = iv[2 * k - 1], iv[2 * k]
					end
				end
				s.ivn = kept
			end
		end
		if s.ivn > 0 then
			count = count + 1
			hits[count] = s
		end
	end
	for i = count + 1, #hits do
		hits[i] = nil
	end
	return count
end

local function inside(s, t)
	local iv = s.iv
	for k = 1, s.ivn do
		if t >= iv[2 * k - 1] and t <= iv[2 * k] then
			return true
		end
	end
	return false
end

-- The trace of the last cast, reused by every cast: passes in order along the ray.
local trace = { n = 0, structure = {}, t0 = {}, t1 = {}, ox = 0, oy = 0, oz = 0, dx = 0, dy = 0, dz = 1 }
M.trace = trace

-- Casts a ray from (ox, oy, oz) along the unit (dx, dy, dz) through the body of `ply`:
-- fills M.trace with the passes (structure, t0, t1 in units along the ray), the
-- structure with the highest priority on each piece. Vessels and nerves are grown by
-- `grow` units (the projectile and its cavity). Returns the number of passes.
function M:Cast(ply, ox, oy, oz, dx, dy, dz, grow)
	local body = self.body
	self:_Frames(body, ply)
	trace.ox, trace.oy, trace.oz, trace.dx, trace.dy, trace.dz = ox, oy, oz, dx, dy, dz
	local count = castStructures(body, ox, oy, oz, dx, dy, dz, grow or 0)
	local nc = 0
	for i = 1, count do
		local s = hits[i]
		local iv = s.iv
		for k = 1, 2 * s.ivn do
			nc = nc + 1
			cuts[nc] = iv[k]
		end
	end
	for i = nc + 1, #cuts do
		cuts[i] = nil
	end
	sort(cuts)
	local n = 0
	local passS, passA, passB = trace.structure, trace.t0, trace.t1
	for i = 1, nc - 1 do
		local a, b = cuts[i], cuts[i + 1]
		if b - a > EPSILON then
			local mid = (a + b) * 0.5
			local best, bestPrio = nil, -1
			for k = 1, count do
				local s = hits[k]
				if s.prio > bestPrio and inside(s, mid) then
					best, bestPrio = s, s.prio
				end
			end
			if best ~= nil then
				if n > 0 and passS[n] == best and passB[n] >= a - EPSILON then
					passB[n] = b
				else
					n = n + 1
					passS[n], passA[n], passB[n] = best, a, b
				end
			end
		end
	end
	for i = n + 1, #passS do
		passS[i], passA[i], passB[i] = nil, nil, nil
	end
	trace.n = n
	return n
end

-- Where a ray enters the body: the first structure, its segment and region and the side
-- of the body (front, back, left, right; for limbs nil), or nil if the ray misses.
-- Leaves the passes in M.trace.
function M:Locate(ply, ox, oy, oz, dx, dy, dz, grow)
	local n = self:Cast(ply, ox, oy, oz, dx, dy, dz, grow)
	if n == 0 then
		return nil
	end
	local s = trace.structure[1]
	local t = trace.t0[1]
	local x, y, z = ox + dx * t, oy + dy * t, oz + dz * t
	return s, self:_Region(s, x, y, z)
end

-- Region and side of a point in structure `s` (torso regions by height).
function M:_Region(s, x, y, z)
	local seg = s.segment
	if seg.type == "limb" then
		return s.region, nil, nil
	end
	local f, l, u = self:_ToLocal(seg, x, y, z)
	local region = s.region
	if seg.id == "torso" and s.kind == "soft" then
		region = u >= 11.5 and "chest" or (u >= 3.5 and "abdomen" or "pelvis")
	end
	local side
	if seg.id == "head" and region == "head" and u < 1.2 and f > 1.2 then
		region = "face"
	end
	f = f - (seg.id == "torso" and 0.25 or 0)
	if f >= 0 and f * f >= l * l * 0.5 then
		side = "front"
	elseif f < 0 and f * f >= l * l * 0.5 then
		side = "back"
	else
		side = l > 0 and "left" or "right"
	end
	return region, side, u
end

-- Distance from (x, y, z) to the surface of structure `s` (negative inside), using the
-- current frames.
function M:_Distance(s, x, y, z)
	local best = math.huge
	local shapes = s.shapes
	for k = 1, #shapes do
		local w = shapes[k].world
		local ax, ay, az = w[1], w[2], w[3]
		local bx, by, bz = w[4] - ax, w[5] - ay, w[6] - az
		local px, py, pz = x - ax, y - ay, z - az
		local bb = bx * bx + by * by + bz * bz
		local t = 0
		if bb > EPSILON then
			t = (px * bx + py * by + pz * bz) / bb
			t = t < 0 and 0 or (t > 1 and 1 or t)
		end
		local qx, qy, qz = px - bx * t, py - by * t, pz - bz * t
		local d = sqrt(qx * qx + qy * qy + qz * qz) - w[7]
		if d < best then
			best = d
		end
	end
	return best
end

-- Distance between the path segment p-q and the axis of structure `s` minus its radius
-- (how far an organ is from the track of a projectile).
function M:_PathDistance(s, px, py, pz, qx, qy, qz)
	local best = math.huge
	local ux, uy, uz = qx - px, qy - py, qz - pz
	local shapes = s.shapes
	for k = 1, #shapes do
		local w = shapes[k].world
		local vx, vy, vz = w[4] - w[1], w[5] - w[2], w[6] - w[3]
		local wx, wy, wz = px - w[1], py - w[2], pz - w[3]
		local a = ux * ux + uy * uy + uz * uz
		local b = ux * vx + uy * vy + uz * vz
		local c = vx * vx + vy * vy + vz * vz
		local d = ux * wx + uy * wy + uz * wz
		local e = vx * wx + vy * wy + vz * wz
		local denom = a * c - b * b
		local sc, tc
		if denom < EPSILON then
			sc = 0
			tc = c > EPSILON and e / c or 0
		else
			sc = (b * e - c * d) / denom
			tc = (a * e - b * d) / denom
		end
		sc = sc < 0 and 0 or (sc > 1 and 1 or sc)
		tc = tc < 0 and 0 or (tc > 1 and 1 or tc)
		local dx = wx + ux * sc - vx * tc
		local dy = wy + uy * sc - vy * tc
		local dz = wz + uz * sc - vz * tc
		local dist = sqrt(dx * dx + dy * dy + dz * dz) - w[7]
		if dist < best then
			best = dist
		end
	end
	return best
end

-- Structures of a segment, in schema order (built on first use).
function M:SegmentStructures(segId)
	local body = self.body
	body.segmentLists = body.segmentLists or {}
	local list = body.segmentLists[segId]
	if list == nil then
		list = {}
		for _, s in ipairs(body.structures) do
			if s.seg == segId then
				list[#list + 1] = s
			end
		end
		body.segmentLists[segId] = list
	end
	return list
end

-- The segment nearest to a world point and the distance to its surface (frames of
-- `ply`, built if needed).
function M:NearestSegment(ply, x, y, z)
	local body = self.body
	self:_Frames(body, ply)
	local bestSeg, best = nil, math.huge
	for _, s in ipairs(body.structures) do
		if s.kind == "soft" or s.id == "skull" then
			local d = self:_Distance(s, x, y, z)
			if d < best then
				bestSeg, best = s.segment, d
			end
		end
	end
	return bestSeg, best
end

-- Whether a player has a usable body for tracing.
function M:CanTrace(ply)
	return IsValid(ply) and ply:IsPlayer()
end
