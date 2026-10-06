-- Spring live forward-test decision session (spring-live-contract.md W3; decisions L1, L2, L5, L6, L7, L10, L12).
-- Pure Luau: it never requires Engine, Features, VerifiedStepper or a Roblox service, never steps physics and never
-- changes the frozen protocol. It runs the frozen 2024 spring-consensus-v1 calibration bar by bar over the states
-- the live capture hands it, with the seven 2024 runs, and keeps result-shaped storage so the unchanged
-- SpringStudy.displayRow expands any decided row for SpringReplayView, SpringPanel and SpringChart.
--   Lead-in (index <= leadInRows): every machine steps with the flat position context; intents are recorded, never
--     traded (compact rows fa="HOLD", fr="lead_in_not_traded", po=0, eq=1; partition calibration_lead_in).
--   Boundary (index leadInRows+1): resetBoundary() on every machine, then one continuous Execution.new() ledger per
--     run, flat at equity 1, for the rest of the run (partition forward_test). Quarter and year figures are equity
--     ratios of that one ledger between period boundaries (L7).
-- compactRow, trimSummary, trimTrades, baselineDiagnostics and fixtureCheck are verbatim copies of SpringStudy's
-- private functions; emaStep is the per-bar body of SpringStudy's baselineInputs loop with its state carried over;
-- the paired comparisons apply SpringStudy's compare() one row at a time in the same order.
-- Chunks (L10) carry the exact inputs (8-field bars, features, hex-packed states) and the compact rows of coupled,
-- independent, numeric and ema_baseline; regenerate() rebuilds every run, including zero, frozen and no_trade, from them.
-- Lead-in validation: L3b compares the re-stepped states with saved2024 (max |dx|, |dv| and |energy| per variant), and
-- the L20 gate steps a leadInRows=0 shadow session over the lead-in rows and counts the rows whose decision or ledger
-- row differs from the offline 2024 result, using the per-row digests in SpringFrozenV1.rowDigests2024.
-- Startup fails closed: hex pins, the threshold pins and the whole-bundle digest compiled into this file
-- (FROZEN_BUNDLE_FNV32, printed by make-spring-frozen.mjs) must equal the loaded SpringFrozenV1.
local SpringPolicy = if script then require(script.Parent.SpringPolicy) else require("./SpringPolicy")
local SpringState = if script then require(script.Parent.SpringState) else require("./SpringState")
local SpringSignals = if script then require(script.Parent.SpringSignals) else require("./SpringSignals")
local Execution = if script then require(script.Parent.Execution) else require("./Execution")
local SpringStudy = if script then require(script.Parent.SpringStudy) else require("./SpringStudy")
local SpringFrozenV1 = if script then require(script.Parent.SpringFrozenV1) else require("./SpringFrozenV1")

local SpringLiveSession = {}
SpringLiveSession.VERSION = "live-1"
SpringLiveSession.SCHEMA = "roalgo-spring-live-session-1"
SpringLiveSession.CHUNK_SCHEMA = "roalgo-spring-live-chunk-1"
SpringLiveSession.FROZEN_SCHEMA = "spring-frozen-v1"
SpringLiveSession.DEFAULT_LEAD_IN_ROWS = 2268
SpringLiveSession.NATIVE_TOLERANCE = 0.002
SpringLiveSession.LEAD_IN_PARTITION = "calibration_lead_in"
SpringLiveSession.FORWARD_PARTITION = "forward_test"
SpringLiveSession.LEAD_IN_REASON = "lead_in_not_traded"
SpringLiveSession.LEAD_IN_SOURCE = "lead_in"
SpringLiveSession.MARKET_EVIDENCE = "forward_test_predeclared"

SpringLiveSession.PACK_SCHEME = "spring-pack-1"
SpringLiveSession.ROW_DIGEST_SCHEME = "spring-row-digest-1"

local LEAD_IN, FORWARD = SpringLiveSession.LEAD_IN_PARTITION, SpringLiveSession.FORWARD_PARTITION
local LEAD_IN_REASON, LEAD_IN_SOURCE = SpringLiveSession.LEAD_IN_REASON, SpringLiveSession.LEAD_IN_SOURCE

-- Compiled-in identity of the frozen 2024 bundle (make-spring-frozen.mjs prints bundleFnv32; the node test checks both).
-- Editing SpringFrozenV1 alone, even with its own pins edited to match, cannot pass new().
local FROZEN_BUNDLE_FNV32 = "2b302cc9"
local EXPECTED_PINS = table.freeze({
	entry = "c58d3570b4debc3f", exit = "98fffc64a2fba93f", bankDeadband = "c58d3570b4de9c3f", unclamped = "c58d3570b4debc3f",
	baseEntry = "d38a558f6b05be3f", baseExit = "f1fccccde004ab3f", baseDeadband = "d38a558f6b059e3f", baseUnclamped = "d38a558f6b05be3f",
	eligible = "1,4,7|9,11,12,14,15|17,19,20,22,23",
})
SpringLiveSession.FROZEN_BUNDLE_FNV32 = FROZEN_BUNDLE_FNV32
-- The decision and ledger fields of a compact row (everything except the 6-digit diagnostics ok/rs/s/b/c/su/bl/st).
local ACTION_FIELDS = table.freeze({ "ia", "is", "ir", "fa", "fs", "fr", "ov", "rc", "pe", "po", "hb", "eq", "sp", "tg", "ex" })
SpringLiveSession.ACTION_FIELDS = ACTION_FIELDS

-- Run kinds and headers (L12). The 2024 kinds keep their SpringStudy headers; live_native replaces recorded_native,
-- whose header says "no live simulation".
local HEADERS = {
	live_native = "Live-captured native physics · 5-minute observations · 2025-2026 forward test.",
	artificial_intervention = "Artificial state intervention · not a recording",
	numerical = "Numerical comparator · not native physics",
	market_baseline = "Market-only baseline · no physical input",
	no_trade = "No-trade baseline · no physical input",
}
local RUN_DEFS = {
	{ id = "coupled", kind = "live_native", variant = "coupled", physical = true, label = "Coupled live native",
		header = HEADERS.live_native },
	{ id = "zero", kind = "artificial_intervention", physical = true, label = "Zero equilibrium (x = v = 0 on every row)",
		header = HEADERS.artificial_intervention .. " · all x and v set to 0" },
	{ id = "frozen", kind = "artificial_intervention", physical = true, label = "Frozen state (2024 calibration sample coupled:12 repeated)",
		header = HEADERS.artificial_intervention .. " · one recorded state repeated on every row · 2024 calibration sample coupled:12" },
	{ id = "independent", kind = "live_native", variant = "independent", physical = true, label = "Independent live native (no coupling)",
		header = HEADERS.live_native .. " Independent rig: 0 coupling springs." },
	{ id = "numeric", kind = "numerical", variant = "numeric", physical = true, label = "Numerical comparator",
		header = HEADERS.numerical },
	{ id = "ema_baseline", kind = "market_baseline", physical = false, label = "EMA trend baseline (market-only, spans 3/12/48, 2024 calibration)",
		header = HEADERS.market_baseline .. " · close-to-close return EMAs" },
	{ id = "no_trade", kind = "no_trade", physical = false, label = "No trade", header = HEADERS.no_trade },
}
local RUN_INDEX = {}
for k, def in RUN_DEFS do RUN_INDEX[def.id] = k end
local VARIANTS = { "coupled", "independent", "numeric" }
local STORED_RUNS = { "coupled", "independent", "numeric", "ema_baseline" }
local REGENERATED_RUNS = { "zero", "frozen", "no_trade" }
SpringLiveSession.RUN_IDS = table.freeze((function() local ids = {} for k, def in RUN_DEFS do ids[k] = def.id end return ids end)())
SpringLiveSession.STORED_RUNS = table.freeze(table.clone(STORED_RUNS))
SpringLiveSession.REGENERATED_RUNS = table.freeze(table.clone(REGENERATED_RUNS))
SpringLiveSession.HEADERS = table.freeze(table.clone(HEADERS))

local EMA_SPANS = { 3, 12, 48 }
local FLAT = table.freeze({ position = 0, pending = false, exitedThisBar = false })
local STATE_DOUBLES = 51
local OPTION_KEYS = { frozen = true, engineConfig = true, driveNames = true, planSha256 = true, leadInRows = true, saved2024 = true, runId = true }
local INPUT_KEYS = { bar = true, feature = true, states = true }
local BAR_KEYS = { t = true, o = true, h = true, l = true, c = true, availableT = true, day = true, label = true }
local FEATURE_KEYS = { reset = true, ready = true, volatility = true, drive = true }
local PIN_KEYS = { "entry", "exit", "bankDeadband", "unclamped", "baseEntry", "baseExit", "baseDeadband", "baseUnclamped",
	"frozenState", "calibrationStd", "baselineStd", "eligible", "active" }
-- Session-owned chunk fields; regenerate() re-drains each chunk and requires these to be identical.
local CHUNK_KEYS = { "schema", "version", "seq", "runId", "planSha256", "protocolId", "frozenResultSha256", "leadInRows",
	"firstIndex", "lastIndex", "count", "bars", "features", "states", "rows", "checks", "atEnd" }

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function isInteger(x) return finite(x) and x % 1 == 0 end
local function fail(message) error("SpringLiveSession: " .. message, 0) end
local function sign(x) if x == nil then return nil end if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end

