-- Ragdoll, server part: the ragdolls themselves. Building one in the pose of a player,
-- hiding the player inside it, corpses with their limits, and the spot to get up on.
--
-- Pose: every physics bone of a new ragdoll takes the place and the angles of the same
-- bone of the player (after SetupBones) and the velocity of the player. Bodies collide
-- with the world, props and bullets but not with players (COLLISION_GROUP_WEAPON); a
-- corpse at rest for config.settleTime sleeps and lets players, NPCs and other bodies
-- pass (COLLISION_GROUP_DEBRIS).
-- Hidden: not drawn, no hull, no movement (MOVETYPE_NONE), view offsets 0 (the eyes are
-- at the origin, which follows the body), no view model or world model.
-- Corpses: at most config.corpses (not less than 1); a new one takes the place of the
-- oldest. Fallen bodies and corpses together: at most config.ragdolls; beyond that the
-- oldest corpse goes, and with no corpse left nobody falls.
-- Getting up: the floor below the pelvis (a line down) and the hull of the player on it,
-- as player movement sees the world (bodies do not block it); otherwise spots on rings
-- around the pelvis that are in sight of it.

local M = NC.Module("ragdoll")

local IsValid = IsValid
local Vector = Vector
local Angle = Angle
local cos = math.cos
local sin = math.sin
local max = math.max
local pi = math.pi
local remove = table.remove
local TraceLine = util.TraceLine
local TraceHull = util.TraceHull

local HEAD = "ValveBiped.Bip01_Head1"
local PELVIS = "ValveBiped.Bip01_Pelvis"
local ZERO = Vector(0, 0, 0)
local LIFT = 8            -- the floor is looked for from this far above the pelvis, units
local DEPTH = 72          -- and down to this far below it
local REST = 4            -- units/s: a corpse slower than this is at rest
local RINGS = { 20, 40 }  -- radii of the rings of spots around the pelvis, units
local RING = 8            -- spots per ring

local filter = {}
local line = { filter = filter, mask = MASK_PLAYERSOLID, collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT }
local hull = { filter = filter, mask = MASK_PLAYERSOLID, collisiongroup = COLLISION_GROUP_PLAYER_MOVEMENT }

-- Building ------------------------------------------------------------------------------------

-- A new ragdoll of `ply` in its pose, moving at `vel` (nil: the velocity of the player),
-- or nil when its model has no ragdoll.
function M:_Build(ply, vel)
	local rag = ents.Create("prop_ragdoll")
	if not IsValid(rag) then
		return nil
	end
	rag:SetModel(ply:GetModel())
	rag:SetSkin(ply:GetSkin())
	for i = 0, ply:GetNumBodyGroups() - 1 do
		rag:SetBodygroup(i, ply:GetBodygroup(i))
	end
	rag:SetColor(ply:GetColor())
	rag:SetMaterial(ply:GetMaterial())
	rag:SetPos(ply:GetPos())
	rag:SetAngles(Angle(0, ply:EyeAngles().y, 0))
	rag:Spawn()
	rag:Activate()
	local count = rag:GetPhysicsObjectCount()
	if count == 0 then
		rag:Remove()
		return nil
	end
	vel = vel or ply:GetVelocity()
	ply:SetupBones()
	for i = 0, count - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		if IsValid(phys) then
			local pos, ang = ply:GetBonePosition(rag:TranslatePhysBoneToBone(i))
			if pos ~= nil then
				phys:SetPos(pos, true)
				phys:SetAngles(ang)
			end
			phys:SetVelocity(vel)
			phys:Wake()
		end
	end
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	return rag
end

-- The physics objects of `rag` by the names of their bones; also body.head, body.pelvis.
function M:_Attach(body, rag)
	local phys = {}
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local obj = rag:GetPhysicsObjectNum(i)
		local name = rag:GetBoneName(rag:TranslatePhysBoneToBone(i))
		if IsValid(obj) and name ~= nil then
			phys[name] = obj
		end
	end
	body.ent = rag
	body.phys = phys
	body.head = phys[HEAD]
	body.pelvis = phys[PELVIS] or rag:GetPhysicsObject()
end

-- The killing force of `dmginfo` pushes the physics object of `rag` nearest to its point.
function M:_Push(rag, dmginfo)
	local force = dmginfo:GetDamageForce()
	if force:IsZero() then
		return
	end
	local pos = dmginfo:GetDamagePosition()
	local nearest = rag:GetPhysicsObject()
	if not pos:IsZero() then
		local best
		for i = 0, rag:GetPhysicsObjectCount() - 1 do
			local phys = rag:GetPhysicsObjectNum(i)
			local d = IsValid(phys) and phys:GetPos():DistToSqr(pos)
			if d and (best == nil or d < best) then
				nearest, best = phys, d
			end
		end
	end
	if IsValid(nearest) then
		nearest:ApplyForceOffset(force, pos)
	end
end

-- The player -----------------------------------------------------------------------------

-- Hides `ply` inside its body; what changes is kept in body.saved.
function M:_Hide(ply, body)
	body.saved = { view = ply:GetViewOffset(), ducked = ply:GetViewOffsetDucked() }
	ply:SetNoDraw(true)
	ply:SetNotSolid(true)
	ply:SetMoveType(MOVETYPE_NONE)
	ply:SetLocalVelocity(ZERO)
	self:_HideView(ply)
	ply:DrawViewModel(false)
	ply:DrawWorldModel(false)
end

-- The eyes of a hidden player are at its origin.
function M:_HideView(ply)
	ply:SetViewOffset(ZERO)
	ply:SetViewOffsetDucked(ZERO)
	ply:SetCurrentViewOffset(ZERO)
