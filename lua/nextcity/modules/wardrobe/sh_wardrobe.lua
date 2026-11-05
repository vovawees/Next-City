-- Wardrobe, shared part: the sets of looks, on both realms in the same order. Titles:
-- lang/<code>/wardrobe.lua of this package.

local M = NC.Module("wardrobe")

local ipairs = ipairs
local format = string.format

-- The models <folder><kind>_<number>.mdl for the numbers.
local function numbered(folder, kind, numbers)
	local out = {}
	for i, number in ipairs(numbers) do
		out[i] = format("%s%s_%02d.mdl", folder, kind, number)
	end
	return out
end

M.SETS = {
	{ "citizens_male", { gender = "male", order = 10,
		models = numbered("models/player/group01/", "male", { 1, 2, 3, 4, 5, 6, 7, 8, 9 }) } },
	{ "citizens_female", { gender = "female", order = 10,
		models = numbered("models/player/group01/", "female", { 1, 2, 3, 4, 5, 6 }) } },
	{ "refugees", { gender = "male", order = 20,
		models = numbered("models/player/group02/", "male", { 2, 4, 6, 8 }) } },
}

function M:Init(ctx)
	local appearance = ctx:Require("appearance")
	for _, entry in ipairs(M.SETS) do
		local id, spec = entry[1], entry[2]
		appearance:AddSet(id, { title = "wardrobe." .. id, gender = spec.gender, order = spec.order,
			models = spec.models })
	end
end
