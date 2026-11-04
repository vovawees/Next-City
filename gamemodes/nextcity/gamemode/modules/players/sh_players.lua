-- Players module, shared part: the life state of every player (replicated to clients).
--
-- States:
--   connecting  joined, the client is still loading (bots skip it)
--   spectator   ready, not in the game (observer)
--   alive       in the game
--   dead        in the game, died; stays dead until someone deploys the player again

local M = NC.Module("players")

M.STATES = { "connecting", "spectator", "alive", "dead" }

local EMPTY = {}

-- Life state of a player, or nil for an unknown player.
function M:State(ply)
	local life = self.ctx.components.life:Get(ply)
	return life and life.state or nil
end

function M:IsAlive(ply)
	return self:State(ply) == "alive"
end

-- A ready player has loaded (or is a bot): every state except "connecting".
function M:IsReady(ply)
	local state = self:State(ply)
	return state ~= nil and state ~= "connecting"
end

-- Game time a dead player comes back, or nil.
function M:RespawnAt(ply)
	local life = self.ctx.components.life:Get(ply)
	local at = life and life.respawnAt or 0
	return at > 0 and at or nil
end

-- Players in a state, sorted by entity index. The server keeps these lists up to date
-- (sv_players.lua); clients build them from the replicated states.
function M:List(state)
	local list = {}
	for index, life in self.ctx.components.life:Each() do
		if life.state == state then
			local ply = Entity(index)
			if IsValid(ply) then
				list[#list + 1] = ply
			end
		end
	end
	table.sort(list, function(a, b) return a:EntIndex() < b:EntIndex() end)
	return list
end

function M:Count(state)
	return #(self:List(state) or EMPTY)
end

-- Finds a player by the text of a console argument: nothing or "^" is `caller`, "#n" or
-- a number the player with that entity index, otherwise the player with exactly that
-- name or the only one whose name contains the text (any case). Returns the player, or
-- nil and the problem.
function M:Find(text, caller)
	if text == nil or text == "" or text == "^" then
		if IsValid(caller) then
			return caller
		end
		return nil, "no player given"
	end
	local index = tonumber(text:match("^#?(%d+)$") or "")
	if index ~= nil then
		local ply = Entity(index)
		if IsValid(ply) and ply:IsPlayer() then
			return ply
		end
		return nil, "no player #" .. index
	end
	local lower = text:lower()
	local found, count = nil, 0
	for _, ply in ipairs(player.GetAll()) do
		local name = ply:Nick()
		if name == text then
			return ply
		end
		if name:lower():find(lower, 1, true) ~= nil then
			found, count = ply, count + 1
		end
	end
	if count == 1 then
		return found
	end
	if count == 0 then
		return nil, "no player matches '" .. text .. "'"
	end
	return nil, count .. " players match '" .. text .. "'"
end
