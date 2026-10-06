-- SpringLiveSession spec (spring-live-contract.md W3; contract D17 style). Self-running:
--   luau.exe tests/SpringLiveSession.spec.luau
-- Pure logic with small SYNTHETIC fixtures (never evidence): states at +/-2 calibration std on the eligible
-- directional x coordinates, as in SpringStudy's fixtureCheck, over four labelled sessions that cross a quarter.
-- The 2024 replay (all 2,268 rows of all 7 runs, 0 differences) is proven by tests/SpringLiveSession.test.mjs.
local loaded, SpringLiveSession = pcall(require, "../src/SpringLiveSession")
assert(loaded and type(SpringLiveSession) == "table" and type(SpringLiveSession.new) == "function",
	"SpringLiveSession must load: " .. tostring(SpringLiveSession))
local loadedFrozen, F = pcall(require, "../src/SpringFrozenV1")
assert(loadedFrozen and type(F) == "table", "SpringFrozenV1 must load: " .. tostring(F))
local loadedView, SpringReplayView = pcall(require, "../src/SpringReplayView")
assert(loadedView and type(SpringReplayView.validateRow) == "function", "SpringReplayView must load: " .. tostring(SpringReplayView))
local passed = 0
local function test(name, fn) fn(); passed += 1; print("PASS " .. name) end

local function deepCopy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in value do out[k] = deepCopy(v) end
	return out
end
local function deepFreeze(t)
	for _, v in t do if type(v) == "table" then deepFreeze(v) end end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end
local function r6(x) if x == 0 then return 0 end return tonumber(string.format("%.6g", x)) end
-- The next double above a positive finite x (bit pattern + 1, split into two exact 32-bit halves).
local function nextUp(x)
	assert(x > 0 and x < math.huge)
	local low, high = string.unpack("<I4I4", string.pack("<d", x))
	if low == 4294967295 then low, high = 0, high + 1 else low += 1 end
	local y = string.unpack("<d", string.pack("<I4I4", low, high))
	assert(y > x and string.pack("<d", y) ~= string.pack("<d", x))
	return y
end
local function raises(fn, needle, what)
	local ok, err = pcall(fn)
	assert(not ok, (what or needle) .. ": expected an error")
	if needle then assert(string.find(tostring(err), needle, 1, true), (what or needle) .. ": error was " .. tostring(err)) end
	return tostring(err)
end
local canonical = SpringLiveSession.canonical

local NAMES = F.descriptor.stateNames
local PLAN = string.rep("0123456789abcdef", 4)
local CONFIG = deepCopy(F.nativeConfig2024) -- a plain (unfrozen) table, as a live engine config is
local DRIVE = table.clone(F.descriptor.driveNames)
local CAL = F.calibration
local RUN_IDS = { "coupled", "zero", "frozen", "independent", "numeric", "ema_baseline", "no_trade" }
local STORED = { coupled = true, independent = true, numeric = true, ema_baseline = true }
local KIND = { coupled = "live_native", zero = "artificial_intervention", frozen = "artificial_intervention", independent = "live_native",
	numeric = "numerical", ema_baseline = "market_baseline", no_trade = "no_trade" }

local function options(over)
	local o = { engineConfig = CONFIG, driveNames = DRIVE, planSha256 = PLAN, leadInRows = 0 }
	for k, v in over or {} do o[k] = v end
	return o
end
local function newSession(over) return SpringLiveSession.new(options(over)) end

-- 4 labelled synthetic sessions of 20 bars (2 in 2025-Q1, 2 in 2025-Q2); prices rise 0.05 per bar.
local DAYS = { "2025-03-28", "2025-03-31", "2025-04-01", "2025-04-02" }
local OPEN = { 1743168600, 1743427800, 1743514200, 1743600600 }
local BARS_PER_DAY = 20
local function vector(scale)
	local v = table.create(51, 0)
	for b = 1, 3 do for _, n in CAL.eligible[b] do v[n] = scale * 2 * CAL.coordinates[n].std end end
	return v
end
local function bar(i)
	local d, k = math.floor((i - 1) / BARS_PER_DAY) + 1, (i - 1) % BARS_PER_DAY
	local t = OPEN[d] + k * 300
	local o, c = 100 + 0.05 * (i - 1), 100 + 0.05 * i
	local minutes = 9 * 60 + 30 + 5 * k
	return { t = t, o = o, h = math.max(o, c) + 0.02, l = math.min(o, c) - 0.02, c = c, availableT = t + 300, day = DAYS[d],
		label = string.format("%s %02d:%02d ET", DAYS[d], math.floor(minutes / 60), minutes % 60) }
end
-- The input for bar i, deep-frozen so any write by the session would raise.
local function input(i, scale, edit)
	local states = {}
	for _, variant in { "coupled", "independent", "numeric" } do states[variant] = { names = NAMES, vector = vector(scale) } end
	local value = { bar = bar(i), feature = { reset = i == 1, ready = i >= 12, volatility = 0.001, drive = { 0, 0, 0, 0, 0, 0, 0, 0 } },
		states = states }
	if edit then edit(value) end
	return deepFreeze(value)
end
local function run(session, first, last, scaleOf, edits)
	for i = first, last do
		local scale = if type(scaleOf) == "function" then scaleOf(i) else (scaleOf or 1)
		session:step(input(i, scale, edits and edits[i]))
	end
	return session
end

