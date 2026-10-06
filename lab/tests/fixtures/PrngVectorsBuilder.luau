-- Builds the PRNG cross-language vector (stored in PrngVectors.luau by tools/gen-result-fixtures.mjs).
-- Each case draws from ONE generator in this order: 16 x nextUint32, 8 x nextNumber, 16 x nextInteger(1, 248),
-- 8 x nextInteger(0, 2^31) (rejects ~half of draws), 8 x nextInteger(-3, 3), 4 x nextInteger(0, 2^32 - 1).
local Prng = require("../../src/Util/Prng")
local Json = require("../../src/Util/Json")

local PrngVectorsBuilder = {}

local function draws(seed: number)
	local g = Prng.new(seed)
	local function take(n: number, fn: () -> number): { number }
		local out = {}
		for i = 1, n do
			out[i] = fn()
		end
		return out
	end
	return {
		seed = seed,
		initialState = Prng.new(seed):state(),
		uint32 = take(16, function() return g:nextUint32() end),
		numbers = take(8, function() return g:nextNumber() end),
		blockStarts = take(16, function() return g:nextInteger(1, 248) end),
		rejecting = take(8, function() return g:nextInteger(0, 2 ^ 31) end),
		signed = take(8, function() return g:nextInteger(-3, 3) end),
		full = take(4, function() return g:nextInteger(0, 2 ^ 32 - 1) end),
	}
end

function PrngVectorsBuilder.build(): string
	local fixed = Prng.fromState({ 1, 2, 3, 4 })
	local fixedOut = {}
	for i = 1, 10 do
		fixedOut[i] = fixed:nextUint32()
	end
	return Json.encode({
		identity = Prng.IDENTITY,
		order = {
			"uint32 x16", "nextNumber x8", "nextInteger(1,248) x16", "nextInteger(0,2^31) x8",
			"nextInteger(-3,3) x8", "nextInteger(0,2^32-1) x4",
		},
		cases = { draws(20261005), draws(20261004), draws(0), draws(1234567), draws(2 ^ 53 - 1) },
		stateVector = { state = { 1, 2, 3, 4 }, uint32 = fixedOut },
	})
end

return PrngVectorsBuilder
