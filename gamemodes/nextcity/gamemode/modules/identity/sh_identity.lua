-- Identity, shared part: the character others see and the rules of names.
--
--   identity:Name(ply)    -> the name of his character while others see it, or nil
--   identity:Gender(ply)  -> "male" | "female" of his character while others see it, or nil
--   identity:IsShown(ply) -> whether others see his character now (a mode turns identities on)
--   identity:NameProblem(name) -> why the rules refuse a cleaned name: short, long, chars,
--                            words; or nil
--   identity:RandomName(gender, language, taken) -> a name from the lists of the language (en
--                            without them); taken(name) -> true skips a name
--   identity:AddNames(language, { male, female, last, lastFemale }) adds names (both realms)
--   identity.CleanName(text) -> the text with single spaces inside and none at the ends
--   identity.Fold(name)   -> the name in lowercase (Latin and Cyrillic letters) to compare
--   identity.Length(name) -> the characters (UTF-8) of a name
--
-- The rules (config): minLength..maxLength characters (at most MAX_BYTES bytes), minWords..
-- maxWords words; letters of any alphabet, spaces, ' - and . inside; every word starts with
-- a letter. Answers players.name with priority 10: answers of modes (aliases) win.

local M = NC.Module("identity")

M.GENDERS = { "male", "female" }
M.MAX_BYTES = 96 -- the longest name the components and the net carry

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local random = math.random
local char = string.char
local format = string.format

local TRIES = 20
local BAD = "[^%a\128-\255 '%-%.]"
local LETTER = "^[%a\128-\255]"
local LISTS = { male = true, female = true, last = true, lastFemale = true }

-- A random integer 1..n (specs replace it).
function M.Random(n)
	return random(n)
end

function M:Init(ctx)
	self.names = {}
	for language, lists in pairs(M.NAMES) do
		self:AddNames(language, lists)
	end
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	ctx:On("players.name", "AnswerName", { priority = 10 })
	if SERVER then
		self:_StartServer(ctx)
	end
end

-- Names -------------------------------------------------------------------------------------

function M.CleanName(text)
	return (tostring(text or ""):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

-- Upper case Cyrillic (А-Я, Ё: bytes 208 144-175, 208 129) to lower case.
local function lowerCyrillic(letter)
	local code = letter:byte(2)
	if code == 129 then
		return "\209\145"
	end
	if code < 160 then
		return "\208" .. char(code + 32)
	end
	return "\209" .. char(code - 32)
end

function M.Fold(name)
	return (tostring(name or ""):lower():gsub("\208[\129\144-\175]", lowerCyrillic))
end

function M.Length(name)
	local _, count = tostring(name or ""):gsub("[^\128-\191]", "")
	return count
end

function M:NameProblem(name)
	local cfg = self.ctx.config
	local length = M.Length(name)
	if length < cfg.minLength then
		return "short"
	end
	if length > cfg.maxLength or #name > M.MAX_BYTES then
		return "long"
	end
	if name:find(BAD) then
		return "chars"
	end
	local words = 0
	for word in name:gmatch("[^ ]+") do
		if not word:find(LETTER) then
			return "chars"
		end
		words = words + 1
	end
	if words < cfg.minWords or words > cfg.maxWords then
		return "words"
	end
	return nil
end

-- Adds names to the lists of a language; female last names go with the last names by
-- position (the same form without them).
function M:AddNames(language, lists)
	assert(type(language) == "string" and language ~= "", "identity: AddNames: a language code")
	assert(type(lists) == "table", "identity: AddNames: a table of lists")
	for key, list in pairs(lists) do
		assert(LISTS[key], format("identity: AddNames: unknown list %s", tostring(key)))
		assert(type(list) == "table", format("identity: AddNames: %s is not a list", tostring(key)))
	end
	local own = self.names[language]
	if own == nil then
		own = { male = {}, female = {}, last = {}, lastFemale = {} }
		self.names[language] = own
	end
	for _, key in ipairs({ "male", "female" }) do
		for _, name in ipairs(lists[key] or {}) do
			own[key][#own[key] + 1] = name
		end
	end
	local female = lists.lastFemale or {}
	for i, last in ipairs(lists.last or {}) do
		own.last[#own.last + 1] = last
		own.lastFemale[#own.lastFemale + 1] = female[i] or last
	end
end

-- A first and a last name; when TRIES of them are taken, a double last name.
function M:RandomName(gender, language, taken)
	local lists = self.names[language]
	if lists == nil or lists.male[1] == nil or lists.female[1] == nil or lists.last[1] == nil then
		lists = self.names.en
	end
	local firsts = gender == "female" and lists.female or lists.male
	local lasts = gender == "female" and lists.lastFemale or lists.last
	local function pick(list)
		return list[M.Random(#list)]
	end
	local name
	for attempt = 1, TRIES * 2 do
		name = pick(firsts) .. " " .. pick(lasts)
		if attempt > TRIES then
			name = name .. "-" .. pick(lasts)
		end
		if taken == nil or not taken(name) then
			return name
		end
	end
	return name
end

-- Characters --------------------------------------------------------------------------------

function M:IsShown(ply)
	return self.ctx.components.identity:Has(ply)
end

function M:Name(ply)
	local shown = self.ctx.components.identity:Get(ply)
	if shown == nil or shown.name == "" then
		return nil
	end
	return shown.name
end

function M:Gender(ply)
	local shown = self.ctx.components.identity:Get(ply)
	return shown ~= nil and shown.gender or nil
end

function M:AnswerName(_, ply)
	return self:Name(ply)
end