end

-- The eyes of `ply` where they were before it fell.
function M:_ShowView(ply, body)
	local saved = body.saved
	ply:SetViewOffset(saved.view)
	ply:SetViewOffsetDucked(saved.ducked)
	ply:SetCurrentViewOffset(saved.view)
end

-- Shows `ply` again: its eyes, models and drawing and, if `alive`, its hull and
-- movement (a dead player keeps what the engine gave it).
function M:_Show(ply, body, alive)
	self:_ShowView(ply, body)
	ply:DrawViewModel(true)
	ply:DrawWorldModel(true)
	ply:SetNoDraw(false)
	if alive then
		ply:SetNotSolid(false)
		ply:SetMoveType(MOVETYPE_WALK)
		ply:SetLocalVelocity(ZERO)
	end
end

-- Corpses ----------------------------------------------------------------------------------

-- Whether one more ragdoll fits; at the limit the oldest corpse makes room.
function M:_Fits()
	if self.fallen + #self.corpses < self.ctx.config.ragdolls then
		return true
	end
	if #self.corpses > 0 then
		self:_RemoveCorpse(1)
		return true
	end
	return false
end

-- `rag` becomes the corpse of `ply`; beyond the limit the oldest corpse goes.
function M:_AddCorpse(ply, rag, now)
	local corpses = self.corpses
	local limit = max(1, self.ctx.config.corpses)
	while #corpses >= limit do
		self:_RemoveCorpse(1)
	end
	local corpse = { corpse = true, ent = rag, ply = ply, at = now, rest = nil, settled = false }
	corpses[#corpses + 1] = corpse
	self.byEnt[rag] = corpse
	return corpse
end

function M:_RemoveCorpse(i)
	local corpse = remove(self.corpses, i)
	local ent = corpse.ent
	self.byEnt[ent] = nil
	if IsValid(ent) then
		ent:Remove()
	end
end

function M:_ForgetCorpse(corpse)
	for i, other in ipairs(self.corpses) do
		if other == corpse then
			remove(self.corpses, i)
			return
		end
	end
end

-- Corpses past config.corpseTime go (at most config.cleanupBudget a call); corpses at
-- rest for config.settleTime sleep and become debris.
function M:Clean(now)
	local config = self.ctx.config
	local budget = config.cleanupBudget
	local corpses = self.corpses
	local i = 1
	while i <= #corpses do
		local corpse = corpses[i]
		if not IsValid(corpse.ent) then
			self.byEnt[corpse.ent] = nil
			remove(corpses, i)
		elseif config.corpseTime > 0 and now - corpse.at >= config.corpseTime and budget > 0 then
			budget = budget - 1
			self:_RemoveCorpse(i)
		else
			if not corpse.settled then
				self:_Settle(corpse, now, config.settleTime)
			end
			i = i + 1
		end
	end
end

function M:_Settle(corpse, now, settleTime)
	local ent = corpse.ent
	if ent:GetVelocity():LengthSqr() > REST * REST then
		corpse.rest = nil
		return
	end
	corpse.rest = corpse.rest or now
	if now - corpse.rest < settleTime then
		return
	end
	corpse.settled = true
	ent:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	for i = 0, ent:GetPhysicsObjectCount() - 1 do
		local phys = ent:GetPhysicsObjectNum(i)
		if IsValid(phys) then
			phys:Sleep()
		end
	end
end

-- Getting up ----------------------------------------------------------------------------------

-- The floor at x, y below z (from LIFT above to DEPTH below) if the hull of `ply` fits
-- on it, otherwise nil.
local function floorAt(ply, x, y, z)
	line.start = Vector(x, y, z + LIFT)
	line.endpos = Vector(x, y, z - DEPTH)
	local tr = TraceLine(line)
	if not tr.Hit or tr.StartSolid then
		return nil
	end
	local pos = tr.HitPos
	local above = Vector(pos.x, pos.y, pos.z + 1)
	hull.start, hull.endpos = above, above
	hull.mins, hull.maxs = ply:GetHull()
	local room = TraceHull(hull)
	if room.Hit or room.StartSolid then
		return nil
	end
	return pos
end

-- Nothing between `from` and x, y at its height.
local function inSight(from, x, y)
	line.start = from
	line.endpos = Vector(x, y, from.z)
	return not TraceLine(line).Hit
end

-- Where `ply` can stand up from its body at `pos` (the pelvis): a spot on the floor
-- with room for its hull, or nil. `rag` (the body, may be nil) does not block.
function M:_Spot(ply, pos, rag)
	filter[1], filter[2] = ply, rag
	local x, y, z = pos.x, pos.y, pos.z
	local spot = floorAt(ply, x, y, z)
	if spot ~= nil then
		return spot
	end
	local from = Vector(x, y, z + LIFT)
	for _, radius in ipairs(RINGS) do
		for j = 0, RING - 1 do
			local a = j * 2 * pi / RING
			local sx, sy = x + cos(a) * radius, y + sin(a) * radius
			if inSight(from, sx, sy) then
				spot = floorAt(ply, sx, sy, z)
				if spot ~= nil then
					return spot
				end
			end
		end
	end
	return nil
end

-- Whether the hull of `ply` still fits at `spot`.
function M:_Free(ply, spot, rag)
	filter[1], filter[2] = ply, rag
	local above = Vector(spot.x, spot.y, spot.z + 1)
	hull.start, hull.endpos = above, above
	hull.mins, hull.maxs = ply:GetHull()
	local room = TraceHull(hull)
	return not room.Hit and not room.StartSolid
end
