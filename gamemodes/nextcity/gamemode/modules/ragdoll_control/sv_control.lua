-- Ragdoll control, server part: a conscious player that lies in its body moves it.
--
-- config.rate times per second, for every fallen body (not unconscious, not getting up)
-- of a conscious player:
--   look   the head turns where the player looks (the eyes attachment of the body), at
--          most config.turnSpeed degrees/s and at most config.neck degrees from where it
--          faced when the body fell (as the chest lies now); looking there already, it
--          holds still;
--   crawl  the movement keys drag the chest and the pelvis along the ground in the
--          direction of the view, at config.crawl units/s with both arms (0.65 of it with
--          one, 0.3 with none, like movement); only while the chest lies on something;
--   grab   the attack keys (primary: the left hand, secondary: the right) reach the hand
--          of an arm the body can use towards what the player looks at, at most
--          config.reach units from the eyes. A hand within config.grabRange of the world
--          or of an object physics moves (not a player) holds on to it with a weld until
--          the key goes up, the arm fails, the grip breaks (config.gripForce), what it
--          holds goes or the body stops lying conscious. After a grip broke or what it
--          held went, the hand waits for another press.
--
-- Listens:  ragdoll.fell, ragdoll.stood, ragdoll.corpse.
-- Emits:    ragdoll_control.grabbed (ply, hand, ent)  hand: "left" or "right"; ent: what it
--                                                     holds, game.GetWorld() for the world
--           ragdoll_control.released (ply, hand)
-- Asks:     ragdoll_control.canGrab (ply, ent) -> false: the hand does not hold on.

local M = NC.Module("ragdoll_control")

local IsValid = IsValid
local pairs = pairs
local next = next
local min = math.min
local max = math.max
local sqrt = math.sqrt
local cos = math.cos
local sin = math.sin
local rad = math.rad
local deg = math.deg
local atan2 = math.atan2
local band = bit.band
local Vector = Vector
local TraceLine = util.TraceLine
local MOVETYPE_VPHYSICS = MOVETYPE_VPHYSICS

local CHEST = "ValveBiped.Bip01_Spine2"
-- The hands: the key that reaches with it, the capability of its arm and its bone.
local HANDS = {
	{ name = "left", key = IN_ATTACK, arm = "canUseArmL", bone = "ValveBiped.Bip01_L_Hand" },
	{ name = "right", key = IN_ATTACK2, arm = "canUseArmR", bone = "ValveBiped.Bip01_R_Hand" },
}
local ARMS = { [0] = 0.3, 0.65, 1 } -- share of the crawling speed by the arms the body can use
local GROUND = 24                  -- units below the chest within which it lies on something
local AIMED = cos(rad(3))          -- a head within 3 degrees of the view holds still
local GAIN = 8                     -- 1/s: degrees/s the head turns per degree it is off
local STILL = 1                    -- degrees/s: a head that turns slower is still
local REACH_SPEED = 300            -- units/s a hand reaches at most
local BLEND = 12                   -- 1/s: how fast the velocities follow what the control wants

local filter = {}
local trace = { filter = filter, mask = MASK_SOLID }
local below = Vector(0, 0, 0)
local push = Vector(0, 0, 0)

function M:Init(ctx)
	self.ragdoll = ctx:Require("ragdoll")
	self.organism = ctx:Require("organism")
	-- ply -> the control of its body: body, neutral (where the head faces when the body
	-- fell, in the frame of the chest), left and right (grips: weld, ent, world), spent
	-- (hand name -> true: waits for another press).
	self.states = {}
	self.eyes = {} -- model -> the id of its eyes attachment (0: none)
	self.list = {} -- the bodies of a tick
end

function M:Start(ctx)
	ctx:Every("control", 1 / max(1, ctx.config.rate), "Control")
	ctx:On("ragdoll.fell", "OnFell")
	ctx:On("ragdoll.stood", "OnGone")
	ctx:On("ragdoll.corpse", "OnGone")
end

-- The hands let go (autorefresh).
function M:Stop()
	local ply = next(self.states)
	while ply ~= nil do
		self:_Forget(ply)
		ply = next(self.states)
	end
end

-- The control of the body of `ply`, with where its head faces in the frame of its chest.
function M:_Begin(ply, body)
	local st = { body = body, neutral = nil, left = nil, right = nil, spent = {} }
	local chest = body.phys[CHEST] or body.pelvis
	local eyes = self:_Eyes(body.ent)
	if eyes ~= nil and chest ~= nil and IsValid(chest) then
		st.neutral = chest:WorldToLocalVector(eyes.Ang:Forward())
	end
	self.states[ply] = st
	return st
end

function M:_Forget(ply)
	if self.states[ply] == nil then
		return
	end
	self:Release(ply, "left")
	self:Release(ply, "right")
	self.states[ply] = nil
end

