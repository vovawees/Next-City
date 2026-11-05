-- Economy: accounts in storage (a new one starts with config.start, the next server keeps
-- them), payments and charges (the account first, then cash), deposits and withdrawals,
-- cash handed face to face and dropped on the ground, the cash of a leaving player, the
-- balance on the client and the commands, with the real gamemode files.

local Env = dofile(T.root .. "tests/gmod/env.lua")

local World = Env.World
local Vector = World.Vector
local Angle = World.Angle

-- opts: data (DATA of an earlier server), settings of the economy.
local function boot(opts)
	opts = opts or {}
	local server = Env.Server({ modules = { "players", "notices", "inventory", "storage", "economy" },
		data = opts.data, patch = { [Env.CONFIG] = function(cfg)
			cfg.modules.settings.economy = opts.settings
			return cfg
		end } })
	server:Boot()
	server:Call("InitPostEntity")
	local NC = server:Get("NC")
	local m = { NC = NC, aims = {} }
	for _, id in ipairs({ "players", "inventory", "economy", "storage" }) do
		m[id] = NC.Modules:Instance(id)
	end
	local shot = server:Get("MASK_SHOT")
	server.traceLine = function(trace)
		local ent = m.aims[trace.filter]
		if ent ~= nil and trace.mask == shot then
			return { Hit = true, Entity = ent, HitPos = ent:GetPos(), Fraction = 0.5, StartSolid = false }
		end
		return { Hit = false, Entity = World.NULL, Fraction = 1, StartSolid = false, HitPos = Vector(trace.endpos) }
	end
	return server, m
end

local function hud(server, client)
	server:Advance(0.3)
	client.time = server.time
	Env.Flush(server, client)
	client.drawn = {}
	client:Call("HUDPaint")
	return client.drawn
end

