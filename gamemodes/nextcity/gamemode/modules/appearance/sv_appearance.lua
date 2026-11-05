-- Appearance, server part.
--
--   appearance:Look(ply)      -> his look { model, skin, bodygroups, color, random } (read only),
--                                or nil while he has none
--   appearance:Effective(ply) -> the look he wears where no mode dresses him: his look after the
--                                modes (appearance.look), or nil
--   appearance:Change(ply, look, force, random) -> true or false, reason[, seconds]. Reasons:
--                                loading, model (not of the sets for his gender), same, cooldown
--                                (and the s left), denied. force (admins, modules): no cooldown,
--                                no question; random: the look was given at random
--   appearance:Request(ply, look) -> Change asked by the player; a notice tells him
--   appearance:Randomize(ply, force) -> Change to a random look of his sets
--   appearance:Wait(ply)      -> s before he may change his look again (0: now)
--   appearance:GenderOf(ply)  -> the gender of his character (identity) or nil
--   appearance:Dress(ply)     puts the clothes on a living player now: the model of a mode (its
--                                answer to gm.PlayerSetModel) or of his look, then the skin,
--                                bodygroups and the color (a job change of the city calls it)
--
-- The look lives in the section "appearance" of the profile. A newcomer gets a random look of
-- the sets for the gender of his character when he is ready (config.random); a random look
-- follows a change of the gender, an own one only when the new gender may not wear it. A look
-- of a set that went away goes too.
--
-- At every spawn the module answers gm.PlayerSetModel below the modes (priority -10): a mode
-- that dresses players (the uniforms of the city) wins, otherwise the model of the effective
-- look; then (players.spawned) the skin and bodygroups of the look go on its model, clamped to
-- what the model has, and the color of the clothes on any model. Bodies and corpses (ragdoll)
-- keep the color the player wore (the component clothes).
--
-- Listens:  profiles.loaded, profiles.leaving, players.ready (after identity), players.spawned,
--           identity.changed, ragdoll.fell, ragdoll.corpse; answers gm.PlayerSetModel.
-- Reduces:  appearance.look (look or nil, ply) -> another look (modes; a copy, may be changed)
-- Asks:     appearance.canChange (ply, look) -> false: he may not change his look now.
-- Emits:    appearance.changed (ply, look, old) (old: nil for the first one)
-- Commands: nc_look [random] (everybody: the look, a random one), nc_looks (the sets).

local M = NC.Module("appearance")

local IsValid = IsValid
local CurTime = CurTime
local type = type
local ipairs = ipairs
local ceil = math.ceil
local min = math.min
local max = math.max
local format = string.format
local concat = table.concat

local PRIORITY = -10 -- below the answers of modes (gm.PlayerSetModel) and after identity
local TRIES = 8      -- random looks tried for one that differs

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.profiles = ctx:Require("profiles")
	self.notices = ctx:Require("notices")
	self.looks = {}   -- ply -> the section of his profile
	self.changed = {} -- ply -> CurTime of his last own change
	ctx.commands:Add("nc_look", { help = "[random] - your look; random: a random one of your sets", admin = false },
		"LookCommand")
	ctx.commands:Add("nc_looks", { help = "the sets of models of looks", admin = false }, "LooksCommand")
end

function M:_StartServer(ctx)
	ctx:On("profiles.loaded", "OnLoaded")
	ctx:On("profiles.leaving", "OnLeaving")
	ctx:On("players.ready", "OnReady", { priority = PRIORITY })
	ctx:On("players.spawned", "OnSpawned", { priority = PRIORITY })
	ctx:On("gm.PlayerSetModel", "AnswerModel", { priority = PRIORITY })
	ctx:On("identity.changed", "OnIdentity")
	ctx:On("ragdoll.fell", "OnBody")
	ctx:On("ragdoll.corpse", "OnBody")
	ctx.net:Receive("change", "OnChangeRequest")
	for _, ply in ipairs(player.GetAll()) do
		if self.profiles:IsLoaded(ply) then
			self:OnLoaded(ply)
		end
	end
end

-- Looks -------------------------------------------------------------------------------------

-- Writes a look into the section of a profile (nil: none).
local function store(section, look, random)
	if look == nil then
		section.model, section.skin, section.bodygroups, section.color, section.random = nil, nil, nil, nil, nil
		return
	end
	section.model, section.skin, section.color, section.random = look.model, look.skin, look.color, random == true
	local groups = {}
	for i, value in ipairs(look.bodygroups) do
		groups[i] = value
	end
	section.bodygroups = groups
