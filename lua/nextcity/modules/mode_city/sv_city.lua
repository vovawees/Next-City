-- City, server part: the mode "city". An endless round (rules respawn and roles): every
-- ready player joins at any time with the default job, the dead come back after
-- respawnDelay s, nobody wins. Every payday s each citizen gets the salary of his job into
-- his bank account (the economy module; the reduction mode_city.salary may change it).
--
-- A job change (nc_job, the menu of the city) checks the limit of places, the cooldown of
-- jobCooldown s and the question mode_city.canJob; the gear of the old job goes away, the
-- gear of the new one comes with its clothes: the uniform of the job (a model of the gender
-- of the character where the job has one) or, for jobs without one (own: the citizens),
-- the look of the character (the appearance module). The gear of a job (its kit, given with
-- issued = true in the state of every thing) stays with its owner: it cannot be dropped or
-- put into somebody else's container; the dead leave it on the body like the rest.
--
-- The shop (offers of sh_city.lua): a citizen buys what his job may buy, the money comes off
-- his account and then his cash (economy:Charge), the things go into his inventory and what
-- does not fit falls at his feet. Bought things are his own, unlike the gear of the job.
--
-- Names: with param names everybody sees the characters of citizens instead of their nicks
-- (the identity module: the city answers identity.enabled; nc_rpname, the tab of F1). The
-- chat: with param localChat what is said in character is heard only around (the chat
-- module: the city answers chat.proximity).
--
--   city:SetJob(ply, id, force) -> true or false, reason[, seconds]   reasons: mode, unknown,
--                                  same, limit, cooldown, jailed, denied
--   city:Buy(ply, offer, times) -> true, things or false, reason      reasons: closed, mode, dead,
--                                  unknown, job, times, jailed, denied, funds
--   city:Round() -> the running round of the city, or nil; city:Members(id); city:Payday(round)
--
-- Asks:     mode_city.canJob (ply, id) -> false, mode_city.canBuy (ply, offer, times) -> false,
--           mode_city.salary (salary, ply) -> salary.
-- Emits:    mode_city.job (ply, id, old), mode_city.bought (ply, offer, times, price).
-- Doors (the doors module): property while the city lives, only the police use a battering
-- ram (doors.property, doors.canRam); every door goes back to the market at the end.
-- The law (the law module) is in force while the city lives (law.enabled): the police want
-- and arrest, the mayor issues warrants (sh_city.lua); the jailed get no salary, change no
-- job and buy nothing (reason jailed); the end of the city is an amnesty.
--
-- Commands: nc_job [job], nc_buy [offer [times]] (everybody), nc_setjob <player> <job> (admin).

local M = NC.Module("mode_city")

local IsValid = IsValid
local CurTime = CurTime
local ipairs = ipairs
local ceil = math.ceil
local floor = math.floor
local type = type
local format = string.format
local concat = table.concat

-- Weapon slots in the order the weapon of a kit goes into the hands.
M.HANDS = { "melee", "secondary", "primary" }

function M:_InitServer(ctx)
	self.rounds = ctx:Require("rounds")
	self.players = ctx:Require("players")
	self.inventory = ctx:Require("inventory")
	self.economy = ctx:Require("economy")
	self.notices = ctx:Require("notices")
	self.doors = ctx:Require("doors")
	self.law = ctx:Require("law")
	self.identity = ctx:Require("identity")
	self.appearance = ctx:Require("appearance")
	self.changed = {} -- ply -> CurTime of his last job change
	self.rounds:RegisterMode({
		id = "city",
		name = "mode_city.name",
		description = "endless city life: jobs, salaries, money, doors and the police",
		minPlayers = 1,
		rules = { "respawn", "roles" },
		params = {
			respawnDelay = { type = "number", default = 10, min = 0, max = 300, desc = "s before the dead come back" },
			payday = { type = "number", default = 300, min = 0, max = 3600,
				desc = "s between salaries (0: no salaries)" },
			jobCooldown = { type = "number", default = 30, min = 0, max = 3600,
				desc = "s a player waits between job changes" },
			names = { type = "boolean", default = true,
				desc = "everybody sees the characters of citizens (identity: nc_rpname, F1) instead of nicks" },
			localChat = { type = "boolean", default = true,
				desc = "what is said in character is heard only around (chat: whisper, say, yell)" },
		},
		Setup = function(round)
			self:Setup(round)
		end,
		PlayerAdded = function(round, ply)
			self:Arrive(round, ply)
		end,
		Loadout = function(_, ply)
			self:Equip(ply)
		end,
		Start = function(round)
			self:Begin(round)
		end,
		Cleanup = function()
			self:Cleanup()
		end,
	}, ctx)
