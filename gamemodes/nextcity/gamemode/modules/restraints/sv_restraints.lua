-- Restraints, server part: the use key ties up and unties, the state of tied players.
--
-- An item with the trait restraint ties up: restraint = { time = 3, untie = 3, consume =
-- true } (s to tie up, s to untie the one tied with it, whether one is used up per tie).
-- The use key on a player within range (or on the body of a player who is down) starts
-- the action: tie him up with the first restraint the player carries, or untie him when
-- he is tied. The other player has to stay within the reach of the action: one who walks
-- away breaks it, so a resisting one has to be stopped first.
--
--   restraints:Tie(ply, by)     -> true or false, reason (at once, without an action)
--   restraints:Untie(ply, by)   -> true or false
--   restraints:IsTied(ply)
--   restraints:Restraint(ply)   -> the restraint a player carries (trait), its item id
--   restraints:Aimed(ply)       -> the player the use key of ply reaches, the entity hit
--   restraints:BeginTie(ply, target), restraints:BeginUntie(ply, target) -> ok, reason
--
-- Asks:    restraints.canTie (ply, target) -> false, restraints.canUntie (ply, target)
--          -> false (modes: only the police ties, only allies untie);
--          restraints.tool (ply) -> a restraint table for players without the item.
-- Answers: movement.speed (slower), inventory.canMove / inventory.canAct (false while tied).
-- Listens: gm.KeyPress, players.died, players.spawned, players.left.
-- Emits:   restraints.tied (ply, by), restraints.untied (ply, by).

local M = NC.Module("restraints")

local CurTime = CurTime
local IsValid = IsValid
local ipairs = ipairs

M.DEFAULT = {} -- a restraint of restraints.tool without its own fields

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.actions = ctx:Require("actions")
	self.inventory = ctx:Require("inventory")
	self.organism = ctx:Require("organism")
	self.movement = ctx:Require("movement")
	self.notices = ctx:Require("notices")
	self.untieTime = {} -- ply -> s to untie him (of the restraint he is tied with)
end

function M:_StartServer(ctx)
	ctx:On("gm.KeyPress", "OnKeyPress")
	ctx:On("players.died", "OnGone")
	ctx:On("players.spawned", "OnGone")
	ctx:On("players.left", "OnGone")
	ctx:On("movement.speed", "OnSpeed")
	ctx:On("inventory.canMove", "AnswerInventory")
	ctx:On("inventory.canAct", "AnswerInventory")
end

-- The restraint a player carries: the trait of the first item with it he has (and the
-- item id), or the answer of restraints.tool; nil without one.
function M:Restraint(ply)
	local inventory = self.inventory
	if inventory ~= nil then
		for _, id in ipairs(inventory:WithTrait("restraint")) do
			if inventory:Count(ply, id) > 0 then
				return inventory:Trait(id, "restraint"), id
			end
		end
	end
	local tool = self.ctx.events:Query("restraints.tool", ply)
	if type(tool) == "table" then
		return tool, nil
	end
	return nil
end

-- The living player the use key of `ply` reaches (his body when he is down), and the
-- entity the trace hit.
function M:Aimed(ply)
	local eye = ply:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * self.ctx.config.range,
		filter = ply, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	if ent == nil or not IsValid(ent) then
		return nil
	end
	local target = ent
	if not ent:IsPlayer() then
		target = self.organism ~= nil and self.organism:PlayerOf(ent) or nil
	end
	if target == nil or target == ply or not self.players:IsAlive(target) then
		return nil
	end
	return target, ent
end

function M:OnKeyPress(ply, key)
	if key ~= IN_USE or not self.players:IsAlive(ply) or self:IsTied(ply) or self.actions:IsBusy(ply) then
		return
	end
	local target = self:Aimed(ply)
	if target == nil then
		return
	end
	local ok, reason
	if self:IsTied(target) then
		ok, reason = self:BeginUntie(ply, target)
	elseif self:Restraint(ply) ~= nil then
		ok, reason = self:BeginTie(ply, target)
	else
		return
	end
	if not ok and reason ~= nil and self.notices ~= nil then
		self.notices:Send(ply, "restraints.fail." .. reason, nil, "bad")
	end
