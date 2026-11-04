-- Teams module, shared part: the palette. Teams 1..4 exist on both realms from the start
-- (team.SetUp with names in the local language); a round decides how many are in play.

local M = NC.Module("teams")

M.PALETTE = {
	{ key = "red", color = Color(220, 64, 52) },
	{ key = "blue", color = Color(52, 120, 220) },
	{ key = "green", color = Color(64, 170, 72) },
	{ key = "yellow", color = Color(226, 180, 40) },
}
M.MAX = #M.PALETTE

-- True for the indexes of the palette (not spectators, unassigned or connecting).
function M:IsPlayable(index)
	return type(index) == "number" and self.PALETTE[index] ~= nil
end

-- Translation key of a team name, e.g. "teams.red".
function M:NameKey(index)
	local entry = self.PALETTE[index]
	return entry and "teams." .. entry.key or nil
end

function M:Color(index)
	local entry = self.PALETTE[index]
	return entry and entry.color or nil
end

-- Registers the palette with the engine in the current language (again on a change).
function M:SetUpTeams()
	local i18n = self.ctx.i18n
	for index, entry in ipairs(self.PALETTE) do
		team.SetUp(index, i18n:T("teams." .. entry.key), entry.color, false)
	end
end

-- Number of teams in play (0 without team play).
function M:Count()
	return #self.scores
end

function M:Score(index)
	return self.scores[index] or 0
end

-- Team of a player if it is a team of the palette, else nil.
function M:Of(ply)
	local index = ply:Team()
	if self.PALETTE[index] ~= nil then
		return index
	end
	return nil
end

-- Players of a team, a new table sorted by entity index.
function M:Members(index)
	local members = {}
	for _, ply in ipairs(player.GetAll()) do
		if ply:Team() == index then
			members[#members + 1] = ply
		end
	end
	return members
end
