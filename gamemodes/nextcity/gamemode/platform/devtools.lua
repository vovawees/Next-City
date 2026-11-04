-- Next-City platform: developer console commands.
--
--   nc_modules       module order, states and failure reasons
--   nc_perf          scheduler profile: time per job and timer tag
--   nc_perf_reset    reset the profile
--   nc_lang [code]   languages and translation completeness; with a code: what is missing
-- Server commands are available to the server console and superadmins; the same
-- commands with the _cl suffix inspect the client realm.

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
	local lines = { format("Next-City %s: %d modules (%s)", NC.VERSION, #rows, SERVER and "server" or "client") }
	for _, row in ipairs(rows) do
		local line = format("  %3s  %-24s %-11s", row.index and tostring(row.index) or "-", row.id, row.state)
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

local function reply(ply, lines)
	for _, line in ipairs(lines) do
		if IsValid(ply) then
			ply:PrintMessage(HUD_PRINTCONSOLE, line)
		else
			print(line)
		end
	end
end

local function register(name, build)
	if SERVER then
		concommand.Add(name, function(ply, _, args)
			if IsValid(ply) and not ply:IsSuperAdmin() then
				reply(ply, { name .. ": superadmin only" })
				return
			end
			reply(ply, build(args))
		end)
	else
		concommand.Add(name .. "_cl", function(_, _, args)
			reply(nil, build(args))
		end)
	end
end

register("nc_modules", moduleLines)
register("nc_perf", perfLines)
register("nc_perf_reset", perfReset)
register("nc_lang", langLines)
