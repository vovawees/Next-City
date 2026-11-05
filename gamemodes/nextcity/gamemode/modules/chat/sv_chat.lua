-- Chat, server part.
--
--   chat:Say(ply, text, teamChat) -> true or false, reason: a line a player typed (what
--                          gm.PlayerSay brings): a line of a channel, a private message or a
--                          command; a notice tells him what went wrong. Reasons: empty, long,
--                          spam, repeat, unconscious, denied, target (no such player), many
--                          (more than one matches), self, nobody (no one to reply to), unknown
--   chat:Send(ply, channel, text) -> true or false, reason: a line of a channel from a player
--                          without the antispam (modules)
--   chat:Private(ply, target, text) -> true or false, reason: a private message
--   chat:Info(ply, lines)  lines of the chat for one player (the replies of commands)
--   chat:Audience(ply, channel, text) -> the ready players who get his line, by entity index
--   chat:Proximity(ply)    -> whether the lines he says in character are heard only around him
--   chat:Range(ply, channel) -> units around him a line of the channel goes, or nil: everywhere
--   chat:Find(text, ply)   -> the player whose name others see is the text (or the only one
--                          with it in the name, any case), or nil and target | many
--
-- Who gets a line. In character (say, whisper, yell, me, it, team): a whisper always around
-- the speaker, the rest around him where the chat is local (chat.proximity), everywhere
-- otherwise; the unconscious do not hear them; team: his team only (team play of the module
-- teams; otherwise a team line is said aloud). A speaker who is not alive talks to those who
-- are not alive where the chat is local, to everybody otherwise (marked dead). OOC goes to
-- everybody, LOOC around. Every listener at last passes gm.PlayerCanSeePlayersChat (the rule
-- dead_mute of rounds: the living do not read the dead); the speaker always sees his line.
--
-- A line is cleaned (control characters), at most maxLength characters; a player sends burst
-- lines in a row and then rate per second; the same line again only after repeatDelay s. The
-- unconscious (organism) speak only out of character. "/<word> args" is a command: a module
-- answers chat.command, otherwise the command nc_<word> runs (its privilege, the reply in the
-- chat); unknown words get a notice and stay private.
--
-- Listens:  players.left; answers gm.PlayerSay ("": the engine shows nothing, the lines go by
--           the net message line).
-- Asks:     chat.proximity (ply) -> true: local, false: global (default config.proximity);
--           chat.canSpeak (ply, channel, text) -> false: he may not;
--           chat.command (ply, word, args, rest) -> true (done), a reply (a string or lines) or
--           false (denied); gm.PlayerCanSeePlayersChat (text, teamOnly, listener, speaker).
-- Emits:    chat.said (ply, channel, text, audience) (pm: audience = { ply, target }).

local M = NC.Module("chat")

local IsValid = IsValid
local CurTime = CurTime
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local min = math.min
local format = string.format
local concat = table.concat
local sort = table.sort
local HUD_PRINTCONSOLE = HUD_PRINTCONSOLE

local MAX_REPLY = 12 -- lines of a reply in the chat; all of them go to the console

local function byIndex(a, b)
	return a:EntIndex() < b:EntIndex()
end

function M:_InitServer(ctx)
	self.players = ctx:Require("players")
	self.notices = ctx:Require("notices")
	self.organism = ctx:Require("organism")
	self.teams = ctx:Require("teams")
	self.buckets = {}  -- ply -> { tokens, at }
	self.last = {}     -- ply -> { text, at }: his last line
	self.partners = {} -- ply -> the player of his last private message
	ctx.commands:Add("nc_chat", { help = "the channels of the chat and whether it is local now", admin = false },
		"ChatCommand")
end

function M:_StartServer(ctx)
	ctx:On("gm.PlayerSay", "AnswerSay")
	ctx:On("players.left", "OnLeft")
end

function M:OnLeft(ply)
	self.buckets[ply], self.last[ply], self.partners[ply] = nil, nil, nil
	for other, partner in pairs(self.partners) do
		if partner == ply then
			self.partners[other] = nil
		end
	end
end

function M:AnswerSay(ply, text, teamChat)
	if not IsValid(ply) or not ply:IsPlayer() then
		return nil
	end
	self:Say(ply, text, teamChat)
	return ""
end

function M:_Fail(ply, reason, params)
	if self.notices ~= nil then
		self.notices:Send(ply, "chat.fail." .. reason, params, "bad")
	end
	return false, reason
end

-- Lines ---------------------------------------------------------------------------------------

-- The antispam: the length, the rate (a bucket of burst tokens) and the same line again.
function M:_Flood(ply, text)
	local cfg = self.ctx.config
	if M.Length(text) > cfg.maxLength then
		return false, "long", { count = cfg.maxLength }
	end
	local now = CurTime()
	local bucket = self.buckets[ply]
	if bucket == nil then
		bucket = { tokens = cfg.burst, at = now }
		self.buckets[ply] = bucket
	end
	bucket.tokens = min(cfg.burst, bucket.tokens + (now - bucket.at) * cfg.rate)
	bucket.at = now
	if bucket.tokens < 1 then
		return false, "spam"
	end
	local last = self.last[ply]
	if last ~= nil and last.text == text and now - last.at < cfg.repeatDelay then
		return false, "repeat"
	end
	bucket.tokens = bucket.tokens - 1
	self.last[ply] = { text = text, at = now }
	return true