-- The eyes attachment of `rag` ({ Pos, Ang }), or nil.
function M:_Eyes(rag)
	local model = rag:GetModel() or ""
	local id = self.eyes[model]
	if id == nil then
		id = rag:LookupAttachment("eyes") or 0
		self.eyes[model] = id
	end
	if id <= 0 then
		return nil
	end
	return rag:GetAttachment(id)
end

function M:OnFell(ply)
	local body = self.ragdoll:Body(ply)
	self:_Forget(ply)
	if body ~= nil then
		self:_Begin(ply, body)
	end
end

function M:OnGone(ply)
	self:_Forget(ply)
end

-- Players and bodies are listed first: a listener of the events of the hands may make
-- others fall or get up.
function M:Control(_, dt)
	local bodies = self.ragdoll:Bodies()
	local states = self.states
	local list, n = self.list, 0
	for ply, st in pairs(states) do
		if bodies[ply] ~= st.body then
			n = n + 1
			list[n] = ply
		end
	end
	for i = 1, n do
		local ply = list[i]
		list[i] = nil
		local st = states[ply]
		if st ~= nil and bodies[ply] ~= st.body then
			self:_Forget(ply)
		end
	end
	n = 0
	for _, body in pairs(bodies) do
		n = n + 1
		list[n] = body
	end
	local config = self.ctx.config
	local blend = min(1, dt * BLEND)
	for i = 1, n do
		local body = list[i]
		list[i] = nil
		local ply = body.ply
		if bodies[ply] == body and IsValid(ply) and IsValid(body.ent) then
			self:_Control(ply, body, blend, config)
		end
	end
end

function M:_Control(ply, body, blend, config)
	local st = self.states[ply]
	if st == nil or st.body ~= body then
		self:_Forget(ply)
		st = self:_Begin(ply, body)
	end
	local caps = self.organism:Capabilities(ply)
	if body.state ~= "fallen" or caps == nil or not caps.alive or caps.unconscious then
		self:_LetGo(ply, st)
		return
	end
	local eyes = self:_Eyes(body.ent)
	if config.look and eyes ~= nil then
		self:_Look(st, ply, body, eyes, blend, config)
	end
	if config.crawl > 0 then
		self:_Crawl(ply, body, caps, blend, config)
	end
	self:_Hands(st, ply, body, caps, eyes, blend, config)
end

function M:_LetGo(ply, st)
	self:Release(ply, "left")
	self:Release(ply, "right")
	st.spent.left, st.spent.right = nil, nil
end

-- Look ------------------------------------------------------------------------------------

-- `dir` turned towards `axis` (a unit vector or nil: no limit) to be at most `limit`
-- degrees off it; nil when `dir` points straight away from it.
local function within(dir, axis, limit)
	if axis == nil then
		return dir
	end
	local c = dir:Dot(axis)
	local edge = cos(rad(limit))
	if c >= edge then
		return dir
	end
	local side = dir - axis * c
	local len = side:Length()
	if len < 1e-6 then
		return nil
	end
	return axis * edge + side * (sin(rad(limit)) / len)
end

function M:_Look(st, ply, body, eyes, blend, config)
	local head = body.head
	if head == nil or not IsValid(head) then
		return
	end
	local neutral = st.neutral
	local chest = body.phys[CHEST] or body.pelvis
	if neutral ~= nil and chest ~= nil and IsValid(chest) then
		neutral = chest:LocalToWorldVector(neutral)
	else
		neutral = nil
	end
	local aim = within(ply:GetAimVector(), neutral, config.neck)
	if aim == nil then
		return
	end
	local gaze = eyes.Ang:Forward()
	local c = gaze:Dot(aim)
	local spin = head:GetAngleVelocity()
	if c >= AIMED then
		-- Looking there already: the head holds still.
		if spin:LengthSqr() >= STILL * STILL then
			head:AddAngleVelocity(spin * -blend)
		end
		return
	end
	local axis = gaze:Cross(aim)
	local s = axis:Length()
	if s < 1e-6 then
		return
	end
	local speed = min(config.turnSpeed, deg(atan2(s, c)) * GAIN)
	local want = head:WorldToLocalVector(axis * (speed / s))
	head:AddAngleVelocity((want - spin) * blend)
end

-- Crawl -----------------------------------------------------------------------------------

-- The horizontal velocity of `phys` goes towards (x, y).
local function drag(phys, x, y, blend)
	local vel = phys:GetVelocity()
	push:SetUnpacked((x - vel.x) * blend, (y - vel.y) * blend, 0)
	phys:AddVelocity(push)
end

