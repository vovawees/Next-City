-- Voice, server part.
--
--   voice:Hears(listener, talker) -> false, true (heard flat: by radio, from the dead, where
--                           voices are global) or "3d" (from where the talker is): the matrix now
--   voice:Rebuild()         who hears whom, now (by itself every refresh s)
--   voice:Proximity(ply)    -> whether his voice is heard by distance (voice.proximity)
--   voice:Mode(ply)         -> the mode of his voice: whisper, normal or yell
--   voice:SetMode(ply, mode) -> true or false, reason (mode: no such mode)
--   voice:Range(ply)        -> units his voice carries now, nil: everywhere
--   voice:Radio(ply)        -> the radio he carries (the first item with the trait radio), or nil
--   voice:Frequency(ply)    -> the frequency of his radio when it is on, or nil
--   voice:Tune(ply, frequency) -> true or false, reason (none, frequency)
--   voice:Switch(ply, on, item) -> true or false, reason (none): his radio (or that item) on or
--                           off, the other way when on is nil
--   voice:Transmit(ply, on) -> true or false, reason (none, off): the talk key of the radio
--   voice:IsTransmitting(ply) -> whether his voice goes into his radio now
--
-- Who hears whom. Nobody hears the unconscious or those voice.canTalk denies; the unconscious
-- hear nothing. Where voices are local (voice.proximity of the talker) the living are heard
-- in 3D within the range of their mode, and flat on every radio that is on at the frequency
-- of theirs while they hold its talk key (within the range of the radio, 0: everywhere); the
-- dead are heard by those who are not alive, anywhere. Where voices are global everybody
-- hears everybody, flat; in team play only the team (teamOnly) unless sv_alltalk is 1 or
-- more. The rules of rounds answer gm.PlayerCanHearPlayersVoice before (dead_mute: the
-- living do not hear the dead), modes may too (a priority above -10). The engine asks many
-- times a tick: the answers come from a matrix rebuilt every refresh s, the column of a
-- talker at once when his talk key changes.
--
-- Radios are items with the trait radio ({ range = units }) of the inventory; their state:
-- frequency (default config.frequency), off (switched off) and label (the frequency on the
-- screen, in brackets when off). Only the first radio a player carries counts.
--
-- Listens:  players.ready, players.left, inventory.changed; answers gm.PlayerCanHearPlayersVoice
--           (priority -10). Net: ptt (the talk key, from the client).
-- Asks:     voice.proximity (ply) -> true: by distance, false: global (default config.proximity);
--           voice.canTalk (ply) -> false: nobody hears him.
-- Emits:    voice.mode (ply, mode, old), voice.radio (ply, frequency, on): tuned or switched.
-- Commands: nc_voice [whisper|normal|yell|cycle], nc_radio [frequency|on|off] (everybody).

local M = NC.Module("voice")

local IsValid = IsValid
local GetConVar = GetConVar
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local floor = math.floor
local format = string.format
local lower = string.lower

local AROUND, FLAT = 1, 2 -- how a listener hears a talker in the matrix
local HEAR_PRIORITY = -10
local REASONS = {
	mode = "no such mode: whisper, normal, yell or cycle",
	none = "you carry no radio",
	off = "your radio is off: nc_radio on",
}

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.teams = ctx:Require("teams")
	self.notices = ctx:Require("notices")
	self.matrix = {}       -- listener -> { [talker] = AROUND or FLAT }
	self.facts = {}        -- ply -> what the matrix knows of him (the last rebuild)
	self.radios = {}       -- ply -> his radio, false: none (nil: to be looked for)
	self.transmitting = {} -- ply -> true while he holds the talk key of the radio
	ctx.commands:Add("nc_voice", { help = "[whisper|normal|yell|cycle] - the mode of your voice", admin = false },
		"VoiceCommand")
	ctx.commands:Add("nc_radio", { help = "[frequency|on|off] - your radio", admin = false }, "RadioCommand")
	if self.inventory ~= nil then
		self.inventory:HandleVerb("radio", function(ply, item)
			return self:_Tell(ply, self:Switch(ply, nil, item))
		end)
	end
end