describe("economy", function()
	it("opens accounts with the start money, pays, charges the account first and keeps it all", function()
		local server, m = boot()
		local client, gordon = Env.Join(server, { name = "Gordon", language = "ru" })
		m.players:Deploy(gordon)
		server:Advance(0.1)
		local economy, inventory = m.economy, m.inventory
		expect(economy:Balance(gordon)):toBe(500)
		expect(economy:Cash(gordon)):toBe(0)
		expect(economy:Format(1234567)):toBe("$1 234 567")
		expect(economy:Format(250)):toBe("$250")
		expect(economy:Format(-1000)):toBe("-$1 000")

		local paid = {}
		m.NC.Events:On("economy.paid", function(ply, amount, reason)
			paid[#paid + 1] = { ply:Nick(), amount, reason }
		end)
		expect(economy:Pay(gordon, 120.7, "salary")):toBe(true)
		expect(paid):toEqual({ { "Gordon", 120, "salary" } })
		expect(economy:Balance(gordon)):toBe(620)
		expect({ economy:Pay(gordon, 0) }):toEqual({ false, "amount" })
		expect({ economy:Pay(gordon, 0 / 0) }):toEqual({ false, "amount" })

		-- Cash is an item in the pockets: the account first, then the cash.
		expect(economy:Withdraw(gordon, 200)):toBe(200)
		expect({ economy:Balance(gordon), economy:Cash(gordon), inventory:Count(gordon, "money") }):toEqual({ 420, 200, 200 })
		expect({ economy:Withdraw(gordon, 1000) }):toEqual({ false, "funds" })
		expect(economy:Charge(gordon, 500, "shop")):toBe(true)
		expect({ economy:Balance(gordon), economy:Cash(gordon) }):toEqual({ 0, 120 })
		expect({ economy:Charge(gordon, 121) }):toEqual({ false, "funds" })
		expect(economy:CanAfford(gordon, 120)):toBe(true)
		expect(economy:Deposit(gordon, 100)):toBe(100)
		expect({ economy:Deposit(gordon, 50) }):toEqual({ false, "cash" })
		expect({ economy:Balance(gordon), economy:Cash(gordon), economy:Wealth(gordon) }):toEqual({ 100, 20, 120 })

		-- Only the owner sees his balance; the client counts his cash.
		local cl = client:Get("NC").Modules:Instance("economy")
		hud(server, client)
		expect({ cl:Balance(), cl:Cash() }):toEqual({ 100, 20 })

		-- The bank screen asks the server; the player learns what happened.
		cl:Request("withdraw", 30)
		local drawn = hud(server, client)
		expect(economy:Balance(gordon)):toBe(70)
		expect(drawn):toContain("Со счёта снято $30. На счёте: $70")
		cl:Request("deposit", 999)
		expect(hud(server, client)):toContain("У вас нет при себе столько наличных")

		-- The next server on the same disk has the account.
		server:Advance(3)
		expect(server.data["nextcity/economy.json"]):toBeTruthy()
		local again, m2 = boot({ data = server.data })
		local _, gordon2 = Env.Join(again, { name = "Gordon", index = gordon:EntIndex() })
		expect(m2.economy:Balance(gordon2)):toBe(70)
		expect(again:Errors()):toEqual({})
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)

	it("hands cash face to face, drops it on the ground and banks what a leaving player carries", function()
		local server, m = boot({ settings = { start = 1000, currency = "₽" } })
		local client, gordon = Env.Join(server, { name = "Gordon", language = "en" })
		local alyx = Env.Bot(server, { name = "Alyx" })
		server:Advance(0.1)
		m.players:Deploy(gordon)
		m.players:Deploy(alyx)
		gordon:SetPos(Vector(0, 0, 0))
		alyx:SetPos(Vector(60, 0, 0))
		gordon:SetEyeAngles(Angle(0, 0, 0))
		server:Advance(0.1)
		local economy, inventory, aims = m.economy, m.inventory, m.aims
		economy:Withdraw(gordon, 300)

		-- Nobody in front.
		local function run(name, ...)
			gordon.printed = {}
			server:Command(name, gordon, { ... })
			return gordon.printed
		end
		expect(run("nc_givemoney", "50")[1]):toBe("nc_givemoney <amount>: target")
		aims[gordon] = alyx
		expect(run("nc_givemoney", "50")[1]):toBe("Gordon: account ₽700, cash ₽250")
		expect(economy:Cash(alyx)):toBe(50)
		expect(hud(server, client)):toContain("You gave Alyx ₽50")
		expect(run("nc_givemoney", "5000")[1]):toBe("nc_givemoney <amount>: cash")
		alyx:SetPos(Vector(400, 0, 0))
		expect(run("nc_givemoney", "10")[1]):toBe("nc_givemoney <amount>: range")

		-- On the ground: an item of cash anybody can pick up.
		expect(run("nc_dropmoney", "40")[1]):toBe("Gordon: account ₽700, cash ₽210")
		local ent
		for e, item in pairs(inventory.ground) do
			if item.id == "money" then
				ent = e
			end
		end
		expect(ent ~= nil and inventory:ItemOf(ent).count):toBe(40)
		expect(hud(server, client)):toContain("You put ₽40 on the ground")

		expect(run("nc_bank", "deposit", "all")[1]):toBe("Gordon: account ₽910, cash ₽0")
		expect(run("nc_bank", "withdraw", "all")[1]):toBe("Gordon: account ₽0, cash ₽910")
		expect(run("nc_bank", "steal", "1")[1]):toBe("nc_bank [deposit | withdraw <amount | all>]")
		expect(run("nc_money")[1]):toBe("nc_money: superadmin only")

		-- The admin sets accounts.
		local _, admin = Env.Join(server, { name = "Admin", superadmin = true })
		admin.printed = {}
		server:Command("nc_money", admin, { "Alyx", "add", "25" })
		expect(admin.printed[1]):toBe("Alyx: account ₽1 025, cash ₽50")
		server:Command("nc_money", nil, { "Gordon", "set", "-5" })
		expect(economy:Balance(gordon)):toBe(0)

		-- Gordon leaves with cash: it is in his account when he comes back.
		Env.Leave(server, gordon)
		server:Advance(0.1)
		local _, back = Env.Join(server, { name = "Gordon", index = gordon:EntIndex() })
		expect({ economy:Balance(back), economy:Cash(back) }):toEqual({ 910, 0 })
		expect(server:Errors()):toEqual({})
		expect(client:Errors()):toEqual({})
	end)
end)
