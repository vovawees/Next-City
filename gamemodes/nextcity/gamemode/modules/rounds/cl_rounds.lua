-- Rounds module, client part: the phase from the server and a small HUD at the top of
-- the screen (mode, round number, timer, the status line of the mode under the scores of
-- the teams) with the result banner after a round.
--
-- Texts are rebuilt when a shown second changes, the state or the status arrives or the
-- language changes, never every frame.
--
-- Emits: rounds.phase (phase, old) when the phase changes.

local M = NC.Module("rounds")

local CurTime = CurTime
local ScrW = ScrW
local ScrH = ScrH
local ceil = math.ceil
local floor = math.floor
local max = math.max

local FONT_SMALL = "NC.Rounds.Small"
local FONT_LARGE = "NC.Rounds.Large"
local WHITE = Color(255, 255, 255)
local OUTLINE = Color(0, 0, 0, 200)
local STATES = { "spectator", "alive", "dead" }

M.STATUS_Y = 98 -- under the scores of the teams (the teams module, y 70)

surface.CreateFont(FONT_SMALL, { font = "Roboto", size = 20, weight = 500, extended = true })
surface.CreateFont(FONT_LARGE, { font = "Roboto", size = 34, weight = 700, extended = true })

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.state = { phase = "waiting", mode = "", name = "", number = 0, endsAt = 0, minPlayers = 0 }
	self.result = nil
	self.status = { key = "", endsAt = 0, params = {} }
	self.statusParams = {}
	self.text = { top = "", timer = "", status = "", headline = nil, subtitle = nil, color = WHITE }
	self.shown = nil
	self.statusShown = nil
	ctx.net:Receive("state", "OnState")
	ctx.net:Receive("result", "OnResult")
	ctx.net:Receive("status", "OnStatus")
end

function M:Start(ctx)
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("i18n.changed", "Invalidate")
end

function M:OnState(data)
	local old = self.state.phase
	self.state = data
	if data.phase ~= "ended" then
		self.result = nil
	end
	self:Invalidate()
	if data.phase ~= old then
		self.ctx.events:Emit("rounds.phase", data.phase, old)
	end
end

function M:OnResult(data)
	self.result = data
	self:Invalidate()
end

function M:OnStatus(data)
	self.status = data
	self.statusParams = self.DecodeParams(data.params)
	self:Invalidate()
end

-- The status line as the server sent it: { key ("" for none), endsAt, params } (do not modify).
function M:Status()
	return self.status
end

-- Seconds until the countdown of the status line ends, nil without one.
function M:_StatusLeft()
	local endsAt = self.status.endsAt
	if self.status.key == "" or endsAt <= 0 then
		return nil
	end
	return max(endsAt - CurTime(), 0)
end

-- Current phase and state as the server sent them (do not modify the state).
function M:Phase()
	return self.state.phase
end

function M:State()
	return self.state
end

-- The result of the round that ended, or nil.
function M:Result()
	return self.result
end

-- Seconds until the phase ends, nil without a limit.
function M:TimeLeft()
	local endsAt = self.state.endsAt
	if endsAt <= 0 then
		return nil
	end
	return max(endsAt - CurTime(), 0)
end

function M:Invalidate()
	self.shown = nil
end

function M:_ReadyCount()
	local count = 0
	for _, state in ipairs(STATES) do
		count = count + self.players:Count(state)
	end
	return count
end

-- A translation key or plain text (mode names may be either).
local function translate(i18n, text, params)
	if text ~= "" and i18n:Has(text) then
		return i18n:T(text, params)
	end
	return text
end

function M:_Headline(result)
	local i18n = self.ctx.i18n
	local teamName = result.team > 0 and team.GetName(result.team) or ""
	local winner = IsValid(result.winner) and self.players:Name(result.winner) or ""
	local params = self.DecodeParams(result.params or {})
	params.team, params.player = teamName, winner
	local key = result.key
	if key == "" then
		if result.team > 0 then
			key = "rounds.result.team"
		elseif winner ~= "" then
			key = "rounds.result.player"
		else
			key = "rounds.result.draw"
		end
	end
	-- A reason with a dot is a translation key of its own ("mode_homicide.reason.fled").
	local reason = result.reason
	if not reason:find(".", 1, true) then
		reason = "rounds.reason." .. reason
	end
	local subtitle = i18n:Has(reason) and i18n:T(reason, params) or nil
	local color = result.team > 0 and team.GetColor(result.team) or WHITE
	return translate(i18n, key, params), subtitle, color
end

function M:_Refresh()
	local i18n = self.ctx.i18n
	local state = self.state
	local text = self.text
	local left = self:TimeLeft()
	local mode = translate(i18n, state.name)
	if state.phase == "waiting" then
		if state.mode == "" then
			text.top, text.timer = i18n:T("rounds.noModes"), ""
		else
			text.top = mode
			text.timer = i18n:T("rounds.waiting", { count = self:_ReadyCount(), min = state.minPlayers })
		end
	else
		text.top = i18n:T("rounds.title", { mode = mode, number = state.number })
		text.timer = left and i18n:T("rounds." .. state.phase, { time = self.FormatTime(left) }) or ""
	end
	local status = self.status
	if status.key ~= "" then
		local params = self.statusParams
		local statusLeft = self:_StatusLeft()
		if statusLeft ~= nil then
			params.time = self.FormatTime(statusLeft)
		end
		text.status = translate(i18n, status.key, params)
	else
		text.status = ""
	end
	local result = self.result
	if state.phase == "ended" and result ~= nil then
		text.headline, text.subtitle, text.color = self:_Headline(result)
	else
		text.headline, text.subtitle = nil, nil
	end
end

function M:Paint()
	local left = self:TimeLeft()
	-- What is on screen changes with the shown second (or each second while waiting) and
	-- the second of the countdown of the status line.
	local shown = left and ceil(left - 1e-3) or -floor(CurTime())
	local statusLeft = self:_StatusLeft()
	local statusShown = statusLeft and ceil(statusLeft - 1e-3) or -1
	if shown ~= self.shown or statusShown ~= self.statusShown then
		self.shown, self.statusShown = shown, statusShown
		self:_Refresh()
	end
	local text = self.text
	local x = ScrW() * 0.5
	draw.SimpleTextOutlined(text.top, FONT_SMALL, x, 8, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, OUTLINE)
	if text.timer ~= "" then
		draw.SimpleTextOutlined(text.timer, FONT_LARGE, x, 30, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, OUTLINE)
	end
	if text.status ~= "" then
		draw.SimpleTextOutlined(text.status, FONT_SMALL, x, M.STATUS_Y, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1,
			OUTLINE)
	end
	if text.headline ~= nil then
		local y = ScrH() * 0.28
		draw.SimpleTextOutlined(text.headline, FONT_LARGE, x, y, text.color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2,
			OUTLINE)
		if text.subtitle ~= nil then
			draw.SimpleTextOutlined(text.subtitle, FONT_SMALL, x, y + 32, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1,
				OUTLINE)
		end
	end
end
