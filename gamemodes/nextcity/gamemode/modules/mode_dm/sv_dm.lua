-- Deathmatch: every player for himself. A kill is a frag (a suicide costs one), the dead
-- come back after respawnDelay s at the spawn points farthest from the others; the first
-- to fragLimit frags wins, and when the time is up the one leader (several: a draw). Rules:
-- time_limit, respawn and, while the loot module runs, loot. Frags and deaths start from
-- zero every round. The status line shows the leader and the limit.
--
-- Loadout as in mode_tdm: with the inventory running and the kit of param kit registered
-- (e.g. "dm" of the supplies package), the things of the kit (the primary weapon into the
-- hands); otherwise the engine weapons of loadout with spareMags magazines each (the last
-- one into the hands) and the kinds of armor.

local M = NC.Module("mode_dm")

local ipairs = ipairs
local IsValid = IsValid

local LOADOUT = { "weapon_crowbar", "weapon_pistol", "weapon_smg1" }

M.HANDS = { "primary", "secondary", "melee" } -- what a kit puts into the hands first

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.armor = ctx:Require("armor")
	self.inventory = ctx:Require("inventory")
	self.warned = {}
	local rules = { "time_limit", "respawn" }
	if ctx:Require("loot") ~= nil then
		rules[#rules + 1] = "loot"
	end
	ctx:Require("rounds"):RegisterMode({
		id = "dm",
		name = "mode_dm.name",
		description = "every player for himself, frags",
		minPlayers = 2,
		rules = rules,
		params = {
			roundTime = { type = "number", default = 600, min = 60, max = 7200, desc = "round length, s" },
			respawnDelay = { type = "number", default = 3, min = 0, max = 60, desc = "seconds before a respawn" },
			fragLimit = { type = "integer", default = 25, min = 0, max = 1000, desc = "frags to win (0 = none)" },
			loadout = { type = "list", of = { type = "string", max = 64 }, max = 16, default = LOADOUT,
				desc = "weapons of a spawning player" },
			spareMags = { type = "integer", default = 3, min = 0, max = 20, desc = "spare magazines per weapon" },
			armor = { type = "list", of = { type = "string", max = 32 }, max = 8, default = {},
				desc = "kinds of armor a spawning player wears (the armor module)" },
			kit = { type = "string", max = 32, default = "dm",
				desc = "kit of items a spawning player gets while the inventory runs (instead of loadout and armor)" },
		},
		PlayerAdded = function(_, ply)
			ply:SetFrags(0)
			ply:SetDeaths(0)
		end,
		Start = function(round)
			self:Update(round)
		end,
		PlayerDied = function(round)
			self:Update(round)
		end,
		PlayerLeft = function(round)
			self:Update(round)
		end,
		Loadout = function(round, ply)
			self:GiveLoadout(ply, round.params)
		end,
		CheckWin = function(round)
			return self:CheckWin(round)
		end,
		Timeout = function(round)
			local leader, _, unique = self:Leader(round)
			return { reason = "time", winner = unique and leader or nil }
		end,
	}, ctx)
end

-- The participant with the most frags, his frags and whether nobody else has as many.
function M:Leader(round)
	local leader, best, unique = nil, 0, false
	for _, ply in ipairs(round:Participants()) do
		if IsValid(ply) then
			local frags = ply:Frags()
			if leader == nil or frags > best then
				leader, best, unique = ply, frags, true
			elseif frags == best then
				unique = false
			end
		end
	end
	if leader == nil or best <= 0 then
		return nil, 0, false
	end
	return leader, best, unique
end

function M:CheckWin(round)
	local limit = round.params.fragLimit
	local leader, frags = self:Leader(round)
	if limit > 0 and leader ~= nil and frags >= limit then
		return { reason = "score", winner = leader }
	end
	return nil
end

-- The status line: the leader and the limit.
function M:Update(round)
	if not round:IsActive() then
		return
	end
	local limit = round.params.fragLimit
	local leader, frags, unique = self:Leader(round)
	local free = limit == 0 and ".free" or ""
	if leader == nil then
		round:SetStatus(limit > 0 and "mode_dm.status.limit" or nil, { limit = limit })
	elseif unique then
		round:SetStatus("mode_dm.status.leader" .. free, { leader = self.players:Name(leader), frags = frags,
			limit = limit })
	else
		round:SetStatus("mode_dm.status.tie" .. free, { frags = frags, limit = limit })
	end
end

-- The kit as items, or the weapons of the loadout with spareMags magazines of reserve
-- ammo each (the last one is in the hands) and the armor.
function M:GiveLoadout(ply, params)
	if self:GiveKit(ply, params.kit) then
		return
	end
	if self.armor ~= nil then
		for _, id in ipairs(params.armor) do
			if self.armor:Kind(id) == nil then
				self:_WarnOnce(id, "unknown kind of armor '%s' in the parameter armor", id)
			else
				self.armor:Equip(ply, id)
			end
		end
	end
	local last
	for _, class in ipairs(params.loadout) do
		local weapon = ply:Give(class)
		if IsValid(weapon) then
			last = class
			local clip, ammo = weapon:GetMaxClip1(), weapon:GetPrimaryAmmoType()
			if params.spareMags > 0 and clip > 0 and ammo >= 0 then
				ply:GiveAmmo(clip * params.spareMags, ammo, true)
			end
		end
	end
	if last ~= nil then
		ply:SelectWeapon(last)
	end
end

-- Gives the kit `id` when the inventory runs and has it; whether it did.
function M:GiveKit(ply, id)
	local inventory = self.inventory
	if inventory == nil or id == "" then
		return false
	end
	if inventory:Kit(id) == nil then
		self:_WarnOnce("kit:" .. id, "unknown kit '%s' in the parameter kit: the loadout of weapons instead", id)
		return false
	end
	inventory:GiveKit(ply, id, { drop = true, select = M.HANDS })
	return true
end

function M:_WarnOnce(id, text, ...)
	if not self.warned[id] then
		self.warned[id] = true
		self.ctx.log:Warn(text, ...)
	end
end
