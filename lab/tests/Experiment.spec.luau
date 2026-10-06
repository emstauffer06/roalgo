-- Experiment: deterministic PRNG, append-only ledger and outcome store, evaluator, non-overlap subset,
-- and the paired moving-block bootstrap. Synthetic fixtures only; no real validation/final data is read.
local Test = require("./Test")
local Prng = require("../src/Util/Prng")
local Ledger = require("../src/Experiment/Ledger")

local suites = {}

---------------------------------------------------------------------------------------------------
-- Prng
---------------------------------------------------------------------------------------------------
local prngSuite = Test.suite("Prng")
table.insert(suites, prngSuite)

Test.case(prngSuite, "xoshiro128** reproduces the published vector for state {1,2,3,4}", function()
	local g = Prng.fromState({ 1, 2, 3, 4 })
	local expected = { 11520, 0, 5927040, 70819200, 2031721883, 1637235492, 1287239034, 3734860849, 3729100597, 4258142804 }
	for i, v in expected do
		Test.eq(g:nextUint32(), v, "output " .. i)
	end
end)

Test.case(prngSuite, "SplitMix64 seeding reproduces the published vector for seed 1234567", function()
	-- 6457827717110365317, 3203168211198807973, 9817491932198370423, 4593380528125082431, 16408922859458223821
	local expected = {
		{ 1503580183, 4211670149 },
		{ 745795716, 1481904037 },
		{ 2285812965, 2750577783 },
		{ 1069479744, 3910630207 },
		{ 3820500071, 147545805 },
	}
	local nextWord = Prng.splitmix64(1234567)
	for i, pair in expected do
		local hi, lo = nextWord()
		Test.eq(hi, pair[1], "hi " .. i)
		Test.eq(lo, pair[2], "lo " .. i)
	end
	-- Prng.new uses the first two SplitMix64 outputs as {lo1, hi1, lo2, hi2}
	Test.deepEq(Prng.new(1234567):state(), { 4211670149, 1503580183, 1481904037, 745795716 })
end)

Test.case(prngSuite, "nextNumber is the 53-bit construction from two draws and lies in [0,1)", function()
	local a = Prng.new(20261005)
	local b = Prng.fromState(a:state())
	for _ = 1, 500 do
		local x = a:nextNumber()
		local hi = bit32.rshift(b:nextUint32(), 5)
		local lo = bit32.rshift(b:nextUint32(), 6)
		Test.eq(x, (hi * 67108864 + lo) / 9007199254740992)
		Test.truthy(x >= 0 and x < 1, "range")
	end
end)

Test.case(prngSuite, "nextInteger is inclusive, covers its range, and validates arguments", function()
	local g = Prng.new(7)
	local seen = {}
	for _ = 1, 400 do
		local v = g:nextInteger(-2, 3)
		Test.truthy(v >= -2 and v <= 3 and v == math.floor(v), "inclusive integer range")
		seen[v] = true
	end
	for v = -2, 3 do
		Test.truthy(seen[v], "value " .. v .. " drawn")
	end
	Test.eq(g:nextInteger(5, 5), 5)
	Test.throws(function() g:nextInteger(3, 2) end, "Prng")
	Test.throws(function() g:nextInteger(0.5, 2) end, "Prng")
	Test.throws(function() g:nextInteger(0, 2 ^ 32) end, "Prng")
	local full = g:nextInteger(0, 2 ^ 32 - 1)
	Test.truthy(full >= 0 and full < 2 ^ 32)
end)

Test.case(prngSuite, "seeding is deterministic and validated", function()
	local a, b = Prng.new(42), Prng.new(42)
	for _ = 1, 50 do
		Test.eq(a:nextUint32(), b:nextUint32())
	end
	Test.truthy(Prng.new(42):nextUint32() ~= Prng.new(43):nextUint32(), "different seeds differ")
	Test.throws(function() Prng.new(-1) end, "seed")
	Test.throws(function() Prng.new(1.5) end, "seed")
	Test.throws(function() Prng.new(0 / 0) end, "seed")
	Test.throws(function() Prng.new(2 ^ 53) end, "seed")
	Test.throws(function() Prng.fromState({ 0, 0, 0, 0 }) end, "zero")
	Test.throws(function() Prng.fromState({ 1, 2, 3 }) end, "state")
	-- state() is a copy: mutating it does not change the generator
	local g = Prng.new(9)
	local s = g:state()
	local first = s[1]
	s[1] = (first + 1) % 4294967296
	Test.eq(g:state()[1], first, "state() returns a copy")
end)

---------------------------------------------------------------------------------------------------
-- Ledger and outcomes
---------------------------------------------------------------------------------------------------
local ledgerSuite = Test.suite("Ledger")
table.insert(suites, ledgerSuite)

local RUN = "run-1"
local T0 = 1600000000 -- synthetic timestamp (2020-09-13), multiple of 3600 not required

local function makeForecast(modelId: string, symbol: string, t: number, prediction: number, runId: string?): any
	local r = runId or RUN
	return {
		id = r .. ":" .. modelId .. ":" .. symbol .. ":" .. tostring(t),
		runId = r,
		modelId = modelId,
		symbol = symbol,
		t = t,
		decisionTime = t + 3600,
		outcomeTime = t + 9 * 3600,
		prediction = prediction,
		modelHash = "mh",
		dataHash = "dh",
	}
end

Test.case(ledgerSuite, "plan immutability test: duplicate IDs are rejected and the saved value is kept", function()
	local ledger = Ledger.new({ runId = RUN })
	local forecast = makeForecast("O14-RAW", "SPY", T0, 0.0012)
	ledger:append(forecast)
	local ok = pcall(function()
		ledger:append(forecast)
	end)
	Test.falsy(ok, "Duplicate forecast IDs must be rejected")
	local saved = ledger:page(1, 1)[1]
	Test.eq(saved.prediction, forecast.prediction)
	Test.eq(ledger:count(), 1)
end)

Test.case(ledgerSuite, "caller mutation after append cannot alter the stored forecast", function()
	local ledger = Ledger.new({ runId = RUN })
	local forecast = makeForecast("O14-RAW", "SPY", T0, 0.5)
	ledger:append(forecast)
	forecast.prediction = 99
	forecast.modelHash = "changed"
	local saved = ledger:get(forecast.id)
	Test.eq(saved.prediction, 0.5)
	Test.eq(saved.modelHash, "mh")
	Test.truthy(table.isfrozen(saved), "stored record is frozen")
	Test.throws(function() (saved :: any).prediction = 1 end, "readonly")
	-- a returned page is a fresh array; mutating it does not change the ledger
	local page = ledger:page(1, 10)
	page[1] = nil :: any
	Test.eq(ledger:count(), 1)
	Test.eq(ledger:page(1, 1)[1].prediction, 0.5)
end)

