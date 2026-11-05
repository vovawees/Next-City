-- Module cami, server: the bridge between platform/permissions.lua and CAMI.
--
-- Listens:  permissions.can (answers by CAMI.PlayerHasAccess; nil without an admin mod or
--           for level "nobody"), permissions.registered / unregistered (offers and
--           withdraws CAMI privileges), gm.InitPostEntity (CAMI may come late).
-- Hooks:    CAMI.PlayerUsergroupChanged, CAMI.SteamIDUsergroupChanged -> Refresh of the
--           player on the next tick, so clients learn the new privileges at once.
-- Commands: nc_cami (state of the adapter).
--
-- A privilege goes to CAMI as { Name = prefix .. id, MinAccess = level, Description }:
-- admin mods grant it to their groups like their own commands. Privileges of level
-- "nobody" are kept away from CAMI (only the console and other sources may).

local M = NC.Module("cami")

local HOOK_ID = "nextcity.cami"
local ASK = { auto = true, always = true, never = true }
local CAMI_LEVELS = { user = true, admin = true, superadmin = true }
local ACCESS_HOOK = "CAMI.PlayerHasAccess"

local function asText(value)
	return tostring(value):match("^[^\n]*")
end

function M:Init(ctx)
	local cfg = ctx.config
	self.ask = cfg.ask
	if not ASK[self.ask] then
		ctx.log:Warn("setting ask must be \"auto\", \"always\" or \"never\", got %s: using auto", tostring(cfg.ask))
		self.ask = "auto"
	end
	self.prefix = cfg.prefix
	self.offer = cfg.register ~= false
	self.offered = {}   -- CAMI name -> privilege id
	self.problems = 0
	self.cami = nil
	self.asking = false
	ctx.commands:Add("nc_cami", { help = "state of the CAMI adapter" }, "Report")
end

function M:Start(ctx)
	ctx:On("permissions.can", "OnCan", { priority = ctx.config.priority })
	ctx:On("permissions.registered", "OnRegistered")
	ctx:On("permissions.unregistered", "OnUnregistered")
	ctx:On("gm.InitPostEntity", "Attach")
	self:Attach()
end

-- The CAMI global, once it is there (admin mods load it in autorun, before the gamemode).
function M:Attach()
	if self.cami ~= nil then
		return true
	end
	local cami = rawget(_G, "CAMI")
	if type(cami) ~= "table" or type(cami.PlayerHasAccess) ~= "function"
		or type(cami.RegisterPrivilege) ~= "function" then
		return false
	end
	self.cami = cami
	hook.Add("CAMI.PlayerUsergroupChanged", HOOK_ID, function(ply)
		self:_Later(ply)
	end)
	hook.Add("CAMI.SteamIDUsergroupChanged", HOOK_ID, function(steamId)
		local ply = player.GetBySteamID(steamId) or player.GetBySteamID64(steamId)
		if ply then
			self:_Later(ply)
		end
	end)
	for _, privilege in ipairs(self.ctx.permissions:List()) do
		self:_Offer(privilege)
	end
	self.ctx.log:Info("CAMI %s: admin mods decide the privileges (%d offered as %s<id>)", tostring(cami.Version),
		self:OfferedCount(), self.prefix)
	return true
end

-- Whether CAMI answers now: an admin mod listens to its questions ("auto"), or the setting.
function M:Asks()
	if self.cami == nil or self.ask == "never" then
		return false
	end
	if self.ask == "always" then
		return true
	end
	local hooks = hook.GetTable()[ACCESS_HOOK]
	return hooks ~= nil and next(hooks) ~= nil
end

-- The CAMI name of a privilege id.
function M:NameOf(id)
	return self.prefix .. id
end

function M:OfferedCount()
	local count = 0
	for _ in pairs(self.offered) do
		count = count + 1
	end
	return count
end

function M:_Problem(what, err)
	self.problems = self.problems + 1
	if self.problems <= 5 then
		self.ctx.log:Warn("CAMI %s failed: %s", what, asText(err))
	end
end

function M:_Offer(privilege)
	if not self.offer or not CAMI_LEVELS[privilege.level] then
		return
	end
	local name = self:NameOf(privilege.id)
	if self.offered[name] ~= nil then
		return
	end
	local ok, err = pcall(self.cami.RegisterPrivilege, {
		Name = name,
		MinAccess = privilege.level,
		Description = privilege.desc or privilege.id,
	})
	if ok then
		self.offered[name] = privilege.id
	else
		self:_Problem("RegisterPrivilege('" .. name .. "')", err)
	end
end

function M:_Withdraw(name)
	if self.offered[name] == nil then
		return
	end
	self.offered[name] = nil
	if type(self.cami.UnregisterPrivilege) == "function" then
		local ok, err = pcall(self.cami.UnregisterPrivilege, name)
		if not ok then
			self:_Problem("UnregisterPrivilege('" .. name .. "')", err)
		end
	end
end

function M:OnRegistered(privilege)
	if self.cami ~= nil then
		self:_Offer(privilege)
	end
end

function M:OnUnregistered(privilege)
	if self.cami ~= nil then
		self:_Withdraw(self:NameOf(privilege.id))
	end
end

-- permissions.can: the answer of the admin mod, or nil (the next source or the levels).
function M:OnCan(ply, id, target, privilege)
	if not CAMI_LEVELS[privilege.level] or not self:Asks() then
		return nil
	end
	-- An admin mod that asks Next-City back while it answers gets the levels.
	if self.asking then
		return nil
	end
	if not (isentity(target) and IsValid(target) and target:IsPlayer()) then
		target = nil
	end
	self.asking = true
	local ok, has = pcall(self.cami.PlayerHasAccess, ply, self:NameOf(id), nil, target,
		{ Fallback = privilege.level })
	self.asking = false
	if not ok then
		self:_Problem("PlayerHasAccess('" .. self:NameOf(id) .. "')", has)
		return nil
	end
	if has == nil then
		return nil
	end
	return has ~= false
end

-- An admin mod moved a player to another group: the client learns its privileges on the
-- next tick (the group may be set after the signal).
function M:_Later(ply)
	self.ctx:After(0, function()
		if IsValid(ply) then
			self.ctx.permissions:Refresh(ply)
		end
	end)
end

function M:Report()
	local cami = self.cami
	if cami == nil then
		return { "CAMI: not found, the levels of the privileges apply (nc_privileges)" }
	end
	local hooks = {}
	for id in pairs(hook.GetTable()[ACCESS_HOOK] or {}) do
		hooks[#hooks + 1] = tostring(id)
	end
	table.sort(hooks)
	return {
		string.format("CAMI %s: ask %s -> %s; hooks of %s: %s", tostring(cami.Version), self.ask,
			self:Asks() and "admin mods decide" or "the levels decide", ACCESS_HOOK,
			#hooks > 0 and table.concat(hooks, ", ") or "none"),
		string.format("  privileges offered: %d as %s<id>%s, problems: %d", self:OfferedCount(), self.prefix,
			self.offer and "" or " (register = false)", self.problems),
	}
end

function M:Stop()
	if self.cami == nil then
		return
	end
	hook.Remove("CAMI.PlayerUsergroupChanged", HOOK_ID)
	hook.Remove("CAMI.SteamIDUsergroupChanged", HOOK_ID)
	local names = {}
	for name in pairs(self.offered) do
		names[#names + 1] = name
	end
	table.sort(names)
	for _, name in ipairs(names) do
		self:_Withdraw(name)
	end
	self.cami = nil
end
