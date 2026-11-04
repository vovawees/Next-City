-- Ammo, server part: the damage pipeline knows every registered type, so engine bullets
-- of it (FireBullets of other weapons) injure like its projectiles; nc_ammo lists them.

local M = NC.Module("ammo")

local format = string.format

function M:_InitServer(ctx)
	self.damage = ctx:Require("damage")
	ctx.commands:Add("nc_ammo", { help = "registered ammunition: [caliber]", admin = false }, "AmmoCommand")
end

function M:_Registered(entry)
	self.damage:RegisterAmmo(entry.id, entry)
end

function M:AmmoCommand(_, args)
	local caliber = args[1]
	local ids = caliber ~= nil and self:OfCaliber(caliber) or self:All()
	if #ids == 0 then
		return caliber ~= nil and format("nc_ammo: no ammunition of caliber %s", caliber) or "nc_ammo: no ammunition"
	end
	local lines = { format("nc_ammo: %d types (energy at 0 / 100 / 300 m)", #ids) }
	for _, id in ipairs(ids) do
		local def = self.types[id]
		local _, e0 = self:At(id, 0)
		local _, e100 = self:At(id, 100)
		local _, e300 = self:At(id, 300)
		lines[#lines + 1] = format("  %-20s %-10s %5.1f g %4d m/s %4.1f mm%s  %d / %d / %d J%s", id, def.caliber,
			def.mass, def.velocity, def.diameter, def.pellets > 1 and format(" x%d", def.pellets) or "", e0, e100,
			e300, def.ap ~= 1 and format("  ap %.1f", def.ap) or "")
	end
	return lines
end
