--!strict
-- Deterministic pseudo-random generator implementing Types.Prng (pure Luau; never Roblox Random).
--
-- Identity: "xoshiro128**/splitmix64/v1".
--   * Generator: xoshiro128** 1.1 (Blackman and Vigna, 2018) on four 32-bit words s[1..4]
--     (s[1] here is s[0] in the reference C code):
--         result = rotl(s1 * 5, 7) * 9            (mod 2^32, s1 is the second word)
--         t = s1 << 9
--         s2 ^= s0; s3 ^= s1; s1 ^= s2; s0 ^= s3; s2 ^= t; s3 = rotl(s3, 11)
--   * Seeding: Prng.new(seed) takes an integer 0 <= seed < 2^53, runs SplitMix64 from state = seed and
--     uses its first two 64-bit outputs z1, z2 as the state {lo32(z1), hi32(z1), lo32(z2), hi32(z2)}.
--   * nextNumber(): 53-bit double in [0,1) from two draws a, b: ((a >> 5) * 2^26 + (b >> 6)) / 2^53.
--   * nextInteger(lo, hi): inclusive, unbiased by rejection: n = hi - lo + 1 (1 <= n <= 2^32);
--     draw x until x < 2^32 - (2^32 mod n); return lo + x mod n. n = 2^32 uses one draw directly.
-- 64-bit arithmetic is done on 32-bit lanes with bit32 and 16-bit limb products, so every intermediate is an
-- exact double. tools/validate-results.mjs re-implements the same generator; both check the shared vector in
-- lab/tests/fixtures/PrngVectors.luau.

local Prng = {}
Prng.__index = Prng
Prng.IDENTITY = "xoshiro128**/splitmix64/v1"

local TWO32 = 4294967296
local TWO53 = 9007199254740992

export type Prng = {
	nextUint32: (self: Prng) -> number,
	nextNumber: (self: Prng) -> number,
	nextInteger: (self: Prng, lo: number, hi: number) -> number,
	state: (self: Prng) -> { number },
	clone: (self: Prng) -> Prng,
}

local band, bxor, lrotate, lshift, rshift = bit32.band, bit32.bxor, bit32.lrotate, bit32.lshift, bit32.rshift

-- (ahi:alo) * (bhi:blo) mod 2^64, all words in [0, 2^32).
local function mul64(ahi: number, alo: number, bhi: number, blo: number): (number, number)
	local a0, a1, a2, a3 = band(alo, 0xFFFF), rshift(alo, 16), band(ahi, 0xFFFF), rshift(ahi, 16)
	local b0, b1, b2, b3 = band(blo, 0xFFFF), rshift(blo, 16), band(bhi, 0xFFFF), rshift(bhi, 16)
	local c0 = a0 * b0
	local c1 = a0 * b1 + a1 * b0
	local c2 = a0 * b2 + a1 * b1 + a2 * b0
	local c3 = a0 * b3 + a1 * b2 + a2 * b1 + a3 * b0
	local l0 = c0 % 65536
	c1 += (c0 - l0) / 65536
	local l1 = c1 % 65536
	c2 += (c1 - l1) / 65536
	local l2 = c2 % 65536
	c3 += (c2 - l2) / 65536
	local l3 = c3 % 65536
	return l3 * 65536 + l2, l1 * 65536 + l0
end

-- z ^ (z >> s) for 0 < s < 32 on a 64-bit value.
local function xorShiftRight(hi: number, lo: number, s: number): (number, number)
	local shi = rshift(hi, s)
	local slo = bit32.bor(rshift(lo, s), lshift(hi, 32 - s))
	return bxor(hi, shi), bxor(lo, slo)
end

local function checkSeed(seed: any)
	if type(seed) ~= "number" or seed ~= seed or seed ~= math.floor(seed) or seed < 0 or seed >= TWO53 then
		error("Prng: seed must be an integer in [0, 2^53), got " .. tostring(seed), 3)
	end
end

