-- Movement, server part: the speeds and the limit of every player from the capabilities
-- of their body. The engine sends the speeds to the client for prediction.
--
--   standing   walk, run and slow walk scaled by moveSpeedMul; no sprint: running is
--              walking; no jump: jump power 0 and the key taken away
--   crawling   (cannot stand) crouching forced at the crawl speed, less without the arms
--   unconscious no input at all
--
-- Other modules scale the speeds (a load, a wound they model): the reduce movement.speed
-- (factor, ply, caps) -> factor, and Refresh(ply) when their factor changed.
--
-- Listens: organism.capabilities, players.spawned (after the organism: the base spawn
--          resets the speeds), players.died, players.left, players.stateChanged,
--          gm.StartCommand.
-- Reduces: movement.speed (1, ply, caps): the share of the speeds left.

local M = NC.Module("movement")

local max = math.max
local min = math.min
local IsValid = IsValid

function M:Init(ctx)
	ctx:Require("players")
	self.organism = ctx:Require("organism")
	self.limits = {} -- ply -> limit (sh_movement.lua)
end

function M:Start(ctx)
	ctx:On("organism.capabilities", "Apply")
	ctx:On("players.spawned", "OnSpawned", { priority = -10 })
	ctx:On("players.died", "Release")
	ctx:On("players.left", "Release")
	ctx:On("players.stateChanged", "OnStateChanged")
	ctx:On("gm.StartCommand", "OnStartCommand")
end

function M:OnSpawned(ply)
	self:Apply(ply, self.organism:Capabilities(ply))
end

function M:OnStateChanged(ply, state)
	if state ~= "alive" then
		self:Release(ply)
	end
end

function M:Release(ply)
	self.limits[ply] = nil
end

-- The speeds for capabilities `caps` (nil: a healthy body): walk, run, slow walk (units/s),
-- the crouching share of the walk and the jump power.
function M:Speeds(caps)
	local config = self.ctx.config
	if caps == nil then
		return config.walk, config.run, config.slowWalk, config.crouch, config.jump
	end
	if not caps.canStand then
		local arms = (caps.canUseArmL and 1 or 0) + (caps.canUseArmR and 1 or 0)
		local crawl = max(1, config.crawl * (6 + 7 * arms) / 20) -- 0.3 without arms, 0.65 with one
		return crawl, crawl, crawl, 1, 0
	end
	local mul = caps.moveSpeedMul
	local walk = max(1, config.walk * mul)
	local run = caps.canSprint and max(walk, config.run * mul) or walk
	local slow = min(walk, max(1, config.slowWalk * mul))
	local jump = caps.canJump and config.jump * (0.7 + 0.3 * mul) or 0
	return walk, run, slow, config.crouch, jump
end

-- Sets the speeds and the limit of `ply` from the capabilities of its body.
function M:Apply(ply, caps)
	if not IsValid(ply) then
		return
	end
	if caps ~= nil and not caps.alive then
		self.limits[ply] = nil
		return
	end
	local walk, run, slow, crouch, jump = self:Speeds(caps)
	local factor = self.ctx.events:Reduce("movement.speed", 1, ply, caps)
	if factor ~= 1 then
		factor = max(0.05, min(2, factor))
		walk, run, slow = max(1, walk * factor), max(1, run * factor), max(1, slow * factor)
		jump = jump * (0.6 + 0.4 * min(1, factor))
	end
	ply:SetWalkSpeed(walk)
	ply:SetRunSpeed(run)
	ply:SetSlowWalkSpeed(slow)
	ply:SetCrouchedWalkSpeed(crouch)
	ply:SetJumpPower(jump)
	self.limits[ply] = M.LimitOf(caps)
end

-- Sets the speeds of a living player again (a factor of movement.speed changed).
function M:Refresh(ply)
	if IsValid(ply) and ply:Alive() then
		self:Apply(ply, self.organism:Capabilities(ply))
	end
end
