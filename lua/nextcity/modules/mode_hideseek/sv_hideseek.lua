-- Hide and Seek, server part: the mode "hideseek". A few seekers (param seekers, 0 = a
-- quarter of the players) and the hiders; rules: time_limit, teams (two teams named
-- hiders and seekers), dead_mute (the dead do not give hiding places away) and, while the
-- loot module runs, loot (the hiders may find something to fight back with).
--
-- The hide phase (param hideTime) opens the round: the seekers are frozen and blind
-- (the client draws the blindfold), nobody hurts a seeker and the seekers hurt nobody;
-- players that become ready in it join as hiders. Then the hunt. Param catch: kill (the
-- seekers kill the hiders) or tag (a hit of a seeker turns a hider into a seeker). The
-- seekers win when no hider is left, the hiders when the time is up or no seeker is left.
-- The scores of the teams are the numbers of their living players.
--
-- Kits of the package by catch and side (M.KITS); without the inventory or the kit the
-- engine weapons of M.WEAPONS.

local M = NC.Module("mode_hideseek")

local CurTime = CurTime
local IsValid = IsValid
local ipairs = ipairs
local floor = math.floor
local max = math.max
local min = math.min

-- Kits by catch and side ("" = nothing; a tag is a hit of the hands).
M.KITS = {
	kill = { seeker = "hideseek_seeker", hider = "" },
	tag = { seeker = "", hider = "" },
}

-- Engine weapons without the inventory or the kit.
M.WEAPONS = {
	kill = { seeker = { "weapon_pistol", "weapon_crowbar" }, hider = {} },
	tag = { seeker = {}, hider = {} },
}

-- Weapon slots in the order the best one of a kit goes into the hands.
M.HANDS = { "primary", "secondary", "melee" }

M.Random = math.random -- (n) -> 1..n; specs replace it

