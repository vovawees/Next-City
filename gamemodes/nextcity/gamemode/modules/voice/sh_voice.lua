-- Voice, shared part: the modes of the voice and the verb of radios.
--
--   voice.MODES          the modes in their order (the cycle): whisper, normal, yell
--   voice.Next(mode)     -> the mode after it in the cycle (yell -> whisper)
--   voice.IsMode(mode)   -> whether it is one of the modes
--   voice:RadioTrait(id) -> the trait radio of an item ({ range }), or nil: not a radio
--
-- With the module inventory the verb radio (the menu of the inventory screen) switches a
-- radio the player carries on or off.

local M = NC.Module("voice")

local ipairs = ipairs

M.MODES = { "whisper", "normal", "yell" }

local NEXT, KNOWN = {}, {}
for i, mode in ipairs(M.MODES) do
	NEXT[mode] = M.MODES[i % #M.MODES + 1]
	KNOWN[mode] = true
end

function M.Next(mode)
	return NEXT[mode] or M.MODES[1]
end

function M.IsMode(mode)
	return KNOWN[mode] == true
end

function M:Init(ctx)
	self.inventory = ctx:Require("inventory")
	if self.inventory ~= nil then
		self.inventory:RegisterVerb("radio", { label = "voice.verb.radio", order = 20,
			Applies = function(_, def, where)
				return where == "own" and def.traits.radio ~= nil
			end })
	end
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		self:_StartServer(ctx)
	else
		self:_StartClient(ctx)
	end
end

function M:RadioTrait(id)
	local inventory = self.inventory
	if inventory == nil then
		return nil
	end
	return inventory:Trait(id, "radio")
end
