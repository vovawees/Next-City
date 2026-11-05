-- CO-OP, server part: the mode "coop". The players clear the map of creatures together: the
-- hostile creatures of the map (param map; the npcs module takes them over, friends and
-- critters stay out) and perPlayer creatures of the group per player (param group; they keep
-- their places unless param hunt) at the points of the map far from the players. The team
-- shares a pool of lives (param lives, 0 = two per player): while there are lives a fallen
-- player comes back after respawnDelay s, then he is out — he does not come back by
-- reconnecting either. Won when no creature is left; lost when nobody is alive and nobody
-- is coming back, or when the time is up (rule time_limit). The status line shows the
-- creatures left and the lives. Rule loot while the loot module runs.

local M = NC.Module("mode_coop")

local IsValid = IsValid
local ipairs = ipairs
local ceil = math.ceil
local max = math.max

M.TAG = "coop"   -- the creatures of the mode for the npcs module
M.FEED = 1       -- s between two tries to bring the rest of the creatures
M.ADOPT = 0.5    -- s after a kill to take over what it left (headcrabs)
M.HANDS = { "primary", "secondary", "melee" }
M.WEAPONS = { "weapon_smg1", "weapon_pistol", "weapon_crowbar" }

function M:Init(ctx)
	self.rounds = ctx:Require("rounds")
	self.players = ctx:Require("players")
	self.npcs = ctx:Require("npcs")
	self.inventory = ctx:Require("inventory")
	self.notices = ctx:Require("notices")
	self.warned = {}
	local rules = { "time_limit" }
	if ctx:Require("loot") ~= nil then
		rules[2] = "loot"
	end
	self.rounds:RegisterMode({
		id = "coop",
		name = "mode_coop.name",
		description = "clear the map of creatures together with shared lives",
		minPlayers = 1,
		rules = rules,
		params = {
			roundTime = { type = "number", default = 900, min = 0, max = 7200,
				desc = "round length, s (0 = no limit); then the round is lost" },
			lives = { type = "integer", default = 0, min = 0, max = 500,
				desc = "lives the team shares (0 = two per player)" },
			respawnDelay = { type = "number", default = 10, min = 0, max = 120, desc = "s before a fallen comes back" },
			map = { type = "boolean", default = true, desc = "the hostile creatures of the map count as enemies" },
			perPlayer = { type = "number", default = 4, min = 0, max = 20,
				desc = "creatures of the group spawned per player at the start" },
			group = { type = "string", max = 32, default = "combine", desc = "group of the spawned creatures (npcs)" },
			hunt = { type = "boolean", default = false, desc = "the creatures run at the players instead of waiting" },
			kit = { type = "string", max = 32, default = "coop", desc = "kit of the players (inventory)" },
			friendlyFire = { type = "boolean", default = false, desc = "players hurt each other" },
		},
		Setup = function(round)
			self:Setup(round)
		end,
		Start = function(round)
			self:Begin(round)
		end,
		Loadout = function(round, ply)
			self:Loadout(round, ply)
		end,
		PlayerDied = function(round, ply)
			self:Fell(round, ply)
		end,
		LateJoin = function(round, ply)
			return round.data.out[ply:SteamID()] == nil
		end,
		ShouldTakeDamage = function(round, ply, attacker)
			if not round.params.friendlyFire and IsValid(attacker) and attacker:IsPlayer() and attacker ~= ply then
				return false
			end
		end,
		CheckWin = function(round)
			return self:CheckWin(round)
		end,
		Timeout = function(round)
			return { key = "mode_coop.result.lost", reason = "mode_coop.reason.time",
				params = { count = self:Left(round) } }
		end,
		Cleanup = function()
			self.npcs:Clear(M.TAG)
		end,
	}, ctx)
end

function M:Setup(round)
	local data = round.data
	data.lives, data.pending, data.started, data.out = 0, 0, false, {}
	round:On("npcs.killed", function(_, _, _, tag)
		if tag == M.TAG then
			self:_AdoptSoon(round)
			self:Update(round)
		end
	end)
	round:On("npcs.removed", function(_, tag)
		if tag == M.TAG then
			self:Update(round)
		end
	end)
	-- Profiles: a won round is a win of every participant.
	round:On("profiles.won", function(_, result)
		return result ~= nil and result.key == "mode_coop.result.won"
	end)
end

