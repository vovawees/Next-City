-- Defense, server part: the mode "defense". The players hold out against waves of creatures
-- (the npcs module; groups of the package module hostiles). Before each wave a pause; then
-- the wave comes from the points of the map farthest from the players and runs at them.
-- A wave is beaten when none of its creatures is left (the headcrabs of killed zombies and
-- the hostile creatures of the map count too). In the pause after a wave the dead come back,
-- the living get more ammunition (param resupply) and the players who joined during the wave
-- come in. The round is won after the last wave and lost when everybody is dead.
--
-- Wave n has ceil(perPlayer * living * (1 + growth * (n - 1))) creatures of the group
-- groups[n] (the last one repeats); those over config maxAlive of npcs come as the others
-- die. The status line shows the countdown of the pause or the creatures left. Rule loot
-- while the loot module runs. Without the inventory or the kit the engine weapons of
-- M.WEAPONS.

local M = NC.Module("mode_defense")

local IsValid = IsValid
local ipairs = ipairs
local ceil = math.ceil
local max = math.max
local min = math.min

M.TAG = "defense"            -- the creatures of the mode for the npcs module
M.FEED = 1                   -- s between two tries to bring the rest of a wave
M.ADOPT = 0.5                -- s after a kill to take over what it left (headcrabs)
M.HANDS = { "primary", "secondary", "melee" }
M.WEAPONS = { "weapon_smg1", "weapon_pistol", "weapon_crowbar" }
M.GROUPS = { "zombies", "zombies_fast", "metrocops", "combine", "combine_elite" }

function M:Init(ctx)
	self.rounds = ctx:Require("rounds")
	self.players = ctx:Require("players")
	self.npcs = ctx:Require("npcs")
	self.inventory = ctx:Require("inventory")
	self.notices = ctx:Require("notices")
	self.warned = {}
	local rules = {}
	if ctx:Require("loot") ~= nil then
		rules[1] = "loot"
	end
	self.rounds:RegisterMode({
		id = "defense",
		name = "mode_defense.name",
		description = "hold out against waves of creatures with a pause before each",
		minPlayers = 1,
		rules = rules,
		params = {
			waves = { type = "integer", default = 5, min = 1, max = 100, desc = "waves to hold out" },
			pause = { type = "number", default = 20, min = 3, max = 300, desc = "pause before each wave, s" },
			perPlayer = { type = "number", default = 3, min = 0.5, max = 20,
				desc = "creatures of the first wave per living player" },
			growth = { type = "number", default = 0.5, min = 0, max = 5,
				desc = "each next wave is bigger by this share of the first one" },
			groups = { type = "list", of = { type = "string", max = 32 }, max = 100, default = M.GROUPS,
				desc = "groups of creatures (nc_npcs kinds) by wave, the last one repeats" },
			kit = { type = "string", max = 32, default = "defense", desc = "kit of the defenders (inventory)" },
			resupply = { type = "string", max = 32, default = "defense_resupply",
				desc = "kit the living get after each wave, empty for none" },
			friendlyFire = { type = "boolean", default = false, desc = "defenders hurt each other" },
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
		LateJoin = function(round)
			return round.data.phase == "pause"
		end,
		SpawnPoint = function()
			return "a"
		end,
		ShouldTakeDamage = function(round, ply, attacker)
			if not round.params.friendlyFire and IsValid(attacker) and attacker:IsPlayer() and attacker ~= ply then
				return false
			end
		end,
		CheckWin = function(round)
			return self:CheckWin(round)
		end,
		Cleanup = function()
			self.npcs:Clear(M.TAG)
		end,
	}, ctx)
end

function M:Setup(round)
	local data = round.data
	data.wave, data.phase, data.pending, data.total = 0, "pause", 0, 0
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
		return result ~= nil and result.key == "mode_defense.result.won"
	end)
end

-- The round starts: the briefing, the feed of waves, the first pause.
function M:Begin(round)
	local notices = self.notices
	if notices ~= nil then
		notices:Broadcast("mode_defense.intro", { count = round.params.waves }, "info")
	end
	round:Every("feed", M.FEED, function()
		if self:Feed(round) > 0 then
			self:Update(round)
		end
	end)
	self:Pause(round, 1)
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

-- The pause before wave n: the countdown in the status line, then the wave.
function M:Pause(round, n)
	local data = round.data
	data.phase, data.wave, data.pending, data.total = "pause", n, 0, 0
	if n > 1 then
		self:Regroup(round)
	end
	local pause = round.params.pause
	round:SetStatus("mode_defense.status.pause", { wave = n, waves = round.params.waves }, CurTime() + pause)
	local token = {}
	data.timer = token
	round:After(pause, function()
		if data.timer == token and round:IsActive() then
			self:Wave(round, n)
		end
	end)
