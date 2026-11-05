-- City, shared part: the jobs, the shop of the jobs and the names of citizens.
--
-- A job is a public role (roles, visible = all) registered on both realms in the same
-- order, with the data of the city: a salary per payday, a limit of places (0: none), the
-- kit of its gear (inventory, default city_<id>), player models, and whether it keeps the
-- law (police) or heads the city (mayor). Packages add jobs with RegisterJob in their Init
-- on both realms.
--
--   city:RegisterJob(id, def), city:Job(id), city:Jobs() -> ids in order, city:DefaultJob()
--   city:JobOf(ply) -> the job (known on the client: every job is public), city:IsPolice(ply)
--   city:CitizenName(ply) -> the name he goes by in the city, or nil (players.name)
--   doors.member (ply, group): a job holds the keys of the doors of its group (by its key;
--   "police": every job that keeps the law and the mayor)
--   law.officer (ply), law.authority (ply): the jobs that keep the law are its officers, the
--   mayor heads it (the law module: the wanted, warrants, arrests, the jail)
--
-- The shop: offers in the order of the menu, registered on both realms in the same order
-- (RegisterOffer in Init of a package). An offer sells `count` of an item (default: the
-- item of its key) for `price`, to the jobs in `jobs` (nil: to everybody).
--
--   city:RegisterOffer(id, def), city:Offer(id), city:Offers() -> ids in order
--   city:MayBuy(ply, offer) -> whether his job may buy it, city:OffersFor(ply) -> offers

local M = NC.Module("mode_city")

local ipairs = ipairs
local type = type
local format = string.format

local WHITE = Color(235, 235, 235)

local function models(path, list)
	local out = {}
	for i, name in ipairs(list) do
		out[i] = format(path, name)
	end
	return out
end

local CITIZENS = models("models/player/group01/%s.mdl", { "male_01", "male_02", "male_03", "male_04", "male_05",
	"male_06", "male_07", "male_08", "male_09", "female_01", "female_02", "female_03", "female_04", "female_06" })
local REBELS = models("models/player/group03/%s.mdl", { "male_01", "male_02", "male_03", "male_04", "male_05",
	"male_06", "male_07", "male_08", "male_09", "female_01", "female_02", "female_03", "female_04", "female_06" })
local MEDICS = models("models/player/group03m/%s.mdl", { "male_01", "male_02", "male_03", "male_04", "male_05",
	"male_06", "male_07", "male_08", "male_09", "female_01", "female_02", "female_03", "female_04", "female_06" })

M.JOBS = {
	{ "citizen", { color = Color(90, 180, 100), salary = 45, default = true, models = CITIZENS } },
	{ "police", { color = Color(70, 120, 235), salary = 85, limit = 4, police = true,
		models = { "models/player/police.mdl", "models/player/police_fem.mdl" } } },
	{ "medic", { color = Color(225, 90, 130), salary = 70, limit = 3, models = MEDICS } },
	{ "gundealer", { color = Color(225, 155, 60), salary = 55, limit = 2, models = { "models/player/odessa.mdl" } } },
	{ "mayor", { color = Color(185, 50, 50), salary = 130, limit = 1, mayor = true,
		models = { "models/player/breen.mdl" } } },
	{ "bandit", { color = Color(140, 140, 140), salary = 25, limit = 4, models = REBELS } },
}

local MEDIC = { "medic" }
local DEALER = { "gundealer" }

M.SHOP = {
	{ "bandage", { price = 15 } },
	{ "pouch", { price = 40 } },
	{ "backpack", { price = 180 } },
	{ "gauze", { price = 30, jobs = MEDIC } },
	{ "tourniquet", { price = 40, jobs = MEDIC } },
	{ "splint", { price = 35, jobs = MEDIC } },
	{ "chest_seal", { price = 45, jobs = MEDIC } },
	{ "morphine", { price = 60, jobs = MEDIC } },
	{ "naloxone", { price = 50, jobs = MEDIC } },
	{ "epinephrine", { price = 70, jobs = MEDIC } },
	{ "txa", { price = 55, jobs = MEDIC } },
	{ "saline", { price = 40, jobs = MEDIC } },
	{ "blood", { price = 90, jobs = MEDIC } },
	{ "ifak", { price = 120, jobs = MEDIC } },
	{ "defibrillator", { price = 400, jobs = MEDIC } },
	{ "usp", { price = 250, jobs = DEALER } },
	{ "python", { price = 600, jobs = DEALER } },
	{ "mp7", { price = 1100, jobs = DEALER } },
	{ "spas12", { price = 1300, jobs = DEALER } },
	{ "knife", { price = 60, jobs = { "gundealer", "bandit" } } },
	{ "ammo_9x19", { count = 30, price = 45, jobs = { "gundealer", "police" } } },
	{ "ammo_357", { count = 12, price = 60, jobs = DEALER } },
	{ "ammo_46x30", { count = 40, price = 80, jobs = DEALER } },
	{ "ammo_12g_buck", { count = 16, price = 60, jobs = DEALER } },
	{ "helmet", { price = 200, jobs = { "gundealer", "police" } } },
	{ "vest_light", { price = 250, jobs = { "gundealer", "police" } } },
	{ "vest", { price = 450, jobs = { "police" } } },
	{ "zipties", { count = 5, price = 25, jobs = { "police", "bandit" } } },
	{ "lockpick", { price = 150, jobs = { "bandit" } } },
}

-- The most purchases of an offer at once.
M.MAX_TIMES = 20

