-- Profiles, shared part: the summary of a profile (the server knows every player's, a
-- client only its own).
--
--   profiles:Summary(ply)          -> { first, visits, playtime, since, kills, deaths, rounds, wins,
--                                       creatures } or nil
--   profiles:SummaryPlaytime(ply)  -> s in the game with the running session, or nil

local M = NC.Module("profiles")

-- Counters of every record that the summary carries (the order of the profile tab).
M.STATS = { "kills", "deaths", "rounds", "wins", "creatures" }

local CurTime = CurTime
local floor = math.floor
local max = math.max

function M:Init(ctx)
	if SERVER then
		self:_InitServer(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		self:_StartServer(ctx)
	end
end

function M:Summary(ply)
	return self.ctx.components.summary:Get(ply)
end

function M:SummaryPlaytime(ply)
	local summary = self:Summary(ply)
	if summary == nil then
		return nil
	end
	if summary.since <= 0 then
		return summary.playtime
	end
	return summary.playtime + floor(max(0, CurTime() - summary.since))
end
