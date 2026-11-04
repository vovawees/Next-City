-- Weapons, server part: giving weapons and the console.
--
-- Commands: nc_weapons — the registered weapons; nc_give <player> <class> [reserve] — a
--           loaded weapon and rounds of its ammo in reserve (two magazines by default),
--           or any other scripted weapon as the engine gives it.

local M = NC.Module("weapons")

local format = string.format
local concat = table.concat
local IsValid = IsValid

function M:_InitServer(ctx)
	ctx.commands:Add("nc_weapons", { help = "registered weapons", admin = false }, "WeaponsCommand")
	ctx.commands:Add("nc_give", { help = "gives a loaded weapon: <player> <class> [reserve rounds]" }, "GiveCommand")
end

-- Gives `ply` the weapon `class` of the registry (or refills the one he has), loaded with
-- its default rounds. opts: ammo (another type of its caliber), empty (unloaded),
-- reserve (rounds of that type to the engine reserve). Returns the weapon, or nil and why.
function M:Give(ply, class, opts)
	opts = opts or {}
	local def = self.defs[class]
	if def == nil then
		return nil, format("unknown weapon '%s'", tostring(class))
	end
	local ammoId = opts.ammo or def.ammo
	local round = self.ammo:Get(ammoId)
	if round == nil or round.caliber ~= def.caliber then
		return nil, format("%s does not fit %s (caliber %s)", tostring(ammoId), class, def.caliber)
	end
	if not IsValid(ply) or not ply:Alive() then
		return nil, "the player is not alive"
	end
	local weapon = ply:GetWeapon(class)
	if not IsValid(weapon) then
		weapon = ply:Give(class, true)
	end
	if not IsValid(weapon) then
		return nil, format("%s cannot be given", class)
	end
	weapon:SetClip1(opts.empty and 0 or def.capacity)
	weapon:SetLoaded(game.GetAmmoID(ammoId))
	if (opts.reserve or 0) > 0 then
		ply:GiveAmmo(opts.reserve, ammoId, true)
	end
	return weapon
end

function M:WeaponsCommand()
	if #self.order == 0 then
		return "nc_weapons: no weapons (packages register them)"
	end
	local lines = { format("nc_weapons: %d weapons", #self.order) }
	for _, class in ipairs(self.order) do
		local def = self.defs[class]
		lines[#lines + 1] = format("  %-20s %-10s %3d%s %5d rpm  %-15s %-8s %.1f / %.1f s  %s", class, def.caliber,
			def.magazine, def.chamber and "+1" or "  ", def.rpm, concat(def.modes, "/"), def.reloadMode, def.reload,
			def.reloadEmpty, self:Name(class))
	end
	return lines
end

function M:GiveCommand(caller, args)
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return "nc_give: " .. problem
	end
	local class = args[2]
	local def = self.defs[class or ""]
	if def == nil then
		-- Any other scripted weapon (melee, the hands of a package) as the engine gives it.
		if class ~= nil and weapons.GetStored(class) ~= nil and ply:Alive() then
			ply:Give(class)
			ply:SelectWeapon(class)
			return format("nc_give: %s got %s", ply:Nick(), class)
		end
		return format("nc_give: unknown weapon '%s'; firearms: %s", tostring(class),
			#self.order > 0 and concat(self.order, ", ") or "none")
	end
	local reserve = math.max(0, math.floor(tonumber(args[3] or "") or def.magazine * 2))
	local weapon, why = self:Give(ply, class, { reserve = reserve })
	if weapon == nil then
		return "nc_give: " .. why
	end
	ply:SelectWeapon(class)
	return format("nc_give: %s got %s and %d rounds of %s", ply:Nick(), class, reserve, def.ammo)
end
