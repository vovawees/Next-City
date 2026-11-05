-- Ragdoll, client part: the camera of the local player while it lies in its body or
-- looks out of its corpse, the head of that body and the hints.
--
-- Camera (gm.CalcView, before the effects that shake it): fallen — at the eyes of the
-- body, looking where the player looks; unconscious — the eyes and where they point;
-- getting up — from the eyes of the body up to the eyes of the player within
-- config.getUpTime; dead — the eyes of the corpse until an observer camera takes over.
-- The near plane comes close and the head of the body shrinks away while the camera is
-- in it. The eyes are kept in the frame of the head bone (measured once per model while
-- the head is whole), so a shrunk head does not move them.
-- Hints at the bottom of the screen: the key to get up once the body may, or why it
-- cannot (the legs, no room, still moving), and getting up. Texts are rebuilt when the
-- state, the reason or the language change, never every frame. The crosshair and the
-- weapon elements are hidden while down.
--
-- Listens:  component body, organism.capabilities, i18n.changed, gm.StartCommand
--           (sh_ragdoll.lua), gm.CalcView (priority 100), gm.HUDPaint, gm.HUDShouldDraw.
-- Commands: nc_fall — fall down, or get up (bind g nc_fall).

local M = NC.Module("ragdoll")

local CurTime = CurTime
local Entity = Entity
local IsValid = IsValid
local LocalPlayer = LocalPlayer
local LocalToWorld = LocalToWorld
local WorldToLocal = WorldToLocal
local ScrW = ScrW
local ScrH = ScrH
local Vector = Vector
local Angle = Angle
local upper = string.upper
local OBS_MODE_NONE = OBS_MODE_NONE

local FONT = "NC.Ragdoll"
local WHITE = Color(255, 255, 255)
local OUTLINE = Color(0, 0, 0, 200)
local HEAD = "ValveBiped.Bip01_Head1"
-- The scale of a hidden head: not 0, the angles of a bone shrunk to nothing are lost.
local SHRUNK = Vector(0.01, 0.01, 0.01)
local WHOLE = Vector(1, 1, 1)
local NEAR = 1        -- units: the near plane of the camera in a body
local HEAD_BACK = 0.25 -- share of getting up after which the head is drawn again
local ENTRY = {}      -- self.down[ply] while the local player lies in its body (no input kept)

-- HL2 elements hidden while down.
M.HIDDEN_DOWN = { CHudCrosshair = true, CHudAmmo = true, CHudSecondaryAmmo = true, CHudWeaponSelection = true,
	CHudZoom = true }

surface.CreateFont(FONT, { font = "Roboto", size = 22, weight = 600, extended = true })

function M:Init(ctx)
	self.organism = ctx:Require("organism")
	self.down = {}          -- ply -> ENTRY while the local player lies in its body (sh_ragdoll.lua)
	self.state = "standing"
	self.index = 0          -- entity index of the body or the corpse
	self.since = 0
	self.blocked = "none"
	self.canStand = true
	self.eyes = {}          -- model -> { bone, pos, ang } (the eyes in the frame of the head) or false
	self.shrunk = nil       -- the entity whose head is shrunk, and the bone
	self.shrunkBone = nil
	self.hint = nil
	self.hintKey = nil      -- what the hint was built for
	ctx.components.body:OnChange("OnBody")
	ctx.commands:Add("nc_fall", { help = "fall down, or get up" }, "FallCommand")
	local playerMenu = ctx:Require("menu")
	if playerMenu ~= nil then
		playerMenu:AddHelp("ragdoll.up", { bind = "+jump", fallback = "space", text = "ragdoll.help.up", order = 80 })
		playerMenu:AddHelp("ragdoll.fall", { bind = "nc_fall", text = "ragdoll.help.fall", order = 81 })
	end
end

function M:Start(ctx)
	ctx:On("gm.StartCommand", "OnStartCommand", { priority = 10 })
	ctx:On("gm.CalcView", "View", { priority = 100 })
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("gm.HUDShouldDraw", "ShouldDraw")
	ctx:On("organism.capabilities", "OnCapabilities")
	ctx:On("i18n.changed", "Invalidate")
	local ply = LocalPlayer()
	if IsValid(ply) then
		self:OnCapabilities(ply, self.organism:Capabilities(ply))
		local data = ctx.components.body:Get(ply)
		if data ~= nil then
			self:OnBody(ply:EntIndex(), data, 0)
		end
	end
end

function M:Stop()
	self:_Unshrink()
end

function M:FallCommand()
	self.ctx.net:SendToServer("fall", {})
end

function M:OnBody(index, data)
	local ply = LocalPlayer()
	if not IsValid(ply) or index ~= ply:EntIndex() then
		return
	end
	if data == nil then
		self.state, self.index, self.since, self.blocked = "standing", 0, 0, "none"
	else
		self.state, self.index, self.since, self.blocked = data.state, data.ent, data.since, data.blocked
	end
	self.down[ply] = M.DOWN[self.state] and ENTRY or nil
	self.hintKey = nil
end

function M:OnCapabilities(_, caps)
	self.canStand = caps == nil or caps.canStand or not self.ctx.config.fallWhenWeak
	self.hintKey = nil
