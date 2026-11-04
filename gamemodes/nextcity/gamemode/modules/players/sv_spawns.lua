-- Players module, server part: spawn points.
--
-- Spawn entities of common map formats are grouped into sides: "a" (rebels, terrorists,
-- red...), "b" (combine, counter-terrorists, blue...) and "any" (every point). A side
-- without points falls back to "any". The lists are rebuilt after map cleanups, which
-- recreate map entities.

local M = NC.Module("players")

local SPAWN_CLASSES = {
	info_player_start = "any", info_player_deathmatch = "any", gmod_player_start = "any",
	info_player_teamspawn = "any", info_player_coop = "any", ins_spawnpoint = "any", aoc_spawnpoint = "any",
	dys_spawn_point = "any", info_player_knight = "any", info_player_fof = "any", info_player_desperado = "any",
	info_player_vigilante = "any",
	info_player_rebel = "a", info_player_terrorist = "a", info_player_axis = "a", info_player_red = "a",
	diprip_start_team_red = "a", info_player_pirate = "a", info_player_human = "a",
	info_player_combine = "b", info_player_counterterrorist = "b", info_player_allies = "b", info_player_blue = "b",
	diprip_start_team_blue = "b", info_player_viking = "b", info_player_zombie = "b",
}

M.SPAWN_CLASSES = SPAWN_CLASSES

local HULL_MINS = Vector(-16, -16, 0)
local HULL_MAXS = Vector(16, 16, 72)
local LIFT = Vector(0, 0, 8)
local DROP = Vector(0, 0, 128)
local HEIGHT = 72

-- Offsets tried around a taken point: four rings of eight directions.
local RING = {}
for ring = 1, 4 do
	for step = 0, 7 do
		local angle = step * math.pi / 4 + (ring % 2) * math.pi / 8
		RING[#RING + 1] = { math.cos(angle) * 48 * ring, math.sin(angle) * 48 * ring }
	end
end

function M:RefreshSpawns()
	local groups = { a = {}, b = {}, any = {} }
	local classes = {}
	for class in pairs(SPAWN_CLASSES) do
		classes[#classes + 1] = class
	end
	table.sort(classes)
	for _, class in ipairs(classes) do
		local side = SPAWN_CLASSES[class]
		for _, ent in ipairs(ents.FindByClass(class)) do
			if side ~= "any" then
				groups[side][#groups[side] + 1] = ent
			end
			groups.any[#groups.any + 1] = ent
		end
	end
	self.spawns = groups
	self.ctx.log:Debug("spawn points: %d (side a %d, side b %d)", #groups.any, #groups.a, #groups.b)
end

local function allValid(list)
	for i = 1, #list do
		if not IsValid(list[i]) then
			return false
		end
	end
	return true
end

-- Spawn entities of a group ("a", "b" or "any"); an empty side falls back to "any".
-- Do not modify the list.
function M:SpawnPoints(group)
	local groups = self.spawns
	if groups == nil or not allValid(groups.any) then
		self:RefreshSpawns()
		groups = self.spawns
	end
	local list = groups[group or "any"] or groups.any
	if list[1] == nil then
		return groups.any
	end
	return list
end

-- Teams count as hostile unless both players are in the same real team.
local function hostile(a, b)
	local team = a:Team()
	if team == TEAM_UNASSIGNED or team == TEAM_CONNECTING or team == TEAM_SPECTATOR then
		return true
	end
	return team ~= b:Team()
end

local function isFree(pos, others, clearance)
	local limit = clearance * clearance
	for i = 1, #others do
		local other = others[i]
		local dx, dy, dz = other.x - pos.x, other.y - pos.y, other.z - pos.z
		if dx * dx + dy * dy < limit and dz < HEIGHT and dz > -HEIGHT then
			return false
		end
	end
	return true
end

local function nearest(pos, list)
	local best = math.huge
	for i = 1, #list do
		local d = pos:DistToSqr(list[i])
		if d < best then
			best = d
		end
	end
	return best
end

-- A free standing spot around a taken point: reachable from it without hitting the
-- world and with ground below. Returns the position or nil.
function M:FindSpot(center, others, ply)
	local clearance = self.ctx.config.clearance
	local from = center + LIFT
	for _, offset in ipairs(RING) do
		local pos = Vector(center.x + offset[1], center.y + offset[2], center.z)
		if isFree(pos, others, clearance) then
			local path = util.TraceHull({ start = from, endpos = pos + LIFT, mins = HULL_MINS, maxs = HULL_MAXS,
				mask = MASK_PLAYERSOLID, filter = ply })
			if not path.Hit and not path.StartSolid then
				local ground = util.TraceLine({ start = pos + LIFT, endpos = pos - DROP, mask = MASK_PLAYERSOLID,
					filter = ply })
				if ground.Hit and not ground.StartSolid then
					return ground.HitPos
				end
			end
		end
	end
	return nil
end

-- Picks a spawn for ply among candidate entities: a point no living player stands on,
-- farthest from hostile players; ties go round-robin, so a round start spreads players.
-- When every point is taken, a free spot next to one. Returns the point and, for a spot
-- next to it, the position (nil, nil without candidates).
function M:PickSpawn(ply, candidates)
	local count = #candidates
	if count == 0 then
		return nil, nil
	end
	local others, hostiles = {}, {}
	for _, other in ipairs(self:List("alive")) do
		if other ~= ply and IsValid(other) then
			local pos = other:GetPos()
			others[#others + 1] = pos
			if hostile(ply, other) then
				hostiles[#hostiles + 1] = pos
			end
		end
	end
	local clearance = self.ctx.config.clearance
	local cursor = self.spawnCursor % count
	self.spawnCursor = self.spawnCursor + 1
	local best, bestScore
	for i = 0, count - 1 do
		local point = candidates[(cursor + i) % count + 1]
		local pos = point:GetPos()
		if isFree(pos, others, clearance) then
			local score = nearest(pos, hostiles)
			if best == nil or score > bestScore then
				best, bestScore = point, score
			end
		end
	end
	if best ~= nil then
		return best, nil
	end
	for i = 0, count - 1 do
		local point = candidates[(cursor + i) % count + 1]
		local spot = self:FindSpot(point:GetPos(), others, ply)
		if spot ~= nil then
			return point, spot
		end
	end
	return candidates[cursor + 1], nil
end