Test.case(ledgerSuite, "IDs are deterministic and validated", function()
	Test.eq(Ledger.forecastId("run_A-1", "R50-RAW_PHYSICS", "QQQ", 1704186000), "run_A-1:R50-RAW_PHYSICS:QQQ:1704186000")
	local p = Ledger.parseId("run_A-1:R50-RAW_PHYSICS:QQQ:1704186000")
	Test.eq(p.runId, "run_A-1")
	Test.eq(p.modelId, "R50-RAW_PHYSICS")
	Test.eq(p.symbol, "QQQ")
	Test.eq(p.t, 1704186000)
	Test.throws(function() Ledger.new({ runId = "bad:run" }) end, "runId")
	Test.throws(function() Ledger.new({ runId = "" }) end, "runId")
	Test.throws(function() Ledger.new({ runId = "has space" }) end, "runId")
	local ledger = Ledger.new({ runId = RUN })
	Test.throws(function() ledger:append(makeForecast("RAW+PHYSICS", "SPY", T0, 0)) end, "modelId")
	Test.throws(function() ledger:append(makeForecast("a:b", "SPY", T0, 0)) end, "modelId")
	local wrongId = makeForecast("M", "SPY", T0, 0)
	wrongId.id = RUN .. ":M:SPY:" .. tostring(T0 + 1)
	Test.throws(function() ledger:append(wrongId) end, "id")
	Test.throws(function() ledger:append(makeForecast("M", "SPY", T0, 0, "other-run")) end, "run")
	Test.eq(ledger:count(), 0, "rejected appends leave no trace")
end)

Test.case(ledgerSuite, "predictions and times must be finite and causal", function()
	local ledger = Ledger.new({ runId = RUN })
	Test.throws(function() ledger:append(makeForecast("M", "SPY", T0, 0 / 0)) end, "prediction")
	Test.throws(function() ledger:append(makeForecast("M", "SPY", T0, math.huge)) end, "prediction")
	Test.throws(function() ledger:append(makeForecast("M", "SPY", T0, -math.huge)) end, "prediction")
	local f = makeForecast("M", "SPY", T0, 0)
	f.prediction = "0" :: any
	Test.throws(function() ledger:append(f) end, "prediction")
	local early = makeForecast("M", "SPY", T0, 0)
	early.decisionTime = T0
	Test.throws(function() ledger:append(early) end, "decisionTime")
	local short = makeForecast("M", "SPY", T0, 0)
	short.outcomeTime = T0 + 8 * 3600
	Test.throws(function() ledger:append(short) end, "outcomeTime")
	local frac = makeForecast("M", "SPY", T0 + 0.5, 0)
	Test.throws(function() ledger:append(frac) end, "t")
	local extra = makeForecast("M", "SPY", T0, 0)
	extra.actual = 0.01
	Test.throws(function() ledger:append(extra) end, "unknown field")
	local noHash = makeForecast("M", "SPY", T0, 0)
	noHash.modelHash = ""
	Test.throws(function() ledger:append(noHash) end, "modelHash")
	Test.eq(ledger:count(), 0)
end)

Test.case(ledgerSuite, "records with a metatable are rejected (validated fields must be the stored fields)", function()
	-- A proxy whose fields come from __index passes field-by-field validation but has no raw fields to copy;
	-- storing it would freeze an empty record into the ledger.
	local ledger = Ledger.new({ runId = RUN })
	local proxy = setmetatable({}, { __index = makeForecast("M", "SPY", T0, 0.25) })
	Test.throws(function() ledger:append(proxy :: any) end, "metatable")
	Test.eq(ledger:count(), 0, "nothing stored")
	Test.eq(ledger:get(RUN .. ":M:SPY:" .. tostring(T0)), nil)
	local failureProxy = setmetatable({}, { __index = { runId = RUN, modelId = "M", symbol = "QQQ", t = T0, reason = "x" } })
	Test.throws(function() ledger:appendFailure(failureProxy :: any) end, "metatable")
	Test.eq(ledger:failureCount(), 0)
	local outcomes = Ledger.newOutcomes({ runId = RUN })
	local outcomeProxy = setmetatable({}, {
		__index = { forecastId = Ledger.forecastId(RUN, "M", "SPY", T0), eligible = true, actual = 0.01 },
	})
	Test.throws(function() outcomes:add(outcomeProxy :: any) end, "metatable")
	Test.eq(outcomes:count(), 0)
	-- a frozen plain record (for example one read back from another ledger) is still accepted
	local other = Ledger.new({ runId = RUN })
	ledger:append(makeForecast("M", "SPY", T0, 0.25))
	other:append(ledger:page(1, 1)[1])
	Test.eq(other:get(RUN .. ":M:SPY:" .. tostring(T0)).prediction, 0.25)
end)

