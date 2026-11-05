-- Economy, server part: accounts, cash, payments and charges, handing cash over.
--
--   economy:Balance(ply), economy:Cash(ply), economy:Wealth(ply) (both)
--   economy:Pay(ply, amount, reason)     -> true or false, reason   into the account
--   economy:Charge(ply, amount, reason)  -> true or false, reason   the account first, then cash
--   economy:CanAfford(ply, amount)
--   economy:Deposit(ply, amount), economy:Withdraw(ply, amount) -> amount moved or false, reason
--   economy:Hand(ply, target, amount)    -> amount handed or false, reason (cash, face to face)
--   economy:Drop(ply, amount)            -> the entity, amount or false, reason (on the ground)
--   economy:SetBalance(ply, amount), economy:GiveCash(ply, amount, opts), economy:TakeCash(ply, amount)
--   economy:Aimed(ply)                   -> the living player in front within range
--
-- Accounts are kept by the storage key of a player (SteamID64, "bot_<name>" for bots) in
-- the namespace "economy" (without storage: for this session); a new one starts with
-- config.start. Reasons: amount, cash, funds, full, target, range, dead.
--
-- Listens:  players.ready (the account component), players.left (first: the cash he
--           carries goes into his account), net cash.
-- Emits:    economy.paid (ply, amount, reason), economy.charged (ply, amount, reason),
--           economy.handed (ply, target, amount), economy.balance (ply, balance, old).
-- Commands: nc_bank [deposit | withdraw <amount | all>], nc_givemoney <amount>,
--           nc_dropmoney <amount>, nc_money [player] [set | add <amount>] (admin).

local M = NC.Module("economy")

local IsValid = IsValid
local ipairs = ipairs
local floor = math.floor
local min = math.min
local max = math.max
local format = string.format

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.notices = ctx:Require("notices")
	self.storage = ctx:Require("storage")
	self.store = self.storage ~= nil and self.storage:Open("economy") or nil
	self.memory = {} -- accounts without storage: key -> { balance }
	ctx.net:Receive("cash", "OnCash")
end

function M:_StartServer(ctx)
	ctx:On("players.ready", "Show")
	ctx:On("players.left", "OnLeft", { priority = 10 })
	ctx.commands:Add("nc_bank", { help = "[deposit | withdraw <amount | all>] - your account and cash",
		admin = false }, "BankCommand")
	ctx.commands:Add("nc_givemoney", { help = "<amount> - hand cash to the player in front of you", admin = false },
		"GiveCommand")
	ctx.commands:Add("nc_dropmoney", { help = "<amount> - put cash on the ground", admin = false }, "DropCommand")
	ctx.commands:Add("nc_money", { help = "[player] [set | add <amount>] - the accounts of players" },
		"MoneyCommand")
	for _, ply in ipairs(self.players:ReadyPlayers()) do
		self:Show(ply)
	end
end

-- The key of the account of a player.
function M:Key(ply)
	if self.storage ~= nil then
		return self.storage:PlayerKey(ply)
	end
	return ply:IsBot() and "bot_" .. ply:Nick() or ply:SteamID64()
end

-- The account of a player (made with config.start when he has none).
function M:Account(ply)
	local key = self:Key(ply)
	local store = self.store
	local account
	if store ~= nil then
		account = store:Get(key)
	else
		account = self.memory[key]
	end
	if type(account) ~= "table" or type(account.balance) ~= "number" then
		account = { balance = max(0, floor(self.ctx.config.start)) }
		if store ~= nil then
			store:Set(key, account)
		else
			self.memory[key] = account
		end
	end
	return account
end

function M:Balance(ply)
	return self:Account(ply).balance
end

function M:Cash(ply)
	return self.inventory:Count(ply, self.item)
end

-- Cash and the account together.
function M:Wealth(ply)
	return self:Balance(ply) + self:Cash(ply)
end

function M:CanAfford(ply, amount)
	return self:Wealth(ply) >= amount
end

-- The balance in the account component of the player (only he sees it).
function M:Show(ply)
	if not IsValid(ply) then
		return
	end
	local balance = min(self:Balance(ply), 4294967295)
	local account = self.ctx.components.account
	if account:Get(ply) == nil then
		account:Add(ply, { balance = balance })
	else
		account:Set(ply, "balance", balance)
	end
end

function M:SetBalance(ply, amount)
	local account = self:Account(ply)
	local old = account.balance
	account.balance = max(0, min(floor(amount), self.ctx.config.maxBalance))
	if self.store ~= nil then
		self.store:Touch()
	end
	self:Show(ply)
	if account.balance ~= old then
		self.ctx.events:Emit("economy.balance", ply, account.balance, old)
	end
	return account.balance
