-- Roles, client part: the roles this client knows and the HUD of his own role — its
-- name and goal at the top left with the allies he knows, and a banner in the middle of
-- the screen for intro seconds when he gets a role. Texts are rebuilt when something
-- changes (roles, language), never every frame.
--
--   roles:Of(ply) -> id known here or nil; roles:Mine(); roles:Allies(); roles:IsRevealed()
--
-- Listens: gm.HUDPaint, i18n.changed.  Emits: roles.changed (mine, old).

local M = NC.Module("roles")

local CurTime = CurTime
local ScrW = ScrW
local ScrH = ScrH
local ipairs = ipairs
local pairs = pairs
local concat = table.concat
local IsValid = IsValid

local FONT_ROLE = "NC.Roles.Role"
local FONT_TEXT = "NC.Roles.Text"
local FONT_BANNER = "NC.Roles.Banner"
local OUTLINE = Color(0, 0, 0, 200)
local WHITE = Color(235, 235, 235)
local LEFT, TOP = 24, 24

surface.CreateFont(FONT_ROLE, { font = "Roboto", size = 26, weight = 700, extended = true })
surface.CreateFont(FONT_TEXT, { font = "Roboto", size = 19, weight = 500, extended = true })
surface.CreateFont(FONT_BANNER, { font = "Roboto", size = 44, weight = 800, extended = true })

function M:_InitClient(ctx)
	self.players = ctx:Require("players")
	self.known = {}      -- ply -> role id
	self.mine = nil
	self.revealed = false
	self.introUntil = 0
	self.text = nil      -- { role, goal, allies, color } or nil
	ctx.net:Receive("known", "OnKnown")
end

function M:_StartClient(ctx)
	ctx:On("gm.HUDPaint", "Paint")
	ctx:On("i18n.changed", "Rebuild")
end

function M:OnKnown(data)
	local known = {}
	for _, entry in ipairs(data.roles) do
		local id = self.order[entry.role]
		if id ~= nil and IsValid(entry.player) then
			known[entry.player] = id
		end
	end
	self.known = known
	self.revealed = data.revealed
	local old = self.mine
	self.mine = known[LocalPlayer()]
	if self.mine ~= old then
		local def = self.defs[self.mine]
		self.introUntil = def ~= nil and def.intro and CurTime() + self.ctx.config.intro or 0
		self.ctx.events:Emit("roles.changed", self.mine, old)
	end
	self:Rebuild()
end

function M:Of(ply)
	return self.known[ply]
end

function M:Mine()
	return self.mine
end

function M:IsRevealed()
	return self.revealed
end

-- Known players of the side of this client's role (without him), by entity index.
function M:Allies()
	local mine = self.defs[self.mine]
	local out = {}
	if mine == nil then
		return out
	end
	local me = LocalPlayer()
	for ply, id in pairs(self.known) do
		if ply ~= me and IsValid(ply) and self.defs[id].side == mine.side then
			out[#out + 1] = ply
		end
	end
	table.sort(out, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return out
end

local function translate(i18n, key, params)
	if key ~= nil and i18n:Has(key) then
		return i18n:T(key, params)
	end
	return key
end

function M:Rebuild()
	local def = self.defs[self.mine]
	if def == nil then
		self.text = nil
		return
	end
	local i18n = self.ctx.i18n
	local role = translate(i18n, def.name)
	local text = { role = role, color = def.color, goal = translate(i18n, def.description),
		banner = i18n:T("roles.you", { role = role }) }
	-- Allies are worth a line only for roles that are not public.
	if def.visible == "side" then
		local names = {}
		for _, ply in ipairs(self:Allies()) do
			names[#names + 1] = self.players:Name(ply)
		end
		if names[1] ~= nil then
			text.allies = i18n:T("roles.allies", { names = concat(names, ", ") })
		end
	end
	self.text = text
end

function M:Paint()
	local text = self.text
	if text == nil then
		return
	end
	draw.SimpleTextOutlined(text.role, FONT_ROLE, LEFT, TOP, text.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, OUTLINE)
	local y = TOP + 30
	if text.goal ~= nil then
		draw.SimpleTextOutlined(text.goal, FONT_TEXT, LEFT, y, WHITE, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, OUTLINE)
		y = y + 22
	end
	if text.allies ~= nil then
		draw.SimpleTextOutlined(text.allies, FONT_TEXT, LEFT, y, text.color, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP, 1, OUTLINE)
	end
	if CurTime() < self.introUntil then
		local x, cy = ScrW() * 0.5, ScrH() * 0.4
		draw.SimpleTextOutlined(text.banner, FONT_BANNER, x, cy, text.color, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 2,
			OUTLINE)
		if text.goal ~= nil then
			draw.SimpleTextOutlined(text.goal, FONT_ROLE, x, cy + 44, WHITE, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1,
				OUTLINE)
		end
	end
end