end

-- After a wave: the dead come back, the living get the resupply kit, the players who
-- joined during the wave come in.
function M:Regroup(round)
	local players, inventory, kit = self.players, self.inventory, round.params.resupply
	for _, ply in ipairs(round:Participants()) do
		if players:IsAlive(ply) then
			if inventory ~= nil and kit ~= "" then
				if inventory:Kit(kit) ~= nil then
					inventory:GiveKit(ply, kit, { drop = true })
				else
					self:_WarnOnce("kit " .. kit, "unknown kit '%s': no resupply", kit)
				end
			end
		else
			round:Respawn(ply, 0)
		end
	end
	for _, ply in ipairs(players:ReadyPlayers()) do
		if not round:IsParticipant(ply) then
			round:AddParticipant(ply)
		end
	end
end

-- The group of wave n: groups[n], the last one for the waves after; an unknown group falls
-- back to the first known one of M.GROUPS (or any).
function M:Group(round, n)
	local groups = round.params.groups
	local id = groups[min(n, #groups)]
	local npcs = self.npcs
	if id ~= nil and npcs:Group(id) ~= nil then
		return id
	end
	local fallback
	for _, other in ipairs(M.GROUPS) do
		if npcs:Group(other) ~= nil then
			fallback = other
			break
		end
	end
	fallback = fallback or npcs:Groups()[1]
	self:_WarnOnce("group " .. tostring(id), "unknown group '%s': %s instead", tostring(id), tostring(fallback))
	return fallback
end

function M:WaveSize(round, n, living)
	local params = round.params
	return ceil(params.perPlayer * max(living, 1) * (1 + params.growth * (n - 1)) - 1e-6)
end

-- Wave n comes: as many creatures as there is room for now, the rest as they die.
function M:Wave(round, n)
	local data = round.data
	local group = self:Group(round, n)
	if group == nil or self.npcs:Spots(1)[1] == nil then
		round:End({ reason = "mode_defense.reason.nowhere" })
		return
	end
	local count = self:WaveSize(round, n, round:AliveCount())
	data.phase, data.group, data.pending, data.total = "wave", group, count, count
	self:Feed(round)
	self.npcs:Adopt(M.TAG, { hunt = true })
	local notices = self.notices
	if notices ~= nil then
		notices:Broadcast("mode_defense.wave", { wave = n, waves = round.params.waves }, "warn")
	end
	self:Update(round)
end

-- Spawns what is left of the wave while there is room; how many came.
function M:Feed(round)
	local data = round.data
	if data.phase ~= "wave" or data.pending <= 0 then
		return 0
	end
	local spawned = self.npcs:SpawnGroup(data.group, data.pending, { tag = M.TAG })
	data.pending = data.pending - spawned
	return spawned
end

-- A killed zombie leaves a headcrab: what is hostile on the map joins the wave soon after.
function M:_AdoptSoon(round)
	local data = round.data
	if data.adopting then
		return
	end
	data.adopting = true
	round:After(M.ADOPT, function()
		data.adopting = false
		if data.phase == "wave" and round:IsActive() and self.npcs:Adopt(M.TAG, { hunt = true }) > 0 then
			self:Update(round)
		end
	end)
end

-- Creatures left in the wave: still to come and alive.
function M:Left(round)
	return round.data.pending + self.npcs:Count(M.TAG)
end

-- The status line of the wave, or the wave is beaten.
function M:Update(round)
	local data = round.data
	if data.phase ~= "wave" or not round:IsActive() then
		return
	end
	local left = self:Left(round)
	if left > 0 then
		round:SetStatus("mode_defense.status.wave", { wave = data.wave, waves = round.params.waves, count = left })
		return
	end
	self:Beaten(round)
end

function M:Beaten(round)
	local data = round.data
	local waves = round.params.waves
	data.phase = "pause"
	if data.wave >= waves then
		round:End({ key = "mode_defense.result.won", reason = "mode_defense.reason.held", params = { count = waves } })
		return
	end
	local notices = self.notices
	if notices ~= nil then
		notices:Broadcast("mode_defense.beaten", { wave = data.wave, waves = waves }, "good", { chat = true })
	end
	self:Pause(round, data.wave + 1)
end

-- Lost when nobody is alive and nobody is coming back.
function M:CheckWin(round)
	if round:AliveCount() == 0 and round:RespawnCount() == 0 then
		local data = round.data
		return { key = "mode_defense.result.lost", reason = "mode_defense.reason.fallen",
			params = { wave = max(data.wave, 1), waves = round.params.waves } }
	end
	return nil
end
