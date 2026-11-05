-- City, shared part: the jobs and the names of citizens.
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

local JOB_KEYS = { name = true, description = true, color = true, salary = true, limit = true, kit = true,
	models = true, police = true, mayor = true, default = true }

function M:Init(ctx)
	self.roles = ctx:Require("roles")
	self.jobs = {}
	self.jobOrder = {}
	self.defaultJob = nil
	for _, entry in ipairs(M.JOBS) do
		self:RegisterJob(entry[1], entry[2])
	end
	if SERVER then
		self:_InitServer(ctx)
	end
end

function M:Start(ctx)
	ctx:On("players.name", "AnswerName")
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
