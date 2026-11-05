-- Identity, the client: the character tab of the menu (F1): the name (typed or random),
-- the gender, saving, what others see and when the next change is allowed.
--
--   identity:Character()      -> the player's own { name, gender, random, ready } or nil
--   identity:Wait()           -> s before he may change his character again (0: now)
--   identity:Ask(name, gender) asks the server for a change (nil keeps the current one)

local M = NC.Module("identity")

local LocalPlayer = LocalPlayer
local IsValid = IsValid
local CurTime = CurTime
local ipairs = ipairs
local tostring = tostring
local ceil = math.ceil
local max = math.max
local concat = table.concat

local ORDER = 20 -- after the profile
local BUTTON_WIDE = 150

function M:_InitClient(ctx)
	self.picked = nil -- the gender picked in the tab and not saved yet
	local menu = ctx:Require("menu")
	if menu ~= nil then
		menu:AddTab("character", { title = "identity.tab", order = ORDER,
			build = function(panel) self:_BuildTab(menu, panel) end,
			stamp = function() return self:_TabStamp() end })
	end
end

function M:Character()
	local me = LocalPlayer()
	return IsValid(me) and self.ctx.components.character:Get(me) or nil
end

function M:Wait()
	local character = self:Character()
	if character == nil or character.ready <= 0 then
		return 0
	end
	return max(0, character.ready - CurTime())
end

function M:Ask(name, gender)
	local character = self:Character()
	name = name ~= nil and tostring(name) or character ~= nil and character.name or ""
	gender = gender or character ~= nil and character.gender or "male"
	self.ctx.net:SendToServer("change", { name = name:sub(1, M.MAX_BYTES), gender = gender })
end

-- What the tab shows: the character, the gender picked, the minutes to wait, whether
-- others see it.
function M:_TabStamp()
	local character = self:Character()
	if character == nil then
		return ""
	end
	return concat({ character.name, character.gender, tostring(character.random), self.picked or "",
		ceil(self:Wait() / 60), tostring(self:IsShown(LocalPlayer())) }, " ")
end

function M:_BuildTab(menu, panel)
	local i18n, cfg = self.ctx.i18n, self.ctx.config
	local colors, fonts = menu.COLORS, menu.FONTS
	local character = self:Character()
	menu:Heading(panel, i18n:T("identity.heading"))
	if character == nil then
		menu:Label(panel, i18n:T("identity.waiting"), colors.dim)
		return
	end
	if self.picked == character.gender then
		self.picked = nil
	end
	local gender = self.picked or character.gender
	local me = LocalPlayer()
	if self:IsShown(me) then
		menu:Label(panel, i18n:T("identity.shown", { name = character.name })).ncShown = true
	else
		menu:Label(panel, i18n:T("identity.hidden", { nick = me:Nick() }), colors.dim).ncShown = false
	end

	local row = menu:Row(panel)
	menu:Caption(row, i18n:T("identity.name"))
	local entry
	local dice = menu:Button(row, i18n:T("identity.random"), function()
		if IsValid(entry) then
			entry:SetValue(self:RandomName(self.picked or character.gender, i18n:Language()))
		end
	end, BUTTON_WIDE, RIGHT)
	dice:DockMargin(0, 4, 4, 4)
	dice.ncAction = "random"
	entry = menu:Entry(row, "name", character.name)

	row = menu:Row(panel)
	menu:Caption(row, i18n:T("identity.gender"))
	for _, id in ipairs(M.GENDERS) do
		local button = menu:Button(row, i18n:T("identity.button." .. id), function()
			self.picked = id
			menu:Refresh(true)
		end, BUTTON_WIDE, LEFT)
		button:DockMargin(0, 4, 4, 4)
		button.ncGender, button.ncActive = id, id == gender
	end

	local wait = self:Wait()
	row = menu:Row(panel)
	local save = menu:Button(row, i18n:T("identity.save"), function()
		self:Ask(menu:Text("name"), self.picked or character.gender)
	end, nil, FILL)
	save.ncAction = "save"
	if wait > 0 then
		menu:Label(panel, i18n:T("identity.wait", { count = ceil(wait / 60) }), colors.gold).ncWait = true
	elseif character.random then
		menu:Label(panel, i18n:T("identity.given"), colors.dim)
	end
	menu:Label(panel, i18n:T("identity.rules", { min = cfg.minLength, max = cfg.maxLength }), colors.dim,
		fonts.small)
	if cfg.cooldown > 0 then
		menu:Label(panel, i18n:T("identity.cooldown", { count = ceil(cfg.cooldown / 60) }), colors.dim, fonts.small)
	end
end