function M:_StartServer(ctx)
	ctx:On("players.ready", "OnReady")
	ctx:On("players.left", "OnLeft")
	ctx:On("gm.PlayerCanHearPlayersVoice", "Hears", { priority = HEAR_PRIORITY })
	if self.inventory ~= nil then
		ctx:On("inventory.changed", "OnInventory")
	end
	ctx.net:Receive("ptt", "OnTalkKey")
	ctx:Every("matrix", ctx.config.refresh, "Rebuild")
	for _, ply in ipairs(self.players:ReadyPlayers()) do
		self:OnReady(ply)
	end
end

function M:OnReady(ply)
	local voice = self.ctx.components.voice
	if not voice:Has(ply) then
		local mode = self.ctx.config.mode
		voice:Add(ply, { mode = M.IsMode(mode) and mode or "normal" })
	end
	self.radios[ply] = nil
end

function M:OnLeft(ply)
	self.matrix[ply], self.facts[ply], self.radios[ply], self.transmitting[ply] = nil, nil, nil, nil
	for _, row in pairs(self.matrix) do
		row[ply] = nil
	end
end

-- The things of a player changed: his radio is looked for again.
function M:OnInventory(_, owner)
	if owner ~= nil then
		self.radios[owner] = nil
	end
end

function M:_Tell(ply, ok, reason)
	if not ok and reason ~= nil and self.notices ~= nil then
		self.notices:Send(ply, "voice.fail." .. reason, { max = self.ctx.config.maxFrequency }, "bad")
	end
	return ok == true
end

-- Modes --------------------------------------------------------------------------------------

function M:Proximity(ply)
	local answer = self.ctx.events:Query("voice.proximity", ply)
	if answer ~= nil then
		return answer == true
	end
	return self.ctx.config.proximity == true
end

function M:Mode(ply)
	local data = self.ctx.components.voice:Get(ply)
	return data ~= nil and data.mode or self.ctx.config.mode
end

function M:SetMode(ply, mode)
	if not M.IsMode(mode) then
		return false, "mode"
	end
	local voice = self.ctx.components.voice
	if not voice:Has(ply) then
		self:OnReady(ply)
	end
	local old = voice:Get(ply).mode
	if old ~= mode then
		voice:Set(ply, "mode", mode)
		self.ctx.events:Emit("voice.mode", ply, mode, old)
	end
	return true
end

function M:Range(ply)
	if not self:Proximity(ply) then
		return nil
	end
	return self.ctx.config[self:Mode(ply) .. "Range"]
end

-- Radios ------------------------------------------------------------------------------------

function M:_FrequencyOf(item)
	local state = item.state
	local frequency = state ~= nil and tonumber(state.frequency) or nil
	return frequency or self.ctx.config.frequency
end

local function isOn(item)
	return item.state == nil or item.state.off ~= true
end

-- The state of a radio as the screen shows it: the frequency, in brackets when it is off.
function M:_Label(item)
	local state = item.state
	if state == nil then
		state = {}
		item.state = state
	end
	local frequency = self:_FrequencyOf(item)
	local label = isOn(item) and tostring(frequency) or format("(%d)", frequency)
	if state.frequency ~= frequency or state.label ~= label then
		state.frequency, state.label = frequency, label
		self.inventory:Touch(item)
	end
end

-- Looks for the radio of a player and tells his client about it.
function M:_Scan(ply)
	local found = false
	local inventory = self.inventory
	if inventory ~= nil and IsValid(ply) then
		for _, item in ipairs(inventory:ItemsOf(ply)) do
			if self:RadioTrait(item.id) ~= nil then
				found = item
				break
			end
		end
	end
	self.radios[ply] = found
	if found then
		self:_Label(found)
	end
	self:_Sync(ply)
	return found or nil
end

-- The components of a player after a change of his radio or his talk key.
function M:_Sync(ply)
	local components = self.ctx.components
	local radio, item = components.radio, self.radios[ply]
	if item then
		local values = { frequency = self:_FrequencyOf(item), on = isOn(item) }
		if radio:Has(ply) then
			radio:Patch(ply, values)
		else
			radio:Add(ply, values)
		end
	elseif radio:Has(ply) then
		radio:Remove(ply)
	end
	if components.voice:Has(ply) then
		components.voice:Set(ply, "radio", self:IsTransmitting(ply))
	end
end

