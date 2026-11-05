-- Teams module, server part: assignment, balance and scores.
--
-- Listens: players.stateChanged (during team play spectators are in TEAM_SPECTATOR),
--          net.ready (scores for a new player), i18n.changed.
-- Emits:   teams.changed (ply, index, old), teams.scores (scores).

local M = NC.Module("teams")

local ipairs = ipairs

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.scores = {}
	self.names = {}
	self.pending = false
	self:SetUpTeams()
	local rounds = ctx:Require("rounds")
	if rounds ~= nil then
		self:_RegisterRules(rounds, ctx)
	end
end

function M:Start(ctx)
	ctx:On("players.stateChanged", "OnStateChanged")
	ctx:On("net.ready", "OnNetReady")
	ctx:On("i18n.changed", "SetUpTeams")
end

-- Puts a player into a team (an index of the palette or TEAM_SPECTATOR, TEAM_UNASSIGNED).
function M:Assign(ply, index)
	local old = ply:Team()
	if old == index then
		return
	end
	ply:SetTeam(index)
	self.ctx.events:Emit("teams.changed", ply, index, old)
end

-- The team among 1..count with the fewest members; ties go to the lower index.
function M:Smallest(count)
	local sizes = {}
	for index = 1, count do
		sizes[index] = 0
	end
	for _, ply in ipairs(player.GetAll()) do
		local index = ply:Team()
		if sizes[index] ~= nil then
			sizes[index] = sizes[index] + 1
		end
	end
	local best = 1
	for index = 2, count do
		if sizes[index] < sizes[best] then
			best = index
		end
	end
	return best
end

-- Number of living members of a team.
function M:AliveCount(index)
	local count = 0
	for _, ply in ipairs(self.players:List("alive")) do
		if ply:Team() == index then
			count = count + 1
		end
	end
	return count
end

-- Starts team play with `count` teams at zero; 0 ends team play and every player is
-- unassigned again. names: translation keys of the team names (nil or "" = the palette).
function M:SetCount(count, names)
	local scores, keys = {}, {}
	for index = 1, math.min(count, self.MAX) do
		scores[index] = 0
		keys[index] = type(names) == "table" and type(names[index]) == "string" and names[index] or ""
	end
	self.scores = scores
	self.names = keys
	self:SetUpTeams()
	for _, ply in ipairs(player.GetAll()) do
		self:_Sync(ply)
	end
	self:_Changed()
end

-- During team play a ready player outside the teams is a spectator of the teams; without
-- team play nobody is in a team.
function M:_Sync(ply)
	local index = ply:Team()
	if self.scores[1] ~= nil then
		if self.players:State(ply) == "spectator" and index ~= TEAM_SPECTATOR then
			self:Assign(ply, TEAM_SPECTATOR)
		end
	elseif index == TEAM_SPECTATOR or self:IsPlayable(index) then
		self:Assign(ply, TEAM_UNASSIGNED)
	end
end

function M:SetScore(index, score)
	if self.scores[index] == nil then
		return
	end
	self.scores[index] = score
	self:_Changed()
end

function M:AddScore(index, amount)
	local score = self.scores[index]
	if score ~= nil then
		self:SetScore(index, score + (amount or 1))
	end
end

-- The team with the highest score, or nil on a tie or without teams.
function M:Leader()
	local best, tie = nil, false
	for index, score in ipairs(self.scores) do
		if best == nil or score > self.scores[best] then
			best, tie = index, false
		elseif score == self.scores[best] then
			tie = true
		end
	end
	if tie then
		return nil
	end
	return best
end

-- Score changes of one tick go out in one message.
function M:_Changed()
	if self.pending then
		return
	end
	self.pending = true
	self.ctx:After(0, function()
		self.pending = false
		self.ctx.net:Broadcast("scores", { scores = self.scores, names = self.names })
		self.ctx.events:Emit("teams.scores", self.scores)
	end)
end

function M:OnStateChanged(ply)
	self:_Sync(ply)
end

function M:OnNetReady(ply)
	self.ctx.net:Send("scores", ply, { scores = self.scores, names = self.names })
end
