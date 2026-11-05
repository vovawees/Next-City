-- Identity, server part.
--
--   identity:Character(ply) -> { name, gender, random, changed } of his profile, or nil (read only)
--   identity:Change(ply, name, gender, force) -> true or false, reason[, seconds]
--        name, gender: nil keeps the current one. Reasons: loading, gender, same, short, long,
--        chars, words, taken, cooldown (and the s left), denied. force (admins): no cooldown,
--        no question.
--   identity:Request(ply, name, gender) -> Change asked by the player; a notice tells him
--   identity:Wait(ply)       -> s before he may change his character again (0: now)
--   identity:IsTaken(name, ply) -> whether somebody else goes by the name (any case)
--   identity:Refresh(ply), identity:RefreshAll() -> look again whether others see characters
--
-- The character lives in the section "identity" of the profile: { name, gender, random =
-- the name was given at random, changed = unix time of the last own change, 0: the next
-- change is free }. A newcomer gets a random gender and a random name in his language when
-- he is ready (config.random); a random name follows a change of the gender until he
-- chooses his own. After an own change he waits config.cooldown s for the next one.
--
-- Names are unique (config.unique, any case): among the players on the server and in the
-- registry of the names taken, the storage namespace config.registry (folded name ->
-- profile key; the names of bots and of a server without storage for the session only).
-- The names of the city of earlier versions (namespace city) move into the profiles.
--
-- Others see the character instead of the nick (players.name, the component identity)
-- while a mode turns identities on for the player: looked at every config.refresh s, on
-- every phase of a round, when he becomes ready and when his state changes.
--
-- Listens:  profiles.loaded, profiles.leaving, players.ready, players.stateChanged, rounds.phase.
-- Asks:     identity.enabled (ply) -> true: others see his character (the city answers it);
--           identity.canChange (ply, name, gender) -> false: he may not change it now.
-- Emits:    identity.changed (ply, name, gender, oldName, oldGender)
-- Commands: nc_rpname [name], nc_gender [male | female] (everybody), nc_setname <player> <name>.

local M = NC.Module("identity")

local IsValid = IsValid
local CurTime = CurTime
local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local ceil = math.ceil
local max = math.max
local format = string.format
local concat = table.concat

local GENDER = { male = true, female = true }
local LEGACY = "city" -- the namespace the city kept the names of citizens in before identity

-- Unix time (specs replace it).
function M.Now()
	return os.time()
end

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.profiles = ctx:Require("profiles")
	self.notices = ctx:Require("notices")
	self.storage = ctx:Require("storage")
	self.registry = self.storage ~= nil and self.storage:Open(ctx.config.registry) or nil
	self.memory = {}     -- folded name -> profile key: names taken for the session only
	self.characters = {} -- ply -> the section of his profile
	ctx.commands:Add("nc_rpname", { help = "[name] - the name of your character", admin = false }, "NameCommand")
	ctx.commands:Add("nc_gender", { help = "[male | female] - the gender of your character", admin = false },
		"GenderCommand")
	ctx.commands:Add("nc_setname", { help = "<player> <name> - give the character of a player a name" },
		"SetNameCommand")
end

function M:_StartServer(ctx)
	ctx:On("profiles.loaded", "OnLoaded")
	ctx:On("profiles.leaving", "OnLeaving")
	ctx:On("players.ready", "OnReady")
	ctx:On("players.stateChanged", "OnReady")
	ctx:On("rounds.phase", "RefreshAll")
	ctx.net:Receive("change", "OnChangeRequest")
	if ctx.config.refresh > 0 then
		ctx:Every("refresh", ctx.config.refresh, "RefreshAll")
	end
	for _, ply in ipairs(player.GetAll()) do
		if self.profiles:IsLoaded(ply) then
			self:OnLoaded(ply)
		end
	end
end

-- Characters --------------------------------------------------------------------------------

function M:Character(ply)
	return self.characters[ply]
end

function M:OnLoaded(ply)
	local section = self.profiles:Section(ply, "identity")
	if section == nil or self.characters[ply] == section then
		return
	end
	section.name = type(section.name) == "string" and section.name or ""
	section.gender = GENDER[section.gender] and section.gender or nil
	section.random = section.random == true
	section.changed = tonumber(section.changed) or 0
	if section.name == "" then
		self:_Migrate(ply, section)
	end
	if section.name ~= "" then
		self:_Claim(ply, section.name)
	end
	self.characters[ply] = section
	self:_Prepare(ply)
