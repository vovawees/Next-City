-- Doors, client part: the hint of the door in front (its sign, owner or group, whether it
-- is for sale and for how much, whether it is locked, what the keys do), its menu (F2,
-- gm_showteam) and the requests of the menu.
--
--   doors:Aimed()                   -> the door in front within config.range, or nil
--   doors:IsLocked(door)            -> locked by a player (the lock of the map is unknown here)
--   doors:HintLines(door)           -> { { text, color } } of the hint of a door
--   doors:OpenMenu(door)            -> the menu of a door (DermaMenu): what this player may do
--   doors:Ask(op, door, arg)        -> asks the server: buy, sell, lock, unlock, add, remove
--                                      (arg: the player), title (arg: the text)
--
-- Asks:    doors.property () -> true (may players own doors now: the mode answers here
--          too), doors.groupName (group) -> the text of a group of the map.
-- Listens: gm.HUDPaint, gm.PlayerBindPress (gm_showteam), i18n.changed.

local M = NC.Module("doors")

local CurTime = CurTime
local IsValid = IsValid
local ScrW = ScrW
local ScrH = ScrH
local ipairs = ipairs
local tostring = tostring
local type = type
local upper = string.upper

local FONT = "NC.Doors.Hint"
local FONT_TITLE = "NC.Doors.Title"
local OUTLINE = Color(0, 0, 0, 200)
local WHITE = Color(235, 235, 235)
local DIM = Color(175, 175, 175)
local GREEN = Color(120, 210, 120)
local RED = Color(230, 90, 70)
local BACK = Color(18, 20, 24, 235)
local HINT_TIME = 0.25 -- s a hint is kept before it is built again
local LINE = 22

surface.CreateFont(FONT, { font = "Roboto", size = 19, weight = 500, extended = true })
surface.CreateFont(FONT_TITLE, { font = "Roboto", size = 24, weight = 700, extended = true })

function M:_InitClient(ctx)
	self.players = ctx:Require("players")
	self.economy = ctx:Require("economy")
	self.hint = nil -- { door, expires, lines }
end

function M:_StartClient(ctx)
	ctx:On("gm.HUDPaint", "PaintHint")
	ctx:On("gm.PlayerBindPress", "OnBind")
	ctx:On("i18n.changed", function()
		self.hint = nil
	end)
end

function M:Aimed()
	local me = LocalPlayer()
	if not IsValid(me) then
		return nil
	end
	local eye = me:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + me:GetAimVector() * self.ctx.config.range,
		filter = me, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	return self:IsDoor(ent) and ent or nil
end

function M:Ask(op, door, arg)
	if not self:IsDoor(door) then
		return
	end
	local data = { op = op, door = door }
	if op == "title" then
		data.title = tostring(arg or "")
	elseif arg ~= nil then
		data.target = arg
	end
	self.ctx.net:SendToServer("door", data)
end

-- Whether a door is locked as far as this client knows (locked by a player).
function M:IsLocked(door)
	local info = self:Info(door)
	return info ~= nil and info.locked == true
end

-- Whether players may own doors now (the mode answers on the client too).
function M:IsProperty()
	return self.ctx.events:Query("doors.property") == true
end

function M:Price()
	local price = self.ctx.config.price
	return self.economy ~= nil and self.economy:Format(price) or tostring(price)
end

function M:GroupName(group)
	local name = self.ctx.events:Query("doors.groupName", group)
	return type(name) == "string" and name or group
end

-- The hint ------------------------------------------------------------------------------

-- The key of a bind as the player has it ("F2"), or the default one.
local function keyOf(bind, fallback)
	return upper(input.LookupBinding(bind) or fallback)
end

