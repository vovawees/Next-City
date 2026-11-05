-- Melee, server part: what a strike does and the console.
--
-- Commands: nc_melee — the registered melee weapons and their attacks.

local M = NC.Module("melee")

local format = string.format
local IsValid = IsValid

local DAMAGE_TYPES = { blunt = DMG_CLUB, slash = DMG_SLASH, stab = DMG_SLASH, stun = DMG_CLUB }
local FORCE = 20     -- engine force per J of a strike
local AMOUNT = 1 / 8 -- the amount of a hit per J: the punch of the view, knocking down

function M:_InitServer(ctx)
	ctx.commands:Add("nc_melee", { help = "registered melee weapons", admin = false }, "MeleeCommand")
end

-- Deals a strike that met `tr` along `dir`: a hit of the organism on a body, engine damage
-- to the rest, the effects and sounds of the contact.
function M:_Deal(owner, weapon, attack, index, tr, dir, scale)
	local config = self.ctx.config
	local energy = attack.energy * scale * config.energy
	local ent = tr.Entity
	local valid = IsValid(ent)
	local victim = valid and (ent:IsPlayer() and ent or self.organism:PlayerOf(ent)) or nil
	local dtype = DAMAGE_TYPES[attack.kind]
	local force = dir * (energy * FORCE * config.push)
	local data = EffectData()
	data:SetOrigin(tr.HitPos)
	data:SetStart(tr.StartPos or owner:GetShootPos())
	data:SetNormal(dir)
	if victim ~= nil then
		-- A weaker blow of a blade goes in less deep.
		self.damage:Inflict(victim, { kind = attack.kind, attacker = owner, inflictor = weapon, type = dtype,
			amount = energy * AMOUNT, energy = energy, depth = attack.depth and attack.depth * scale, pos = tr.HitPos,
			dir = dir, force = force, hitgroup = tr.HitGroup })
		if ent ~= victim then
			-- The body he is down in moves with the blow.
			local phys = ent:GetPhysicsObjectNum(tr.PhysicsBone or 0)
			if IsValid(phys) then
				phys:ApplyForceOffset(force, tr.HitPos)
			end
		end
		if attack.kind == "slash" or attack.kind == "stab" then
			util.Effect("BloodImpact", data, true, true)
		end
		self:_Sound(owner, attack.sounds.hit)
	else
		if valid then
			local dmginfo = DamageInfo()
			dmginfo:SetAttacker(owner)
			dmginfo:SetInflictor(weapon)
			dmginfo:SetDamage(attack.damage ~= nil and attack.damage * scale or energy * config.entityDamage)
			dmginfo:SetDamageType(dtype)
			dmginfo:SetDamageForce(force)
			dmginfo:SetDamagePosition(tr.HitPos)
			ent:TakeDamageInfo(dmginfo)
		end
		data:SetEntity(tr.Entity)
		data:SetSurfaceProp(tr.SurfaceProps or 0)
		data:SetHitBox(tr.HitBox or 0)
		data:SetDamageType(dtype)
		util.Effect("Impact", data, true, true)
		self:_Sound(owner, attack.sounds.world)
	end
	self.ctx.events:Emit("melee.struck", owner, weapon, ent, index)
end

function M:_Sound(owner, name)
	if name ~= nil then
		owner:EmitSound(name)
	end
end

local function describe(attack)
	return format("%s %g J %gu %g+%g s", attack.kind, attack.energy, attack.reach, attack.windup, attack.recovery)
end

function M:MeleeCommand()
	if #self.order == 0 then
		return "nc_melee: no melee weapons (packages register them)"
	end
	local lines = { format("nc_melee: %d weapons", #self.order) }
	for _, class in ipairs(self.order) do
		local def = self.defs[class]
		lines[#lines + 1] = format("  %-20s %d hand(s)  %-28s %-28s %s", class, def.hands, describe(def.primary),
			def.secondary and describe(def.secondary) or "-", self:Name(class))
	end
	return lines
end
