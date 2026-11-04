-- Spectator module, server part: the cameras of players that are not alive.
--
-- A dead player sees the engine's death view for deathCam seconds, then observes; a
-- spectator observes at once. An observer follows a living player (first person or
-- chase camera) or flies free: attack and alt-attack follow the next and the previous
-- player, jump switches the camera (first person -> chase -> free -> first person).
-- With teamOnly a player of a team follows only living teammates while there are any.
--
-- Cameras are checked on the tick after a change (deaths, spawns, departures, team
-- changes) and twice a second, so an observer never keeps a dead or forbidden target,
-- whatever changed it (the engine included).
--
-- Listens: players.stateChanged, players.left, teams.changed, gm.KeyPress.
-- Asks:    spectator.canObserve (viewer, target) -> false forbids following the target.
-- Emits:   spectator.target (viewer, target, old); target nil is the free camera.

local M = NC.Module("spectator")

local CurTime = CurTime
local IsValid = IsValid
local ipairs = ipairs
local pairs = pairs

local CAMERAS = { in_eye = OBS_MODE_IN_EYE, chase = OBS_MODE_CHASE, roaming = OBS_MODE_ROAMING }
local NAMES = { [OBS_MODE_IN_EYE] = "in_eye", [OBS_MODE_CHASE] = "chase", [OBS_MODE_ROAMING] = "roaming" }
local NEXT_CAMERA = {
	[OBS_MODE_IN_EYE] = OBS_MODE_CHASE,
	[OBS_MODE_CHASE] = OBS_MODE_ROAMING,
	[OBS_MODE_ROAMING] = OBS_MODE_IN_EYE,
}
local KEY_DELAY = 0.15 -- the shortest time between two camera changes by keys, s
local OBSERVED = { "spectator", "dead" }

local function byIndex(a, b)
	return a:EntIndex() < b:EntIndex()
end

function M:Init(ctx)
	self.players = ctx:Require("players")
	self.teams = ctx:Require("teams")
	-- ply -> { camera, follow, target, index, observing, nextKey }; kept until the player
	-- leaves, so the chosen camera survives respawns.
	self.views = {}
	self.dying = {} -- ply -> the timer that ends the death camera
	self.pending = false
	local cfg = ctx.config
	local deathCam = cfg.deathCam
	if deathCam ~= deathCam or deathCam < 0 or deathCam > 60 then
		ctx.log:Warn("setting 'deathCam' = %s is outside 0..60; using 3", tostring(deathCam))
		deathCam = 3
	end
	self.deathCam = deathCam
	self.camera = CAMERAS[cfg.camera]
	if self.camera == nil then
		ctx.log:Warn("setting 'camera' = %s is not in_eye, chase or roaming; using in_eye", tostring(cfg.camera))
		self.camera = OBS_MODE_IN_EYE
	end
end

function M:Start(ctx)
	ctx:On("players.stateChanged", "OnStateChanged")
	ctx:On("players.left", "OnLeft")
	ctx:On("teams.changed", "Invalidate")
	ctx:On("gm.KeyPress", "OnKeyPress")
	ctx:Every("check", 0.5, "Check")
	for _, state in ipairs(OBSERVED) do
		for _, ply in ipairs(self.players:List(state)) do
			self:Observe(ply)
		end
	end
end

-- API ------------------------------------------------------------------------------------

-- Makes a dead or spectating player an observer now (a death camera ends early).
-- Returns false for other players.
function M:Observe(ply)
	local state = self.players:State(ply)
	if state ~= "dead" and state ~= "spectator" then
		return false
	end
	self:_EndDeathCam(ply)
	local view = self.views[ply]
	if view == nil then
		local camera = self.camera
		view = { camera = camera, follow = camera ~= OBS_MODE_ROAMING and camera or OBS_MODE_IN_EYE, target = nil,
			index = 0, observing = false, nextKey = 0 }
		self.views[ply] = view
	end
	view.observing = true
	self:_Refresh(ply, view, self:_Counts())
	return true
end

function M:IsObserving(ply)
	local view = self.views[ply]
	return view ~= nil and view.observing
end

-- The player an observer follows, or nil (free camera, death camera, not observing).
function M:Target(ply)
	local view = self.views[ply]
	return view and view.observing and view.target or nil