function M:HintLines(door)
	local me = LocalPlayer()
	local i18n = self.ctx.i18n
	local lines = {}
	local function add(key, params, color)
		lines[#lines + 1] = { text = i18n:T(key, params), color = color or WHITE }
	end
	local title = self:Title(door)
	if title ~= nil then
		lines[1] = { text = title, color = WHITE, title = true }
	end
	local owner, group = self:Owner(door), self:Group(door)
	if owner == me then
		add("doors.hint.yours", nil, GREEN)
	elseif owner ~= nil then
		add("doors.hint.owner", { who = self.players:Name(owner) })
		if self:IsCoowner(me, door) then
			add("doors.hint.coowner", nil, GREEN)
		end
	elseif group ~= nil then
		lines[#lines + 1] = { text = self:GroupName(group), color = DIM }
	elseif self:IsProperty() then
		if self:ForSale(door) then
			add("doors.hint.sale", { price = self:Price(), key = keyOf("gm_showteam", "f2") }, GREEN)
		else
			add("doors.hint.closed", nil, DIM)
		end
	end
	local locked = self:IsLocked(door)
	if locked then
		add("doors.hint.locked", nil, RED)
	end
	if self:HasKeys(me, door) then
		add(locked and "doors.hint.unlock" or "doors.hint.lock", { keys = keyOf("+walk", "alt") .. " + "
			.. keyOf("+use", "e") }, DIM)
	end
	return lines
end

function M:PaintHint()
	local door = self:Aimed()
	if door == nil then
		self.hint = nil
		return
	end
	local hint = self.hint
	if hint == nil or hint.door ~= door or CurTime() >= hint.expires then
		hint = { door = door, expires = CurTime() + HINT_TIME, lines = self:HintLines(door) }
		self.hint = hint
	end
	local x, y = ScrW() * 0.5, ScrH() * 0.5 + 36
	for _, line in ipairs(hint.lines) do
		draw.SimpleTextOutlined(line.text, line.title and FONT_TITLE or FONT, x, y, line.color, TEXT_ALIGN_CENTER,
			TEXT_ALIGN_TOP, 1, OUTLINE)
		y = y + (line.title and LINE + 6 or LINE)
	end
end

-- The menu ------------------------------------------------------------------------------

function M:OnBind(_, bind, pressed)
	if not pressed or bind ~= "gm_showteam" then
		return nil
	end
	local door = self:Aimed()
	if door == nil then
		return nil
	end
	self:OpenMenu(door)
	return true
end

local function others(self, door, keys)
	local me, out = LocalPlayer(), {}
	for _, ply in ipairs(player.GetAll()) do
		if ply ~= me and IsValid(ply) and self:IsCoowner(ply, door) == keys then
			out[#out + 1] = ply
		end
	end
	return out
end

function M:OpenMenu(door)
	local me = LocalPlayer()
	local i18n = self.ctx.i18n
	local menu = DermaMenu()
	local function option(key, params, fn)
		return menu:AddOption(i18n:T(key, params), fn)
	end
	local count = 0
	if self:IsProperty() and self:ForSale(door) then
		option("doors.menu.buy", { price = self:Price() }, function() self:Ask("buy", door) end)
		count = count + 1
	end
	if self:HasKeys(me, door) then
		local locked = self:IsLocked(door)
		option(locked and "doors.menu.unlock" or "doors.menu.lock", nil, function()
			self:Ask(locked and "unlock" or "lock", door)
		end)
		count = count + 1
	end
	if self:Owner(door) == me then
		local give = menu:AddSubMenu(i18n:T("doors.menu.add"))
		for _, ply in ipairs(others(self, door, false)) do
			give:AddOption(self.players:Name(ply), function() self:Ask("add", door, ply) end)
		end
		local take = menu:AddSubMenu(i18n:T("doors.menu.remove"))
		for _, ply in ipairs(others(self, door, true)) do
			take:AddOption(self.players:Name(ply), function() self:Ask("remove", door, ply) end)
		end
		option("doors.menu.title", nil, function() self:OpenTitle(door) end)
		option("doors.menu.sell", nil, function() self:Ask("sell", door) end)
		count = count + 4
	elseif self:IsCoowner(me, door) then
		option("doors.menu.back", nil, function() self:Ask("remove", door, me) end)
		count = count + 1
	end
	if count == 0 then
		option("doors.menu.none", nil, function() end)
	end
	menu:Open()
	self.menu = menu
	return menu
end

-- The sign of a door: a small window with a text entry.
function M:OpenTitle(door)
	local i18n = self.ctx.i18n
	local frame = vgui.Create("DFrame")
	frame:SetSize(360, 112)
	frame:Center()
	frame:SetTitle(i18n:T("doors.menu.sign"))
	frame:MakePopup()
	frame.Paint = function(_, w, h)
		draw.RoundedBox(6, 0, 0, w, h, BACK)
	end
	local entry = frame:Add("DTextEntry")
	entry:Dock(TOP)
	entry:SetTall(28)
	entry:SetValue(self:Title(door) or "")
	entry.ncTitle = true
	local save = frame:Add("DButton")
	save:Dock(BOTTOM)
	save:SetTall(28)
	save:SetText(i18n:T("doors.menu.save"))
	save.ncSave = true
	save.DoClick = function()
		self:Ask("title", door, entry:GetValue())
		frame:Remove()
	end
	entry.OnEnter = save.DoClick
	self.titleFrame = frame
	return frame
end