end

function M:_StartServer(ctx)
	ctx.net:Receive("job", "OnJobRequest")
	ctx.net:Receive("buy", "OnBuyRequest")
	ctx:On("players.left", "OnLeft")
	ctx.commands:Add("nc_job", { help = "[job] - the jobs of the city, or become one", admin = false }, "JobCommand")
	ctx.commands:Add("nc_buy", { help = "[offer [times]] - the shop of your job, or buy", admin = false },
		"BuyCommand")
	ctx.commands:Add("nc_setjob", { help = "<player> <job> - give a player a job at once" }, "SetJobCommand")
end

-- The running round of the city (preparing or active), or nil.
function M:Round()
	local round = self.rounds:Round()
	if round == nil or round.mode ~= "city" or round.result ~= nil then
		return nil
	end
	return round
end

-- The gear of a job stays with its owner.
local function issued(item)
	return item ~= nil and item.state ~= nil and item.state.issued == true
end

function M:Setup(round)
	-- The uniform of the job; the own look (appearance answers) where the job has none.
	round:On("gm.PlayerSetModel", function(ply)
		local job = self:JobOf(ply)
		if job == nil or job.own and self.appearance ~= nil and self.appearance:Look(ply) ~= nil then
			return nil
		end
		return self:ModelFor(ply, job)
	end)
	-- Doors are property in the city; only the police break them in.
	round:On("doors.property", function()
		return true
	end)
	round:On("doors.canRam", function(ply)
		if not self:IsPolice(ply) then
			return false
		end
	end)
	round:On("law.enabled", function()
		return true
	end)
	if round.params.names then
		round:On("identity.enabled", function()
			return true
		end)
	end
	if round.params.localChat then
		round:On("chat.proximity", function()
			return true
		end)
	end
	local inventory = self.inventory
	if inventory == nil then
		return
	end
	round:On("inventory.canMove", function(ply, item, _, to)
		if issued(item) and inventory:Where(ply, to) ~= "own" then
			return false
		end
	end)
	round:On("inventory.canAct", function(_, item, verb)
		if verb == "drop" and issued(item) then
			return false
		end
	end)
end

-- A citizen arrives with the default job.
function M:Arrive(_, ply)
	self.changed[ply] = nil
	self.roles:Assign(ply, self.defaultJob)
end

function M:Begin(round)
	local interval = round.params.payday
	if interval > 0 and self.economy ~= nil then
		round:Every("payday", interval, function()
			self:Payday(round)
		end)
	end
end

function M:Cleanup()
	self.changed = {}
	if self.doors ~= nil then
		self.doors:ReleaseAll()
	end
	if self.law ~= nil then
		self.law:Amnesty()
	end
end

function M:_Jailed(ply)
	return self.law ~= nil and self.law:IsJailed(ply)
end

function M:OnLeft(ply)
	self.changed[ply] = nil
end

-- Players with job `id` (by entity index).
function M:Members(id)
	return self.roles:Members(id)
end

local function female(path)
	return path:find("female", 1, true) ~= nil or path:find("_fem", 1, true) ~= nil
end