-- The round starts: the lives, the creatures of the map and of the group, the briefing.
function M:Begin(round)
	local data, params = round.data, round.params
	data.lives = params.lives > 0 and params.lives or 2 * round:ParticipantCount()
	if params.map then
		self.npcs:Adopt(M.TAG, { hunt = params.hunt })
	end
	local group = params.group
	if params.perPlayer > 0 then
		if self.npcs:Group(group) ~= nil then
			data.pending = ceil(params.perPlayer * max(round:ParticipantCount(), 1) - 1e-6)
			self:Feed(round)
		else
			self:_WarnOnce("group " .. group, "unknown group '%s': no creatures spawned", group)
		end
	end
	data.started = true
	if self:Left(round) == 0 then
		round:End({ reason = "mode_coop.reason.empty" })
		return
	end
	round:Every("feed", M.FEED, function()
		if self:Feed(round) > 0 then
			self:Update(round)
		end
	end)
	local notices = self.notices
	if notices ~= nil then
		notices:Broadcast("mode_coop.intro", { count = self:Left(round), lives = data.lives }, "info")
	end
	self:Update(round)
end

-- The kit (its weapon into the hands) or the engine weapons.
function M:Loadout(round, ply)
	local inventory, kit = self.inventory, round.params.kit
	if inventory ~= nil and kit ~= "" then
		if inventory:Kit(kit) ~= nil then
			inventory:GiveKit(ply, kit, { drop = true, select = M.HANDS })
			return
		end
		self:_WarnOnce("kit " .. kit, "unknown kit '%s': engine weapons instead", kit)
	end
	for _, class in ipairs(M.WEAPONS) do
		local weapon = ply:Give(class)
		if IsValid(weapon) then
			local clip, ammo = weapon:GetMaxClip1(), weapon:GetPrimaryAmmoType()
			if clip > 0 and ammo >= 0 then
				ply:GiveAmmo(clip * 4, ammo, true)
			end
		end
	end
	if ply:HasWeapon(M.WEAPONS[1]) then
		ply:SelectWeapon(M.WEAPONS[1])
	end
end

function M:_WarnOnce(id, text, ...)
	if not self.warned[id] then
		self.warned[id] = true
		self.ctx.log:Warn(text, ...)
	end
end

-- Spawns what is left of the creatures of the group while there is room; how many came.
function M:Feed(round)
	local data = round.data
	if data.pending <= 0 then
		return 0
	end
	local spawned = self.npcs:SpawnGroup(round.params.group, data.pending, { tag = M.TAG, hunt = round.params.hunt })
	if spawned == 0 and self.npcs:Spots(1)[1] == nil then
		data.pending = 0 -- nowhere to come: the creatures of the map are the whole job
		return 0
	end
	data.pending = data.pending - spawned
	return spawned
end

-- A killed zombie leaves a headcrab: what is hostile on the map is taken over soon after.
function M:_AdoptSoon(round)
	local data = round.data
	if data.adopting or not round.params.map then
		return
	end
	data.adopting = true
	round:After(M.ADOPT, function()
		data.adopting = false
		if round:IsActive() and self.npcs:Adopt(M.TAG, { hunt = round.params.hunt }) > 0 then
			self:Update(round)
		end
	end)
end

-- Creatures left: still to come and alive.
function M:Left(round)
	return round.data.pending + self.npcs:Count(M.TAG)
end

-- The status line, or the map is clear.
function M:Update(round)
	local data = round.data
	if not data.started or not round:IsActive() then
		return
	end
	local left = self:Left(round)
	if left == 0 then
		round:End({ key = "mode_coop.result.won", reason = "mode_coop.reason.cleared" })
		return
	end
	round:SetStatus("mode_coop.status", { count = left, lives = data.lives })
end

-- A player fell: a life of the team brings him back, without lives he is out.
function M:Fell(round, ply)
	local data = round.data
	if not round:IsActive() or not round:IsParticipant(ply) then
		return
	end
	local notices = self.notices
	local who = self.players:Name(ply)
	if data.lives > 0 then
		data.lives = data.lives - 1
		round:Respawn(ply, round.params.respawnDelay)
		if notices ~= nil then
			notices:Broadcast("mode_coop.life", { who = who, lives = data.lives }, "warn", { chat = true })
		end
	else
		data.out[ply:SteamID()] = true
		if notices ~= nil then
			notices:Broadcast("mode_coop.out", { who = who }, "bad", { chat = true })
		end
	end
	self:Update(round)
end

-- Lost when nobody is alive and nobody is coming back.
function M:CheckWin(round)
	if round:AliveCount() == 0 and round:RespawnCount() == 0 then
		return { key = "mode_coop.result.lost", reason = "mode_coop.reason.fallen", params = { count = self:Left(round) } }
	end
	return nil
end
