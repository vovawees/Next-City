-- Notices, client part: toasts at the top right, newest on top, and chat lines.
--
-- Show(key, params, kind, opts) shows a notice of this client (client modules use it
-- for their own messages); the server's notices arrive the same way. Texts are
-- translated when they arrive and again when the language changes, never per frame.
--
-- Listens: gm.HUDPaint, i18n.changed.
-- Emits:   notices.shown (key, params, kind, text)  client

local M = NC.Module("notices")

local CurTime = CurTime
local ScrW = ScrW
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local min = math.min
local remove = table.remove

local FONT = "NC.Notice"
local FADE = 0.5 -- s of fading out at the end
local TOP = 96   -- px from the top of the screen
local GAP = 6
local PAD = 8

M.COLORS = {
	info = Color(235, 235, 235),
	good = Color(120, 220, 120),
	warn = Color(240, 200, 80),
	bad = Color(235, 90, 80),
}

surface.CreateFont(FONT, { font = "Roboto", size = 20, weight = 500, extended = true })

function M:Init(ctx)
	self.list = {} -- { key, params, kind, text, at, color, back }, oldest first
	ctx.net:Receive("notice", "OnNotice")
end

function M:Start(ctx)
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("i18n.changed", "Retranslate")
end

local function decode(list)
	local params = {}
	for _, entry in ipairs(list) do
		if entry.kind == "number" then
			params[entry.name] = tonumber(entry.value) or 0
		elseif entry.kind == "key" then
			params[entry.name] = { key = entry.value }
		else
			params[entry.name] = entry.value
		end
	end
	return params
end

function M:OnNotice(data)
	self:Show(data.key, decode(data.params), data.kind, { chat = data.chat })
end

function M:_Text(key, params)
	local i18n = self.ctx.i18n
	if i18n:Has(key) then
		return i18n:T(key, params)
	end
	return tostring(key)
end

-- Shows a notice (see the top of the file); returns its text.
function M:Show(key, params, kind, opts)
	kind = M.COLORS[kind] ~= nil and kind or "info"
	local color = M.COLORS[kind]
	local text = self:_Text(key, params)
	local list = self.list
	list[#list + 1] = { key = key, params = params, kind = kind, text = text, at = CurTime(),
		color = Color(color.r, color.g, color.b), back = Color(0, 0, 0, 170) }
	while #list > self.ctx.config.max do
		remove(list, 1)
	end
	if opts ~= nil and opts.chat then
		chat.AddText(color, text)
	end
	self.ctx.events:Emit("notices.shown", key, params, kind, text)
	return text
end

-- The notices on the screen, oldest first (do not modify).
function M:Active()
	local list, now, duration = self.list, CurTime(), self.ctx.config.duration
	while list[1] ~= nil and now - list[1].at >= duration do
		remove(list, 1)
	end
	return list
end

function M:Retranslate()
	for _, entry in ipairs(self.list) do
		entry.text = self:_Text(entry.key, entry.params)
	end
end

function M:Paint()
	local list = self:Active()
	if list[1] == nil then
		return
	end
	local now, duration = CurTime(), self.ctx.config.duration
	local right = ScrW() - 24
	local y = TOP
	surface.SetFont(FONT)
	for i = #list, 1, -1 do
		local entry = list[i]
		local alpha = min(1, (entry.at + duration - now) / FADE)
		local w, h = surface.GetTextSize(entry.text)
		entry.back.a = 170 * alpha
		entry.color.a = 255 * alpha
		draw.RoundedBox(4, right - w - PAD * 2, y, w + PAD * 2, h + PAD, entry.back)
		draw.SimpleText(entry.text, FONT, right - PAD, y + PAD / 2, entry.color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_TOP)
		y = y + h + PAD + GAP
	end
end
