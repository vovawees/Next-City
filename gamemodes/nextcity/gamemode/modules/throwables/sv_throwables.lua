-- Throwables, server part: the thrown things and the console.
--
-- A thrown thing is an entity of def.entity (a physics prop of the model) that the server
-- watches while it is live: its fuse, its first hard hit for an impact fuse (going off
-- waits for the next tick: nothing is removed inside a collision; a thing that broke on
-- that hit, a bottle, goes off where it broke), the sound of its bounces. Removed
-- otherwise, it is gone without going off. Going off calls def.detonate of the package (errors are logged), emits
-- throwables.detonated and removes the thing (unless def.remove is false). Beyond
-- config.maxLive the oldest live things go out as duds.
--
-- Commands: nc_throwables — the registered throwables.

local M = NC.Module("throwables")

local format = string.format
local IsValid = IsValid
local Vector = Vector
local CurTime = CurTime

local HAND = Vector(16, -6, -4) -- where the hand lets it go, forward / left / up of the eyes
local HAND_BOX = 3              -- half the side of the box traced to the hand, units
local DROP_SPEED = 40           -- units/s of a thing dropped from the hand
local BOUNCE_SPEED = 60         -- units/s of a hit that sounds
local BOUNCE_GAP = 0.2          -- s between the sounds of bounces at least
local TIRED_ENERGY = 0.6        -- the share of a throw without the stamina for it

local function onError(err)
	return debug.traceback(tostring(err), 2)
end

function M:_InitServer(ctx)
	self.live = {}     -- ent -> { ent, class, def, thrower, fuse, thrown, hit, pos, bounced }
	self.liveList = {} -- the live entries, oldest first
	self.trace = {}
	ctx:Every("fuses", 0, "Tick")
	ctx:On("gm.EntityRemoved", "OnEntityRemoved")
	ctx.commands:Add("nc_throwables", { help = "registered throwables", admin = false }, "ThrowablesCommand")
end

-- Where the hand of `owner` lets a thing go: ahead of the eyes, short of the world.
function M:_HandPos(owner)
	local start = owner:GetShootPos()
	local ang = owner:EyeAngles()
	local target = start + ang:Forward() * HAND.x - ang:Right() * HAND.y + ang:Up() * HAND.z
	local trace = self.trace
	trace.start, trace.endpos, trace.filter, trace.mask = start, target, owner, MASK_SOLID
	trace.mins, trace.maxs = Vector(-HAND_BOX, -HAND_BOX, -HAND_BOX), Vector(HAND_BOX, HAND_BOX, HAND_BOX)
	local tr = util.TraceHull(trace)
	return tr.Hit and tr.HitPos or target
end