end

-- The name a player chose in the city of earlier versions becomes his character.
function M:_Migrate(ply, section)
	if self.storage == nil then
		return
	end
	local legacy = self.storage:Open(LEGACY)
	local key = self.profiles:Key(ply)
	local record = legacy:Get(key)
	if type(record) ~= "table" or type(record.name) ~= "string" then
		return
	end
	local name = M.CleanName(record.name)
	if self:NameProblem(name) == nil and not self:IsTaken(name, ply) then
		section.name, section.random = name, false
		self.profiles:Touch(ply)
	end
	legacy:Delete(key)
end

function M:OnReady(ply)
	self:_Prepare(ply)
end

-- A ready player with a loaded profile: a gender and a random name when he has none.
function M:_Prepare(ply)
	local section = self.characters[ply]
	if section == nil or not IsValid(ply) or not self.players:IsReady(ply) then
		return
	end
	local random = self.ctx.config.random
	if section.gender == nil then
		section.gender = section.name == "" and random and M.GENDERS[M.Random(#M.GENDERS)] or "male"
		self.profiles:Touch(ply)
	end
	if section.name == "" and random then
		section.name, section.random = self:_RandomFor(ply, section.gender), true
		self:_Claim(ply, section.name)
		self.profiles:Touch(ply)
	end
	self:_Publish(ply)
	self:Refresh(ply)
end

function M:OnLeaving(ply)
	self.characters[ply] = nil
	for _, id in ipairs({ "identity", "character" }) do
		local store = self.ctx.components[id]
		if store:Has(ply) then
			store:Remove(ply)
		end
	end
end

function M:_RandomFor(ply, gender)
	return self:RandomName(gender, self.ctx.i18n:LanguageOf(ply), function(name)
		return self:IsTaken(name, ply)
	end)
end

-- What the player himself sees of his character (the character tab).
function M:_Publish(ply)
	local section = self.characters[ply]
	if section == nil or not IsValid(ply) then
		return
	end
	local wait = self:Wait(ply)
	local values = { name = section.name, gender = section.gender or "male", random = section.random,
		ready = wait > 0 and CurTime() + wait or 0 }
	local store = self.ctx.components.character
	if store:Has(ply) then
		store:Patch(ply, values)
	else
		store:Add(ply, values)
	end
end

function M:Refresh(ply)
	local section = self.characters[ply]
	local store = self.ctx.components.identity
	local on = section ~= nil and section.name ~= "" and IsValid(ply) and self.players:IsReady(ply)
		and self.ctx.events:Query("identity.enabled", ply) == true
	if on then
		local values = { name = section.name, gender = section.gender or "male" }
		if store:Has(ply) then
			store:Patch(ply, values)
		else
			store:Add(ply, values)
		end
	elseif store:Has(ply) then
		store:Remove(ply)
	end
	return on
end

function M:RefreshAll()
	for ply in pairs(self.characters) do
		if IsValid(ply) then
			self:Refresh(ply)
		end
	end
end

-- Names taken -------------------------------------------------------------------------------

function M:_Owner(folded)
	local key = self.memory[folded]
	if key == nil and self.registry ~= nil then
		key = self.registry:Get(folded)
	end
	return key
end

-- `name` becomes the name of `ply` in the registry unless somebody has it; frees `old`.
function M:_Claim(ply, name, old)
	if not self.ctx.config.unique then
		return
	end
	local key = self.profiles:Key(ply)
	if old ~= nil and old ~= "" then
		local folded = M.Fold(old)
		if self.memory[folded] == key then
			self.memory[folded] = nil
		end
		if self.registry ~= nil and self.registry:Get(folded) == key then
			self.registry:Delete(folded)
		end
	end
	local folded = M.Fold(name)
	if self:_Owner(folded) ~= nil then
		return
	end
	if self.registry ~= nil and self.profiles:IsPersistent(ply) then
		self.registry:Set(folded, key)
	else
		self.memory[folded] = key
	end
end

function M:IsTaken(name, ply)
	if not self.ctx.config.unique then
		return false
	end
	local folded = M.Fold(name)
	local owner = self:_Owner(folded)
	if owner ~= nil and (ply == nil or owner ~= self.profiles:Key(ply)) then
		return true
	end
	for other, section in pairs(self.characters) do
		if other ~= ply and IsValid(other) and M.Fold(section.name) == folded then
			return true
		end
	end
	return false
end

-- Changes -----------------------------------------------------------------------------------

function M:Wait(ply)
	local section = self.characters[ply]
	if section == nil or section.changed <= 0 then
		return 0
	end
	return max(0, section.changed + self.ctx.config.cooldown - M.Now())
end

function M:Change(ply, name, gender, force)
	local section = self.characters[ply]
	if section == nil or section.gender == nil then
		return false, "loading"
	end
	local oldName, oldGender = section.name, section.gender
	name = name ~= nil and M.CleanName(name) or oldName
	gender = gender or oldGender
	if not GENDER[gender] then
		return false, "gender"
	end
	if name == oldName and gender == oldGender then
		return false, "same"
	end
	local random = section.random and name == oldName
	if not random then
		local problem = self:NameProblem(name)
		if problem == nil and M.Fold(name) ~= M.Fold(oldName) and self:IsTaken(name, ply) then
			problem = "taken"
		end
		if problem ~= nil then
			return false, problem
		end
	end
	if not force then
		local wait = self:Wait(ply)
		if wait > 0 then
			return false, "cooldown", ceil(wait)
		end
		if self.ctx.events:Query("identity.canChange", ply, name, gender) == false then
			return false, "denied"
		end
	end
	-- A given name follows the gender until the player chooses his own.
	if random then
		name = self:_RandomFor(ply, gender)
	end
	section.name, section.gender, section.random = name, gender, random
	if not force and not random then
		section.changed = M.Now()
	end
	self:_Claim(ply, name, oldName)
	self.profiles:Touch(ply)
	self:_Publish(ply)
	self:Refresh(ply)
	self.ctx.events:Emit("identity.changed", ply, name, gender, oldName, oldGender)
	return true
end

function M:Request(ply, name, gender)
	local ok, reason, wait = self:Change(ply, name, gender, false)
	local notices = self.notices
	if notices ~= nil then
		if ok then
			local section = self.characters[ply]
			notices:Send(ply, "identity.changed", { name = section.name,
				gender = { key = "identity.gender." .. section.gender } }, "good")
		else
			notices:Send(ply, "identity.fail." .. reason, { count = ceil((wait or 0) / 60) }, "bad")
		end
	end
	return ok, reason, wait
end

function M:OnChangeRequest(msg, ply)
	self:Request(ply, msg.name, msg.gender)
end

-- Commands ----------------------------------------------------------------------------------

local function failed(command, reason, wait)
	return format("%s: %s%s", command, reason, wait ~= nil and format(" (%d s)", wait) or "")
end

function M:_Describe(ply)
	local section = self.characters[ply]
	if section == nil then
		return "no character yet"
	end
	return format("%s, %s%s", section.name ~= "" and section.name or "(no name)", section.gender or "male",
		self:IsShown(ply) and "" or " (others see the nick now)")
end

function M:NameCommand(caller, args)
	if not IsValid(caller) then
		return "nc_rpname: run it in the game"
	end
	if args[1] == nil then
		return "nc_rpname: you are " .. self:_Describe(caller)
	end
	local ok, reason, wait = self:Request(caller, concat(args, " "), nil)
	if not ok then
		return failed("nc_rpname", reason, wait)
	end
	return "nc_rpname: you are " .. self:_Describe(caller)
end

function M:GenderCommand(caller, args)
	if not IsValid(caller) then
		return "nc_gender: run it in the game"
	end
	if args[1] == nil then
		return "nc_gender: you are " .. self:_Describe(caller)
	end
	local ok, reason, wait = self:Request(caller, nil, args[1])
	if not ok then
		return failed("nc_gender", reason, wait)
	end
	return "nc_gender: you are " .. self:_Describe(caller)
end

function M:SetNameCommand(caller, args)
	if args[1] == nil or args[2] == nil then
		return "nc_setname <player> <name>"
	end
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return "nc_setname: " .. problem
	end
	local ok, reason = self:Change(ply, concat(args, " ", 2), nil, true)
	if not ok then
		return failed("nc_setname", reason)
	end
	local section = self.characters[ply]
	if self.notices ~= nil and ply ~= caller then
		self.notices:Send(ply, "identity.renamed", { name = section.name }, "info")
	end
	return format("nc_setname: %s is %s", ply:Nick(), self:_Describe(ply))
end