-- Returns an iterator over SplitMix64 outputs; each call returns (hi32, lo32).
function Prng.splitmix64(seed: number): () -> (number, number)
	checkSeed(seed)
	local shi, slo = math.floor(seed / TWO32), seed % TWO32
	return function()
		slo += 0x7F4A7C15
		local carry = if slo >= TWO32 then 1 else 0
		slo %= TWO32
		shi = (shi + 0x9E3779B9 + carry) % TWO32
		local zhi, zlo = xorShiftRight(shi, slo, 30)
		zhi, zlo = mul64(zhi, zlo, 0xBF58476D, 0x1CE4E5B9)
		zhi, zlo = xorShiftRight(zhi, zlo, 27)
		zhi, zlo = mul64(zhi, zlo, 0x94D049BB, 0x133111EB)
		return xorShiftRight(zhi, zlo, 31)
	end
end

local function fromWords(s0: number, s1: number, s2: number, s3: number): Prng
	if s0 == 0 and s1 == 0 and s2 == 0 and s3 == 0 then
		error("Prng: all-zero state is invalid", 3)
	end
	local self = setmetatable({ _s0 = s0, _s1 = s1, _s2 = s2, _s3 = s3 }, Prng)
	return self :: any
end

-- New generator from an integer seed (see header for the seeding rule).
function Prng.new(seed: number): Prng
	checkSeed(seed)
	local nextWord = Prng.splitmix64(seed)
	local h1, l1 = nextWord()
	local h2, l2 = nextWord()
	return fromWords(l1, h1, l2, h2)
end

-- New generator from an explicit state {s0, s1, s2, s3} of 32-bit unsigned integers (test vectors, checkpoints).
function Prng.fromState(state: { number }): Prng
	if type(state) ~= "table" or #state ~= 4 then
		error("Prng: state must be four 32-bit words", 2)
	end
	for i = 1, 4 do
		local w = state[i]
		if type(w) ~= "number" or w ~= math.floor(w) or w < 0 or w >= TWO32 then
			error("Prng: state word " .. i .. " must be an integer in [0, 2^32)", 2)
		end
	end
	return fromWords(state[1], state[2], state[3], state[4])
end

function Prng.nextUint32(self: any): number
	local s0, s1, s2, s3 = self._s0, self._s1, self._s2, self._s3
	local result = (lrotate((s1 * 5) % TWO32, 7) * 9) % TWO32
	local t = lshift(s1, 9)
	s2 = bxor(s2, s0)
	s3 = bxor(s3, s1)
	s1 = bxor(s1, s2)
	s0 = bxor(s0, s3)
	s2 = bxor(s2, t)
	s3 = lrotate(s3, 11)
	self._s0, self._s1, self._s2, self._s3 = s0, s1, s2, s3
	return result
end

function Prng.nextNumber(self: any): number
	local a = rshift(Prng.nextUint32(self), 5)
	local b = rshift(Prng.nextUint32(self), 6)
	return (a * 67108864 + b) / TWO53
end

function Prng.nextInteger(self: any, lo: number, hi: number): number
	if type(lo) ~= "number" or type(hi) ~= "number" or lo ~= math.floor(lo) or hi ~= math.floor(hi) then
		error("Prng: nextInteger bounds must be integers", 2)
	end
	if math.abs(lo) >= TWO53 or math.abs(hi) >= TWO53 or lo > hi then
		error("Prng: nextInteger requires lo <= hi within +/-2^53", 2)
	end
	local n = hi - lo + 1
	if n > TWO32 then
		error("Prng: nextInteger range exceeds 2^32 values", 2)
	end
	if n == TWO32 then
		return lo + Prng.nextUint32(self)
	end
	local limit = TWO32 - (TWO32 % n)
	local x = Prng.nextUint32(self)
	while x >= limit do
		x = Prng.nextUint32(self)
	end
	return lo + x % n
end

-- Copy of the current state words {s0, s1, s2, s3}.
function Prng.state(self: any): { number }
	return { self._s0, self._s1, self._s2, self._s3 }
end

function Prng.clone(self: any): Prng
	return fromWords(self._s0, self._s1, self._s2, self._s3)
end

return Prng
