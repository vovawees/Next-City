-- Riot, server part: the mode "riot". The riot police (param police, 0 = a third of the
-- players) against the rioters; rules: time_limit, teams (two teams named rioters and
-- police) and, while the loot module runs, loot (what the rioters find to fight with).
--
-- The police carry stun batons, which knock down, and zip ties: the use key on a rioter (or
-- on his body while he is down) ties him up (the restraints module). Players tie up only the
-- other side and untie only their own: the rioters free each other. A player who is dead or
-- tied is out; a side wins when nobody of the other is standing, and when the time is up the
-- side with more players standing (as many: a draw). The scores of the teams are the numbers
-- of their players standing. Param firearms: false keeps guns and ammunition out of the loot
-- and of the kits, true gives the police pistols.
--
-- Kits of the package by side (M.KITS); without the inventory or the kit the engine weapons
-- of M.WEAPONS.

local M = NC.Module("mode_riot")

local IsValid = IsValid
local ipairs = ipairs
local floor = math.floor
local max = math.max
local min = math.min

-- Kits by side.
M.KITS = { police = "riot_police", police_armed = "riot_police_armed", rioter = "riot_rioter" }

-- Engine weapons without the inventory or the kit (the first one goes into the hands).
M.WEAPONS = {
	police = { "weapon_stunstick" },
	police_armed = { "weapon_stunstick", "weapon_pistol" },
	rioter = { "weapon_crowbar" },
}

-- Weapon slots in the order the weapon of a kit goes into the hands.
M.HANDS = { "melee", "secondary", "primary" }

M.FIREARM_SLOTS = { primary = true, secondary = true }

M.Random = math.random -- (n) -> 1..n; specs replace it