end

function M:Say(ply, text, teamChat)
	text = M.Clean(text)
	if text == "" then
		return false, "empty"
	end
	local ok, reason, params = self:_Flood(ply, text)
	if not ok then
		return self:_Fail(ply, reason, params)
	end
	local what, rest, word = M.Parse(text)
	if what == "command" then
		return self:_Command(ply, word, rest)
	end
	if what == "pm" then
		local target, problem, message = self:_Target(ply, rest)
		if target == nil then
			return self:_Fail(ply, problem, { command = "/pm" })
		end
		return self:Private(ply, target, message)
	end
	if what == "reply" then
		local partner = self.partners[ply]
		if partner == nil or not IsValid(partner) then
			return self:_Fail(ply, "nobody")
		end
		return self:Private(ply, partner, rest)
	end
	if what == "say" and teamChat and self:_Teamed(ply) then
		what = "team"
	end
	local sent, problem = self:Send(ply, what, rest)
	if not sent then
		return self:_Fail(ply, problem, { command = what == "say" and "" or "/" .. what })
	end
	return true
end

function M:_Teamed(ply)
	local teams = self.teams
	return teams ~= nil and teams:Count() > 0 and teams:Of(ply) ~= nil
end

function M:_Unconscious(ply)
	local organism = self.organism
	return organism ~= nil and organism:IsUnconscious(ply) == true
end

function M:Proximity(ply)
	local answer = self.ctx.events:Query("chat.proximity", ply)
	if answer ~= nil then
		return answer == true
	end
	return self.ctx.config.proximity == true
end

function M:Range(ply, channel)
	local cfg = self.ctx.config
	if channel == "whisper" then
		return cfg.whisperRange
	end
	if channel == "looc" then
		return cfg.loocRange
	end
	if channel == "say" or channel == "me" or channel == "it" then
		return self:Proximity(ply) and cfg.sayRange or nil
	end
	if channel == "yell" then
		return self:Proximity(ply) and cfg.yellRange or nil
	end
	return nil
end

-- Whether a listener gets a line of the speaker (not the speaker himself).
function M:_Gets(speaker, listener, channel, text, near)
	local players = self.players
	local ic = M.IC[channel] == true
	if ic and self:_Unconscious(listener) then
		return false
	end
	-- Where the chat is local the dead talk to those who are not alive, everywhere.
	local ghost = ic and not players:IsAlive(speaker)
	if ghost and near.proximity and players:IsAlive(listener) then
		return false
	end
	if channel == "team" and listener:Team() ~= speaker:Team() then
		return false
	end
	local range = near.range
	if range ~= nil and not (ghost and near.proximity)
		and listener:GetPos():DistToSqr(near.origin) > range * range then
		return false
	end
	return self.ctx.events:Query("gm.PlayerCanSeePlayersChat", text, channel == "team", listener, speaker) ~= false
end

