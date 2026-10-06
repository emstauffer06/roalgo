-- Plan Task 4: the four-state financial Markov reward model (plan Section 5) and the optional R60 regime block
-- (plan Section 3). All prices are synthetic fixtures; no validation/final market data is read.
-- Expected values are restated in the test from the plan's formulas on tiny fixtures, never taken from the module.
local Test = require("./Test")
local Config = require("../src/Config")
local Markov = require("../src/Model/Markov")
local RegimeFeatures = require("../src/Model/RegimeFeatures")
local MiniJson = require("../fixtures/MiniJson")
local Json = require("../src/Util/Json")

local HOUR = 3600
local BASE_T = 1641220000 - (1641220000 % HOUR) -- an hour boundary in early 2022 (synthetic training time)

local function bar(t: number, c: number): { number }
	return { t, c, c, c, c, 100, 10, c }
end

local function closesFromReturns(start: number, returns: { number }): { number }
	local out = { start }
	for i, r in returns do
		out[i + 1] = out[i] * math.exp(r)
	end
	return out
end

-- days: { { spy = {closes}, qqq = {closes}, gapAfter = k? } }. Day d starts at BASE_T + (d-1) days; a gap skips one hour
-- after the k-th bar. Segments follow the plan: first pair, NY date change, or delta ~= 3600.
local function makeStream(days: { any }): { any }
	local pairs = {}
	local segmentId, offset = 0, 0
	local prevT, prevDate = nil, nil
	for d, day in days do
		local dateKey = 20220100 + d
		local t = day.startT or (BASE_T + (d - 1) * 86400) -- startT lets a fixture place a date change exactly 3600 s on
		for k = 1, #day.spy do
			if day.gapAfter and k == day.gapAfter + 1 then
				t += HOUR
			end
			if prevT == nil or dateKey ~= prevDate or t - prevT ~= HOUR then
				segmentId += 1
				offset = 1
			else
				offset += 1
			end
			local index = #pairs + 1
			pairs[index] = {
				index = index,
				t = t,
				decisionTime = t + HOUR,
				dateNY = "2022-01-" .. string.format("%02d", d),
				dateKey = dateKey,
				dayNumber = 19000 + d,
				hourNY = 4 + k,
				segmentId = segmentId,
				segmentOffset = offset,
				spy = bar(t, day.spy[k]),
				qqq = bar(t, day.qqq[k]),
			}
			prevT, prevDate = t, dateKey
			t += HOUR
		end
	end
	return pairs
end

local function slice(pairs: { any }, first: number, last: number): { any }
	local out = {}
	for i = first, last do
		table.insert(out, pairs[i])
	end
	return out
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

-- Deterministic test PRNG.
local function lcg(seed: number)
	local state = seed
	return function(): number
		state = (1664525 * state + 1013904223) % 4294967296
		return state / 4294967296
	end
end

local function randomDay(rnd: () -> number, hours: number): any
	local rs, rq = {}, {}
	for i = 1, hours - 1 do
		rs[i] = (rnd() - 0.5) * 0.004
		rq[i] = (rnd() - 0.5) * 0.006
	end
	return { spy = closesFromReturns(400 + rnd(), rs), qqq = closesFromReturns(300 + rnd(), rq) }
end

-- Independent restatement of the plan's state inputs for a closes array, at position k (needs k >= 4).
local function obs(closes: { number }, k: number): (number, number)
	local r0 = math.log(closes[k] / closes[k - 1])
	local r1 = math.log(closes[k - 1] / closes[k - 2])
	local r2 = math.log(closes[k - 2] / closes[k - 3])
	return r0, math.sqrt((r0 * r0 + r1 * r1 + r2 * r2) / 3)
end

local function planState(r0: number, v: number, tau: number): number
	if v <= tau then
		return if r0 >= 0 then 1 else 2
	end
	return if r0 >= 0 then 3 else 4
end

local function opts(validationStart: number?): any
	return { validationStart = validationStart or (BASE_T + 400 * 86400), sourceHashes = { hourly = "fixture" } }
end

--------------------------------------------------------------------------------------------------
local markov = Test.suite("Markov")

Test.case(markov, "fixed design constants agree with config", function()
	local m = Config.values.markov
	Test.eq(Markov.STATE_COUNT, m.stateCount)
	Test.eq(Markov.LAPLACE, m.laplace)
	Test.eq(Markov.REWARD_SHRINKAGE, m.rewardShrinkage)
	Test.eq(Markov.RETURNS_FOR_VOLATILITY, m.returnsForVolatility)
	Test.eq(Markov.HORIZON, m.horizon)
	Test.eq(Markov.HORIZON, Config.values.horizonHours)
	Test.eq(Markov.WARMUP, Config.values.warmupObservations)
end)

