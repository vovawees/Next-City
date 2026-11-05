-- Rounds module, server part: built-in rule blocks.
--
--   time_limit     roundTime: the round ends when the time is up (0 = no limit)
--   respawn        respawn (instant | wave | none), respawnDelay, waveInterval: dead
--                  participants come back; players that become ready join an active round
--   last_standing  free for all: the last living participant wins
--   silent_deaths  deaths are not announced: no kill feed, no console line (gm.PlayerDeathNotice)
--   dead_mute      the living do not hear the dead and spectators: chat and voice
--
-- A mode lists rules by id and may redeclare a rule parameter to change its default.

local M = NC.Module("rounds")

local ceil = math.ceil

local TIME_LIMIT = {
	id = "time_limit",
	description = "the round ends when the time is up",
	params = {
		roundTime = { type = "number", default = 300, min = 0, max = 86400, desc = "round length, s (0 = no limit)" },
	},
	Start = function(round)
		round:SetTimeLimit(round.params.roundTime)
	end,
}

local RESPAWN = {
	id = "respawn",
	description = "dead participants come back; late players join",
	params = {
		respawn = { type = "enum", values = { "instant", "wave", "none" }, desc = "how dead players come back" },
		respawnDelay = { type = "number", default = 5, min = 0, max = 600, desc = "seconds before a respawn" },
		waveInterval = { type = "number", default = 15, min = 1, max = 600, desc = "seconds between waves" },
	},
	PlayerDied = function(round, ply)
		local params = round.params
		if params.respawn == "instant" then
			round:Respawn(ply, params.respawnDelay)
		elseif params.respawn == "wave" then
			-- The first wave at least respawnDelay away; waves are counted from the start.
			local elapsed = round:Elapsed()
			local wave = ceil((elapsed + params.respawnDelay) / params.waveInterval) * params.waveInterval
			round:Respawn(ply, wave - elapsed)
		end
	end,
	LateJoin = function(round)
		if round.params.respawn ~= "none" then
			return true
		end
	end,
}

local LAST_STANDING = {
	id = "last_standing",
	description = "free for all: the last living participant wins",
	CheckWin = function(round)
		if round:RespawnCount() > 0 then
			return nil
		end
		local alive = round:Alive()
		if alive[2] ~= nil then
			return nil
		end
		if alive[1] ~= nil then
			return { reason = "last", winner = alive[1] }
		end
		return { reason = "elimination" }
	end,
}

local SILENT_DEATHS = {
	id = "silent_deaths",
	description = "deaths are not announced: no kill feed, no console line",
	Setup = function(round)
		round:On("gm.PlayerDeathNotice", function()
			return false
		end)
	end,
}

function M:_RegisterBuiltinRules()
	local players = self.players
	self:RegisterRule(TIME_LIMIT)
	self:RegisterRule(RESPAWN)
	self:RegisterRule(LAST_STANDING)
	self:RegisterRule(SILENT_DEATHS)
	self:RegisterRule({
		id = "dead_mute",
		description = "the living do not hear the dead and spectators (chat and voice)",
		Setup = function(round)
			round:On("gm.PlayerCanSeePlayersChat", function(_, _, listener, speaker)
				if players:IsAlive(listener) and not players:IsAlive(speaker) then
					return false
				end
			end)
			round:On("gm.PlayerCanHearPlayersVoice", function(listener, talker)
				if players:IsAlive(listener) and not players:IsAlive(talker) then
					return false
				end
			end)
		end,
	})
end
