-- Chat, the client: the lines of the channels in the chat box — the name others see in the
-- color of his team, the tags of the channels in the language of the player, the text through
-- the filter of the game (util.FilterText, as the base chat does) — and the chat of the help of
-- the menu (F1).
--
--   chat:Parts(line) -> the colors and the texts chat.AddText gets for a line of the net
--                       message line

local M = NC.Module("chat")

local IsValid = IsValid
local GetConVar = GetConVar
local ipairs = ipairs
local unpack = unpack

local WHITE = Color(235, 235, 235)
local COLORS = {
	dead = Color(255, 30, 40),
	team = Color(30, 160, 40),
	whisper = Color(180, 180, 180),
	yell = Color(255, 215, 140),
	me = Color(200, 170, 255),
	it = Color(150, 210, 150),
	ooc = Color(120, 170, 255),
	looc = Color(150, 200, 255),
	pm = Color(255, 170, 60),
	info = Color(170, 170, 170),
}
M.COLORS = COLORS

-- The chat of the help of the menu: the id and what the player types.
local HELP = {
	{ "whisper", "/w" }, { "yell", "/y" }, { "me", "/me" }, { "it", "/it" }, { "ooc", "//" }, { "looc", ".//" },
	{ "pm", "/pm" }, { "reply", "/r" }, { "command", "/..." },
}

local FILTER_CHAT = 64 -- the bit of cl_chatfilters: the filter of the chat instead of the game content

function M:_InitClient(ctx)
	ctx.net:Receive("line", "OnLine")
	local menu = ctx:Require("menu")
	if menu ~= nil then
		for i, entry in ipairs(HELP) do
			menu:AddHelp("chat." .. entry[1], { section = "chat", label = entry[2], text = "chat.help." .. entry[1],
				order = i * 10 })
		end
	end
end

local function filtered(text, speaker)
	local filter = util.FilterText
	if filter == nil then
		return text
	end
	local context = TEXT_FILTER_GAME_CONTENT
	local filters = GetConVar("cl_chatfilters")
	if filters ~= nil and bit.band(filters:GetInt(), FILTER_CHAT) ~= 0 then
		context = TEXT_FILTER_CHAT
	end
	return filter(text, context, IsValid(speaker) and speaker or nil)
end

function M:Parts(line)
	local i18n = self.ctx.i18n
	local channel, speaker = line.channel, line.speaker
	if channel == "info" then
		return { COLORS.info, line.text }
	end
	local text = filtered(line.text, speaker)
	if channel == "it" then
		return { COLORS.it, "** " .. text }
	end
	local parts = {}
	local function add(color, value)
		parts[#parts + 1] = color
		parts[#parts + 1] = value
	end
	if line.dead then
		add(COLORS.dead, i18n:T("chat.tag.dead") .. " ")
	end
	if channel == "me" then
		add(COLORS.me, "* " .. line.name .. " " .. text)
		return parts
	end
	local color = IsValid(speaker) and team.GetColor(speaker:Team()) or WHITE
	if channel == "team" or channel == "ooc" or channel == "looc" then
		add(COLORS[channel], i18n:T("chat.tag." .. channel) .. " ")
	elseif channel == "pm" or channel == "pmto" then
		add(COLORS.pm, i18n:T("chat.tag.pm") .. (channel == "pmto" and " → " or " "))
		color = COLORS.pm
	end
	add(color, line.name)
	if channel == "whisper" or channel == "yell" then
		add(COLORS[channel], " " .. i18n:T("chat.verb." .. channel) .. ": " .. text)
	else
		add(WHITE, ": " .. text)
	end
	return parts
end

function M:OnLine(line)
	chat.AddText(unpack(self:Parts(line)))
end
