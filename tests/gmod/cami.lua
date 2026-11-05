-- A CAMI fake for specs: the parts of the Common Admin Mod Interface that admin mods and
-- addons use (privileges, PlayerHasAccess with its default handler, usergroup signals),
-- written after its documented behaviour and installed as the CAMI global of a realm
-- before it boots. Cami.AdminMod adds an admin mod in the style of ULX: groups with
-- inheritance and allow lists, a new privilege goes to the group of its MinAccess.

local Cami = {}

local ACCESS = "CAMI.PlayerHasAccess"

-- Installs CAMI into a realm (before Boot). Returns the CAMI table; .privileges holds what
-- was registered.
function Cami.Install(env)
	local G = env.G
	local privileges = {}
	local cami = { Version = 20211019, privileges = privileges }

	-- CAMI's own answer when no admin mod answers: MinAccess against IsAdmin/IsSuperAdmin.
	local default = {}
	default[ACCESS] = function(_, actor, name, callback, _, extra)
		if not G.IsValid(actor) then
			return callback(true, "Fallback.")
		end
		local function allows(level)
			return level == "user" or level == "admin" and actor:IsAdmin()
				or level == "superadmin" and actor:IsSuperAdmin()
		end
		local privilege = privileges[name]
		if privilege == nil then
			local fallback = extra and extra.Fallback
			return callback(fallback == nil and actor:IsAdmin() or allows(fallback), "Fallback.")
		end
		return callback(allows(privilege.MinAccess), "Fallback.")
	end

	function cami.RegisterPrivilege(privilege)
		privileges[privilege.Name] = privilege
		G.hook.Call("CAMI.OnPrivilegeRegistered", nil, privilege)
		return privilege
	end

	function cami.UnregisterPrivilege(name)
		local privilege = privileges[name]
		if privilege == nil then
			return false
		end
		privileges[name] = nil
		G.hook.Call("CAMI.OnPrivilegeUnregistered", nil, privilege)
		return true
	end

	function cami.GetPrivilege(name)
		return privileges[name]
	end

	function cami.GetPrivileges()
		return privileges
	end

	-- Without a callback the answer must come at once, else CAMI raises an error.
	function cami.PlayerHasAccess(actor, name, callback, target, extra)
		local has, reason
		local answer = callback or function(value, why)
			has, reason = value, why
		end
		G.hook.Call(ACCESS, default, actor, name, answer, target, extra)
		if callback ~= nil then
			return
		end
		if has == nil then
			error("CAMI.PlayerHasAccess: an admin mod did not give an immediate answer for " .. name)
		end
		return has, reason
	end

	function cami.SignalUserGroupChanged(ply, old, new, source)
		G.hook.Call("CAMI.PlayerUsergroupChanged", nil, ply, old, new, source)
	end

	function cami.SignalSteamIDUserGroupChanged(steamId, old, new, source)
		G.hook.Call("CAMI.SteamIDUsergroupChanged", nil, steamId, old, new, source)
	end

	rawset(G, "CAMI", cami)
	return cami
end

-- An admin mod over an installed CAMI: mod:Group(name, inherits), mod:Allow(group,
-- privilege, true | false | nil), mod:SetGroup(ply, group) (signals the change like
-- `ulx adduser`); mod.asked counts the questions it answered, mod.last is the last one
-- { actor, name, target, extra }. Like ULX it keeps what it knows: a privilege goes to
-- the group of its MinAccess only the first time it is registered.
function Cami.AdminMod(env, cami)
	local G = env.G
	local mod = {
		asked = 0,
		known = {},
		groups = {
			user = { allow = {} },
			admin = { inherits = "user", allow = {} },
			superadmin = { inherits = "admin", allow = {} },
		},
	}

	function mod:Group(name, inherits)
		self.groups[name] = { inherits = inherits, allow = {} }
	end

	function mod:Allow(group, privilege, value)
		self.groups[group].allow[privilege] = value
	end

	function mod:SetGroup(ply, group)
		local old = ply:GetUserGroup()
		ply:SetUserGroup(group)
		cami.SignalUserGroupChanged(ply, old, group, "fakemod")
	end

	G.hook.Add("CAMI.OnPrivilegeRegistered", "fakemod", function(privilege)
		if mod.known[privilege.Name] then
			return
		end
		mod.known[privilege.Name] = true
		local group = mod.groups[privilege.MinAccess]
		if group ~= nil then
			group.allow[privilege.Name] = true
		end
	end)

	G.hook.Add(ACCESS, "fakemod", function(actor, name, callback, target, extra)
		mod.asked = mod.asked + 1
		mod.last = { actor, name, target, extra }
		local group = mod.groups[actor:GetUserGroup()] or mod.groups.user
		while group ~= nil do
			local allowed = group.allow[name]
			if allowed ~= nil then
				callback(allowed, "fakemod")
				return true
			end
			group = mod.groups[group.inherits]
		end
		callback(false, "fakemod")
		return true
	end)
	return mod
end

return Cami