end

-- A whole positive amount, or nil.
local function whole(amount)
	amount = tonumber(amount)
	if amount == nil or amount ~= amount or amount < 1 or amount == math.huge then
		return nil
	end
	return floor(amount)
end

-- Gives cash into the inventory of a player: how much went in (opts as inventory:Give).
function M:GiveCash(ply, amount, opts)
	local given = self.inventory:Give(ply, self.item, amount, nil, opts)
	return given or 0
end

function M:TakeCash(ply, amount)
	return self.inventory:Take(ply, self.item, amount)
end

-- Pays `amount` into the account of a player (a salary, a refund, a sale).
function M:Pay(ply, amount, reason)
	amount = whole(amount)
	if amount == nil then
		return false, "amount"
	end
	self:SetBalance(ply, self:Balance(ply) + amount)
	self.ctx.events:Emit("economy.paid", ply, amount, reason)
	return true
end

-- Charges a player `amount`: from the account, what it lacks from the cash he carries.
function M:Charge(ply, amount, reason)
	amount = whole(amount)
	if amount == nil then
		return false, "amount"
	end
	local balance, cash = self:Balance(ply), self:Cash(ply)
	if balance + cash < amount then
		return false, "funds"
	end
	local fromAccount = min(balance, amount)
	if amount > fromAccount then
		local taken = self:TakeCash(ply, amount - fromAccount)
		if taken < amount - fromAccount then
			self:GiveCash(ply, taken, { drop = true })
			return false, "funds"
		end
	end
	if fromAccount > 0 then
		self:SetBalance(ply, balance - fromAccount)
	end
	self.ctx.events:Emit("economy.charged", ply, amount, reason)
	return true
end

-- Cash into the account; the amount moved.
function M:Deposit(ply, amount)
	amount = whole(amount)
	if amount == nil then
		return false, "amount"
	end
	if self:Cash(ply) < amount then
		return false, "cash"
	end
	local room = self.ctx.config.maxBalance - self:Balance(ply)
	if room < amount then
		return false, "full"
	end
	local taken = self:TakeCash(ply, amount)
	self:SetBalance(ply, self:Balance(ply) + taken)
	return taken
end

-- Cash out of the account into the pockets, as much as fits; the amount moved.
function M:Withdraw(ply, amount)
	amount = whole(amount)
	if amount == nil then
		return false, "amount"
	end
	local balance = self:Balance(ply)
	if balance < amount then
		return false, "funds"
	end
	local given = self:GiveCash(ply, amount)
	if given <= 0 then
		return false, "full"
	end
	self:SetBalance(ply, balance - given)
	return given
end

-- The living player in front of `ply` within config.range, or nil.
function M:Aimed(ply)
	local eye = ply:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * self.ctx.config.range,
		filter = ply, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	if ent == nil or not IsValid(ent) or not ent:IsPlayer() or not self.players:IsAlive(ent) then
		return nil
	end
	return ent
end

-- Hands `amount` of cash to `target`, face to face; the amount handed.
function M:Hand(ply, target, amount)
	amount = whole(amount)
	if amount == nil then
		return false, "amount"
	end
	if not self.players:IsAlive(ply) then
		return false, "dead"
	end
	if target == nil or not IsValid(target) or target == ply or not self.players:IsAlive(target) then
		return false, "target"
	end
	if ply:GetPos():Distance(target:GetPos()) > self.ctx.config.range + 32 then
		return false, "range"
	end
	if self:Cash(ply) < amount then
		return false, "cash"
	end
	local taken = self:TakeCash(ply, amount)
	local given = self:GiveCash(target, taken)
	if given < taken then
		self:GiveCash(ply, taken - given, { drop = true })
	end
	if given <= 0 then
		return false, "full"
	end
	self.ctx.events:Emit("economy.handed", ply, target, given)
	return given
end

-- Puts `amount` of cash on the ground in front of a player (at most a stack): the entity
-- and the amount.
function M:Drop(ply, amount)
	amount = whole(amount)
	if amount == nil then
		return false, "amount"
	end
	if not self.players:IsAlive(ply) then
		return false, "dead"
	end
	if self:Cash(ply) < amount then
		return false, "cash"
	end
	local inventory = self.inventory
	local item = inventory:Create(self.item, min(amount, self.ctx.config.stack))
	if item == nil then
		return false, "cash"
	end
	self:TakeCash(ply, item.count)
	local count = item.count
	local ent = inventory:SpawnItem(item, inventory:DropPos(ply), Angle(0, ply:EyeAngles().y, 0))
	if ent == nil then
		self:GiveCash(ply, count, { drop = true })
		return false, "full"
	end
	return ent, count
