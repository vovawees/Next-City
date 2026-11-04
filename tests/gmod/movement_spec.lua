-- Movement module: speeds and limits of user commands by the capabilities of the body, on
-- the server and in the prediction of the client, with the real gamemode files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local IN = World.IN

local function boot()
	local server = Env.Server({ modules = { "players", "organism", "movement" } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	return server, NC.Modules:Instance("movement"), NC.Modules:Instance("organism"), NC.Modules:Instance("players")
end

local function deploy(server, players, name)
	local ply = Env.Bot(server, { name = name })
	server:Advance(0.1)
	players:Deploy(ply)
	return ply
end

local function speeds(ply)
	return { ply:GetWalkSpeed(), ply:GetRunSpeed(), ply:GetSlowWalkSpeed(), ply:GetCrouchedWalkSpeed(),
		ply:GetJumpPower() }
end

-- The buttons and the forward and side movement a user command keeps.
local function run(realm, ply, buttons)
	local cmd = Env.RunCommand(realm, ply, buttons, 200, 50)
	return cmd:GetButtons(), cmd:GetForwardMove(), cmd:GetSideMove()
end

local ALL = IN.JUMP + IN.SPEED + IN.FORWARD + IN.ATTACK

describe("movement", function()
	it("gives a healthy body the configured speeds and every key", function()
		local server, movement, _, players = boot()
		local ply = deploy(server, players, "Bob")
		expect(speeds(ply)):toEqual({ 160, 300, 90, 0.4, 190 })
		expect(movement:Limit(ply)):toBeNil()
		expect({ run(server, ply, ALL) }):toEqual({ ALL, 200, 50 })
		expect(server:Errors()):toEqual({})
	end)

	it("takes sprinting and jumping away with a broken leg, on the server and in prediction", function()
		local server, _, organism, players = boot()
		local client, gordon = Env.Join(server, { name = "Gordon" })
		players:Deploy(gordon)
		server:Command("nc_hurt", nil, { "Gordon", "bullet", "femur_l" })
		local caps = organism:Capabilities(gordon)
		expect(caps.canSprint or caps.canJump):toBe(false)
		local walk = gordon:GetWalkSpeed()
		expect(walk):toBeCloseTo(160 * caps.moveSpeedMul, 1e-9)
		expect(speeds(gordon)):toEqual({ walk, walk, math.min(walk, 90 * caps.moveSpeedMul), 0.4, 0 })
		expect({ run(server, gordon, ALL) }):toEqual({ IN.FORWARD + IN.ATTACK, 200, 50 })

		expect({ run(client, gordon, ALL) }):toEqual({ ALL, 200, 50 }) -- the vitals are on the way
		client.time = server.time
		server:Advance(0.5)
		Env.Flush(server, client)
		expect({ run(client, gordon, ALL) }):toEqual({ IN.FORWARD + IN.ATTACK, 200, 50 })

		expect(organism:ApplyTreatment(gordon, "splint", { limb = "leg_l" })):toBe(true)
		expect(gordon:GetWalkSpeed() > walk):toBe(true)
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("makes a body that cannot stand crawl, slower without the arms", function()
		local server, _, organism, players = boot()
		local ply = deploy(server, players, "Bob")
		server:Command("nc_hurt", nil, { "Bob", "bullet", "femur_l" })
		server:Command("nc_hurt", nil, { "Bob", "bullet", "femur_r" })
		expect(organism:Capabilities(ply).canStand):toBe(false)
		expect(speeds(ply)):toEqual({ 45, 45, 45, 1, 0 })
		expect({ run(server, ply, ALL) }):toEqual({ IN.FORWARD + IN.ATTACK + IN.DUCK, 200, 50 })
		server:Command("nc_hurt", nil, { "Bob", "bullet", "humerus_l" })
		expect(organism:Capabilities(ply).canUseArmL):toBe(false)
		expect(ply:GetWalkSpeed()):toBeCloseTo(45 * 0.65, 1e-9)
		expect(server:Errors()):toEqual({})
	end)

	it("leaves an unconscious body no input, except in noclip, and a dazed one crawling", function()
		local server, _, organism, players = boot()
		local ply = deploy(server, players, "Bob")
		organism:_Knockout(organism:State(ply), 3)
		server:Advance(0.2)
		expect(organism:IsUnconscious(ply)):toBe(true)
		expect({ run(server, ply, ALL + IN.USE) }):toEqual({ IN.DUCK, 0, 0 })
		ply:SetMoveType(World.MOVETYPE.NOCLIP)
		expect({ run(server, ply, ALL) }):toEqual({ ALL, 200, 50 })
		ply:SetMoveType(World.MOVETYPE.WALK)
		local woke = false
		for _ = 1, 600 do
			server:Advance(0.1)
			if not woke and not organism:IsUnconscious(ply) then
				woke = true
				expect(run(server, ply, IN.FORWARD + IN.ATTACK)):toBe(IN.FORWARD + IN.ATTACK + IN.DUCK) -- dazed
			end
			if organism:Capabilities(ply).canStand then
				break
			end
		end
		expect(run(server, ply, IN.FORWARD + IN.ATTACK)):toBe(IN.FORWARD + IN.ATTACK)
		expect(server:Errors()):toEqual({})
	end)

	it("forgets the limit at death and gives a new body the full speeds", function()
		local server, movement, _, players = boot()
		local ply = deploy(server, players, "Bob")
		server:Command("nc_hurt", nil, { "Bob", "bullet", "femur_l" })
		expect(movement:Limit(ply)):toBeTruthy()
		Env.Kill(ply)
		expect(movement:Limit(ply)):toBeNil()
		players:Deploy(ply)
		expect(speeds(ply)):toEqual({ 160, 300, 90, 0.4, 190 })
		expect({ run(server, ply, ALL) }):toEqual({ ALL, 200, 50 })
		expect(server:Errors()):toEqual({})
	end)
end)
