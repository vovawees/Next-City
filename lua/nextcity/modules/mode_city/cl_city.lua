-- City, client part: the job under the name of the player in front (players.targetLines)
-- and the requests of the menu of the city.
--
--   city:AskJob(id), city:AskName(name), city:AskBuy(offer, times) -> ask the server
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

-- The menu asks the server for a job, a name, a purchase.
function M:AskJob(id)
	for index, jobId in ipairs(self.jobOrder) do
		if jobId == id then
			self.ctx.net:SendToServer("job", { job = index })
			return
		end
	end
end

function M:AskName(name)
	self.ctx.net:SendToServer("name", { name = tostring(name) })
end

function M:AskBuy(id, times)
	times = math.min(M.MAX_TIMES, math.max(1, math.floor(tonumber(times) or 1)))
	for index, offerId in ipairs(self.offerOrder) do
		if offerId == id then
			self.ctx.net:SendToServer("buy", { offer = index, times = times })
			return
		end
	end
end
