-- Inventory, client part: the screen and the hint under the crosshair.
--
-- The screen (the context menu key, C by default, or nc_inventory) shows the player's own
-- containers on the left (equipment, pockets, bags) and what he has open on the right (a
-- crate, a body, a bag in them). It opens by itself when he searches something.
--   drag a slot onto a slot      moves the stack (Shift: half, Ctrl: one) there
--   drag onto a title            moves it to the first slot of that container that fits
--   drag onto the empty right    puts it on the ground
--   right click                  the verbs of the item and "move to"
--   double click                 takes it (from others) or does its first verb
-- The hint names the thing on the ground or the place in front of the player and the
-- key to use it.
--
-- Listens: gm.PlayerBindPress (+menu_context), gm.HUDPaint, inventory.updated,
--          inventory.closed, i18n.changed.
-- Emits:   inventory.screen (open)  client: the screen opened (true) or closed (false)

local M = NC.Module("inventory")

local IsValid = IsValid
local LocalPlayer = LocalPlayer
local ScrW = ScrW
local ScrH = ScrH
local ipairs = ipairs
local tostring = tostring
local max = math.max
local min = math.min
local floor = math.floor
local ceil = math.ceil
local format = string.format
local concat = table.concat

local FONT = "NC.Inventory"
local FONT_SMALL = "NC.InventorySmall"
local FONT_HINT = "NC.InventoryHint"
local DRAG = "nc_item"
local SLOT = 58       -- px of a slot
local GAP = 4         -- px between slots
local COLUMNS = 6
local HEADER = 28     -- px of the title of a container
local PAD = 10

local WHITE = Color(235, 235, 235)
local DIM = Color(150, 150, 150)
local BACK = Color(18, 20, 24, 235)
local PANEL = Color(30, 33, 38, 230)
local SLOT_BACK = Color(42, 46, 52, 235)
local SLOT_HOVER = Color(62, 68, 76, 245)
local BORDER = Color(70, 76, 86, 255)
local OUTLINE = Color(0, 0, 0, 200)
local WORN = Color(220, 90, 70)
local GOOD = Color(120, 200, 120)

-- The colour of the stripe of a slot by the category of its item.
M.CATEGORY_COLORS = {
	weapon = Color(205, 95, 75),
	ammo = Color(210, 175, 75),
	medical = Color(95, 185, 115),
	armor = Color(95, 135, 205),
	gear = Color(155, 120, 205),
	tool = Color(170, 170, 175),
	food = Color(205, 145, 90),
	valuable = Color(235, 205, 85),
	misc = Color(125, 125, 130),
}

surface.CreateFont(FONT, { font = "Roboto", size = 18, weight = 600, extended = true })
surface.CreateFont(FONT_SMALL, { font = "Roboto", size = 14, weight = 500, extended = true })
surface.CreateFont(FONT_HINT, { font = "Roboto", size = 20, weight = 500, extended = true })

function M:_InitScreen(ctx)
	self.frame = nil
	self.screenDirty = false
	self.hintKey = nil  -- what the hint was built for
	self.hintLines = nil
	ctx.commands:Add("nc_inventory", { help = "opens or closes the inventory screen" }, "ScreenCommand")
	local playerMenu = ctx:Require("menu")
	if playerMenu ~= nil then
		playerMenu:AddHelp("inventory.screen", { bind = "+menu_context", fallback = "c", text = "inventory.help.screen",
			order = 50 })
		playerMenu:AddHelp("inventory.use", { bind = "+use", fallback = "e", text = "inventory.help.use", order = 60 })
	end
end

function M:_StartScreen(ctx)
	ctx:On("gm.PlayerBindPress", "OnScreenBind")
	ctx:On("gm.HUDPaint", "PaintHint")
	ctx:On("inventory.updated", "OnScreenChange")
	ctx:On("inventory.closed", "OnScreenChange")
	ctx:On("i18n.changed", "OnScreenLanguage")
end

function M:Stop()
	self:CloseScreen()
end

-- Texts ------------------------------------------------------------------------------------

function M:_T(key, params, fallback)
	local i18n = self.ctx.i18n
	if key ~= nil and i18n:Has(key) then
		return i18n:T(key, params)
	end
	return fallback or tostring(key)