Test.case(markov, "state inequalities, including ties at tau and r0 = 0", function()
	Test.eq(Markov.classify(0, 0.5, 0.5), 1, "r0=0, v=tau")
	Test.eq(Markov.classify(-0.0, 0.1, 0.5), 1, "negative zero counts as r0 >= 0")
	Test.eq(Markov.classify(-1e-12, 0.5, 0.5), 2, "r0<0, v=tau")
	Test.eq(Markov.classify(0, 0.5000001, 0.5), 3, "r0=0, v>tau")
	Test.eq(Markov.classify(1e-3, 0.7, 0.5), 3)
	Test.eq(Markov.classify(-1e-3, 0.7, 0.5), 4)
end)

Test.case(markov, "constant rewards give 8c for any valid P", function()
	local P = {
		{ 0.1, 0.2, 0.3, 0.4 },
		{ 0.25, 0.25, 0.25, 0.25 },
		{ 0.7, 0.1, 0.1, 0.1 },
		{ 0, 0, 0.5, 0.5 },
	}
	local c = 0.0003
	for s = 1, 4 do
		Test.near(Markov.expectedRewardSum(P, { c, c, c, c }, s, 8), 8 * c, 1e-18, "start " .. s)
	end
end)

Test.case(markov, "P = identity and one-hot state i give 8 mu_i", function()
	local I = { { 1, 0, 0, 0 }, { 0, 1, 0, 0 }, { 0, 0, 1, 0 }, { 0, 0, 0, 1 } }
	local mu = { 0.1, -0.2, 0.3, -0.4 }
	for i = 1, 4 do
		Test.near(Markov.expectedRewardSum(I, mu, i, 8), 8 * mu[i], 1e-15, "state " .. i)
	end
end)

Test.case(markov, "expected reward sum is p_k = p_(k-1) P with a row vector, summed over k = 1..horizon", function()
	-- Asymmetric P so a transposition (column-stochastic use) would give a different answer.
	local P = {
		{ 0.6, 0.4, 0, 0 },
		{ 0, 0.1, 0.9, 0 },
		{ 0, 0, 0.2, 0.8 },
		{ 0.5, 0, 0, 0.5 },
	}
	local mu = { 1, 10, 100, 1000 }
	-- From state 1: p1 = (0.6, 0.4, 0, 0) -> 0.6 + 4 = 4.6; p2 = p1 P = (0.36, 0.28, 0.36, 0) -> 0.36 + 2.8 + 36 = 39.16.
	Test.near(Markov.expectedRewardSum(P, mu, 1, 2), 4.6 + 39.16, 1e-12)
	Test.throws(function()
		Markov.expectedRewardSum(P, mu, 5, 2)
	end, "Markov: state")
	Test.throws(function()
		Markov.expectedRewardSum({ { 0.5, 0.6, 0, 0 }, P[2], P[3], P[4] }, mu, 1, 2)
	end, "Markov: transition row")
end)

-- One segment of six pairs: three state-bearing observations (offsets 4, 5, 6); odd-count median.
local function sixPairFixture(): ({ any }, { number }, { number })
	local spy = { 100, 101, 100.5, 102, 101, 101 } -- last return is exactly 0
	local qqq = { 300, 299, 300.5, 300.25, 303, 301 }
	return makeStream({ { spy = spy, qqq = qqq } }), spy, qqq
end

