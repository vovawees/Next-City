-- Next-City benchmarks: the hot paths of the gamemode in the emulated realms, plain LuaJIT.
--
--   luajit tests/bench.lua          -- with the JIT compiler
--   luajit tests/bench.lua nojit    -- interpreter only: closer to GMod, where calls into
--                                   -- the engine keep much of the code interpreted
--
-- The numbers include the emulator (entities, bones and traces in Lua), so they compare
-- changes; the cost in GMod is measured there with nc_perf.

if arg ~= nil and arg[1] == "nojit" then
	jit.off()
end

local source = debug.getinfo(1, "S").source
local root = source:match("^@(.-)tests[/\\]bench%.lua$") or ""
if root ~= "" and not root:find("[/\\]$") then
	root = root .. "/"
end
T = { root = root, gamemode = root .. "gamemodes/nextcity/gamemode/" }

local Env = dofile(root .. "tests/gmod/env.lua")
local World = Env.World
local Vector = World.Vector
local Angle = World.Angle
local IN = World.IN
local clock = os.clock

local PLAYERS = 128
local MODULES = { "players", "organism", "damage", "armor", "movement", "hud" }

local function report(name, total, count, unit)
	local scale = unit == "us" and 1e6 or 1e3
	print(string.format("  %-44s %9.3f %s  (%d runs)", name, total / count * scale, unit, count))
end

-- Seconds `fn` takes, repeated `count` times after a warm-up.
local function time(count, fn)
	for _ = 1, math.min(count, 50) do
		fn()
	end
	collectgarbage()
	local started = clock()
	for _ = 1, count do
		fn()
	end
	return clock() - started
end

local server = Env.Server({ modules = MODULES })
server:Boot()
server:Call("InitPostEntity")
local NC = server:Get("NC")
local players = NC.Modules:Instance("players")
local organism = NC.Modules:Instance("organism")
local movement = NC.Modules:Instance("movement")
local armor = NC.Modules:Instance("armor")
local client, gordon = Env.Join(server, { name = "Gordon" })
local bots = { gordon }
for i = 2, PLAYERS do
	bots[i] = Env.Bot(server, { name = "Bot" .. i })
end
server:Advance(0.1)
for i, ply in ipairs(bots) do
	players:Deploy(ply)
	ply:SetPos(Vector((i % 16) * 100, math.floor(i / 16) * 100, 0))
end
-- A new body for players killed or dying (the kill of a dead body follows on the next tick).
local function redeploy()
	server:Advance(0.1)
	for _, ply in ipairs(bots) do
		if not ply:Alive() or organism:IsDead(ply) then
			players:Deploy(ply)
		end
	end
end

print(string.format("Next-City benchmarks (%s), %d players, modules: %s", jit.status() and "JIT" or "no JIT",
	PLAYERS, table.concat(MODULES, ", ")))
print("server")
local TICK = 1 / 66
-- The organism as the scheduler runs it: every tick the bodies due (rate per second each).
local function simulate()
	server.time = server.time + TICK
	organism:SimTick(server.time, TICK)
end
local ticks = 660
report("organism per tick, healthy bodies", time(ticks, simulate), ticks, "ms")
report("  per body step", time(ticks, simulate), ticks * PLAYERS * organism.ctx.config.rate * TICK, "us")

