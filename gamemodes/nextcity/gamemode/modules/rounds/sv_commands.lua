-- Rounds module, server part: console commands.
--
--   nc_round                              the round, the next mode and the parameters
--   nc_round restart [mode]               a new round now, with any number of players
--   nc_round end                          ends the round as a draw
--   nc_round next <mode>                  the mode of the next round
--   nc_round param <mode> <name> [value]  overrides a parameter from the next round on;
--                                         without a value the override is dropped
--   nc_modes                              registered modes, their rules and parameters

local M = NC.Module("rounds")

local format = string.format
local concat = table.concat

local USAGE = {
	"usage: nc_round [restart [mode] | end | next <mode> | param <mode> <name> [value]]",
}

function M:_AddCommands(ctx)
	ctx.commands:Add("nc_round", { help = "round status; restart, end, next <mode>, param <mode> <name> [value]" },
		"RoundCommand")
	ctx.commands:Add("nc_modes", { help = "registered modes, their rules and parameters", admin = false },
		"ModesCommand")
end

local function showValue(value)
	if type(value) == "table" then
		local parts = {}
		for i, item in ipairs(value) do
			parts[i] = tostring(item)
		end
		return "{" .. concat(parts, ", ") .. "}"
	end
	if type(value) == "string" then
		return "'" .. value .. "'"
	end
	return tostring(value)
end

local function paramLine(values)
	local names = {}
	for name in pairs(values) do
		names[#names + 1] = name
	end
	table.sort(names)
	local parts = {}
	for i, name in ipairs(names) do
		parts[i] = name .. " = " .. showValue(values[name])
	end
	return concat(parts, ", ")
end

function M:StatusLines()
	local lines = {}
	local round = self.round
	local phase = self:Phase()
	if round == nil then
		lines[1] = format("Phase %s, %d ready players", phase, self:_ReadyCount())
	else
		local left = round:TimeLeft()
		lines[1] = format("Round %d (%s): %s%s", round.number, round.mode, phase,
			left and ", " .. self.FormatTime(left) .. " left" or "")
		lines[2] = format("Participants %d: alive %d, respawning %d", round:ParticipantCount(), round:AliveCount(),
			round:RespawnCount())
		lines[3] = "Params: " .. paramLine(round.params)
		if round.result ~= nil then
			lines[4] = "Result: " .. paramLine(round.result)
		end
	end
	local entry = self:_PeekMode()
	if entry == nil then
		lines[#lines + 1] = "Next: no mode to play"
	else
		lines[#lines + 1] = format("Next: %s (needs %d players)%s", entry.id, entry.minPlayers,
			self.nextModeId and ", chosen by an admin" or "")
	end
	return lines
end

function M:RoundCommand(_, args)
	local action = args[1]
	if action == nil or action == "status" then
		return self:StatusLines()
	end
	if action == "restart" then
		local ok, err = self:Restart(args[2])
		return ok and "nc_round: a new round starts" or "nc_round: " .. tostring(err)
	end
	if action == "end" then
		if self:EndRound(self.round, { reason = "admin" }) then
			return "nc_round: the round ended"
		end
		return "nc_round: no round is running"
	end
	if action == "next" then
		local ok, err = self:SetNextMode(args[2])
		return ok and format("nc_round: the next round plays '%s'", args[2]) or "nc_round: " .. err
	end
	if action == "param" then
		return self:_ParamCommand(args[2], args[3], args[4])
	end
	return { format("nc_round: unknown action '%s'", tostring(action)), USAGE[1] }
end

function M:_ParamCommand(mode, name, text)
	local set = self:ParamSet(mode)
	if set == nil then
		return format("nc_round: unknown mode '%s'", tostring(mode))
	end
	if name == nil or not set:Has(name) then
		return format("nc_round: mode '%s' has params: %s", mode, concat(set:Names(), ", "))
	end
	if text == nil then
		self:ResetParam(mode, name)
		return format("nc_round: %s.%s is back to %s from the next round", mode, name,
			showValue(self:ResolveParams(mode)[name]))
	end
	local value, err = set:Parse(name, text)
	if value == nil then
		return "nc_round: " .. err
	end
	local fixed, problem = self:SetParam(mode, name, value)
	return format("nc_round: %s.%s = %s from the next round%s", mode, name, showValue(fixed),
		problem and " (" .. problem .. ")" or "")
end

function M:ModesCommand()
	local lines = {}
	for _, id in ipairs(self:Modes()) do
		local entry = self.modes[id]
		local available, reason = self:IsAvailable(id)
		lines[#lines + 1] = format("%s  %s  min %d players  rules: %s%s", id, entry.name, entry.minPlayers,
			entry.rules[1] and concat(entry.rules, ", ") or "-", available and "" or "  [unavailable: " .. reason .. "]")
		local set = self:ParamSet(id)
		local values = self:ResolveParams(id)
		for _, name in ipairs(set:Names()) do
			local def = set:Get(name)
			lines[#lines + 1] = format("    %-16s %s%s", name, set:Describe(name, values[name]),
				def.desc and "  -- " .. def.desc or "")
		end
	end
	if lines[1] == nil then
		lines[1] = "No modes registered"
	end
	return lines
end