function M:Radio(ply)
	local item = self.radios[ply]
	if item and self.inventory:Instance(item.uid) ~= item then
		item = nil
	end
	if item == nil then
		item = self:_Scan(ply)
	end
	return item or nil
end

function M:Frequency(ply)
	local item = self:Radio(ply)
	if item == nil or not isOn(item) then
		return nil
	end
	return self:_FrequencyOf(item)
end

function M:IsTransmitting(ply)
	return self.transmitting[ply] == true and self:Frequency(ply) ~= nil
end

function M:_Changed(ply, item)
	self:_Label(item)
	if item == self.radios[ply] then
		self:_Sync(ply)
		self:_Refresh(ply)
	end
	local frequency, on = self:_FrequencyOf(item), isOn(item)
	if self.notices ~= nil then
		self.notices:Send(ply, on and "voice.radio.on" or "voice.radio.off", { frequency = frequency }, "info")
	end
	self.ctx.events:Emit("voice.radio", ply, frequency, on)
end

function M:Tune(ply, frequency)
	local item = self:Radio(ply)
	if item == nil then
		return false, "none"
	end
	frequency = tonumber(frequency)
	if frequency == nil or frequency ~= floor(frequency) or frequency < 1
		or frequency > self.ctx.config.maxFrequency then
		return false, "frequency"
	end
	item.state = item.state or {}
	item.state.frequency = frequency
	self:_Changed(ply, item)
	return true
end

function M:Switch(ply, on, item)
	item = item or self:Radio(ply)
	if item == nil then
		return false, "none"
	end
	if on == nil then
		on = not isOn(item)
	end
	item.state = item.state or {}
	item.state.off = not on or nil
	self:_Changed(ply, item)
	return true
end

function M:Transmit(ply, on)
	on = on == true
	if on then
		local item = self:Radio(ply)
		if item == nil then
			return false, "none"
		end
		if not isOn(item) then
			return false, "off"
		end
	end
	if (self.transmitting[ply] == true) ~= on then
		self.transmitting[ply] = on or nil
		self:_Sync(ply)
		self:_Refresh(ply)
	end
	return true
end

function M:OnTalkKey(data, ply)
	self:_Tell(ply, self:Transmit(ply, data.on))
end

-- The matrix -------------------------------------------------------------------------------

-- Fills what the matrix needs to know of a player; teamOnly: global voices stay in teams.
function M:_Fill(ply, facts, teamOnly)
	local cfg, events = self.ctx.config, self.ctx.events
	local pos = ply:GetPos()
	facts.x, facts.y, facts.z = pos.x, pos.y, pos.z
	local organism = self.organism
	local awake = organism == nil or organism:IsUnconscious(ply) ~= true
	local alive = self.players:IsAlive(ply)
	facts.awake, facts.alive = awake, alive
	facts.talks = awake and events:Query("voice.canTalk", ply) ~= false
	facts.proximity = self:Proximity(ply)
	local range = cfg[self:Mode(ply) .. "Range"] or cfg.normalRange
	facts.range2 = range * range
	facts.team = teamOnly and ply:Team() or nil
	local frequency = self:Frequency(ply)
	if not alive or not awake then
		frequency = nil
	end
	facts.rx = frequency
	facts.tx, facts.txRange2 = nil, nil
	if frequency ~= nil and self.transmitting[ply] then
		facts.tx = frequency
		local trait = self:RadioTrait(self.radios[ply].id)
		local reach = trait ~= nil and tonumber(trait.range) or cfg.radioRange
		facts.txRange2 = reach > 0 and reach * reach or nil
	end
	return facts
end

-- How listener l hears talker t (their facts): nil, AROUND or FLAT.
local function how(t, l)
	if not t.talks or not l.awake then
		return nil
	end
	if not t.proximity then
		if t.team ~= nil and l.team ~= t.team then
			return nil
		end
		return FLAT
	end
	if not t.alive then
		return not l.alive and FLAT or nil
	end
	local dx, dy, dz = t.x - l.x, t.y - l.y, t.z - l.z
	local distance2 = dx * dx + dy * dy + dz * dz
	if distance2 <= t.range2 then
		return AROUND
	end
	local frequency = t.tx
	if frequency ~= nil and l.rx == frequency and (t.txRange2 == nil or distance2 <= t.txRange2) then
		return FLAT
	end
	return nil