function M:Audience(ply, channel, text)
	local near = { proximity = self:Proximity(ply), range = self:Range(ply, channel), origin = ply:GetPos() }
	local out = {}
	for _, listener in ipairs(self.players:ReadyPlayers()) do
		if listener == ply or self:_Gets(ply, listener, channel, text or "", near) then
			out[#out + 1] = listener
		end
	end
	sort(out, byIndex)
	return out
end

-- Sends a line to the net-ready players of a list.
function M:_Deliver(list, data)
	local net, ready = self.ctx.net, {}
	for _, ply in ipairs(list) do
		if net:IsReady(ply) then
			ready[#ready + 1] = ply
		end
	end
	if ready[1] ~= nil then
		net:Send("line", ready, data)
	end
end

function M:_Log(ply, channel, text, target)
	if not self.ctx.config.log then
		return
	end
	local players = self.players
	local name, nick = players:Name(ply), ply:Nick()
	local who = name == nick and name or format("%s (%s)", name, nick)
	if target ~= nil then
		who = who .. " -> " .. players:Name(target)
	end
	self.ctx.log:Info("%s %s: %s", channel, who, text)
end

function M:Send(ply, channel, text)
	text = M.Cut(M.Clean(text), M.MAX_TEXT)
	if not IsValid(ply) or M.IC[channel] == nil and channel ~= "ooc" and channel ~= "looc" then
		return false, "denied"
	end
	if text == "" then
		return false, "empty"
	end
	if M.IC[channel] and self:_Unconscious(ply) then
		return false, "unconscious"
	end
	if self.ctx.events:Query("chat.canSpeak", ply, channel, text) == false then
		return false, "denied"
	end
	local audience = self:Audience(ply, channel, text)
	local players = self.players
	self:_Deliver(audience, { channel = channel, speaker = ply, name = channel == "it" and "" or players:Name(ply),
		text = text, dead = M.IC[channel] == true and not players:IsAlive(ply) })
	self:_Log(ply, channel, text)
	self.ctx.events:Emit("chat.said", ply, channel, text, audience)
	return true
end

-- Private messages ------------------------------------------------------------------------------

function M:Find(text, ply)
	local wanted = M.Fold(M.Clean(text))
	if wanted == "" then
		return nil, "target"
	end
	local found, count = nil, 0
	for _, other in ipairs(self.players:ReadyPlayers()) do
		local name = M.Fold(self.players:Name(other))
		if name == wanted then
			return other
		end
		if other ~= ply and name:find(wanted, 1, true) ~= nil then
			found, count = other, count + 1
		end
	end
	if count == 1 then
		return found
	end
	return nil, count == 0 and "target" or "many"
end

-- The receiver and the text of "/pm <name> <text>": a "quoted name", the longest run of
-- words that is exactly somebody's name, or the first word as a part of one.
function M:_Target(ply, rest)
	local quoted, after = rest:match("^\"([^\"]*)\"%s*(.*)$")
	if quoted ~= nil then
		local target, problem = self:Find(quoted, ply)
		return target, problem, after
	end
	local starts, stops = {}, {}
	for start, stop in rest:gmatch("()%S+()") do
		starts[#starts + 1], stops[#stops + 1] = start, stop
	end
	if starts[1] == nil then
		return nil, "empty"
	end
	local players = self.players
	for count = #starts, 1, -1 do
		local wanted = M.Fold(rest:sub(1, stops[count] - 1))
		for _, other in ipairs(players:ReadyPlayers()) do
			if M.Fold(players:Name(other)) == wanted then
				return other, nil, M.Clean(rest:sub(stops[count]))
			end
		end
	end
	local target, problem = self:Find(rest:sub(1, stops[1] - 1), ply)
	return target, problem, M.Clean(rest:sub(stops[1]))
end

function M:Private(ply, target, text)
	text = M.Cut(M.Clean(text), M.MAX_TEXT)
	if text == "" then
		return self:_Fail(ply, "empty", { command = "/pm" })
	end
	if target == ply then
		return self:_Fail(ply, "self")
	end
	local events = self.ctx.events
	if events:Query("chat.canSpeak", ply, "pm", text) == false
		or events:Query("gm.PlayerCanSeePlayersChat", text, false, target, ply) == false then
		return self:_Fail(ply, "denied")
	end
	local players = self.players
	self:_Deliver({ target }, { channel = "pm", speaker = ply, name = players:Name(ply), text = text, dead = false })
	self:_Deliver({ ply }, { channel = "pmto", speaker = ply, name = players:Name(target), text = text, dead = false })
	self.partners[ply], self.partners[target] = target, ply
	self:_Log(ply, "pm", text, target)
	events:Emit("chat.said", ply, "pm", text, { ply, target })
	return true
end

-- Commands --------------------------------------------------------------------------------------

function M:Info(ply, lines)
	if type(lines) ~= "table" then
		lines = { lines }
	end
	local shown = {}
	for i, line in ipairs(lines) do
		line = tostring(line)
		ply:PrintMessage(HUD_PRINTCONSOLE, line)
		if i <= MAX_REPLY then
			shown[#shown + 1] = line
		end
	end
	for _, line in ipairs(shown) do
		self:_Deliver({ ply }, { channel = "info", speaker = ply, name = "", text = M.Cut(line, M.MAX_TEXT),
			dead = false })
	end
	if #lines > MAX_REPLY and self.notices ~= nil then
		self.notices:Send(ply, "chat.more", { count = #lines - MAX_REPLY }, "info")
	end
end

function M:_Command(ply, word, rest)
	local args = M.Words(rest)
	local answer = self.ctx.events:Query("chat.command", ply, word, args, rest)
	if answer == false then
		return self:_Fail(ply, "denied")
	end
	if answer ~= nil then
		if answer ~= true then
			self:Info(ply, answer)
		end
		return true
	end
	local found, lines = self.ctx.commands:Execute("nc_" .. word, ply, args)
	if not found then
		return self:_Fail(ply, "unknown", { command = "/" .. word })
	end
	self:Info(ply, lines)
	return true
end

-- Lists the channels for the console: nc_chat (everybody).
function M:ChatCommand(caller)
	local cfg = self.ctx.config
	local proximity = IsValid(caller) and self:Proximity(caller) or cfg.proximity
	return {
		format("chat: %s; whisper %d, say %s, yell %s, looc %d units", proximity and "local" or "global",
			cfg.whisperRange, proximity and tostring(cfg.sayRange) or "everywhere",
			proximity and tostring(cfg.yellRange) or "everywhere", cfg.loocRange),
		concat({ "/w", "/y", "/me", "/it", "//", ".//", "/pm", "/r", "/<command>" }, " "),
	}
end
