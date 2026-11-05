-- Appearance, shared part: the sets of models and the looks made of them.
--
--   appearance:AddSet(id, spec) spec: models (a list of paths), gender ("male" | "female"; nil:
--                          everybody), title (lang key, default appearance.set.<id>), order
--                          (default 100). Packages add sets in their Init on both realms (the
--                          official one: the module wardrobe); the same id replaces a set
--   appearance:RemoveSet(id), appearance:Set(id) -> { id, title, gender, order, models } or nil
--   appearance:Sets(gender)  -> the sets a character of the gender may wear, in order (nil: all)
--   appearance:SetOf(model, gender) -> the first of those sets with the model, or nil
--   appearance:Allows(model, gender) -> whether a character of the gender may wear the model
--   appearance:Models(gender) -> every model of those sets, in order
--   appearance:Pick(gender, n) -> look number n (1, 2, ...) of those models and the palette: the
--                          same number gives the same look (the aliases of a mode); nil without sets
--   appearance:RandomLook(gender) -> a random model of those sets in a random color of the palette
--   appearance.PALETTE     the colors of clothes the tab offers (0xRRGGBB); DEFAULT_COLOR is the
--                          one of the engine
--   appearance.Pack(r, g, b) -> color, appearance.Unpack(color) -> r, g, b,
--   appearance.ToVector(color), appearance.FromVector(v): the player color of the engine
--   appearance.Normalize(path) -> the model path in lowercase with forward slashes
--   appearance.CleanLook(look) -> a copy with valid values, or nil without a model
--   appearance.SameLook(a, b) -> whether two looks are the same
--
-- A look: { model = path (normalized), skin = 0.., bodygroups = { the values of the groups 0,
-- 1, ...; the trailing zeros left out }, color = 0xRRGGBB }.

local M = NC.Module("appearance")

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local assert = assert
local floor = math.floor
local min = math.min
local max = math.max
local random = math.random
local format = string.format
local lower = string.lower
local sort = table.sort

local ID = "^[a-z][a-z0-9_]*$"
local GENDERS = { male = true, female = true }
local SET_KEYS = { models = true, gender = true, title = true, order = true }

M.MAX_MODEL = 128 -- bytes of a model path (the components and the net)
M.MAX_GROUPS = 16 -- bodygroups of a look
M.MAX_VALUE = 255 -- of a skin and of a bodygroup
M.MAX_COLOR = 0xFFFFFF
M.DEFAULT_COLOR = 0x3E586A -- the player color of the engine (62, 88, 106)

-- The colors of clothes the tab offers; random looks take one of them.
M.PALETTE = {
	0x3E586A, -- slate blue, the color of the engine
	0x2B3A55, -- navy
	0x3C5A3A, -- olive
	0x6B5B3E, -- khaki
	0x7A2E2E, -- dark red
	0xA65A2E, -- rust
	0x8C7A1F, -- mustard
	0x5A3E6B, -- plum
	0x2E6B6B, -- teal
	0x2A2A2A, -- charcoal
	0x8A8A8A, -- grey
	0xD8D2C4, -- off-white
}

-- A random integer 1..n (specs replace it).
function M.Random(n)
	return random(n)
end

function M:Init(ctx)
	self.sets = {}      -- id -> set
	self.sorted = nil   -- the sets in order (built when asked)
	self.added = 0      -- sets added: the order of equal orders
	self.identity = ctx:Require("identity")
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		self:_StartServer(ctx)
	else
		self:_StartClient(ctx)
	end
end

-- Colors and looks --------------------------------------------------------------------------

local function whole(value, top)
	value = tonumber(value)
	if value == nil or value ~= value then
		return 0
	end
	return min(top, max(0, floor(value + 0.5)))
end

function M.Normalize(path)
	return (lower(tostring(path or "")):gsub("\\", "/"))
end

function M.Pack(r, g, b)
	return whole(r, 255) * 65536 + whole(g, 255) * 256 + whole(b, 255)
end

function M.Unpack(color)
	color = whole(color, M.MAX_COLOR)
	return floor(color / 65536), floor(color / 256) % 256, color % 256
end

function M.ToVector(color)
	local r, g, b = M.Unpack(color)
	return Vector(r / 255, g / 255, b / 255)
end

function M.FromVector(v)
	return M.Pack(v.x * 255, v.y * 255, v.z * 255)
end

