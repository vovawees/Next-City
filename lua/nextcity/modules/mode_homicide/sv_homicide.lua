-- Homicide, server part: the mode "homicide". Murderers (they know each other), sheriffs
-- and innocents; the murderers win when nobody innocent is left alive, the innocents when
-- no murderer is or when the time is up. Rules: time_limit, roles (revealed at the end),
-- silent_deaths (no kill feed), dead_mute (the living do not hear the dead) and, while
-- the loot module runs, loot (the loot of the map points).
--
-- Variants (param variant; random picks one for each round):
--   standard  the murderer has a knife, the sheriff a revolver
--   gunfree   no firearms: the sheriff has a stun baton, no guns and ammunition in the loot
--   wildwest  everybody has a revolver, the murderer a knife as well
--
-- Kits of the package by variant and role (M.KITS); without the inventory or the kit the
-- engine weapons of M.WEAPONS. Everybody starts with empty hands. A player of the
-- innocent side who kills an innocent pays (param penalty): drops his firearms (drop),
-- dies (kill) or nothing (none). With aliases every participant gets one for the round
-- and wears its look (appearance.look: a model of the sets for the gender of his character
-- and a color of clothes by the number of the alias), so a face gives no name away.

local M = NC.Module("mode_homicide")

local ipairs = ipairs
local IsValid = IsValid
local max = math.max
local min = math.min

M.VARIANTS = { "standard", "gunfree", "wildwest" }

-- Kits by variant and role ("" = nothing).
M.KITS = {
	standard = { murderer = "homicide_murderer", sheriff = "homicide_sheriff", innocent = "" },
	gunfree = { murderer = "homicide_murderer", sheriff = "homicide_sheriff_gunfree", innocent = "" },
	wildwest = { murderer = "homicide_murderer_wildwest", sheriff = "homicide_wildwest",
		innocent = "homicide_wildwest" },
}

-- Engine weapons without the inventory or the kit.
M.WEAPONS = {
	standard = { murderer = { "weapon_crowbar" }, sheriff = { "weapon_357" }, innocent = {} },
	gunfree = { murderer = { "weapon_crowbar" }, sheriff = { "weapon_stunstick" }, innocent = {} },
	wildwest = { murderer = { "weapon_crowbar", "weapon_357" }, sheriff = { "weapon_357" },
		innocent = { "weapon_357" } },
}

M.FIREARM_SLOTS = { primary = true, secondary = true }

