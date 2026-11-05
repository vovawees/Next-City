-- Voice, the client: who talks — the players this client hears, from the engine hooks
-- PlayerStartVoice and PlayerEndVoice, whose base panels (the nicks and the avatars) stay off
-- the screen: the HUD shows the names others see (players:Name) on the right, a yell, a
-- whisper and a radio marked — the own voice and radio while he talks and a moment after a
-- change, the talk key of the radio (+nc_radio: bind b +nc_radio; it turns the microphone on
-- by itself) and the keys of the help of the menu (F1).
--
--   voice:Talkers()        -> the players talking now that this client hears, in the order
--                             they began (not the local player)
--   voice:IsTalking()      -> whether the local player talks now
--   voice:Mode(ply)        -> the mode of the voice of a player (default the local one)
--   voice:Radio()          -> { frequency, on } of the radio the local player carries, or nil
--   voice:IsTransmitting() -> whether he holds the talk key of the radio
--   voice:TalkRadio(on)    the talk key of the radio pressed (true) or released
--   voice:Lines()          -> what the HUD shows: { text, color } from the top
--
-- Listens: gm.PlayerStartVoice and gm.PlayerEndVoice (answers true: no base panel),
--          gm.HUDPaint, i18n.changed; the components voice and radio.

local M = NC.Module("voice")

local IsValid = IsValid
local LocalPlayer = LocalPlayer
local CurTime = CurTime
local ScrW = ScrW
local ScrH = ScrH
local ipairs = ipairs
local min = math.min
local remove = table.remove

local FONT = "NC.Voice"
local WHITE = Color(235, 235, 235)
local DIM = Color(170, 170, 170)
local RADIO = Color(140, 220, 140)
local OUTLINE = Color(0, 0, 0, 200)
local LINE = 22
local RIGHT = 24       -- px from the right edge
local MAX_SHOWN = 6    -- talkers on the screen, then "and n more"
local SHOW_CHANGE = 3  -- s the own voice stays on the screen after a change
local HUD_TIME = 0.5   -- s the lines are kept (the names others see may change)

surface.CreateFont(FONT, { font = "Roboto", size = 19, weight = 500, extended = true })

function M:_InitClient(ctx)
	self.players = ctx:Require("players")
	self.notices = ctx:Require("notices")
	self.talking = {}      -- ply -> true while he talks (heard here)
	self.order = {}        -- the talkers in the order they began
	self.me = false        -- the local player talks
	self.transmitting = false
	self.changedAt = nil   -- CurTime of the last change of the own voice or radio
	self.known = nil       -- the own mode and radio seen last: { mode, frequency, on }
	self.cache = nil       -- { expires, lines }
	ctx.commands:Add("+nc_radio", { help = "talk into your radio while the key is held" }, function()
		self:TalkRadio(true)
	end)
	ctx.commands:Add("-nc_radio", { help = "stop talking into the radio" }, function()
		self:TalkRadio(false)
	end)
	local menu = ctx:Require("menu")
	if menu ~= nil then
		menu:AddHelp("voice.talk", { bind = "+voicerecord", text = "voice.help.talk", order = 86,
			params = function() return { mode = self:_ModeName(self:Mode()) } end })
		menu:AddHelp("voice.radio", { bind = "+nc_radio", text = "voice.help.radio", order = 87 })
		menu:AddHelp("voice.mode", { bind = "nc_voice cycle", text = "voice.help.mode", order = 88 })
	end
end

function M:_StartClient(ctx)
	ctx:On("gm.PlayerStartVoice", "OnStartVoice")
	ctx:On("gm.PlayerEndVoice", "OnEndVoice")
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("i18n.changed", "_Dirty")
	ctx.components.voice:OnChange("OnVoice")
	ctx.components.radio:OnChange("OnRadio")
end

function M:_Dirty()
	self.cache = nil
end

-- Talkers -----------------------------------------------------------------------------------

