local loaded, SpringSignals = pcall(require, "../src/SpringSignals")
assert(loaded and type(SpringSignals) == "table", "SpringSignals must implement the physical spring scorer")
local loadedState, SpringState = pcall(require, "../src/SpringState")
assert(loadedState and type(SpringState) == "table", "SpringState is required by the scorer tests")
local loadedFixtures, Fixtures = pcall(require, "./SpringFixtures")
assert(loadedFixtures and type(Fixtures) == "table", "SpringFixtures must provide synthetic fixtures")
local passed = 0
local function test(n, f) f(); passed += 1; print("PASS " .. n) end
local function rejects(f, fragment)
	local ok, err = pcall(f)
	assert(not ok, "expected a rejection containing '" .. fragment .. "'")
	assert(string.find(tostring(err), fragment, 1, true), "wrong rejection: " .. tostring(err) .. " (expected '" .. fragment .. "')")
end
local function near(a, b, e) assert(math.abs(a - b) <= (e or 1e-12), tostring(a) .. " != " .. tostring(b)) end

-- All data below is synthetic fixture data (Fixtures.HEADER), never historical evidence.
local protocol = Fixtures.protocol()
local descriptor = Fixtures.descriptor()
local FLAT, LONG, SHORT = Fixtures.context(0), Fixtures.context(1), Fixtures.context(-1)
local function calibrateStream(count, generator, options)
	return SpringSignals.calibrate(Fixtures.stream(descriptor, count, generator, options), descriptor, protocol)
end
local BASE = calibrateStream(180)

-- In-test reference statistics over explicit member samples (population std, divide by n).
local function reference(samples, kind, node)
	local n, sum = #samples, 0
	for _, s in samples do sum += s[kind][node] end
	local mean = sum / n
	local squares = 0
	for _, s in samples do squares += (s[kind][node] - mean) ^ 2 end
	return mean, math.sqrt(squares / n), math.sqrt(squares / (n - 1))
end
local function coordinate(c, kind, node) return c.coordinates[if kind == "x" then node else 24 + node] end
local function machineRun(calibration, xvs, contexts, options)
	local m = SpringSignals.new(calibration, protocol)
	local intents = {}
	for k, xv in xvs do
		local sample = Fixtures.sample(descriptor, k, xv[1], xv[2], options)
		intents[k] = m:step(sample, contexts and contexts[k] or FLAT)
	end
	return intents, m
end
local function repeated(n, x, v)
	local out = {}
	for k = 1, n do out[k] = { x, v } end
	return out
end

