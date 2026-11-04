-- Geometry of an emulated world for traces (tests/gmod/env.lua: Env.Geometry).
--
-- With geometry, util.TraceLine, util.TraceHull and util.PointContents of a realm see:
--   boxes      geometry:Box(mins, maxs, opts), parts of the map; opts: mat (MAT_*, default
--              MAT_CONCRETE), contents (CONTENTS_*, default CONTENTS_SOLID), sky (HitSky),
--              surface (SurfaceProps), displacement (DispFlags 1: the ground)
--   props      entities with ent.box = { mins, maxs } around their position, ent.mat and
--              ent.contents (default CONTENTS_SOLID)
--   players    living solid players: hitboxes around the bones of their skeleton for rays
--              with CONTENTS_HITBOX in the mask, otherwise their hull (CONTENTS_MONSTER)
--   ragdolls   a box around every physics object (PhysicsBone)
-- Like the engine: masks pick what a trace sees, the filter (an entity, a list or a
-- function that answers true to hit) skips entities, a trace that starts inside a box is
-- StartSolid and that box does not stop it (FractionLeftSolid: where it leaves the box),
-- one that never leaves it is AllSolid; hulls grow every box by their extents and see
-- the hull of players, not hitboxes. trace.output gets the result when it is given.
-- geometry.traces counts the traces.

local Geometry = {}
Geometry.__index = Geometry

local band = bit.band
local bor = bit.bor
local huge = math.huge
local World, Vector, H

-- The world of the emulator (tests/gmod/world.lua) the geometry belongs to.
function Geometry.Bind(world)
	World, Vector, H = world, world.Vector, world.HITGROUP
	Geometry._Hitboxes()
	return Geometry
end

Geometry.CONTENTS = {
	EMPTY = 0, SOLID = 1, WINDOW = 2, GRATE = 8, SLIME = 16, WATER = 32, MOVEABLE = 16384, PLAYERCLIP = 65536,
	MONSTER = 33554432, DEBRIS = 67108864, HITBOX = 1073741824,
}
local C = Geometry.CONTENTS
Geometry.MASK = {
	SOLID = 33570827, SHOT = 1174421507, SHOT_HULL = 100679691, PLAYERSOLID = 33636363, WATER = 16432,
	SOLID_BRUSHONLY = 16395, OPAQUE = 16513, VISIBLE = 24705,
}
Geometry.MAT = {
	ANTLION = 65, BLOODYFLESH = 66, CONCRETE = 67, DIRT = 68, EGGSHELL = 69, FLESH = 70, GRATE = 71,
	ALIENFLESH = 72, CLIP = 73, SNOW = 74, PLASTIC = 76, METAL = 77, SAND = 78, FOLIAGE = 79, COMPUTER = 80,
	SLOSH = 83, TILE = 84, GRASS = 85, VENT = 86, WOOD = 87, DEFAULT = 88, GLASS = 89, WARPSHIELD = 90,
}

local B = "ValveBiped.Bip01_"
-- Hitboxes of a player: the bones they span and how far they reach past them (local).
function Geometry._Hitboxes()
	Geometry.HITBOXES = {
		{ group = H.HEAD, bones = { "Head1" }, pad = { 4.5, 4, 5.5 } },
		{ group = H.CHEST, bones = { "Spine2", "Spine4" }, pad = { 6, 7, 3.5 } },
		{ group = H.STOMACH, bones = { "Pelvis", "Spine", "Spine1" }, pad = { 5.5, 7, 1 } },
		{ group = H.LEFTARM, bones = { "L_UpperArm", "L_Forearm", "L_Hand" }, pad = { 2.5, 1.5, 2 } },
		{ group = H.RIGHTARM, bones = { "R_UpperArm", "R_Forearm", "R_Hand" }, pad = { 2.5, 1.5, 2 } },
		{ group = H.LEFTLEG, bones = { "L_Thigh", "L_Calf", "L_Foot", "L_Toe0" }, pad = { 3, 3, 1 } },
		{ group = H.RIGHTLEG, bones = { "R_Thigh", "R_Calf", "R_Foot", "R_Toe0" }, pad = { 3, 3, 1 } },
	}
end
-- Half sizes of the boxes around the physics objects of a ragdoll.
local RAGDOLL_HALF = { [B .. "Pelvis"] = 6, [B .. "Spine2"] = 7, [B .. "Head1"] = 4.5 }
local RAGDOLL_LIMB = 3