end

local function aimedEntity(self, ply, target)
	local _, ent = self:Aimed(ply)
	return ent ~= nil and self.organism ~= nil and self.organism:PlayerOf(ent) == target and ent or target
end

-- Starts tying `target` up (the action of ply). ok, or false and the reason.
function M:BeginTie(ply, target)
	local restraint = self:Restraint(ply)
	if restraint == nil then
		return false, "none"
	end
	if self:IsTied(target) then
		return false, "tied"
	end
	if self.ctx.events:Query("restraints.canTie", ply, target) == false then
		return false, "denied"
	end
	return self.actions:Begin(ply, {
		id = "restraints.tie", label = "restraints.action.tie",
		duration = restraint.time or self.ctx.config.time,
		target = aimedEntity(self, ply, target),
		Check = function()
			if not self.players:IsAlive(target) or self:IsTied(target) then
				return false, "target"
			end
			return true
		end,
		OnComplete = function()
			local now, id = self:Restraint(ply)
			if now == nil then
				return
			end
			if now.consume ~= false and id ~= nil and self.inventory ~= nil then
				self.inventory:Take(ply, id, 1)
			end
			self:Tie(target, ply, now)
		end,
	})
end

-- Starts untying `target` (the action of ply). ok, or false and the reason.
function M:BeginUntie(ply, target)
	if not self:IsTied(target) then
		return false, "free"
	end
	if self.ctx.events:Query("restraints.canUntie", ply, target) == false then
		return false, "denied"
	end
	return self.actions:Begin(ply, {
		id = "restraints.untie", label = "restraints.action.untie",
		duration = self.untieTime[target] or self.ctx.config.untie,
		target = aimedEntity(self, ply, target),
		Check = function()
			if not self:IsTied(target) then
				return false, "target"
			end
			return true
		end,
		OnComplete = function()
			self:Untie(target, ply)
		end,
	})
end

-- Ties a player up at once (`restraint`: its untie time). by: who did it, or nil.
function M:Tie(ply, by, restraint)
	if not IsValid(ply) or not self.players:IsAlive(ply) then
		return false, "target"
	end
	if self:IsTied(ply) then
		return false, "tied"
	end
	self.ctx.components.tied:Add(ply, { since = CurTime() })
	self.untieTime[ply] = restraint ~= nil and restraint.untie or nil
	self.actions:Cancel(ply, "cancelled")
	local hands = self.hands
	if hands ~= nil and ply:HasWeapon(hands.CLASS) then
		ply:SelectWeapon(hands.CLASS)
	end
	self:_Refresh(ply)
	if self.notices ~= nil then
		self.notices:Send(ply, "restraints.tied", nil, "bad")
	end
	self.ctx.events:Emit("restraints.tied", ply, by)
	return true
end

function M:Untie(ply, by)
	if not self:IsTied(ply) then
		return false
	end
	self.ctx.components.tied:Remove(ply)
	self.untieTime[ply] = nil
	self:_Refresh(ply)
	if self.notices ~= nil and IsValid(ply) then
		self.notices:Send(ply, "restraints.untied", nil, "good")
	end
	self.ctx.events:Emit("restraints.untied", ply, by)
	return true
end

function M:_Refresh(ply)
	if self.movement ~= nil and IsValid(ply) then
		self.movement:Refresh(ply)
	end
end

-- Death, a new life or leaving frees a player (quietly).
function M:OnGone(ply)
	if self:IsTied(ply) then
		self.ctx.components.tied:Remove(ply)
		self.untieTime[ply] = nil
		self.ctx.events:Emit("restraints.untied", ply, nil)
	end
end

function M:OnSpeed(factor, ply)
	if self:IsTied(ply) then
		return factor * self.ctx.config.speed
	end
	return factor
end

function M:AnswerInventory(ply)
	if self:IsTied(ply) then
		return false
	end
	return nil
end