Test.case(ledgerSuite, "pages are ordered and bounded", function()
	local ledger = Ledger.new({ runId = RUN })
	for i = 1, 7 do
		ledger:append(makeForecast("M", "SPY", T0 + i * 3600, i / 100))
	end
	Test.eq(ledger:count(), 7)
	local p = ledger:page(3, 2)
	Test.eq(#p, 2)
	Test.eq(p[1].prediction, 0.03)
	Test.eq(p[2].prediction, 0.04)
	Test.eq(#ledger:page(6, 10), 2)
	Test.eq(#ledger:page(8, 10), 0)
	Test.eq(#ledger:page(1, 0), 0)
	Test.throws(function() ledger:page(0, 1) end, "start")
	Test.throws(function() ledger:page(1, -1) end, "limit")
	Test.throws(function() ledger:page(1.5, 1) end, "start")
end)

Test.case(ledgerSuite, "failures are separate records, never numeric zero forecasts", function()
	local ledger = Ledger.new({ runId = RUN })
	ledger:append(makeForecast("PHYS", "SPY", T0, 0.001))
	ledger:appendFailure({ runId = RUN, modelId = "PHYS", symbol = "QQQ", t = T0, reason = "physics_saturation" })
	Test.eq(ledger:count(), 1, "a failure is not a forecast")
	Test.eq(ledger:failureCount(), 1)
	local failure = ledger:failurePage(1, 1)[1]
	Test.eq(failure.id, RUN .. ":PHYS:QQQ:" .. tostring(T0))
	Test.eq(failure.reason, "physics_saturation")
	Test.eq(failure.prediction, nil, "no numeric prediction on a failure")
	Test.eq(ledger:get(failure.id), nil, "failure id has no forecast")
	Test.truthy(table.isfrozen(failure))
	-- a forecast cannot be added for an id that already failed, and vice versa
	Test.throws(function() ledger:append(makeForecast("PHYS", "QQQ", T0, 0)) end, "failure")
	Test.throws(function()
		ledger:appendFailure({ runId = RUN, modelId = "PHYS", symbol = "SPY", t = T0, reason = "x" })
	end, "forecast")
	Test.throws(function()
		ledger:appendFailure({ runId = RUN, modelId = "PHYS", symbol = "SPY", t = T0 + 3600, reason = "x", prediction = 0 })
	end, "prediction")
	Test.throws(function()
		ledger:appendFailure({ runId = RUN, modelId = "PHYS", symbol = "SPY", t = T0 + 3600, reason = "" })
	end, "reason")
end)

Test.case(ledgerSuite, "outcomes are a separate store; adding one never mutates a forecast", function()
	local ledger = Ledger.new({ runId = RUN })
	local f = makeForecast("M", "SPY", T0, 0.002)
	ledger:append(f)
	local before = ledger:get(f.id)
	local outcomes = Ledger.newOutcomes({ runId = RUN })
	local o = { forecastId = f.id, eligible = true, actual = 0.004 }
	outcomes:add(o)
	o.actual = 1 -- caller mutation after add
	local after = ledger:get(f.id)
	Test.eq(after, before, "same frozen record")
	Test.eq(after.actual, nil)
	Test.eq(outcomes:get(f.id).actual, 0.004)
	Test.truthy(table.isfrozen(outcomes:get(f.id)))
	Test.eq(outcomes:count(), 1)
	Test.throws(function() outcomes:add({ forecastId = f.id, eligible = true, actual = 0.004 }) end, "duplicate")
	-- eligibility contract
	local id2 = Ledger.forecastId(RUN, "M", "SPY", T0 + 3600)
	Test.throws(function() outcomes:add({ forecastId = id2, eligible = true }) end, "actual")
	Test.throws(function() outcomes:add({ forecastId = id2, eligible = true, actual = 0 / 0 }) end, "actual")
	Test.throws(function() outcomes:add({ forecastId = id2, eligible = false, actual = 0.1, exclusionReason = "missing_target" }) end, "actual")
	Test.throws(function() outcomes:add({ forecastId = id2, eligible = false, exclusionReason = "made_up" }) end, "exclusionReason")
	Test.throws(function() outcomes:add({ forecastId = id2, eligible = true, actual = 0.1, exclusionReason = "missing_target" }) end, "exclusionReason")
	Test.throws(function() outcomes:add({ forecastId = "other-run:M:SPY:" .. tostring(T0), eligible = true, actual = 0 }) end, "run")
	outcomes:add({ forecastId = id2, eligible = false, exclusionReason = "missing_intermediate_hour" })
	Test.eq(outcomes:count(), 2)
	Test.eq(#outcomes:page(1, 5), 2)
end)

---------------------------------------------------------------------------------------------------
-- Evaluator
---------------------------------------------------------------------------------------------------
local Evaluator = require("../src/Experiment/Evaluator")
local Json = require("../src/Util/Json")
local SyntheticRun = require("./fixtures/SyntheticRun")

local evalSuite = Test.suite("Evaluator")
table.insert(suites, evalSuite)

local function key(model: string, symbol: string, split: string): string
	return SyntheticRun.RUN .. ":" .. model .. "|" .. symbol .. "|" .. split
end

Test.case(evalSuite, "plan metric fixture: MAE, RMSE, direction, zero-prediction count", function()
	local m = Evaluator.pointMetrics({
		{ prediction = 0.00, actual = 0.01 },
		{ prediction = -0.01, actual = -0.02 },
		{ prediction = 0.02, actual = 0.03 },
	})
	Test.eq(m.n, 3)
	Test.near(m.mae, 0.01, 1e-15, "MAE")
	Test.near(m.rmse, 0.01, 1e-15, "RMSE")
	Test.near(m.maeBps, 100, 1e-11, "MAE bps")
	Test.near(m.rmseBps, 100, 1e-11, "RMSE bps")
	Test.eq(m.directionCorrect, 2)
	Test.eq(m.directionTotal, 3)
	Test.near(m.directionAccuracy, 2 / 3, 1e-15)
	Test.eq(m.zeroPredictions, 1, "zero prediction counted and incorrect")
	Test.eq(m.zeroActuals, 0)
	Test.near(m.alwaysUpAccuracy, 2 / 3, 1e-15, "always-up benchmark")
	Test.near(m.meanPrediction, 0.01 / 3, 1e-17)
	Test.near(m.meanActual, 0.02 / 3, 1e-17)
end)

Test.case(evalSuite, "zero actuals are excluded from direction; correlation undefined at zero variance", function()
	local m = Evaluator.pointMetrics({
		{ prediction = 0.1, actual = 0 },
		{ prediction = 0.1, actual = 0.02 },
		{ prediction = 0.1, actual = -0.01 },
	})
	Test.eq(m.zeroActuals, 1)
	Test.eq(m.directionTotal, 2)
	Test.eq(m.directionCorrect, 1)
	Test.eq(m.correlation, nil, "constant predictions -> correlation undefined")
	Test.eq(m.forecastDispersion, 0)
	local c = Evaluator.pointMetrics({
		{ prediction = 0.1, actual = 0.02 },
		{ prediction = 0.2, actual = 0.04 },
		{ prediction = 0.4, actual = 0.08 },
	})
	Test.near(c.correlation, 1, 1e-12)
	local constActual = Evaluator.pointMetrics({ { prediction = 1, actual = 0.1 }, { prediction = 2, actual = 0.1 } })
	Test.eq(constActual.correlation, nil, "constant actuals -> correlation undefined")
	local empty = Evaluator.pointMetrics({})
	Test.eq(empty.n, 0)
	Test.eq(empty.rmse, nil)
	Test.eq(empty.directionAccuracy, nil)
	Test.throws(function() Evaluator.pointMetrics({ { prediction = 0 / 0, actual = 0 } }) end, "finite")
end)

Test.case(evalSuite, "population, coverage and exclusions per model/symbol/split; ids keep models apart", function()
	local run = SyntheticRun.build({ dropPhysics = true })
	local result = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits, failures = run.failures, originInfo = run.originInfo,
	})
	-- 3 models x 2 symbols x 3 splits
	Test.eq(#result.groups, 18)
	for _, model in SyntheticRun.MODELS do
		for _, symbol in SyntheticRun.SYMBOLS do
			local tr = result.byKey[key(model, symbol, "train")]
			Test.eq(tr.eligible, 14, "train eligible " .. model .. symbol)
			Test.eq(tr.excluded.missing_target, 3)
			Test.eq(tr.excluded.missing_intermediate_hour, 1)
			Test.eq(tr.excluded.split_boundary, 1)
			Test.eq(tr.excluded.insufficient_warmup, 0)
			Test.eq(tr.issuedExcluded, 5, "forecasts issued at excluded origins stay counted")
			Test.eq(result.byKey[key(model, symbol, "validation")].eligible, 10)
			Test.eq(result.byKey[key(model, symbol, "final")].eligible, 10)
		end
	end
	local phys = result.byKey[key("O14-PHYSICS", "QQQ", "validation")]
	Test.eq(phys.missing, 1, "missing physics forecast stays visible")
	Test.eq(phys.failures, 1)
	Test.eq(phys.n, 9)
	Test.eq(phys.issuedEligible, 9)
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "QQQ", "validation")].missing, 0)
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "QQQ", "validation")].n, 10)
	Test.eq(result.comparison.status, "incomplete")
	Test.eq(#result.comparison.incompleteGroups, 1)
	Test.eq(result.comparison.incompleteGroups[1].modelId, "O14-PHYSICS")
end)

