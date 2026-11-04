-- Teams module, server part: rule blocks for rounds.
--
--   teams             teams (2..4), friendlyFire: participants are spread over the teams
--                     (the smallest first), team 1 spawns on side "a", team 2 on side "b"
--   team_elimination  a team without living members and pending respawns is out; the
--                     last team standing wins
--   team_score        scoreLimit (0 = none): a kill of an enemy scores for the team of the
--                     killer; the limit wins, and when time is up the leader wins

local M = NC.Module("teams")

local IsValid = IsValid

local SIDES = { "a", "b" }

function M:_RegisterRules(rounds, ctx)
	local teams = self

	rounds:RegisterRule({
		id = "teams",
		description = "participants are spread over balanced teams",
		params = {
			teams = { type = "integer", default = 2, min = 2, max = self.MAX, desc = "number of teams" },
			friendlyFire = { type = "boolean", desc = "teammates can hurt each other" },
		},
		Setup = function(round)
			teams:SetCount(round.params.teams)
		end,
		PlayerAdded = function(round, ply)
			teams:Assign(ply, teams:Smallest(round.params.teams))
		end,
		SpawnPoint = function(_, ply)
			return SIDES[ply:Team()] or "any"
		end,
		ShouldTakeDamage = function(round, ply, attacker)
			if round.params.friendlyFire or not (IsValid(attacker) and attacker:IsPlayer()) or attacker == ply then
				return nil
			end
			if teams:IsPlayable(ply:Team()) and attacker:Team() == ply:Team() then
				return false
			end
		end,
		Cleanup = function()
			teams:SetCount(0)
		end,
	}, ctx)

	rounds:RegisterRule({
		id = "team_elimination",
		description = "the last team with living members wins",
		CheckWin = function(round)
			local standing, count = nil, 0
			for index = 1, teams:Count() do
				if teams:_InGame(round, index) then
					standing, count = index, count + 1
				end
			end
			if count == 1 then
				return { reason = "elimination", team = standing }
			end
			if count == 0 then
				return { reason = "elimination" }
			end
		end,
	}, ctx)

	rounds:RegisterRule({
		id = "team_score",
		description = "kills of enemies score; the score limit or the leader at the end wins",
		params = {
			scoreLimit = { type = "integer", default = 50, min = 0, max = 10000, desc = "score to win (0 = none)" },
		},
		PlayerDied = function(round, ply, _, attacker)
			if not (IsValid(attacker) and attacker:IsPlayer()) or attacker == ply then
				return
			end
			local index = attacker:Team()
			if teams:IsPlayable(index) and index ~= ply:Team() and round:IsParticipant(attacker) then
				teams:AddScore(index, 1)
			end
		end,
		CheckWin = function(round)
			local limit = round.params.scoreLimit
			if limit <= 0 then
				return nil
			end
			for index = 1, teams:Count() do
				if teams:Score(index) >= limit then
					return { reason = "score", team = index }
				end
			end
		end,
		Timeout = function()
			return { reason = "time", team = teams:Leader() }
		end,
	}, ctx)
end

-- A team is still in the round while a member is alive or waiting for a respawn.
function M:_InGame(round, index)
	for _, ply in ipairs(round:Participants()) do
		if ply:Team() == index and (self.players:IsAlive(ply) or round:IsRespawning(ply)) then
			return true
		end
	end
	return false
end
