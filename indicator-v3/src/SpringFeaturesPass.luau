-- SpringFeaturesPass: the in-Studio inputs pass for the spring live forward test.
-- Contract: spring-live-contract.md section 1b, decision L15 ("Everything in Studio").
--
-- Runs the capture-time v2 Features over ALL bars in time order, once, with no physics, and keeps for every bar
--     t, drive[8], volatility, ready, reset            (and regime[R] when Features returns it)
-- in compact flat arrays. Lanes later read those drives; nothing here touches an Engine or StepPhysics.
--
-- The module does NOT require Features. The caller injects the object, so the pass can never bind to the wrong
-- (v3, 12-drive) Features:
--     local pass = SpringFeaturesPass.new({features = SpringV2Features.new(prehistory, {symbol = "SPY"})})
--     pass:push(bar)  --> index           (exactly one features:step per bar, strictly increasing t)
--     pass:pushPage(bars) --> last index  (a page of bars, e.g. the 512-bar pages of the live data server)
--     pass:get(i) --> {t, drive = {8}, volatility, ready, reset, regime = {R}?}   (a fresh copy every call)
--     pass:count(), pass:stats(), pass:failure(), pass:digest()
--
-- Failure policy (L4, no in-place recovery): a bar that is rejected BEFORE Features sees it (not a table, t not a
-- finite number, t not after the last stored t) raises and leaves the pass exactly as it was. Once features:step has
-- been called, any problem (it raised, or its result is malformed: drive not exactly 8 finite numbers, volatility not
-- finite, ready or reset not boolean, a regime that appears, disappears or changes size, a t that is not the bar's t)
-- POISONS the pass: Features has advanced and the pass has not stored the bar, so continuing would silently misalign
-- the two. A poisoned pass raises on every later push and reports the reason from pass:failure().
--
-- Yielding: after a bar has been stored and the bar count is a multiple of yieldEvery, onProgress(count, t) is called
-- and then yield(count). The default yield is task.wait() (Roblox scheduler) when a task library exists, otherwise no
-- yield (luau.exe). Callback errors are caught, counted in stats() and never abort the pass. The state is always
-- consistent at a yield, so another thread may call get/count/digest while this one is yielded.
--
-- digest(): "sfp1-hex:<count>:<sha256>" over a canonical byte stream of every stored value. Hex mode packs every number
-- with string.pack("<d") (bit exact, the sign of zero included). When string.pack is unavailable, "sfp1-g17" is
-- the same stream with every number written as %.17g text. The stream, so a receipt can be recomputed from saved values:
--     "SFP1" .. <I4 count><I2 8><I2 regimeSize>                                          (little endian)
--     per bar: <d t><d drive1..drive8><d volatility><d regime1..regimeR><B flags>        flags = ready 1 + reset 2
-- digest() covers the bars stored when it was called, even if more arrive while it yields.

local SpringFeaturesPass = {}
SpringFeaturesPass.__index = SpringFeaturesPass

SpringFeaturesPass.SCHEMA = "roalgo-spring-features-pass-1"
SpringFeaturesPass.DIGEST_PREFIX = "sfp1"
SpringFeaturesPass.DRIVE_SIZE = 8
SpringFeaturesPass.DEFAULT_YIELD_EVERY = 512

local DRIVE = SpringFeaturesPass.DRIVE_SIZE
local FLAG_READY, FLAG_RESET = 1, 2

-- ---------------------------------------------------------------------------------------------------------------------
-- SHA-256 (streaming). Pure Luau on bit32 so Studio and luau.exe produce the same receipt; tested against the NIST
-- vectors in tests/SpringFeaturesPass.spec.luau and against Node's crypto in tests/spring-features-pass.test.mjs.
local K256 = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local M32 = 4294967296
local WORDS16 = string.rep(">I4", 16)

local function newHasher()
	local band, bxor, bnot, rrotate, rshift = bit32.band, bit32.bxor, bit32.bnot, bit32.rrotate, bit32.rshift
	local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
	local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
	local w = table.create(64, 0)
	local pending, total, finished = "", 0, false

	local function compress(data: string, at: number)
		w[1], w[2], w[3], w[4], w[5], w[6], w[7], w[8], w[9], w[10], w[11], w[12], w[13], w[14], w[15], w[16] =
			string.unpack(WORDS16, data, at)
		for j = 17, 64 do
			local w15, w2 = w[j - 15], w[j - 2]
			local s0 = bxor(rrotate(w15, 7), rrotate(w15, 18), rshift(w15, 3))
			local s1 = bxor(rrotate(w2, 17), rrotate(w2, 19), rshift(w2, 10))
			w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % M32
		end
		local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
		for j = 1, 64 do
			local S1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
			local ch = bxor(band(e, f), band(bnot(e), g))
			local t1 = (h + S1 + ch + K256[j] + w[j]) % M32
			local S0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
			local maj = bxor(band(a, b), band(a, c), band(b, c))
			local t2 = (S0 + maj) % M32
			h, g, f, e, d, c, b, a = g, f, e, (d + t1) % M32, c, b, a, (t1 + t2) % M32
		end
		h0, h1, h2, h3 = (h0 + a) % M32, (h1 + b) % M32, (h2 + c) % M32, (h3 + d) % M32
		h4, h5, h6, h7 = (h4 + e) % M32, (h5 + f) % M32, (h6 + g) % M32, (h7 + h) % M32
	end

	local hasher = {}
	function hasher.update(chunk: string)
		assert(type(chunk) == "string", "sha256 update: string required")
		assert(not finished, "sha256 hasher already finalised")
		total += #chunk
		local data = if pending == "" then chunk else pending .. chunk
		local full = #data - #data % 64
		for at = 1, full, 64 do compress(data, at) end
		pending = if full == #data then "" else string.sub(data, full + 1)
	end
	function hasher.final(): string
		assert(not finished, "sha256 hasher already finalised")
		finished = true
		-- message length in bits as a 64-bit big-endian integer: total*8 = high*2^32 + low
		local high, low = math.floor(total / 0x20000000), (total % 0x20000000) * 8
		local tail = pending .. "\128" .. string.rep("\0", (55 - total) % 64) .. string.pack(">I4I4", high, low)
		for at = 1, #tail, 64 do compress(tail, at) end
		return string.format(string.rep("%08x", 8), h0, h1, h2, h3, h4, h5, h6, h7)
	end
	return hasher
end

function SpringFeaturesPass.sha256(message: string): string
	assert(type(message) == "string", "SpringFeaturesPass.sha256: string required")
	local hasher = newHasher()
	hasher.update(message)
	return hasher.final()
end
SpringFeaturesPass._newHasher = newHasher

-- ---------------------------------------------------------------------------------------------------------------------
local function finite(x): boolean
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

local function describe(x): string
	if x == nil then return "nil" end
	if type(x) == "number" then return string.format("%.17g", x) end
	return type(x) .. " " .. tostring(x)
end

-- A bar the pass may hand to Features: a table with a finite t that is after lastT. Returns a problem or nil.
local function barProblem(bar, lastT): string?
	if type(bar) ~= "table" then return "bar must be a table, got " .. type(bar) end
	local t = bar.t
	if not finite(t) then return "bar.t must be a finite number, got " .. describe(t) end
	if lastT ~= nil and not (t > lastT) then
		return string.format("bar.t %s is not after the last stored t %s (bars must strictly increase)", describe(t), describe(lastT))
	end
	return nil
end

-- Checks what features:step returned. Returns (problem or nil, regimeSize). regimeSize is the entry count of
-- feature.regime (0 when absent). `lockedRegime` is the size fixed by the first bar, or nil for the first bar.
local function featureProblem(feature, bar, lockedRegime): (string?, number)
	if type(feature) ~= "table" then return "Features:step must return a table, got " .. type(feature), 0 end
	local drive = feature.drive
	if type(drive) ~= "table" then return "drive must be a table of " .. DRIVE .. " finite numbers, got " .. type(drive), 0 end
	local keys = 0
	for _ in drive do keys += 1 end
	if keys ~= DRIVE then
		return string.format("drive must hold exactly %d values, found %d", DRIVE, keys), 0
	end
	for j = 1, DRIVE do
		if not finite(drive[j]) then return string.format("drive[%d] must be a finite number, got %s", j, describe(drive[j])), 0 end
	end
	if not finite(feature.volatility) then return "volatility must be a finite number, got " .. describe(feature.volatility), 0 end
	if type(feature.ready) ~= "boolean" then return "ready must be a boolean, got " .. describe(feature.ready), 0 end
	if type(feature.reset) ~= "boolean" then return "reset must be a boolean, got " .. describe(feature.reset), 0 end
	if feature.t ~= nil and feature.t ~= bar.t then
		return string.format("feature.t %s is not the bar's t %s", describe(feature.t), describe(bar.t)), 0
	end
	local regime = feature.regime
	local size = 0
	if regime ~= nil then
		if type(regime) ~= "table" then return "regime must be a table of finite numbers when present, got " .. type(regime), 0 end
		for _ in regime do size += 1 end
		if size == 0 then return "regime must not be an empty table", 0 end
		for j = 1, size do
			if not finite(regime[j]) then return string.format("regime[%d] must be a finite number, got %s", j, describe(regime[j])), size end
		end
	end
	if lockedRegime ~= nil and size ~= lockedRegime then
		return string.format("regime size %d differs from the %d fixed by the first bar", size, lockedRegime), size
	end
	return nil, size
end

-- ---------------------------------------------------------------------------------------------------------------------
function SpringFeaturesPass.new(options)
	assert(type(options) == "table", "SpringFeaturesPass.new: options table required")
	local features = options.features
	assert(type(features) == "table" and type(features.step) == "function",
		"SpringFeaturesPass.new: options.features must be an object with a step method (inject SpringV2Features.new(...))")

	local yieldEvery = if options.yieldEvery == nil then SpringFeaturesPass.DEFAULT_YIELD_EVERY else options.yieldEvery
	assert(type(yieldEvery) == "number" and yieldEvery >= 1 and yieldEvery == math.floor(yieldEvery) and yieldEvery < math.huge,
		"SpringFeaturesPass.new: yieldEvery must be a positive integer")

	local yieldFn = options.yield
	if yieldFn == nil then
		-- the default: the Roblox scheduler when there is one (nothing under luau.exe)
		local scheduler = options.scheduler or task
		if type(scheduler) == "table" and type(scheduler.wait) == "function" then
			yieldFn = function() scheduler.wait() end
		end
	elseif yieldFn == false then
		yieldFn = nil
	else
		assert(type(yieldFn) == "function", "SpringFeaturesPass.new: yield must be a function, false or nil")
	end
	assert(options.onProgress == nil or type(options.onProgress) == "function", "SpringFeaturesPass.new: onProgress must be a function")

	local packAvailable = pcall(string.pack, "<d", 1)
	local encoding = options.encoding
	if encoding == nil then encoding = if packAvailable then "hex" else "g17" end
	assert(encoding == "hex" or encoding == "g17", "SpringFeaturesPass.new: encoding must be \"hex\" or \"g17\"")
	assert(encoding ~= "hex" or packAvailable, "SpringFeaturesPass.new: hex encoding needs string.pack")

	return setmetatable({
		_features = features,
		_step = features.step,
		_yieldEvery = yieldEvery,
		_yield = yieldFn,
		_onProgress = options.onProgress,
		_encoding = encoding,
		_n = 0,
		_lastT = nil,
		_regimeSize = nil,
		_busy = false,
		_failure = nil,
		-- flat storage: drive[(i-1)*8 + j], regime[(i-1)*R + j], one number per bar for t, volatility and flags
		_t = {},
		_drive = {},
		_vol = {},
		_flags = {},
		_regime = {},
		_stats = { yields = 0, progressCalls = 0, callbackErrors = 0, lastCallbackError = nil },
	}, SpringFeaturesPass)
end

function SpringFeaturesPass:_open(level: number)
	if self._failure then
		error("SpringFeaturesPass: the pass has failed and accepts no more bars: " .. self._failure, level + 1)
	end
	if self._busy then
		error("SpringFeaturesPass: push re-entered while features:step is running", level + 1)
	end
end

-- Calls onProgress (optional) and yield. Both are caught: a UI or scheduler error must never corrupt or abort the pass.
function SpringFeaturesPass:_boundary(count: number, t: number, withProgress: boolean)
	local stats = self._stats
	if withProgress and self._onProgress then
		stats.progressCalls += 1
		local ok, err = pcall(self._onProgress, count, t)
		if not ok then
			stats.callbackErrors += 1
			stats.lastCallbackError = "onProgress: " .. tostring(err)
		end
	end
	if self._yield then
		stats.yields += 1
		local ok, err = pcall(self._yield, count)
		if not ok then
			stats.callbackErrors += 1
			stats.lastCallbackError = "yield: " .. tostring(err)
		end
	end
end

function SpringFeaturesPass:_poison(index: number, bar, message: string)
	local t = if type(bar) == "table" then bar.t else nil
	self._failure = string.format("bar #%d (t=%s): %s", index, describe(t), message)
	error("SpringFeaturesPass: " .. self._failure, 0)
end

-- Exactly one features:step for this bar. Returns the bar's 1-based index.
function SpringFeaturesPass:push(bar): number
	self:_open(2)
	local problem = barProblem(bar, self._lastT)
	if problem then error("SpringFeaturesPass:push: " .. problem, 2) end

	local index = self._n + 1
	self._busy = true
	local ok, feature = pcall(self._step, self._features, bar)
	self._busy = false
	if not ok then self:_poison(index, bar, "Features:step raised: " .. tostring(feature)) end
	local message, regimeSize = featureProblem(feature, bar, self._regimeSize)
	if message then self:_poison(index, bar, message) end

	-- commit: nothing below can fail
	if self._regimeSize == nil then self._regimeSize = regimeSize end
	local drive, source = self._drive, feature.drive
	local base = (index - 1) * DRIVE
	for j = 1, DRIVE do drive[base + j] = source[j] end
	if regimeSize > 0 then
		local regime, from = self._regime, feature.regime
		local rbase = (index - 1) * regimeSize
		for j = 1, regimeSize do regime[rbase + j] = from[j] end
	end
	self._t[index] = bar.t
	self._vol[index] = feature.volatility
	self._flags[index] = (if feature.ready then FLAG_READY else 0) + (if feature.reset then FLAG_RESET else 0)
	self._n = index
	self._lastT = bar.t

	if index % self._yieldEvery == 0 then self:_boundary(index, bar.t, true) end
	return index
end

-- A page of bars in time order. The whole page is checked before the first bar is stepped, so a page with an
-- out-of-order bar is rejected untouched. Returns the index of the last stored bar (count() for an empty page).
function SpringFeaturesPass:pushPage(bars): number
	self:_open(2)
	if type(bars) ~= "table" then error("SpringFeaturesPass:pushPage: page must be an array of bars, got " .. type(bars), 2) end
	local size = #bars
	local last = self._lastT
	for i = 1, size do
		local problem = barProblem(bars[i], last)
		if problem then error(string.format("SpringFeaturesPass:pushPage: bars[%d]: %s", i, problem), 2) end
		last = bars[i].t
	end
	for i = 1, size do self:push(bars[i]) end
	return self._n
end

function SpringFeaturesPass:count(): number
	return self._n
end

-- nil, or the reason the pass was poisoned.
function SpringFeaturesPass:failure(): string?
	return self._failure
end

function SpringFeaturesPass:get(i: number)
	if type(i) ~= "number" or i ~= math.floor(i) or i < 1 or i > self._n then
		error(string.format("SpringFeaturesPass:get(%s): index must be an integer in 1..%d", tostring(i), self._n), 2)
	end
	local drive, base = table.create(DRIVE), (i - 1) * DRIVE
	for j = 1, DRIVE do drive[j] = self._drive[base + j] end
	local flags = self._flags[i]
	local row = {
		t = self._t[i],
		drive = drive,
		volatility = self._vol[i],
		ready = flags % 2 == 1,
		reset = flags >= FLAG_RESET,
	}
	local size = self._regimeSize or 0
	if size > 0 then
		local regime, rbase = table.create(size), (i - 1) * size
		for j = 1, size do regime[j] = self._regime[rbase + j] end
		row.regime = regime
	end
	return row
end

function SpringFeaturesPass:stats()
	local s = self._stats
	return {
		count = self._n,
		lastT = self._lastT,
		regimeSize = self._regimeSize or 0,
		yieldEvery = self._yieldEvery,
		encoding = self._encoding,
		yields = s.yields,
		progressCalls = s.progressCalls,
		callbackErrors = s.callbackErrors,
		lastCallbackError = s.lastCallbackError,
		failure = self._failure,
	}
end

-- See the header for the stream. Yields like push does (without onProgress). Covers the bars stored at the call.
function SpringFeaturesPass:digest(): string
	local n = self._n
	local size = self._regimeSize or 0
	local encoding = self._encoding
	local hasher = newHasher()
	local width = 1 + DRIVE + 1 + size
	local fmt = "<" .. string.rep("d", width) .. "B"
	local values = table.create(width + 1)
	local fields = table.create(width)
	local parts, count = table.create(64), 0

	if encoding == "hex" then
		hasher.update("SFP1" .. string.pack("<I4I2I2", n, DRIVE, size))
	else
		hasher.update(string.format("SFP1-g17;%d;%d;%d\n", n, DRIVE, size))
	end
	local t, drive, vol, flags, regime = self._t, self._drive, self._vol, self._flags, self._regime
	for i = 1, n do
		local base, rbase = (i - 1) * DRIVE, (i - 1) * size
		values[1] = t[i]
		for j = 1, DRIVE do values[1 + j] = drive[base + j] end
		values[DRIVE + 2] = vol[i]
		for j = 1, size do values[DRIVE + 2 + j] = regime[rbase + j] end
		local row
		if encoding == "hex" then
			values[width + 1] = flags[i]
			row = string.pack(fmt, table.unpack(values, 1, width + 1))
		else
			for k = 1, width do fields[k] = string.format("%.17g", values[k]) end
			row = table.concat(fields, ",") .. "|" .. flags[i] .. "\n"
		end
		count += 1
		parts[count] = row
		if count == 64 then
			hasher.update(table.concat(parts, "", 1, count))
			count = 0
		end
		if i % self._yieldEvery == 0 and i < n then self:_boundary(i, t[i], false) end
	end
	if count > 0 then hasher.update(table.concat(parts, "", 1, count)) end
	return string.format("%s-%s:%d:%s", SpringFeaturesPass.DIGEST_PREFIX, encoding, n, hasher.final())
end

return SpringFeaturesPass