local AMMO = { "Pistol", "SMG1", "AR2", "357", "Buckshot" }
local BONES = { "Head1", "Spine2", "Spine4", "Pelvis", "L_Thigh", "R_UpperArm", "R_Calf" }
local shooter = bots[2]
-- Batches of one shot at every other player, new bodies between the batches (not timed).
local spent, shots = 0, 0
for batch = 1, 20 do
	redeploy()
	collectgarbage()
	local started = clock()
	for i = 3, PLAYERS do
		local k = batch * PLAYERS + i
		Env.Shoot(shooter, bots[i], { bone = BONES[k % #BONES + 1], ammo = AMMO[k % #AMMO + 1] })
	end
	if batch > 2 then -- warm-up
		spent, shots = spent + clock() - started, shots + PLAYERS - 2
	end
end
report("bullet hit (ScalePlayerDamage .. damage.hit)", spent, shots, "us")
redeploy()
for i, ply in ipairs(bots) do -- wounds that bleed for minutes
	if i % 2 == 0 then
		armor:Equip(ply, "vest")
	end
	Env.Shoot(shooter, ply, { bone = "R_UpperArm", ammo = "Pistol" })
	Env.Shoot(shooter, ply, { bone = "L_Calf", ammo = "SMG1" })
end
redeploy()
local wounded = 0
for _, ply in ipairs(bots) do
	local wounds = organism:Wounds(ply)
	if ply:Alive() and wounds ~= nil and #wounds > 0 then
		wounded = wounded + 1
	end
end
report(string.format("organism per tick, %d wounded bodies", wounded), time(ticks, simulate), ticks, "ms")
redeploy()
report("server tick, everything", time(ticks, function()
	server:Advance(TICK)
end), ticks, "ms")

local cmd = World.UserCmd(IN.FORWARD + IN.SPEED + IN.JUMP, 200, 0)
local healthy = bots[PLAYERS]
movement.limits[healthy] = nil
report("StartCommand, no limit", time(200000, function()
	movement:OnStartCommand(healthy, cmd)
end), 200000, "us")
local limited = bots[PLAYERS - 1]
movement.limits[limited] = movement.LimitOf({ alive = true, canStand = true, canSprint = false, canJump = false })
report("StartCommand, limited", time(200000, function()
	cmd:SetButtons(IN.FORWARD + IN.SPEED + IN.JUMP)
	movement:OnStartCommand(limited, cmd)
end), 200000, "us")

-- Bodies on a flat floor, on a server of their own: players down in them look around,
-- crawl and reach. Without the physics of the emulator.
do
	local bodies = Env.Server({ modules = { "players", "organism", "damage", "ragdoll", "ragdoll_control" } })
	bodies:Boot()
	bodies:Call("InitPostEntity")
	bodies.traceLine = function(trace)
		local a, b = trace.start, trace.endpos
		if a.z >= 0 and b.z <= 0 and a.z ~= b.z then
			local t = a.z / (a.z - b.z)
			return { Hit = true, HitWorld = true, StartSolid = false, Fraction = t, PhysicsBone = 0,
				HitPos = Vector(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0), Entity = World.WORLD }
		end
		return { Hit = false, HitWorld = false, StartSolid = false, Fraction = 1, HitPos = Vector(b), Entity = World.NULL }
	end
	local modules = bodies:Get("NC").Modules
	local ragdoll, control = modules:Instance("ragdoll"), modules:Instance("ragdoll_control")
	local list = {}
	for i = 1, ragdoll.ctx.config.ragdolls do
		list[i] = Env.Bot(bodies, { name = "Body" .. i })
	end
	bodies:Advance(0.1)
	for i, ply in ipairs(list) do
		modules:Instance("players"):Deploy(ply)
		ply:SetPos(Vector((i % 8) * 100, math.floor(i / 8) * 100, 0))
		World.LayRagdoll(ragdoll:Fall(ply).ent)
		ply:SetEyeAngles(Angle(30, i * 37 % 360, 0))
		Env.RunCommand(bodies, ply, IN.FORWARD + IN.ATTACK, 200, 0)
	end
	local now = bodies.time
	report(string.format("ragdoll think, %d bodies", #list), time(ticks, function()
		now = now + TICK
		ragdoll:Think(now)
	end), ticks, "ms")
	report(string.format("ragdoll control, %d bodies", #list), time(ticks, function()
		now = now + TICK
		control:Control(now, TICK)
	end), ticks, "ms")
	local errors = bodies:Errors()
	if #errors > 0 then
		print("errors:\n" .. table.concat(errors, "\n"))
		os.exit(1)
	end
end

print("client")
if not gordon:Alive() then
	players:Deploy(gordon)
end
armor:Equip(gordon, "vest")
armor:Equip(gordon, "helmet")
server:Command("nc_hurt", nil, { "Gordon", "bullet", "femur_l" })
server:Advance(0.5)
client:Advance(server.time - client.time)
Env.Flush(server, client)
local ELEMENTS = { "CHudHealth", "CHudBattery", "CHudAmmo", "CHudSecondaryAmmo", "CHudCrosshair", "CHudChat",
	"CHudWeaponSelection", "CHudDamageIndicator", "CHudGMod", "CHudHintDisplay" }
report("frame: effects, HUD and 30 HUDShouldDraw", time(5000, function()
	client.drawn, client.rects, client.effects = {}, {}, {}
	client:Call("RenderScreenspaceEffects")
	client:Call("HUDPaint")
	for i = 1, 30 do
		client:Call("HUDShouldDraw", ELEMENTS[i % #ELEMENTS + 1])
	end
end), 5000, "us")
report("StartCommand (prediction), limited", time(200000, function()
	cmd:SetButtons(IN.FORWARD + IN.SPEED + IN.JUMP)
	client:Call("StartCommand", gordon, cmd)
end), 200000, "us")

local errors = server:Errors()
for _, err in ipairs(client:Errors()) do
	errors[#errors + 1] = err
end
if #errors > 0 then
	print("errors:\n" .. table.concat(errors, "\n"))
	os.exit(1)
end
