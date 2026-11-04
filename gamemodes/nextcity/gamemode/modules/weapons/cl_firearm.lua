-- Weapons, client part: what the shooter sees of the firearm base.
--   sights  the viewmodel moves to def.sights as they rise, the view narrows to
--           sights.fov of itself and the mouse slows down with it
--   sway    the viewmodel turns about the eyes with the sway of the aim, so the sights
--           show where the shot goes; the sway and bob of the engine fade while aiming
--   lowered while sprinting or when the body cannot hold it; a shot kicks it back
--   names   PrintName is the translated name, again when the language changes
--   mode    the name of the fire mode for a moment after a switch (DrawHUD)
--
-- Listens: i18n.changed.

local M = NC.Module("weapons")
local FIREARM = M.FIREARM

local CurTime = CurTime
local RealTime = RealTime
local FrameTime = FrameTime
local IsFirstTimePredicted = IsFirstTimePredicted
local Angle = Angle
local min = math.min
local max = math.max

local MODE_TIME = 1.5  -- s the new fire mode is shown
local KICK_TIME = 0.08 -- s the viewmodel takes to come back after a shot
local LOWERING = 5     -- 1/s: how fast the weapon goes down and up
local HINT = Color(235, 235, 235, 255)

function M:_InitClient(ctx)
	ctx:On("i18n.changed", "_Rename")
end

-- The registered weapons and the ones that exist take their translated names.
function M:_Rename()
	for _, class in ipairs(self.order) do
		local name = self:Name(class)
		local stored = weapons.GetStored(class)
		if stored ~= nil then
			stored.PrintName = name
		end
		for _, weapon in ipairs(ents.FindByClass(class)) do
			weapon.PrintName = name
		end
	end
end

function FIREARM:_ModeChanged()
	if IsFirstTimePredicted() then
		self.modeShown = RealTime()
	end
end

function FIREARM:_Kicked()
	if IsFirstTimePredicted() then
		self.kicked = RealTime()
	end
end

-- How far the weapon is lowered, 0 to 1, eased every frame.
function FIREARM:_Lowered(owner)
	local target = self:CanFire(owner) and 0 or 1
	local current, step = self.lowered or 0, FrameTime() * LOWERING
	current = target > current and min(target, current + step) or max(target, current - step)
	self.lowered = current
	return current
end

-- Where the viewmodel is drawn: turned with the sway about the eyes, at the sights as
-- they rise, lowered, kicked back by a shot.
function FIREARM:GetViewModelPosition(pos, ang)
	local def = self:Def()
	local owner = self:_Player()
	if def == nil or owner == nil then
		return pos, ang
	end
	local now = CurTime()
	local aim = self:AimFraction(now)
	local pitch, yaw = self:SwayAt(owner, now, M.organism:Capabilities(owner))
	ang = Angle(ang)
	ang:RotateAroundAxis(ang:Right(), -pitch)
	ang:RotateAroundAxis(ang:Up(), yaw)
	local sights = def.sights
	if sights ~= nil and aim > 0 then
		if sights.ang ~= nil then
			local x, y, z = sights.ang:Unpack()
			ang:RotateAroundAxis(ang:Right(), x * aim)
			ang:RotateAroundAxis(ang:Up(), y * aim)
			ang:RotateAroundAxis(ang:Forward(), z * aim)
		end
		if sights.pos ~= nil then
			local x, y, z = sights.pos:Unpack()
			pos = pos + ang:Right() * (x * aim) + ang:Forward() * (y * aim) + ang:Up() * (z * aim)
		end
	end
	local lowered = self:_Lowered(owner)
	if lowered > 0 then
		ang:RotateAroundAxis(ang:Right(), -18 * lowered)
		ang:RotateAroundAxis(ang:Up(), 20 * lowered)
		pos = pos - ang:Up() * (2 * lowered)
	end
	local kick = self.kicked ~= nil and 1 - (RealTime() - self.kicked) / KICK_TIME or 0
	if kick > 0 then
		pos = pos - ang:Forward() * (def.recoil.kick * kick)
	end
	local steady = 1 - 0.85 * aim
	self.SwayScale, self.BobScale = steady, steady
	return pos, ang
end

-- The share of the view left at the sights.
function FIREARM:_Zoom()
	local def = self:Def()
	if def == nil or def.sights == nil then
		return 1
	end
	return 1 - (1 - def.sights.fov) * self:AimFraction(CurTime())
end

function FIREARM:TranslateFOV(fov)
	return fov * self:_Zoom()
end

function FIREARM:AdjustMouseSensitivity()
	local zoom = self:_Zoom()
	return zoom < 1 and zoom or nil
end

function FIREARM:DrawHUD()
	local shown = self.modeShown
	if shown == nil or self:Def() == nil then
		return
	end
	local left = shown + MODE_TIME - RealTime()
	if left <= 0 then
		self.modeShown = nil
		return
	end
	HINT.a = 255 * min(1, left / 0.4)
	draw.SimpleText(M.ctx.i18n:T("weapons.mode." .. self:FireMode()), "DermaLarge", ScrW() * 0.5, ScrH() * 0.8, HINT,
		TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end
