-- Economy, shared part: the cash item and amounts of money as text.
--
--   economy:Format(1250) -> "$1 250" (config currency and group)
--   economy.item         -> the id of the cash item

local M = NC.Module("economy")

local floor = math.floor
local abs = math.abs
local format = string.format
local concat = table.concat

function M:Init(ctx)
	local config = ctx.config
	self.inventory = ctx:Require("inventory")
	self.item = config.item
	self.inventory:RegisterItem(config.item, {
		name = "economy.money",
		description = "economy.money.desc",
		model = config.model,
		weight = config.weight,
		stack = config.stack,
		size = 1,
		category = "valuable",
		traits = { money = {} },
	})
	if SERVER then
		self:_InitServer(ctx)
	end
end

function M:Start(ctx)
	if SERVER then
		self:_StartServer(ctx)
	end
end

-- An amount of money as text: the currency, then the digits in groups of three.
function M:Format(amount)
	local config = self.ctx.config
	local value = floor(tonumber(amount) or 0)
	local digits = format("%d", abs(value))
	local head = #digits % 3
	local parts = {}
	if head > 0 then
		parts[1] = digits:sub(1, head)
	end
	for i = head + 1, #digits, 3 do
		parts[#parts + 1] = digits:sub(i, i + 2)
	end
	return (value < 0 and "-" or "") .. config.currency .. concat(parts, config.group)
end