function M:OnStartVoice(ply)
	if IsValid(ply) then
		if ply == LocalPlayer() then
			self.me = true
		elseif not self.talking[ply] then
			self.talking[ply] = true
			self.order[#self.order + 1] = ply
		end
		self.cache = nil
	end
	return true
end

function M:OnEndVoice(ply)
	if ply == LocalPlayer() then
		self.me = false
	elseif self.talking[ply] then
		self.talking[ply] = nil
		for i, other in ipairs(self.order) do
			if other == ply then
				remove(self.order, i)
				break
			end
		end
	end
	self.cache = nil
	return true
end

function M:Talkers()
	local out = {}
	for i = #self.order, 1, -1 do
		if not IsValid(self.order[i]) then
			self.talking[self.order[i]] = nil
			remove(self.order, i)
		end
	end
	for i, ply in ipairs(self.order) do
		out[i] = ply
	end
	return out
end

function M:IsTalking()
	return self.me
end

-- The own voice and radio ---------------------------------------------------------------------

function M:Mode(ply)
	ply = ply or LocalPlayer()
	local data = IsValid(ply) and self.ctx.components.voice:Get(ply) or nil
	return data ~= nil and data.mode or "normal"
end

function M:_ModeName(mode)
	return self.ctx.i18n:T("voice.mode." .. mode)
end

function M:Radio()
	local me = LocalPlayer()
	local data = IsValid(me) and self.ctx.components.radio:Get(me) or nil
	if data == nil or data.frequency == 0 then
		return nil
	end
	return { frequency = data.frequency, on = data.on }
end

function M:IsTransmitting()
	return self.transmitting
end

-- The own voice or radio changed: shown for a moment (not when they first arrive).
function M:_Check()
	local radio = self:Radio()
	local now = { mode = self:Mode(), frequency = radio and radio.frequency, on = radio ~= nil and radio.on }
	local known = self.known
	if known ~= nil and (known.mode ~= now.mode or known.frequency ~= now.frequency or known.on ~= now.on) then
		self.changedAt = CurTime()
	end
	self.known = now
	self.cache = nil
end

function M:OnVoice(index)
	local me = LocalPlayer()
	if IsValid(me) and index == me:EntIndex() then
		self:_Check()
	else
		self.cache = nil
	end
end

function M:OnRadio()
	self:_Check()
end

local function microphone(on)
	local lib = permissions
	if lib ~= nil and lib.EnableVoiceChat ~= nil then
		lib.EnableVoiceChat(on)
	end
end

function M:TalkRadio(on)
	if on then
		local radio = self:Radio()
		local problem = radio == nil and "none" or not radio.on and "off" or nil
		if problem ~= nil then
			if self.notices ~= nil then
				self.notices:Show("voice.fail." .. problem, nil, "bad")
			end
			return
		end
		if self.transmitting then
			return
		end
		self.transmitting = true
		self.ctx.net:SendToServer("ptt", { on = true })
		microphone(true)
	elseif self.transmitting then
		self.transmitting = false
		self.ctx.net:SendToServer("ptt", { on = false })
		microphone(false)
	end
	self.cache = nil
end

-- The HUD -----------------------------------------------------------------------------------

function M:_TalkerLine(ply)
	local i18n = self.ctx.i18n
	local data = self.ctx.components.voice:Get(ply)
	local text = self.players:Name(ply)
	if data ~= nil and data.radio then
		return { text = text .. " · " .. i18n:T("voice.hud.radio"), color = RADIO }
	end
	if data ~= nil and data.mode ~= "normal" then
		text = text .. " · " .. self:_ModeName(data.mode)
	end
	return { text = text, color = WHITE }
end

function M:Lines()
	local cache = self.cache
	if cache ~= nil and CurTime() < cache.expires then
		return cache.lines
	end
	local i18n = self.ctx.i18n
	local lines = {}
	local talkers = self:Talkers()
	for i, ply in ipairs(talkers) do
		if i > MAX_SHOWN then
			lines[#lines + 1] = { text = i18n:T("voice.hud.more", { count = #talkers - MAX_SHOWN }), color = DIM }
			break
		end
		lines[#lines + 1] = self:_TalkerLine(ply)
	end
	local changed = self.changedAt ~= nil and CurTime() - self.changedAt < SHOW_CHANGE
	local radio = self:Radio()
	if self.transmitting and radio ~= nil then
		lines[#lines + 1] = { text = i18n:T("voice.hud.transmit", { frequency = radio.frequency }), color = RADIO }
	elseif self.me or changed then
		lines[#lines + 1] = { text = i18n:T("voice.hud.own", { mode = self:_ModeName(self:Mode()) }),
			color = self.me and WHITE or DIM }
	end
	if changed and radio ~= nil and not self.transmitting then
		lines[#lines + 1] = { text = i18n:T(radio.on and "voice.hud.radio_on" or "voice.hud.radio_off",
			{ frequency = radio.frequency }), color = DIM }
	end
	local expires = CurTime() + HUD_TIME
	if changed then
		expires = min(expires, self.changedAt + SHOW_CHANGE)
	end
	self.cache = { expires = expires, lines = lines }
	return lines
end

function M:Paint()
	local lines = self:Lines()
	if lines[1] == nil then
		return
	end
	local x, y = ScrW() - RIGHT, ScrH() * 0.5
	for _, line in ipairs(lines) do
		draw.SimpleTextOutlined(line.text, FONT, x, y, line.color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP, 1, OUTLINE)
		y = y + LINE
	end
end