Test.case(evalSuite, "group metrics equal a direct recomputation from the fixture", function()
	local run = SyntheticRun.build()
	local allModels = {}
	for _, model in SyntheticRun.MODELS do
		table.insert(allModels, SyntheticRun.RUN .. ":" .. model)
	end
	local result = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits, originInfo = run.originInfo, requiredModels = allModels,
	})
	Test.eq(result.comparison.status, "complete")
	-- direct recomputation for one group
	local byId = {}
	for _, o in run.outcomes do
		byId[o.forecastId] = o
	end
	local sse, sae, n = 0, 0, 0
	for _, f in run.forecasts do
		local o = byId[f.id]
		if f.modelId == "O14-PHYSICS" and f.symbol == "SPY" and o.eligible and f.decisionTime >= run.splits.validationStart
			and f.decisionTime < run.splits.testStart then
			local e = f.prediction - o.actual
			sse += e * e
			sae += math.abs(e)
			n += 1
		end
	end
	local g = result.byKey[key("O14-PHYSICS", "SPY", "validation")]
	Test.eq(g.n, n)
	Test.near(g.rmse, math.sqrt(sse / n), 1e-15)
	Test.near(g.mae, sae / n, 1e-15)
	-- the constant Markov model has undefined correlation and zero dispersion
	local mk = result.byKey[key("O14-MARKOV", "SPY", "train")]
	Test.eq(mk.correlation, nil)
	Test.eq(mk.forecastDispersion, 0)
	Test.near(mk.meanPrediction, 0.0001, 1e-18)
	-- the zero actual is excluded from direction; the zero RAW prediction is counted and incorrect
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "SPY", "train")].zeroActuals, 1)
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "SPY", "train")].directionTotal, 13)
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "QQQ", "train")].zeroPredictions, 1)
end)

Test.case(evalSuite, "benchmarks: always-up and training-majority direction", function()
	local run = SyntheticRun.build()
	local result = Evaluator.score(run.forecasts, run.outcomes, { splits = run.splits })
	for _, symbol in SyntheticRun.SYMBOLS do
		local up, down = 0, 0
		for _, o in run.origins do
			if o.eligible and o.dayIndex <= 2 then
				local a = run.actualOf[symbol .. "@" .. tostring(o.t)]
				if a > 0 then up += 1 elseif a < 0 then down += 1 end
			end
		end
		local majority = if up >= down then "up" else "down"
		Test.eq(result.trainingMajority[symbol], majority, "majority " .. symbol)
		local g = result.byKey[key("O14-PHYSICS", symbol, "validation")]
		local vu, vn = 0, 0
		for _, o in run.origins do
			if o.eligible and (o.dayIndex == 3 or o.dayIndex == 4) then
				local a = run.actualOf[symbol .. "@" .. tostring(o.t)]
				if a ~= 0 then
					vn += 1
					if a > 0 then vu += 1 end
				end
			end
		end
		Test.near(g.alwaysUpAccuracy, vu / vn, 1e-15)
		local expectedMajority = if majority == "up" then vu / vn else (vn - vu) / vn
		Test.near(g.trainingMajorityAccuracy, expectedMajority, 1e-15)
	end
end)

