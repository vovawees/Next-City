-- Roles, server part: who has which role and who knows it.
--
--   roles:Assign(ply, id)        nil clears; emits roles.assigned (ply, id, old)
--   roles:Of(ply), Side(ply), Members(id), OnSide(side), Clear(), Knows(viewer, target)
--   roles:Reveal(on)             everybody knows every role (the end of a round)
--   roles:Deal(players, { { "murderer", 1 }, { "sheriff", 1 } }, "innocent")
--                                -> { [ply] = id }: random players for the counts, the rest
--
-- What a client knows goes out once per tick after a change, only to the clients whose
-- knowledge changed. The rule roles (with the rounds module): revealed at the end of a
-- round, cleared at its cleanup — modes with roles list it.
--
-- Listens: players.left, net.ready.  Emits: roles.assigned (ply, id, old).
-- Commands: nc_roles, nc_role <player> [role] (admin).

local M = NC.Module("roles")

local pairs = pairs
local ipairs = ipairs
local format = string.format
local concat = table.concat
local floor = math.floor
local IsValid = IsValid

M.Random = math.random -- (n) -> 1..n; specs replace it

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.of = {}        -- ply -> role id
	self.revealed = false
	self.sent = {}      -- ply -> signature of the last message
	self.pending = false
	ctx.commands:Add("nc_roles", { help = "roles of the players" }, "ListCommand")
	ctx.commands:Add("nc_role", { help = "<player> [role] - gives a player a role (none clears it)" }, "RoleCommand")
	local rounds = ctx:Require("rounds")
	if rounds ~= nil then
		rounds:RegisterRule({
			id = "roles",
			description = "roles of the players: revealed when the round ends, cleared after it",
			End = function()
				self:Reveal(true)
			end,
			Cleanup = function()
				self:Clear()
			end,
		}, ctx)
	end
end

function M:_StartServer(ctx)
	ctx:On("players.left", "OnLeft")
	ctx:On("net.ready", "OnNetReady")
end

-- Assignment -------------------------------------------------------------------------------

function M:Assign(ply, id)
	assert(id == nil or self.defs[id] ~= nil, "roles: Assign: unknown role " .. tostring(id))
	local old = self.of[ply]
	if old == id then
		return
	end
	self.of[ply] = id
	self:_Changed()
	self.ctx.events:Emit("roles.assigned", ply, id, old)
end

function M:Of(ply)
	return self.of[ply]
end

function M:Side(ply)
	local id = self.of[ply]
	return id and self.defs[id].side or nil
end

-- Players with role `id` / with a role of side `side`, sorted by entity index.
function M:Members(id)
	local out = {}
	for ply, role in pairs(self.of) do
		if role == id and IsValid(ply) then
			out[#out + 1] = ply
		end
	end
	table.sort(out, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return out
end

function M:OnSide(side)
	local out = {}
	for ply, role in pairs(self.of) do
		if self.defs[role].side == side and IsValid(ply) then
			out[#out + 1] = ply
		end
	end
	table.sort(out, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return out
end

-- Takes every role away and hides them again.
function M:Clear()
	local old = self.of
	self.of = {}
	self.revealed = false
	self:_Changed()
	for ply, id in pairs(old) do
		self.ctx.events:Emit("roles.assigned", ply, nil, id)
	end
end

function M:Reveal(on)
	on = on ~= false
	if self.revealed ~= on then
		self.revealed = on
		self:_Changed()
	end
end

function M:IsRevealed()
	return self.revealed
end

-- Whether `viewer` knows the role of `target`.
function M:Knows(viewer, target)
	local id = self.of[target]
	if id == nil then
		return false
	end
	if viewer == target or self.revealed then
		return true
	end
	local def = self.defs[id]
	if def.visible == "all" then
		return true
	end
	if def.visible == "side" then
		local mine = self.of[viewer]
		return mine ~= nil and self.defs[mine].side == def.side
	end
	return false
end

-- Random players of `list` for the counts of `spec` in order, `rest` (a role or nil) for
-- the others; { [ply] = id }. Counts are floored; a list too short fills the first ones.
function M:Deal(list, spec, rest)
	local pool = {}
	for i, ply in ipairs(list) do
		pool[i] = ply
	end
	for i = #pool, 2, -1 do
		local j = M.Random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local out, next = {}, 1
	for _, entry in ipairs(spec) do
		for _ = 1, floor(entry[2] or 0) do
			if pool[next] == nil then
				break
			end
			out[pool[next]] = entry[1]
			next = next + 1
		end
	end
	for i = next, #pool do
		out[pool[i]] = rest
	end
	return out
end

function M:OnLeft(ply)
	self.sent[ply] = nil
	if self.of[ply] ~= nil then
		self:Assign(ply, nil)
	end
end

-- Network ----------------------------------------------------------------------------------

function M:_Changed()
	if self.pending then
		return
	end
	self.pending = true
	self.ctx:After(0, function()
		self.pending = false
		self:Flush()
	end)
end

-- What `viewer` knows: the message and its signature.
function M:_Known(viewer)
	local list, parts = {}, {}
	for target, id in pairs(self.of) do
		if IsValid(target) and self:Knows(viewer, target) then
			local index = self.defs[id].index
			list[#list + 1] = { player = target, role = index }
		end
	end
	table.sort(list, function(a, b) return a.player:EntIndex() < b.player:EntIndex() end)
	for i, entry in ipairs(list) do
		parts[i] = entry.player:EntIndex() .. ":" .. entry.role
	end
	parts[#parts + 1] = self.revealed and "r" or "h"
	return { roles = list, revealed = self.revealed }, concat(parts, ",")
end

-- Sends every ready client what it knows, if that changed.
function M:Flush()
	local net = self.ctx.net
	for _, ply in ipairs(net:ReadyPlayers()) do
		local message, signature = self:_Known(ply)
		if self.sent[ply] ~= signature then
			self.sent[ply] = signature
			net:Send("known", ply, message)
		end
	end
end

function M:OnNetReady(ply)
	local message, signature = self:_Known(ply)
	self.sent[ply] = signature
	self.ctx.net:Send("known", ply, message)
end

-- Commands ---------------------------------------------------------------------------------

function M:ListCommand()
	local lines = {}
	for _, ply in ipairs(player.GetAll()) do
		local id = self.of[ply]
		if id ~= nil then
			lines[#lines + 1] = format("%-20s %-16s side %s", ply:Nick(), id, self.defs[id].side)
		end
	end
	if lines[1] == nil then
		lines[1] = "nobody has a role"
	end
	lines[#lines + 1] = format("roles: %s; revealed: %s", concat(self:All(), ", "), self.revealed and "yes" or "no")
	return lines
end

function M:RoleCommand(caller, args)
	local ply, problem = self.players:Find(args[1], caller)
	if ply == nil then
		return problem
	end
	local id = args[2]
	if id ~= nil and self.defs[id] == nil then
		return "unknown role " .. id .. " (nc_roles)"
	end
	self:Assign(ply, id)
	return id and format("%s is %s now", ply:Nick(), id) or format("%s has no role now", ply:Nick())
end