---------------------------------------------------------------------------------------------------
test("new accepts the shipped frozen bundle; the 7 runs keep the 2024 order with the L5/L12 kinds and headers", function()
	local session = newSession()
	local runs = session:runs()
	assert(#runs == 7)
	for k, r in runs do
		assert(r.id == RUN_IDS[k] and r.kind == KIND[r.id], "run " .. k)
		local canonicalHeader = SpringReplayView.HEADERS[r.kind]
		assert(canonicalHeader and string.sub(r.header, 1, #canonicalHeader) == canonicalHeader, "header of " .. r.id)
		assert(r.rowCount == 0)
	end
	assert(string.find(runs[1].header, "Live-captured native physics", 1, true) and string.find(runs[4].header, "0 coupling springs", 1, true))
	assert(session:rowCount() == 0 and #session:bars().t == 0 and session:drainChunk() == nil)
	local identity = session:identity()
	assert(SpringLiveSession.deepDiff(identity.pins, F.pins, "pins") == nil and identity.frozenResultSha256 == F.resultSha256)
	assert(identity.leadInRows == 0 and identity.planSha256 == PLAN and identity.fixturePass == true)
	local e = session:evidence()
	assert(e.marketEvidence == "forward_test_predeclared" and e.fixtureCheck.pass and e.implementationStatus == "pass")
	assert(e.physicsDependence == "fixtures_verified", "no forward-test action difference yet")
	local defaults = options()
	defaults.leadInRows = nil
	assert(SpringLiveSession.new(defaults).leadInRows == 2268, "default lead-in is the 2,268 calibration rows (L1)")
	assert(SpringLiveSession.new(options({ frozen = F })):rowCount() == 0)
end)

test("new fails closed: hex pins, frozen identity, engine config, describe(), options", function()
	local function tampered(edit) local c = deepCopy(F); edit(c); return deepFreeze(c) end
	raises(function() newSession({ frozen = deepCopy(F) }) end, "deep-frozen", "unfrozen copy")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.thresholds.entry = nextUp(c.calibration.thresholds.entry) end) }) end,
		"hex pin mismatch for entry", "entry one ulp up")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.thresholds.unclamped = nextUp(c.calibration.thresholds.unclamped) end) }) end,
		"hex pin mismatch for unclamped")
	raises(function() newSession({ frozen = tampered(function(c) c.baselineCalibration.thresholds.exit = nextUp(c.baselineCalibration.thresholds.exit) end) }) end,
		"hex pin mismatch for baseExit")
	raises(function() newSession({ frozen = tampered(function(c) c.frozenState.x[1] = nextUp(c.frozenState.x[1]) end) }) end,
		"hex pin mismatch for frozenState", "frozen state one ulp up")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.coordinates[17].std = nextUp(c.calibration.coordinates[17].std) end) }) end,
		"hex pin mismatch for calibrationStd")
	raises(function() newSession({ frozen = tampered(function(c) c.baselineCalibration.coordinates[2].std *= 1.5 end) }) end,
		"hex pin mismatch for baselineStd")
	raises(function() newSession({ frozen = tampered(function(c) c.pins.entry = string.rep("0", 16) end) }) end, "differs from the shipped SpringFrozenV1 pin")
	raises(function() newSession({ frozen = tampered(function(c) c.pins.extra = "00" end) }) end, "not a pinned key")
	raises(function() newSession({ frozen = tampered(function(c) c.resultSha256 = string.rep("0", 64) end) }) end, "not the pinned 2024 result")
	-- Identity fields, each refused by its own check (the bundle digest would refuse them too, with another message).
	raises(function() newSession({ frozen = tampered(function(c) c.schema = "spring-frozen-v2" end) }) end, "frozen schema must be spring-frozen-v1")
	raises(function() newSession({ frozen = tampered(function(c) c.protocolId = "spring-consensus-v2" end) }) end, "frozen protocol spring-consensus-v2")
	raises(function() newSession({ frozen = tampered(function(c) c.frozenState.sampleId = "coupled:13" end) }) end, "is not the first calibration sample")
	-- Deep-frozen means every nested table: a frozen top table over one unfrozen coordinate is refused.
	local shallow = deepCopy(F)
	local skip = shallow.calibration.coordinates[7]
	local function freezeExcept(t)
		for _, v in t do if type(v) == "table" and v ~= skip then freezeExcept(v) end end
		table.freeze(t)
	end
	freezeExcept(shallow)
	assert(table.isfrozen(shallow.calibration.coordinates) and not table.isfrozen(shallow.calibration.coordinates[7]))
	raises(function() newSession({ frozen = shallow }) end, "deep-frozen", "one nested table not frozen")
	-- Decision-determining fields that are not doubles: which nodes vote and which coordinates are active.
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.eligible[1] = { 1, 7 } end) }) end, "hex pin mismatch for eligible")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.eligible[2][2] = 10 end) }) end, "hex pin mismatch for eligible")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.coordinates[28].active = false end) }) end, "hex pin mismatch for active")
	-- Everything else is covered by the whole-bundle digest compiled into SpringLiveSession (checked last).
	local bundle = "differs from the digest compiled into SpringLiveSession"
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.thresholds.rank = 900 end) }) end, bundle, "thresholds.rank")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.n = 1500 end) }) end, bundle, "calibration.n")
	raises(function() newSession({ frozen = tampered(function(c) c.calibration.coordinates[3].mean += 0.5 end) }) end, bundle, "a calibration mean")
	raises(function() newSession({ frozen = tampered(function(c) c.frozenState.t += 300 end) }) end, bundle, "frozenState.t")
	raises(function() newSession({ frozen = tampered(function(c) c.nativeConfig2024.schema ..= "x" end) }) end, "engine config differs", "frozen native config")
	raises(function() newSession({ frozen = tampered(function(c) c.sources.generator = "hand-edited" end) }) end, bundle, "sources")
	raises(function() newSession({ frozen = tampered(function(c)
		local rows = c.rowDigests2024.rows
		c.rowDigests2024.rows = string.sub(rows, 1, 99) .. (if string.sub(rows, 100, 100) == "0" then "1" else "0") .. string.sub(rows, 101)
	end) }) end, bundle, "one 2024 row digest character")
	raises(function() newSession({ frozen = tampered(function(c) c.rowDigests2024.scheme = "other" end) }) end, "rowDigests2024 must use")
	raises(function() newSession({ frozen = tampered(function(c) c.rowDigests2024.sessions[3].first += 1 end) }) end, "sessions must cover")
	raises(function() newSession({ frozen = tampered(function(c) c.rowDigests2024.rows ..= "00000000" end) }) end, "8 lowercase hex characters per row")
	raises(function() newSession({ frozen = tampered(function(c) c.descriptor.nodes[2].omega = 99 end) }) end,
		"describe() differs from the frozen 2024 descriptor", "tampered frozen descriptor")
	local config = deepCopy(CONFIG); config.nodes[5].k += 1e-9
	raises(function() newSession({ engineConfig = config }) end, "engineConfig.nodes.5.k", "rig stiffness changed")
	local extra = deepCopy(CONFIG); extra.liveOnly = true
	raises(function() newSession({ engineConfig = extra }) end, "engine config differs", "extra config key")
	local rail = deepCopy(CONFIG); rail.railLimit = nil
	raises(function() newSession({ engineConfig = rail }) end, "railLimit", "missing config key")
	local swapped = table.clone(DRIVE); swapped[1], swapped[2] = swapped[2], swapped[1]
	raises(function() newSession({ driveNames = swapped }) end, "describe rejected", "drive names out of order")
	raises(function() newSession({ planSha256 = string.upper(PLAN) }) end, "planSha256")
	raises(function() newSession({ planSha256 = string.sub(PLAN, 2) }) end, "planSha256")
	raises(function() newSession({ leadInRows = -1 }) end, "leadInRows")
	raises(function() newSession({ leadInRows = 1.5 }) end, "leadInRows")
	raises(function() newSession({ saved2024 = {} }) end, "saved2024")
	raises(function() newSession({ runId = "bad id!" }) end, "runId")
	raises(function() newSession({ liveRows = 3 }) end, "unknown option")
	raises(function() SpringLiveSession.new(nil) end, "options table")
