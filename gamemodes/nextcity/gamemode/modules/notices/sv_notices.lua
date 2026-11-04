-- Notices, server part: messages to players in their own language.
--
--   notices:Send(ply or { players }, "inventory.full", { item = { key = "items.ak47" } }, "warn")
--   notices:Broadcast("rounds.started", nil, "info", { chat = true })
--
-- key: a key of the language files (a text without a translation is shown as it is);
-- params: name -> string, number (plural forms) or { key = "..." } (translated by the
-- client); kind: "info" (default), "good", "warn", "bad"; opts.chat: a chat line too.
-- Values are cut to 128 bytes, at most 8 params.

local M = NC.Module("notices")

local type = type
local pairs = pairs
local tostring = tostring
local sort = table.sort
local byte = string.byte
local sub = string.sub

local KINDS = { info = true, good = true, warn = true, bad = true }
local MAX_PARAMS = 8
local MAX_VALUE = 128
local MAX_NAME = 24

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
M.Cut = cut

local function byName(a, b)
	return a.name < b.name
end

-- The params of a notice as the message carries them, sorted by name.
function M:Encode(params)
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

function M:_Message(key, params, kind, opts)
	return {
		key = cut(tostring(key), 64),
		kind = KINDS[kind] and kind or "info",
		chat = type(opts) == "table" and opts.chat == true,
		params = self:Encode(params),
	}
end

-- Sends a notice to a player or a list of players (see the top of the file).
function M:Send(target, key, params, kind, opts)
	if target == nil or (type(target) == "table" and target[1] == nil and not IsValid(target)) then
		return
	end
	self.ctx.net:Send("notice", target, self:_Message(key, params, kind, opts))
end

-- Sends a notice to every ready player.
function M:Broadcast(key, params, kind, opts)
	self.ctx.net:Broadcast("notice", self:_Message(key, params, kind, opts))
end