-- ---------------------------------------------------------------------------------------------------------------
-- Verbatim copies of SpringStudy's private helpers (lean-1). Do not edit one side without the other.
-- ---------------------------------------------------------------------------------------------------------------
local function r6(x) if x == nil then return nil end if x == 0 then return 0 end return tonumber(string.format("%.6g", x)) end
local function r10(x) if x == nil then return nil end if x == 0 then return 0 end return tonumber(string.format("%.10g", x)) end
local function round6(values) if values == nil then return nil end local out = table.create(#values) for i = 1, #values do out[i] = r6(values[i]) end return out end

local function baselineDiagnostics(input, baseCal, clip)
	if not baseCal.available then return { valid = false, reason = "baseline_calibration_unavailable" } end
	if not input.valid then return { valid = false, reason = "baseline_no_prior_close" } end
	local banks, sum = table.create(3), 0
	for k = 1, 3 do
		banks[k] = math.clamp(input.ema[k] / baseCal.coordinates[k].std, -clip, clip) / clip
		sum += banks[k]
	end
	return { valid = true, score = sum / 3, bankScores = banks }
end

-- A synthetic, labelled self-check that the physical scorer and policy produce BUY, SELL and physics CLOSE from
-- x/v alone with the frozen calibration (fixtures, never historical evidence).
local function fixtureCheck(calibration, descriptor, p)
	if not calibration.available then return { pass = false, reason = "calibration_unavailable" } end
	local base = 1.0e9
	local function sample(k, scale, tag)
		local x, v = table.create(24, 0), table.create(24, 0)
		for b = 1, 3 do for _, n in calibration.eligible[b] do x[n] = scale * 2 * calibration.coordinates[n].std end end
		local t = base + k * 300
		return SpringState.synthetic(descriptor, "fixture:" .. tag .. ":" .. k, t, t + 300, "fixture", k == 1, x, v)
	end
	local function drive(direction, tag)
		local machine = SpringSignals.new(calibration, p)
		local entryAt, entryAction = nil, nil
		for k = 1, 14 do
			local intent = machine:step(sample(k, direction, tag), FLAT)
			if intent.action ~= "HOLD" and entryAt == nil then entryAt, entryAction = k, intent.action end
		end
		local held = { position = if direction > 0 then 1 else -1, pending = false, exitedThisBar = false }
		local closeAt, closeReason = nil, nil
		for k = 15, 16 do
			local intent = machine:step(sample(k, 0, tag), held)
			if intent.action == "CLOSE" and closeAt == nil then closeAt, closeReason = k, intent.reason end
		end
		return { entryAt = entryAt, entryAction = entryAction, closeAt = closeAt, closeReason = closeReason }
	end
	local positive, negative = drive(1, "pos"), drive(-1, "neg")
	local quiet = SpringSignals.new(calibration, p)
	local zeroEntries = 0
	for k = 1, 20 do if quiet:step(sample(k, 0, "zero"), FLAT).action ~= "HOLD" then zeroEntries += 1 end end
	local pass = positive.entryAt == 13 and positive.entryAction == "BUY" and positive.closeAt == 16
		and positive.closeReason == "physics_loss_of_conviction"
		and negative.entryAt == 13 and negative.entryAction == "SELL" and negative.closeAt == 16
		and negative.closeReason == "physics_loss_of_conviction" and zeroEntries == 0
	return { pass = pass, positive = positive, negative = negative, zeroStreamEntries = zeroEntries,
		note = "synthetic samples at +/-2 calibration std on every eligible directional x coordinate; flat until warm-up" }
end

-- Exported for inspection only: new() calls the local function, so replacing this field changes nothing.
SpringLiveSession.fixtureCheck = fixtureCheck

-- L6 primary criterion, fixed before row 1: an edge is claimed only if coupled beats no-trade AND the EMA baseline.
local function edgeClaimed(coupledNet, noTradeNet, emaNet)
	return coupledNet > noTradeNet and coupledNet > emaNet
end
SpringLiveSession.edgeClaimed = edgeClaimed

local function compactRow(row, physical)
	local intent = row.intent
	local d = intent.diagnostics or {}
	local st = d.state
	local c = {
		ok = d.valid, rs = d.reason, s = r6(d.score), b = round6(d.bankScores),
		c = if physical then round6(d.nodeContributions) else nil,
		su = d.setup, bl = d.blocked,
		st = if st then { st.warmup, st.posConfirm, st.negConfirm, st.longExit, st.shortExit } else nil,
		ia = intent.action, is = intent.source, ir = intent.reason,
		fa = row.signal, fs = row.signalSource, fr = row.primaryReason,
		ov = if row.overridden then true else nil,
		rc = if #row.riskConditions > 0 then table.clone(row.riskConditions) else nil,
		pe = if row.pending then { a = row.pending.action, s = row.pending.source, r = row.pending.reason, t = row.pending.signalT } else nil,
		po = row.position, hb = row.holdBars, eq = r10(row.equity), sp = r10(row.stop), tg = r10(row.target),
	}
	if #row.executions > 0 then
		local ex = table.create(#row.executions)
		for k, f in row.executions do
			ex[k] = { t = f.t, a = f.action, sd = f.side, p = r10(f.price), r = f.reason, s = f.source, st = f.signalT }
		end
		c.ex = ex
	end
	return c
end

local function trimSummary(summary, rowCount)
	local pending = summary.pendingSignal
	return {
		rows = rowCount, firstT = summary.firstT, lastT = summary.lastT,
		netReturn = summary.netReturn, finalEquity = summary.finalEquity, maxDrawdown = summary.maxDrawdown,
		totalFees = summary.totalFees, totalBorrow = summary.totalBorrow, tradeCount = summary.tradeCount,
		wins = summary.wins, losses = summary.losses, winRate = summary.winRate, realizedNetPnl = summary.realizedNetPnl,
		totalTurnover = summary.totalTurnover, exposureFraction = summary.exposureFraction, openPosition = summary.openPosition,
		pendingUnfilled = if pending then { action = pending.action, source = pending.source, reason = pending.reason, signalT = pending.signalT } else nil,
		finalMarking = summary.finalMarking,
	}
end

local function trimTrades(trades)
	local out = table.create(#trades)
	for k, t in trades do
		out[k] = { direction = t.direction, entryT = t.entryT, exitT = t.exitT, entryPrice = t.entryPrice, exitPrice = t.exitPrice,
			netReturn = t.netReturn, netPnl = t.netPnl, fees = t.totalFees, borrow = t.borrow, reason = t.reason,
			entrySource = t.entrySource, exitSource = t.exitSource, holdSeconds = t.holdSeconds }
	end
	return out
end

-- SpringStudy.baselineInputs, one bar at a time: the loop body verbatim, with prevObs/prevClose/emas carried in state.
local function emaStep(state, rec)
	local obs = { t = rec.bar.t, day = rec.bar.day, reset = rec.feature.reset }
	if SpringPolicy.segmentBreak(state.prevObs, obs) then state.prevClose, state.emas = nil, nil end
	state.prevObs = obs
	local close = rec.bar.c
	local valid = false
	if state.prevClose ~= nil and finite(close) and close > 0 then
		local r = close / state.prevClose - 1
		if state.emas == nil then
			state.emas = { r, r, r }
		else
			for k = 1, 3 do local alpha = 2 / (EMA_SPANS[k] + 1); state.emas[k] += alpha * (r - state.emas[k]) end
		end
		valid = true
	end
	state.prevClose = close
	return { valid = valid, ema = if valid then { state.emas[1], state.emas[2], state.emas[3] } else nil }
end

-- SpringStudy.compare() applied to one row (same fields, same row order, so the same floating-point sums).
local function newComparison()
	return { rows = 0, bothScored = 0, sumAbs = 0, signDisagreements = 0, setupDifferences = 0,
		intentActionDifferences = 0, emittedActionDifferences = 0, emittedLongSide = 0, emittedShortSide = 0, emittedCloseSide = 0,
		finalActionDifferences = 0, executedFillDifferences = 0 }
end
local function compareOne(c, a, b)
	c.rows += 1
	if a.valid and b.valid and a.score ~= nil and b.score ~= nil then
		c.bothScored += 1
		c.sumAbs += math.abs(a.score - b.score)
		if sign(a.score) ~= sign(b.score) then c.signDisagreements += 1 end
	end
	if a.setup ~= b.setup then c.setupDifferences += 1 end
	if a.intent ~= b.intent then
		c.intentActionDifferences += 1
		if a.intent ~= "HOLD" or b.intent ~= "HOLD" then
			c.emittedActionDifferences += 1
			if a.intent == "BUY" or b.intent == "BUY" then c.emittedLongSide += 1
			elseif a.intent == "SELL" or b.intent == "SELL" then c.emittedShortSide += 1
			else c.emittedCloseSide += 1 end
		end
	end
	if a.final ~= b.final then c.finalActionDifferences += 1 end
	if a.fills ~= b.fills then c.executedFillDifferences += 1 end
end
local function comparisonView(c)
	return { rows = c.rows, bothScored = c.bothScored, meanAbsScoreDiff = if c.bothScored > 0 then c.sumAbs / c.bothScored else nil,
		signDisagreements = c.signDisagreements, setupDifferences = c.setupDifferences, intentActionDifferences = c.intentActionDifferences,
		emittedActionDifferences = c.emittedActionDifferences, emittedLongSide = c.emittedLongSide, emittedShortSide = c.emittedShortSide,
		emittedCloseSide = c.emittedCloseSide, finalActionDifferences = c.finalActionDifferences, executedFillDifferences = c.executedFillDifferences }
end

-- ---------------------------------------------------------------------------------------------------------------
-- Exact doubles: string.pack("<d") little-endian bytes (buffer.writef64 where string.pack is missing), lowercase hex.
-- ---------------------------------------------------------------------------------------------------------------
local HEX = table.create(256)
local HEX_VALUE = {}
for b = 0, 255 do HEX[b + 1] = string.format("%02x", b); HEX_VALUE[HEX[b + 1]] = b end
local PACK_FORMATS = {}
local function packFormat(n)
	local f = PACK_FORMATS[n]
	if not f then f = "<" .. string.rep("d", n); PACK_FORMATS[n] = f end
	return f
end
local function packDoubles(values, n)
	if type(string.pack) == "function" then return string.pack(packFormat(n), table.unpack(values, 1, n)) end
	local b = buffer.create(8 * n)
	for i = 1, n do buffer.writef64(b, 8 * (i - 1), values[i]) end
	return buffer.tostring(b)
end
-- count doubles starting at double number `first` (1-based) of a packed string.
local function unpackDoubles(bytes, first, count)
	local out = table.create(count)
	if type(string.unpack) == "function" then
		local values = { string.unpack(packFormat(count), bytes, 8 * (first - 1) + 1) }
		for i = 1, count do out[i] = values[i] end
		return out
	end
	local b = buffer.fromstring(bytes)
	for i = 1, count do out[i] = buffer.readf64(b, 8 * (first + i - 2)) end
	return out
end
local function toHex(bytes)
	local out = table.create(#bytes)
	for k = 1, #bytes do out[k] = HEX[string.byte(bytes, k) + 1] end
	return table.concat(out)
end
local function fromHex(text, byteCount, what)
	if type(text) ~= "string" or #text ~= 2 * byteCount or string.find(text, "[^0-9a-f]") then
		fail(what .. " must be " .. 2 * byteCount .. " lowercase hex characters")
	end
	local out = table.create(byteCount)
	for k = 1, byteCount do out[k] = string.char(HEX_VALUE[string.sub(text, 2 * k - 1, 2 * k)]) end
	return table.concat(out)
end
local function hexDouble(x) return toHex(packDoubles({ x }, 1)) end
local function hexDoubles(values) return toHex(packDoubles(values, #values)) end
SpringLiveSession.hexDouble = hexDouble
SpringLiveSession.hexDoubles = hexDoubles

-- Deterministic text of a JSON-like value (sorted keys, %.17g numbers); used to compare and digest rows.
local function canonicalInto(value, out)
	local kind = type(value)
	if kind == "number" then
		out[#out + 1] = if value ~= value then "nan" else string.format("%.17g", value)
	elseif kind == "string" then
		out[#out + 1] = string.format("%q", value)
	elseif kind == "boolean" then
		out[#out + 1] = if value then "true" else "false"
	elseif kind == "table" then
		local keys = {}
		for key in value do keys[#keys + 1] = key end
		local n = #value
		if n > 0 and #keys == n then
			out[#out + 1] = "["
			for k = 1, n do
				if k > 1 then out[#out + 1] = "," end
				canonicalInto(value[k], out)
			end
			out[#out + 1] = "]"
		else
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			out[#out + 1] = "{"
			for k, key in keys do
				if k > 1 then out[#out + 1] = "," end
				out[#out + 1] = tostring(key) .. "="
				canonicalInto(value[key], out)
			end
			out[#out + 1] = "}"
		end
	elseif kind == "nil" then
		out[#out + 1] = "nil"
	else
		fail("cannot canonicalise a " .. kind)
	end
end
local function canonical(value)
	local out = {}
	canonicalInto(value, out)
	return table.concat(out)
end
SpringLiveSession.canonical = canonical

-- spring-pack-1 (make-spring-frozen.mjs packValue reproduces it byte for byte):
--   number 'n' + 8 bytes little-endian double ('N' for NaN; signedZero=false writes -0 as +0); string 's' + u32le length +
--   bytes; boolean 't'/'f'; array (keys exactly 1..n, n > 0) 'a' + u32le n + items; map 'm' + u32le count + (key, value)
--   pairs in byte order of the string keys. An empty table is an empty map.
local HAS_PACK = type(string.pack) == "function"
local function u32le(n)
	if HAS_PACK then return string.pack("<I4", n) end
	local b = buffer.create(4)
	buffer.writeu32(b, 0, n)
	return buffer.tostring(b)
end
local function f64le(x)
	if HAS_PACK then return string.pack("<d", x) end
	local b = buffer.create(8)
	buffer.writef64(b, 0, x)
	return buffer.tostring(b)
end
local function packInto(value, out, signedZero)
	local kind = type(value)
	if kind == "number" then
		if value ~= value then
			out[#out + 1] = "N"
		else
			if value == 0 and not signedZero then value = 0 end
			out[#out + 1] = "n" .. f64le(value)
		end
	elseif kind == "string" then
		out[#out + 1] = "s" .. u32le(#value) .. value
	elseif kind == "boolean" then
		out[#out + 1] = if value then "t" else "f"
	elseif kind == "table" then
		local n, count = #value, 0
		for _ in value do count += 1 end
		if n > 0 and count == n then
			out[#out + 1] = "a" .. u32le(n)
			for k = 1, n do packInto(value[k], out, signedZero) end
		else
			local keys = table.create(count)
			for key in value do
				if type(key) ~= "string" then fail("pack: map keys must be strings, got a " .. type(key)) end
				keys[#keys + 1] = key
			end
			table.sort(keys)
			out[#out + 1] = "m" .. u32le(count)
			for _, key in keys do
				out[#out + 1] = "s" .. u32le(#key) .. key
				packInto(value[key], out, signedZero)
			end
		end
	else
		fail("pack: cannot encode a " .. kind)
	end
end
local function packValue(value, signedZero)
	local out = {}
	packInto(value, out, signedZero ~= false)
	return table.concat(out)
end
-- FNV-1a 32-bit (offset 2166136261, prime 16777619 = 2^24 + 403, kept exact in doubles).
local FNV_OFFSET = 2166136261
local bxor, lshift, byte = bit32.bxor, bit32.lshift, string.byte
local function fnv(h, text)
	local n = #text
	local k = 1
	while k + 3 <= n do
		local b1, b2, b3, b4 = byte(text, k, k + 3)
		h = bxor(h, b1); h = (lshift(h, 24) + h * 403) % 4294967296
		h = bxor(h, b2); h = (lshift(h, 24) + h * 403) % 4294967296
		h = bxor(h, b3); h = (lshift(h, 24) + h * 403) % 4294967296
		h = bxor(h, b4); h = (lshift(h, 24) + h * 403) % 4294967296
		k += 4
	end
	for j = k, n do
		h = bxor(h, byte(text, j)); h = (lshift(h, 24) + h * 403) % 4294967296
	end
	return h
end
local function hex32(h) return string.format("%08x", h) end
-- spring-row-digest-1: one compact row, its decision/ledger fields, and FNV-1a over u32le digests (several rows or runs).
local function rowDigest(row) return fnv(FNV_OFFSET, packValue(row, false)) end
local function actionDigest(row)
	local picked = {}
	for _, key in ACTION_FIELDS do picked[key] = row[key] end
	return fnv(FNV_OFFSET, packValue(picked, false))
end
local function rangeDigest(rows, first, last)
	local parts = table.create(last - first + 1)
	for i = first, last do parts[#parts + 1] = u32le(rowDigest(rows[i])) end
	return hex32(fnv(FNV_OFFSET, table.concat(parts)))
end
SpringLiveSession.packValue = packValue
SpringLiveSession.rowDigest = function(row) return hex32(rowDigest(row)) end
SpringLiveSession.actionDigest = function(row) return hex32(actionDigest(row)) end
SpringLiveSession.rangeDigest = rangeDigest

-- ---------------------------------------------------------------------------------------------------------------
-- Startup checks (fail closed)
-- ---------------------------------------------------------------------------------------------------------------
local function isDeepFrozen(t, seen)
	if not table.isfrozen(t) then return false end
	seen = seen or {}
	if seen[t] then return true end
	seen[t] = true
	for _, v in t do
		if type(v) == "table" and not isDeepFrozen(v, seen) then return false end
	end
	return true
end

-- First path at which a and b differ (types, values, missing keys both ways), or nil when identical.
local function deepDiff(a, b, path)
	if type(a) ~= type(b) then return path .. " (" .. type(a) .. " vs " .. type(b) .. ")" end
	if type(a) ~= "table" then
		if a ~= b then return path .. " (" .. tostring(a) .. " vs " .. tostring(b) .. ")" end
		return nil
	end
	for k, v in a do
		local d = deepDiff(v, b[k], path .. "." .. tostring(k))
		if d then return d end
	end
	for k in b do
		if a[k] == nil then return path .. "." .. tostring(k) .. " (missing on the left)" end
	end
	return nil
end
SpringLiveSession.deepDiff = deepDiff

local function computedPins(frozen)
	local t, bt = frozen.calibration.thresholds, frozen.baselineCalibration.thresholds
	local state = table.create(48)
	for i = 1, 24 do state[i] = frozen.frozenState.x[i]; state[24 + i] = frozen.frozenState.v[i] end
	local stds = table.create(48)
	for k = 1, 48 do stds[k] = frozen.calibration.coordinates[k].std end
	local baseStds = table.create(3)
	for k = 1, 3 do baseStds[k] = frozen.baselineCalibration.coordinates[k].std end
	local banks, active = table.create(3), table.create(48)
	for b = 1, 3 do
		local ids = table.create(#frozen.calibration.eligible[b])
		for k, n in frozen.calibration.eligible[b] do ids[k] = tostring(n) end
		banks[b] = table.concat(ids, ",")
	end
	for k = 1, 48 do active[k] = if frozen.calibration.coordinates[k].active == true then "1" else "0" end
	return {
		entry = hexDouble(t.entry), exit = hexDouble(t.exit), bankDeadband = hexDouble(t.bankDeadband), unclamped = hexDouble(t.unclamped),
		baseEntry = hexDouble(bt.entry), baseExit = hexDouble(bt.exit), baseDeadband = hexDouble(bt.bankDeadband), baseUnclamped = hexDouble(bt.unclamped),
		frozenState = hexDoubles(state), calibrationStd = hexDoubles(stds), baselineStd = hexDoubles(baseStds),
		eligible = table.concat(banks, "|"), active = table.concat(active),
	}
end

-- The per-row 2024 digests (L20) must be the spring-row-digest-1 list of the 7 runs in RUN_DEFS order.
local function checkRowDigests(digests)
	if type(digests) ~= "table" or digests.scheme ~= SpringLiveSession.ROW_DIGEST_SCHEME or digests.pack ~= SpringLiveSession.PACK_SCHEME then
		fail("frozen rowDigests2024 must use " .. SpringLiveSession.ROW_DIGEST_SCHEME .. " over " .. SpringLiveSession.PACK_SCHEME)
	end
	local n = digests.count
	if not isInteger(n) or n < 1 or type(digests.rows) ~= "string" or #digests.rows ~= 8 * n or type(digests.actions) ~= "string"
		or #digests.actions ~= 8 * n or string.find(digests.rows, "[^0-9a-f]") or string.find(digests.actions, "[^0-9a-f]") then
		fail("frozen rowDigests2024 must hold 8 lowercase hex characters per row")
	end
	if deepDiff(digests.runIds, SpringLiveSession.RUN_IDS, "runIds") or deepDiff(digests.actionFields, ACTION_FIELDS, "actionFields") then
		fail("frozen rowDigests2024 runs or action fields differ from this session's")
	end
	local nextFirst = 1
	for _, s in (if type(digests.sessions) == "table" then digests.sessions else {}) do
		if type(s) ~= "table" or s.first ~= nextFirst or not isInteger(s.last) or s.last < s.first or type(s.runs) ~= "table" then
			fail("frozen rowDigests2024 sessions must cover the rows in order")
		end
		for _, id in SpringLiveSession.RUN_IDS do
			if type(s.runs[id]) ~= "string" or #s.runs[id] ~= 8 then fail("frozen rowDigests2024 session " .. tostring(s.day) .. " lacks run " .. id) end
		end
		nextFirst = s.last + 1
	end
	if nextFirst ~= n + 1 then fail("frozen rowDigests2024 sessions must cover rows 1.." .. n) end
end

local function checkFrozen(frozen, p)
	if type(frozen) ~= "table" then fail("frozen inputs table required") end
	if not isDeepFrozen(frozen) then fail("frozen inputs must be deep-frozen (use the SpringFrozenV1 module)") end
	if frozen.schema ~= SpringLiveSession.FROZEN_SCHEMA then fail("frozen schema must be " .. SpringLiveSession.FROZEN_SCHEMA) end
	if frozen.protocolId ~= p.id then fail("frozen protocol " .. tostring(frozen.protocolId) .. " is not " .. p.id) end
	if frozen.resultSha256 ~= SpringFrozenV1.resultSha256 then
		fail("frozen inputs come from result " .. tostring(frozen.resultSha256) .. ", not the pinned 2024 result " .. SpringFrozenV1.resultSha256)
	end
	if type(frozen.pins) ~= "table" then fail("frozen pins missing") end
	for key in frozen.pins do
		if SpringFrozenV1.pins[key] == nil then fail("frozen pin " .. tostring(key) .. " is not a pinned key") end
	end
	for _, key in PIN_KEYS do
		if frozen.pins[key] ~= SpringFrozenV1.pins[key] then fail("frozen pin " .. key .. " differs from the shipped SpringFrozenV1 pin") end
	end
	for key, hex in EXPECTED_PINS do
		if frozen.pins[key] ~= hex then fail("frozen pin " .. key .. " differs from the 2024 value compiled into SpringLiveSession") end
	end
	local cal, base, state = frozen.calibration, frozen.baselineCalibration, frozen.frozenState
	if type(cal) ~= "table" or cal.available ~= true or type(cal.thresholds) ~= "table" or type(cal.coordinates) ~= "table" or #cal.coordinates ~= 48 then
		fail("frozen calibration must be available with 48 coordinates")
	end
	if type(base) ~= "table" or base.available ~= true or type(base.thresholds) ~= "table" or type(base.coordinates) ~= "table" or #base.coordinates ~= 3 then
		fail("frozen baseline calibration must be available with 3 coordinates")
	end
	if type(state) ~= "table" or type(state.x) ~= "table" or #state.x ~= 24 or type(state.v) ~= "table" or #state.v ~= 24 then
		fail("frozen state must hold 24 x and 24 v")
	end
	if state.sampleId ~= cal.firstSampleId then fail("frozen state " .. tostring(state.sampleId) .. " is not the first calibration sample " .. tostring(cal.firstSampleId)) end
	local ok, computed = pcall(computedPins, frozen)
	if not ok then fail("frozen values cannot be packed: " .. tostring(computed)) end
	for _, key in PIN_KEYS do
		if computed[key] ~= frozen.pins[key] then
			fail("hex pin mismatch for " .. key .. ": the loaded doubles are not bit-identical to the 2024 values")
		end
	end
	local okSignals, err = pcall(SpringSignals.new, cal, p)
	if not okSignals then fail("frozen calibration rejected by SpringSignals: " .. tostring(err)) end
	local okPolicy, errPolicy = pcall(SpringPolicy.new, base.thresholds, p, "baseline")
	if not okPolicy then fail("frozen baseline thresholds rejected by SpringPolicy: " .. tostring(errPolicy)) end
	checkRowDigests(frozen.rowDigests2024)
	return computed
end

-- Last startup check: the whole bundle (every field, every double bit for bit) against the compiled-in digest.
local function checkBundle(frozen)
	local ok, digest = pcall(function() return hex32(fnv(FNV_OFFSET, packValue(frozen, true))) end)
	if not ok then fail("new: the frozen bundle cannot be encoded: " .. tostring(digest)) end
	if digest ~= FROZEN_BUNDLE_FNV32 then
		fail("new: frozen bundle digest " .. digest .. " differs from the digest compiled into SpringLiveSession (" .. FROZEN_BUNDLE_FNV32
			.. "): SpringFrozenV1 was edited or built from other inputs")
	end
	return digest
end

-- ---------------------------------------------------------------------------------------------------------------
-- Session
-- ---------------------------------------------------------------------------------------------------------------
local Session = {}
Session.__index = Session

local function newStub()
	return { resetBoundary = function() end }
end

-- One state per variant per row: the 51 doubles packed exactly, false for a missing variant, or a marker that
-- reproduces fromRecord's names/vector rejection exactly on regeneration.
local function encodeState(state, expectedNames)
	if type(state) ~= "table" then return false end
	local names, vector = state.names, state.vector
	if type(names) ~= "table" or #names ~= #expectedNames then return { invalid = "names_mismatch" } end
	for k = 1, #expectedNames do if names[k] ~= expectedNames[k] then return { invalid = "names_mismatch" } end end
	if type(vector) ~= "table" or #vector ~= #expectedNames then return { invalid = "malformed_vector" } end
	local values = table.create(STATE_DOUBLES)
	for k = 1, STATE_DOUBLES do
		local x = vector[k]
		values[k] = if type(x) == "number" then x else 0 / 0
	end
	return packDoubles(values, STATE_DOUBLES)
end
local function decodeState(encoded, expectedNames, what)
	if encoded == false or encoded == nil then return nil end
	if type(encoded) == "table" then
		if encoded.invalid == "names_mismatch" then return { names = {}, vector = {} } end
		if encoded.invalid == "malformed_vector" then return { names = expectedNames, vector = {} } end
		fail(what .. " has an unknown invalid marker " .. tostring(encoded.invalid))
	end
	return { names = expectedNames, vector = unpackDoubles(fromHex(encoded, 8 * STATE_DOUBLES, what), 1, STATE_DOUBLES) }
end

local function stateProxy(session, variant, offset)
	return setmetatable({}, {
		__index = function(_, index)
			if type(index) ~= "number" or index < 1 or index > session.count then return nil end
			local packed = session.packed[variant][index]
			if not session.validState[variant][index] or type(packed) ~= "string" then return false end
			return round6(unpackDoubles(packed, offset, 24))
		end,
		__newindex = function() fail("display states are read-only") end,
	})
end

local newSession
function SpringLiveSession.new(opts)
	return newSession(opts)
end

newSession = function(opts)
	if type(opts) ~= "table" then fail("new: options table required") end
	for key in opts do
		if not OPTION_KEYS[key] then fail("new: unknown option " .. tostring(key)) end
	end
	local p = SpringPolicy.protocol()
	local frozen = if opts.frozen == nil then SpringFrozenV1 else opts.frozen
	local pins = checkFrozen(frozen, p)
	local leadInRows = if opts.leadInRows == nil then SpringLiveSession.DEFAULT_LEAD_IN_ROWS else opts.leadInRows
	if not isInteger(leadInRows) or leadInRows < 0 then fail("new: leadInRows must be a non-negative integer") end
	local plan = opts.planSha256
	if type(plan) ~= "string" or #plan ~= 64 or string.find(plan, "[^0-9a-f]") then fail("new: planSha256 must be 64 lowercase hex characters") end
	if opts.saved2024 ~= nil and type(opts.saved2024) ~= "function" then fail("new: saved2024 must be a function(index) or nil") end
	if opts.runId ~= nil and (type(opts.runId) ~= "string" or #opts.runId > 100 or not string.match(opts.runId, "^[%w_%-]+$")) then
		fail("new: runId must match ^[A-Za-z0-9_-]{1,100}$")
	end
	-- Rig identity: the live engine config must equal the 2024 native config leaf for leaf (k, c, damping, couplings,
	-- masses, rail limits, ... which the descriptor does not cover).
	if type(opts.engineConfig) ~= "table" then fail("new: engineConfig table required") end
	local configDiff = deepDiff(opts.engineConfig, frozen.nativeConfig2024, "engineConfig")
	if configDiff then fail("new: engine config differs from the 2024 native config at " .. configDiff) end
	-- Descriptor: rebuilt from the engine config with describe(), equal to the frozen 2024 descriptor leaf for leaf.
	local okNames, names = pcall(SpringState.expectedStateNames, opts.engineConfig)
	if not okNames then fail("new: cannot derive state names from the engine config: " .. tostring(names)) end
	local okDescribe, described = pcall(SpringState.describe, opts.engineConfig,
		{ coupled = names, independent = names, numeric = names }, opts.driveNames, p)
	if not okDescribe then fail("new: SpringState.describe rejected the engine config: " .. tostring(described)) end
	local descriptorDiff = deepDiff(described, frozen.descriptor, "descriptor")
	if descriptorDiff then fail("new: describe() differs from the frozen 2024 descriptor at " .. descriptorDiff) end
	-- Fixture self-check with the frozen calibration (synthetic, never evidence).
	local fixture = fixtureCheck(frozen.calibration, frozen.descriptor, p)
	if not fixture.pass then fail("new: fixture self-check failed with the frozen calibration") end
	local bundleDigest = checkBundle(frozen)

	local self = setmetatable({}, Session)
	self.p = p
	self.frozen = frozen
	self.pins = pins
	self.bundleDigest = bundleDigest
	self.descriptor = frozen.descriptor
	self.calibration = frozen.calibration
	self.baseCal = frozen.baselineCalibration
	self.leadInRows = leadInRows
	self.planSha256 = plan
	self.runId = opts.runId
	self.saved2024 = opts.saved2024
	self.count = 0
	self.failed = nil
	self.fixture = fixture
	self.zeros = table.create(24, 0)
	self.frozenX, self.frozenV = table.clone(frozen.frozenState.x), table.clone(frozen.frozenState.v)
	self.ema = { prevObs = nil, prevClose = nil, emas = nil }
	self.machines = {}
	for _, def in RUN_DEFS do
		if def.physical then
			self.machines[def.id] = SpringSignals.new(frozen.calibration, p)
		elseif def.id == "ema_baseline" then
			self.machines[def.id] = if self.baseCal.available then SpringPolicy.new(self.baseCal.thresholds, p, "baseline") else newStub()
		else
			self.machines[def.id] = newStub()
		end
	end
	self.ledgers = nil
	self.packed, self.validState = {}, {}
	for _, variant in VARIANTS do self.packed[variant], self.validState[variant] = {}, {} end
	self.barColumns = { t = {}, o = {}, h = {}, l = {}, c = {} }
	self.pending = nil
	self.seq = 0
	self.lastEquity = {}
	self.comparisonAcc = {}
	for _, def in RUN_DEFS do
		if def.id ~= "coupled" then
			self.comparisonAcc[def.id] = { all = newComparison(), [LEAD_IN] = newComparison(), [FORWARD] = newComparison() }
		end
	end
	self.dependence = { coupledEmitted = 0, zeroEmitted = 0, maxSumError = 0, zeroNonZero = 0, forwardRows = 0, leadInRows = 0 }
	self.periods = {}
	for _, def in RUN_DEFS do self.periods[def.id] = { quarters = {}, years = {} } end
	self.repro = { compared = 0, missing = 0, indexMismatches = 0, tMismatches = 0, resetMismatches = 0, invalidLive = 0,
		maxAbs = { coupled = 0, independent = 0, numeric = 0 }, maxAbsXV = { coupled = 0, independent = 0, numeric = 0 },
		maxAbsX = { coupled = 0, independent = 0, numeric = 0 }, maxAbsV = { coupled = 0, independent = 0, numeric = 0 },
		maxAbsEnergy = { coupled = 0, independent = 0, numeric = 0 }, maxAbsDrive = 0, firstExceeded = nil }
	-- L20: a leadInRows=0 shadow session decides the lead-in rows exactly as the offline 2024 study did (continuous
	-- ledgers from row 1); each of its rows is digested and compared with SpringFrozenV1.rowDigests2024. The shadow is
	-- dropped (and its memory released) after the last compared row.
	local digests = frozen.rowDigests2024
	local sessionAcc, sessionsDiffering = {}, {}
	for _, def in RUN_DEFS do sessionAcc[def.id], sessionsDiffering[def.id] = FNV_OFFSET, 0 end
	self.decision = { target = math.min(leadInRows, digests.count), compared = 0, rowDifferences = 0, actionRowDifferences = 0,
		firstDifferentRow = nil, firstActionDifferentRow = nil, sessionsCompared = 0, sessionsDiffering = sessionsDiffering,
		sessionAcc = sessionAcc, sessionIndex = 1, error = nil }
	if self.decision.target > 0 then
		self.shadow = newSession({ frozen = frozen, engineConfig = opts.engineConfig, driveNames = opts.driveNames, planSha256 = plan, leadInRows = 0 })
	end

	local runs = table.create(#RUN_DEFS)
	for k, def in RUN_DEFS do
		runs[k] = {
			id = def.id, kind = def.kind, label = def.label, header = def.header, physical = def.physical,
			thresholds = if def.physical then frozen.calibration.thresholds elseif def.id == "ema_baseline" then self.baseCal.thresholds else nil,
			fullHistory = { label = "live_continuous", rows = {} },
		}
	end
	self.result = {
		schema = SpringLiveSession.SCHEMA,
		version = SpringLiveSession.VERSION,
		protocol = p,
		leadInRows = leadInRows,
		descriptor = frozen.descriptor,
		runs = runs,
		timeline = {},
		states = {},
		frozenState = { sampleId = frozen.frozenState.sampleId, x = round6(self.frozenX), v = round6(self.frozenV) },
		evidence = {},
	}
	for _, variant in VARIANTS do
		self.result.states[variant] = { x = stateProxy(self, variant, 1), v = stateProxy(self, variant, 25) }
	end
	self:_refreshEvidence()
	return self
end

-- ---------------------------------------------------------------------------------------------------------------
-- Stepping
-- ---------------------------------------------------------------------------------------------------------------
local function checkInput(self, input)
	if type(input) ~= "table" then fail("step: input table required") end
	for key in input do if not INPUT_KEYS[key] then fail("step: input field '" .. tostring(key) .. "' is not allowed") end end
	local bar, feature = input.bar, input.feature
	if type(bar) ~= "table" then fail("step: bar table required") end
	for key in bar do if not BAR_KEYS[key] then fail("step: bar field '" .. tostring(key) .. "' is not allowed (8 display fields only)") end end
	for _, key in { "t", "o", "h", "l", "c", "availableT" } do
		if not finite(bar[key]) then fail("step: bar." .. key .. " must be finite") end
	end
	if type(bar.day) ~= "string" or not string.match(bar.day, "^%d%d%d%d%-%d%d%-%d%d$") then fail("step: bar.day must be YYYY-MM-DD") end
	if type(bar.label) ~= "string" then fail("step: bar.label must be a string") end
	local previous = self.barColumns.t[self.count]
	if previous ~= nil and not (bar.t > previous) then fail("step: bar.t must increase strictly") end
	if type(feature) ~= "table" then fail("step: feature table required") end
	for key in feature do if not FEATURE_KEYS[key] then fail("step: feature field '" .. tostring(key) .. "' is not allowed") end end
	if type(feature.reset) ~= "boolean" or type(feature.ready) ~= "boolean" then fail("step: feature.reset and feature.ready must be booleans") end
	if type(feature.volatility) ~= "number" then fail("step: feature.volatility must be a number") end
	local drive = feature.drive
	if type(drive) ~= "table" or #drive ~= 8 then fail("step: feature.drive must hold 8 numbers") end
	for k = 1, 8 do if type(drive[k]) ~= "number" then fail("step: feature.drive[" .. k .. "] must be a number") end end
	if type(input.states) ~= "table" then fail("step: states table required") end
	return {
		t = bar.t, o = bar.o, h = bar.h, l = bar.l, c = bar.c, availableT = bar.availableT, day = bar.day, label = bar.label,
	}, {
		reset = feature.reset, ready = feature.ready, volatility = feature.volatility, drive = table.clone(drive),
	}
end

local function availableTOf(bar, p)
	return if bar.availableT ~= nil then bar.availableT else bar.t + p.availabilityLag
end

local function decideFor(self, def, i, ctx, samples, baseDiag, baseObs, bar)
	local machine = self.machines[def.id]
	if def.physical then
		return machine:step(samples[def.variant or def.id], ctx)
	elseif def.id == "ema_baseline" then
		if not self.baseCal.available then
			return { action = "HOLD", source = "baseline", reason = "baseline_calibration_unavailable",
				availableT = availableTOf(bar, self.p), sampleId = "ema:" .. i, diagnostics = { valid = false, reason = "baseline_calibration_unavailable", setup = "none" } }
		end
		local intent = machine:step(baseDiag, baseObs, ctx)
		-- The shared policy names invalid inputs invalid_physics_state; for the baseline that means no prior close.
		if intent.action == "HOLD" and intent.reason == "invalid_physics_state" then intent.reason = baseDiag.reason end
		return intent
	end
	return { action = "HOLD", source = "baseline", reason = "no_trade_comparator", availableT = availableTOf(bar, self.p),
		sampleId = "no_trade:" .. i, diagnostics = { valid = true, setup = "none" } }
end

-- Lead-in row: the intent as decided with the flat context, never traded (L2).
local function leadInRow(intent, physical)
	local d = intent.diagnostics or {}
	local st = d.state
	local emitted = intent.action ~= "HOLD"
	return {
		ok = d.valid, rs = d.reason, s = r6(d.score), b = round6(d.bankScores),
		c = if physical then round6(d.nodeContributions) else nil,
		su = d.setup, bl = d.blocked,
		st = if st then { st.warmup, st.posConfirm, st.negConfirm, st.longExit, st.shortExit } else nil,
		ia = intent.action, is = intent.source, ir = intent.reason,
		fa = "HOLD", fs = LEAD_IN_SOURCE, fr = LEAD_IN_REASON,
		ov = if emitted then true else nil,
		rc = if emitted then { LEAD_IN_REASON } else nil,
		po = 0, hb = 0, eq = 1,
	}
end

local INTENT_ACTIONS = { BUY = true, SELL = true, CLOSE = true, HOLD = true }
local INTENT_SOURCES = { physics = true, risk = true, baseline = true }
local function checkLeadInIntent(intent, availableT, runId)
	if type(intent) ~= "table" or not INTENT_ACTIONS[intent.action] or not INTENT_SOURCES[intent.source]
		or type(intent.reason) ~= "string" or intent.availableT ~= availableT then
		fail("step: run " .. runId .. " returned a malformed lead-in intent")
	end
end

-- The same per-row raw fields SpringStudy's runLedger keeps for compare() and the evidence counts.
local function rawOfLedgerRow(row)
	local d = row.intent.diagnostics or {}
	local fills = {}
	for _, f in row.executions do fills[#fills + 1] = f.action .. ":" .. tostring(f.source) end
	return { valid = d.valid, score = d.score, setup = d.setup or "none", intent = row.intent.action, intentSource = row.intent.source,
		final = row.signal, finalSource = row.signalSource, fills = table.concat(fills, ","), position = row.position,
		contributions = d.nodeContributions }
end
local function rawOfLeadIn(intent)
	local d = intent.diagnostics or {}
	return { valid = d.valid, score = d.score, setup = d.setup or "none", intent = intent.action, intentSource = intent.source,
		final = "HOLD", finalSource = LEAD_IN_SOURCE, fills = "", position = 0, contributions = d.nodeContributions }
end

-- Memory (measured on the 2024 replay: 21.3 KB per bar before these two steps). The ledger keeps every row it
-- returns; once the compact row and raw fields are taken, the ledger's newest row is replaced by a table with only
-- the fields Execution:result() reads (t, position, grossExposure, executions). Compact rows are rebuilt into
-- right-sized tables (a 21-key constructor reserves 32 hash slots), deep-frozen (callers get read-only rows), and
-- reuse the previous row's identical fixed-length b/c/st arrays (zero and frozen repeat them on every row). The
-- variable-length rc is never shared (it is rare, so sharing it saved nothing).
local EMPTY = table.freeze({})
local function slimLedgerRow(ledger, row)
	local rows = ledger.rows
	if rows[#rows] ~= row then fail("ledger row bookkeeping changed; refusing to slim it") end
	rows[#rows] = { t = row.t, position = row.position, grossExposure = row.grossExposure,
		executions = if #row.executions > 0 then row.executions else EMPTY }
end
local function deepFreezeValue(value)
	if type(value) == "table" and not table.isfrozen(value) then
		for _, v in value do deepFreezeValue(v) end
		table.freeze(value)
	end
	return value
end
local SHAREABLE = { b = true, c = true, st = true }
local function sameArray(a, b)
	if type(a) ~= "table" or #a ~= #b then return false end
	for k = 1, #b do
		local x, y = a[k], b[k]
		if x ~= y or (x == 0 and 1 / x ~= 1 / y) then return false end
	end
	return true
end
local function packRow(previous, compact)
	local out = {}
	for key, value in compact do
		if type(value) == "table" then
			local prior = previous and previous[key]
			value = if SHAREABLE[key] and prior ~= nil and sameArray(prior, value) then prior else deepFreezeValue(value)
		end
		out[key] = value
	end
	return table.freeze(out)
end

local function periodKeys(day)
	local y, m = string.match(day, "^(%d%d%d%d)%-(%d%d)%-%d%d$")
	return y, y .. "-Q" .. tostring(math.ceil(tonumber(m) / 3))
end
local function trackPeriod(list, key, i, t, equity)
	local last = list[#list]
	if last == nil or last.key ~= key then
		last = { key = key, firstIndex = i, firstT = t, rows = 0 }
		list[#list + 1] = last
	end
	last.lastIndex, last.lastT, last.rows, last.endEquity = i, t, last.rows + 1, equity
end

local function compareSaved(self, i, bar, feature, states)
	local repro = self.repro
	local ok, saved = pcall(self.saved2024, i)
	if not ok then fail("saved2024(" .. i .. ") failed: " .. tostring(saved)) end
	if type(saved) ~= "table" then repro.missing += 1; return end
	repro.compared += 1
	if saved.index ~= nil and saved.index ~= i then repro.indexMismatches += 1 end
	if saved.t ~= bar.t then repro.tMismatches += 1 end
	if saved.reset ~= nil and saved.reset ~= feature.reset then repro.resetMismatches += 1 end
	if type(saved.drive) == "table" then
		for k = 1, 8 do
			local d = math.abs((saved.drive[k] or 0 / 0) - feature.drive[k])
			if d ~= d then d = math.huge end
			repro.maxAbsDrive = math.max(repro.maxAbsDrive, d)
		end
	end
	for _, variant in VARIANTS do
		local live = type(states[variant]) == "table" and states[variant].vector or nil
		local reference = saved[variant]
		if type(live) ~= "table" or #live ~= STATE_DOUBLES or type(reference) ~= "table" or #reference ~= STATE_DOUBLES then
			repro.invalidLive += 1
		else
			-- Entries 1-24 are x, 25-48 v, 49-51 the bank energies (Mechanics.state); L20 reports dx and dv per variant.
			local worst, worstX, worstV, worstE = 0, 0, 0, 0
			for k = 1, STATE_DOUBLES do
				local a, b = live[k], reference[k]
				local d = if type(a) == "number" and type(b) == "number" then math.abs(a - b) else math.huge
				if d ~= d then d = math.huge end
				worst = math.max(worst, d)
				if k <= 24 then worstX = math.max(worstX, d) elseif k <= 48 then worstV = math.max(worstV, d) else worstE = math.max(worstE, d) end
			end
			repro.maxAbs[variant] = math.max(repro.maxAbs[variant], worst)
			repro.maxAbsXV[variant] = math.max(repro.maxAbsXV[variant], worstX, worstV)
			repro.maxAbsX[variant] = math.max(repro.maxAbsX[variant], worstX)
			repro.maxAbsV[variant] = math.max(repro.maxAbsV[variant], worstV)
			repro.maxAbsEnergy[variant] = math.max(repro.maxAbsEnergy[variant], worstE)
			local limit = if variant == "numeric" then 0 else SpringLiveSession.NATIVE_TOLERANCE
			if worst > limit and repro.firstExceeded == nil then repro.firstExceeded = { index = i, variant = variant, maxAbs = worst } end
		end
	end
end

-- L20: the shadow (leadInRows=0) decides row i from the same input; its 7 rows are digested and compared with the
-- stored 2024 row digests (all runs together per row, and per run per 2024 session). A shadow failure is recorded and
-- disclosed (the gate then reports "differs"); it never fails the live session.
local function stepShadow(self, input, i)
	local d, shadow = self.decision, self.shadow
	local ok, err = pcall(shadow.step, shadow, input)
	if not ok then
		d.error = "the leadInRows=0 shadow session failed at row " .. i .. ": " .. tostring(err)
		self.shadow = nil
		return
	end
	local digests = self.frozen.rowDigests2024
	local rowParts, actionParts = table.create(#RUN_DEFS), table.create(#RUN_DEFS)
	for k, def in RUN_DEFS do
		local row = shadow.result.runs[k].fullHistory.rows[i]
		local digest = u32le(rowDigest(row))
		rowParts[k], actionParts[k] = digest, u32le(actionDigest(row))
		d.sessionAcc[def.id] = fnv(d.sessionAcc[def.id], digest)
	end
	local expected = string.sub(digests.rows, 8 * i - 7, 8 * i)
	if hex32(fnv(FNV_OFFSET, table.concat(rowParts))) ~= expected then
		d.rowDifferences += 1
		d.firstDifferentRow = d.firstDifferentRow or i
	end
	if hex32(fnv(FNV_OFFSET, table.concat(actionParts))) ~= string.sub(digests.actions, 8 * i - 7, 8 * i) then
		d.actionRowDifferences += 1
		d.firstActionDifferentRow = d.firstActionDifferentRow or i
	end
	d.compared = i
	local session = digests.sessions[d.sessionIndex]
	if session and i == session.last then
		d.sessionsCompared += 1
		for _, def in RUN_DEFS do
			if hex32(d.sessionAcc[def.id]) ~= session.runs[def.id] then d.sessionsDiffering[def.id] += 1 end
			d.sessionAcc[def.id] = FNV_OFFSET
		end
		d.sessionIndex += 1
	end
	if i >= d.target then self.shadow = nil end
end

local function stepRow(self, input)
	local bar, feature = checkInput(self, input)
	local p, desc = self.p, self.descriptor
	local i = self.count + 1
	local leadIn = i <= self.leadInRows
	if leadIn and self.saved2024 then compareSaved(self, i, bar, feature, input.states) end

	-- Narrow samples: the live variants through SpringState.fromRecord (bar.t, availableT, day, reset and x/v only),
	-- then the zero and frozen interventions.
	local record = { bar = bar, feature = { reset = feature.reset }, states = input.states }
	local samples = {}
	for _, variant in VARIANTS do samples[variant] = SpringState.fromRecord(record, variant, desc, variant .. ":" .. i) end
	samples.zero = SpringState.synthetic(desc, "zero:" .. i, bar.t, bar.availableT, bar.day, feature.reset, self.zeros, self.zeros)
	samples.frozen = SpringState.synthetic(desc, "frozen:" .. i, bar.t, bar.availableT, bar.day, feature.reset, self.frozenX, self.frozenV)
	-- Market-only EMA adapter (never enters SpringSignals).
	local baseDiag = baselineDiagnostics(emaStep(self.ema, { bar = bar, feature = feature }), self.baseCal, p.calibration.clip)
	local baseObs = { id = "ema:" .. i, t = bar.t, availableT = bar.availableT, day = bar.day, reset = feature.reset }

	-- Boundary (L2): reset every machine and open one continuous ledger per run.
	if not leadIn and self.ledgers == nil then
		if i > 1 then for _, def in RUN_DEFS do self.machines[def.id]:resetBoundary() end end
		self.ledgers = {}
		for _, def in RUN_DEFS do self.ledgers[def.id] = Execution.new() end
	end
	local availableT = availableTOf(bar, p)
	local risk = { volatility = feature.volatility, ready = feature.ready }
	local compacts, raws, equities = {}, {}, {}
	for _, def in RUN_DEFS do
		if leadIn then
			local intent = decideFor(self, def, i, FLAT, samples, baseDiag, baseObs, bar)
			checkLeadInIntent(intent, availableT, def.id)
			compacts[def.id], raws[def.id] = leadInRow(intent, def.physical), rawOfLeadIn(intent)
		else
			local row = self.ledgers[def.id]:stepIntent(bar, risk, function(ctx)
				return decideFor(self, def, i, ctx, samples, baseDiag, baseObs, bar)
			end)
			compacts[def.id], raws[def.id], equities[def.id] = compactRow(row, def.physical), rawOfLedgerRow(row), row.equity
			slimLedgerRow(self.ledgers[def.id], row)
		end
	end

	-- Commit (only after every run decided this bar).
	self.result.timeline[i] = { t = bar.t, a = bar.availableT, l = bar.label, d = bar.day }
	local pendingStates = {}
	for _, variant in VARIANTS do
		local encoded = encodeState(input.states[variant], desc.stateNames)
		self.packed[variant][i] = encoded
		self.validState[variant][i] = samples[variant].valid
		pendingStates[variant] = encoded
	end
	for _, def in RUN_DEFS do
		local rows = self.result.runs[RUN_INDEX[def.id]].fullHistory.rows
		rows[i] = packRow(rows[i - 1], compacts[def.id])
	end
	local columns = self.barColumns
	columns.t[i], columns.o[i], columns.h[i], columns.l[i], columns.c[i] = bar.t, bar.o, bar.h, bar.l, bar.c
	local pending = self.pending
	if pending == nil then
		pending = { first = i, bars = {}, features = {}, states = { coupled = {}, independent = {}, numeric = {} } }
		self.pending = pending
	end
	pending.bars[#pending.bars + 1] = bar
	pending.features[#pending.features + 1] = feature
	for _, variant in VARIANTS do table.insert(pending.states[variant], pendingStates[variant]) end

	local partition = if leadIn then LEAD_IN else FORWARD
	for id, acc in self.comparisonAcc do
		compareOne(acc.all, raws.coupled, raws[id])
		compareOne(acc[partition], raws.coupled, raws[id])
	end
	local dep = self.dependence
	local coupled, zero = raws.coupled, raws.zero
	if coupled.valid and coupled.contributions then
		local s = 0
		for _, v in coupled.contributions do s += v end
		dep.maxSumError = math.max(dep.maxSumError, math.abs(s - coupled.score))
	end
	if zero.score ~= nil and zero.score ~= 0 then dep.zeroNonZero += 1 end
	if leadIn then
		dep.leadInRows += 1
	else
		dep.forwardRows += 1
		if coupled.intent ~= "HOLD" and coupled.intentSource == "physics" then dep.coupledEmitted += 1 end
		if zero.intent ~= "HOLD" and zero.intentSource == "physics" then dep.zeroEmitted += 1 end
		local year, quarter = periodKeys(bar.day)
		for _, def in RUN_DEFS do
			local equity = equities[def.id]
			self.lastEquity[def.id] = equity
			trackPeriod(self.periods[def.id].quarters, quarter, i, bar.t, equity)
			trackPeriod(self.periods[def.id].years, year, i, bar.t, equity)
		end
	end
	self.count = i
	self:_refreshEvidence()
	if self.shadow and i <= self.decision.target then
		local ok, err = pcall(stepShadow, self, input, i)
		if not ok then
			self.decision.error = "lead-in decision rows could not be digested at row " .. i .. ": " .. tostring(err)
			self.shadow = nil
		end
	end
	return i
end

-- Steps every run on one bar. Any error marks the session failed and later steps refuse (L4: abort, never resume).
function Session:step(input)
	if self.failed then fail("step: the session failed earlier (" .. self.failed .. "); start a new session from row 1") end
	local ok, result = pcall(stepRow, self, input)
	if not ok then
		self.failed = tostring(result)
		error(result, 0)
	end
	return result
end

function Session:_refreshEvidence()
	local e = self.result.evidence
	local problems = {}
	if not self.calibration.available then table.insert(problems, "calibration unavailable") end
	local dep = self.dependence
	if dep.maxSumError > 1e-12 then table.insert(problems, "contribution sum error " .. dep.maxSumError) end
	if dep.zeroNonZero > 0 then table.insert(problems, dep.zeroNonZero .. " zero-run rows scored non-zero") end
	if not self.fixture.pass then table.insert(problems, "fixture self-check failed") end
	local zc = self.comparisonAcc.zero[FORWARD]
	e.implementationStatus = if #problems == 0 then "pass" else "fail"
	e.implementationProblems = problems
	e.physicsDependence = if zc.emittedActionDifferences > 0 and self.fixture.pass then "history_verified"
		elseif self.fixture.pass then "fixtures_verified" else "not_verified"
	e.physicsDependenceCounts = {
		coupledVsZeroEmittedActionDifferences = zc.emittedActionDifferences,
		coupledVsZeroIntentDifferences = zc.intentActionDifferences,
		coupledVsZeroFinalDifferences = zc.finalActionDifferences,
		denominatorRows = zc.rows,
		coupledPhysicsActionsEmitted = dep.coupledEmitted,
		zeroPhysicsActionsEmitted = dep.zeroEmitted,
		maxContributionSumError = dep.maxSumError,
	}
	e.dependenceScope = FORWARD
	e.leadInRows = dep.leadInRows
	e.forwardRows = dep.forwardRows
	e.fixtureCheck = self.fixture
	e.marketEvidence = SpringLiveSession.MARKET_EVIDENCE
	e.tradingApproval = "experimental - not approved for trading"
end

-- ---------------------------------------------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------------------------------------------
local function deepCopy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = deepCopy(v) end
	return out
end

local function findRun(self, runId)
	local k = RUN_INDEX[runId]
	if k == nil then fail("unknown run " .. tostring(runId)) end
	return self.result.runs[k]
end

function Session:rowCount() return self.count end

function Session:partitionOf(index)
	return if index <= self.leadInRows then LEAD_IN else FORWARD
end

-- SpringStudy.displayRow over the growing result, with the live partition of that row.
function Session:displayRow(runId, index)
	findRun(self, runId)
	if not isInteger(index) or index < 1 or index > self.count then fail("displayRow: row " .. tostring(index) .. " is not decided yet") end
	local row = SpringStudy.displayRow(self.result, runId, index)
	row.partition = self:partitionOf(index)
	return row
end

function Session:runs()
	return SpringStudy.runs(self.result)
end

-- Compact rows of one run (the live array; read-only for callers).
function Session:rows(runId)
	return findRun(self, runId).fullHistory.rows
end

-- Price columns for SpringChart: {t={}, o={}, h={}, l={}, c={}} (the live arrays; read-only for callers).
function Session:bars()
	return self.barColumns
end

function Session:comparisons()
	local out = {}
	for id, acc in self.comparisonAcc do
		out["coupled_vs_" .. id] = { all = comparisonView(acc.all), [LEAD_IN] = comparisonView(acc[LEAD_IN]), [FORWARD] = comparisonView(acc[FORWARD]) }
	end
	return out
end

function Session:context(runId, compareId)
	findRun(self, runId)
	local other = if runId == "coupled" then compareId else runId
	local acc = other and self.comparisonAcc[other]
	local scope = if self.count > self.leadInRows then FORWARD else LEAD_IN
	return {
		rowCount = self.count,
		comparisons = if acc then comparisonView(acc[scope]) else nil,
		comparisonScope = scope,
		evidence = self.result.evidence,
		provenance = { run = self.runId or "live", protocol = self.p.id, plan = string.sub(self.planSha256, 1, 8),
			frozen = string.sub(self.frozen.resultSha256, 1, 8), session = SpringLiveSession.VERSION },
	}
end

function Session:evidence()
	return deepCopy(self.result.evidence)
end

-- Cost: it reads every ledger row, like summary(); call it at chunk cadence.
function Session:trades(runId)
	findRun(self, runId)
	if self.ledgers == nil then return {} end
	return trimTrades(self.ledgers[runId]:result().trades)
end

local function periodView(list)
	local out, previous = table.create(#list), 1
	for k, period in list do
		out[k] = { key = period.key, firstIndex = period.firstIndex, lastIndex = period.lastIndex, firstT = period.firstT,
			lastT = period.lastT, rows = period.rows, startEquity = previous, endEquity = period.endEquity,
			netReturn = period.endEquity / previous - 1 }
		previous = period.endEquity
	end
	return out
end

-- L20 decision-row gate over the lead-in (see stepShadow).
local function decisionView(self)
	local d, digests = self.decision, self.frozen.rowDigests2024
	local out = {
		scheme = SpringLiveSession.ROW_DIGEST_SCHEME,
		reference = "offline 2024 result " .. string.sub(self.frozen.resultSha256, 1, 8) .. " fullHistory rows of all 7 runs (continuous ledgers from row 1)",
		method = "a leadInRows=0 shadow session decides the lead-in rows; each row of the 7 runs is compared by digest",
		expectedRows = digests.count, target = d.target, compared = d.compared,
		rowDifferences = d.rowDifferences, actionRowDifferences = d.actionRowDifferences,
		firstDifferentRow = d.firstDifferentRow, firstActionDifferentRow = d.firstActionDifferentRow,
		sessionsCompared = d.sessionsCompared, sessionsDiffering = table.clone(d.sessionsDiffering), error = d.error,
		note = "rowDifferences counts rows whose decision or ledger row (the whole compact row, any of the 7 runs) differs (L20);"
			.. " actionRowDifferences counts rows whose intent, final action, pending order, position, equity, stop, target or fills differ",
	}
	if d.target == 0 then
		out.status, out.label = "not_checked", "no lead-in in this session: decision rows not compared with the offline 2024 result"
	elseif d.error then
		out.status, out.label = "differs", "lead-in decision rows could not all be compared with the offline 2024 result: " .. d.error
	elseif d.compared < d.target then
		out.status = "in_progress"
		out.label = string.format("lead-in decision-row comparison in progress: %d of %d rows", d.compared, d.target)
	elseif d.rowDifferences > 0 then
		out.status = "differs"
		out.label = string.format("%d of %d lead-in rows differ from the offline 2024 result (decision or ledger row; %d with a different action or ledger)",
			d.rowDifferences, d.compared, d.actionRowDifferences)
	elseif d.compared < digests.count then
		out.status = "partial"
		out.label = string.format("the %d lead-in rows equal the offline 2024 result, but only %d of its %d rows were in the lead-in",
			d.compared, d.compared, digests.count)
	else
		out.status = "pass"
		out.label = string.format("all %d lead-in decision and ledger rows equal the offline 2024 result (0 differences)", d.compared)
	end
	return out
end

-- Forward-test ledgers (L2), sub-period returns of the one continuous ledger (L7) and the predeclared criterion (L6).
-- Cost: it reads every ledger row (about 75 ms at 36,288 rows in the CLI), so call it at chunk cadence, not per bar.
function Session:summary()
	local out = { schema = SpringLiveSession.SCHEMA, version = SpringLiveSession.VERSION, rows = self.count, leadInRows = self.leadInRows,
		forwardRows = self.dependence.forwardRows, phase = if self.count > self.leadInRows then FORWARD else LEAD_IN,
		runs = {}, periods = {}, failed = self.failed }
	if self.ledgers then
		for _, def in RUN_DEFS do
			local result = self.ledgers[def.id]:result()
			out.runs[def.id] = trimSummary(result.summary, #result.rows)
			out.periods[def.id] = { quarters = periodView(self.periods[def.id].quarters), years = periodView(self.periods[def.id].years),
				note = "equity ratio between period boundaries of the one continuous forward-test ledger (L7)" }
		end
		local coupled, none, ema = out.runs.coupled.netReturn, out.runs.no_trade.netReturn, out.runs.ema_baseline.netReturn
		out.primaryCriterion = {
			rule = "edge claimed only if coupled net return after costs over the whole forward test is > no-trade (0) and > ema_baseline (L6)",
			coupledNetReturn = coupled, noTradeNetReturn = none, emaBaselineNetReturn = ema,
			edgeClaimed = edgeClaimed(coupled, none, ema),
			forwardRows = self.dependence.forwardRows,
			note = "interim until the controller records completion at the last bar; a single path is not statistical proof",
		}
		-- L20 / L3b disclosure beside the headline: the lead-in validation of this run.
		local rows, repro = decisionView(self), self:reproducibility()
		out.primaryCriterion.leadInValidation = {
			decisionRows = { status = rows.status, label = rows.label, rowDifferences = rows.rowDifferences,
				actionRowDifferences = rows.actionRowDifferences, compared = rows.compared, expectedRows = rows.expectedRows },
			states = { status = repro.status, label = repro.label },
		}
	end
	return out
end

-- L3b: lead-in states against the saved 2024 capture (when a saved2024 lookup was given): max |difference| over the
-- 51-vectors (the gate, as the v2 replay probes defined the 0.002 tolerance), and per variant over x (maxAbsX), v
-- (maxAbsV) and the bank energies (maxAbsEnergy). decisionRows is the L20 decision-row gate (see decisionView).
function Session:reproducibility()
	local r = self.repro
	local out = deepCopy(r)
	out.leadInRows = self.leadInRows
	out.tolerance = { numeric = 0, native = SpringLiveSession.NATIVE_TOLERANCE }
	out.decisionRows = decisionView(self)
	if self.saved2024 == nil then
		out.status = "not_checked"
		out.label = "lead-in not compared with the 2024 capture (no saved2024 lookup)"
		return out
	end
	local decided = math.min(self.count, self.leadInRows)
	if decided < self.leadInRows then
		out.status = "in_progress"
		out.label = string.format("lead-in comparison in progress: %d of %d rows", decided, self.leadInRows)
		return out
	end
	local pass = r.compared == self.leadInRows and r.missing == 0 and r.indexMismatches == 0 and r.tMismatches == 0
		and r.resetMismatches == 0 and r.invalidLive == 0 and r.maxAbs.numeric == 0
		and r.maxAbs.coupled <= SpringLiveSession.NATIVE_TOLERANCE and r.maxAbs.independent <= SpringLiveSession.NATIVE_TOLERANCE
	out.pass = pass
	out.drivesExact = r.maxAbsDrive == 0
	out.status = if pass then "pass" else "differs"
	out.label = if pass then "lead-in re-capture matches the 2024 calibration capture (numeric exact; native within 0.002)"
		else "re-captured physics differs from the 2024 calibration capture"
	return out
end

-- What the plan seal needs from the session: frozen identity, pins and the decision setup.
function Session:identity()
	return {
		sessionSchema = SpringLiveSession.SCHEMA, sessionVersion = SpringLiveSession.VERSION, protocolId = self.p.id,
		frozenSchema = self.frozen.schema, frozenResultSha256 = self.frozen.resultSha256, pins = deepCopy(self.frozen.pins),
		frozenBundleFnv32 = self.bundleDigest, rowDigestScheme = SpringLiveSession.ROW_DIGEST_SCHEME,
		canonicalSha256 = deepCopy(self.frozen.canonicalSha256), leadInRows = self.leadInRows, planSha256 = self.planSha256,
		runId = self.runId, runs = SpringLiveSession.RUN_IDS, storedRuns = SpringLiveSession.STORED_RUNS,
		regeneratedRuns = SpringLiveSession.REGENERATED_RUNS, fixturePass = self.fixture.pass,
	}
end

-- ---------------------------------------------------------------------------------------------------------------
-- Chunks (L10)
-- ---------------------------------------------------------------------------------------------------------------
local function encodeFeature(feature)
	local out = { reset = feature.reset, ready = feature.ready }
	if finite(feature.volatility) then out.volatility = feature.volatility else out.volatilityHex = hexDouble(feature.volatility) end
	local allFinite = true
	for k = 1, 8 do if not finite(feature.drive[k]) then allFinite = false end end
	if allFinite then out.drive = table.clone(feature.drive) else out.driveHex = hexDoubles(feature.drive) end
	return out
end
local function decodeFeature(f, what)
	if type(f) ~= "table" then fail(what .. " must be a table") end
	local volatility = f.volatility
	if volatility == nil then volatility = unpackDoubles(fromHex(f.volatilityHex, 8, what .. ".volatilityHex"), 1, 1)[1] end
	local drive = f.drive
	if drive == nil then drive = unpackDoubles(fromHex(f.driveHex, 64, what .. ".driveHex"), 1, 8) else drive = table.clone(drive) end
	return { reset = f.reset, ready = f.ready, volatility = volatility, drive = drive }
end

-- Takes every row decided since the previous drain. Returns nil when there is none. The chunk is plain JSON-ready data
-- (no nil holes; states are hex strings, false or {invalid=reason}); numbers must be serialised at round-trip
-- precision (SpringJson). The controller may add its own fields (native stats, chain hashes) before posting.
-- checks[runId] (all 7 runs): spring-row-digest-1 digest of the run's rows in the chunk, final actions and fills.
-- The pending batch is released only after the chunk is built, so an error while building loses nothing.
function Session:drainChunk()
	local pending = self.pending
	if pending == nil then return nil end
	local seq = self.seq + 1
	local first, last = pending.first, self.count
	local states = {}
	for _, variant in VARIANTS do
		local list = table.create(#pending.states[variant])
		for k, encoded in pending.states[variant] do
			list[k] = if type(encoded) == "string" then toHex(encoded) else (if encoded == false then false else table.clone(encoded))
		end
		states[variant] = list
	end
	local rows = {}
	for _, id in STORED_RUNS do
		local all, list = findRun(self, id).fullHistory.rows, table.create(last - first + 1)
		for i = first, last do list[#list + 1] = all[i] end
		rows[id] = list
	end
	local checks = {}
	for _, def in RUN_DEFS do
		local all = findRun(self, def.id).fullHistory.rows
		local actions, fills = 0, 0
		for i = first, last do
			if all[i].fa ~= "HOLD" then actions += 1 end
			fills += if all[i].ex then #all[i].ex else 0
		end
		checks[def.id] = { digest = rangeDigest(all, first, last), finalActions = actions, fills = fills }
	end
	local equity = {}
	for _, def in RUN_DEFS do
		if self.lastEquity[def.id] ~= nil then equity[def.id] = hexDouble(self.lastEquity[def.id]) end
	end
	local features = table.create(#pending.features)
	for k, feature in pending.features do features[k] = encodeFeature(feature) end
	local bars = table.create(#pending.bars)
	for k, bar in pending.bars do bars[k] = table.clone(bar) end
	local chunk = {
		schema = SpringLiveSession.CHUNK_SCHEMA, version = SpringLiveSession.VERSION, seq = seq, runId = self.runId,
		planSha256 = self.planSha256, protocolId = self.p.id, frozenResultSha256 = self.frozen.resultSha256,
		leadInRows = self.leadInRows, firstIndex = first, lastIndex = last, count = last - first + 1,
		bars = bars, features = features, states = states, rows = rows, checks = checks,
		atEnd = { equity = equity, rows = last, phase = if last > self.leadInRows then FORWARD else LEAD_IN },
	}
	self.pending = nil
	self.seq = seq
	return chunk
end

-- Step inputs rebuilt exactly from one saved chunk.
function SpringLiveSession.chunkInputs(chunk, stateNames)
	stateNames = stateNames or SpringFrozenV1.descriptor.stateNames
	if type(chunk) ~= "table" or chunk.schema ~= SpringLiveSession.CHUNK_SCHEMA then fail("chunk schema must be " .. SpringLiveSession.CHUNK_SCHEMA) end
	local n = chunk.count
	if not isInteger(n) or n < 1 or type(chunk.bars) ~= "table" or #chunk.bars ~= n or type(chunk.features) ~= "table" or #chunk.features ~= n
		or type(chunk.states) ~= "table" then
		fail("chunk " .. tostring(chunk.seq) .. " must hold count bars, features and states")
	end
	local inputs = table.create(n)
	for j = 1, n do
		local states = {}
		for _, variant in VARIANTS do
			local list = chunk.states[variant]
			if type(list) ~= "table" then fail("chunk " .. tostring(chunk.seq) .. " states." .. variant .. " missing") end
			states[variant] = decodeState(list[j], stateNames, "chunk " .. tostring(chunk.seq) .. " states." .. variant .. "[" .. j .. "]")
		end
		local b = chunk.bars[j]
		if type(b) ~= "table" then fail("chunk bar " .. j .. " must be a table") end
		inputs[j] = {
			bar = { t = b.t, o = b.o, h = b.h, l = b.l, c = b.c, availableT = b.availableT, day = b.day, label = b.label },
			feature = decodeFeature(chunk.features[j], "chunk " .. tostring(chunk.seq) .. " features[" .. j .. "]"),
			states = states,
		}
	end
	return inputs
end

-- Rebuilds a session from saved chunks (in order, from row 1): every run is re-decided from the exact inputs, the
-- stored rows of coupled/independent/numeric/ema_baseline are compared row by row, and each chunk is re-drained and
-- compared field by field (bars, features, states, rows, the zero/frozen/no_trade digests, end equities). Returns the
-- regenerated session (all seven runs, including the regenerated ones) and a report.
function SpringLiveSession.regenerate(opts, chunks)
	if type(chunks) ~= "table" then fail("regenerate: chunks array required") end
	local session = SpringLiveSession.new(opts)
	local report = { chunks = 0, rows = 0, rowDifferences = {}, chunkFieldMismatches = {}, problems = {}, firstDifference = nil }
	for _, id in STORED_RUNS do report.rowDifferences[id] = 0 end
	for k, chunk in chunks do
		local problem = nil
		if type(chunk) ~= "table" or chunk.schema ~= SpringLiveSession.CHUNK_SCHEMA then problem = "chunk " .. k .. " schema"
		elseif chunk.seq ~= k then problem = "chunk " .. k .. " has seq " .. tostring(chunk.seq)
		elseif chunk.firstIndex ~= session.count + 1 then problem = "chunk " .. k .. " starts at " .. tostring(chunk.firstIndex) .. ", expected " .. session.count + 1
		elseif chunk.leadInRows ~= session.leadInRows then problem = "chunk " .. k .. " leadInRows " .. tostring(chunk.leadInRows)
		elseif chunk.planSha256 ~= session.planSha256 then problem = "chunk " .. k .. " belongs to plan " .. tostring(chunk.planSha256)
		elseif type(chunk.rows) ~= "table" then problem = "chunk " .. k .. " rows missing" end
		if problem == nil then
			for _, id in STORED_RUNS do
				if type(chunk.rows[id]) ~= "table" or #chunk.rows[id] ~= chunk.count then problem = "chunk " .. k .. " rows." .. id .. " must hold count rows" end
			end
		end
		if problem then table.insert(report.problems, problem); break end
		-- A malformed chunk or a refused row is a reported problem, never an error thrown at the caller.
		local okInputs, inputs = pcall(SpringLiveSession.chunkInputs, chunk, session.descriptor.stateNames)
		if not okInputs then table.insert(report.problems, "chunk " .. k .. ": " .. tostring(inputs)); break end
		for j, input in inputs do
			local okStep, i = pcall(session.step, session, input)
			if not okStep then problem = "chunk " .. k .. " row " .. j .. ": " .. tostring(i); break end
			for _, id in STORED_RUNS do
				local okRow, saved = pcall(canonical, chunk.rows[id][j])
				local mine = canonical(session:rows(id)[i])
				if not okRow or mine ~= saved then
					report.rowDifferences[id] += 1
					report.firstDifference = report.firstDifference or { index = i, run = id, regenerated = mine, saved = if okRow then saved else tostring(saved) }
				end
			end
		end
		if problem then table.insert(report.problems, problem); break end
		local okDrain, again = pcall(session.drainChunk, session)
		if not okDrain or type(again) ~= "table" then table.insert(report.problems, "chunk " .. k .. " could not be re-drained: " .. tostring(again)); break end
		for _, key in CHUNK_KEYS do
			local okKey, saved = pcall(canonical, chunk[key])
			if not okKey or canonical(again[key]) ~= saved then table.insert(report.chunkFieldMismatches, "chunk " .. k .. " " .. key) end
		end
		report.chunks += 1
	end
	report.rows = session.count
	local differences = 0
	for _, n in report.rowDifferences do differences += n end
	report.totalRowDifferences = differences
	report.pass = #report.problems == 0 and differences == 0 and #report.chunkFieldMismatches == 0
	return session, report
end

return SpringLiveSession