Test.case(markov, "hand-checkable fit: tau, states, counts, transitions, P, mu, pi, global reward", function()
	local pairs, spy, qqq = sixPairFixture()
	local model = Markov.fit(pairs, opts())
	for _, sym in { { key = "spy", closes = spy }, { key = "qqq", closes = qqq } } do
		local rec = model[sym.key]
		local r0s, vs = {}, {}
		for k = 4, 6 do
			local r0, v = obs(sym.closes, k)
			table.insert(r0s, r0)
			table.insert(vs, v)
		end
		local sorted = table.clone(vs)
		table.sort(sorted)
		local tau = sorted[2]
		Test.near(rec.tau, tau, 1e-15 * tau, sym.key .. " tau = median of three")
		local states = {}
		for i = 1, 3 do
			states[i] = planState(r0s[i], vs[i], rec.tau)
		end
		local counts, sums = { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
		for i = 1, 3 do
			counts[states[i]] += 1
			sums[states[i]] += r0s[i]
		end
		Test.deepEq(rec.stateCounts, counts, sym.key .. " state counts")
		Test.eq(rec.stateBearingCount, 3)
		local N = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
		N[states[1]][states[2]] += 1
		N[states[2]][states[3]] += 1
		Test.deepEq(rec.transitionCounts, N, sym.key .. " transitions")
		Test.eq(rec.transitionTotal, 2)
		local g = (r0s[1] + r0s[2] + r0s[3]) / 3
		Test.near(rec.globalReward, g, 1e-18, sym.key .. " global reward")
		for i = 1, 4 do
			local rowTotal = N[i][1] + N[i][2] + N[i][3] + N[i][4]
			for j = 1, 4 do
				Test.near(rec.P[i][j], (N[i][j] + 1) / (rowTotal + 4), 1e-16, "P")
			end
			Test.near(rec.mu[i], (sums[i] + 20 * g) / (counts[i] + 20), 1e-18, "mu")
			Test.near(rec.pi[i], (counts[i] + 1) / (3 + 4), 1e-16, "pi")
			Test.near(rec.rewardSums[i], sums[i], 1e-18, "reward sums")
		end
	end
	-- SPY's last observation has r0 = ln(101/101) = 0 exactly.
	local r0, v = obs(spy, 6)
	Test.eq(r0, 0)
	Test.eq(Markov.classify(r0, v, model.spy.tau), if v <= model.spy.tau then 1 else 3)
	Test.eq(model.stateDefinitionVersion, Markov.STATE_DEFINITION_VERSION)
	Test.eq(model.provenance.trainingPairCount, 6)
	Test.eq(model.provenance.sourceHashes.hourly, "fixture")
end)

Test.case(markov, "eight-hour forecast on a fitted chain equals an independent restatement of the plan formulas", function()
	-- Constant-mu and identity-P fixtures cannot tell sum_{k=1..8} from sum_{k=0..7}; a fitted, non-trivial chain can.
	local pairs, spy, qqq = sixPairFixture()
	local model = Markov.fit(pairs, opts())
	for s, closes in { spy, qqq } do
		local r0s, vs = {}, {}
		for k = 4, 6 do
			r0s[k - 3], vs[k - 3] = obs(closes, k)
		end
		local sorted = table.clone(vs)
		table.sort(sorted)
		local tau = sorted[2]
		local st, counts, sums = {}, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }
		for i = 1, 3 do
			st[i] = planState(r0s[i], vs[i], tau)
			counts[st[i]] += 1
			sums[st[i]] += r0s[i]
		end
		local N = { { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
		N[st[1]][st[2]] += 1
		N[st[2]][st[3]] += 1
		local g = (r0s[1] + r0s[2] + r0s[3]) / 3
		local P, mu = {}, {}
		for i = 1, 4 do
			local rowTotal = N[i][1] + N[i][2] + N[i][3] + N[i][4]
			P[i] = {}
			for j = 1, 4 do
				P[i][j] = (N[i][j] + 1) / (rowTotal + 4)
			end
			mu[i] = (sums[i] + 20 * g) / (counts[i] + 20)
		end
		for start = 1, 4 do
			local p = { 0, 0, 0, 0 }
			p[start] = 1
			local expected = 0
			for _ = 1, 8 do
				local q = { 0, 0, 0, 0 }
				for i = 1, 4 do
					for j = 1, 4 do
						q[j] += p[i] * P[i][j]
					end
				end
				p = q
				expected += p[1] * mu[1] + p[2] * mu[2] + p[3] * mu[3] + p[4] * mu[4]
			end
			local statesArg = if s == 1 then { start, 1 } else { 1, start }
			local f = Markov.predict(model, statesArg, 8)
			Test.near(f[s], expected, 1e-17, "symbol " .. s .. " from state " .. start)
			-- Guard against the off-by-one (k = 0..7): it differs from the k = 1..8 sum on this fixture.
			local shifted = expected - (p[1] * mu[1] + p[2] * mu[2] + p[3] * mu[3] + p[4] * mu[4]) + mu[start]
			Test.truthy(math.abs(shifted - expected) > 1e-12, "fixture distinguishes k = 0..7 from k = 1..8")
		end
	end
end)

Test.case(markov, "even count: tau is the mean of the two middle values; the median observation ties into low volatility", function()
	local spy = { 100, 101, 100.5, 102, 101 } -- two state-bearing observations
	local qqq = { 50, 50.5, 50.25, 50.75, 50.1, 50.3, 50.2 } -- five
	local pairs = makeStream({ { spy = spy, qqq = { qqq[1], qqq[2], qqq[3], qqq[4], qqq[5] } }, { spy = { 1, 2, 3, 4, 5, 6, 7 }, qqq = qqq } })
	local model = Markov.fit(pairs, opts())
	-- SPY: day 1 gives v4, v5; day 2 closes 1..7 give five more.
	local vs = {}
	for k = 4, 5 do
		local _, v = obs(spy, k)
		table.insert(vs, v)
	end
	for k = 4, 7 do
		local _, v = obs({ 1, 2, 3, 4, 5, 6, 7 }, k)
		table.insert(vs, v)
	end
	table.sort(vs)
	Test.eq(#vs, 6)
	Test.near(model.spy.tau, (vs[3] + vs[4]) / 2, 1e-15, "even median")
	-- QQQ: 2 + 4 = 6 observations as well; odd check via a 3-observation stream is in the hand-checkable case.
	local qv = {}
	for k = 4, 5 do
		local _, v = obs({ qqq[1], qqq[2], qqq[3], qqq[4], qqq[5] }, k)
		table.insert(qv, v)
	end
	for k = 4, 7 do
		local _, v = obs(qqq, k)
		table.insert(qv, v)
	end
	table.sort(qv)
	Test.near(model.qqq.tau, (qv[3] + qv[4]) / 2, 1e-15)
	-- A value equal to tau is low volatility (v <= tau).
	Test.eq(Markov.classify(0.001, model.qqq.tau, model.qqq.tau), 1)
end)

Test.case(markov, "rows sum to one, probabilities are in (0,1), pi sums to one", function()
	local rnd = lcg(5)
	local days = {}
	for d = 1, 20 do
		days[d] = randomDay(rnd, 16)
	end
	local model = Markov.fit(makeStream(days), opts())
	for _, key in { "spy", "qqq" } do
		local rec = model[key]
		local piSum = 0
		for i = 1, 4 do
			local s = 0
			for j = 1, 4 do
				local p = rec.P[i][j]
				Test.truthy(p > 0 and p < 1, "P entry in (0,1)")
				s += p
			end
			Test.near(s, 1, 1e-15, key .. " row " .. i)
			piSum += rec.pi[i]
			Test.truthy(rec.pi[i] > 0 and rec.pi[i] < 1)
		end
		Test.near(piSum, 1, 1e-15, key .. " pi")
		Test.eq(rec.stateBearingCount, 20 * 13, "13 state-bearing observations per 16-hour day")
		Test.eq(rec.transitionTotal, 20 * 12, "12 within-day transitions per day")
	end
	local pi = Markov.stationaryPi(model)
	Test.deepEq(pi[1], model.spy.pi)
	Test.deepEq(pi[2], model.qqq.pi)
end)

Test.case(markov, "unseen states get a uniform row and the global reward", function()
	-- Day 1: steady +1% hours (high volatility, up). Day 2: steady -0.01% hours (low volatility, down).
	local up = closesFromReturns(100, { 0.01, 0.01, 0.01, 0.01, 0.01 })
	local down = closesFromReturns(100, { -0.0001, -0.0001, -0.0001, -0.0001, -0.0001 })
	local pairs = makeStream({ { spy = up, qqq = up }, { spy = down, qqq = down } })
	local model = Markov.fit(pairs, opts())
	local rec = model.spy
	Test.deepEq(rec.stateCounts, { 0, 3, 3, 0 }, "only states 2 and 3 occur")
	for _, unseen in { 1, 4 } do
		Test.deepEq(rec.P[unseen], { 0.25, 0.25, 0.25, 0.25 }, "uniform row " .. unseen)
		Test.near(rec.mu[unseen], rec.globalReward, 1e-18, "global reward " .. unseen)
		Test.near(rec.pi[unseen], 1 / 10, 1e-16)
	end
end)

Test.case(markov, "no transition across a date or a missing hour", function()
	local rnd = lcg(9)
	local day1 = randomDay(rnd, 6) -- states at offsets 4,5,6: 2 transitions
	local day2 = randomDay(rnd, 9)
	day2.gapAfter = 5 -- segment A: 5 pairs (states 4,5: 1 transition); segment B: 4 pairs (state 4: none)
	local day3 = randomDay(rnd, 5) -- states 4,5: 1 transition
	local pairs = makeStream({ day1, day2, day3 })
	Test.eq(pairs[12].segmentOffset, 1, "fixture: the gap starts a new segment")
	Test.eq(pairs[12].t - pairs[11].t, 2 * HOUR, "fixture: the gap is a missing hour")
	Test.eq(pairs[12].dateKey, pairs[11].dateKey, "fixture: same date across the gap")
	local model = Markov.fit(pairs, opts())
	for _, key in { "spy", "qqq" } do
		local rec = model[key]
		Test.eq(rec.stateBearingCount, 3 + 2 + 1 + 2, key .. " state-bearing observations")
		Test.eq(rec.transitionTotal, 2 + 1 + 0 + 1, key .. " transitions only within segments")
		local s = 0
		for i = 1, 4 do
			for j = 1, 4 do
				s += rec.transitionCounts[i][j]
			end
		end
		Test.eq(s, rec.transitionTotal)
	end
end)

Test.case(markov, "no transition across a date change even when the next bar is exactly 3600 s later", function()
	-- Day 2 starts one hour after day 1's last bar (e.g. 23:00 -> 00:00 New York): time alone would connect them.
	local rnd = lcg(17)
	local day1 = randomDay(rnd, 6)
	local day2 = randomDay(rnd, 6)
	day2.startT = BASE_T + 6 * HOUR
	local pairs = makeStream({ day1, day2 })
	Test.eq(pairs[7].t - pairs[6].t, HOUR, "fixture: consecutive hours")
	Test.truthy(pairs[7].dateKey ~= pairs[6].dateKey, "fixture: different NY dates")
	Test.eq(pairs[7].segmentOffset, 1, "fixture: the date change starts a segment")
	local model = Markov.fit(pairs, opts())
	for _, key in { "spy", "qqq" } do
		Test.eq(model[key].stateBearingCount, 3 + 3, key .. " states")
		Test.eq(model[key].transitionTotal, 2 + 2, key .. " no transition across the date")
	end
end)

Test.case(markov, "fit rejects a segment break the plan's segment rule does not allow, and a segment spanning dates", function()
	-- Plan Section 3: a segment starts only on the first pair, a NY date change, or a delta other than 3600 s.
	-- A spurious break would silently delay states and drop transitions.
	local pairs = makeStream({ randomDay(lcg(18), 8) })
	local spurious = deepCopy(pairs)
	for i = 5, 8 do
		spurious[i].segmentId += 1
		spurious[i].segmentOffset = i - 4
	end
	Test.throws(function()
		Markov.fit(spurious, opts())
	end, "Markov: spurious segment break")
	local spanning = deepCopy(pairs)
	for i = 5, 8 do
		spanning[i].dateKey += 1
	end
	Test.throws(function()
		Markov.fit(spanning, opts())
	end, "Markov: inconsistent segment data")
	local noDate = deepCopy(pairs)
	noDate[3].dateKey = nil
	Test.throws(function()
		Markov.fit(noDate, opts())
	end, "dateKey")
end)

Test.case(markov, "states() raises, never returns nil, when the current pair is warmed but the window is wrong", function()
	-- A nil state at a warmed origin would silently drop a Markov forecast (the plan requires one at every warmed
	-- origin). nil is reserved for the first three observations of a segment.
	local rnd = lcg(15)
	local pairs = makeStream({ randomDay(rnd, 6), randomDay(rnd, 6) })
	local model = Markov.fit(pairs, opts())
	Test.eq(pairs[10].segmentOffset, 4, "fixture: pair 10 is the first warmed pair of day 2")
	Test.truthy(Markov.states(model, slice(pairs, 7, 10)) ~= nil, "the correct window has a state")
	Test.throws(function()
		Markov.states(model, { pairs[8], pairs[9], pairs[10] })
	end, "Markov: warmed pair")
	Test.throws(function()
		Markov.states(model, { pairs[10] })
	end, "Markov: warmed pair")
	Test.throws(function()
		Markov.states(model, { pairs[4], pairs[5], pairs[6], pairs[10] })
	end, "Markov: warmed pair")
	Test.throws(function()
		Markov.states(model, { pairs[6], pairs[8], pairs[9], pairs[10] })
	end, "Markov: warmed pair")
	Test.throws(function()
		Markov.states(model, {})
	end, "Markov: states needs the current pair")
	-- The first three observations of a segment have no state, whatever window precedes them.
	Test.eq(Markov.states(model, { pairs[7] }), nil, "offset 1 alone")
	Test.eq(Markov.states(model, slice(pairs, 5, 8)), nil, "offset 2 with the previous date")
	Test.eq(Markov.states(model, slice(pairs, 6, 9)), nil, "offset 3 with the previous date")
end)

Test.case(markov, "state-bearing observations with no eligible eight-hour target still count", function()
	-- An 11-hour segment: origins at offsets >= 4 have no bar 8 hours later on the same date, yet all are states.
	local pairs = makeStream({ randomDay(lcg(3), 11) })
	local model = Markov.fit(pairs, opts())
	Test.eq(model.spy.stateBearingCount, 8)
	Test.eq(model.spy.transitionTotal, 7)
	Test.eq(model.qqq.stateBearingCount, 8)
end)

Test.case(markov, "the training slice must be boundary-checked against validation_start", function()
	local pairs = makeStream({ randomDay(lcg(4), 8) })
	local validationStart = pairs[6].decisionTime -- pair 6 completes exactly at the boundary
	local model = Markov.fit(slice(pairs, 1, 5), opts(validationStart))
	Test.eq(model.spy.stateBearingCount, 2)
	Test.eq(model.spy.transitionTotal, 1, "no transition into the validation pair")
	Test.eq(model.validationStart, validationStart)
	Test.throws(function()
		Markov.fit(slice(pairs, 1, 6), opts(validationStart))
	end, "Markov: training slice is not boundary-checked")
	Test.throws(function()
		Markov.fit(slice(pairs, 1, 5), opts(pairs[5].decisionTime))
	end, "Markov: training slice is not boundary-checked")
	Markov.fit(slice(pairs, 1, 5), opts(pairs[5].decisionTime + 1))
	Test.throws(function()
		Markov.fit(slice(pairs, 1, 5), {})
	end, "Markov: options.validationStart")
end)

Test.case(markov, "empty and state-free samples are hard failures", function()
	Test.throws(function()
		Markov.fit({}, opts())
	end, "Markov: empty training sample")
	local pairs = makeStream({ randomDay(lcg(6), 3), randomDay(lcg(7), 3) })
	Test.throws(function()
		Markov.fit(pairs, opts())
	end, "Markov: no state-bearing training observations")
end)

Test.case(markov, "the slice must be contiguous, start at a segment boundary and have consistent segments", function()
	local pairs = makeStream({ randomDay(lcg(8), 10) })
	local holed = slice(pairs, 1, 10)
	table.remove(holed, 6)
	Test.throws(function()
		Markov.fit(holed, opts())
	end, "Markov: training slice is not contiguous")
	Test.throws(function()
		Markov.fit(slice(pairs, 2, 10), opts())
	end, "Markov: training slice must start at a segment boundary")
	local bad = deepCopy(slice(pairs, 1, 10))
	bad[5].segmentOffset = 7
	Test.throws(function()
		Markov.fit(bad, opts())
	end, "Markov: inconsistent segment")
	local badClose = deepCopy(slice(pairs, 1, 10))
	badClose[3].spy[5] = 0
	Test.throws(function()
		Markov.fit(badClose, opts())
	end, "Markov: invalid close")
	local badTime = deepCopy(slice(pairs, 1, 10))
	badTime[3].decisionTime += 1
	Test.throws(function()
		Markov.fit(badTime, opts())
	end, "decisionTime must equal t + 3600")
end)

Test.case(markov, "states() needs four consecutive same-segment pairs", function()
	local rnd = lcg(10)
	local day = randomDay(rnd, 9)
	day.gapAfter = 5
	local pairs = makeStream({ day })
	local model = Markov.fit(pairs, opts())
	Test.eq(Markov.states(model, slice(pairs, 1, 3)), nil, "fewer than four")
	Test.eq(Markov.states(model, slice(pairs, 4, 7)), nil, "window spans the gap")
	Test.throws(function()
		Markov.states(model, slice(pairs, 1, 5))
	end, "Markov: states expects at most four")
	local s = Markov.states(model, slice(pairs, 2, 5)) :: { number }
	local r0s, vs = obs(day.spy, 5)
	local r0q, vq = obs(day.qqq, 5)
	Test.deepEq(s, { planState(r0s, vs, model.spy.tau), planState(r0q, vq, model.qqq.tau) })
	Test.eq(Markov.state, Markov.states, "plan Section 7 alias")
	local broken = deepCopy(slice(pairs, 2, 5))
	broken[4].qqq[5] = 0 / 0
	Test.throws(function()
		Markov.states(model, broken)
	end, "Markov: invalid close")
end)

Test.case(markov, "predict asserts the production horizon and never turns a missing state into zero", function()
	local pairs = sixPairFixture()
	local model = Markov.fit(pairs, opts())
	Test.throws(function()
		Markov.predict(model, { 1, 2 }, 4)
	end, "Markov: horizon must be 8")
	Test.throws(function()
		Markov.predict(model, nil :: any, 8)
	end, "Markov: states")
	Test.throws(function()
		Markov.predict(model, { 1, 5 }, 8)
	end, "Markov: state")
	for a = 1, 4 do
		for b = 1, 4 do
			local f = Markov.predict(model, { a, b }, 8)
			Test.eq(#f, 2)
			Test.eq(f[1], Markov.expectedRewardSum(model.spy.P, model.spy.mu, a, 8))
			Test.eq(f[2], Markov.expectedRewardSum(model.qqq.P, model.qqq.mu, b, 8))
		end
	end
end)

Test.case(markov, "frozen predictions through t are unchanged when later prices change", function()
	local rnd = lcg(12)
	local days = {}
	for d = 1, 12 do
		days[d] = randomDay(rnd, 16)
	end
	local pairs = makeStream(days)
	local validationStart = pairs[16 * 8].decisionTime + 1 -- first eight days are training
	local trainingEnd = 16 * 8
	local function replay(stream: { any }): (any, { [number]: { number } })
		local model = Markov.fit(slice(stream, 1, trainingEnd), opts(validationStart))
		local out = {}
		for k = trainingEnd + 1, #stream do
			local st = Markov.states(model, slice(stream, math.max(1, k - 3), k))
			if st then
				out[k] = Markov.predict(model, st, 8)
			end
		end
		return model, out
	end
	local modelA, predA = replay(pairs)
	local cut = trainingEnd + 16 * 2 + 7 -- mid-day in validation
	local changed = deepCopy(pairs)
	for k = cut + 1, #changed do
		changed[k].spy[5] *= 1 + (rnd() - 0.5) * 0.2
		changed[k].qqq[5] *= 1 + (rnd() - 0.5) * 0.2
	end
	local modelB, predB = replay(changed)
	Test.deepEq(Markov.serialize(modelB), Markov.serialize(modelA), "model does not depend on later prices")
	local compared = 0
	for k = trainingEnd + 1, cut do
		if predA[k] then
			Test.eq(predB[k][1], predA[k][1], "SPY forecast at " .. k)
			Test.eq(predB[k][2], predA[k][2], "QQQ forecast at " .. k)
			compared += 1
		else
			Test.eq(predB[k], nil)
		end
	end
	Test.truthy(compared > 20, "fixture compares many origins")
	local differs = false
	for k = cut + 1, #pairs do
		if predA[k] and (predA[k][1] ~= predB[k][1]) then
			differs = true
		end
	end
	Test.truthy(differs, "fixture: later forecasts do react to the changed prices")
end)

Test.case(markov, "JSON round trip reproduces the artifact and identical predictions", function()
	local rnd = lcg(13)
	local model = Markov.fit(makeStream({ randomDay(rnd, 16), randomDay(rnd, 16), randomDay(rnd, 12) }), opts())
	local text = MiniJson.encode(Markov.serialize(model))
	local reloaded = Markov.deserialize(MiniJson.decode(text))
	Test.deepEq(Markov.serialize(reloaded), Markov.serialize(model))
	for a = 1, 4 do
		for b = 1, 4 do
			Test.deepEq(Markov.predict(reloaded, { a, b }, 8), Markov.predict(model, { a, b }, 8))
		end
	end
	Test.truthy(table.isfrozen(reloaded) and table.isfrozen(reloaded.spy.P[1]), "reloaded model frozen")
	local function tampered(f: (any) -> ()): any
		local t = MiniJson.decode(text)
		f(t)
		return t
	end
	Test.throws(function()
		Markov.deserialize(tampered(function(t)
			t.spy.P[1][1] += 0.01
		end))
	end, "Markov: artifact")
	Test.throws(function()
		Markov.deserialize(tampered(function(t)
			t.qqq.transitionCounts[2][3] += 1
		end))
	end, "Markov: artifact")
	Test.throws(function()
		Markov.deserialize(tampered(function(t)
			t.stateDefinitionVersion = "other"
		end))
	end, "Markov: artifact")
	Test.throws(function()
		Markov.deserialize(tampered(function(t)
			t.spy.mu[4] = t.spy.mu[4] * 2 + 1e-3
		end))
	end, "Markov: artifact")
	-- An artifact whose own provenance says training reached validation_start is not a training-only fit.
	Test.throws(function()
		Markov.deserialize(tampered(function(t)
			t.provenance.lastT = t.validationStart - 3600
		end))
	end, "Markov: artifact provenance")
	Test.throws(function()
		Markov.deserialize(tampered(function(t)
			t.provenance.firstT = t.provenance.lastT + 3600
		end))
	end, "Markov: artifact provenance")
end)

Test.case(markov, "round trip through the production Util/Json serializer (markov-model.json path)", function()
	-- MiniJson is a test helper; this proves the serializer that actually writes markov-model.json preserves the artifact.
	local rnd = lcg(19)
	local model = Markov.fit(makeStream({ randomDay(rnd, 16), randomDay(rnd, 13) }), opts())
	local text = Json.encode(Markov.serialize(model))
	local reloaded = Markov.deserialize(Json.decode(text))
	Test.eq(Json.encode(Markov.serialize(reloaded)), text, "byte-identical re-encoding")
	for a = 1, 4 do
		for b = 1, 4 do
			local x, y = Markov.predict(model, { a, b }, 8), Markov.predict(reloaded, { a, b }, 8)
			Test.eq(y[1], x[1], "SPY forecast")
			Test.eq(y[2], x[2], "QQQ forecast")
		end
	end
	Test.eq(reloaded.spy.tau, model.spy.tau, "tau exact")
	Test.eq(reloaded.provenance.sourceHashes.hourly, "fixture")
end)

Test.case(markov, "the model is frozen and independent of later caller mutation", function()
	local pairs = makeStream({ randomDay(lcg(14), 16) })
	local model = Markov.fit(pairs, opts())
	local before = Markov.serialize(model)
	pairs[10].spy[5] *= 2
	pairs[11].qqq[5] *= 0.5
	Test.deepEq(Markov.serialize(model), before)
	Test.truthy(table.isfrozen(model) and table.isfrozen(model.spy) and table.isfrozen(model.qqq.transitionCounts[1]))
end)

--------------------------------------------------------------------------------------------------
local regime = Test.suite("RegimeFeatures")

local function fittedModel(): any
	local rnd = lcg(21)
	local days = {}
	for d = 1, 6 do
		days[d] = randomDay(rnd, 16)
	end
	return Markov.fit(makeStream(days), opts())
end

local function piP(rec: any): { number }
	local out = { 0, 0, 0, 0 }
	for j = 1, 4 do
		for i = 1, 4 do
			out[j] += rec.pi[i] * rec.P[i][j]
		end
	end
	return out
end

Test.case(regime, "first three observations of a segment use pi*P with mask 0", function()
	local model = fittedModel()
	local ps, pq = piP(model.spy), piP(model.qqq)
	for offset = 1, 3 do
		local v = RegimeFeatures.compute(model, nil, offset)
		Test.eq(#v, 10)
		for j = 1, 4 do
			Test.near(v[j], ps[j], 1e-16, "SPY pi*P " .. j)
			Test.near(v[5 + j], pq[j], 1e-16, "QQQ pi*P " .. j)
		end
		Test.eq(v[5], 0, "SPY mask")
		Test.eq(v[10], 0, "QQQ mask")
	end
end)

Test.case(regime, "from the fourth observation: row i of frozen P with mask 1", function()
	local model = fittedModel()
	for offset = 4, 9 do
		local v = RegimeFeatures.compute(model, { 2, 3 }, offset)
		Test.deepEq({ v[1], v[2], v[3], v[4] }, { model.spy.P[2][1], model.spy.P[2][2], model.spy.P[2][3], model.spy.P[2][4] })
		Test.deepEq({ v[6], v[7], v[8], v[9] }, { model.qqq.P[3][1], model.qqq.P[3][2], model.qqq.P[3][3], model.qqq.P[3][4] })
		Test.eq(v[5], 1)
		Test.eq(v[10], 1)
	end
end)

Test.case(regime, "values are bounded probabilities", function()
	local model = fittedModel()
	for _, case in { { nil, 2 }, { { 1, 4 }, 5 }, { { 4, 1 }, 12 } } do
		local v = RegimeFeatures.compute(model, case[1] :: any, case[2] :: number)
		for _, block in { 0, 5 } do
			local s = 0
			for j = 1, 4 do
				Test.truthy(v[block + j] > 0 and v[block + j] < 1)
				s += v[block + j]
			end
			Test.near(s, 1, 1e-15)
		end
	end
end)

Test.case(regime, "inconsistent state/offset inputs are errors, not silent defaults", function()
	local model = fittedModel()
	Test.throws(function()
		RegimeFeatures.compute(model, { 1, 1 }, 3)
	end, "RegimeFeatures: a state cannot exist before")
	Test.throws(function()
		RegimeFeatures.compute(model, nil, 4)
	end, "RegimeFeatures: missing state")
	Test.throws(function()
		RegimeFeatures.compute(model, nil, 0)
	end, "RegimeFeatures: segmentOffset")
	Test.throws(function()
		RegimeFeatures.compute(model, nil, 1.5)
	end, "RegimeFeatures: segmentOffset")
	Test.throws(function()
		RegimeFeatures.compute(model, { 1, 5 }, 6)
	end, "RegimeFeatures: state")
end)

Test.case(regime, "R60 dimensions and default-disabled status", function()
	local profiles = Config.values.profiles
	Test.eq(RegimeFeatures.DIMENSION, 10)
	Test.eq(#RegimeFeatures.NAMES, 10)
	Test.eq(profiles.R50.dimension + RegimeFeatures.DIMENSION, profiles.R60.dimension, "D = 60")
	local D = profiles.R60.dimension
	local dims = {}
	for i, lag in Config.values.lags do
		dims[i] = (D + 1) * lag
	end
	Test.deepEq(dims, { 61, 244, 488 }, "raw lag dimensions")
	Test.eq(Config.values.maxLag * (D + 1) + 48, 536, "eight raw lags plus physics")
	Test.eq(profiles.R60.enabled, false, "R60 disabled by default")
	Test.eq(profiles.R60.required, false)
end)

return { markov, regime }
