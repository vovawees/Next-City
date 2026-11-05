-- City, client part: the job under the name of the player in front (players.targetLines),
-- the money and the salary at the top left under the job (the roles module draws the job
-- and its goal), the answers of the doors on the client and the requests of the menu.
--
--   city:IsRunning()  -> the city is the round now (as the rounds module tells this client)
--   city:Count(id)    -> players with job `id` this client knows of
--   city:AskJob(id), city:AskBuy(offer, times) -> ask the server
--
-- Answers: doors.property (doors are property while the city runs), doors.groupName (a
--          group of doors by the name of its job).
-- Listens: players.targetLines, gm.HUDPaint, gm.PlayerBindPress (gm_showspare2: the menu,
--          cl_menu.lua), roles.changed, i18n.changed.

local M = NC.Module("mode_city")

local CurTime = CurTime
local IsValid = IsValid
local ipairs = ipairs
local tostring = tostring

local FONT = "NC.City.Hud"
local OUTLINE = Color(0, 0, 0, 200)
local WHITE = Color(235, 235, 235)
local DIM = Color(175, 175, 175)
local LEFT, TOP = 24, 84 -- under the job and its goal (the roles module, y 24-76)
local HUD_TIME = 0.25    -- s the texts of the HUD are kept before they are built again

surface.CreateFont(FONT, { font = "Roboto", size = 19, weight = 500, extended = true })

function M:_InitClient(ctx)
	self.rounds = ctx:Require("rounds")
	self.players = ctx:Require("players")
	self.economy = ctx:Require("economy")
	self.inventory = ctx:Require("inventory")
	self.law = ctx:Require("law")
	self.identity = ctx:Require("identity")
	self.hud = nil -- { expires, money, salary }
	self:_InitMenu()
	local playerMenu = ctx:Require("menu")
	self.playerMenu = playerMenu
	if playerMenu ~= nil then
		playerMenu:AddHelp("mode_city.menu", { bind = "gm_showspare2", fallback = "f4", text = "mode_city.help.menu",
			order = 40, visible = function() return self:IsRunning() end })
	end
end

function M:_StartClient(ctx)
	ctx:On("players.targetLines", "AddTargetLine")
	ctx:On("gm.HUDPaint", "PaintHud")
	ctx:On("gm.PlayerBindPress", "OnBind")
	ctx:On("doors.property", "AnswerProperty")
	ctx:On("doors.groupName", "AnswerGroupName")
	ctx:On("roles.changed", "OnJobChanged")
	ctx:On("i18n.changed", "OnLanguage")
end

function M:IsRunning()
	local state = self.rounds ~= nil and self.rounds:State() or nil
	return state ~= nil and state.mode == "city" and (state.phase == "preparing" or state.phase == "active")
end

function M:Count(id)
	local count = 0
	for _, ply in ipairs(player.GetAll()) do
		if self.roles:Of(ply) == id then
			count = count + 1
		end
	end
	return count
end

function M:_Name(key, fallback)
	local i18n = self.ctx.i18n
	return i18n:Has(key) and i18n:T(key) or fallback
end

function M:Money(amount)
	return self.economy ~= nil and self.economy:Format(amount) or tostring(amount)
end

-- The job of a citizen under his name.
function M:AddTargetLine(lines, ply)
	local job = self:JobOf(ply)
	if job ~= nil then
		lines[#lines + 1] = self:_Name(job.name, job.id)
	end
	return lines
end

function M:AnswerProperty()
	if self:IsRunning() then
		return true
	end
end

function M:AnswerGroupName(group)
	local job = self.jobs[group]
	if job ~= nil and self:IsRunning() then
		return self:_Name(job.name, job.id)
	end
end

-- The HUD ---------------------------------------------------------------------------------

function M:HudLines()
	local me = LocalPlayer()
	local economy = self.economy
	if not IsValid(me) or economy == nil or not self:IsRunning() then
		return nil
	end
	local i18n = self.ctx.i18n
	local lines = { { text = i18n:T("mode_city.hud.money", { balance = self:Money(economy:Balance()),
		cash = self:Money(economy:Cash()) }), color = WHITE } }
	local job = self:JobOf(me)
	if job ~= nil and job.salary > 0 then
		lines[#lines + 1] = { text = i18n:T("mode_city.hud.salary", { amount = self:Money(job.salary) }), color = DIM }
	end
	lines[#lines + 1] = { text = i18n:T("mode_city.hud.menu", { key = self:MenuKey() }), color = DIM }
	return lines
end

function M:PaintHud()
	local hud = self.hud
	if hud == nil or CurTime() >= hud.expires then
		hud = { expires = CurTime() + HUD_TIME, lines = self:HudLines() }
		self.hud = hud
	end
	if hud.lines == nil then
		return
	end
	local y = TOP
	for _, line in ipairs(hud.lines) do
		draw.SimpleTextOutlined(line.text, FONT, LEFT, y, line.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, OUTLINE)
		y = y + 22
	end
end

function M:OnJobChanged()
	self.hud = nil
	self:RefreshMenu(true)
end

function M:OnLanguage()
	self.hud = nil
	self:RefreshMenu(true)
end

-- Requests --------------------------------------------------------------------------------

-- The menu asks the server for a job, a name, a purchase.
function M:AskJob(id)
	for index, jobId in ipairs(self.jobOrder) do
		if jobId == id then
			self.ctx.net:SendToServer("job", { job = index })
			return
		end
	end
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
