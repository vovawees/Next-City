-- Organism, client part: the body of the local player.
--
-- Only the owner gets the vitals. Capabilities are decoded from them like on the server,
-- so prediction (movement, weapons) reads the same values. While unconscious the player
-- may give up with the reload key once the server would allow it.
--
-- Listens: component vitals, gm.PlayerBindPress.
-- Emits:   organism.vitals (ply, vitals, mask)   vitals arrived (vitals nil: removed)
--          organism.capabilities (ply, caps)     what the body can do changed (nil: no body)

local M = NC.Module("organism")

local CurTime = CurTime
local IsValid = IsValid
local LocalPlayer = LocalPlayer

function M:Init(ctx)
	self.vitals = nil
	self.caps = nil
	ctx.components.vitals:OnChange("OnVitals")
end

function M:Start(ctx)
	ctx:On("gm.PlayerBindPress", "OnBindPress")
	local ply = LocalPlayer()
	if IsValid(ply) then
		local data = ctx.components.vitals:Get(ply)
		if data ~= nil then
			self:OnVitals(ply:EntIndex(), data, 0)
		end
	end
end

function M:OnVitals(index, data, mask)
	local ply = LocalPlayer()
	if not IsValid(ply) or index ~= ply:EntIndex() then
		return
	end
	local events = self.ctx.events
	if data == nil then
		self.vitals, self.caps, self.capsBits, self.speed = nil, nil, nil, nil
		events:Emit("organism.vitals", ply, nil, 0)
		events:Emit("organism.capabilities", ply, nil)
		return
	end
	self.vitals = data
	self.caps = M.DecodeCapabilities(data, self.caps)
	events:Emit("organism.vitals", ply, data, mask)
	if data.caps ~= self.capsBits or data.speed ~= self.speed then
		self.capsBits, self.speed = data.caps, data.speed
		events:Emit("organism.capabilities", ply, self.caps)
	end
end

local function isLocal(ply)
	return ply == nil or ply == LocalPlayer()
end

-- What the body of the local player can do (see sh_organism.lua), or nil. Clients know
-- only their own body. Do not modify.
function M:Capabilities(ply)
	return isLocal(ply) and self.caps or nil
end

-- The vitals of the local player, or nil. Do not modify.
function M:Vitals(ply)
	return isLocal(ply) and self.vitals or nil
end

function M:IsUnconscious(ply)
	local caps = self:Capabilities(ply)
	return caps ~= nil and caps.unconscious
end

-- Seconds until the local player may give up (0: now), or nil if they may not.
function M:SuccumbIn()
	local vitals = self.vitals
	local delay = self.ctx.config.succumbDelay
	if vitals == nil or vitals.since <= 0 or delay < 0 then
		return nil
	end
	local left = vitals.since + delay - CurTime()
	return left > 0 and left or 0
end

-- Unconscious: the reload key gives up (the movement module takes the other keys away).
function M:OnBindPress(ply, bind, pressed)
	if not pressed or bind:find("+reload", 1, true) == nil or not self:IsUnconscious(ply) then
		return
	end
	if self:SuccumbIn() == 0 then
		self.ctx.net:SendToServer("succumb", {})
	end
	return true
end