function M.CleanLook(look)
	if type(look) ~= "table" or type(look.model) ~= "string" then
		return nil
	end
	local model = M.Normalize(look.model)
	if model == "" or #model > M.MAX_MODEL then
		return nil
	end
	local source = type(look.bodygroups) == "table" and look.bodygroups or {}
	local groups, last = {}, 0
	for i = 1, M.MAX_GROUPS do
		local value = whole(source[i], M.MAX_VALUE)
		groups[i] = value
		if value > 0 then
			last = i
		end
	end
	for i = last + 1, M.MAX_GROUPS do
		groups[i] = nil
	end
	return { model = model, skin = whole(look.skin, M.MAX_VALUE), bodygroups = groups,
		color = look.color ~= nil and whole(look.color, M.MAX_COLOR) or M.DEFAULT_COLOR }
end

function M.SameLook(a, b)
	if a == nil or b == nil then
		return a == b
	end
	if a.model ~= b.model or a.skin ~= b.skin or a.color ~= b.color then
		return false
	end
	for i = 1, M.MAX_GROUPS do
		if (a.bodygroups[i] or 0) ~= (b.bodygroups[i] or 0) then
			return false
		end
	end
	return true
end

-- Sets --------------------------------------------------------------------------------------

function M:AddSet(id, spec)
	assert(type(id) == "string" and id:find(ID) ~= nil,
		"appearance: the id of a set is lowercase letters, digits and _: " .. tostring(id))
	assert(type(spec) == "table", "appearance: set " .. id .. " needs a spec")
	for key in pairs(spec) do
		assert(SET_KEYS[key], format("appearance: set %s: unknown field %s", id, tostring(key)))
	end
	assert(spec.gender == nil or GENDERS[spec.gender], "appearance: set " .. id .. ": gender male or female")
	assert(type(spec.models) == "table" and spec.models[1] ~= nil, "appearance: set " .. id .. " needs models")
	local models = {}
	for i, path in ipairs(spec.models) do
		assert(type(path) == "string" and path ~= "" and #path <= M.MAX_MODEL,
			format("appearance: set %s: model %d is a path of at most %d bytes", id, i, M.MAX_MODEL))
		models[i] = M.Normalize(path)
	end
	local old = self.sets[id]
	if old == nil then
		self.added = self.added + 1
	end
	local set = { id = id, title = spec.title or "appearance.set." .. id, gender = spec.gender,
		order = tonumber(spec.order) or 100, models = models, seq = old ~= nil and old.seq or self.added }
	self.sets[id] = set
	self.sorted = nil
	return set
end

function M:RemoveSet(id)
	self.sets[id] = nil
	self.sorted = nil
end

function M:Set(id)
	return self.sets[id]
end

local function before(a, b)
	if a.order ~= b.order then
		return a.order < b.order
	end
	return a.seq < b.seq
end

function M:_Sorted()
	local list = self.sorted
	if list == nil then
		list = {}
		for _, set in pairs(self.sets) do
			list[#list + 1] = set
		end
		sort(list, before)
		self.sorted = list
	end
	return list
end

local function fits(set, gender)
	return set.gender == nil or gender == nil or set.gender == gender
end

function M:Sets(gender)
	local out = {}
	for _, set in ipairs(self:_Sorted()) do
		if fits(set, gender) then
			out[#out + 1] = set
		end
	end
	return out
end

function M:SetOf(model, gender)
	model = M.Normalize(model)
	for _, set in ipairs(self:_Sorted()) do
		if fits(set, gender) then
			for _, path in ipairs(set.models) do
				if path == model then
					return set
				end
			end
		end
	end
	return nil
end

function M:Allows(model, gender)
	return self:SetOf(model, gender) ~= nil
end

function M:Models(gender)
	local out, seen = {}, {}
	for _, set in ipairs(self:Sets(gender)) do
		for _, path in ipairs(set.models) do
			if not seen[path] then
				seen[path] = true
				out[#out + 1] = path
			end
		end
	end
	return out
end

function M:Pick(gender, n)
	local models = self:Models(gender)
	if models[1] == nil then
		return nil
	end
	n = max(1, floor(tonumber(n) or 1))
	return { model = models[(n - 1) % #models + 1], skin = 0, bodygroups = {},
		color = M.PALETTE[(n - 1) % #M.PALETTE + 1] }
end

function M:RandomLook(gender)
	local models = self:Models(gender)
	if models[1] == nil then
		return nil
	end
	return { model = models[M.Random(#models)], skin = 0, bodygroups = {},
		color = M.PALETTE[M.Random(#M.PALETTE)] }
end