local JOB_KEYS = { name = true, description = true, color = true, salary = true, limit = true, kit = true,
	models = true, police = true, mayor = true, default = true }

function M:Init(ctx)
	self.roles = ctx:Require("roles")
	self.jobs = {}
	self.jobOrder = {}
	self.defaultJob = nil
	self.offers = {}
	self.offerOrder = {}
	for _, entry in ipairs(M.JOBS) do
		self:RegisterJob(entry[1], entry[2])
	end
	for _, entry in ipairs(M.SHOP) do
		self:RegisterOffer(entry[1], entry[2])
	end
	if SERVER then
		self:_InitServer(ctx)
	else
		self:_InitClient(ctx)
	end
end

function M:Start(ctx)
	ctx:On("players.name", "AnswerName")
	ctx:On("doors.member", "AnswerMember")
	ctx:On("law.officer", "AnswerOfficer")
	ctx:On("law.authority", "AnswerAuthority")
	if SERVER then
		self:_StartServer(ctx)
	else
		self:_StartClient(ctx)
	end
end

-- Registers or replaces a job (see the top of the file); its definition.
function M:RegisterJob(id, def)
	def = def or {}
	for key in pairs(def) do
		assert(JOB_KEYS[key], format("mode_city: job %s: unknown field %s", tostring(id), tostring(key)))
	end
	local job = {
		id = id,
		name = def.name or "mode_city.job." .. id,
		description = def.description or "mode_city.job." .. id .. ".desc",
		color = def.color or WHITE,
		salary = math.max(0, math.floor(def.salary or 0)),
		limit = math.max(0, math.floor(def.limit or 0)),
		kit = def.kit or "city_" .. id,
		models = type(def.models) == "table" and def.models or {},
		police = def.police == true,
		mayor = def.mayor == true,
	}
	self.roles:Register(id, { name = job.name, description = job.description, color = job.color,
		visible = "all", intro = true })
	if self.jobs[id] == nil then
		self.jobOrder[#self.jobOrder + 1] = id
	end
	self.jobs[id] = job
	if def.default == true or self.defaultJob == nil then
		self.defaultJob = id
	end
	return job
end

function M:Job(id)
	return self.jobs[id]
end

function M:Jobs()
	local out = {}
	for i, id in ipairs(self.jobOrder) do
		out[i] = id
	end
	return out
end

function M:DefaultJob()
	return self.defaultJob
end

-- The job of a player, or nil.
function M:JobOf(ply)
	local id = self.roles:Of(ply)
	return id ~= nil and self.jobs[id] or nil
end

function M:IsPolice(ply)
	local job = self:JobOf(ply)
	return job ~= nil and job.police
end

function M:IsMayor(ply)
	local job = self:JobOf(ply)
	return job ~= nil and job.mayor
end

local OFFER_KEYS = { item = true, count = true, price = true, jobs = true }

-- Registers or replaces an offer of the shop (see the top of the file); the offer.
function M:RegisterOffer(id, def)
	for key in pairs(def) do
		assert(OFFER_KEYS[key], format("mode_city: offer %s: unknown field %s", tostring(id), tostring(key)))
	end
	local count, price = def.count or 1, def.price
	assert(type(price) == "number" and price >= 1 and price == math.floor(price),
		format("mode_city: offer %s: the price is a whole number from 1", tostring(id)))
	assert(type(count) == "number" and count >= 1 and count == math.floor(count),
		format("mode_city: offer %s: the count is a whole number from 1", tostring(id)))
	local offer = { id = id, item = def.item or id, count = count, price = price, jobs = nil, allowed = nil }
	if type(def.jobs) == "table" then
		offer.jobs, offer.allowed = {}, {}
		for i, job in ipairs(def.jobs) do
			offer.jobs[i], offer.allowed[job] = job, true
		end
	end
	if self.offers[id] == nil then
		assert(#self.offerOrder < 255, "mode_city: at most 255 offers")
		self.offerOrder[#self.offerOrder + 1] = id
	end
	self.offers[id] = offer
	return offer
end

function M:Offer(id)
	return self.offers[id]
end

function M:Offers()
	local out = {}
	for i, id in ipairs(self.offerOrder) do
		out[i] = id
	end
	return out
end

-- Whether the job of a player may buy an offer.
function M:MayBuy(ply, offer)
	if offer.allowed == nil then
		return true
	end
	local job = self:JobOf(ply)
	return job ~= nil and offer.allowed[job.id] == true
end

-- The offers the job of a player may buy, in the order of the menu.
function M:OffersFor(ply)
	local out = {}
	for _, id in ipairs(self.offerOrder) do
		local offer = self.offers[id]
		if self:MayBuy(ply, offer) then
			out[#out + 1] = offer
		end
	end
	return out
end

-- The name a player goes by in the city, or nil.
function M:CitizenName(ply)
	local citizen = self.ctx.components.citizen:Get(ply)
	if citizen == nil or citizen.name == "" then
		return nil
	end
	return citizen.name
end

function M:AnswerName(_, ply)
	return self:CitizenName(ply)
end

-- The groups of doors of the map in the city: a job by its key; the police doors open to
-- every job that keeps the law and to the mayor.
function M:AnswerMember(ply, group)
	local job = self:JobOf(ply)
	if job ~= nil and (job.id == group or (group == "police" and (job.police or job.mayor))) then
		return true
	end
end

function M:AnswerOfficer(ply)
	if self:IsPolice(ply) then
		return true
	end
end

function M:AnswerAuthority(ply)
	if self:IsMayor(ply) then
		return true
	end
end