end

-- A player leaves: the cash he carries goes into his account.
function M:OnLeft(ply)
	if not self.ctx.config.depositOnLeave then
		return
	end
	local cash = self:Cash(ply)
	if cash > 0 then
		local taken = self:TakeCash(ply, cash)
		self:SetBalance(ply, self:Balance(ply) + taken)
	end
	if self.store ~= nil then
		self.store:Flush()
	end
end

-- Tells a player what happened (key economy.<what>) with the amounts as text.
function M:Tell(ply, key, params, kind)
	if self.notices ~= nil and IsValid(ply) then
		self.notices:Send(ply, "economy." .. key, params, kind or "info")
	end
end

-- What a player is told when cash moved, by operation.
M.DONE = { deposit = "deposited", withdraw = "withdrew", give = "gave", drop = "dropped" }

-- Cash in the hands, for the bank screen and the commands: the player learns what happened.
-- true, or false and the reason.
function M:Handle(ply, op, amount)
	local result, reason, moved, target
	if op == "deposit" then
		result, reason = self:Deposit(ply, amount)
		moved = result
	elseif op == "withdraw" then
		result, reason = self:Withdraw(ply, amount)
		moved = result
	elseif op == "give" then
		target = self:Aimed(ply)
		result, reason = self:Hand(ply, target, amount)
		moved = result
	elseif op == "drop" then
		local info
		result, info = self:Drop(ply, amount)
		if result then
			moved = info
		else
			reason = info
		end
	else
		return false, "amount"
	end
	if not result then
		self:Tell(ply, "fail." .. tostring(reason), nil, "bad")
		return false, reason
	end
	local params = { amount = self:Format(moved), balance = self:Format(self:Balance(ply)) }
	if target ~= nil then
		params.who = self.players:Name(target)
		self:Tell(target, "got", { amount = params.amount, who = self.players:Name(ply) }, "good")
	end
	self:Tell(ply, M.DONE[op], params, "good")
	return true
end

function M:OnCash(data, ply)
	if self.players:IsReady(ply) then
		self:Handle(ply, data.op, data.amount)
	end
end

-- Commands ------------------------------------------------------------------------------

local function describe(self, ply)
	return format("%s: account %s, cash %s", ply:Nick(), self:Format(self:Balance(ply)), self:Format(self:Cash(ply)))
end

function M:BankCommand(caller, args)
	if not IsValid(caller) then
		return "nc_bank: run it in the game"
	end
	local op = args[1]
	if op == nil then
		return describe(self, caller)
	end
	if op ~= "deposit" and op ~= "withdraw" then
		return "nc_bank [deposit | withdraw <amount | all>]"
	end
	local amount = args[2]
	if amount == "all" then
		amount = op == "deposit" and self:Cash(caller) or self:Balance(caller)
	end
	local ok, reason = self:Handle(caller, op, amount)
	if not ok then
		return "nc_bank: " .. tostring(reason)
	end
	return describe(self, caller)
end

function M:GiveCommand(caller, args)
	if not IsValid(caller) then
		return "nc_givemoney: run it in the game"
	end
	local ok, reason = self:Handle(caller, "give", args[1])
	return ok and describe(self, caller) or "nc_givemoney <amount>: " .. tostring(reason)
end

function M:DropCommand(caller, args)
	if not IsValid(caller) then
		return "nc_dropmoney: run it in the game"
	end
	local ok, reason = self:Handle(caller, "drop", args[1])
	return ok and describe(self, caller) or "nc_dropmoney <amount>: " .. tostring(reason)
end

function M:MoneyCommand(caller, args)
	if args[1] == nil then
		local lines = {}
		for _, ply in ipairs(self.players:ReadyPlayers()) do
			lines[#lines + 1] = describe(self, ply)
		end
		return lines[1] ~= nil and lines or "nc_money: nobody is here"
	end
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return problem
	end
	local op, amount = args[2], tonumber(args[3])
	if op == nil then
		return describe(self, ply)
	end
	if (op ~= "set" and op ~= "add") or amount == nil or amount ~= amount then
		return "nc_money <player> [set | add <amount>]"
	end
	self:SetBalance(ply, op == "set" and amount or self:Balance(ply) + amount)
	return describe(self, ply)
end
