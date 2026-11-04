local Params = T.load("core/params.lua")

local function collector()
	local messages = {}
	return messages, function(message)
		messages[#messages + 1] = message
	end
end

local function sample()
	return Params.Define({
		roundTime = { type = "number", default = 300, min = 30, max = 3600, desc = "round length" },
		teams = { type = "integer", default = 2, min = 2, max = 4 },
		friendlyFire = { type = "boolean" },
		respawn = { type = "enum", values = { "none", "wave", "instant" } },
		title = { type = "string", max = 9 },
		loadout = { type = "list", of = { type = "string", max = 16 }, max = 3, default = { "weapon_crowbar" } },
		delays = { type = "list", of = { type = "integer", min = 0, max = 10 } },
	})
end

describe("params", function()
	it("fills defaults, including the implicit ones", function()
		local set = sample()
		expect(set:Defaults()):toEqual({
			roundTime = 300, teams = 2, friendlyFire = false, respawn = "none", title = "",
			loadout = { "weapon_crowbar" }, delays = {},
		})
		expect(set:Names()):toEqual({ "delays", "friendlyFire", "loadout", "respawn", "roundTime", "teams", "title" })
		expect(set:Count()):toBe(7)
		expect(set:Has("teams")):toBe(true)
		expect(set:Has("nope")):toBe(false)
		expect(set:Get("roundTime").desc):toBe("round length")
	end)

	it("returns fresh copies that never share the defaults", function()
		local set = sample()
		local a = set:Resolve(nil)
		a.loadout[1] = "changed"
		expect(set:Resolve(nil).loadout):toEqual({ "weapon_crowbar" })
		local b = set:Resolve({ loadout = { "weapon_pistol" } })
		expect(b.loadout):toEqual({ "weapon_pistol" })
		expect(set:Get("loadout").default):toEqual({ "weapon_crowbar" })
	end)

	it("keeps valid overrides without warnings", function()
		local set = sample()
		local messages, warn = collector()
		local values = set:Resolve({
			roundTime = 600.5, teams = 3, friendlyFire = true, respawn = "wave", title = "Арен",
			loadout = { "a", "b" }, delays = { 0, 10 },
		}, warn)
		expect(messages):toEqual({})
		expect(values):toEqual({
			roundTime = 600.5, teams = 3, friendlyFire = true, respawn = "wave", title = "Арен",
			loadout = { "a", "b" }, delays = { 0, 10 },
		})
	end)

	it("replaces values of a wrong type with the default", function()
		local set = sample()
		local messages, warn = collector()
		local values = set:Resolve({
			roundTime = "long", teams = "3", friendlyFire = 1, respawn = "sometimes", title = 5, loadout = "knife",
		}, warn)
		expect(values.roundTime):toBe(300)
		expect(values.teams):toBe(2)
		expect(values.friendlyFire):toBe(false)
		expect(values.respawn):toBe("none")
		expect(values.title):toBe("")
		expect(values.loadout):toEqual({ "weapon_crowbar" })
		expect(messages):toEqual({
			"param 'friendlyFire': must be a boolean, got 1; using false",
			"param 'loadout': must be a list, got 'knife'; using {'weapon_crowbar'}",
			"param 'respawn': must be one of none, wave, instant, got 'sometimes'; using 'none'",
			"param 'roundTime': must be a finite number, got 'long'; using 300",
			"param 'teams': must be an integer, got '3'; using 2",
			"param 'title': must be a string, got 5; using ''",
		})
	end)

	it("rejects NaN and infinities", function()
		local set = sample()
		local messages, warn = collector()
		local values = set:Resolve({ roundTime = 0 / 0, teams = math.huge }, warn)
		expect(values.roundTime):toBe(300)
		expect(values.teams):toBe(2)
		expect(#messages):toBe(2)
	end)

	it("clamps numbers and rounds integers", function()
		local set = sample()
		local messages, warn = collector()
		local values = set:Resolve({ roundTime = 5, teams = 7 }, warn)
		expect(values.roundTime):toBe(30)
		expect(values.teams):toBe(4)
		expect(messages):toEqual({
			"param 'roundTime': 5 is below the minimum 30; using 30",
			"param 'teams': 7 is above the maximum 4; using 4",
		})
		messages, warn = collector()
		expect(set:Resolve({ teams = 2.6 }, warn).teams):toBe(3)
		expect(messages):toEqual({ "param 'teams': must be an integer, got 2.6; using 3" })
		expect(set:Resolve({ teams = 1.2 }).teams):toBe(2)
	end)

	it("cuts long strings on a UTF-8 boundary", function()
		local set = sample()
		local messages, warn = collector()
		-- "Арена" is 10 bytes; 9 bytes would split the last letter.
		expect(set:Resolve({ title = "Арена" }, warn).title):toBe("Арен")
		expect(messages):toEqual({ "param 'title': is longer than 9 bytes; using 'Арен'" })
		expect(set:Resolve({ title = "abcdefghij" }).title):toBe("abcdefghi")
	end)

	it("drops invalid list elements and extra ones", function()
		local set = sample()
		local messages, warn = collector()
		local values = set:Resolve({ loadout = { "a", 5, "b", "c", "d" }, delays = { 3.4, -1, "x", 11 } }, warn)
		expect(values.loadout):toEqual({ "a", "b", "c" })
		expect(values.delays):toEqual({ 3, 0, 10 })
		expect(messages):toEqual({
			"param 'delays': element 1 must be an integer, got 3.4; element 2 -1 is below the minimum 0; "
				.. "element 3 must be an integer, got 'x', dropped; element 4 11 is above the maximum 10; using {3, 0, 10}",
			"param 'loadout': element 2 must be a string, got 5, dropped; "
				.. "has more than 3 elements, the rest are dropped; using {'a', 'b', 'c'}",
		})
	end)

	it("warns about unknown keys and a non-table override", function()
		local set = sample()
		local messages, warn = collector()
		local values = set:Resolve({ roundtime = 10, teams = 3 }, warn)
		expect(values.roundtime):toBeNil()
		expect(values.teams):toBe(3)
		expect(messages):toEqual({ "unknown param 'roundtime'" })
		messages, warn = collector()
		expect(set:Resolve(5, warn)):toEqual(set:Defaults())
		expect(messages):toEqual({ "params must be a table, got number; using the defaults" })
		expect(set:Resolve({ teams = 9 }).teams):toBe(4)
	end)

	it("coerces single values", function()
		local set = sample()
		expect({ set:Coerce("teams", 3) }):toEqual({ 3 })
		local value, problem = set:Coerce("teams", 9)
		expect(value):toBe(4)
		expect(problem):toBe("9 is above the maximum 4")
		value, problem = set:Coerce("respawn", "never")
		expect(value):toBe("none")
		expect(problem):toContain("must be one of")
		value, problem = set:Coerce("nope", 1)
		expect(value):toBeNil()
		expect(problem):toBe("unknown param")
	end)

	it("parses console text", function()
		local set = sample()
		expect(set:Parse("roundTime", " 120 ")):toBe(120)
		expect(set:Parse("friendlyFire", "ON")):toBe(true)
		expect(set:Parse("friendlyFire", "0")):toBe(false)
		expect(set:Parse("respawn", "wave")):toBe("wave")
		expect(set:Parse("loadout", "a, b ,c")):toEqual({ "a", "b", "c" })
		expect(set:Parse("loadout", "")):toEqual({})
		expect(set:Parse("delays", "1,2")):toEqual({ 1, 2 })
		local value, err = set:Parse("teams", "two")
		expect(value):toBeNil()
		expect(err):toBe("'two' is not a number")
		value, err = set:Parse("friendlyFire", "maybe")
		expect(value):toBeNil()
		expect(err):toContain("is not a boolean")
		value, err = set:Parse("delays", "1,x")
		expect(value):toBeNil()
		expect(err):toBe("'x' is not a number")
		expect(select(2, set:Parse("nope", "1"))):toBe("unknown param 'nope'")
	end)

	it("describes parameters for listings", function()
		local set = sample()
		expect(set:Describe("teams")):toBe("integer 2..4 = 2")
		expect(set:Describe("teams", 3)):toBe("integer 2..4 = 3")
		expect(set:Describe("respawn")):toBe("enum none|wave|instant = 'none'")
		expect(set:Describe("friendlyFire")):toBe("boolean = false")
		expect(set:Describe("title")):toBe("string <=9 = ''")
		expect(set:Describe("loadout")):toBe("list of string <=16 <=3 = {'weapon_crowbar'}")
		expect(set:Describe("nope")):toBeNil()
	end)

	it("merges sets, later ones win", function()
		local rule = Params.Define({
			roundTime = { type = "number", default = 300, min = 30 },
			respawnDelay = { type = "number", default = 5 },
			mode = { type = "string" },
		})
		local mode = Params.Define({
			roundTime = { type = "number", default = 600 },
			mode = { type = "boolean" },
		})
		local merged, conflicts = Params.Merge({ rule, mode })
		expect(merged:Defaults()):toEqual({ roundTime = 600, respawnDelay = 5, mode = false })
		expect(merged:Get("roundTime").min):toBeNil()
		expect(conflicts):toEqual({ "mode" })
		expect(Params.Merge({}):Count()):toBe(0)
	end)

	it("rejects bad specs with the parameter name", function()
		local cases = {
			{ { x = 5 }, "params: x: spec must be a table" },
			{ { x = { type = "float" } }, "params: x: unknown type 'float'" },
			{ { x = { type = "number" } }, "params: x: default must be a finite number" },
			{ { x = { type = "number", default = 1, defualt = 2 } }, "params: x: unknown spec key 'defualt'" },
			{ { x = { type = "number", default = 5, min = 10, max = 1 } }, "params: x: min must not be greater than max" },
			{ { x = { type = "integer", default = 1.5 } }, "params: x: default must be an integer" },
			{ { x = { type = "integer", default = 1, max = 2.5 } }, "params: x: max must be an integer" },
			{ { x = { type = "boolean", default = "yes" } }, "params: x: default must be a boolean" },
			{ { x = { type = "enum", values = {} } }, "params: x: 'values' must be a non-empty array of strings" },
			{ { x = { type = "enum", values = { "a", "a" } } }, "params: x: duplicate value 'a'" },
			{ { x = { type = "enum", values = { "a" }, default = "b" } }, "params: x: default must be one of the values" },
			{ { x = { type = "string", default = "long", max = 2 } }, "params: x: default is longer than max" },
			{ { x = { type = "string", max = 0 } }, "params: x: max must be a positive integer (bytes)" },
			{ { x = { type = "list" } }, "params: x: 'of' must be a type name or an element spec" },
			{ { x = { type = "list", of = "list" } }, "params: x: lists of lists are not supported" },
			{ { x = { type = "list", of = "table" } }, "params: x element: unknown type 'table'" },
			{ { x = { type = "list", of = { type = "string", default = "" } } }, "params: x: list elements take no default" },
			{ { x = { type = "list", of = "integer", default = { 1, "2" } } },
				"params: x: default element 2 is invalid (must be an integer, got '2')" },
			{ { x = { type = "list", of = "integer", default = { 1, 2 }, max = 1 } },
				"params: x: default has more than max elements" },
			{ { x = { type = "list", of = "string", default = { a = 1 } } }, "params: x: default must be an array" },
			{ { x = { type = "number", default = 1, values = { "a" } } }, "params: x: 'values' is only for enums" },
			{ { x = { type = "number", default = 1, desc = 5 } }, "params: x: desc must be a string" },
			{ { ["1x"] = { type = "boolean" } }, "params: 1x: parameter names must start with a letter" },
		}
		for _, case in ipairs(cases) do
			expect(function()
				Params.Define(case[1])
			end):toFail(case[2])
		end
		expect(function()
			Params.Define(5)
		end):toFail("params: spec must be a table")
	end)
end)