function M:_InitServer(ctx)
	self.rounds = ctx:Require("rounds")
	self.teams = ctx:Require("teams")
	self.players = ctx:Require("players")
	self.inventory = ctx:Require("inventory")
	self.notices = ctx:Require("notices")
	self.restraints = ctx:Require("restraints")
	self.warned = {}
	local rules = { "time_limit", "teams" }
	if ctx:Require("loot") ~= nil then
		rules[#rules + 1] = "loot"
	end
	self.rounds:RegisterMode({
		id = "riot",
		name = "mode_riot.name",
		description = "the riot police tie up the rioters, the rioters fight back",
		minPlayers = 2,
		rules = rules,
		params = {
			roundTime = { type = "number", default = 420, min = 60, max = 3600,
				desc = "round length, s (then the side with more players standing wins)" },
			police = { type = "integer", default = 0, min = 0, max = 32,
				desc = "police officers in a round (0 = a third of the players)" },
			firearms = { type = "boolean", default = false,
				desc = "pistols for the police, guns and ammunition in the loot" },
			-- Of the rule teams: always the two teams of the mode.
			teams = { type = "integer", default = 2, min = 2, max = 2, desc = "the rioters and the police" },
			teamNames = { type = "list", of = { type = "string", max = 48 }, max = 2,
				default = { "mode_riot.team.rioters", "mode_riot.team.police" },
				desc = "translation keys of the team names" },
		},
		Setup = function(round)
			self:Setup(round)
		end,
		Participants = function(round, ready)
			self:Deal(round, ready)
		end,
		PlayerAdded = function(round, ply)
			self:Join(round, ply)
		end,
		PlayerSpawned = function(round)
			self:_Score(self:Count(round))
		end,
		Loadout = function(round, ply)
			self:Loadout(round, ply)
		end,
		Start = function(round)
			self:Brief(round)
		end,
		CheckWin = function(round)
			return self:CheckWin(round)
		end,
		Timeout = function(round)
			return self:Timeout(round)
		end,
	}, ctx)
end

local function isPlayer(ent)
	return ent ~= nil and IsValid(ent) and ent:IsPlayer()
end

-- Firearms and their ammunition: the weapon slots and the ammo trait of the package.
function M:IsFirearm(def)
	if def == nil then
		return false
	end
	local weapon = def.traits.weapon
	return def.traits.ammo ~= nil or (weapon ~= nil and M.FIREARM_SLOTS[weapon.slot or "primary"] == true)
end

-- Without firearms the loot of the round has no guns and ammunition. Players tie up only
-- the other side and untie only their own; a tie or an untie may decide the round.
function M:Setup(round)
	if not round.params.firearms then
		round:On("loot.allow", function(_, def)
			if self:IsFirearm(def) then
				return false
			end
		end)
	end
	round:On("restraints.canTie", function(ply, target)
		if ply:Team() == target:Team() then
			return false
		end
	end)
	round:On("restraints.canUntie", function(ply, target)
		if ply:Team() ~= target:Team() then
			return false
		end
	end)
	round:On("restraints.tied", function(ply, by)
		self:Tied(round, ply, by)
	end)
	round:On("restraints.untied", function(ply, by)
		self:Untied(round, ply, by)
	end)
end

-- How many police officers for `count` players: at least one, and one rioter is left.
function M:PoliceFor(params, count)
	local wanted = params.police
	if wanted == 0 then
		wanted = floor(count / 3 + 0.5)
	end
	return max(1, min(wanted, count - 1))
end

-- The police among the ready players, in a random order.
function M:Deal(round, ready)
	local count = #ready
	local police = self:PoliceFor(round.params, count)
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
		deal[ready[index]] = i <= police and M.POLICE or M.RIOTERS
	end
	round.data.deal = deal
end

-- The team of the deal; one who joins later goes to the police while it has fewer officers
-- than the players of the round want, else to the rioters.
function M:Join(round, ply)
	local deal = round.data.deal
	local index = deal ~= nil and deal[ply] or nil
	if index == nil then
		local police = 0
		for _, other in ipairs(round:Participants()) do
			if other ~= ply and other:Team() == M.POLICE then
				police = police + 1
			end
		end
		index = police < self:PoliceFor(round.params, round:ParticipantCount()) and M.POLICE or M.RIOTERS
	end
	self.teams:Assign(ply, index)
end

function M:Side(round, ply)
	if ply:Team() == M.POLICE then
		return round.params.firearms and "police_armed" or "police"
	end
	return "rioter"
end

function M:Loadout(round, ply)
	local side = self:Side(round, ply)
	self:_Equip(ply, M.KITS[side] or "", M.WEAPONS[side] or {})
end

-- The kit (its melee weapon into the hands) or the engine weapons.
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
	if weapons[1] ~= nil and ply:HasWeapon(weapons[1]) then
		ply:SelectWeapon(weapons[1])
	end
end

-- Each side learns what to do.
function M:Brief(round)
	local notices = self.notices
	if notices == nil then
		return
	end
	for _, ply in ipairs(round:Participants()) do
		notices:Send(ply, ply:Team() == M.POLICE and "mode_riot.intro.police" or "mode_riot.intro.rioter", nil, "info")
	end
end

-- An enemy tied a player up: a frag for him and a line for everybody.
function M:Tied(round, ply, by)
	if isPlayer(by) and round:IsParticipant(ply) and by:Team() ~= ply:Team() then
		by:AddFrags(1)
		self:_Tell("mode_riot.tied", ply, by)
	end
	round:CheckWin()
end

-- A teammate untied a player (death and a new life untie quietly).
function M:Untied(round, ply, by)
	if isPlayer(by) and round:IsParticipant(ply) then
		self:_Tell("mode_riot.freed", ply, by)
	end
	round:CheckWin()
end

function M:_Tell(key, ply, by)
	if self.notices ~= nil then
		local players = self.players
		self.notices:Broadcast(key, { who = players:Name(ply), by = players:Name(by) }, "info", { chat = true })
	end
end

-- A player stands while he is alive and not tied up.
function M:Standing(ply)
	if not self.players:IsAlive(ply) then
		return false
	end
	local restraints = self.restraints
	return restraints == nil or not restraints:IsTied(ply)
end

-- Rioters and police officers of the round standing.
function M:Count(round)
	local rioters, police = 0, 0
	for _, ply in ipairs(round:Participants()) do
		if self:Standing(ply) then
			local index = ply:Team()
			if index == M.RIOTERS then
				rioters = rioters + 1
			elseif index == M.POLICE then
				police = police + 1
			end
		end
	end
	return rioters, police
end

-- The scores of the teams show how many of them stand.
function M:_Score(rioters, police)
	local teams = self.teams
	if teams:Score(M.RIOTERS) ~= rioters then
		teams:SetScore(M.RIOTERS, rioters)
	end
	if teams:Score(M.POLICE) ~= police then
		teams:SetScore(M.POLICE, police)
	end
end

function M:CheckWin(round)
	local rioters, police = self:Count(round)
	self:_Score(rioters, police)
	if rioters == 0 and police == 0 then
		return { reason = "mode_riot.reason.nobody" }
	end
	if rioters == 0 then
		return { reason = "mode_riot.reason.suppressed", team = M.POLICE }
	end
	if police == 0 then
		return { reason = "mode_riot.reason.overrun", team = M.RIOTERS }
	end
	return nil
end

-- The time is up: the side with more players standing wins.
function M:Timeout(round)
	local rioters, police = self:Count(round)
	self:_Score(rioters, police)
	if rioters > police then
		return { reason = "mode_riot.reason.time", team = M.RIOTERS }
	end
	if police > rioters then
		return { reason = "mode_riot.reason.time", team = M.POLICE }
	end
	return { reason = "mode_riot.reason.even" }
end
