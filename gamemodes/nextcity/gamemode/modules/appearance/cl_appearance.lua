-- Appearance, the client: the appearance tab of the menu (F1) — a preview of the look, the sets
-- for the gender of the character, their models, the skin and bodygroups the model has, the
-- color of the clothes (a palette and a mixer), saving — and the color of the clothes on
-- bodies and corpses.
--
--   appearance:Look()   -> the player's own { model ("" while none), skin, bodygroups, color,
--                          random, ready } or nil
--   appearance:Wait()   -> s before he may change his look again (0: now)
--   appearance:Gender() -> the gender of his character (identity) or nil
--   appearance:Ask(look) asks the server to save a look
--   appearance:Draft()  -> the look picked in the tab and not saved yet, or nil

local M = NC.Module("appearance")

local LocalPlayer = LocalPlayer
local IsValid = IsValid
local CurTime = CurTime
local Entity = Entity
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local ceil = math.ceil
local max = math.max
local format = string.format
local concat = table.concat

local ORDER = 30          -- after the character
local CHECK = 0.5         -- s between the looks for bodies that came late (clothes)
local PREVIEW_WIDE = 220
local PREVIEW_TALL = 300
local ICON = 64
local SPACE = 4
local PER_ROW = 7         -- icons of models in a row (a narrow menu fits 7)
local CAPTION_WIDE = 120
local SET_WIDE = 130
local STEP_WIDE = 40
local BUTTON_WIDE = 150
local SWATCH = 24
local MIXER_TALL = 120
local ROW = 38            -- a row of the menu with its margin
local IDLE = "idle_all_01"

function M:_InitClient(ctx)
	self.draft = nil -- the look picked in the tab and not saved yet
	self.shown = nil -- the look the tab shows (the draft or the saved one)
	local menu = ctx:Require("menu")
	if menu ~= nil then
		menu:AddTab("appearance", { title = "appearance.tab", order = ORDER,
			build = function(panel) self:_BuildTab(menu, panel) end,
			stamp = function() return self:_TabStamp() end })
	end
end

function M:_StartClient(ctx)
	ctx.components.clothes:OnChange("OnClothes")
	ctx:Every("clothes", CHECK, "DressBodies")
end

function M:Look()
	local me = LocalPlayer()
	return IsValid(me) and self.ctx.components.look:Get(me) or nil
end

function M:Wait()
	local look = self:Look()
	if look == nil or look.ready <= 0 then
		return 0
	end
	return max(0, look.ready - CurTime())
end

function M:Gender()
	local identity = self.identity
	local character = identity ~= nil and identity:Character() or nil
	return character ~= nil and character.gender or nil
end

function M:Draft()
	return self.draft
end

function M:Ask(look)
	look = M.CleanLook(look)
	if look == nil then
		return false
	end
	self.ctx.net:SendToServer("change", { model = look.model, skin = look.skin, bodygroups = look.bodygroups,
		color = look.color })
	return true
end

-- Bodies and corpses ------------------------------------------------------------------------

-- The material proxy of the player color asks the entity (a prop_ragdoll has no owner).
function M:_Tint(index, data)
	data = data or self.ctx.components.clothes:Get(index)
	local ent = Entity(index)
	if data == nil or not IsValid(ent) or ent.ncClothes == data.color then
		return
	end
	local color = M.ToVector(data.color)
	ent.ncClothes = data.color
	ent.GetPlayerColor = function()
		return color
	end
end

function M:OnClothes(index)
	self:_Tint(index)
end

function M:DressBodies()
	for index, data in self.ctx.components.clothes:Each() do
		self:_Tint(index, data)
	end
end

-- The tab -----------------------------------------------------------------------------------

-- Whether a mode dresses the living player in another model than the one of his look.
function M:_Dressed(look)
	local me = LocalPlayer()
	return IsValid(me) and me:Alive() and look.model ~= "" and M.Normalize(me:GetModel()) ~= look.model
end

function M:_TabStamp()
	local look = self:Look()
	if look == nil then
		return ""
	end
	return concat({ look.model, look.skin, concat(look.bodygroups, "."), look.color, tostring(look.random),
		tostring(self:Wait() > 0), tostring(self:Gender()), tostring(self:_Dressed(look)) }, " ")
end

-- The look the tab shows: the draft while it differs from the saved look and the gender may
-- wear it, else the saved look, else the first look of the sets.
function M:_Current(look, gender)
	local draft = self.draft
	if draft ~= nil and (M.SameLook(draft, look) or not self:Allows(draft.model, gender)) then
		self.draft, draft = nil, nil
	end
	if draft ~= nil then
		return draft
	end
	if look.model ~= "" and self:Allows(look.model, gender) then
		return look
	end
	return self:Pick(gender, 1)