-- Throws a live thing of the throwable `class` for `owner` (a player, or nil): opts.pos
-- (default: his hand), opts.velocity (units/s), opts.fuse (the game time it goes off;
-- nil: no fuse). Returns the entity, or nil.
function M:Launch(owner, class, opts)
	opts = opts or {}
	local def = self.defs[class]
	if def == nil then
		return nil
	end
	local ent = ents.Create(def.entity)
	if not IsValid(ent) then
		return nil
	end
	local valid = IsValid(owner)
	ent:SetModel(def.model)
	ent:SetPos(opts.pos or valid and self:_HandPos(owner) or Vector(0, 0, 0))
	ent:SetAngles(valid and owner:EyeAngles() or Angle(0, 0, 0))
	if valid then
		ent:SetOwner(owner) -- the thrower does not collide with it
	end
	ent:Spawn()
	ent:Activate()
	local phys = ent:GetPhysicsObject()
	if IsValid(phys) then
		phys:SetMass(def.mass)
		phys:Wake()
		phys:SetVelocity(opts.velocity or Vector(0, 0, 0))
	end
	ent:AddCallback("PhysicsCollide", function(e, data)
		self:_Collide(e, data)
	end)
	local entry = { ent = ent, class = class, def = def, thrower = valid and owner or nil, fuse = opts.fuse,
		thrown = CurTime() }
	self.live[ent] = entry
	local list = self.liveList
	list[#list + 1] = entry
	while #list > self.ctx.config.maxLive do
		local oldest = table.remove(list, 1)
		self.live[oldest.ent] = nil
		if IsValid(oldest.ent) then
			oldest.ent:Remove()
		end
	end
	self.ctx.events:Emit("throwables.thrown", owner, ent, class)
	return ent
end

-- The throw of the weapon (sh_throw.lua): the energy by the throw, the body and the config.
function M:_Thrown(weapon, owner, index, fuse)
	local def = weapon:Def()
	local energy = def.energy * self.ctx.config.energy * (index == 2 and self.ctx.config.lob or 1)
	if not self.organism:Exert(owner, def.stamina) and self.organism:IsSimulated(owner) then
		energy = energy * TIRED_ENERGY
	end
	local velocity = owner:GetAimVector() * M.Speed(energy, def.mass) + owner:GetVelocity()
	owner:RemoveAmmo(1, def.ammo)
	return self:Launch(owner, def.class, { velocity = velocity, fuse = fuse })
end

-- The weapon is put away with the fuse running: the thing drops from the hand.
function M:_Drop(weapon, owner)
	local def = weapon:Def()
	owner:RemoveAmmo(1, def.ammo)
	return self:Launch(owner, def.class, { velocity = owner:GetVelocity() + Vector(0, 0, -DROP_SPEED),
		fuse = weapon:GetFuse() })
end

-- Held past its fuse: it goes off in the hand.
function M:_GoOffInHand(weapon, owner)
	local def = weapon:Def()
	owner:RemoveAmmo(1, def.ammo)
	local ent = self:Launch(owner, def.class, { velocity = owner:GetVelocity() })
	if ent ~= nil then
		self:Detonate(ent)
	end
end

-- The thrower of the live thing `ent` (nil for none or not live).
function M:Thrower(ent)
	local entry = self.live[ent]
	return entry ~= nil and entry.thrower or nil
end

-- Whether `ent` is a live thrown thing.
function M:IsLive(ent)
	return self.live[ent] ~= nil
end

-- Sets off the live thing `ent` now; whether it was live.
function M:Detonate(ent)
	local entry = self.live[ent]
	if entry == nil then
		return false
	end
	self:_Forget(entry)
	local def = entry.def
	local pos = IsValid(ent) and ent:GetPos() or entry.pos or Vector(0, 0, 0)
	if def.detonate ~= nil then
		local ok, err = xpcall(def.detonate, onError, ent, entry.thrower, pos, def)
		if not ok then
			self.ctx.log:Error("%s went off with an error: %s", entry.class, tostring(err))
		end
	end
	self.ctx.events:Emit("throwables.detonated", ent, entry.class, entry.thrower, pos)
	if def.remove and IsValid(ent) then
		ent:Remove()
	end
	return true
end

function M:_Forget(entry)
	self.live[entry.ent] = nil
	local list = self.liveList
	for i = #list, 1, -1 do
		if list[i] == entry then
			table.remove(list, i)
			break
		end
	end
end

-- Every tick: what is due goes off.
function M:Tick(now)
	local list = self.liveList
	if #list == 0 then
		return
	end
	local due = {}
	for _, entry in ipairs(list) do
		if entry.hit or not IsValid(entry.ent) or entry.fuse ~= nil and now >= entry.fuse then
			due[#due + 1] = entry
		end
	end
	for _, entry in ipairs(due) do
		if entry.hit or IsValid(entry.ent) then
			self:Detonate(entry.ent)
		else
			self:_Forget(entry)
		end
	end
end

-- A hit of a live thing: the sound of a bounce; a hard one sets off an impact fuse.
function M:_Collide(ent, data)
	local entry = self.live[ent]
	if entry == nil then
		return
	end
	local def = entry.def
	local speed = data.Speed or 0
	local now = CurTime()
	if speed >= BOUNCE_SPEED and def.sounds.bounce ~= nil and now - (entry.bounced or -1) >= BOUNCE_GAP then
		entry.bounced = now
		ent:EmitSound(def.sounds.bounce)
	end
	if def.impact and speed >= self.ctx.config.impactSpeed and now >= entry.thrown + def.arm then
		entry.hit = true
	end
end

-- A live thing removed: broken on the hit that set it off, it still goes off at the next
-- tick where it was; removed otherwise, it is gone.
function M:OnEntityRemoved(ent)
	local entry = self.live[ent]
	if entry == nil then
		return
	end
	if entry.hit then
		entry.pos = ent:GetPos()
	else
		self:_Forget(entry)
	end
end

function M:ThrowablesCommand()
	if #self.order == 0 then
		return "nc_throwables: no throwables (packages register them)"
	end
	local lines = { format("nc_throwables: %d throwables", #self.order) }
	for _, class in ipairs(self.order) do
		local def = self.defs[class]
		local trigger = def.fuse ~= nil and format("fuse %g s", def.fuse) or ""
		if def.impact then
			trigger = trigger ~= "" and trigger .. " + impact" or "impact"
		end
		lines[#lines + 1] = format("  %-20s %g kg %g J %4.0f u/s  %-18s x%d  %s", class, def.mass, def.energy,
			M.Speed(def.energy, def.mass), trigger ~= "" and trigger or "-", def.max, self:Name(class))
	end
	return lines
end
