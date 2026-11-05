-- Profiles, the client: the profile tab of the menu (F1) with the summary of the player's
-- own profile: the first visit, the visits, the time in the game and the statistics.
--
--   profiles:FormatPlaytime(s) -> the time as the tab shows it ("5 h 12 min")

local M = NC.Module("profiles")

local LocalPlayer = LocalPlayer
local IsValid = IsValid
local ipairs = ipairs
local tostring = tostring
local floor = math.floor
local concat = table.concat
local date = os.date

local ORDER = 10 -- the first tab of the menu

function M:_InitClient(ctx)
	local menu = ctx:Require("menu")
	if menu ~= nil then
		menu:AddTab("profile", { title = "profiles.tab", order = ORDER,
			build = function(panel) self:_BuildTab(menu, panel) end,
			stamp = function() return self:_TabStamp() end })
	end
end

function M:FormatPlaytime(seconds)
	local i18n = self.ctx.i18n
	local minutes = floor((seconds or 0) / 60)
	local hours = floor(minutes / 60)
	if hours > 0 then
		return i18n:T("profiles.time.hours", { hours = hours, minutes = minutes % 60 })
	end
	return i18n:T("profiles.time.minutes", { minutes = minutes })
end

-- What the tab shows: the summary and the minutes of the playtime.
function M:_TabStamp()
	local me = LocalPlayer()
	local summary = IsValid(me) and self:Summary(me) or nil
	if summary == nil then
		return ""
	end
	local parts = { summary.first, summary.visits, floor((self:SummaryPlaytime(me) or 0) / 60) }
	for _, name in ipairs(M.STATS) do
		parts[#parts + 1] = summary[name]
	end
	return concat(parts, " ")
end

function M:_BuildTab(menu, panel)
	local i18n = self.ctx.i18n
	local me = LocalPlayer()
	menu:Heading(panel, me:Nick())
	local summary = self:Summary(me)
	if summary == nil then
		menu:Label(panel, i18n:T("profiles.waiting"), menu.COLORS.dim)
		return
	end
	local function add(id, caption, value)
		local row = menu:Row(panel)
		row.ncStat = id
		menu:Caption(row, caption)
		menu:Value(row, tostring(value)).ncValue = tostring(value)
	end
	add("first", i18n:T("profiles.first"), summary.first > 0 and date("%Y-%m-%d", summary.first) or "-")
	add("visits", i18n:T("profiles.visits"), summary.visits)
	add("playtime", i18n:T("profiles.playtime"), self:FormatPlaytime(self:SummaryPlaytime(me)))
	menu:Heading(panel, i18n:T("profiles.stats"))
	for _, name in ipairs(M.STATS) do
		add(name, i18n:T("profiles.stat." .. name), summary[name])
	end
end
