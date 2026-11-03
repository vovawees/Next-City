-- Next-City: shared entry point, runs on the server and on clients.
GM.Name = "Next-City"
GM.Author = "Vovawe"
GM.Website = "https://github.com/vovawees/Next-City"
GM.TeamBased = false

-- The only global of the project.
NC = NC or {}
NC.VERSION = "0.1.0"
NC.ROOT = GM.FolderName .. "/gamemode/"

-- Includes a gamemode file (path relative to gamemode/) on this realm and, on the
-- server, sends it to clients. Returns whatever the file returns.
function NC.IncludeShared(path)
	if SERVER then
		AddCSLuaFile(NC.ROOT .. path)
	end
	return include(NC.ROOT .. path)
end

NC.IncludeShared("platform/boot.lua")
