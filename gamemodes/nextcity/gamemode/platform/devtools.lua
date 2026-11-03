-- Next-City platform: developer console commands.
--
--   nc_modules       module order, states and failure reasons
--   nc_perf          scheduler profile: time per job and timer tag
--   nc_perf_reset    reset the profile
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
		concommand.Add(name, function(ply)
			if IsValid(ply) and not ply:IsSuperAdmin() then
				reply(ply, { name .. ": superadmin only" })
				return
			end
			reply(ply, build())
		end)
	else
		concommand.Add(name .. "_cl", function()
			reply(nil, build())
		end)
	end
end

register("nc_modules", moduleLines)
register("nc_perf", perfLines)
register("nc_perf_reset", perfReset)