end)

test("the fixture self-check: the shipped calibration passes it (BUY/SELL at 13, CLOSE at 16); the export is not a hook", function()
	local p = require("../src/SpringPolicy").protocol()
	local check = SpringLiveSession.fixtureCheck(F.calibration, F.descriptor, p)
	assert(check.pass and check.positive.entryAt == 13 and check.positive.entryAction == "BUY" and check.negative.entryAction == "SELL")
	assert(check.positive.closeAt == 16 and check.zeroStreamEntries == 0)
	local unavailable = deepCopy(F.calibration)
	unavailable.available = false
	assert(SpringLiveSession.fixtureCheck(deepFreeze(unavailable), F.descriptor, p).pass == false)
	-- new() calls its own local copy: replacing the exported field changes nothing. (A drifted SpringSignals that fails
	-- the self-check is refused in tests/SpringLiveSession.test.mjs, which loads a deliberately broken copy.)
	local real = SpringLiveSession.fixtureCheck
	SpringLiveSession.fixtureCheck = function() return { pass = false } end
	local ok, session = pcall(newSession)
	SpringLiveSession.fixtureCheck = real
	assert(ok and session:evidence().fixtureCheck.pass == true, tostring(session))
end)

test("spring-pack-1 and spring-row-digest-1 equal make-spring-frozen.mjs byte for byte (known answers computed in Node)", function()
	local function hex(s) return (string.gsub(s, ".", function(ch) return string.format("%02x", string.byte(ch)) end)) end
	assert(hex(SpringLiveSession.packValue({ a = { 1, -0.5, true }, b = "hi", c = {} }))
		== "6d0300000073010000006161030000006e000000000000f03f6e000000000000e0bf74730100000062730200000068697301000000636d00000000")
	local row = { ok = true, rs = "x", s = -0, b = { 0.25, -1.5, 3 }, ia = "BUY", is = "physics", ir = "confirmed_positive_setup", fa = "HOLD",
		fs = "risk", fr = "risk_not_ready", ov = true, rc = { "risk_not_ready", "invalid_risk_volatility" }, po = 0, hb = 0, eq = 1, st = { 13, 2, 0, 0, 0 },
		ex = { { t = 1743168600, a = "BUY", sd = 1, p = 100.05, r = "confirmed_positive_setup", s = "physics", st = 1743168300 } } }
	assert(SpringLiveSession.rowDigest(row) == "d657ac45" and SpringLiveSession.actionDigest(row) == "4fe06f98")
	local positive = table.clone(row); positive.s = 0
	assert(SpringLiveSession.rowDigest(positive) == "d657ac45", "row digests ignore the sign of zero (JSON cannot keep it)")
	local changed = table.clone(row); changed.s = 1e-300
	assert(SpringLiveSession.rowDigest(changed) ~= "d657ac45" and SpringLiveSession.actionDigest(changed) == "4fe06f98",
		"a diagnostic changes the row digest, not the action digest")
	local moved = table.clone(row); moved.eq = 1.0000000001
	assert(SpringLiveSession.actionDigest(moved) ~= "4fe06f98")
	assert(SpringLiveSession.rangeDigest({ row, row, positive }, 1, 1) ~= SpringLiveSession.rangeDigest({ row, row, positive }, 1, 3))
	raises(function() SpringLiveSession.packValue({ [2] = 1 }) end, "map keys must be strings")
end)

