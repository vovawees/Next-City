-- Self-test of the runner's matchers, so a broken matcher cannot hide failures.

describe("runner", function()
	it("compares with toBe and toEqual", function()
		expect(1):toBe(1)
		expect({ a = { 1, 2 } }):toEqual({ a = { 1, 2 } })
		expect(function() expect({ 1 }):toEqual({ 2 }) end):toFail("expected")
		expect(function() expect(1):toBe(2) end):toFail("expected 2, got 1")
	end)

	it("checks truthiness and nil", function()
		expect(true):toBeTruthy()
		expect(false):toBeFalsy()
		expect(nil):toBeNil()
		expect(function() expect(0):toBeNil() end):toFail("expected nil")
		expect(function() expect(nil):toBeTruthy() end):toFail("truthy")
	end)

	it("checks containment", function()
		expect("hello world"):toContain("o w")
		expect({ "a", { 1 } }):toContain({ 1 })
		expect(function() expect("abc"):toContain("%a") end):toFail("to contain")
	end)

	it("checks failures", function()
		expect(function() error("boom 42") end):toFail("boom 42")
		expect(function() expect(function() end):toFail() end):toFail("expected the function to fail")
		expect(function() expect(function() error("x") end):toFail("#missing#") end):toFail("expected error containing")
	end)

	it("compares numbers approximately", function()
		expect(0.1 + 0.2):toBeCloseTo(0.3)
		expect(function() expect(1):toBeCloseTo(2, 0.5) end):toFail("expected 2")
	end)

	it("knows the gamemode path", function()
		local suffix = "gamemodes/nextcity/gamemode/"
		expect(T.gamemode:sub(-#suffix)):toBe(suffix)
	end)
end)