end

function M:_Shown()
	return self.draft or self.shown or { model = "", skin = 0, bodygroups = {}, color = M.DEFAULT_COLOR }
end

-- Changes the draft (made from the look shown).
function M:_Edit(changes)
	local draft = self.draft
	if draft == nil then
		draft = M.CleanLook(self:_Shown()) or { model = "", skin = 0, bodygroups = {}, color = M.DEFAULT_COLOR }
		self.draft = draft
	end
	for key, value in pairs(changes) do
		draft[key] = value
	end
end

function M:_SetGroup(group, value)
	local groups = {}
	for i = 1, group + 1 do
		groups[i] = self:_Shown().bodygroups[i] or 0
	end
	groups[group + 1] = value
	self:_Edit({ bodygroups = groups })
end

function M:_Preview(parent, current)
	local preview = parent:Add("DModelPanel")
	preview:Dock(LEFT)
	preview:SetWide(PREVIEW_WIDE)
	preview:SetFOV(36)
	preview:SetCamPos(Vector(110, 0, 50))
	preview:SetLookAt(Vector(0, 0, 36))
	preview:SetAnimated(true)
	preview:SetModel(current.model)
	preview.ncPreview = true
	local ent = preview.Entity
	if IsValid(ent) then
		local sequence = ent:LookupSequence(IDLE)
		if sequence ~= nil and sequence > 0 then
			ent:ResetSequence(sequence)
		end
		ent:SetSkin(current.skin)
		for i, value in ipairs(current.bodygroups) do
			ent:SetBodygroup(i - 1, value)
		end
		ent.GetPlayerColor = function()
			return M.ToVector(self:_Shown().color)
		end
	end
	return preview, ent
end

function M:_Stepper(menu, parent, caption, id, value, count, apply)
	local row = menu:Row(parent)
	menu:Caption(row, caption, CAPTION_WIDE)
	local function step(dir)
		apply((value + dir) % count)
		menu:Refresh(true)
	end
	local back = menu:Button(row, "<", function() step(-1) end, STEP_WIDE, LEFT)
	back:DockMargin(0, 4, 4, 4)
	back.ncStep, back.ncDir = id, -1
	local forward = menu:Button(row, ">", function() step(1) end, STEP_WIDE, RIGHT)
	forward:DockMargin(4, 4, 6, 4)
	forward.ncStep, forward.ncDir = id, 1
	local label = menu:Value(row, format("%d / %d", value + 1, count))
	label:SetContentAlignment(5)
	label.ncValue = id
end