function Geometry.New(env)
	return setmetatable({ env = env, boxes = {}, traces = 0 }, Geometry)
end

-- A part of the map from `mins` to `maxs` (see the top of the file).
function Geometry:Box(mins, maxs, opts)
	opts = opts or {}
	local box = { mins = Vector(mins), maxs = Vector(maxs), mat = opts.mat or Geometry.MAT.CONCRETE,
		contents = opts.contents or C.SOLID, sky = opts.sky == true, surface = opts.surface or 0,
		displacement = opts.displacement == true }
	self.boxes[#self.boxes + 1] = box
	return box
end

-- A wall across x from `x` to `x + thickness` (units), wide and high.
function Geometry:Wall(x, thickness, mat, opts)
	opts = opts or {}
	opts.mat = mat
	return self:Box(Vector(x, -1000, -1000), Vector(x + thickness, 1000, 1000), opts)
end

-- The slab test of the segment o + d*t, t in [0, 1], against a box: the entry and exit
-- fractions and the axis and sign of the face it enters.
local function slab(ox, oy, oz, dx, dy, dz, x0, y0, z0, x1, y1, z1)
	local tmin, tmax = -huge, huge
	local axis, sign = 0, 0
	local o = { ox, oy, oz }
	local d = { dx, dy, dz }
	local lo = { x0, y0, z0 }
	local hi = { x1, y1, z1 }
	for i = 1, 3 do
		if d[i] == 0 then
			if o[i] < lo[i] or o[i] > hi[i] then
				return nil
			end
		else
			local t0 = (lo[i] - o[i]) / d[i]
			local t1 = (hi[i] - o[i]) / d[i]
			local s = -1
			if t0 > t1 then
				t0, t1 = t1, t0
				s = 1
			end
			if t0 > tmin then
				tmin, axis, sign = t0, i, s
			end
			if t1 < tmax then
				tmax = t1
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin, tmax, axis, sign
end

local function inside(x, y, z, x0, y0, z0, x1, y1, z1)
	return x > x0 and x < x1 and y > y0 and y < y1 and z > z0 and z < z1
end

local function filtered(filter, ent)
	if filter == nil then
		return false
	end
	if type(filter) == "function" then
		return filter(ent) ~= true
	end
	if filter == ent then
		return true
	end
	if type(filter) == "table" and getmetatable(filter) == nil then
		for _, item in ipairs(filter) do
			if item == ent then
				return true
			end
		end
	end
	return false
end

-- Local positions of the bones of `ply` (as GetBonePosition, before the yaw and position).
local function localBone(ply, short)
	local name = B .. short
	local rel = ply.bones[name] or World.SKELETON[name]
	local z = rel.z
	if ply.crouching then
		z = z > 38.5 and z - 20 or z * 0.65
	end
	return rel.x, rel.y, z
end

-- Candidate shapes of the realm for a trace with `mask` (and a hull for TraceHull).
function Geometry:_Shapes(mask, hull, ignoreWorld)
	local shapes = {}
	if not ignoreWorld then
		for _, box in ipairs(self.boxes) do
			if band(box.contents, mask) ~= 0 then
				shapes[#shapes + 1] = { box.mins, box.maxs, ent = World.WORLD, mat = box.mat, contents = box.contents,
					sky = box.sky, surface = box.surface, world = true, displacement = box.displacement }
			end
		end
	end
	local list = {}
	for _, ent in pairs(self.env.entities) do
		list[#list + 1] = ent
	end
	table.sort(list, function(a, b) return a:EntIndex() < b:EntIndex() end)
	for _, ent in ipairs(list) do
		if ent:IsValid() then
			if ent:IsPlayer() then
				if ent:Alive() and ent:IsSolid() and band(mask, bor(C.HITBOX, C.MONSTER)) ~= 0 then
					shapes[#shapes + 1] = { player = ent, hitboxes = band(mask, C.HITBOX) ~= 0 and not hull }
				end
			elseif ent.phys ~= nil and ent.phys[0] ~= nil then
				if band(mask, C.SOLID) ~= 0 then
					for i = 0, #World.PHYS_BONES - 1 do
						local phys = ent.phys[i]
						local half = RAGDOLL_HALF[phys.bone] or RAGDOLL_LIMB
						local p = phys.pos
						shapes[#shapes + 1] = { Vector(p.x - half, p.y - half, p.z - half),
							Vector(p.x + half, p.y + half, p.z + half), ent = ent, mat = Geometry.MAT.FLESH,
							contents = C.SOLID, bone = i }
					end
				end
			elseif ent.box ~= nil then
				local contents = ent.contents or C.SOLID
				if band(contents, mask) ~= 0 then
					local p = ent:GetPos()
					shapes[#shapes + 1] = { p + ent.box[1], p + ent.box[2], ent = ent, mat = ent.mat or Geometry.MAT.DEFAULT,
						contents = contents }
				end
			end
		end
	end
	return shapes
end

local function result(start, endpos, out)
	out = out or {}
	for key in pairs(out) do
		out[key] = nil
	end
	out.Hit, out.HitWorld, out.HitNonWorld, out.HitSky, out.HitNoDraw = false, false, false, false, false
	out.StartSolid, out.AllSolid = false, false
	out.Fraction, out.FractionLeftSolid = 1, 0
	out.StartPos, out.HitPos = Vector(start), Vector(endpos)
	out.HitNormal = Vector(0, 0, 0)
	out.Normal = (endpos - start):GetNormalized()
	out.Entity = World.NULL
	out.MatType, out.SurfaceProps, out.HitGroup, out.HitBox, out.PhysicsBone, out.Contents = 0, 0, 0, 0, 0, 0
	out.HitTexture = "**empty**"
	out.DispFlags = 0
	return out
end

-- The nearest hit of the segment on the hitboxes (or the hull) of a player.
local function playerHit(shape, ox, oy, oz, dx, dy, dz, hmins, hmaxs)
	local ply = shape.player
	local pos = ply.pos
	local yaw = math.rad(ply.angles.y)
	local c, s = math.cos(yaw), math.sin(yaw)
	-- The segment in the frame of the player.
	local rx, ry, rz = ox - pos.x, oy - pos.y, oz - pos.z
	local lx, ly, lz = rx * c + ry * s, -rx * s + ry * c, rz
	local ldx, ldy, ldz = dx * c + dy * s, -dx * s + dy * c, dz
	local best, bestAxis, bestSign, bestGroup
	if shape.hitboxes then
		for _, hitbox in ipairs(Geometry.HITBOXES) do
			local x0, y0, z0, x1, y1, z1 = huge, huge, huge, -huge, -huge, -huge
			for _, bone in ipairs(hitbox.bones) do
				local bx, by, bz = localBone(ply, bone)
				x0, y0, z0 = math.min(x0, bx), math.min(y0, by), math.min(z0, bz)
				x1, y1, z1 = math.max(x1, bx), math.max(y1, by), math.max(z1, bz)
			end
			local p = hitbox.pad
			local t, _, axis, sign = slab(lx, ly, lz, ldx, ldy, ldz, x0 - p[1], y0 - p[2], z0 - p[3], x1 + p[1],
				y1 + p[2], z1 + p[3])
			if t ~= nil and t >= 0 and t <= 1 and (best == nil or t < best) then
				best, bestAxis, bestSign, bestGroup = t, axis, sign, hitbox.group
			end
		end
	else
		local mins, maxs = ply:GetHull()
		if ply.crouching then
			mins, maxs = ply:GetHullDuck()
		end
		local t, _, axis, sign = slab(rx, ry, rz, dx, dy, dz, mins.x - hmaxs.x, mins.y - hmaxs.y, mins.z - hmaxs.z,
			maxs.x - hmins.x, maxs.y - hmins.y, maxs.z - hmins.z)
		if t ~= nil and t >= 0 and t <= 1 then
			local n = { 0, 0, 0 }
			n[axis] = sign
			return t, Vector(n[1], n[2], n[3]), H.GENERIC
		end
		return nil
	end
	if best == nil then
		return nil
	end
	local n = { 0, 0, 0 }
	n[bestAxis] = bestSign
	-- The normal back in the world.
	return best, Vector(n[1] * c - n[2] * s, n[1] * s + n[2] * c, n[3]), bestGroup
end

-- util.TraceLine and util.TraceHull (with trace.mins and trace.maxs).
function Geometry:Trace(trace, hull)
	self.traces = self.traces + 1
	local start, endpos = trace.start, trace.endpos
	local out = result(start, endpos, trace.output)
	local mask = trace.mask or Geometry.MASK.SOLID
	local hmins = hull and trace.mins or Vector(0, 0, 0)
	local hmaxs = hull and trace.maxs or Vector(0, 0, 0)
	local ox, oy, oz = start.x, start.y, start.z
	local dx, dy, dz = endpos.x - ox, endpos.y - oy, endpos.z - oz
	local best, bestShape, bestNormal, bestGroup
	local leave = 0
	for _, shape in ipairs(self:_Shapes(mask, hull, trace.ignoreworld)) do
		local ent = shape.ent or shape.player
		if shape.world or not filtered(trace.filter, ent) then
			if shape.player ~= nil then
				local t, normal, group = playerHit(shape, ox, oy, oz, dx, dy, dz, hmins, hmaxs)
				if t ~= nil and (best == nil or t < best) then
					best, bestShape, bestNormal, bestGroup = t, shape, normal, group
				end
			else
				local mn, mx = shape[1], shape[2]
				local x0, y0, z0 = mn.x - hmaxs.x, mn.y - hmaxs.y, mn.z - hmaxs.z
				local x1, y1, z1 = mx.x - hmins.x, mx.y - hmins.y, mx.z - hmins.z
				if inside(ox, oy, oz, x0, y0, z0, x1, y1, z1) then
					out.StartSolid = true
					local _, t1 = slab(ox, oy, oz, dx, dy, dz, x0, y0, z0, x1, y1, z1)
					t1 = t1 or 0
					if t1 >= 1 or (dx == 0 and dy == 0 and dz == 0) then
						out.AllSolid = true
						out.Hit, out.Fraction, out.FractionLeftSolid = true, 0, 1
						out.HitPos = Vector(start)
						out.Entity = ent
						out.HitWorld = shape.world == true
						out.HitNonWorld = not shape.world
						out.MatType, out.Contents = shape.mat, shape.contents
						return out
					end
					if t1 > leave then
						leave = t1
					end
				else
					local t, _, axis, sign = slab(ox, oy, oz, dx, dy, dz, x0, y0, z0, x1, y1, z1)
					if t ~= nil and t >= 0 and t <= 1 and (best == nil or t < best) then
						local n = { 0, 0, 0 }
						n[axis] = sign
						best, bestShape, bestNormal, bestGroup = t, shape, Vector(n[1], n[2], n[3]), H.GENERIC
					end
				end
			end
		end
	end
	out.FractionLeftSolid = leave
	if best == nil then
		return out
	end
	out.Hit = true
	out.Fraction = best
	out.HitPos = Vector(ox + dx * best, oy + dy * best, oz + dz * best)
	out.HitNormal = bestNormal
	if bestShape.player ~= nil then
		out.Entity = bestShape.player
		out.HitNonWorld = true
		out.MatType = Geometry.MAT.FLESH
		out.HitGroup = bestGroup
		out.Contents = bor(C.HITBOX, C.MONSTER)
		out.HitTexture = "**studio**"
	else
		out.Entity = bestShape.ent
		out.HitWorld = bestShape.world == true
		out.HitNonWorld = not bestShape.world
		out.HitSky = bestShape.sky == true
		out.MatType = bestShape.mat
		out.SurfaceProps = bestShape.surface or 0
		out.PhysicsBone = bestShape.bone or 0
		out.Contents = bestShape.contents
		out.DispFlags = bestShape.displacement and 1 or 0
		out.HitTexture = bestShape.sky and "TOOLS/TOOLSSKYBOX" or (bestShape.world and "CONCRETE/WALL" or "**studio**")
	end
	return out
end

-- util.PointContents: the contents of the boxes of the map around `pos`.
function Geometry:PointContents(pos)
	local contents = 0
	for _, box in ipairs(self.boxes) do
		local mn, mx = box.mins, box.maxs
		if inside(pos.x, pos.y, pos.z, mn.x, mn.y, mn.z, mx.x, mx.y, mx.z) then
			contents = bor(contents, box.contents)
		end
	end
	return contents
end

-- Makes the traces of `env` see this geometry.
function Geometry:Install()
	local env = self.env
	env.geometry = self
	env.traceLine = function(trace) return self:Trace(trace, false) end
	env.traceHull = function(trace) return self:Trace(trace, true) end
	env.pointContents = function(pos) return self:PointContents(pos) end
	return self
end

return Geometry