-- The models of a job for the gender of a player's character (identity): those of it, or
-- all when the job has none of it.
function M:_ModelsFor(ply, models)
	local character = self.identity ~= nil and self.identity:Character(ply) or nil
	local gender = character ~= nil and character.gender or nil
	if gender == nil then
		return models
	end
	local out = {}
	for _, path in ipairs(models) do
		if female(path) == (gender == "female") then
			out[#out + 1] = path
		end
	end
	return out[1] ~= nil and out or models
end

-- The model of a job for a player: the same one every life.
function M:ModelFor(ply, job)
	local list = self:_ModelsFor(ply, job.models)
	if list[1] == nil then
		return nil
	end
	return list[(ply:EntIndex() - 1) % #list + 1]
end

-- The clothes of his job on a living player (his own look where the job has no uniform).
function M:_Dress(ply, job)
	if self.appearance ~= nil then
		self.appearance:Dress(ply)
		return
	end
	local model = self:ModelFor(ply, job)
	if model ~= nil then
		ply:SetModel(model)
	end
end

-- The gear of his job for a living player (the model comes with gm.PlayerSetModel).
function M:Equip(ply)
	local job = self:JobOf(ply) or self.jobs[self.defaultJob]
	local inventory = self.inventory
	if job == nil then
		return
	end
	if inventory ~= nil and inventory:Kit(job.kit) ~= nil then
		inventory:GiveKit(ply, job.kit, { drop = true, select = M.HANDS, state = { issued = true } })
	end
end

-- The gear of his job a player carries goes away.
function M:Unequip(ply)
	local inventory = self.inventory
	if inventory == nil then
		return
	end
	for _, item in ipairs(inventory:ItemsOf(ply)) do
		if issued(item) then
			inventory:Destroy(item)
		end
	end
end

-- Gives a player job `id` (see the top of the file). force: an admin, no checks but the
-- job itself.
function M:SetJob(ply, id, force)
	local round = self:Round()
	if round == nil or not round:IsParticipant(ply) then
		return false, "mode"
	end
	local job = self.jobs[id]
	if job == nil then
		return false, "unknown"
	end
	local old = self.roles:Of(ply)
	if old == id then
		return false, "same"
	end
	if not force then
		if job.limit > 0 and #self:Members(id) >= job.limit then
			return false, "limit"
		end
		local last = self.changed[ply]
		local wait = last ~= nil and last + round.params.jobCooldown - CurTime() or 0
		if wait > 0 then
			return false, "cooldown", ceil(wait)
		end
		if self:_Jailed(ply) then
			return false, "jailed"
		end
		if self.ctx.events:Query("mode_city.canJob", ply, id) == false then
			return false, "denied"
		end
	end
	self.changed[ply] = CurTime()
	self.roles:Assign(ply, id)
	if self.players:IsAlive(ply) then
		self:Unequip(ply)
		self:Equip(ply)
		self:_Dress(ply, job)
	end
	if self.notices ~= nil then
		self.notices:Broadcast("mode_city.became", { who = self.players:Name(ply), job = { key = job.name } },
			"info", { chat = true })
	end
	self.ctx.events:Emit("mode_city.job", ply, id, old)
	return true
end

-- A job change asked by a player; he learns why not.
function M:RequestJob(ply, id)
	local ok, reason, wait = self:SetJob(ply, id)
	if not ok and self.notices ~= nil then
		local job = self.jobs[id]
		self.notices:Send(ply, "mode_city.fail." .. reason, { count = wait or (job and job.limit) or 0,
			job = job and { key = job.name } or tostring(id) }, "bad")
	end
	return ok, reason, wait
end

function M:OnJobRequest(data, ply)
	local id = self.jobOrder[data.job]
	if id ~= nil then
		self:RequestJob(ply, id)
	end
end

-- Buys `times` (1 to MAX_TIMES, default 1) purchases of an offer (see the top of the file).
-- Returns true and how many things went into the inventory, or false and the reason.
function M:Buy(ply, id, times)
	times = times or 1
	local inventory, economy = self.inventory, self.economy
	if inventory == nil or economy == nil then
		return false, "closed"
	end
	local round = self:Round()
	if round == nil or not round:IsParticipant(ply) then
		return false, "mode"
	end
	if not self.players:IsAlive(ply) then
		return false, "dead"
	end
	local offer = self.offers[id]
	if offer == nil or inventory:Def(offer.item) == nil then
		return false, "unknown"
	end
	if not self:MayBuy(ply, offer) then
		return false, "job"
	end
	if type(times) ~= "number" or times ~= floor(times) or times < 1 or times > M.MAX_TIMES then
		return false, "times"
	end
	if self:_Jailed(ply) then
		return false, "jailed"
	end
	if self.ctx.events:Query("mode_city.canBuy", ply, id, times) == false then
		return false, "denied"
	end
	local price = offer.price * times
	local ok, reason = economy:Charge(ply, price, "mode_city.buy")
	if not ok then
		return false, reason
	end
	local given = inventory:Give(ply, offer.item, offer.count * times, nil, { drop = true })
	self.ctx.events:Emit("mode_city.bought", ply, id, times, price)
	return true, given
end

-- A purchase asked by a player; he learns what he got or why not.
function M:RequestBuy(ply, id, times)
	local ok, given = self:Buy(ply, id, times)
	local notices = self.notices
	if notices == nil then
		return ok, given
	end
	local offer = self.offers[id]
	if not ok then
		notices:Send(ply, "mode_city.fail.buy." .. given, { count = M.MAX_TIMES }, "bad")
		return ok, given
	end
	local count = offer.count * (times or 1)
	notices:Send(ply, "mode_city.bought", { item = { key = self.inventory:Def(offer.item).name }, count = count,
		price = self.economy:Format(offer.price * (times or 1)) }, "good")
	if given < count then
		notices:Send(ply, "mode_city.dropped", { count = count - given }, "info")
	end
	return ok, given
end

function M:OnBuyRequest(data, ply)
	local id = self.offerOrder[data.offer]
	if id ~= nil then
		self:RequestBuy(ply, id, data.times)
	end
end

-- Pays every citizen the salary of his job.
function M:Payday(round)
	local economy = self.economy
	if economy == nil then
		return
	end
	local events = self.ctx.events
	for _, ply in ipairs(round:Participants()) do
		local job = self:JobOf(ply)
		local base = job ~= nil and not self:_Jailed(ply) and job.salary or 0
		local salary = events:Reduce("mode_city.salary", base, ply)
		if type(salary) == "number" and salary >= 1 then
			economy:Pay(ply, salary, "salary")
			if self.notices ~= nil then
				self.notices:Send(ply, "mode_city.payday", { amount = economy:Format(salary) }, "good")
			end
		end
	end
end

-- Commands ------------------------------------------------------------------------------

function M:JobCommand(caller, args)
	local id = args[1]
	if id == nil or not IsValid(caller) then
		local lines = {}
		for _, jobId in ipairs(self.jobOrder) do
			local job = self.jobs[jobId]
			local taken = #self:Members(jobId)
			lines[#lines + 1] = format("%-10s %d/%s  salary %d%s", jobId, taken, job.limit > 0 and job.limit or "-",
				job.salary, IsValid(caller) and self.roles:Of(caller) == jobId and "  (yours)" or "")
		end
		return lines
	end
	local ok, reason, wait = self:RequestJob(caller, id)
	if ok then
		return "nc_job: you are " .. id
	end
	return format("nc_job %s: %s%s", id, reason, wait ~= nil and format(" (%d s)", wait) or "")
end

function M:BuyCommand(caller, args)
	local id = args[1]
	if id == nil then
		local lines = {}
		local economy = self.economy
		for _, offerId in ipairs(self.offerOrder) do
			local offer = self.offers[offerId]
			if not IsValid(caller) or self:MayBuy(caller, offer) then
				local price = economy ~= nil and economy:Format(offer.price) or tostring(offer.price)
				lines[#lines + 1] = format("%-14s x%-3d %8s%s", offerId, offer.count, price,
					not IsValid(caller) and offer.jobs ~= nil and "  " .. concat(offer.jobs, ", ") or "")
			end
		end
		return lines
	end
	if not IsValid(caller) then
		return "nc_buy: run it in the game"
	end
	local times = args[2] ~= nil and tonumber(args[2]) or 1
	local ok, given = self:RequestBuy(caller, id, times)
	if not ok then
		return format("nc_buy %s: %s", id, given)
	end
	local offer = self.offers[id]
	return format("nc_buy %s: bought %d for %s", id, offer.count * times,
		self.economy:Format(offer.price * times))
end

function M:SetJobCommand(caller, args)
	if args[1] == nil or args[2] == nil then
		return "nc_setjob <player> <job>"
	end
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return problem
	end
	local ok, reason = self:SetJob(ply, args[2], true)
	if not ok then
		return "nc_setjob: " .. reason
	end
	return format("nc_setjob: %s is %s", ply:Nick(), args[2])
end
