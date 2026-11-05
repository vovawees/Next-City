-- Team Deathmatch: two to four teams, a kill of an enemy scores for the team; the score
-- limit or the leader when time is up wins. Respawns are instant (after respawnDelay).
-- Everything but the loadout comes from rule blocks: time_limit, teams, team_score,
-- respawn, team_elimination (a team that lost every member is out) and, while the loot
-- module runs, loot (the loot of the map points).
--
-- Loadout: with the inventory running and a kit of the parameter kit registered
-- (inventory:RegisterKit, e.g. "tdm" of the supplies package), the things of the kit as
-- items: weapons, ammunition and armor go into the equipment. Otherwise the weapons of
-- loadout with spareMags magazines in the engine reserve and the kinds of armor.

local M = NC.Module("mode_tdm")

local ipairs = ipairs
local IsValid = IsValid

local LOADOUT = { "weapon_crowbar", "weapon_pistol", "weapon_smg1" }
local HANDS = { "primary", "secondary", "melee" } -- what a kit puts in the hands first

function M:Init(ctx)
	self.armor = ctx:Require("armor")
	self.inventory = ctx:Require("inventory")
	self.warned = {}
	local rules = { "time_limit", "teams", "team_score", "respawn", "team_elimination" }
	if ctx:Require("loot") ~= nil then
		rules[#rules + 1] = "loot"
	end
	ctx:Require("rounds"):RegisterMode({
		id = "tdm",
		name = "mode_tdm.name",
		description = "teams score kills of enemies",
		minPlayers = 2,
		rules = rules,
		params = {
			roundTime = { type = "number", default = 600, min = 60, max = 7200, desc = "round length, s" },
			respawnDelay = { type = "number", default = 5, min = 0, max = 60, desc = "seconds before a respawn" },
			scoreLimit = { type = "integer", default = 50, min = 0, max = 10000, desc = "score to win (0 = none)" },
			loadout = { type = "list", of = { type = "string", max = 64 }, max = 16, default = LOADOUT,
				desc = "weapons of a spawning player" },
			spareMags = { type = "integer", default = 3, min = 0, max = 20, desc = "spare magazines per weapon" },
			armor = { type = "list", of = { type = "string", max = 32 }, max = 8, default = {},
				desc = "kinds of armor a spawning player wears (the armor module)" },
			kit = { type = "string", max = 32, default = "tdm",
				desc = "kit of items a spawning player gets while the inventory runs (instead of loadout and armor)" },
		},
		Loadout = function(round, ply)
			self:GiveLoadout(ply, round.params)
		end,
	}, ctx)
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
				if not self.warned[id] then
					self.warned[id] = true
					self.ctx.log:Warn("unknown kind of armor '%s' in the parameter armor", id)
				end
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

-- Gives the kit `id` when the inventory runs and has it; whether it did. The weapon of the
-- primary slot (else the sidearm) goes into the hands.
function M:GiveKit(ply, id)
	local inventory = self.inventory
	if inventory == nil or id == "" then
		return false
	end
	if inventory:Kit(id) == nil then
		if not self.warned["kit:" .. id] then
			self.warned["kit:" .. id] = true
			self.ctx.log:Warn("unknown kit '%s' in the parameter kit: the loadout of weapons instead", id)
		end
		return false
	end
	inventory:GiveKit(ply, id, { drop = true, select = HANDS })
	return true
end