end

-- The camera an observer chose: "in_eye", "chase" or "roaming"; nil if not observing.
-- A follow camera shows the free camera while there is nobody to follow.
function M:Camera(ply)
	local view = self.views[ply]
	return view and view.observing and NAMES[view.camera] or nil
end

-- Observers following `target`, a new table sorted by entity index.
function M:Viewers(target)
	local list = {}
	for ply, view in pairs(self.views) do
		if view.observing and view.target == target then
			list[#list + 1] = ply
		end
	end
	table.sort(list, byIndex)
	return list
end

-- True if `viewer` may follow `target`: a living player other than the viewer, a teammate
-- while the viewer's team has living members (teamOnly), and no spectator.canObserve
-- listener says false. Counts the living players: not for loops over every player.
function M:CanObserve(viewer, target)
	return self:_Allowed(viewer, target, self:_TeamOf(viewer, self:_Counts()))
end

-- Switches the camera of an observer: "in_eye", "chase" or "roaming". Returns false for
-- an unknown camera or a player that is not observing.
function M:SetCamera(ply, camera)
	local mode = CAMERAS[camera]
	local view = self.views[ply]
	if mode == nil or view == nil or not view.observing then
		return false
	end
	view.camera = mode
	if mode ~= OBS_MODE_ROAMING then
		view.follow = mode
	end
	self:_Refresh(ply, view, self:_Counts())
	return true
end

-- Follows `target` if the observer may; the free camera switches to the last follow
-- camera. Returns true on success.
function M:Follow(ply, target)
	local view = self.views[ply]
	if view == nil or not view.observing or not self:CanObserve(ply, target) then
		return false
	end
	if view.camera == OBS_MODE_ROAMING then
		view.camera = view.follow
	end
	self:_Show(ply, view, target)
	return true
end

-- Follows the next (step 1) or the previous (step -1) allowed player in entity index
-- order; the free camera goes back to the last followed player if it still may. Returns
-- the target, or nil when there is nobody to follow.
function M:Next(ply, step)
	local view = self.views[ply]
	if view == nil or not view.observing then
		return nil
	end
	local roaming = view.camera == OBS_MODE_ROAMING
	local target = self:_Step(ply, view.index, step, self:_TeamOf(ply, self:_Counts()), roaming)
	if target == nil then
		return nil
	end
	if roaming then
		view.camera = view.follow
	end
	self:_Show(ply, view, target)
	return target
end

-- Checks every observer: a follow camera keeps an allowed target or gets the next one.
-- Runs twice a second and on the tick after a change.
function M:Check()
	self.pending = false
	-- A listener of spectator.target may start observers: walk a copy, not the views.
	local list = {}
	for ply, view in pairs(self.views) do
		if view.observing and IsValid(ply) then
			list[#list + 1] = ply
		end
	end
	local counts = self:_Counts()
	for _, ply in ipairs(list) do
		local view = self.views[ply]
		if view ~= nil and view.observing then
			self:_Refresh(ply, view, counts)
		end
	end
end

-- Schedules Check for the next tick; the changes of one tick share it.
function M:Invalidate()
	if not self.pending then
		self.pending = true
		self.ctx:After(0, "Check")
	end
end

-- Targets ---------------------------------------------------------------------------------

-- Living players per team while observers are limited to teammates, else nil.
function M:_Counts()
	if self.teams == nil or not self.ctx.config.teamOnly then
		return nil
	end
	local counts = {}
	for _, ply in ipairs(self.players:List("alive")) do
		local index = ply:Team()
		counts[index] = (counts[index] or 0) + 1
	end
	return counts
end

-- The team an observer is limited to (theirs while a teammate lives), or nil.
function M:_TeamOf(viewer, counts)
	if counts == nil then
		return nil
	end
	local index = self.teams:Of(viewer)
	if index ~= nil and (counts[index] or 0) > 0 then
		return index
	end
	return nil
end

function M:_Allowed(viewer, target, team)
	if target == viewer or not IsValid(target) or not self.players:IsAlive(target) then
		return false
	end
	if team ~= nil and target:Team() ~= team then
		return false
	end
	return self.ctx.events:Query("spectator.canObserve", viewer, target) ~= false
end

-- The allowed player after (step 1) or before (step -1) entity index `index`, wrapping
-- around; with `inclusive` the player at `index` itself comes first.
function M:_Step(viewer, index, step, team, inclusive)
	local base = index * step
	local best, bestKey, first, firstKey
	for _, ply in ipairs(self.players:List("alive")) do
		if self:_Allowed(viewer, ply, team) then
			local key = ply:EntIndex() * step
			if (key > base or inclusive and key == base) and (bestKey == nil or key < bestKey) then
				best, bestKey = ply, key
			end
			if firstKey == nil or key < firstKey then
				first, firstKey = ply, key
			end
		end
	end
	return best or first
end

-- Cameras ---------------------------------------------------------------------------------

-- A follow camera keeps its target while allowed, else takes the next one (the last
-- followed player first, so a respawned target is picked up again).
function M:_Refresh(ply, view, counts)
	local target
	if view.camera ~= OBS_MODE_ROAMING then
		local team = self:_TeamOf(ply, counts)
		target = view.target
		if target == nil or not self:_Allowed(ply, target, team) then
			target = self:_Step(ply, view.index, 1, team, true)
		end
	end
	self:_Show(ply, view, target)
end

-- Puts the engine camera of an observer on `target` (nil: the free camera, which starts
-- at the eyes of the player followed before).
function M:_Show(ply, view, target)
	local old = view.target
	local camera = target ~= nil and view.camera or OBS_MODE_ROAMING
	if ply:GetObserverMode() ~= camera then
		ply:Spectate(camera)
		if camera == OBS_MODE_ROAMING and IsValid(old) then
			ply:SetPos(old:EyePos())
			ply:SetEyeAngles(old:EyeAngles())
		end
	end
	local entity = target or NULL
	if ply:GetObserverTarget() ~= entity then
		ply:SpectateEntity(entity)
	end
	view.target = target
	if target ~= nil then
		view.index = target:EntIndex()
	end
	if old ~= target then
		self.ctx.events:Emit("spectator.target", ply, target, old)
	end
end

-- Not observing any more (alive again); the engine camera is the business of Deploy.
function M:_Stop(ply)
	self:_EndDeathCam(ply)
	local view = self.views[ply]
	if view == nil or not view.observing then
		return
	end
	local old = view.target
	view.observing, view.target = false, nil
	if old ~= nil then
		self.ctx.events:Emit("spectator.target", ply, nil, old)
	end
end

function M:_StartDeathCam(ply)
	self:_EndDeathCam(ply)
	if self.deathCam <= 0 then
		self:Observe(ply)
		return
	end
	self.dying[ply] = self.ctx:After(self.deathCam, function()
		self.dying[ply] = nil
		if IsValid(ply) then
			self:Observe(ply)
		end
	end)
end

function M:_EndDeathCam(ply)
	local timer = self.dying[ply]
	if timer ~= nil then
		self.dying[ply] = nil
		timer:Cancel()
	end
end

-- Events ----------------------------------------------------------------------------------

function M:OnStateChanged(ply, state, old)
	if state == "dead" then
		self:_Stop(ply)
		self:_StartDeathCam(ply)
	elseif state == "spectator" then
		self:Observe(ply)
	else
		self:_Stop(ply)
	end
	if old == "alive" or state == "alive" then
		self:Invalidate()
	end
end

function M:OnLeft(ply)
	self:_EndDeathCam(ply)
	self.views[ply] = nil
	self:Invalidate()
end

function M:OnKeyPress(ply, key)
	local view = self.views[ply]
	if view == nil or not view.observing or key ~= IN_ATTACK and key ~= IN_ATTACK2 and key ~= IN_JUMP then
		return
	end
	local now = CurTime()
	if now < view.nextKey then
		return
	end
	view.nextKey = now + KEY_DELAY
	if key == IN_JUMP then
		-- The cycle goes from what is on screen: a follow camera without a target is free.
		local shown = view.target ~= nil and view.camera or OBS_MODE_ROAMING
		self:SetCamera(ply, NAMES[NEXT_CAMERA[shown]])
	else
		self:Next(ply, key == IN_ATTACK and 1 or -1)
	end
end