function M:_Crawl(ply, body, caps, blend, config)
	local input = body.input
	local forward, side = input.forward, input.side
	if forward == 0 and side == 0 then
		return
	end
	local chest = body.phys[CHEST] or body.pelvis
	if chest == nil or not IsValid(chest) then
		return
	end
	local pos = chest:GetPos()
	below:SetUnpacked(pos.x, pos.y, pos.z - GROUND)
	trace.start, trace.endpos = pos, below
	filter[1], filter[2] = ply, body.ent
	if not TraceLine(trace).Hit then
		return
	end
	local f = forward > 0 and 1 or (forward < 0 and -1 or 0)
	local r = side > 0 and 1 or (side < 0 and -1 or 0)
	local yaw = rad(ply:EyeAngles().y)
	local cy, sy = cos(yaw), sin(yaw)
	-- Forward is (cy, sy), right is (sy, -cy).
	local x, y = cy * f + sy * r, sy * f - cy * r
	local arms = (caps.canUseArmL and 1 or 0) + (caps.canUseArmR and 1 or 0)
	local speed = config.crawl * ARMS[arms] / sqrt(x * x + y * y)
	x, y = x * speed, y * speed
	drag(chest, x, y, blend)
	local pelvis = body.pelvis
	if pelvis ~= nil and pelvis ~= chest and IsValid(pelvis) then
		drag(pelvis, x, y, blend)
	end
end

-- Hands -----------------------------------------------------------------------------------

function M:_Hands(st, ply, body, caps, eyes, blend, config)
	local buttons = body.input.buttons
	local spent = st.spent
	for i = 1, #HANDS do
		local hand = HANDS[i]
		local name = hand.name
		local grip = st[name]
		if band(buttons, hand.key) == 0 or not caps[hand.arm] then
			spent[name] = nil
			if grip ~= nil then
				self:Release(ply, name)
			end
		elseif grip ~= nil then
			if not IsValid(grip.weld) or not (grip.world or IsValid(grip.ent)) then
				self:Release(ply, name)
				spent[name] = true
			end
		elseif not spent[name] and config.reach > 0 then
			self:_Reach(st, ply, body, hand, eyes, blend, config)
		end
	end
end

-- The hand reaches towards what the player looks at and holds on once it is there.
function M:_Reach(st, ply, body, hand, eyes, blend, config)
	local phys = body.phys[hand.bone]
	if phys == nil or not IsValid(phys) then
		return
	end
	local rag = body.ent
	local from = eyes ~= nil and eyes.Pos or (body.head ~= nil and body.head:GetPos() or rag:GetPos())
	trace.start, trace.endpos = from, from + ply:GetAimVector() * config.reach
	filter[1], filter[2] = ply, rag
	local tr = TraceLine(trace)
	local to = tr.HitPos - phys:GetPos()
	local dist = to:Length()
	if tr.Hit and dist <= config.grabRange and self:_Grab(st, ply, rag, hand, tr) then
		return
	end
	local scale = dist > 0 and min(dist * config.pull, REACH_SPEED) / dist or 0
	local vel = phys:GetVelocity()
	push:SetUnpacked((to.x * scale - vel.x) * blend, (to.y * scale - vel.y) * blend, (to.z * scale - vel.z) * blend)
	phys:AddVelocity(push)
end

function M:_Grab(st, ply, rag, hand, tr)
	local ent, bone, world = tr.Entity, tr.PhysicsBone or 0, tr.HitWorld == true
	if tr.HitSky then
		return false
	end
	if world then
		ent, bone = game.GetWorld(), 0
	elseif not IsValid(ent) or ent == rag or ent:IsPlayer() or ent:GetMoveType() ~= MOVETYPE_VPHYSICS
		or not IsValid(ent:GetPhysicsObjectNum(bone)) then
		return false
	end
	if self.ctx.events:Query("ragdoll_control.canGrab", ply, ent) == false then
		return false
	end
	local id = rag:LookupBone(hand.bone)
	local physBone = id ~= nil and rag:TranslateBoneToPhysBone(id) or -1
	if physBone < 0 then
		return false
	end
	local weld = constraint.Weld(rag, ent, physBone, bone, self.ctx.config.gripForce, false, false)
	if not IsValid(weld) then
		return false
	end
	st[hand.name] = { weld = weld, ent = ent, world = world }
	self.ctx.events:Emit("ragdoll_control.grabbed", ply, hand.name, ent)
	return true
end

-- API --------------------------------------------------------------------------------------

-- `hand` ("left" or "right") of `ply` lets go. Returns whether it held something.
function M:Release(ply, hand)
	local st = self.states[ply]
	local grip = st and st[hand]
	if grip == nil then
		return false
	end
	st[hand] = nil
	if IsValid(grip.weld) then
		grip.weld:Remove()
	end
	self.ctx.events:Emit("ragdoll_control.released", ply, hand)
	return true
end

-- What `hand` ("left" or "right") of `ply` holds: an entity, game.GetWorld(), or nil.
function M:Grip(ply, hand)
	local st = self.states[ply]
	local grip = st and st[hand]
	return grip and grip.ent
end
