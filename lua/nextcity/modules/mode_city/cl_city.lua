-- City, client part: the job under the name of the player in front (players.targetLines).
--
-- Listens: players.targetLines.

local M = NC.Module("mode_city")

function M:_StartClient(ctx)
	ctx:On("players.targetLines", "AddTargetLine")
end

-- The job of a citizen under his name.
function M:AddTargetLine(lines, ply)
	local job = self:JobOf(ply)
	if job ~= nil then
		local i18n = self.ctx.i18n
		lines[#lines + 1] = i18n:Has(job.name) and i18n:T(job.name) or job.id
	end
	return lines
end
