-- Next-City platform: developer console commands.
--
--   nc_modules       module order, states, failure reasons and packages but the core
--   nc_perf          scheduler profile: time per job and timer tag
--   nc_perf_reset    reset the profile
--   nc_lang [code]   languages and translation completeness; with a code: what is missing
--   nc_net           network messages: sent and received (count, bytes), drops by reason
--   nc_net_reset     reset the network statistics
--   nc_components    component stores: audience, rate, entries, traffic
--   nc_privileges [player]  privileges and their levels; with a player: what it has
-- Server commands are privileges of the platform (level superadmin, platform/permissions.lua);
-- the same commands with the _cl suffix inspect the client realm.

local format = string.format

local MAX_REASON = 160

local function shortReason(reason)
	local line = tostring(reason):match("^[^\n]*")
	if #line > MAX_REASON then
		line = line:sub(1, MAX_REASON - 3) .. "..."
	end
	return line
end

local function moduleLines()
	local rows = NC.Modules:Report()
	local packages = NC.ModulePackages or {}
	local lines = { format("Next-City %s: %d modules (%s)", NC.VERSION, #rows, SERVER and "server" or "client") }
	for _, row in ipairs(rows) do
		local line = format("  %3s  %-24s %-11s", row.index and tostring(row.index) or "-", row.id, row.state)
		local package = packages[row.id]
		if package ~= nil and package ~= "core" then
			line = line .. " [" .. package .. "]"
		end
		if row.provides ~= row.id then
			line = line .. " provides " .. row.provides
		end
		if row.reason then
			line = line .. "  " .. shortReason(row.reason)
		end
		lines[#lines + 1] = line:match("^(.-)%s*$")
	end
	for _, message in ipairs(NC.Modules:Errors()) do
		lines[#lines + 1] = "  error: " .. shortReason(message)
	end
	return lines
end

local function perfLines()
	local lines = {
		format("Scheduler profile (%s), ms:", SERVER and "server" or "client"),
		format("  %-36s %10s %9s %9s %8s %6s", "id", "total", "avg", "max", "calls", "errors"),
	}
	for _, row in ipairs(NC.Scheduler:Stats()) do
		lines[#lines + 1] = format("  %-36s %10.3f %9.4f %9.4f %8d %6d%s", row.id, row.total * 1000,
			row.avg * 1000, row.max * 1000, row.calls, row.errors, row.disabled and "  DISABLED" or "")
	end
	lines[#lines + 1] = format("  pending timers: %d", NC.Scheduler:Pending())
	return lines
end

local function perfReset()
	NC.Scheduler:ResetStats()
	return { "Scheduler profile reset" }
end

local function bytesText(n)
	if n >= 1048576 then
		return format("%.1f MiB", n / 1048576)
	end
	if n >= 1024 then
		return format("%.1f KiB", n / 1024)
	end
	return format("%d B", n)
end

local function netLines()
	local service = NC.Net
	local stats = service:Stats()
	local state
	if SERVER then
		state = format("ready players: %d", #service:ReadyPlayers())
	else
		state = service:IsReady() and "ready" or "not ready"
	end
	local lines = {
		format("Network (%s): %d messages, %s", SERVER and "server" or "client", #stats, state),
		format("  %-32s %-6s %7s %10s %7s %10s  %s", "message", "from", "sent", "out", "recv", "in", "dropped, errors"),
	}
	for _, row in ipairs(stats) do
		local notes = {}
		for reason, count in pairs(row.dropped) do
			notes[#notes + 1] = reason .. "=" .. count
		end
		table.sort(notes)
		if row.errors > 0 then
			notes[#notes + 1] = "errors=" .. row.errors
		end
		local line = format("  %-32s %-6s %7d %10s %7d %10s  %s", row.name, row.from, row.sent, bytesText(row.bytesOut),
			row.received, bytesText(row.bytesIn), table.concat(notes, " "))
		lines[#lines + 1] = line:match("^(.-)%s*$")
	end
	return lines
end

local function netReset()
	NC.Net:ResetStats()
	return { "Network statistics reset" }
end

local function componentLines()
	local rows = NC.Components:Report()
	local entries = 0
	for _, row in ipairs(rows) do
		entries = entries + row.count
	end
	local lines = {
		format("Components (%s): %d, %d entries", SERVER and "server" or "client", #rows, entries),
		format("  %-32s %-9s %5s %7s %6s %7s %10s", "component", "replicate", "rate", "entries", "fields",
			SERVER and "sent" or "recv", SERVER and "out" or "in"),
	}
	for _, row in ipairs(rows) do
		local count, bytes = row.sent, row.bytesOut
		if CLIENT then
			count, bytes = row.received, row.bytesIn
		end
		local line = format("  %-32s %-9s %5s %7d %6d %7d %10s%s", row.id, row.replicate or "local",
			row.rate and tostring(row.rate) or "-", row.count, row.fields, count, bytesText(bytes),
			row.alive and "" or "  STOPPED")
		lines[#lines + 1] = line
	end
	return lines
end

local MAX_PROBLEMS = 100

local function langSummary(i18n, problems)
	local missing, other = {}, {}
	for _, problem in ipairs(problems) do
		local counts = problem.kind == "missing" and missing or other
		counts[problem.code] = (counts[problem.code] or 0) + 1
	end
	local reference = #i18n:Catalog():Keys(i18n.default)
	local lines = {
		format("Languages (%s): default %s, in use %s, %d reference keys", SERVER and "server" or "client",
			i18n.default, i18n:Language(), reference),
		format("  %-8s %6s %10s %9s  %s", "code", "keys", "complete", "problems", "name"),
	}
	for _, lang in ipairs(i18n:Languages()) do
		local complete = "not loaded"
		if lang.loaded then
			local done = reference - (missing[lang.code] or 0)
			complete = reference > 0 and format("%d%%", math.floor(done / reference * 100)) or "-"
		end
		local name = lang.english ~= lang.name and format("%s (%s)", lang.name, lang.english) or lang.name
		lines[#lines + 1] = format("  %-8s %6d %10s %9d  %s", lang.code, lang.keys, complete, other[lang.code] or 0,
			name)
	end
	return lines
end

local function findLanguage(i18n, code)
	for _, lang in ipairs(i18n:Languages()) do
		if lang.code == code then
			return lang
		end
	end
	return nil
end

local function langLines(args)
	local i18n = NC.I18n
	local problems = i18n:Check()
	local code = args and args[1]
	if code == nil or code == "" then
		return langSummary(i18n, problems)
	end
	code = NC.Lib.I18n.Normalize(code) or code
	local lang = findLanguage(i18n, code)
	if lang == nil then
		return { format("Unknown language '%s' (no lang/%s folder)", code, code) }
	end
	if not lang.loaded then
		return { format("Language '%s' is not loaded on the %s", code, SERVER and "server" or "client") }
	end
	local lines = { format("Translation problems of '%s' against '%s':", code, i18n.default) }
	local shown, total = 0, 0
	for _, problem in ipairs(problems) do
		if problem.code == code then
			total = total + 1
			if shown < MAX_PROBLEMS then
				shown = shown + 1
				lines[#lines + 1] = format("  %-11s %s: %s", problem.kind, problem.key, problem.message)
			end
		end
	end
	if total == 0 then
		lines[#lines + 1] = "  none"
	elseif total > shown then
		lines[#lines + 1] = format("  ... and %d more", total - shown)
	end
	return lines
end

-- A player by the text of an argument: "^" is the caller, "#n" or n the entity index,
-- else the only player whose name contains the text (any case).
local function findPlayer(text, caller)
	if text == "^" then
		return caller, caller == nil and "the console is not a player" or nil
	end
	local index = tonumber(text:match("^#?(%d+)$") or "")
	if index ~= nil then
		local ply = Entity(index)
		if IsValid(ply) and ply:IsPlayer() then
			return ply
		end
		return nil, "no player #" .. index
	end
	local lower, found, count = text:lower(), nil, 0
	for _, ply in ipairs(player.GetAll()) do
		if ply:Nick() == text then
			return ply
		end
		if ply:Nick():lower():find(lower, 1, true) ~= nil then
			found, count = ply, count + 1
		end
	end
	if count == 1 then
		return found
	end
	return nil, count == 0 and "no player matches '" .. text .. "'" or count .. " players match '" .. text .. "'"
end

local function privilegeLines(args, caller)
	local permissions = NC.Permissions
	local ply
	if CLIENT then
		ply = LocalPlayer()
	elseif args and args[1] ~= nil and args[1] ~= "" then
		local problem
		ply, problem = findPlayer(args[1], caller)
		if ply == nil then
			return { problem }
		end
	end
	local list = permissions:List()
	if CLIENT then
		-- Server-only privileges (admin commands) are known by their ids only.
		local known = {}
		for _, privilege in ipairs(list) do
			known[privilege.id] = true
		end
		for _, id in ipairs(permissions:Granted()) do
			if not known[id] then
				list[#list + 1] = { id = id, level = "-", declared = "-", module = "-" }
			end
		end
		table.sort(list, function(a, b)
			return a.id < b.id
		end)
	end
	local lines
	if ply == nil then
		lines = { format("Privileges (%s): %d", SERVER and "server" or "client", #list) }
	else
		local granted = permissions:Granted(ply)
		local rank = SERVER and format(", rank %s, group %s", permissions:Rank(ply), ply:GetUserGroup()) or ""
		lines = { format("Privileges of %s (%s%s): %d of %d", ply:Nick(), SERVER and "server" or "client", rank,
			#granted, #list) }
		if CLIENT and not permissions:IsKnown() then
			lines[#lines + 1] = "  the server has not sent them yet"
		end
	end
	lines[#lines + 1] = format("  %s%-32s %-11s %-16s %s", ply ~= nil and "  " or "", "privilege", "level", "module",
		"description")
	local changed = false
	for _, privilege in ipairs(list) do
		local level = privilege.level
		if level ~= privilege.declared then
			level, changed = level .. "*", true
		end
		local mark = ""
		if ply ~= nil then
			mark = permissions:Can(ply, privilege.id) and "+ " or "- "
		end
		local line = format("  %s%-32s %-11s %-16s %s", mark, privilege.id, level, tostring(privilege.module),
			privilege.desc or "")
		lines[#lines + 1] = line:match("^(.-)%s*$")
	end
	if changed then
		lines[#lines + 1] = "  * the level is set in config permissions.levels"
	end
	return lines
end

local function reply(ply, lines)
	for _, line in ipairs(lines) do
		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTCONSOLE, line)
		else
			print(line)
		end
	end
end

local function register(name, desc, build)
	if SERVER then
		local permissions = NC.Permissions
		permissions:Register(name, { module = "platform", name = name, level = "superadmin", desc = desc,
			command = name })
		concommand.Add(name, function(ply, _, args)
			local caller = IsValid(ply) and ply or nil
			if not permissions:Can(caller, name) then
				reply(caller, { name .. ": no access" })
				return
			end
			reply(caller, build(args, caller))
		end)
	else
		concommand.Add(name .. "_cl", function(_, _, args)
			reply(nil, build(args))
		end)
	end
end

register("nc_modules", "module states, failures and packages", moduleLines)
register("nc_perf", "scheduler profile", perfLines)
register("nc_perf_reset", "reset the scheduler profile", perfReset)
register("nc_lang", "languages and translation problems", langLines)
register("nc_net", "network statistics", netLines)
register("nc_net_reset", "reset the network statistics", netReset)
register("nc_components", "component stores and their traffic", componentLines)
register("nc_privileges", "privileges and what a player has", privilegeLines)