test("calibration uses valid post-warm-up samples (D1) with population std, mean and RMS for all 48 coordinates", function()
	local samples = Fixtures.stream(descriptor, 180)
	local c = SpringSignals.calibrate(samples, descriptor, protocol)
	assert(c.schema == "spring-calibration-v1" and c.protocolId == "spring-consensus-v1" and c.available == true and c.unavailableReason == nil)
	assert(c.n == 169 and c.inputCount == 180 and c.excludedWarmup == 11 and c.excludedInvalid == 0)
	assert(c.firstSampleId == "fixture:12" and c.lastSampleId == "fixture:180")
	assert(#c.coordinates == 48 and #c.eligible[1] == 3 and #c.eligible[2] == 5 and #c.eligible[3] == 5)
	local members = table.move(samples, 12, 180, 1, {})
	for k = 1, 48 do
		local co = c.coordinates[k]
		local kind, node = if k <= 24 then "x" else "v", (k - 1) % 24 + 1
		assert(co.kind == kind and co.node == node and co.name == descriptor.stateNames[k] and co.directional == descriptor.nodes[node].directional)
		local mean, population, sample = reference(members, kind, node)
		near(co.mean, mean, 1e-15)
		near(co.std, population, 1e-14)
		assert(math.abs(co.std - sample) > 1e-6 * sample, "std must be the population std, not the n-1 sample std")
		near(co.rms, math.sqrt(mean * mean + population * population), 1e-14)
		assert(co.active == true)
	end
	-- The 11 warm-up samples cannot influence the statistics.
	local wild = Fixtures.stream(descriptor, 180, function(k, x, v)
		Fixtures.motion(k, x, v)
		if k <= 11 then for i = 1, 24 do x[i], v[i] = 1000 * i, -1000 * i end end
	end)
	local c2 = SpringSignals.calibrate(wild, descriptor, protocol)
	Fixtures.deepEqual(c2.coordinates, c.coordinates)
	Fixtures.deepEqual(c2.thresholds, c.thresholds)
end)

test("segment position restarts after a reset, an intraday gap or an invalid sample; overnight does not", function()
	assert(calibrateStream(180, nil, { resetAt = { [60] = true } }).n == 158)
	local gap = calibrateStream(180, nil, { gapBefore = { [60] = true } })
	assert(gap.n == 158 and gap.excludedWarmup == 22)
	local invalid = calibrateStream(180, nil, { invalidAt = { [60] = true } })
	assert(invalid.n == 157 and invalid.excludedInvalid == 1 and invalid.excludedWarmup == 22)
	local overnight = calibrateStream(180, nil, { overnightBefore = { [60] = true } })
	assert(overnight.n == 169 and overnight.excludedWarmup == 11)
	-- The restarted warm-up samples are really excluded: wild values there change nothing.
	local function wildAt(k, x, v)
		Fixtures.motion(k, x, v)
		if k >= 60 and k <= 70 then for i = 1, 24 do x[i] = 500 end end
	end
	local a = calibrateStream(180, nil, { resetAt = { [60] = true } })
	local b = calibrateStream(180, wildAt, { resetAt = { [60] = true } })
	Fixtures.deepEqual(a.coordinates, b.coordinates)
end)

test("near-constant coordinates are dropped by std > max(1e-6, 1e-4 x RMS), both bounds", function()
	local function generator(k, x, v)
		Fixtures.motion(k, x, v)
		local alt = if k % 2 == 0 then 1 else -1
		x[2] = 0.5                 -- constant
		x[3] = 1 + 0.5e-4 * alt    -- relative bound: std ~5e-5 < 1e-4 x RMS -> dropped
		x[5] = 1 + 2e-4 * alt      -- std ~2e-4 > 1e-4 x RMS -> active
		x[6] = 5e-7 * alt          -- absolute bound: std 5e-7 < 1e-6 -> dropped
		x[8] = 2e-6 * alt          -- std 2e-6 > 1e-6 -> active
		v[1] = 0.25                -- directional velocity constant -> dropped, node 1 scores zX/5
		x[4] = -0.3                -- directional displacement constant -> node 4 not eligible
	end
	local c = calibrateStream(180, generator)
	local expected = { [2] = false, [3] = false, [5] = true, [6] = false, [8] = true, [4] = false }
	for node, active in expected do
		local co = coordinate(c, "x", node)
		assert(co.active == active, "x" .. node .. " active=" .. tostring(co.active))
		assert(co.mean == co.mean and co.std == co.std and co.rms == co.rms, "dropped coordinates still report statistics")
		if not active then assert(co.clipCount == 0 and co.clipFraction == 0) end
	end
	assert(coordinate(c, "v", 1).active == false and coordinate(c, "v", 4).active == true)
	assert(#c.eligible[1] == 2 and c.eligible[1][1] == 1 and c.eligible[1][2] == 7 and c.available)
	local x, v = table.create(24, 0), table.create(24, 0)
	x[1], v[1] = 2 * coordinate(c, "x", 1).std, 3
	local d = SpringSignals.score(Fixtures.sample(descriptor, 1, x, v), c)
	assert(d.zV[1] == 0 and d.zX[1] == 2)
	near(d.nodeScores[1], 2 / 5)
	near(d.bankScores[1], (2 / 5) / 2)
	assert(d.zX[4] == 0 and d.nodeScores[4] == 0 and d.nodeContributions[4] == 0)
end)

test("a bank with fewer than two eligible nodes is unavailable: every intent is HOLD with a reason, no fallback", function()
	local c = calibrateStream(180, function(k, x, v)
		Fixtures.motion(k, x, v)
		x[4], x[7] = 0.2, -0.2
	end)
	assert(c.available == false and c.unavailableReason == "insufficient_eligible_nodes:Fast" and c.thresholds == nil)
	assert(c.n == 169 and #c.eligible[1] == 1 and #c.coordinates == 48, "statistics stay disclosed")
	local strong = table.create(24, 1)
	local d = SpringSignals.score(Fixtures.sample(descriptor, 1, strong, table.create(24, 0)), c)
	assert(d.valid == false and d.reason == "calibration_unavailable" and d.score == nil)
	for _, ctx in { FLAT, LONG, SHORT } do
		local intents = machineRun(c, repeated(30, strong, table.create(24, 0)), table.create(30, ctx))
		for _, i in intents do
			assert(i.action == "HOLD" and i.source == "physics" and i.reason == "calibration_unavailable")
			assert(i.diagnostics.blocked == "calibration_unavailable" and i.diagnostics.reason == "calibration_unavailable:insufficient_eligible_nodes:Fast")
		end
	end
	local both = calibrateStream(180, function(k, x, v)
		Fixtures.motion(k, x, v)
		x[4], x[7], x[19], x[20], x[22], x[23] = 0, 0, 0, 0, 0, 0
	end)
	assert(both.unavailableReason == "insufficient_eligible_nodes:Fast,Slow")
end)

test("fewer than 100 calibration samples is unavailable; exactly 100 is available", function()
	local short = calibrateStream(110)
	assert(short.n == 99 and short.available == false and short.unavailableReason == "insufficient_calibration_samples" and short.thresholds == nil)
	local enough = calibrateStream(111)
	assert(enough.n == 100 and enough.available == true and enough.thresholds.n == 100 and enough.thresholds.rank == 65)
	local empty = SpringSignals.calibrate({}, descriptor, protocol)
	assert(empty.n == 0 and empty.available == false and #empty.coordinates == 0 and empty.firstSampleId == nil)
	local m = SpringSignals.new(short, protocol)
	local x, v = Fixtures.positiveAgreement(BASE)
	for k = 1, 20 do assert(m:step(Fixtures.sample(descriptor, k, x, v), FLAT).reason == "calibration_unavailable") end
end)

test("standardized values clip at +/-5 and clip counts are recorded", function()
	local outliers = { [50] = 40, [120] = -40, [150] = 2 }
	local c = calibrateStream(180, function(k, x, v)
		Fixtures.motion(k, x, v)
		if outliers[k] then x[9] = outliers[k] * 0.116 end
	end)
	local co = coordinate(c, "x", 9)
	local members = table.move(Fixtures.stream(descriptor, 180, function(k, x, v)
		Fixtures.motion(k, x, v)
		if outliers[k] then x[9] = outliers[k] * 0.116 end
	end), 12, 180, 1, {})
	local expected = 0
	for _, s in members do if math.abs(s.x[9] / co.std) > 5 then expected += 1 end end
	assert(expected == 2 and co.clipCount == 2)
	near(co.clipFraction, 2 / 169)
	local x, v = table.create(24, 0), table.create(24, 0)
	x[9] = 100 * co.std
	local d = SpringSignals.score(Fixtures.sample(descriptor, 1, x, v), c)
	assert(d.zX[9] == 5 and d.clipped == 1)
	near(d.nodeScores[9], 0.8)
	x[9] = -100 * co.std
	d = SpringSignals.score(Fixtures.sample(descriptor, 1, x, v), c)
	assert(d.zX[9] == -5 and d.clipped == 1)
	x[9], v[9] = 4.9 * co.std, -1000
	d = SpringSignals.score(Fixtures.sample(descriptor, 1, x, v), c)
	assert(d.zV[9] == -5 and d.clipped == 1, "4.9 is not clipped; the velocity is")
	near(d.zX[9], 4.9)
	near(d.nodeScores[9], 0.8 * d.zX[9] / 5 - 0.2)
end)

test("equilibrium x=0, v=0 scores exactly 0 and never enters", function()
	local zeroX, zeroV = Fixtures.equilibrium()
	local d = SpringSignals.score(Fixtures.sample(descriptor, 1, zeroX, zeroV), BASE)
	assert(d.valid and d.score == 0)
	local sum = 0
	for _, value in d.nodeContributions do sum += value end
	assert(math.abs(sum - d.score) < 1e-12)
	for b = 1, 3 do assert(d.bankScores[b] == 0) end
	for i = 1, 24 do assert(d.zX[i] == 0 and d.zV[i] == 0 and d.nodeContributions[i] == 0) end
	local intents = machineRun(BASE, repeated(40, zeroX, zeroV))
	for _, i in intents do assert(i.action == "HOLD" and i.diagnostics.setup == "none") end
	-- Positioned, a neutral state is loss of conviction: CLOSE on the second observation.
	local held = machineRun(BASE, repeated(2, zeroX, zeroV), { LONG, LONG })
	assert(held[1].action == "HOLD" and held[2].action == "CLOSE" and held[2].reason == "physics_loss_of_conviction")
end)

test("node contributions sum to the score within 1e-12; scores follow the node/bank/total definitions", function()
	local seed = 12345
	local function rand() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 * 2 - 1 end
	local samples = Fixtures.stream(descriptor, 180)
	for k = 1, 200 do
		local x, v = table.create(24), table.create(24)
		for i = 1, 24 do x[i] = rand() * 10 * coordinate(BASE, "x", i).std; v[i] = rand() * 10 * coordinate(BASE, "v", i).std end
		table.insert(samples, Fixtures.sample(descriptor, k, x, v))
	end
	for _, s in samples do
		local d = SpringSignals.score(s, BASE)
		local sum = 0
		for _, value in d.nodeContributions do sum += value end
		assert(math.abs(sum - d.score) < 1e-12, "contribution sum")
		assert(math.abs(d.score) <= 1 and d.score == (d.bankScores[1] + d.bankScores[2] + d.bankScores[3]) / 3)
		for b = 1, 3 do
			local ids, bankSum = BASE.eligible[b], 0
			for _, i in ids do
				local zx = math.clamp(s.x[i] / coordinate(BASE, "x", i).std, -5, 5)
				local zv = math.clamp(s.v[i] / coordinate(BASE, "v", i).std, -5, 5)
				near(d.nodeScores[i], 0.8 * zx / 5 + 0.2 * zv / 5, 1e-15)
				near(d.nodeContributions[i], d.nodeScores[i] / #ids / 3, 1e-15)
				bankSum += d.nodeScores[i]
			end
			near(d.bankScores[b], bankSum / #ids, 1e-15)
		end
		for i = 1, 24 do
			if not descriptor.nodes[i].directional then assert(d.nodeScores[i] == 0 and d.zX[i] == 0 and d.nodeContributions[i] == 0) end
		end
	end
end)

test("entry threshold is the nearest-rank 0.65 quantile of |training score|: element ceil(0.65 n)", function()
	assert(SpringSignals.nearestRank(100, 0.65) == 65 and SpringSignals.nearestRank(20, 0.65) == 13 and SpringSignals.nearestRank(1, 0.65) == 1)
	assert(SpringSignals.nearestRank(169, 0.65) == 110 and SpringSignals.nearestRank(101, 0.65) == 66 and SpringSignals.nearestRank(1513, 0.65) == 984)
	local function series(k) return (if k % 2 == 0 then 1 else -1) * k / 1000 end
	local samples = Fixtures.stream(descriptor, 180, function(k, x, v)
		for _, id in descriptor.directional do x[id] = series(k) end
	end)
	local c = SpringSignals.calibrate(samples, descriptor, protocol)
	assert(c.available and coordinate(c, "v", 1).active == false)
	local members = table.move(samples, 12, 180, 1, {})
	local _, std = reference(members, "x", 1)
	local absolute = {}
	for _, s in members do table.insert(absolute, math.abs(math.clamp(s.x[1] / std, -5, 5) / 5)) end
	table.sort(absolute)
	local t = c.thresholds
	assert(t.rank == 110 and t.n == 169 and t.quantile == 0.65)
	near(t.unclamped, absolute[110])
	assert(math.abs(absolute[109] - absolute[110]) > 1e-6 and math.abs(absolute[111] - absolute[110]) > 1e-6, "neighbouring ranks are distinguishable")
	assert(t.unclamped > 0.10 and t.unclamped < 0.35 and t.entry == t.unclamped)
	assert(t.exit == 0.45 * t.entry and t.bankDeadband == 0.25 * t.entry)
end)

test("entry threshold clamps at both bounds (0.10 and 0.35) and keeps the 0.45/0.25 ratios", function()
	local low = calibrateStream(180, function(k, x, v)
		local value = (if k % 2 == 0 then 1 else -1) * (if k % 10 == 0 then 1 else 0.01)
		for _, id in descriptor.directional do x[id] = value end
	end)
	assert(low.thresholds.unclamped < 0.10 and low.thresholds.entry == 0.10)
	assert(low.thresholds.exit == 0.45 * 0.10 and low.thresholds.bankDeadband == 0.25 * 0.10)
	local high = calibrateStream(180, function(k, x, v)
		for _, id in descriptor.directional do x[id] = 1 + 0.01 * (if k % 2 == 0 then 1 else -1) end
	end)
	assert(high.thresholds.unclamped > 0.35 and high.thresholds.entry == 0.35)
	assert(high.thresholds.exit == 0.45 * 0.35 and high.thresholds.bankDeadband == 0.25 * 0.35)
	assert(coordinate(high, "x", 1).clipCount == 169 and coordinate(high, "x", 1).clipFraction == 1)
end)

test("positive agreement -> BUY and negative agreement -> SELL at observation 13; disagreement never enters", function()
	local px, pv = Fixtures.positiveAgreement(BASE)
	local intents = machineRun(BASE, repeated(13, px, pv))
	for k = 1, 11 do assert(intents[k].action == "HOLD" and intents[k].reason == "warmup") end
	assert(intents[12].action == "HOLD" and intents[12].reason == "positive_setup_unconfirmed")
	local buy = intents[13]
	assert(buy.action == "BUY" and buy.source == "physics" and buy.reason == "confirmed_positive_setup" and buy.sampleId == "fixture:13")
	near(buy.diagnostics.score, 0.48)
	assert(#buy.diagnostics.nodeContributions == 24 and buy.diagnostics.valid == true)
	local nx, nv = Fixtures.negativeAgreement(BASE)
	local neg = machineRun(BASE, repeated(13, nx, nv))
	assert(neg[12].action == "HOLD" and neg[13].action == "SELL" and neg[13].reason == "confirmed_negative_setup")
	near(neg[13].diagnostics.score, -0.48)
	local dx, dv = Fixtures.disagreement(BASE)
	for _, i in machineRun(BASE, repeated(30, dx, dv)) do assert(i.action == "HOLD" and i.diagnostics.setup == "none") end
end)

test("physics CLOSE from long and short by loss of conviction and by bank reversal", function()
	local wx, wv = Fixtures.weak(BASE)
	local long = machineRun(BASE, repeated(2, wx, wv), { LONG, LONG })
	assert(long[1].action == "HOLD" and long[2].action == "CLOSE" and long[2].source == "physics" and long[2].reason == "physics_loss_of_conviction")
	local short = machineRun(BASE, repeated(2, wx, wv), { SHORT, SHORT })
	assert(short[1].action == "HOLD" and short[2].action == "CLOSE" and short[2].reason == "physics_loss_of_conviction")
	local lx, lv = Fixtures.longReversal(BASE)
	local lr = machineRun(BASE, repeated(1, lx, lv), { LONG })[1]
	assert(lr.action == "CLOSE" and lr.reason == "physics_bank_reversal" and lr.diagnostics.score > BASE.thresholds.exit)
	local sx, sv = Fixtures.shortReversal(BASE)
	local sr = machineRun(BASE, repeated(1, sx, sv), { SHORT })[1]
	assert(sr.action == "CLOSE" and sr.reason == "physics_bank_reversal" and sr.diagnostics.score < -BASE.thresholds.exit)
	-- The same reversal states do not close the opposite side.
	assert(machineRun(BASE, repeated(1, lx, lv), { SHORT })[1].action == "HOLD")
	assert(machineRun(BASE, repeated(1, sx, sv), { LONG })[1].action == "HOLD")
end)

test("an invalid sample clears confirmation and never enters; while positioned it is a risk CLOSE", function()
	local px, pv = Fixtures.positiveAgreement(BASE)
	local bx, bv = Fixtures.nonFinite()
	local sequence = repeated(27, px, pv)
	sequence[13] = { bx, bv }
	local intents = machineRun(BASE, sequence)
	assert(intents[12].reason == "positive_setup_unconfirmed")
	assert(intents[13].action == "HOLD" and intents[13].reason == "invalid_physics_state" and intents[13].diagnostics.state.warmup == 0)
	for k = 14, 24 do assert(intents[k].reason == "warmup") end
	assert(intents[25].reason == "positive_setup_unconfirmed" and intents[26].action == "BUY")
	for k = 1, 25 do assert(intents[k].action == "HOLD") end
	local held = machineRun(BASE, { { bx, bv } }, { LONG })[1]
	assert(held.action == "CLOSE" and held.source == "risk" and held.reason == "invalid_physics_state")
end)

test("raw isolation: identical x/v with radically different raw features, labels, drive, force -> identical diagnostics and intents", function()
	local times = Fixtures.timeline(16)
	local px, pv = Fixtures.positiveAgreement(BASE)
	local wx, wv = Fixtures.weak(BASE)
	local contexts = {}
	for k = 1, 16 do contexts[k] = if k <= 13 then FLAT else LONG end
	local function run(market, label)
		local m = SpringSignals.new(BASE, protocol)
		local out, diagnostics, records = {}, {}, {}
		for k, o in times do
			local x, v = if k <= 13 then px else wx, if k <= 13 then pv else wv
			local record = Fixtures.record({ market = market, label = label .. k, t = o.t, day = o.day, reset = o.reset, x = x, v = v })
			records[k] = record
			local sample = SpringState.fromRecord(record, "coupled", descriptor, "coupled:" .. k)
			diagnostics[k] = SpringSignals.score(sample, BASE)
			out[k] = m:step(sample, contexts[k])
		end
		return out, diagnostics, records
	end
	local a, da, ra = run(1, "synthetic A ")
	local b, db, rb = run(-37, "zzz synthetic B ")
	assert(ra[5].bar.c ~= rb[5].bar.c and ra[5].bar.label ~= rb[5].bar.label and ra[5].feature.raw[1] ~= rb[5].feature.raw[1])
	assert(ra[5].feature.drive[1] ~= rb[5].feature.drive[1] and ra[5].states.coupled.nodes[3].force ~= rb[5].states.coupled.nodes[3].force)
	assert(ra[5].states.coupled.nodes[3].drive ~= rb[5].states.coupled.nodes[3].drive and ra[5].feature.volatility ~= rb[5].feature.volatility)
	assert(ra[5].states.coupled.vector[49] ~= rb[5].states.coupled.vector[49], "energies differ too")
	Fixtures.deepEqual(da, db)
	Fixtures.deepEqual(a, b)
	assert(a[13].action == "BUY" and a[15].action == "CLOSE", "the compared sequence exercises entries and exits")
end)

-- calibrate() is pure over the rows it is given; choosing only rows with t < trainEndT is the caller's job
-- (SpringStudy), so the partition-level future-isolation test belongs in SpringStudy's spec as well.
test("calibration future isolation: later samples never change it, and it keeps no reference to its inputs", function()
	local full = Fixtures.stream(descriptor, 260)
	local trainEndT = full[201].t
	local function training()
		local out = {}
		for _, s in full do if s.t < trainEndT then table.insert(out, s) end end
		return out
	end
	local first = training()
	local inputSnapshot = Fixtures.deepCopy(first)
	local c1 = SpringSignals.calibrate(first, descriptor, protocol)
	Fixtures.deepEqual(first, inputSnapshot) -- calibrate does not mutate its inputs
	local snapshot = Fixtures.deepCopy(c1)
	for k = 201, 260 do
		for i = 1, 24 do full[k].x[i] = 1000 * i; full[k].v[i] = -1000 end
	end
	local c2 = SpringSignals.calibrate(training(), descriptor, protocol)
	Fixtures.deepEqual(c1, c2)
	local leaked = SpringSignals.calibrate(full, descriptor, protocol)
	assert(leaked.n ~= c1.n and leaked.coordinates[1].std ~= c1.coordinates[1].std, "including future samples would be visible")
	for _, s in first do s.x[1] = 99; s.v[1] = -99 end
	Fixtures.deepEqual(c1, snapshot)
	local calTables = Fixtures.tables(c1)
	for t in Fixtures.tables(first) do assert(not calTables[t], "calibration shares a table with a sample") end
end)

test("descriptor and calibration are deep-frozen", function()
	Fixtures.assertDeepFrozen(descriptor)
	Fixtures.assertDeepFrozen(BASE)
	assert(not pcall(function() BASE.thresholds.entry = 0.2 end))
	assert(not pcall(function() BASE.coordinates[1].std = 1 end))
	assert(not pcall(function() table.insert(BASE.eligible[1], 2) end))
	assert(not pcall(function() BASE.available = false end))
	local unavailable = calibrateStream(50)
	Fixtures.assertDeepFrozen(unavailable)
end)

test("the scorer accepts only narrow samples, frozen calibrations and the exact protocol", function()
	local x, v = Fixtures.positiveAgreement(BASE)
	local record = Fixtures.record({ x = x, v = v })
	rejects(function() SpringSignals.calibrate({ record }, descriptor, protocol) end, "is not allowed")
	rejects(function() SpringSignals.score(record, BASE) end, "is not allowed")
	rejects(function() SpringSignals.new(BASE, protocol):step(record, FLAT) end, "is not allowed")
	local sample = Fixtures.sample(descriptor, 1, x, v)
	local widened = Fixtures.deepCopy(sample)
	widened.feature = { volatility = 0.01 }
	rejects(function() SpringSignals.score(widened, BASE) end, "sample field 'feature' is not allowed")
	rejects(function() SpringSignals.score(sample, Fixtures.deepCopy(BASE)) end, "frozen calibration")
	local p = Fixtures.deepCopy(protocol)
	p.calibration.clip = 4
	rejects(function() SpringSignals.calibrate({ sample }, descriptor, p) end, "protocol mismatch")
	rejects(function() SpringSignals.new(BASE, p) end, "protocol mismatch")
	rejects(function() SpringSignals.new(BASE, protocol):step(sample, { position = 0, pending = false, exitedThisBar = false, bar = {} }) end, "context field 'bar'")
	local backwards = { Fixtures.sample(descriptor, 2, x, v), Fixtures.sample(descriptor, 1, x, v) }
	rejects(function() SpringSignals.calibrate(backwards, descriptor, protocol) end, "increase strictly")
	local forged = table.clone(descriptor)
	forged.protocolId = "spring-consensus-v0"
	table.freeze(forged)
	rejects(function() SpringSignals.calibrate(Fixtures.stream(descriptor, 20), forged, protocol) end, "descriptor protocol mismatch")
	local withMeta = Fixtures.deepCopy(sample)
	setmetatable(withMeta, { __index = function(_, k) return record.bar[k] end })
	rejects(function() SpringSignals.score(withMeta, BASE) end, "metatable is not allowed")
	rejects(function() SpringSignals.new(BASE, protocol):step(withMeta, FLAT) end, "metatable is not allowed")
end)

test("machine resetBoundary keeps warm-up and clears confirmation", function()
	local px, pv = Fixtures.positiveAgreement(BASE)
	local m = SpringSignals.new(BASE, protocol)
	for k = 1, 12 do m:step(Fixtures.sample(descriptor, k, px, pv), FLAT) end
	assert(m:state().posConfirm == 1 and m:state().warmup == 12)
	m:resetBoundary()
	assert(m:state().posConfirm == 0 and m:state().warmup == 12)
	assert(m:step(Fixtures.sample(descriptor, 13, px, pv), FLAT).action == "HOLD")
	assert(m:step(Fixtures.sample(descriptor, 14, px, pv), FLAT).action == "BUY")
end)

-- Review 2026-10-05: D12 was only tested at policy level. The machine builds the observation from the sample, so
-- its wiring (reset, day, t) is tested here. History has 0 intraday gaps and its only reset is record 1, so only
-- these synthetic fixtures exercise it.
test("the physical machine applies D12: a recorded reset or an intraday gap restarts warm-up, overnight does not", function()
	local px, pv = Fixtures.positiveAgreement(BASE)
	local function run(count, options) return machineRun(BASE, repeated(count, px, pv), nil, options) end
	local overnightOpts, gapOpts = { overnightBefore = { [13] = true } }, { gapBefore = { [13] = true } }
	local tOvernight, tGap = Fixtures.timeline(13, overnightOpts), Fixtures.timeline(13, gapOpts)
	assert(tOvernight[13].day ~= tOvernight[12].day and tOvernight[13].t - tOvernight[12].t > 300, "fixture: new session at 13")
	assert(tGap[13].day == tGap[12].day and tGap[13].t - tGap[12].t == 600, "fixture: missing interval before 13")
	local overnight = run(13, overnightOpts)
	assert(overnight[13].action == "BUY" and overnight[13].diagnostics.state.warmup == 13)
	local gap = run(13, gapOpts)
	assert(gap[13].action == "HOLD" and gap[13].reason == "warmup" and gap[13].diagnostics.blocked == "warmup")
	assert(gap[13].diagnostics.state.warmup == 1 and gap[13].diagnostics.state.posConfirm == 0)
	local reset = run(13, { resetAt = { [13] = true } })
	assert(reset[13].action == "HOLD" and reset[13].reason == "warmup" and reset[13].diagnostics.state.warmup == 1)
	-- After the restart the earliest entry is again the 13th observation of the new segment.
	local restarted = run(25, { resetAt = { [13] = true } })
	for k = 13, 23 do assert(restarted[k].reason == "warmup" and restarted[k].diagnostics.state.warmup == k - 12) end
	assert(restarted[24].reason == "positive_setup_unconfirmed" and restarted[25].action == "BUY" and restarted[25].diagnostics.state.warmup == 13)
	-- A reset before warm-up completes.
	local early = run(9, { resetAt = { [7] = true } })
	assert(early[6].diagnostics.state.warmup == 6 and early[7].diagnostics.state.warmup == 1 and early[9].diagnostics.state.warmup == 3)
	-- Session 2 (20-bar sessions): the overnight boundary before 21 continues the count; a gap before 30 restarts it.
	local opts = { session = 20, gapBefore = { [30] = true } }
	local tl = Fixtures.timeline(30, opts)
	assert(tl[21].day ~= tl[20].day and tl[30].day == tl[29].day and tl[30].t - tl[29].t == 600)
	local s2 = run(30, opts)
	assert(s2[21].diagnostics.state.warmup == 21 and s2[29].diagnostics.state.warmup == 29)
	assert(s2[30].diagnostics.state.warmup == 1 and s2[30].reason == "warmup")
	-- An exit counter of a held position is cleared by the gap but not by the overnight boundary.
	local wx, wv = Fixtures.weak(BASE)
	local heldGap = machineRun(BASE, repeated(2, wx, wv), { LONG, LONG }, { gapBefore = { [2] = true } })
	assert(heldGap[2].action == "HOLD" and heldGap[2].diagnostics.state.longExit == 1)
	local heldOvernight = machineRun(BASE, repeated(2, wx, wv), { LONG, LONG }, { overnightBefore = { [2] = true } })
	assert(heldOvernight[2].action == "CLOSE" and heldOvernight[2].reason == "physics_loss_of_conviction")
end)

test("machine intents echo the sample's id and availableT (D9), also for invalid samples and unavailable calibrations", function()
	local px, pv = Fixtures.positiveAgreement(BASE)
	local m = SpringSignals.new(BASE, protocol)
	for k = 1, 14 do
		local s = Fixtures.sample(descriptor, k, px, pv)
		local i = m:step(s, FLAT)
		assert(i.availableT == s.availableT and i.availableT == s.t + 300 and i.sampleId == s.id and s.id == "fixture:" .. k)
	end
	-- A bar available later than t + 300: the sample is invalid and the intent keeps the bar's own availableT.
	local T = Fixtures.T0
	local late = SpringState.fromRecord(Fixtures.record({ t = T, availableT = T + 600, x = px, v = pv }), "coupled", descriptor, "coupled:1")
	assert(late.valid == false and late.invalidReason == "availability_mismatch" and late.availableT == T + 600)
	local close = SpringSignals.new(BASE, protocol):step(late, LONG)
	assert(close.action == "CLOSE" and close.source == "risk" and close.reason == "invalid_physics_state")
	assert(close.availableT == T + 600 and close.sampleId == "coupled:1" and close.diagnostics.reason == "availability_mismatch")
	local hold = SpringSignals.new(BASE, protocol):step(late, FLAT)
	assert(hold.action == "HOLD" and hold.source == "physics" and hold.reason == "invalid_physics_state" and hold.availableT == T + 600)
	-- A bar with no availableT: the sample is invalid, the intent is the D7 one, and its availableT is t + 300,
	-- exactly what Execution expects for such a bar (D9). It must not abort the run.
	local record = Fixtures.record({ t = T, x = px, v = pv })
	record.bar.availableT = nil
	local missing = SpringState.fromRecord(record, "coupled", descriptor, "coupled:1")
	assert(missing.valid == false and missing.invalidReason == "availability_mismatch" and missing.availableT == nil)
	for _, case in { { LONG, "CLOSE", "risk" }, { SHORT, "CLOSE", "risk" }, { FLAT, "HOLD", "physics" } } do
		local i = SpringSignals.new(BASE, protocol):step(missing, case[1])
		assert(i.action == case[2] and i.source == case[3] and i.reason == "invalid_physics_state", i.action .. "/" .. i.source)
		assert(i.availableT == T + 300 and i.sampleId == "coupled:1" and i.diagnostics.reason == "availability_mismatch")
	end
	assert(missing.availableT == nil, "the machine never writes into the sample")
	-- Invalid reasons pass through the scorer into the intent diagnostics.
	local bx, bv = Fixtures.nonFinite()
	local broken = Fixtures.sample(descriptor, 1, bx, bv)
	local d = SpringSignals.score(broken, BASE)
	assert(d.valid == false and d.reason == "non_finite_state" and d.score == nil)
	assert(SpringSignals.new(BASE, protocol):step(broken, FLAT).diagnostics.reason == "non_finite_state")
	-- Unavailable calibration: identity echoed, the same availability rule, and the position context still validated.
	local unavailable = calibrateStream(50)
	assert(unavailable.available == false)
	local um = SpringSignals.new(unavailable, protocol)
	local s3 = Fixtures.sample(descriptor, 3, px, pv)
	local u = um:step(s3, LONG)
	assert(u.action == "HOLD" and u.reason == "calibration_unavailable" and u.availableT == s3.availableT and u.availableT == s3.t + 300 and u.sampleId == s3.id)
	assert(um:step(late, FLAT).availableT == T + 600 and um:step(missing, SHORT).availableT == T + 300)
	rejects(function() um:step(s3, { position = 5, pending = false, exitedThisBar = false }) end, "position must be")
	rejects(function() um:step(s3, { position = 0, pending = false, exitedThisBar = false, price = 100 }) end, "context field 'price'")
	rejects(function() um:step(Fixtures.record({ x = px, v = pv }), FLAT) end, "is not allowed")
end)

test("calibration scoreSummary (the D3 disclosure figures) equals an independent recomputation over the D1 members", function()
	local bias = { 0.9, 0.3, -0.2 } -- per-bank tilt so the total and the three banks have different positive shares
	local function biased(k, x, v)
		Fixtures.motion(k, x, v)
		for i = 1, 24 do x[i] += bias[math.ceil(i / 8)] * (0.08 + 0.004 * i) end
		-- Warm-up rows (1-11 and 100-110 after the reset) are wild: counting them would move every figure.
		if k <= 11 or (k >= 100 and k <= 110) then for i = 1, 24 do x[i], v[i] = 50 * i, -50 * i end end
	end
	local samples = Fixtures.stream(descriptor, 180, biased, { resetAt = { [100] = true } })
	local c = SpringSignals.calibrate(samples, descriptor, protocol)
	local members = {}
	for k = 12, 99 do table.insert(members, samples[k]) end
	for k = 111, 180 do table.insert(members, samples[k]) end
	assert(c.available and c.n == #members and c.n == 158 and c.inputCount == 180)
	local n, sum, positive, lowest, highest = #members, 0, 0, math.huge, -math.huge
	local bankSums, bankPositive = { 0, 0, 0 }, { 0, 0, 0 }
	for _, s in members do
		local d = SpringSignals.score(s, c)
		sum += d.score
		if d.score > 0 then positive += 1 end
		lowest, highest = math.min(lowest, d.score), math.max(highest, d.score)
		for b = 1, 3 do
			bankSums[b] += d.bankScores[b]
			if d.bankScores[b] > 0 then bankPositive[b] += 1 end
		end
	end
	local sm = c.scoreSummary
	local keys = {}
	for k in sm do table.insert(keys, k) end
	table.sort(keys)
	assert(table.concat(keys, ",") == "bankMeans,bankPositiveShares,max,mean,min,positiveShare")
	near(sm.mean, sum / n)
	near(sm.positiveShare, positive / n)
	assert(sm.min == lowest and sm.max == highest)
	assert(#sm.bankMeans == 3 and #sm.bankPositiveShares == 3)
	for b = 1, 3 do
		near(sm.bankMeans[b], bankSums[b] / n)
		near(sm.bankPositiveShares[b], bankPositive[b] / n)
	end
	-- The fixture is informative, so the check cannot pass by symmetry: a mixed total share, both signs of score,
	-- and banks that differ in sign and in positive share.
	assert(sm.positiveShare > 0.05 and sm.positiveShare < 0.95 and sm.min < 0 and sm.max > 0 and sm.min < sm.mean and sm.mean < sm.max)
	assert(math.abs(sm.positiveShare - 0.5) > 0.1, "positive and negative shares must differ (a 50% share hides a sign bug)")
	assert(sm.bankMeans[1] > 0.02 and sm.bankMeans[3] < -0.02, string.format("bank means %.4f %.4f %.4f", sm.bankMeans[1], sm.bankMeans[2], sm.bankMeans[3]))
	for a = 1, 3 do
		for b = a + 1, 3 do
			assert(math.abs(sm.bankPositiveShares[a] - sm.bankPositiveShares[b]) > 0.05, "bank positive shares must differ")
			assert(math.abs(sm.bankMeans[a] - sm.bankMeans[b]) > 0.01, "bank means must differ")
		end
	end
	-- An unavailable calibration publishes no summary rather than a misleading one.
	assert(calibrateStream(50).scoreSummary == nil)
end)

test("nearest rank when 0.65 n is an integer (n = 100): the threshold is element 65 itself", function()
	local function series(k) return (if k % 2 == 0 then 1 else -1) * k / 1000 end
	local samples = Fixtures.stream(descriptor, 111, function(k, x, v)
		for _, id in descriptor.directional do x[id] = series(k) end
	end)
	local c = SpringSignals.calibrate(samples, descriptor, protocol)
	assert(c.available and c.n == 100 and c.thresholds.rank == 65 and c.thresholds.n == 100)
	local members = table.move(samples, 12, 111, 1, {})
	local _, std = reference(members, "x", 1)
	local absolute = {}
	for _, s in members do table.insert(absolute, math.abs(math.clamp(s.x[1] / std, -5, 5) / 5)) end
	table.sort(absolute)
	near(c.thresholds.unclamped, absolute[65])
	assert(math.abs(absolute[64] - absolute[65]) > 1e-6 and math.abs(absolute[66] - absolute[65]) > 1e-6, "neighbouring ranks are distinguishable")
end)

test("clipping is strict: exactly 5 standard deviations is not clipped, anything beyond is", function()
	-- x[9] alternates exactly +/-0.25 over 170 members, so its mean is exactly 0 and its population std exactly 0.25.
	local c = calibrateStream(181, function(k, x, v)
		Fixtures.motion(k, x, v)
		x[9] = if k % 2 == 0 then 0.25 else -0.25
	end)
	local co = coordinate(c, "x", 9)
	assert(c.n == 170 and co.mean == 0 and co.std == 0.25 and co.active and co.clipCount == 0)
	-- Calibration clip counts use the same strict rule. 66 members: two at +/-1.25 and 64 alternating +/-0.125 give
	-- mean exactly 0 and population std exactly 0.25 (4.125 / 66 = 0.0625), so the two outliers sit at exactly 5 sigma.
	local function edge(k, x, v)
		Fixtures.motion(k, x, v)
		x[9] = if k == 12 then 1.25 elseif k == 13 then -1.25 elseif k % 2 == 0 then 0.125 else -0.125
	end
	local atFive = coordinate(calibrateStream(77, edge), "x", 9)
	assert(atFive.mean == 0 and atFive.std == 0.25 and atFive.active and atFive.clipCount == 0 and atFive.clipFraction == 0)
	local beyond = coordinate(calibrateStream(77, function(k, x, v)
		edge(k, x, v)
		if k == 14 then x[9] = 5 end
	end), "x", 9)
	assert(beyond.clipCount == 1 and math.abs(5 / beyond.std) > 5 and math.abs(1.25 / beyond.std) < 5)
	local x, v = table.create(24, 0), table.create(24, 0)
	for _, case in { { 1.25, 5, 0 }, { -1.25, -5, 0 }, { 1.25 + 1e-9, 5, 1 }, { -1.25 - 1e-9, -5, 1 }, { 1.2, 4.8, 0 } } do
		x[9] = case[1]
		local d = SpringSignals.score(Fixtures.sample(descriptor, 1, x, v), c)
		assert(d.zX[9] == case[2] and d.clipped == case[3], string.format("x=%.12f zX=%.12f clipped=%d", case[1], d.zX[9], d.clipped))
	end
end)

print("SpringSignals: " .. passed .. " tests passed")