function M:_BuildTab(menu, panel)
	local i18n = self.ctx.i18n
	local colors, fonts = menu.COLORS, menu.FONTS
	menu:Heading(panel, i18n:T("appearance.heading"))
	local look = self:Look()
	if look == nil then
		menu:Label(panel, i18n:T("appearance.waiting"), colors.dim)
		return
	end
	local gender = self:Gender()
	local sets = self:Sets(gender)
	if sets[1] == nil then
		menu:Label(panel, i18n:T("appearance.none"), colors.dim)
		return
	end
	local current = self:_Current(look, gender)
	self.shown = current
	if look.model == "" then
		menu:Label(panel, i18n:T("appearance.nolook"), colors.dim)
	elseif look.random then
		menu:Label(panel, i18n:T("appearance.given"), colors.dim).ncGiven = true
	end
	if self:_Dressed(look) then
		menu:Label(panel, i18n:T("appearance.dressed"), colors.gold).ncDressed = true
	end

	-- The preview and the sets with their models.
	local active = self:SetOf(current.model, gender) or sets[1]
	local box = panel:Add("DPanel")
	box:Dock(TOP)
	box:DockMargin(0, 4, 0, 4)
	box:SetTall(max(PREVIEW_TALL, ROW + ceil(#active.models / PER_ROW) * (ICON + SPACE) + SPACE))
	box:SetPaintBackground(false)
	local _, ent = self:_Preview(box, current)
	local side = box:Add("DPanel")
	side:Dock(FILL)
	side:DockMargin(10, 0, 0, 0)
	side:SetPaintBackground(false)
	local row = menu:Row(side)
	menu:Caption(row, i18n:T("appearance.set"), CAPTION_WIDE)
	for _, set in ipairs(sets) do
		local button = menu:Button(row, i18n:T(set.title), function()
			if set ~= active then
				self:_Edit({ model = set.models[1], skin = 0, bodygroups = {} })
				menu:Refresh(true)
			end
		end, SET_WIDE, LEFT)
		button:DockMargin(0, 4, 4, 4)
		button.ncSet, button.ncActive = set.id, set == active
	end
	local grid = side:Add("DIconLayout")
	grid:Dock(TOP)
	grid:SetSpaceX(SPACE)
	grid:SetSpaceY(SPACE)
	local function outline(icon, w, h)
		if icon.ncActive then
			surface.SetDrawColor(colors.gold)
			surface.DrawOutlinedRect(0, 0, w, h, 2)
		end
	end
	for _, model in ipairs(active.models) do
		local icon = grid:Add("SpawnIcon")
		icon:SetSize(ICON, ICON)
		icon:SetModel(model)
		icon:SetTooltip(model)
		icon.PaintOver = outline
		icon.DoClick = function()
			if model ~= current.model then
				self:_Edit({ model = model, skin = 0, bodygroups = {} })
				menu:Refresh(true)
			end
		end
		icon.ncModel, icon.ncActive = model, model == current.model
	end

	-- What the model has: skins and bodygroups with a choice.
	if IsValid(ent) then
		local skins = ent:SkinCount() or 1
		if skins > 1 then
			self:_Stepper(menu, panel, i18n:T("appearance.skin"), "skin", current.skin % skins, skins, function(value)
				self:_Edit({ skin = value })
			end)
		end
		for group = 0, (ent:GetNumBodyGroups() or 0) - 1 do
			local count = ent:GetBodygroupCount(group) or 1
			if count > 1 then
				local value = (current.bodygroups[group + 1] or 0) % count
				self:_Stepper(menu, panel, tostring(ent:GetBodygroupName(group) or group), "bodygroup" .. group, value,
					count, function(chosen) self:_SetGroup(group, chosen) end)
			end
		end
	end

	-- The color of the clothes.
	row = menu:Row(panel)
	menu:Caption(row, i18n:T("appearance.color"), CAPTION_WIDE)
	local function swatch(button, w, h)
		draw.RoundedBox(4, 0, 0, w, h, button.ncActive and colors.white or button:IsHovered() and colors.hover
			or colors.button)
		draw.RoundedBox(4, 2, 2, w - 4, h - 4, button.ncFill)
	end
	for _, color in ipairs(M.PALETTE) do
		local r, g, b = M.Unpack(color)
		local button = row:Add("DButton")
		button:Dock(LEFT)
		button:SetWide(SWATCH)
		button:DockMargin(0, 5, 4, 5)
		button:SetText("")
		button.Paint = swatch
		button.DoClick = function()
			self:_Edit({ color = color })
			menu:Refresh(true)
		end
		button.ncColor, button.ncActive, button.ncFill = color, color == current.color, Color(r, g, b)
	end
	local mixer = panel:Add("DColorMixer")
	mixer:Dock(TOP)
	mixer:DockMargin(0, 0, 0, 4)
	mixer:SetTall(MIXER_TALL)
	mixer:SetPalette(false)
	mixer:SetAlphaBar(false)
	mixer:SetWangs(true)
	local r, g, b = M.Unpack(current.color)
	mixer:SetColor(Color(r, g, b))
	mixer.ValueChanged = function(_, color)
		local packed = M.Pack(color.r, color.g, color.b)
		if packed ~= self:_Shown().color then
			self:_Edit({ color = packed })
		end
	end
	mixer.ncMixer = true

	-- Saving.
	row = menu:Row(panel)
	local dice = menu:Button(row, i18n:T("appearance.random"), function()
		local random = self:RandomLook(gender)
		if random ~= nil then
			self.draft = random
			menu:Refresh(true)
		end
	end, BUTTON_WIDE, LEFT)
	dice:DockMargin(0, 4, 4, 4)
	dice.ncAction = "random"
	local undo = menu:Button(row, i18n:T("appearance.undo"), function()
		self.draft = nil
		menu:Refresh(true)
	end, BUTTON_WIDE, LEFT)
	undo:DockMargin(0, 4, 4, 4)
	undo.ncAction = "undo"
	local save = menu:Button(row, i18n:T("appearance.save"), function()
		self:Ask(self:_Shown())
	end, nil, FILL)
	save:DockMargin(0, 4, 4, 4)
	save.ncAction = "save"
	if self.draft ~= nil then
		menu:Label(panel, i18n:T("appearance.unsaved"), colors.gold).ncUnsaved = true
	end
	local wait = self:Wait()
	if wait > 0 then
		menu:Label(panel, i18n:T("appearance.wait", { count = ceil(wait) }), colors.gold).ncWait = true
	end
	menu:Label(panel, i18n:T("appearance.hint"), colors.dim, fonts.small)
end