end

-- The translated title of a container snapshot (without a translation: of its kind).
function M:Title(c)
	local params = { name = c.name }
	local i18n = self.ctx.i18n
	if c.title ~= nil and i18n:Has(c.title) then
		return i18n:T(c.title, params)
	end
	return self:_T("inventory.kind." .. c.kind, params, c.name ~= "" and c.name or c.kind)
end

local function kg(value)
	return format("%.1f", value)
end

-- What the player carries, kg (the bags count in the containers they lie in).
function M:ScreenLoad()
	local load = 0
	for _, c in ipairs(self:Own()) do
		if c.parent == 0 then
			load = load + c.weight
		end
	end
	return load
end

function M:_Tooltip(item, def)
	local lines = { self:Name(item.id) }
	local description = self:Description(item.id)
	if description ~= nil then
		lines[#lines + 1] = description
	end
	if def ~= nil then
		lines[#lines + 1] = self:_T("inventory.screen.weight", { weight = kg(def.weight * item.count) })
	end
	if item.cond < 1 then
		lines[#lines + 1] = self:_T("inventory.screen.condition", { value = floor(item.cond * 100 + 0.5) })
	end
	return concat(lines, "\n")
end

-- Opening and closing ----------------------------------------------------------------------

function M:IsScreenOpen()
	return IsValid(self.frame)
end

local function paintFrame(_, w, h)
	draw.RoundedBox(6, 0, 0, w, h, BACK)
end

local function paintColumn(_, w, h)
	draw.RoundedBox(4, 0, 0, w, h, PANEL)
end

-- Opens the screen (or rebuilds it when open). Returns the frame, or nil when the player
-- is not alive.
function M:OpenScreen()
	if IsValid(self.frame) then
		self:RebuildScreen()
		return self.frame
	end
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then
		return nil
	end
	local column = COLUMNS * SLOT + (COLUMNS - 1) * GAP + 2 * PAD + 14
	local frame = vgui.Create("DFrame")
	frame:SetSize(2 * column + 3 * PAD, min(ScrH() - 80, 640))
	frame:Center()
	frame:SetTitle("")
	frame:SetDraggable(true)
	frame:SetSizable(false)
	frame:ShowCloseButton(true)
	frame:MakePopup()
	frame:SetKeyboardInputEnabled(false)
	frame.Paint = paintFrame
	frame.OnRemove = function(panel)
		self:_ScreenRemoved(panel)
	end
	frame.Think = function()
		self:_ScreenThink()
	end
	local title = frame:Add("DLabel")
	title:Dock(TOP)
	title:SetTall(24)
	title:SetFont(FONT)
	title:SetTextColor(WHITE)
	local own = frame:Add("DScrollPanel")
	own:Dock(LEFT)
	own:SetWide(column)
	own:DockMargin(0, 4, PAD, 0)
	own.Paint = paintColumn
	local external = frame:Add("DScrollPanel")
	external:Dock(FILL)
	external:DockMargin(0, 4, 0, 0)
	external.Paint = paintColumn
	self.frame, self.titleLabel, self.ownPanel, self.externalPanel = frame, title, own, external
	self:RebuildScreen()
	self.ctx.events:Emit("inventory.screen", true)
	return frame
end

-- Closes the screen and the containers of others the player had open.
function M:CloseScreen()
	if IsValid(self.frame) then
		self.frame:Remove()
	end
end

function M:ToggleScreen()
	if IsValid(self.frame) then
		self:CloseScreen()
	else
		self:OpenScreen()
	end
end

function M:ScreenCommand()
	self:ToggleScreen()
end

function M:_ScreenRemoved(frame)
	if self.frame ~= frame then
		return
	end
	self.frame, self.titleLabel, self.ownPanel, self.externalPanel = nil, nil, nil, nil
	self.screenDirty = false
	for _, c in ipairs(self:External()) do
		self:Close(c.id)
	end
	self.ctx.events:Emit("inventory.screen", false)
end

function M:_ScreenThink()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then
		self:CloseScreen()
		return
	end
	if self.screenDirty and not self:_Dragging() then
		self:RebuildScreen()
	end
end

function M:_Dragging()
	return dragndrop ~= nil and dragndrop.IsDragging() == true
end

function M:OnScreenBind(_, bind, pressed)
	if not pressed or bind ~= "+menu_context" then
		return nil
	end
	self:ToggleScreen()
	return true
end

function M:OnScreenChange()
	if IsValid(self.frame) then
		if self:_Dragging() then
			self.screenDirty = true -- a rebuild would drop the slot in the hand
		else
			self:RebuildScreen()
		end
	end
end

function M:OnScreenLanguage()
	self.hintKey = nil
	self:OnScreenChange()
end

-- Building ---------------------------------------------------------------------------------

-- Builds the screen anew from the snapshots.
function M:RebuildScreen()
	if not IsValid(self.frame) then
		return
	end
	self.screenDirty = false
	self.titleLabel:SetText(self:_T("inventory.screen.title", { load = kg(self:ScreenLoad()) }, "Inventory"))
	self.ownPanel:Clear()
	self.externalPanel:Clear()
	local receive = function(receiver, panels, dropped)
		if dropped and panels ~= nil and panels[1] ~= nil then
			self:_Drop(panels[1], receiver)
		end
	end
	self.receive = receive
	for _, c in ipairs(self:Own()) do
		self:_BuildContainer(self.ownPanel, c, "own", receive)
	end
	local external = self:External()
	for _, c in ipairs(external) do
		self:_BuildContainer(self.externalPanel, c, "external", receive)
	end
	-- The empty right side: dropping there puts the thing on the ground.
	local ground = self.externalPanel
	ground.ncGround = true
	ground.ncReceive = receive
	ground:Receiver(DRAG, receive)
	if #external == 0 then
		local hint = ground:Add("DLabel")
		hint:Dock(TOP)
		hint:DockMargin(PAD, PAD, PAD, 0)
		hint:SetWrap(true)
		hint:SetAutoStretchVertical(true)
		hint:SetFont(FONT_SMALL)
		hint:SetTextColor(DIM)
		hint:SetText(self:_T("inventory.screen.nothing", { key = self:_UseKey() }))
	end
end

local function paintHeader(panel, w, h)
	surface.SetDrawColor(BORDER)
	surface.DrawRect(0, h - 1, w, 1)
	draw.SimpleText(panel.ncTitle, FONT, 2, h / 2, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
	draw.SimpleText(panel.ncInfo, FONT_SMALL, w - (panel.ncInfoRight or 2), h / 2, DIM, TEXT_ALIGN_RIGHT,
		TEXT_ALIGN_CENTER)
end

function M:_BuildContainer(parent, c, where, receive)
	local header = parent:Add("DPanel")
	header:Dock(TOP)
	header:DockMargin(PAD, PAD, PAD, 4)
	header:SetTall(HEADER)
	header.ncContainer, header.ncSlot = c.id, 0
	header.ncTitle = self:Title(c)
	local used = #c.items
	if c.maxWeight ~= nil then
		header.ncInfo = self:_T("inventory.screen.used", { used = used, size = c.size,
			weight = kg(c.weight) .. " / " .. kg(c.maxWeight) })
	else
		header.ncInfo = self:_T("inventory.screen.used", { used = used, size = c.size, weight = kg(c.weight) })
	end
	header.Paint = paintHeader
	header.ncReceive = receive
	header:Receiver(DRAG, receive)
	if where == "external" then
		local close = header:Add("DButton")
		close:Dock(RIGHT)
		close:SetWide(HEADER)
		close:SetText("×")
		close:SetTooltip(self:_T("inventory.screen.close"))
		close.ncAction = "close"
		close.DoClick = function()
			self:Close(c.id)
		end
		if c.parent == 0 and used > 0 then
			local all = header:Add("DButton")
			all:Dock(RIGHT)
			all:DockMargin(0, 2, 4, 2)
			all:SetWide(96)
			all:SetText(self:_T("inventory.verb.take_all"))
			all.ncAction = "take_all"
			all.DoClick = function()
				self:Act(c.id, 0, "take_all")
			end
		end
		header.ncInfoRight = HEADER + (c.parent == 0 and used > 0 and 104 or 4)
	end
	local grid = parent:Add("DIconLayout")
	grid:Dock(TOP)
	grid:DockMargin(PAD, 0, PAD, 4)
	grid:SetSpaceX(GAP)
	grid:SetSpaceY(GAP)
	grid:SetTall(ceil(c.size / COLUMNS) * (SLOT + GAP))
	for slot = 1, c.size do
		self:_BuildSlot(grid, c, slot, where, receive)
	end
end

local function paintSlot(button, w, h)
	surface.SetDrawColor(button:IsHovered() and SLOT_HOVER or SLOT_BACK)
	surface.DrawRect(0, 0, w, h)
	local item = button.ncItem
	if item == nil then
		if button.ncSlotName ~= nil then
			draw.SimpleText(button.ncSlotName, FONT_SMALL, w / 2, h / 2, DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		end
	else
		surface.SetDrawColor(button.ncColor)
		surface.DrawRect(0, h - 3, w, 3)
		if item.cond < 1 then
			surface.SetDrawColor(item.cond < 0.35 and WORN or GOOD)
			surface.DrawRect(2, h - 6, floor((w - 4) * item.cond), 2)
		end
		if button.ncCount ~= nil then
			draw.SimpleTextOutlined(button.ncCount, FONT_SMALL, w - 3, h - 4, WHITE, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM,
				1, OUTLINE)
		end
		if button.ncCorner ~= nil then
			draw.SimpleTextOutlined(button.ncCorner, FONT_SMALL, 3, 2, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, OUTLINE)
		end
	end
	surface.SetDrawColor(BORDER)
	surface.DrawOutlinedRect(0, 0, w, h)
	return true
end

function M:_BuildSlot(grid, c, slot, where, receive)
	local button = grid:Add("DButton")
	button:SetSize(SLOT, SLOT)
	button:SetText("")
	button.ncContainer, button.ncSlot, button.ncWhere, button.ncKind = c.id, slot, where, c.kind
	button.Paint = paintSlot
	button.ncReceive = receive
	button:Receiver(DRAG, receive)
	local name = c.slotNames ~= nil and c.slotNames[slot] or nil
	if name ~= nil and name ~= "" then
		button.ncSlotName = self:_T("inventory.slot." .. name, nil, name)
	end
	local item = c.bySlot[slot]
	if item == nil then
		if button.ncSlotName ~= nil then
			button:SetTooltip(button.ncSlotName)
		end
		return button
	end
	local def = self:Def(item.id)
	button.ncItem = item
	button.ncColor = M.CATEGORY_COLORS[def ~= nil and def.category or "misc"] or M.CATEGORY_COLORS.misc
	button.ncCount = item.count > 1 and "×" .. item.count or nil
	if item.label ~= "" then
		button.ncCorner = item.label
	elseif item.charge > 0 then
		button.ncCorner = tostring(item.charge)
	end
	button:SetTooltip(self:_Tooltip(item, def))
	local icon = button:Add("ModelImage")
	icon:SetPos(5, 4)
	icon:SetSize(SLOT - 10, SLOT - 10)
	icon:SetModel(def ~= nil and def.model or M.DEFAULT_MODEL)
	icon:SetMouseInputEnabled(false)
	button:Droppable(DRAG)
	button.DoRightClick = function(panel)
		self:OpenMenu(panel)
	end
	button.DoDoubleClick = function(panel)
		self:QuickUse(panel)
	end
	return button
end

-- Intents of the screen ----------------------------------------------------------------------

-- How many of a stack a drag moves: all, half with Shift, one with Ctrl (0: all).
function M:_DragCount(item)
	if input.IsKeyDown(KEY_LCONTROL) or input.IsKeyDown(KEY_RCONTROL) then
		return 1
	end
	if input.IsKeyDown(KEY_LSHIFT) or input.IsKeyDown(KEY_RSHIFT) then
		return max(1, floor(item.count / 2))
	end
	return 0
end

-- A slot (source) was dropped onto a slot, a title or the empty right side (receiver).
function M:_Drop(source, receiver)
	local item = source.ncItem
	if item == nil or source.ncContainer == nil then
		return
	end
	local count = self:_DragCount(item)
	if receiver.ncGround then
		if source.ncWhere == "own" then
			self:Act(source.ncContainer, source.ncSlot, "drop", count)
		end
		return
	end
	local to, toSlot = receiver.ncContainer, receiver.ncSlot
	if to == nil or (to == source.ncContainer and toSlot == source.ncSlot) then
		return
	end
	self:Move(source.ncContainer, source.ncSlot, to, toSlot, count)
end

-- The menu of a slot: the verbs of its item, then "move to" every other container seen.
function M:OpenMenu(button)
	local item = button.ncItem
	if item == nil then
		return nil
	end
	local menu = DermaMenu()
	local id, slot = button.ncContainer, button.ncSlot
	for _, verb in ipairs(self:VerbsFor(item, button.ncWhere, button.ncKind)) do
		local verbId = verb.id
		menu:AddOption(self:_T(verb.label, nil, verbId), function()
			self:Act(id, slot, verbId, 0)
		end)
	end
	local targets = {}
	for _, c in ipairs(self:Own()) do
		targets[#targets + 1] = c
	end
	for _, c in ipairs(self:External()) do
		targets[#targets + 1] = c
	end
	local sub = nil
	for _, c in ipairs(targets) do
		if c.id ~= id and c.id ~= item.sub then -- not a bag into itself
			if sub == nil then
				sub = menu:AddSubMenu(self:_T("inventory.screen.moveTo"))
			end
			local to = c.id
			sub:AddOption(self:Title(c), function()
				self:Move(id, slot, to, 0, 0)
			end)
		end
	end
	menu:Open()
	return menu
end

-- Double click: take from others, otherwise the first verb that is not drop or split.
function M:QuickUse(button)
	local item = button.ncItem
	if item == nil then
		return
	end
	if button.ncWhere == "external" then
		self:Act(button.ncContainer, button.ncSlot, "take", 0)
		return
	end
	for _, verb in ipairs(self:VerbsFor(item, "own", button.ncKind)) do
		if verb.id ~= "drop" and verb.id ~= "split" then
			self:Act(button.ncContainer, button.ncSlot, verb.id, 0)
			return
		end
	end
end

-- The hint under the crosshair --------------------------------------------------------------

function M:_UseKey()
	local key = input.LookupBinding("+use")
	return key ~= nil and tostring(key):upper() or "E"
end

-- The thing on the ground or the place in front of the local player: the entity and its
-- ground or place data, or nil.
function M:Aimed()
	local ply = LocalPlayer()
	if not IsValid(ply) or not ply:Alive() then
		return nil
	end
	local eye = ply:EyePos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * self.ctx.config.reach, filter = ply,
		mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	if ent == nil or not IsValid(ent) then
		return nil
	end
	local components = self.ctx.components
	local ground = components.ground:Get(ent)
	if ground ~= nil then
		return ent, ground, nil
	end
	local place = components.place:Get(ent)
	if place ~= nil then
		return ent, nil, place
	end
	return nil
end

function M:_HintLines(ground, place)
	if ground ~= nil then
		local name = self:Name(ground.id)
		if ground.count > 1 then
			name = name .. " ×" .. ground.count
		end
		return { name, self:_T("inventory.hint.pickup", { key = self:_UseKey() }) }
	end
	return { self:_T(place.title, { name = place.name }, place.name), self:_T("inventory.hint.search",
		{ key = self:_UseKey() }) }
end

function M:PaintHint()
	if IsValid(self.frame) then
		return
	end
	local ent, ground, place = self:Aimed()
	if ent == nil then
		self.hintKey = nil
		return
	end
	local key = ground ~= nil and format("g%d:%s:%d", ent:EntIndex(), ground.id, ground.count)
		or format("p%d:%s:%s", ent:EntIndex(), place.title, place.name)
	if key ~= self.hintKey then
		self.hintKey, self.hintLines = key, self:_HintLines(ground, place)
	end
	local x, y = ScrW() / 2, ScrH() / 2 + 36
	local lines = self.hintLines
	draw.SimpleTextOutlined(lines[1], FONT_HINT, x, y, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, OUTLINE)
	draw.SimpleTextOutlined(lines[2], FONT_SMALL, x, y + 22, DIM, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, OUTLINE)
end