end

function M:_TeamOnly()
	local teams = self.teams
	if not self.ctx.config.teamOnly or teams == nil or teams:Count() == 0 then
		return false
	end
	local alltalk = GetConVar("sv_alltalk")
	return alltalk == nil or alltalk:GetInt() < 1
end

function M:Rebuild()
	local list = self.players:ReadyPlayers()
	local facts, matrix = self.facts, self.matrix
	local teamOnly = self:_TeamOnly()
	local seen = {}
	for _, ply in ipairs(list) do
		seen[ply] = true
		facts[ply] = self:_Fill(ply, facts[ply] or {}, teamOnly)
	end
	for ply in pairs(facts) do
		if not seen[ply] then
			facts[ply], matrix[ply] = nil, nil
		end
	end
	for _, listener in ipairs(list) do
		local row = matrix[listener]
		if row == nil then
			row = {}
			matrix[listener] = row
		else
			for talker in pairs(row) do
				row[talker] = nil
			end
		end
		local l = facts[listener]
		for _, talker in ipairs(list) do
			if talker ~= listener then
				row[talker] = how(facts[talker], l)
			end
		end
	end
end

-- The row and the column of a player at once (his radio or its talk key changed).
function M:_Refresh(ply)
	local facts, matrix = self.facts, self.matrix
	local own = facts[ply]
	if own == nil then
		return
	end
	self:_Fill(ply, own, self:_TeamOnly())
	local row = matrix[ply]
	for other, theirs in pairs(matrix) do
		if other ~= ply then
			local them = facts[other]
			theirs[ply] = how(own, them)
			row[other] = how(them, own)
		end
	end
end

function M:Hears(listener, talker)
	local row = self.matrix[listener]
	local heard = row ~= nil and row[talker] or nil
	if heard == AROUND then
		return "3d"
	end
	return heard == FLAT
end

-- Commands -----------------------------------------------------------------------------------

function M:_VoiceLines(ply)
	local cfg = self.ctx.config
	local lines = {}
	if ply == nil and cfg.proximity or ply ~= nil and self:Proximity(ply) then
		lines[1] = format("voice: by distance; whisper %d, normal %d, yell %d units", cfg.whisperRange,
			cfg.normalRange, cfg.yellRange)
	else
		lines[1] = "voice: everywhere" .. (self:_TeamOnly() and ", in the team" or "")
	end
	if ply ~= nil then
		local range = self:Range(ply)
		lines[2] = format("your voice: %s (%s)", self:Mode(ply), range ~= nil and range .. " units" or "everywhere")
	end
	return lines
end

-- The mode of the voice: nc_voice [whisper|normal|yell|cycle] (everybody).
function M:VoiceCommand(caller, args)
	if not IsValid(caller) then
		return self:_VoiceLines(nil)
	end
	local wanted = args[1] ~= nil and lower(args[1]) or nil
	if wanted == nil then
		return self:_VoiceLines(caller)
	end
	if wanted == "cycle" then
		wanted = M.Next(self:Mode(caller))
	end
	local ok, reason = self:SetMode(caller, wanted)
	if not ok then
		return "nc_voice: " .. REASONS[reason]
	end
	return self:_VoiceLines(caller)[2]
end

function M:_RadioLine(ply)
	local item = self:Radio(ply)
	if item == nil then
		return "radio: none"
	end
	return format("radio: %d, %s", self:_FrequencyOf(item), isOn(item) and "on" or "off")
end

-- The radio: nc_radio [frequency|on|off] (everybody).
function M:RadioCommand(caller, args)
	if not IsValid(caller) then
		return "nc_radio: for players"
	end
	local wanted = args[1] ~= nil and lower(args[1]) or nil
	if wanted == nil then
		return self:_RadioLine(caller)
	end
	local ok, reason
	if wanted == "on" or wanted == "off" then
		ok, reason = self:Switch(caller, wanted == "on")
	else
		ok, reason = self:Tune(caller, wanted)
	end
	if not ok then
		if reason == "frequency" then
			return format("nc_radio: frequencies are 1-%d", self.ctx.config.maxFrequency)
		end
		return "nc_radio: " .. REASONS[reason]
	end
	return self:_RadioLine(caller)
end