end

function M:Invalidate()
	self.hintKey = nil
end

-- API ------------------------------------------------------------------------------------------

-- The state of the local player's body (sh_ragdoll.lua: M.STATES).
function M:State()
	return self.state
end

function M:IsDown()
	return M.DOWN[self.state] == true
end

-- The body or the corpse of the local player, or nil (none, or not known here yet).
function M:Ragdoll()
	local index = self.index
	if index == 0 then
		return nil
	end
	local ent = Entity(index)
	if IsValid(ent) then
		return ent
	end
	return nil
end

-- Camera ---------------------------------------------------------------------------------------

-- The eyes of the model of `rag` in the frame of its head bone, or false without the bone.
function M:_EyesOf(rag)
	local model = rag:GetModel()
	local eyes = self.eyes[model]
	if eyes ~= nil then
		return eyes
	end
	eyes = false
	local bone = rag:LookupBone(HEAD)
	local pos, ang
	if bone ~= nil then
		pos, ang = rag:GetBonePosition(bone)
	end
	if pos ~= nil then
		eyes = { bone = bone, pos = Vector(0, 0, 0), ang = Angle(0, 0, 0) }
		local id = rag:LookupAttachment("eyes")
		local att = id ~= nil and id > 0 and rag:GetAttachment(id) or nil
		if att ~= nil then
			eyes.pos, eyes.ang = WorldToLocal(att.Pos, att.Ang, pos, ang)
		end
	end
	self.eyes[model] = eyes
	return eyes
end

-- Where the eyes of `rag` are and where they point, and the head bone; or nil.
function M:_Eyes(rag)
	local eyes = self:_EyesOf(rag)
	if eyes == false then
		local id = rag:LookupAttachment("eyes")
		local att = id ~= nil and id > 0 and rag:GetAttachment(id) or nil
		if att == nil then
			return nil
		end
		return att.Pos, att.Ang, nil
	end
	local pos, ang = rag:GetBonePosition(eyes.bone)
	if pos == nil then
		return nil
	end
	pos, ang = LocalToWorld(eyes.pos, eyes.ang, pos, ang)
	return pos, ang, eyes.bone
end

-- Shrinks the head `bone` of `rag` away (bone nil: gives the head back).
function M:_Shrink(rag, bone)
	if self.shrunk == rag and self.shrunkBone == bone then
		return
	end
	self:_Unshrink()
	if bone ~= nil then
		rag:ManipulateBoneScale(bone, SHRUNK)
		self.shrunk, self.shrunkBone = rag, bone
	end
end

function M:_Unshrink()
	local rag = self.shrunk
	if rag ~= nil and IsValid(rag) then
		rag:ManipulateBoneScale(self.shrunkBone, WHOLE)
	end
	self.shrunk, self.shrunkBone = nil, nil
end

-- The view of the local player while it lies in its body or looks out of its corpse.
function M:View(view, ply)
	local state = self.state
	local rag = nil
	if state ~= "standing" and ply == LocalPlayer()
		and (state ~= "dead" or ply:GetObserverMode() == OBS_MODE_NONE) then
		rag = self:Ragdoll()
	end
	if rag == nil then
		if self.shrunk ~= nil then
			self:_Unshrink()
		end
		return
	end
	rag:SetupBones()
	local pos, ang, bone = self:_Eyes(rag)
	if pos == nil then
		self:_Unshrink()
		return
	end
	if state == "getting_up" then
		local t = (CurTime() - self.since) / self.ctx.config.getUpTime
		t = t <= 0 and 0 or t >= 1 and 1 or t * t * (3 - 2 * t)
		local x, y, z = pos:Unpack()
		local tx, ty, tz = ply:EyePos():Unpack()
		pos:SetUnpacked(x + (tx - x) * t, y + (ty - y) * t, z + (tz - z) * t)
		if t > HEAD_BACK then
			bone = nil
		end
	elseif state ~= "fallen" then
		view.angles = ang
	end
	self:_Shrink(rag, bone)
	view.origin = pos
	view.znear = NEAR
	view.drawviewer = false
end

-- Hints ---------------------------------------------------------------------------------------

-- The hint for now, or nil.
function M:_HintKey()
	local state = self.state
	if state == "getting_up" then
		return "gettingUp"
	end
	if state ~= "fallen" then
		return nil
	end
	if not self.canStand then
		return "legs"
	end
	if self.blocked ~= "none" then
		return self.blocked -- room, moving
	end
	if CurTime() - self.since >= self.ctx.config.getUpDelay then
		return "getUp"
	end
	return nil
end

function M:Paint()
	local key = self:_HintKey()
	if key == nil then
		return
	end
	if key ~= self.hintKey then
		self.hintKey = key
		self.hint = self.ctx.i18n:T("ragdoll." .. key, { key = upper(input.LookupBinding("+jump") or "space") })
	end
	draw.SimpleTextOutlined(self.hint, FONT, ScrW() * 0.5, ScrH() - 96, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM,
		1, OUTLINE)
end

function M:ShouldDraw(name)
	if M.HIDDEN_DOWN[name] and M.DOWN[self.state] then
		return false
	end
end