function M:_InitServer(ctx)
	self.rounds = ctx:Require("rounds")
	self.teams = ctx:Require("teams")
	self.players = ctx:Require("players")
	self.inventory = ctx:Require("inventory")
	self.notices = ctx:Require("notices")
	self.hands = ctx:Require("hands")
	self.warned = {}
	local rules = { "time_limit", "teams", "dead_mute" }
	if ctx:Require("loot") ~= nil then
		rules[#rules + 1] = "loot"
	end
	self.rounds:RegisterMode({
		id = "hideseek",
		name = "mode_hideseek.name",
		description = "the hiders hide from the blindfolded seekers, then the seekers hunt them",
		minPlayers = 2,
		rules = rules,
		params = {
			roundTime = { type = "number", default = 360, min = 60, max = 3600,
				desc = "round length with the hide phase, s (then the hiders win)" },
			hideTime = { type = "number", default = 60, min = 5, max = 600,
				desc = "the hide phase: the seekers are frozen and blind, s" },
			seekers = { type = "integer", default = 0, min = 0, max = 32,
				desc = "seekers in a round (0 = a quarter of the players)" },
			catch = { type = "enum", values = { "kill", "tag" }, default = "kill",
				desc = "kill: the seekers kill the hiders; tag: a hit turns a hider into a seeker" },
			-- Of the rule teams: always the two teams of the mode.
			teams = { type = "integer", default = 2, min = 2, max = 2, desc = "the hiders and the seekers" },
			teamNames = { type = "list", of = { type = "string", max = 48 }, max = 2,
				default = { "mode_hideseek.team.hiders", "mode_hideseek.team.seekers" },
				desc = "translation keys of the team names" },
		},
		Participants = function(round, ready)
			self:Deal(round, ready)
		end,
		PlayerAdded = function(round, ply)
			local deal = round.data.deal
			self.teams:Assign(ply, deal ~= nil and deal[ply] or M.HIDERS)
		end,
		LateJoin = function(round)
			return self:IsHiding(round) or round.data.releaseAt == nil
		end,
		PlayerSpawned = function(round)
			self:_Score(self:Count(round))
		end,
		Loadout = function(round, ply)
			self:Loadout(round, ply)
		end,
		Start = function(round)
			self:BeginHiding(round)
		end,
		ShouldTakeDamage = function(round, ply, attacker)
			return self:AnswerDamage(round, ply, attacker)
		end,
		CheckWin = function(round)
			return self:CheckWin(round)
		end,
		Timeout = function()
			return { reason = "mode_hideseek.reason.time", team = M.HIDERS }
		end,
		End = function()
			self:_SendPhase(nil, 0)
		end,
	}, ctx)
end

-- Seekers for the ready players: at least one, and at least one hider is left.
function M:Deal(round, ready)
	local count = #ready
	local wanted = round.params.seekers
	if wanted == 0 then
		wanted = floor(count / 4 + 0.5)
	end
	local seekers = max(1, min(wanted, count - 1))
	local order = {}
	for i = 1, count do
		order[i] = i
	end
	for i = count, 2, -1 do
		local j = M.Random(i)
		order[i], order[j] = order[j], order[i]
	end
	local deal = {}
	for i, index in ipairs(order) do
		deal[ready[index]] = i <= seekers and M.SEEKERS or M.HIDERS
	end
	round.data.deal = deal
end

function M:IsHiding(round)
	local releaseAt = round.data.releaseAt
	return releaseAt ~= nil and not round.data.released
end

function M:Side(ply)
	return ply:Team() == M.SEEKERS and "seeker" or "hider"
end

function M:Loadout(round, ply)
	local catch = round.params.catch
	local side = self:Side(ply)
	self:_Equip(ply, M.KITS[catch][side] or "", M.WEAPONS[catch][side] or {})
end

-- The kit (its best weapon into the hands) or the engine weapons.
function M:_Equip(ply, kit, weapons)
	local inventory = self.inventory
	if inventory ~= nil and kit ~= "" then
		if inventory:Kit(kit) ~= nil then
			inventory:GiveKit(ply, kit, { drop = true, select = M.HANDS })
			return
		end
		if not self.warned[kit] then
			self.warned[kit] = true
			self.ctx.log:Warn("unknown kit '%s': engine weapons instead", kit)
		end
	end
	for _, class in ipairs(weapons) do
		local weapon = ply:Give(class)
		if IsValid(weapon) then
			local clip, ammo = weapon:GetMaxClip1(), weapon:GetPrimaryAmmoType()
			if clip > 0 and ammo >= 0 then
				ply:GiveAmmo(clip * 2, ammo, true)
			end
		end
	end
end

-- The round starts with the hide phase: the seekers are frozen (the client blinds them).
function M:BeginHiding(round)
	local hideTime = round.params.hideTime
	round.data.releaseAt = CurTime() + hideTime
	round.data.released = false
	for _, ply in ipairs(round:Participants()) do
		if ply:Team() == M.SEEKERS then
			ply:Freeze(true)
		end
		if self.notices ~= nil then
			self.notices:Send(ply, "mode_hideseek.intro." .. self:Side(ply), { time = floor(hideTime + 0.5) }, "info")
		end
	end
	self:_SendPhase(nil, round.data.releaseAt)
	round:After(hideTime, function()
		self:Release(round)
	end)
end

-- The hunt begins.
function M:Release(round)
	if self.rounds:Round() ~= round or self.rounds:Phase() ~= "active" then
		return
	end
	round.data.released = true
	for _, ply in ipairs(round:Participants()) do
		if IsValid(ply) and ply:Team() == M.SEEKERS then
			ply:Freeze(false)
		end
	end
	if self.notices ~= nil then
		self.notices:Broadcast("mode_hideseek.released", nil, "warn")
	end
end

function M:_SendPhase(ply, releaseAt)
	if ply == nil then
		self.ctx.net:Broadcast("phase", { releaseAt = releaseAt })
	else
		self.ctx.net:Send("phase", ply, { releaseAt = releaseAt })
	end
end

function M:OnNetReady(ply)
	local round = self.rounds:Round()
	if round ~= nil and round.mode == "hideseek" and self:IsHiding(round) then
		self:_SendPhase(ply, round.data.releaseAt)
	end
end

local function isPlayer(ent)
	return ent ~= nil and IsValid(ent) and ent:IsPlayer()
end

-- While hiding nobody hurts a seeker and the seekers hurt nobody; in the hunt with catch
-- tag a hit of a seeker turns a hider into a seeker instead of hurting him.
function M:AnswerDamage(round, ply, attacker)
	local fromSeeker = isPlayer(attacker) and attacker:Team() == M.SEEKERS
	if self:IsHiding(round) then
		if ply:Team() == M.SEEKERS or fromSeeker then
			return false
		end
		return nil
	end
	if fromSeeker and round.params.catch == "tag" and ply:Team() == M.HIDERS and round:IsParticipant(ply)
		and round:IsParticipant(attacker) and self.players:IsAlive(attacker) then
		self:Tag(round, ply, attacker)
		return false
	end
	return nil
end

-- A hider is caught by a tag: he seeks from now on.
function M:Tag(round, ply, seeker)
	self.teams:Assign(ply, M.SEEKERS)
	self:_Equip(ply, M.KITS.tag.seeker or "", M.WEAPONS.tag.seeker or {})
	seeker:AddFrags(1)
	if self.notices ~= nil then
		local players = self.players
		self.notices:Broadcast("mode_hideseek.caught", { who = players:Name(ply), by = players:Name(seeker) }, "info",
			{ chat = true })
	end
	-- Not from inside the damage.
	round:After(0, function()
		round:CheckWin()
	end)
end

-- Living hiders and seekers of the round.
function M:Count(round)
	local hiders, seekers = 0, 0
	local players = self.players
	for _, ply in ipairs(round:Participants()) do
		if players:IsAlive(ply) then
			local index = ply:Team()
			if index == M.HIDERS then
				hiders = hiders + 1
			elseif index == M.SEEKERS then
				seekers = seekers + 1
			end
		end
	end
	return hiders, seekers
end

-- The scores of the teams show how many of them are alive.
function M:_Score(hiders, seekers)
	local teams = self.teams
	if teams:Score(M.HIDERS) ~= hiders then
		teams:SetScore(M.HIDERS, hiders)
	end
	if teams:Score(M.SEEKERS) ~= seekers then
		teams:SetScore(M.SEEKERS, seekers)
	end
end

function M:CheckWin(round)
	local hiders, seekers = self:Count(round)
	self:_Score(hiders, seekers)
	if hiders == 0 then
		return { reason = "mode_hideseek.reason.found", team = M.SEEKERS }
	end
	if seekers == 0 then
		return { reason = "mode_hideseek.reason.seekers", team = M.HIDERS }
	end
	return nil
end
