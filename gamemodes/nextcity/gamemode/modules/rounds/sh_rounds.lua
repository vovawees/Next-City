-- Rounds module, shared part: phases, time formatting and the params of status lines.

local M = NC.Module("rounds")

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local floor = math.floor
local ceil = math.ceil
local format = string.format
local byte = string.byte
local sub = string.sub
local sort = table.sort

local MAX_PARAMS = 8
local MAX_NAME = 24
local MAX_VALUE = 128

-- waiting    not enough players for the mode (warmup)
-- preparing  a new round: participants spawned, the start is near
-- active     the round is played
-- ended      the result is shown, the next round is near
M.PHASES = { "waiting", "preparing", "active", "ended" }

-- "m:ss" for a number of seconds rounded up, "h:mm:ss" from an hour on. A hair above a
-- whole second (float noise in game time) does not show the next second.
function M.FormatTime(seconds)
	seconds = ceil(seconds - 1e-3)
	if seconds ~= seconds or seconds <= 0 then
		return "0:00"
	end
	local hours = floor(seconds / 3600)
	local minutes = floor(seconds % 3600 / 60)
	if hours > 0 then
		return format("%d:%02d:%02d", hours, minutes, seconds % 60)
	end
	return format("%d:%02d", minutes, seconds % 60)
end

-- `text` cut to `size` bytes without splitting a UTF-8 character.
local function cut(text, size)
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

local function byName(a, b)
	return a.name < b.name
end

-- Params of a status line as the message carries them, sorted by name: name -> a number
-- (plural forms), a text or { key = "..." } (translated by the client); at most 8.
function M.EncodeParams(params)
	local list = {}
	if type(params) ~= "table" then
		return list
	end
	for name, value in pairs(params) do
		if type(name) == "string" and #list < MAX_PARAMS then
			local entry = { name = cut(name, MAX_NAME) }
			if type(value) == "number" then
				entry.kind, entry.value = "number", tostring(value)
			elseif type(value) == "table" and type(value.key) == "string" then
				entry.kind, entry.value = "key", cut(value.key, MAX_VALUE)
			else
				entry.kind, entry.value = "text", cut(tostring(value), MAX_VALUE)
			end
			list[#list + 1] = entry
		end
	end
	sort(list, byName)
	return list
end

function M.DecodeParams(list)
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
