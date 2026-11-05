-- Chat, shared part: the channels and how a typed line names one.
--
--   chat.CHANNELS       the channels of lines (the order of the net enum)
--   chat.IC             channel -> true for those in character: say, whisper, yell, me, it, team
--   chat.ALIASES        the word after "/" -> what the line is: whisper (/w), yell (/y), me, it,
--                       ooc, looc, pm, reply (/r)
--   chat.Parse(text)    -> what, rest, word for a cleaned line: "//text" ooc, ".//text" looc,
--                       "/w text" an alias, "/word args" a command (what = "command", word in
--                       lower case), anything else say
--   chat.Clean(text)    -> the line without control characters and the spaces at its ends
--   chat.Length(text)   -> its characters (UTF-8)
--   chat.Fold(text)     -> lower case (Latin and Cyrillic) to compare names
--   chat.Words(text)    -> the arguments of a command: words, "quoted words" stay together
--   chat.Cut(text, n)   -> at most n bytes without splitting a character

local M = NC.Module("chat")

local tostring = tostring
local byte = string.byte
local char = string.char
local sub = string.sub
local find = string.find
local lower = string.lower

M.CHANNELS = { "say", "whisper", "yell", "me", "it", "ooc", "looc", "pm", "pmto", "team", "info" }
M.IC = { say = true, whisper = true, yell = true, me = true, it = true, team = true }
M.ALIASES = {
	w = "whisper", whisper = "whisper",
	y = "yell", yell = "yell",
	me = "me", it = "it",
	ooc = "ooc", looc = "looc",
	pm = "pm", r = "reply", reply = "reply",
}
M.MAX_TEXT = 800 -- bytes of a line (the net)

function M:Init(ctx)
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		self:_StartServer(ctx)
	end
end

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.Clean(text)
	local spaced = tostring(text or ""):gsub("%c", " ")
	return trim(spaced)
end

function M.Length(text)
	local _, count = tostring(text or ""):gsub("[^\128-\191]", "")
	return count
end

-- Upper case Cyrillic (А-Я, Ё: bytes 208 144-175, 208 129) to lower case.
local function lowerCyrillic(letter)
	local code = byte(letter, 2)
	if code == 129 then
		return "\209\145"
	end
	if code < 160 then
		return "\208" .. char(code + 32)
	end
	return "\209" .. char(code - 32)
end

function M.Fold(text)
	return (lower(tostring(text or "")):gsub("\208[\129\144-\175]", lowerCyrillic))
end

function M.Cut(text, size)
	if #text <= size then
		return text
	end
	local stop = size
	while stop > 0 do
		local b = byte(text, stop + 1)
		if b == nil or b < 0x80 or b >= 0xC0 then
			break
		end
		stop = stop - 1
	end
	return sub(text, 1, stop)
end

function M.Parse(text)
	if sub(text, 1, 2) == "//" then
		return "ooc", trim(sub(text, 3))
	end
	if sub(text, 1, 3) == ".//" then
		return "looc", trim(sub(text, 4))
	end
	local word, rest = text:match("^/(%S+)%s*(.*)$")
	if word == nil then
		return "say", text
	end
	word = lower(word)
	local alias = M.ALIASES[word]
	if alias ~= nil then
		return alias, rest
	end
	return "command", rest, word
end

function M.Words(text)
	local out = {}
	local i, n = 1, #text
	while i <= n do
		local c = sub(text, i, i)
		if c == " " then
			i = i + 1
		elseif c == "\"" then
			local close = find(text, "\"", i + 1, true) or n + 1
			out[#out + 1] = sub(text, i + 1, close - 1)
			i = close + 1
		else
			local stop = find(text, " ", i, true) or n + 1
			out[#out + 1] = sub(text, i, stop - 1)
			i = stop
		end
	end
	return out
end