test("lead-in rows step with the flat context, show intents and are never traded (L2)", function()
	local session = run(newSession({ leadInRows = 20 }), 1, 20, 1)
	for _, id in RUN_IDS do
		for i, r in session:rows(id) do
			assert(r.fa == "HOLD" and r.fr == "lead_in_not_traded" and r.fs == "lead_in", id .. " row " .. i .. " final")
			assert(r.po == 0 and r.eq == 1 and r.hb == 0 and r.ex == nil and r.pe == nil and r.sp == nil, id .. " row " .. i .. " ledger")
			assert(session:displayRow(id, i).partition == "calibration_lead_in")
		end
	end
	local rows = session:rows("coupled")
	assert(rows[12].ia == "HOLD" and rows[12].ir == "positive_setup_unconfirmed" and rows[12].ov == nil and rows[12].rc == nil)
	assert(rows[13].ia == "BUY" and rows[13].is == "physics" and rows[13].ir == "confirmed_positive_setup", "intent shown at warm-up + 1")
	assert(rows[13].ov == true and rows[13].rc[1] == "lead_in_not_traded" and #rows[13].rc == 1)
	local buys = 0
	for _, r in rows do if r.ia == "BUY" then buys += 1 end end
	assert(buys == 4, "flat context: a BUY intent every second row from 13 (" .. buys .. ")")
	for _, r in session:rows("zero") do assert(r.ia == "HOLD" and r.s == 0) end
	local shown = session:displayRow("coupled", 13)
	assert(shown.intent.action == "BUY" and shown.final.action == "HOLD" and shown.final.overridden == true)
	assert(shown.final.riskConditions[1] == "lead_in_not_traded" and shown.equity == 1 and shown.position == 0)
	local summary = session:summary()
	assert(next(summary.runs) == nil and summary.phase == "calibration_lead_in" and summary.primaryCriterion == nil)
	assert(#session:trades("coupled") == 0)
	local e = session:evidence()
	assert(e.leadInRows == 20 and e.forwardRows == 0 and e.physicsDependenceCounts.denominatorRows == 0)
	local c = session:comparisons().coupled_vs_zero
	assert(c.calibration_lead_in.emittedActionDifferences == 4 and c.forward_test.rows == 0 and c.all.rows == 20)
	assert(e.physicsDependence == "fixtures_verified", "4 lead-in coupled-vs-zero differences never count as forward-test dependence")
	assert(e.physicsDependenceCounts.coupledVsZeroEmittedActionDifferences == 0 and e.physicsDependenceCounts.coupledPhysicsActionsEmitted == 0)
	-- Forward rows without a coupled-vs-zero difference keep fixtures_verified; the lead-in differences stay out.
	local quiet = run(run(newSession({ leadInRows = 20 }), 1, 20, 1), 21, 26, 0)
	assert(quiet:evidence().physicsDependence == "fixtures_verified" and quiet:comparisons().coupled_vs_zero.all.emittedActionDifferences == 4)
	raises(function() session:rows("coupled")[1].fa = "BUY" end, nil, "rows are read-only")
	-- bar.t must increase strictly in the lead-in too (no ledger there to refuse a repeated bar).
	local repeated = run(newSession({ leadInRows = 20 }), 1, 3, 1)
	raises(function() repeated:step(input(3, 1)) end, "bar.t must increase strictly", "repeated lead-in bar")
	assert(repeated.failed and repeated:rowCount() == 3)
end)

test("the lead-in/forward boundary row: count == leadInRows is still the lead-in for context, chunks and summary", function()
	local session = run(newSession({ leadInRows = 10 }), 1, 10, 1)
	local ctx = session:context("coupled", "zero")
	assert(ctx.comparisonScope == "calibration_lead_in" and ctx.comparisons.rows == 10, "scope at the last lead-in row")
	assert(session:summary().phase == "calibration_lead_in" and next(session:summary().runs) == nil)
	local chunk = session:drainChunk()
	assert(chunk.atEnd.phase == "calibration_lead_in" and next(chunk.atEnd.equity) == nil and chunk.lastIndex == 10)
	run(session, 11, 11, 1)
	local after = session:context("coupled", "zero")
	assert(after.comparisonScope == "forward_test" and after.comparisons.rows == 1)
	assert(session:drainChunk().atEnd.phase == "forward_test" and session:summary().phase == "forward_test")
	assert(session:partitionOf(10) == "calibration_lead_in" and session:partitionOf(11) == "forward_test")
end)

test("the boundary resets every machine and opens flat ledgers at equity 1 (L2)", function()
	-- Flat lead-in: BUY at 13 and 15; row 16 ends with posConfirm 1. After resetBoundary() row 17 confirms from 0 again.
	local session = run(newSession({ leadInRows = 16 }), 1, 30, 1)
	local rows = session:rows("coupled")
	assert(rows[16].st[2] == 1 and rows[16].fa == "HOLD" and session:displayRow("coupled", 16).partition == "calibration_lead_in")
	assert(rows[17].ia == "HOLD" and rows[17].ir == "positive_setup_unconfirmed" and rows[17].st[2] == 1,
		"row 17 must confirm from 0 after the reset (a missing reset gives BUY here)")
	assert(rows[18].ia == "BUY" and rows[18].fa == "BUY" and rows[18].pe and rows[18].pe.a == "BUY", "first traded entry")
	assert(rows[19].po == 1 and rows[19].ex and rows[19].ex[1].a == "BUY" and rows[19].ex[1].t == bar(19).t, "fills at the next open")
	assert(session:displayRow("coupled", 17).partition == "forward_test")
	for _, id in RUN_IDS do
		local r = session:rows(id)[17]
		assert(r.eq == 1 and r.po == 0 and r.fr ~= "lead_in_not_traded", id .. " opens flat at equity 1")
	end
	assert(rows[17].st[1] == 17, "warm-up is kept across the boundary (resetBoundary keeps the warm-up count)")
	local summary = session:summary()
	assert(summary.runs.coupled.rows == 14 and summary.runs.coupled.firstT == bar(17).t and summary.forwardRows == 14)
	assert(summary.runs.no_trade.netReturn == 0 and summary.runs.zero.tradeCount == 0)
end)

test("one continuous forward ledger; quarter and year returns are equity ratios of it (L7) and the L6 criterion", function()
	local session = run(newSession({ leadInRows = 0 }), 1, 80, function(i) return if i <= 40 then 1 elseif i <= 60 then -1 else 0.2 end)
	local summary = session:summary()
	local net = summary.runs.coupled.netReturn
	assert(summary.runs.coupled.tradeCount > 0 and #session:trades("coupled") == summary.runs.coupled.tradeCount)
	local quarters, years = summary.periods.coupled.quarters, summary.periods.coupled.years
	assert(#quarters == 2 and quarters[1].key == "2025-Q1" and quarters[2].key == "2025-Q2" and #years == 1 and years[1].key == "2025")
	assert(quarters[1].rows == 40 and quarters[2].rows == 40 and quarters[1].firstIndex == 1 and quarters[2].firstIndex == 41)
	assert(quarters[1].startEquity == 1 and quarters[2].startEquity == quarters[1].endEquity)
	local chained = (1 + quarters[1].netReturn) * (1 + quarters[2].netReturn) - 1
	assert(math.abs(chained - net) < 1e-12 and math.abs(years[1].netReturn - net) < 1e-15, "sub-periods chain to the whole ledger")
	assert(math.abs(quarters[2].endEquity - summary.runs.coupled.finalEquity) < 1e-15)
	local criterion = summary.primaryCriterion
	assert(criterion.coupledNetReturn == net and criterion.noTradeNetReturn == 0 and criterion.emaBaselineNetReturn == summary.runs.ema_baseline.netReturn)
	assert(criterion.edgeClaimed == (net > 0 and net > summary.runs.ema_baseline.netReturn) and criterion.forwardRows == 80)
	for _, t in session:trades("coupled") do assert(t.entrySource == "physics" or t.entrySource == "risk") end
	-- No lead-in here: the L20 gate is not checked and says so beside the headline.
	assert(criterion.leadInValidation.decisionRows.status == "not_checked" and criterion.leadInValidation.states.status == "not_checked")
end)

test("L6 criterion: an edge needs coupled > no-trade AND coupled > ema_baseline", function()
	local claim = SpringLiveSession.edgeClaimed
	assert(claim(0.02, 0, 0.01) == true)
	assert(claim(-0.01, 0, -0.03) == false, "coupled above the EMA baseline but below no-trade")
	assert(claim(0.01, 0, 0.02) == false, "coupled above no-trade but below the EMA baseline")
	assert(claim(0, 0, -0.01) == false and claim(0.01, 0, 0.01) == false, "ties are not an edge")
	assert(claim(-0.02, -0.03, -0.04) == true, "the bar is no-trade's own net return, whatever it is")
	-- The session's headline uses it: a falling path where coupled loses less than the EMA baseline (see fixture below).
	local session = newSession({ leadInRows = 0 })
	for i = 1, 80 do
		session:step(input(i, if i <= 40 then 1 else -1, function(v)
			-- prices fall 0.05 per bar with a whipsaw every third bar
			local base = 104 - 0.05 * i + (if i % 3 == 0 then 0.4 else 0)
			local o = 104 - 0.05 * (i - 1) + (if (i - 1) % 3 == 0 then 0.4 else 0)
			v.bar.o, v.bar.c = o, base
			v.bar.h, v.bar.l = math.max(o, base) + 0.02, math.min(o, base) - 0.02
		end))
	end
	local c = session:summary().primaryCriterion
	assert(c.edgeClaimed == claim(c.coupledNetReturn, c.noTradeNetReturn, c.emaBaselineNetReturn))
	assert(c.coupledNetReturn < 0 and c.coupledNetReturn > c.emaBaselineNetReturn and c.edgeClaimed == false,
		string.format("fixture: coupled %.6g, ema %.6g", c.coupledNetReturn, c.emaBaselineNetReturn))
end)

test("displayRow goes through SpringStudy.displayRow with the live partition; every run passes the replay validation", function()
	local session = run(newSession({ leadInRows = 10 }), 1, 20, 1)
	for _, index in { 5, 15 } do
		for _, id in RUN_IDS do
			local r = session:displayRow(id, index)
			assert(SpringReplayView.validateRow(r, F.descriptor) == nil, id .. ": " .. tostring(SpringReplayView.validateRow(r, F.descriptor)))
			assert(r.runId == id and r.runKind == KIND[id] and r.index == index and r.t == bar(index).t and r.label == bar(index).label)
			assert(r.availableT == bar(index).availableT and r.availableT ~= r.t and r.day == bar(index).day, id .. " timeline availableT and day")
			assert(r.partition == (if index <= 10 then "calibration_lead_in" else "forward_test"))
			assert(r.evidence.marketEvidence == "forward_test_predeclared")
		end
	end
	local coupled, frozen, zero = session:displayRow("coupled", 15), session:displayRow("frozen", 15), session:displayRow("zero", 15)
	local n = CAL.eligible[1][1]
	assert(coupled.x[n] == r6(2 * CAL.coordinates[n].std) and coupled.sampleId == "coupled:15")
	for i = 1, 24 do
		assert(frozen.x[i] == r6(F.frozenState.x[i]) and frozen.v[i] == r6(F.frozenState.v[i]) and zero.x[i] == 0)
	end
	assert(session:displayRow("ema_baseline", 15).x == nil and session:displayRow("no_trade", 15).x == nil)
	raises(function() session:displayRow("coupled", 21) end, "not decided yet")
	raises(function() session:displayRow("live", 1) end, "unknown run")
	local columns = session:bars()
	assert(#columns.t == 20 and columns.c[20] == bar(20).c and columns.o[1] == bar(1).o and columns.h[7] == bar(7).h and columns.l[9] == bar(9).l)
	local ctx = session:context("coupled", "zero")
	assert(ctx.rowCount == 20 and ctx.comparisonScope == "forward_test" and ctx.comparisons.rows == 10 and ctx.evidence.marketEvidence == "forward_test_predeclared")
	assert(ctx.provenance.plan == string.sub(PLAN, 1, 8))
	assert(session:context("zero", "coupled").comparisons.rows == 10 and session:context("coupled", "coupled").comparisons == nil)
	local early = run(newSession({ leadInRows = 10 }), 1, 5, 1):context("coupled", "ema_baseline")
	assert(early.comparisonScope == "calibration_lead_in" and early.comparisons.rows == 5)
end)

test("the frozen comparator is the full-precision record 12 state, not the 6-digit display copy (L5)", function()
	local exact = 0
	for i = 1, 24 do if F.frozenState.x[i] ~= r6(F.frozenState.x[i]) then exact += 1 end end
	assert(exact > 0, "SpringFrozenV1 carries full-precision x")
	local packed = table.create(48)
	for i = 1, 24 do packed[i] = F.frozenState.x[i]; packed[24 + i] = F.frozenState.v[i] end
	assert(SpringLiveSession.hexDoubles(packed) == F.pins.frozenState and F.frozenState.sampleId == "coupled:12" and F.frozenState.recordIndex == 12)
	assert(F.calibration.firstSampleId == "coupled:12")
end)

test("drainChunk carries exact inputs and only the four stored runs; nothing new gives nil (L10)", function()
	local session = run(newSession({ leadInRows = 5, runId = "fixture-run" }), 1, 12, 1)
	local chunk = session:drainChunk()
	assert(chunk.schema == "roalgo-spring-live-chunk-1" and chunk.seq == 1 and chunk.runId == "fixture-run" and chunk.planSha256 == PLAN)
	assert(chunk.firstIndex == 1 and chunk.lastIndex == 12 and chunk.count == 12 and chunk.leadInRows == 5 and chunk.frozenResultSha256 == F.resultSha256)
	assert(#chunk.bars == 12 and #chunk.features == 12)
	for i, b in chunk.bars do
		local keys = 0
		for _ in b do keys += 1 end
		assert(keys == 8 and canonical(b) == canonical(bar(i)), "bar " .. i .. " carries the 8 display fields")
		local f = chunk.features[i]
		assert(f.reset == (i == 1) and f.ready == (i >= 12) and f.volatility == 0.001 and #f.drive == 8 and f.volatilityHex == nil)
	end
	local expected = SpringLiveSession.hexDoubles(vector(1))
	for _, variant in { "coupled", "independent", "numeric" } do
		assert(#chunk.states[variant] == 12)
		for _, h in chunk.states[variant] do assert(h == expected and #h == 816, variant .. " state is the exact 51 doubles in hex") end
	end
	local runs = {}
	for id, rows in chunk.rows do
		runs[#runs + 1] = id
		assert(STORED[id] and #rows == 12, "stored run " .. id)
		for i, r in rows do assert(canonical(r) == canonical(session:rows(id)[i])) end
	end
	assert(#runs == 4, "rows only for coupled, independent, numeric and ema_baseline")
	for _, id in { "zero", "frozen", "no_trade" } do assert(chunk.rows[id] == nil) end
	-- checks for all 7 runs: the digest is the spring-row-digest-1 combination of every row digest in the chunk, and
	-- the action and fill counts are those of the rows (recounted here independently).
	local function fnv(h, text)
		for k = 1, #text do h = bit32.bxor(h, string.byte(text, k)); h = (bit32.lshift(h, 24) + h * 403) % 4294967296 end
		return h
	end
	local function unhex(h) return (string.unpack("<d", (string.gsub(h, "%x%x", function(x) return string.char(tonumber(x, 16)) end)))) end
	local function verify(c)
		for _, id in RUN_IDS do
			local parts, actions, fills = {}, 0, 0
			for i = c.firstIndex, c.lastIndex do
				local r = session:rows(id)[i]
				parts[#parts + 1] = string.pack("<I4", tonumber(SpringLiveSession.rowDigest(r), 16))
				if r.fa ~= "HOLD" then actions += 1 end
				fills += if r.ex then #r.ex else 0
			end
			local check = c.checks[id]
			assert(check.digest == string.format("%08x", fnv(2166136261, table.concat(parts))), id .. " checks.digest covers every row")
			assert(check.finalActions == actions and check.fills == fills, id .. " checks counts")
		end
		-- End equities: exact doubles of each run's ledger equity after the chunk's last row.
		local summary = session:summary()
		for _, id in RUN_IDS do
			assert(type(c.atEnd.equity[id]) == "string" and #c.atEnd.equity[id] == 16)
			assert(unhex(c.atEnd.equity[id]) == summary.runs[id].finalEquity, id .. " end equity")
		end
	end
	verify(chunk)
	assert(chunk.atEnd.phase == "forward_test" and chunk.atEnd.rows == 12)
	assert(session:drainChunk() == nil, "a second drain has nothing new")
	run(session, 13, 15, 1)
	local second = session:drainChunk()
	assert(second.seq == 2 and second.firstIndex == 13 and second.lastIndex == 15 and #second.bars == 3)
	verify(second)
	assert(second.checks.coupled.fills > 0 and second.checks.coupled.finalActions > 0, "the fixture trades, so the counts are exercised")
	assert(unhex(second.atEnd.equity.coupled) ~= 1, "the coupled ledger moved")
	local early = run(newSession({ leadInRows = 20 }), 1, 3, 1):drainChunk()
	assert(next(early.atEnd.equity) == nil and early.atEnd.phase == "calibration_lead_in", "no ledger equity during the lead-in")
end)

local function regenerationFixture()
	local session = newSession({ leadInRows = 25, runId = "fixture-run" })
	local chunks = {}
	for i = 1, 60 do
		session:step(input(i, if i <= 30 then 1 elseif i <= 45 then -1 else 0.1))
		if i % 20 == 0 then chunks[#chunks + 1] = session:drainChunk() end
	end
	return session, chunks
end

test("regenerate rebuilds all seven runs exactly from the chunks, including zero, frozen and no_trade (L10)", function()
	local original, chunks = regenerationFixture()
	local copies = deepCopy(chunks) -- what a JSON round trip hands back: plain, unfrozen tables
	local session, report = SpringLiveSession.regenerate(options({ leadInRows = 25, runId = "fixture-run" }), copies)
	assert(report.pass == true and report.chunks == 3 and report.rows == 60 and report.totalRowDifferences == 0, canonical(report))
	assert(#report.chunkFieldMismatches == 0 and #report.problems == 0)
	for _, id in RUN_IDS do
		for i = 1, 60 do assert(canonical(session:rows(id)[i]) == canonical(original:rows(id)[i]), id .. " row " .. i) end
	end
	assert(canonical(session:summary()) == canonical(original:summary()) and canonical(session:comparisons()) == canonical(original:comparisons()))
	assert(original:summary().runs.coupled.tradeCount > 0, "the fixture trades, so the ledgers are exercised")
end)

test("regenerate reports tampered rows, states, digests, equities, order and plan", function()
	local _, chunks = regenerationFixture()
	local function regenerate(edit, over)
		local copies = deepCopy(chunks)
		edit(copies)
		local _, report = SpringLiveSession.regenerate(options(over or { leadInRows = 25, runId = "fixture-run" }), copies)
		return report
	end
	local function has(list, needle) for _, s in list do if string.find(s, needle, 1, true) then return true end end return false end
	local r = regenerate(function(c) c[2].rows.coupled[3].s += 1e-6 end)
	assert(not r.pass and r.rowDifferences.coupled == 1 and r.totalRowDifferences == 1 and r.firstDifference.index == 23 and has(r.chunkFieldMismatches, "chunk 2 rows"))
	r = regenerate(function(c) local h = c[1].states.coupled[18]; c[1].states.coupled[18] = string.sub(h, 1, 14) .. "40" .. string.sub(h, 17) end)
	assert(not r.pass and r.rowDifferences.coupled >= 1 and r.firstDifference.index == 18, "a changed exact state changes the decision rows")
	r = regenerate(function(c) c[3].checks.zero.digest = "00000000" end)
	assert(not r.pass and r.totalRowDifferences == 0 and has(r.chunkFieldMismatches, "chunk 3 checks"), "regenerated-run digest")
	r = regenerate(function(c) c[3].atEnd.equity.frozen = string.rep("0", 16) end)
	assert(not r.pass and has(r.chunkFieldMismatches, "chunk 3 atEnd"))
	-- Forward-test volatility sets the stop and target of every entry, so a changed saved volatility changes rows.
	r = regenerate(function(c) for _, f in c[2].features do f.volatility = 0.002 end end)
	assert(not r.pass and r.rowDifferences.coupled >= 1 and r.firstDifference.index > 25, "saved forward-test volatility")
	r = regenerate(function(c) c[2], c[3] = c[3], c[2] end)
	assert(not r.pass and #r.problems == 1 and string.find(r.problems[1], "seq", 1, true))
	r = regenerate(function() end, { leadInRows = 25, runId = "fixture-run", planSha256 = string.rep("f", 64) })
	assert(not r.pass and string.find(r.problems[1], "plan", 1, true))
	r = regenerate(function() end, { leadInRows = 24, runId = "fixture-run" })
	assert(not r.pass and string.find(r.problems[1], "leadInRows", 1, true))
	r = regenerate(function(c) table.remove(c[1].rows.ema_baseline) end)
	assert(not r.pass and string.find(r.problems[1], "ema_baseline", 1, true))
	-- A chunk that does not start where the previous one ended (same seq) is a problem, not a silent re-alignment.
	r = regenerate(function(c) c[2].firstIndex += 1 end)
	assert(not r.pass and #r.problems == 1 and string.find(r.problems[1], "chunk 2 starts at 22, expected 21", 1, true), canonical(r.problems))
	-- Malformed content is reported in problems; regenerate never throws at its caller.
	r = regenerate(function(c) c[1].states.coupled[3] = "zz" end)
	assert(not r.pass and string.find(r.problems[1], "chunk 1:", 1, true) and string.find(r.problems[1], "lowercase hex", 1, true))
	r = regenerate(function(c) c[2].features[4].driveHex = "00"; c[2].features[4].drive = nil end)
	assert(not r.pass and string.find(r.problems[1], "chunk 2:", 1, true))
	r = regenerate(function(c) c[3].bars[5].h = c[3].bars[5].c - 1 end)
	assert(not r.pass and string.find(r.problems[1], "chunk 3 row 5:", 1, true) and r.chunks == 2, canonical(r.problems))
	r = regenerate(function(c) c[1].bars[2].label = nil end)
	assert(not r.pass and string.find(r.problems[1], "chunk 1 row 2:", 1, true))
end)

test("missing and invalid variants and non-finite features are stored exactly and replay to the same rows", function()
	local NAN = 0 / 0
	local edits = {
		[14] = function(v) v.states.independent = nil end,
		[15] = function(v) v.states.numeric = { names = {}, vector = vector(1) } end,
		[16] = function(v) v.states.coupled.vector[3] = NAN end,
		[17] = function(v) v.states.numeric.vector[51] = nil end,
		[18] = function(v) v.feature.volatility = NAN end,
		[19] = function(v) v.feature.drive[4] = math.huge end,
	}
	local session = run(newSession({ leadInRows = 0 }), 1, 24, 1, edits)
	assert(session:rows("independent")[14].ok == false and session:rows("independent")[14].rs == "missing_variant")
	assert(session:rows("numeric")[15].rs == "names_mismatch" and session:rows("coupled")[16].rs == "non_finite_state")
	assert(session:rows("numeric")[17].rs == "malformed_vector" and session:rows("coupled")[17].ok == true)
	assert(session:displayRow("independent", 14).x == nil and SpringReplayView.validateRow(session:displayRow("independent", 14), F.descriptor) == nil)
	local chunk = session:drainChunk()
	assert(chunk.states.independent[14] == false and chunk.states.numeric[15].invalid == "names_mismatch")
	assert(chunk.states.numeric[17].invalid == "malformed_vector" and type(chunk.states.coupled[16]) == "string")
	assert(chunk.features[18].volatility == nil and chunk.features[18].volatilityHex == SpringLiveSession.hexDouble(NAN))
	assert(chunk.features[19].drive == nil and #chunk.features[19].driveHex == 128)
	local _, report = SpringLiveSession.regenerate(options({ leadInRows = 0 }), { deepCopy(chunk) })
	assert(report.pass and report.totalRowDifferences == 0, canonical(report))
end)

test("a failed step aborts the session for good; committed rows still drain (L4)", function()
	local session = run(newSession({ leadInRows = 0 }), 1, 3, 1)
	raises(function() session:step(input(3, 1)) end, "increase strictly", "repeated bar")
	assert(session.failed and session:rowCount() == 3)
	raises(function() session:step(input(4, 1)) end, "failed earlier", "no resume after a failure")
	local chunk = session:drainChunk()
	assert(chunk.count == 3 and chunk.lastIndex == 3)
	local broken = run(newSession({ leadInRows = 0 }), 1, 3, 1)
	raises(function() broken:step(input(4, 1, function(v) v.bar.h = v.bar.c - 1 end)) end, "consistent OHLC", "ledger refusal")
	assert(broken:rowCount() == 3 and #broken:rows("coupled") == 3 and #broken:bars().t == 3, "nothing of the failed bar is committed")
	raises(function() broken:step(input(4, 1)) end, "failed earlier")
end)

test("input fences: only the 8 bar fields and 4 feature fields; strict types", function()
	local cases = {
		{ "bar contexts", function(v) v.bar.contexts = {} end, "bar field 'contexts'" },
		{ "feature raw", function(v) v.feature.raw = {} end, "feature field 'raw'" },
		{ "extra input key", function(v) v.record = {} end, "input field 'record'" },
		{ "day format", function(v) v.bar.day = "2025/03/28" end, "YYYY-MM-DD" },
		{ "missing label", function(v) v.bar.label = nil end, "label" },
		{ "7 drive values", function(v) v.feature.drive[8] = nil end, "drive" },
		{ "ready not boolean", function(v) v.feature.ready = 1 end, "booleans" },
		{ "missing availableT", function(v) v.bar.availableT = nil end, "availableT" },
		{ "states missing", function(v) v.states = nil end, "states" },
	}
	for _, case in cases do
		local session = newSession()
		raises(function() session:step(input(1, 1, case[2])) end, case[3], case[1])
		assert(session:rowCount() == 0)
	end
end)

test("reproducibility compares lead-in states with saved2024: numeric exact, native within 0.002 (L3b)", function()
	local function saved(perturb)
		return function(i)
			local s = { index = i, t = bar(i).t, reset = i == 1, drive = { 0, 0, 0, 0, 0, 0, 0, 0 },
				coupled = vector(1), independent = vector(1), numeric = vector(1) }
			if perturb then perturb(i, s) end
			return s
		end
	end
	local function check(perturb) return run(newSession({ leadInRows = 10, saved2024 = saved(perturb) }), 1, 12, 1):reproducibility() end
	local exact = check(nil)
	assert(exact.status == "pass" and exact.pass and exact.compared == 10 and exact.maxAbs.coupled == 0 and exact.maxAbs.numeric == 0 and exact.drivesExact)
	local close = check(function(i, s) if i == 5 then s.coupled[1] += 0.001 end end)
	assert(close.pass and math.abs(close.maxAbs.coupled - 0.001) < 1e-12 and close.maxAbsXV.coupled == close.maxAbs.coupled)
	local edge = check(function(i, s) if i == 5 then s.coupled[2] = 0.002 end end)
	assert(edge.pass and edge.maxAbs.coupled == 0.002, "0.002 itself is within the tolerance")
	local over = check(function(i, s) if i == 5 then s.coupled[2] = 0.0021 end end)
	assert(not over.pass and over.status == "differs" and over.firstExceeded.index == 5, "0.0021 is outside the 0.002 tolerance")
	local far = check(function(i, s) if i == 5 then s.independent[30] += 0.003 end end)
	assert(far.status == "differs" and not far.pass and far.firstExceeded.index == 5 and far.firstExceeded.variant == "independent")
	assert(far.label == "re-captured physics differs from the 2024 calibration capture")
	local numeric = check(function(i, s) if i == 7 then s.numeric[50] += 1e-12 end end)
	assert(not numeric.pass and numeric.maxAbsXV.numeric == 0 and numeric.maxAbs.numeric > 0, "numeric must match exactly, energies included")
	local missing = check(function(i, s) if i == 3 then s.coupled = nil end end)
	assert(not missing.pass and missing.invalidLive == 1)
	local shifted = check(function(i, s) if i == 4 then s.t += 300 end end)
	assert(not shifted.pass and shifted.tMismatches == 1)
	local drive = check(function(i, s) if i == 2 then s.drive[3] = 0.5 end end)
	assert(drive.pass and drive.drivesExact == false and drive.maxAbsDrive == 0.5, "drives are reported, the L3 gate is on the state vectors")
	-- L20 reports dx and dv per variant; bank energies are reported separately (the 0.002 gate is on all 51 entries).
	local split = check(function(i, s)
		if i == 3 then s.coupled[2] += 0.0011 end
		if i == 6 then s.coupled[30] -= 0.0007; s.independent[24] += 0.0004 end
		if i == 8 then s.numeric[49] += 0.0003; s.independent[51] += 0.0019 end
	end)
	local function near(a, b) return math.abs(a - b) < 1e-12 end
	assert(near(split.maxAbsX.coupled, 0.0011) and near(split.maxAbsV.coupled, 0.0007) and split.maxAbsEnergy.coupled == 0)
	assert(near(split.maxAbsX.independent, 0.0004) and split.maxAbsV.independent == 0 and near(split.maxAbsEnergy.independent, 0.0019))
	assert(split.maxAbsX.numeric == 0 and split.maxAbsV.numeric == 0 and near(split.maxAbsEnergy.numeric, 0.0003))
	assert(near(split.maxAbsXV.coupled, 0.0011) and near(split.maxAbsXV.independent, 0.0004) and near(split.maxAbs.independent, 0.0019))
	assert(split.status == "differs" and split.firstExceeded.variant == "numeric" and split.firstExceeded.index == 8, "numeric energies must match exactly")
	-- The native 0.002 gate covers all 51 readouts, energies included (the v2 replay probes defined it that way).
	local energy = check(function(i, s) if i == 9 then s.coupled[49] += 0.003 end end)
	assert(energy.status == "differs" and energy.maxAbsXV.coupled == 0 and near(energy.maxAbsEnergy.coupled, 0.003), canonical(energy.maxAbsEnergy))
	-- The saved record's own index and reset must agree with the live row.
	local index = check(function(i, s) if i == 3 then s.index = 4 end end)
	assert(not index.pass and index.status == "differs" and index.indexMismatches == 1 and index.resetMismatches == 0)
	local reset = check(function(i, s) if i == 4 then s.reset = true end end)
	assert(not reset.pass and reset.status == "differs" and reset.resetMismatches == 1 and reset.indexMismatches == 0)
	local partial = run(newSession({ leadInRows = 10, saved2024 = saved(nil) }), 1, 4, 1):reproducibility()
	assert(partial.status == "in_progress" and partial.compared == 4)
	assert(run(newSession({ leadInRows = 10 }), 1, 2, 1):reproducibility().status == "not_checked")
	local throwing = newSession({ leadInRows = 10, saved2024 = function() error("page fetch failed") end })
	raises(function() throwing:step(input(1, 1)) end, "page fetch failed")
	assert(throwing.failed)
end)

test("L20 decision-row gate: a leadInRows=0 shadow decides the lead-in and is compared with the 2024 row digests", function()
	local none = run(newSession({ leadInRows = 0 }), 1, 3, 1)
	local r0 = none:reproducibility().decisionRows
	assert(r0.status == "not_checked" and r0.compared == 0 and r0.target == 0 and none.shadow == nil, "no lead-in, no shadow")
	-- Synthetic rows are not the 2024 rows: every full compact row differs (scores), while the decision and ledger
	-- fields of these warm-up rows (HOLD, flat, equity 1) equal the 2024 ones.
	local session = newSession({ leadInRows = 10 })
	assert(session.shadow ~= nil)
	run(session, 1, 4, 1)
	local mid = session:reproducibility()
	assert(mid.status == "not_checked" and mid.decisionRows.status == "in_progress" and mid.decisionRows.compared == 4, canonical(mid.decisionRows))
	run(session, 5, 12, 1)
	local d = session:reproducibility().decisionRows
	assert(d.status == "differs" and d.compared == 10 and d.target == 10 and d.expectedRows == 2268, canonical(d))
	assert(d.rowDifferences == 10 and d.firstDifferentRow == 1, canonical(d))
	assert(d.actionRowDifferences == 0 and d.firstActionDifferentRow == nil, canonical(d))
	assert(d.sessionsCompared == 0 and d.sessionsDiffering.coupled == 0, "the first 2024 session has 78 rows")
	assert(string.find(d.label, "10 of 10 lead-in rows differ from the offline 2024 result", 1, true), d.label)
	assert(session.shadow == nil, "the shadow is released after the last lead-in row")
	-- Past the warm-up the synthetic setups change the intents (row 12 on): those rows are also action differences.
	local longer = run(newSession({ leadInRows = 16 }), 1, 16, 1):reproducibility().decisionRows
	assert(longer.rowDifferences == 16 and longer.actionRowDifferences == 5 and longer.firstActionDifferentRow == 12, canonical(longer))
	assert(string.find(longer.label, "(decision or ledger row; 5 with a different action or ledger)", 1, true), longer.label)
	local gate = session:summary().primaryCriterion.leadInValidation
	assert(gate.decisionRows.status == "differs" and gate.decisionRows.rowDifferences == 10 and gate.decisionRows.label == d.label)
	-- The shadow never changes the live rows: the same inputs without a lead-in comparison give the same lead-in rows.
	local reference = run(newSession({ leadInRows = 10 }), 1, 12, 1)
	for _, id in RUN_IDS do
		for i = 1, 12 do assert(canonical(reference:rows(id)[i]) == canonical(session:rows(id)[i])) end
	end
	-- A shadow failure (its ledger refuses an inconsistent bar the untraded lead-in accepts) is disclosed, never fatal.
	local broken = newSession({ leadInRows = 10 })
	run(broken, 1, 12, 1, { [5] = function(v) v.bar.h = v.bar.c - 1 end })
	local b = broken:reproducibility().decisionRows
	assert(b.status == "differs" and b.compared == 4 and string.find(b.error, "shadow session failed at row 5", 1, true), canonical(b))
	assert(not broken.failed and broken:rowCount() == 12 and broken.shadow == nil)
end)

test("evidence: forward-test dependence counts and the predeclared market evidence (L6)", function()
	local session = run(newSession({ leadInRows = 0 }), 1, 20, 1)
	local e = session:evidence()
	local counts = e.physicsDependenceCounts
	assert(e.dependenceScope == "forward_test" and counts.denominatorRows == 20 and counts.coupledPhysicsActionsEmitted > 0)
	assert(counts.zeroPhysicsActionsEmitted == 0 and counts.coupledVsZeroEmittedActionDifferences > 0 and e.physicsDependence == "history_verified")
	assert(counts.maxContributionSumError <= 1e-12 and e.implementationStatus == "pass" and e.tradingApproval == "experimental - not approved for trading")
	e.marketEvidence = "changed"
	assert(session:evidence().marketEvidence == "forward_test_predeclared", "evidence() returns a copy")
end)

print("SpringLiveSession: " .. passed .. " tests passed")
