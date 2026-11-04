-- Rounds module, shared part: phases and time formatting.

local M = NC.Module("rounds")

local floor = math.floor
local ceil = math.ceil
local format = string.format

-- waiting    not enough players for the mode (warmup)
-- preparing  a new round: participants spawned, the start is near
-- active     the round is played
-- ended      the result is shown, the next round is near
M.PHASES = { "waiting", "preparing", "active", "ended" }

-- "m:ss" for a number of seconds rounded up, "h:mm:ss" from an hour on. A hair above a
-- whole second (float noise in game time) does not show the next second.
function M.FormatTime(seconds)
	seconds = ceil(seconds - 1e-3)
	if seconds ~= seconds or seconds <= 0 then
		return "0:00"
	end
	local hours = floor(seconds / 3600)
	local minutes = floor(seconds % 3600 / 60)
	if hours > 0 then
		return format("%d:%02d:%02d", hours, minutes, seconds % 60)
	end
	return format("%d:%02d", minutes, seconds % 60)
end