M.Random = math.random -- (n) -> 1..n; specs replace it

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.inventory = ctx:Require("inventory")
	self.notices = ctx:Require("notices")
	self.hands = ctx:Require("hands")
	self.appearance = ctx:Require("appearance")
	self.warned = {}
	local rules = { "time_limit", "roles", "silent_deaths", "dead_mute" }
	if ctx:Require("loot") ~= nil then
		rules[#rules + 1] = "loot"
	end
	local variants = { "random" }
	for i, id in ipairs(M.VARIANTS) do
		variants[i + 1] = id
	end
	ctx:Require("rounds"):RegisterMode({
		id = "homicide",
		name = "mode_homicide.name",
		description = "find the murderer among innocents",
		minPlayers = 3,
		rules = rules,
		params = {
			roundTime = { type = "number", default = 480, min = 60, max = 3600,
				desc = "round length, s (then the innocents win)" },
			variant = { type = "enum", values = variants, default = "standard",
				desc = "standard, gunfree (no firearms), wildwest (revolvers for all) or random" },
			murderers = { type = "integer", default = 1, min = 1, max = 8, desc = "murderers in a round" },
			sheriffs = { type = "integer", default = 1, min = 0, max = 8, desc = "sheriffs in a round" },
			penalty = { type = "enum", values = { "drop", "kill", "none" }, default = "drop",
				desc = "what a player who kills an innocent pays: drops his firearms, dies or nothing" },
			aliases = { type = "boolean", default = true, desc = "players see aliases instead of names" },
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
		Loadout = function(round, ply)
			self:Loadout(round, ply)
		end,
		PlayerDied = function(round, ply, _, attacker)
			self:Died(round, ply, attacker)
		end,
		CheckWin = function(round)
			return self:CheckWin(round)
		end,
		Timeout = function()
			return { reason = "time", key = "mode_homicide.win.innocents" }
		end,
		End = function(round)
			self:Reveal(round)
		end,
		Cleanup = function()
			self.ctx.components.alias:Clear()
		end,
	}, ctx)
end

-- Firearms and their ammunition: the weapon slots and the ammo trait of the package.
function M:IsFirearm(def)
	if def == nil then
		return false
	end
	local weapon = def.traits.weapon
	return def.traits.ammo ~= nil or (weapon ~= nil and M.FIREARM_SLOTS[weapon.slot or "primary"] == true)
end

function M:Setup(round)
	local variant = round.params.variant
	if variant == "random" then
		variant = M.VARIANTS[M.Random(#M.VARIANTS)]
	end
	round.data.variant = variant
	if round.params.aliases and self.appearance ~= nil then
		round:On("appearance.look", function(_, ply)
			return self:AliasLook(ply)
		end)
	end
	if variant == "gunfree" then
		round:On("loot.allow", function(_, def)
			if self:IsFirearm(def) then
				return false
			end
		end)
	end
	if self.notices ~= nil then
		self.notices:Broadcast("mode_homicide.variant." .. variant, nil, "info", { chat = true })
	end
end

-- Roles for the ready players: at least one innocent is left; aliases in a random order.
function M:Deal(round, ready)
	local count, params, data = #ready, round.params, round.data
	local murderers = max(1, min(params.murderers, count - 1))
	local sheriffs = max(0, min(params.sheriffs, count - murderers - 1))
	data.deal = self.roles:Deal(ready, { { "murderer", murderers }, { "sheriff", sheriffs } }, "innocent")
	local order = {}
	for i = 1, min(count, 255) do
		order[i] = i
	end
	for i = #order, 2, -1 do
		local j = M.Random(i)
		order[i], order[j] = order[j], order[i]
	end
	data.aliases, data.given = order, 0
end

-- The look of the alias of a participant (appearance), or nil without an alias.
function M:AliasLook(ply)
	local alias = self.ctx.components.alias:Get(ply)
	local appearance = self.appearance
	if alias == nil or alias.index == 0 or appearance == nil then
		return nil
	end
	return appearance:Pick(appearance:GenderOf(ply), alias.index)
end

function M:Join(round, ply)
	local data = round.data
	self.roles:Assign(ply, data.deal ~= nil and data.deal[ply] or "innocent")
	if round.params.aliases then
		data.given = (data.given or 0) + 1
		local index = data.aliases ~= nil and data.aliases[data.given] or data.given
		self.ctx.components.alias:Add(ply, { index = min(index, 255) })
	end
end

function M:Loadout(round, ply)
	local role = self.roles:Of(ply) or "innocent"
	local variant = round.data.variant or "standard"
	self:_Equip(ply, M.KITS[variant][role] or "", M.WEAPONS[variant][role] or {})
	-- Empty hands: a weapon in the hands would give the role away.
	local hands = self.hands
	if hands ~= nil and ply:HasWeapon(hands.CLASS) then
		ply:SelectWeapon(hands.CLASS)
	end
end

function M:_Equip(ply, kit, weapons)
	local inventory = self.inventory
	if inventory ~= nil and kit ~= "" then
		if inventory:Kit(kit) ~= nil then
			inventory:GiveKit(ply, kit, { drop = true })
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

-- A player of the innocent side killed an innocent: the penalty of the round.
function M:Died(round, victim, killer)
	if killer == nil or not IsValid(killer) or not killer:IsPlayer() or killer == victim then
		return
	end
	local roles = self.roles
	if roles:Side(victim) ~= "innocent" or roles:Side(killer) ~= "innocent" then
		return
	end
	local penalty = round.params.penalty
	if penalty == "none" or not round:IsParticipant(killer) or not self.players:IsAlive(killer) then
		return
	end
	if penalty == "kill" then
		-- Not from inside this death.
		round:After(0, function()
			if IsValid(killer) and self.players:IsAlive(killer) then
				self.players:Kill(killer)
			end
		end)
	else
		self:DropFirearms(killer)
	end
	if self.notices ~= nil then
		self.notices:Send(killer, "mode_homicide.penalty." .. penalty, nil, "bad")
	end
end

-- The firearms of a player fall to the ground (the ammunition stays).
function M:DropFirearms(ply)
	local inventory = self.inventory
	if inventory == nil then
		for _, weapon in ipairs(ply:GetWeapons()) do
			if weapon:GetMaxClip1() > 0 then
				ply:DropWeapon(weapon)
			end
		end
		return
	end
	for _, item in ipairs(inventory:ItemsOf(ply)) do
		local weapon = inventory:Trait(item.id, "weapon")
		if weapon ~= nil and M.FIREARM_SLOTS[weapon.slot or "primary"] then
			inventory:DropItem(ply, item)
		end
	end
end

function M:CheckWin(round)
	local roles, players = self.roles, self.players
	local murderers, armed, innocents, last = 0, 0, 0, nil
	for _, ply in ipairs(round:Participants()) do
		local side, alive = roles:Side(ply), players:IsAlive(ply)
		if side == "murderer" then
			murderers = murderers + 1
			if alive then
				armed, last = armed + 1, ply
			end
		elseif side == "innocent" and alive then
			innocents = innocents + 1
		end
	end
	if armed == 0 then
		local reason = murderers == 0 and "mode_homicide.reason.fled" or "mode_homicide.reason.stopped"
		return { reason = reason, key = "mode_homicide.win.innocents" }
	end
	if innocents == 0 then
		if armed == 1 then
			return { reason = "mode_homicide.reason.innocents", key = "mode_homicide.win.murderer", winner = last }
		end
		return { reason = "mode_homicide.reason.innocents", key = "mode_homicide.win.murderers" }
	end
	return nil
end

-- Who was who, in the chat of everybody: "The murderer was Bravo (Gordon)".
function M:Reveal(round)
	local notices = self.notices
	if notices == nil then
		return
	end
	for _, role in ipairs({ "murderer", "sheriff" }) do
		for _, ply in ipairs(self.roles:Members(role)) do
			if round:IsParticipant(ply) then
				local name, alias = ply:Nick(), self:Alias(ply)
				local who = alias ~= nil and alias .. " (" .. name .. ")" or name
				notices:Broadcast("mode_homicide.reveal." .. role, { who = who }, "info", { chat = true })
			end
		end
	end
end
