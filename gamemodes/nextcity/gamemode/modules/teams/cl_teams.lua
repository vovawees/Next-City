-- Teams module, client part: team names in the client language and the scores of the
-- teams in play under the round timer.

local M = NC.Module("teams")

local ScrW = ScrW
local FONT = "NC.Teams.Score"
local OUTLINE = Color(0, 0, 0, 200)
local GAP = 24

surface.CreateFont(FONT, { font = "Roboto", size = 22, weight = 700, extended = true })

function M:Init(ctx)
	self.scores = {}
	self.names = {}
	self.texts = {}
	self:SetUpTeams()
	ctx.net:Receive("scores", "OnScores")
end

function M:Start(ctx)
	ctx:On("i18n.changed", "OnLanguage")
	ctx:On("gm.HUDPaint", "Paint")
end

function M:OnLanguage()
	self:SetUpTeams()
	self:_Refresh()
end

function M:OnScores(data)
	self.scores = data.scores
	self.names = data.names
	self:SetUpTeams()
	self:_Refresh()
	self.ctx.events:Emit("teams.scores", self.scores)
end

-- "Reds 12" per team, measured once per change.
function M:_Refresh()
	local texts = {}
	surface.SetFont(FONT)
	local total = 0
	for index, score in ipairs(self.scores) do
		local text = team.GetName(index) .. " " .. score
		local width = surface.GetTextSize(text)
		texts[index] = { text = text, width = width, color = self:Color(index) }
		total = total + width + (index > 1 and GAP or 0)
	end
	self.texts = texts
	self.width = total
end

function M:Paint()
	local texts = self.texts
	if texts[1] == nil then
		return
	end
	local x = (ScrW() - self.width) * 0.5
	for _, item in ipairs(texts) do
		draw.SimpleTextOutlined(item.text, FONT, x, 70, item.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, OUTLINE)
		x = x + item.width + GAP
	end
end