end

function M:Look(ply)
	local section = self.looks[ply]
	if section == nil or section.model == nil then
		return nil
	end
	return section
end

function M:GenderOf(ply)
	local identity = self.identity
	local character = identity ~= nil and identity:Character(ply) or nil
	return character ~= nil and character.gender or nil
end

function M:OnLoaded(ply)
	local section = self.profiles:Section(ply, "appearance")
	if section == nil or self.looks[ply] == section then
		return
	end
	local look = M.CleanLook(section)
	if look ~= nil and not self:Allows(look.model) then
		look = nil
	end
	store(section, look, section.random == true)
	self.looks[ply] = section
	self:_Prepare(ply)
end

function M:OnReady(ply)
	self:_Prepare(ply)
end

-- A ready player with a loaded profile: a random look when he has none (or one his gender
-- may not wear), then he puts it on.
function M:_Prepare(ply)
	local section = self.looks[ply]
	if section == nil or not IsValid(ply) or not self.players:IsReady(ply) then
		return
	end
	local gender = self:GenderOf(ply)
	if section.model ~= nil and not self:Allows(section.model, gender) then
		store(section, nil)
		self.profiles:Touch(ply)
	end
	if section.model == nil and self.ctx.config.random then
		local look = self:RandomLook(gender)
		if look ~= nil then
			store(section, look, true)
			self.profiles:Touch(ply)
		end
	end
	self:_Publish(ply)
	self:Dress(ply)
end

function M:OnLeaving(ply)
	self.looks[ply], self.changed[ply] = nil, nil
	local components = self.ctx.components.look
	if components:Has(ply) then
		components:Remove(ply)
	end
end

-- What the player himself sees of his look (the appearance tab).
function M:_Publish(ply)
	local section = self.looks[ply]
	if section == nil or not IsValid(ply) then
		return
	end
	local wait = self:Wait(ply)
	local look = self:Look(ply)
	local values = { model = look ~= nil and look.model or "", skin = look ~= nil and look.skin or 0,
		bodygroups = look ~= nil and look.bodygroups or {}, color = look ~= nil and look.color or M.DEFAULT_COLOR,
		random = look ~= nil and look.random == true, ready = wait > 0 and CurTime() + wait or 0 }
	local components = self.ctx.components.look
	if components:Has(ply) then
		components:Patch(ply, values)
	else
		components:Add(ply, values)
	end
end

function M:Effective(ply)
	local look = self:Look(ply)
	local result = self.ctx.events:Reduce("appearance.look", look ~= nil and M.CleanLook(look) or nil, ply)
	return M.CleanLook(result)
end

-- Dressing ----------------------------------------------------------------------------------

function M:AnswerModel(ply)
	local look = self:Effective(ply)
	return look ~= nil and look.model or nil
end

function M:OnSpawned(ply)
	self:_Details(ply)
end

-- The color of the clothes on any model; the skin and the bodygroups only on the model of
-- the look (a mode that dresses the player keeps its own).
function M:_Details(ply)
	local look = self:Effective(ply)
	if look == nil or not IsValid(ply) then
		return
	end
	ply:SetPlayerColor(M.ToVector(look.color))
	if M.Normalize(ply:GetModel()) ~= look.model then
		return
	end
	ply:SetSkin(min(look.skin, max(0, (ply:SkinCount() or 1) - 1)))
	for group = 0, ply:GetNumBodyGroups() - 1 do
		local count = ply:GetBodygroupCount(group) or 1
		ply:SetBodygroup(group, min(look.bodygroups[group + 1] or 0, max(0, count - 1)))
	end
end

function M:Dress(ply)
	if not IsValid(ply) or not self.players:IsAlive(ply) then
		return false
	end
	local model = self.ctx.events:Query("gm.PlayerSetModel", ply)
	if type(model) == "string" and model ~= "" and M.Normalize(ply:GetModel()) ~= M.Normalize(model) then
		ply:SetModel(model)
	end
	self:_Details(ply)
	return true
end

-- A body or a corpse keeps the color of the clothes its player wore.
function M:OnBody(ply, rag)
	if not IsValid(ply) or not IsValid(rag) then
		return
	end
	local values = { color = M.FromVector(ply:GetPlayerColor()) }
	local clothes = self.ctx.components.clothes
	if clothes:Has(rag) then
		clothes:Patch(rag, values)
	else
		clothes:Add(rag, values)
	end