Test.case(evalSuite, "monthly, origin-hour and segment-age breakdowns keep missing coverage visible", function()
	local run = SyntheticRun.build({ dropPhysics = true })
	local result = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits, failures = run.failures, originInfo = run.originInfo,
	})
	local g = result.byKey[key("O14-PHYSICS", "QQQ", "validation")]
	local months = g.breakdowns.month
	Test.eq(#months, 1)
	Test.eq(months[1].key, "2020-10")
	Test.eq(months[1].eligible, 10)
	Test.eq(months[1].missing, 1)
	Test.eq(months[1].n, 9)
	local trainMonths = result.byKey[key("O14-PHYSICS", "QQQ", "train")].breakdowns.month
	Test.eq(#trainMonths, 1)
	Test.eq(trainMonths[1].key, "2020-09")
	local hours = g.breakdowns.hour
	Test.eq(#hours, 5, "hours 8..12 eligible")
	local sumN, sumMissing = 0, 0
	for i, b in hours do
		Test.eq(b.key, 7 + i)
		sumN += b.n
		sumMissing += b.missing
	end
	Test.eq(sumN, 9)
	Test.eq(sumMissing, 1)
	Test.eq(hours[3].missing, 1, "the dropped forecast was at hour 10")
	Test.eq(#g.breakdowns.segmentAge, 5)
	Test.eq(g.breakdowns.segmentAge[1].key, 4)
	-- without originInfo, breakdowns are absent rather than guessed
	local bare = Evaluator.score(run.forecasts, run.outcomes, { splits = run.splits, failures = run.failures })
	Test.eq(bare.byKey[key("O14-PHYSICS", "QQQ", "validation")].breakdowns, nil)
end)

Test.case(evalSuite, "a required model with no records is entirely missing and blocks completion", function()
	local run = SyntheticRun.build()
	local result = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits, requiredModels = { SyntheticRun.RUN .. ":O14-RAW_PHYSICS" },
	})
	Test.eq(result.comparison.status, "incomplete")
	local g = result.byKey[key("O14-RAW_PHYSICS", "SPY", "validation")]
	Test.eq(g.eligible, 10)
	Test.eq(g.missing, 10)
	Test.eq(g.n, 0)
	Test.eq(g.rmse, nil)
end)

Test.case(evalSuite, "a comparison is complete only against a declared required-model list", function()
	-- The physics model left no forecasts, failures or outcomes at all (e.g. its run never exported).
	local run = SyntheticRun.build()
	local forecasts, outcomes = {}, {}
	for _, f in run.forecasts do
		if f.modelId ~= "O14-PHYSICS" then
			table.insert(forecasts, f)
		end
	end
	for _, o in run.outcomes do
		if not string.find(o.forecastId, ":O14-PHYSICS:", 1, true) then
			table.insert(outcomes, o)
		end
	end
	local undeclared = Evaluator.score(forecasts, outcomes, { splits = run.splits })
	Test.truthy(undeclared.comparison.status ~= "complete", "an absent model cannot be certified complete by omission")
	Test.eq(undeclared.comparison.status, "undeclared")
	Test.eq(#undeclared.comparison.requiredModels, 0)
	local declared = Evaluator.score(forecasts, outcomes, {
		splits = run.splits,
		requiredModels = { SyntheticRun.RUN .. ":O14-RAW_RIDGE", SyntheticRun.RUN .. ":O14-PHYSICS" },
	})
	Test.eq(declared.comparison.status, "incomplete")
	Test.eq(#declared.comparison.requiredModels, 2)
	-- with every declared model present at every eligible origin the comparison is complete
	local full = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits,
		requiredModels = { SyntheticRun.RUN .. ":O14-RAW_RIDGE", SyntheticRun.RUN .. ":O14-PHYSICS" },
	})
	Test.eq(full.comparison.status, "complete")
	-- missing coverage in a model outside the declared list still blocks completion
	local dropped = SyntheticRun.build({ dropPhysics = true })
	local partial = Evaluator.score(dropped.forecasts, dropped.outcomes, {
		splits = dropped.splits, failures = dropped.failures, requiredModels = { SyntheticRun.RUN .. ":O14-RAW_RIDGE" },
	})
	Test.eq(partial.comparison.status, "incomplete")
end)

Test.case(evalSuite, "correlation stays finite and scale-invariant at extreme magnitudes", function()
	local function rows(scale: number)
		return {
			{ prediction = 1 * scale, actual = 2 * scale },
			{ prediction = 2 * scale, actual = 3 * scale },
			{ prediction = 4 * scale, actual = 7 * scale },
		}
	end
	-- deviations p: -4/3, -1/3, 5/3 and a: -2, -1, 3 -> cov 8, sum p^2 42/9, sum a^2 14
	local reference = 8 / math.sqrt((42 / 9) * 14)
	Test.near(Evaluator.pointMetrics(rows(1)).correlation :: number, reference, 1e-15, "reference correlation")
	for _, scale in { 1e-170, 1e-100, 1e100, 1e150 } do
		local c = Evaluator.pointMetrics(rows(scale)).correlation
		Test.truthy(type(c) == "number" and c == c and math.abs(c :: number) <= 1 + 1e-15, "finite at scale " .. tostring(scale))
		Test.near(c :: number, reference, 1e-12, "same correlation at scale " .. tostring(scale))
	end
end)

Test.case(evalSuite, "joins are strict: unmatched, duplicated, or inconsistent records fail loudly", function()
	local run = SyntheticRun.build()
	local fewer = table.clone(run.outcomes)
	table.remove(fewer, 1)
	Test.throws(function() Evaluator.score(run.forecasts, fewer, { splits = run.splits }) end, "no outcome")
	local dup = table.clone(run.forecasts)
	table.insert(dup, run.forecasts[1])
	Test.throws(function() Evaluator.score(dup, run.outcomes, { splits = run.splits }) end, "duplicate")
	-- one model claims a different actual for the same symbol/timestamp
	local bent = table.clone(run.outcomes)
	for i, o in bent do
		if o.eligible and string.find(o.forecastId, "O14-MARKOV", 1, true) then
			bent[i] = { forecastId = o.forecastId, eligible = true, actual = (o.actual :: number) + 1e-9 }
			break
		end
	end
	Test.throws(function() Evaluator.score(run.forecasts, bent, { splits = run.splits }) end, "inconsistent")
	-- an eligible outcome whose horizon crosses a split boundary is rejected
	local crossing = Evaluator.score(run.forecasts, run.outcomes, { splits = run.splits })
	Test.truthy(crossing)
	-- validation now starts at date-2 19:00: the date-2 hour-10 origin (outcome 19:00) crosses it
	local tightSplits = { validationStart = run.splits.validationStart - 5 * 3600, testStart = run.splits.testStart,
		datasetEnd = run.splits.datasetEnd }
	Test.throws(function() Evaluator.score(run.forecasts, run.outcomes, { splits = tightSplits }) end, "split")
end)

Test.case(evalSuite, "profiles in different runs must share identical eligible timestamp sets", function()
	local run = SyntheticRun.build()
	local function rerun(list: { any }, field: string, newRun: string): { any }
		local out = {}
		for _, r in list do
			local c = table.clone(r)
			assert(string.sub(c[field], 1, #SyntheticRun.RUN + 1) == SyntheticRun.RUN .. ":")
			c[field] = newRun .. string.sub(c[field], #SyntheticRun.RUN + 1)
			if c.runId then
				c.runId = newRun
			end
			table.insert(out, c)
		end
		return out
	end
	local forecasts = table.clone(run.forecasts)
	local outcomes = table.clone(run.outcomes)
	for _, f in rerun(run.forecasts, "id", "r50-run") do
		table.insert(forecasts, f)
	end
	local r50Outcomes = rerun(run.outcomes, "forecastId", "r50-run")
	local ok = Evaluator.score(forecasts, (function()
		local all = table.clone(outcomes)
		for _, o in r50Outcomes do
			table.insert(all, o)
		end
		return all
	end)(), { splits = run.splits, requiredModels = (function()
		local req = {}
		for _, runId in { SyntheticRun.RUN, "r50-run" } do
			for _, model in SyntheticRun.MODELS do
				table.insert(req, runId .. ":" .. model)
			end
		end
		return req
	end)() })
	Test.eq(#ok.groups, 2 * 3 * 2 * 3, "two runs x three models x two symbols x three splits")
	Test.eq(ok.comparison.status, "complete")
	Test.eq(ok.byKey["r50-run:O14-PHYSICS|SPY|validation"].eligible, ok.byKey[key("O14-PHYSICS", "SPY", "validation")].eligible)
	-- the rich profile marks one origin excluded that the original treats as eligible: same count is not enough
	for i, o in r50Outcomes do
		if o.eligible then
			r50Outcomes[i] = { forecastId = o.forecastId, eligible = false, exclusionReason = "missing_target" }
			break
		end
	end
	local all = table.clone(outcomes)
	for _, o in r50Outcomes do
		table.insert(all, o)
	end
	Test.throws(function() Evaluator.score(forecasts, all, { splits = run.splits }) end, "inconsistent")
end)

Test.case(evalSuite, "eligible origin sets are asserted identical per split, not inferred from coverage", function()
	local run = SyntheticRun.build()
	-- copies the run under another run id, optionally dropping every record at one origin timestamp
	local function copyRun(newRun: string, dropT: number?): ({ any }, { any })
		local fs, os = {}, {}
		for _, f in run.forecasts do
			if f.t ~= dropT then
				local c = table.clone(f)
				c.id = newRun .. string.sub(c.id, #SyntheticRun.RUN + 1)
				c.runId = newRun
				table.insert(fs, c)
			end
		end
		for _, o in run.outcomes do
			if Ledger.parseId(o.forecastId).t ~= dropT then
				local c = table.clone(o)
				c.forecastId = newRun .. string.sub(c.forecastId, #SyntheticRun.RUN + 1)
				table.insert(os, c)
			end
		end
		return fs, os
	end
	local function merged(extra: { any }): { any }
		local all = table.clone(run.outcomes)
		for _, o in extra do
			table.insert(all, o)
		end
		return all
	end
	local validationT, trainT
	for _, o in run.origins do
		if o.eligible and o.dayIndex == 3 and not validationT then
			validationT = o.t
		end
		if o.eligible and o.dayIndex == 0 and not trainT then
			trainT = o.t
		end
	end
	local _, same = copyRun("r50-run")
	local sets = Evaluator.eligibleOrigins(merged(same), { splits = run.splits })
	Test.eq(#sets["r50-run"].validation, 20, "10 eligible origins x 2 symbols")
	Test.deepEq(sets["r50-run"], sets[SyntheticRun.RUN])
	Evaluator.assertSameEligibleOrigins(merged(same), { SyntheticRun.RUN, "r50-run" }, nil, { splits = run.splits })
	-- a run lacking one validation origin entirely is a population mismatch, named as such
	local _, lacking = copyRun("r50-run", validationT)
	Test.throws(function()
		Evaluator.assertSameEligibleOrigins(merged(lacking), { SyntheticRun.RUN, "r50-run" }, nil, { splits = run.splits })
	end, tostring(validationT))
	-- H14-style: a different training population with identical validation/final origins passes on those splits
	local _, h14 = copyRun("h14-run", trainT)
	Evaluator.assertSameEligibleOrigins(merged(h14), { SyntheticRun.RUN, "h14-run" }, { "validation", "final" },
		{ splits = run.splits })
	Test.throws(function()
		Evaluator.assertSameEligibleOrigins(merged(h14), { SyntheticRun.RUN, "h14-run" }, { "train" }, { splits = run.splits })
	end, "population")
	-- a listed run with no outcome records at all cannot pass
	Test.throws(function()
		Evaluator.assertSameEligibleOrigins(run.outcomes, { SyntheticRun.RUN, "absent-run" }, nil, { splits = run.splits })
	end, "absent-run")
end)

Test.case(evalSuite, "split rule: upper boundaries exclusive, label reaching the boundary excluded", function()
	local s = { validationStart = 1000000, testStart = 2000000, datasetEnd = 3000000 }
	Test.eq(Evaluator.labelSplit(1000000 - 3600, 1000000 - 1, s), "train")
	Test.eq(Evaluator.labelSplit(1000000 - 3600, 1000000, s), "none", "outcome reaching validation start")
	Test.eq(Evaluator.labelSplit(1000000, 1028800, s), "validation")
	Test.eq(Evaluator.labelSplit(2000000 - 3600, 2000000, s), "none")
	Test.eq(Evaluator.labelSplit(2000000, 2028800, s), "final")
	Test.eq(Evaluator.labelSplit(3000000 - 28800, 3000000, s), "none", "outcome reaching dataset end")
	Test.eq(Evaluator.decisionSplit(1000000 - 1, s), "train")
	Test.eq(Evaluator.decisionSplit(2000000, s), "final")
	Test.eq(Evaluator.decisionSplit(3000000, s), "none")
end)

Test.case(evalSuite, "non-overlap subset: accept when decision >= previous selected outcome", function()
	-- hourly origins t0..t0+10h on one date: decisions t+1h, outcomes t+9h
	local t0 = 1601251200 + 7 * 3600
	local origins = {}
	for h = 0, 10 do
		table.insert(origins, t0 + h * 3600)
	end
	Test.deepEq(Evaluator.nonOverlap(origins), { t0, t0 + 8 * 3600 }, "boundary is inclusive")
	-- 7h later is still overlapping (decision t0+8h < outcome t0+9h)
	Test.deepEq(Evaluator.nonOverlap({ t0, t0 + 7 * 3600 }), { t0 })
	-- unsorted input, duplicates (two symbols share a timestamp) and record form
	Test.deepEq(Evaluator.nonOverlap({ { t = t0 + 8 * 3600 }, { t = t0 }, { t = t0 }, { t = t0 + 3600 } }), { t0, t0 + 8 * 3600 })
	-- one origin per synthetic date when the day has 5 consecutive eligible origins
	local run = SyntheticRun.build()
	local eligibleTrain = {}
	for _, o in run.origins do
		if o.eligible and o.dayIndex <= 2 then
			table.insert(eligibleTrain, o.t)
		end
	end
	Test.eq(#Evaluator.nonOverlap(eligibleTrain), 3, "one per date")
	Test.throws(function() Evaluator.nonOverlap({ 0 / 0 }) end, "Evaluator")
end)

Test.case(evalSuite, "non-overlap scoring population is one origin per date", function()
	local run = SyntheticRun.build()
	local result = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits, subset = "nonOverlap",
	})
	Test.eq(result.subset, "nonOverlap")
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "SPY", "train")].eligible, 3)
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "QQQ", "validation")].eligible, 2)
	Test.eq(result.byKey[key("O14-RAW_RIDGE", "SPY", "final")].n, 2)
end)

Test.case(evalSuite, "metric records are flat and JSON-encodable; joined rows carry identity and dates", function()
	local run = SyntheticRun.build({ dropPhysics = true })
	local result = Evaluator.score(run.forecasts, run.outcomes, {
		splits = run.splits, failures = run.failures, originInfo = run.originInfo,
	})
	local records = Evaluator.metricRecords(result)
	Test.eq(#records, 18)
	for _, r in records do
		Test.truthy(type(Json.encode(r)) == "string")
	end
	local joined = Evaluator.join(run.forecasts, run.outcomes, { splits = run.splits, originInfo = run.originInfo })
	-- eligible origins: (14 + 10 + 10) per symbol x 2 symbols x 3 models
	Test.eq(#joined, 34 * 2 * 3)
	local missing = 0
	for _, row in joined do
		Test.truthy(row.date ~= nil and row.modelKey ~= nil and row.symbol ~= nil)
		if row.prediction == nil then
			missing += 1
		end
	end
	Test.eq(missing, 1)
end)

---------------------------------------------------------------------------------------------------
-- Bootstrap
---------------------------------------------------------------------------------------------------
local Bootstrap = require("../src/Experiment/Bootstrap")
local bootSuite = Test.suite("Bootstrap")
table.insert(suites, bootSuite)

local RAW = SyntheticRun.RUN .. ":O14-RAW_RIDGE"
local PHYS = SyntheticRun.RUN .. ":O14-PHYSICS"
local MARKOV = SyntheticRun.RUN .. ":O14-MARKOV"
local SCALES = { SPY = 0.006, QQQ = 0.007 }

local function joinedRun(opts: any?)
	local run = SyntheticRun.build(opts)
	return Evaluator.join(run.forecasts, run.outcomes, { splits = run.splits, originInfo = run.originInfo }), run
end

Test.case(bootSuite, "a model compared with itself gives 0 and [0,0]", function()
	local joined = joinedRun()
	local iv = Bootstrap.compare(joined, {
		seed = 20261005, blockLength = 2, replicates = 300, metric = "normalizedRmse",
		targetScales = SCALES, modelA = PHYS, modelB = PHYS,
	})
	Test.eq(iv.estimate, 0)
	Test.eq(iv.lower, 0)
	Test.eq(iv.upper, 0)
	Test.eq(iv.seed, 20261005)
	Test.eq(iv.blockLength, 2)
	Test.eq(iv.replicateCount, 300)
end)

Test.case(bootSuite, "sampled indices are moving blocks of consecutive dates truncated to the date count", function()
	local prng = Prng.new(5)
	for _, m in { 7, 10, 12 } do
		for _ = 1, 50 do
			local idx = Bootstrap.sampleDateIndices(m, 3, prng)
			Test.eq(#idx, m, "truncated to the original date count")
			for i = 1, m, 3 do
				local start = idx[i]
				Test.truthy(start >= 1 and start <= m - 3 + 1, "block start range")
				for j = 1, 2 do
					if i + j <= m then
						Test.eq(idx[i + j], start + j, "consecutive dates within a block")
					end
				end
			end
		end
	end
end)

Test.case(bootSuite, "resampling carries every origin, both assets and every model of a sampled date", function()
	local joined = joinedRun()
	local dates, rowsByDate = Bootstrap.orderedDates(joined)
	Test.eq(#dates, 7)
	Test.eq(dates[1], "2020-09-28")
	local prng = Prng.new(77)
	local idx = Bootstrap.sampleDateIndices(#dates, 2, prng)
	local rows = Bootstrap.expand(dates, rowsByDate, idx)
	local occurrences: { [string]: number } = {}
	for _, i in idx do
		occurrences[dates[i]] = (occurrences[dates[i]] or 0) + 1
	end
	local perDate: { [string]: { [string]: number } } = {}
	for _, row in rows do
		perDate[row.date] = perDate[row.date] or {}
		local k = row.modelKey .. "|" .. row.symbol
		perDate[row.date][k] = (perDate[row.date][k] or 0) + 1
	end
	for date, count in occurrences do
		local original = rowsByDate[date]
		local originsOnDate = #original / 6 -- 2 symbols x 3 models
		for _, model in { RAW, PHYS, MARKOV } do
			for _, symbol in SyntheticRun.SYMBOLS do
				Test.eq(perDate[date][model .. "|" .. symbol], count * originsOnDate, date .. " " .. model .. " " .. symbol)
			end
		end
	end
	local total = 0
	for _, i in idx do
		total += #rowsByDate[dates[i]]
	end
	Test.eq(#rows, total)
end)

Test.case(bootSuite, "reproducible with the same seed; interval brackets a clear difference", function()
	local joined, run = joinedRun()
	-- a perfect "model" built from the actuals: its RMSE is 0, so the difference is negative in every replicate
	local perfect = {}
	for _, row in joined do
		if row.modelKey == RAW then
			local copy = table.clone(row)
			copy.modelKey = SyntheticRun.RUN .. ":PERFECT"
			copy.prediction = run.actualOf[row.symbol .. "@" .. tostring(row.t)]
			table.insert(perfect, copy)
		end
		table.insert(perfect, row)
	end
	local opts = {
		seed = 99, blockLength = 2, replicates = 400, metric = "normalizedRmse", targetScales = SCALES,
		modelA = SyntheticRun.RUN .. ":PERFECT", modelB = RAW,
	}
	local a = Bootstrap.compare(perfect, opts)
	local b = Bootstrap.compare(perfect, opts)
	Test.deepEq(a, b, "same seed, same interval")
	Test.truthy(a.estimate < 0 and a.upper < 0 and a.lower <= a.upper, "perfect beats RAW in every replicate")
	local c = Bootstrap.compare(joined, {
		seed = 99, blockLength = 2, replicates = 400, metric = "normalizedRmse", targetScales = SCALES,
		modelA = PHYS, modelB = RAW,
	})
	local d = Bootstrap.compare(joined, {
		seed = 100, blockLength = 2, replicates = 400, metric = "normalizedRmse", targetScales = SCALES,
		modelA = PHYS, modelB = RAW,
	})
	Test.eq(c.estimate, d.estimate, "estimate does not depend on the seed")
	Test.truthy(c.lower ~= d.lower or c.upper ~= d.upper, "different seeds resample differently")
	-- per-symbol RMSE difference equals the direct point estimate
	local spy = Bootstrap.compare(joined, {
		seed = 1, blockLength = 2, replicates = 50, metric = "rmse", symbols = { "SPY" }, modelA = PHYS, modelB = RAW,
	})
	local rs = Evaluator.score(run.forecasts, run.outcomes, { splits = run.splits })
	local sseP, sseR, n = 0, 0, 0
	for _, split in { "train", "validation", "final" } do
		local gp = rs.byKey[key("O14-PHYSICS", "SPY", split)]
		local gr = rs.byKey[key("O14-RAW_RIDGE", "SPY", split)]
		sseP += gp.rmse * gp.rmse * gp.n
		sseR += gr.rmse * gr.rmse * gr.n
		n += gp.n
	end
	Test.near(spy.estimate, math.sqrt(sseP / n) - math.sqrt(sseR / n), 1e-12)
end)

Test.case(bootSuite, "duplicate rows and inconsistent origin dates are rejected, not silently weighted", function()
	local joined = joinedRun()
	local opts = { seed = 1, blockLength = 2, replicates = 50, metric = "rmse", modelA = PHYS, modelB = RAW }
	for _, model in { RAW, PHYS } do
		local dup = table.clone(joined)
		for _, r in joined do
			if r.modelKey == model then
				table.insert(dup, r)
				break
			end
		end
		Test.throws(function() Bootstrap.compare(dup, opts) end, "duplicate", "duplicate " .. model .. " row")
	end
	-- one model's row for an origin labelled with a different date would split the origin across dates
	local bent = {}
	local bentOne = false
	for _, r in joined do
		local c = table.clone(r)
		if not bentOne and r.modelKey == PHYS then
			c.date = if r.date == "2020-09-28" then "2020-09-29" else "2020-09-28"
			bentOne = true
		end
		table.insert(bent, c)
	end
	Test.truthy(bentOne, "fixture has a PHYS row to relabel")
	Test.throws(function() Bootstrap.compare(bent, opts) end, "date")
	-- a requested symbol with no rows is an error, not a silent narrowing to the other asset
	local spyOnly = {}
	for _, r in joined do
		if r.symbol == "SPY" then
			table.insert(spyOnly, r)
		end
	end
	for _, metric in { "rmse", "mae", "normalizedRmse" } do
		Test.throws(function()
			Bootstrap.compare(spyOnly, { seed = 1, blockLength = 2, replicates = 20, metric = metric, targetScales = SCALES,
				symbols = { "SPY", "QQQ" }, modelA = PHYS, modelB = RAW })
		end, "QQQ", metric .. " with QQQ absent")
	end
end)

Test.case(bootSuite, "built-in metric path equals an independent row-level replay of the same draws", function()
	local joined = joinedRun()
	local seed, L, R = 4242, 2, 120
	local iv = Bootstrap.compare(joined, {
		seed = seed, blockLength = L, replicates = R, metric = "normalizedRmse", targetScales = SCALES,
		modelA = PHYS, modelB = RAW,
	})
	-- independent replay: distinct sorted dates, the same PRNG draws, every row of a drawn date, metric from rows
	local dateSet, dates = {}, {}
	for _, row in joined do
		if not dateSet[row.date] then
			dateSet[row.date] = true
			table.insert(dates, row.date)
		end
	end
	table.sort(dates)
	local m = #dates
	local function normRmse(sample: { any }, model: string): number
		local total = 0
		for _, sym in { "QQQ", "SPY" } do
			local sse, n = 0, 0
			for _, row in sample do
				if row.modelKey == model and row.symbol == sym then
					sse += (row.prediction - row.actual) ^ 2
					n += 1
				end
			end
			total += math.sqrt(sse / n) / SCALES[sym]
		end
		return total / 2
	end
	local function diffFor(dateList: { string }): number
		local sample = {}
		for _, d in dateList do
			for _, row in joined do
				if row.date == d then
					table.insert(sample, row)
				end
			end
		end
		return normRmse(sample, PHYS) - normRmse(sample, RAW)
	end
	Test.near(iv.estimate, diffFor(dates), 1e-12, "estimate on the original sample")
	local g = Prng.new(seed)
	local diffs = {}
	for r = 1, R do
		local drawn = {}
		while #drawn < m do
			local start = g:nextInteger(1, m - L + 1)
			for j = 0, L - 1 do
				if #drawn < m then
					table.insert(drawn, dates[start + j])
				end
			end
		end
		diffs[r] = diffFor(drawn)
	end
	table.sort(diffs)
	local function pct(p: number): number
		local h = (R - 1) * p + 1
		local lo = math.floor(h)
		return diffs[lo] + (h - lo) * (diffs[lo + 1] - diffs[lo])
	end
	Test.near(iv.lower, pct(0.025), 1e-12, "2.5th percentile")
	Test.near(iv.upper, pct(0.975), 1e-12, "97.5th percentile")
	Test.truthy(iv.lower < iv.upper, "the replay draws a non-degenerate interval")
end)

Test.case(bootSuite, "split filter and validation of inputs", function()
	local joined = joinedRun({ dropPhysics = true })
	-- the dropped physics forecast is in validation: comparing there is an incomplete pairing
	Test.throws(function()
		Bootstrap.compare(joined, { seed = 1, blockLength = 1, replicates = 10, metric = "normalizedRmse",
			targetScales = SCALES, modelA = PHYS, modelB = RAW, split = "validation" })
	end, "incomplete pairing")
	-- training has both models everywhere
	local iv = Bootstrap.compare(joined, { seed = 1, blockLength = 1, replicates = 10, metric = "normalizedRmse",
		targetScales = SCALES, modelA = PHYS, modelB = RAW, split = "train" })
	Test.eq(iv.replicateCount, 10)
	Test.throws(function()
		Bootstrap.compare(joined, { blockLength = 1, replicates = 10, metric = "normalizedRmse", targetScales = SCALES,
			modelA = PHYS, modelB = RAW, split = "train" })
	end, "seed")
	Test.throws(function()
		Bootstrap.compare(joined, { seed = 1, blockLength = 5, replicates = 10, metric = "normalizedRmse",
			targetScales = SCALES, modelA = PHYS, modelB = RAW, split = "train" })
	end, "blockLength")
	Test.throws(function()
		Bootstrap.compare(joined, { seed = 1, replicates = 10, metric = "normalizedRmse", targetScales = { SPY = 0 },
			modelA = PHYS, modelB = RAW, split = "train", blockLength = 1 })
	end, "targetScales")
	Test.throws(function()
		Bootstrap.compare(joined, { seed = 1, replicates = 10, metric = "nope", targetScales = SCALES,
			modelA = PHYS, modelB = RAW, split = "train", blockLength = 1 })
	end, "metric")
	Test.eq(Bootstrap.percentile({ 1, 2, 3, 4, 5 }, 0.5), 3)
	Test.near(Bootstrap.percentile({ 1, 2, 3, 4, 5 }, 0.025), 1.1, 1e-15)
	Test.near(Bootstrap.percentile({ 1, 2, 3, 4, 5 }, 0.975), 4.9, 1e-15)
end)

Test.case(bootSuite, "default block length and replicate count come from the plan (5 dates, 2,000)", function()
	local Config = require("../src/Config")
	Test.eq(Bootstrap.DEFAULT_BLOCK_LENGTH, 5)
	Test.eq(Bootstrap.DEFAULT_REPLICATES, 2000)
	Test.eq(Config.values.bootstrap.blockDates, Bootstrap.DEFAULT_BLOCK_LENGTH)
	local joined = joinedRun()
	local iv = Bootstrap.compare(joined, { seed = 3, metric = "normalizedRmse", targetScales = SCALES,
		modelA = PHYS, modelB = RAW })
	Test.eq(iv.blockLength, 5)
	Test.eq(iv.replicateCount, 2000)
end)

return suites