end

-- Changes -----------------------------------------------------------------------------------

function M:Wait(ply)
	local last = self.changed[ply]
	if last == nil then
		return 0
	end
	return max(0, last + self.ctx.config.cooldown - CurTime())
end

function M:Change(ply, look, force, random)
	local section = self.looks[ply]
	if section == nil then
		return false, "loading"
	end
	look = M.CleanLook(look)
	if look == nil or not self:Allows(look.model, self:GenderOf(ply)) then
		return false, "model"
	end
	local old = self:Look(ply)
	if old ~= nil and M.SameLook(old, look) then
		return false, "same"
	end
	if not force then
		local wait = self:Wait(ply)
		if wait > 0 then
			return false, "cooldown", ceil(wait)
		end
		if self.ctx.events:Query("appearance.canChange", ply, look) == false then
			return false, "denied"
		end
		self.changed[ply] = CurTime()
	end
	old = old ~= nil and M.CleanLook(old) or nil
	store(section, look, random)
	self.profiles:Touch(ply)
	self:_Publish(ply)
	self:Dress(ply)
	self.ctx.events:Emit("appearance.changed", ply, M.CleanLook(section), old)
	return true
end

function M:Randomize(ply, force)
	local gender, old = self:GenderOf(ply), self:Look(ply)
	local look = self:RandomLook(gender)
	for _ = 2, TRIES do
		if look == nil or not M.SameLook(look, old) then
			break
		end
		look = self:RandomLook(gender)
	end
	if look == nil then
		return false, "model"
	end
	return self:Change(ply, look, force, true)
end

function M:_Tell(ply, ok, reason, wait)
	local notices = self.notices
	if notices == nil then
		return
	end
	if ok then
		notices:Send(ply, "appearance.changed", nil, "good")
	else
		notices:Send(ply, "appearance.fail." .. reason, { count = wait or 0 }, "bad")
	end
end

function M:Request(ply, look)
	local ok, reason, wait = self:Change(ply, look, false, false)
	self:_Tell(ply, ok, reason, wait)
	return ok, reason, wait
end

function M:OnChangeRequest(msg, ply)
	self:Request(ply, msg)
end

-- A new gender: a random look follows it, an own one stays while the gender may wear it.
function M:OnIdentity(ply, _, gender, _, oldGender)
	local section = self.looks[ply]
	if section == nil or gender == oldGender then
		return
	end
	if section.model ~= nil and not section.random and self:Allows(section.model, gender) then
		return
	end
	local look = self.ctx.config.random and self:RandomLook(gender) or nil
	store(section, look, true)
	self.profiles:Touch(ply)
	self:_Publish(ply)
	self:Dress(ply)
end

-- Commands ----------------------------------------------------------------------------------

function M:_Describe(ply)
	local look = self:Look(ply)
	if look == nil then
		return "no look (the model of the game)"
	end
	local r, g, b = M.Unpack(look.color)
	local text = format("%s, skin %d, bodygroups [%s], color %d %d %d%s", look.model, look.skin,
		concat(look.bodygroups, " "), r, g, b, look.random and " (given at random)" or "")
	local worn = M.Normalize(ply:GetModel())
	if self.players:IsAlive(ply) and worn ~= look.model then
		text = text .. "; now dressed as " .. worn
	end
	return text
end

function M:LookCommand(caller, args)
	if not IsValid(caller) then
		return "nc_look: run it in the game"
	end
	if args[1] == "random" then
		local ok, reason, wait = self:Randomize(caller, false)
		self:_Tell(caller, ok, reason, wait)
		if not ok then
			return format("nc_look: %s%s", reason, wait ~= nil and format(" (%d s)", wait) or "")
		end
	elseif args[1] ~= nil then
		return "nc_look [random]"
	end
	return "nc_look: " .. self:_Describe(caller)
end

function M:LooksCommand()
	local sets = self:Sets()
	if sets[1] == nil then
		return "nc_looks: no sets (packages add them)"
	end
	local lines = {}
	for _, set in ipairs(sets) do
		lines[#lines + 1] = format("%s (%s): %d models", set.id, set.gender or "everybody", #set.models)
	end
	return concat(lines, "\n")
end
