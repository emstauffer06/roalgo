-- Spring Indicator study (spring-indicator-contract.md, SpringStudy section; handover sections 8, 9 and Task 4).
-- LEAN VERSION "lean-1", written 2026-10-05 after phase 1 was cut short at the owner's request ("cut it off early and
-- just publish and measure the result of what's done"). Not yet independently reviewed.
-- It runs the frozen spring-consensus-v1 indicator and its controls over the saved v2 history with the real
-- SpringState / SpringSignals / SpringPolicy / Execution modules, once, and stores compact rows for the replay.
--   Runs: coupled, zero, frozen, independent, numeric (physical scorer) - ema_baseline (market-only) - no_trade.
--   Ledgers per run: one continuous full_history_development ledger (drives the replay and the paired comparisons)
--   plus three partition ledgers (training_retrospective, validation, evaluation), each starting flat.
-- Directional decisions see only SpringState samples (physical runs) or EMA bank scores (baseline). Prices reach
-- only the EMA baseline adapter and Execution. No Engine, no native stepping (newNativeSteps = 0).
local SpringPolicy = if script then require(script.Parent.SpringPolicy) else require("./SpringPolicy")
local SpringState = if script then require(script.Parent.SpringState) else require("./SpringState")
local SpringSignals = if script then require(script.Parent.SpringSignals) else require("./SpringSignals")
local Execution = if script then require(script.Parent.Execution) else require("./Execution")

local SpringStudy = {}
SpringStudy.SCHEMA = "roalgo-spring-indicator-v1"
SpringStudy.VERSION = "lean-1"

local HEADERS = {
	recorded_native = "Recorded native physics · 5-minute observations · no live simulation.",
	artificial_intervention = "Artificial state intervention · not a recording",
	numerical = "Numerical comparator · not native physics",
	market_baseline = "Market-only baseline · no physical input",
	no_trade = "No-trade baseline · no physical input",
	synthetic_fixture = "Synthetic fixture · not historical evidence",
}
local RUN_DEFS = {
	{ id = "coupled", kind = "recorded_native", variant = "coupled", physical = true, label = "Coupled recorded native",
		header = HEADERS.recorded_native },
	{ id = "zero", kind = "artificial_intervention", physical = true, label = "Zero equilibrium (x = v = 0 on every row)",
		header = HEADERS.artificial_intervention .. " · all x and v set to 0" },
	{ id = "frozen", kind = "artificial_intervention", physical = true, label = "Frozen state (first calibration sample repeated)",
		header = HEADERS.artificial_intervention .. " · one recorded state repeated on every row" },
	{ id = "independent", kind = "recorded_native", variant = "independent", physical = true, label = "Independent recorded native (no coupling)",
		header = HEADERS.recorded_native .. " Independent rig: 0 coupling springs." },
	{ id = "numeric", kind = "numerical", variant = "numeric", physical = true, label = "Numerical comparator",
		header = HEADERS.numerical },
	{ id = "ema_baseline", kind = "market_baseline", physical = false, label = "EMA trend baseline (market-only, spans 3/12/48)",
		header = HEADERS.market_baseline .. " · close-to-close return EMAs" },
	{ id = "no_trade", kind = "no_trade", physical = false, label = "No trade", header = HEADERS.no_trade },
}
local RUN_IDS = {}
for i, def in RUN_DEFS do RUN_IDS[i] = def.id end
local PARTITIONS = { "training_retrospective", "validation", "evaluation" }
local VARIANTS = { "coupled", "independent", "numeric" }
local EMA_SPANS = { 3, 12, 48 }
local FLAT = table.freeze({ position = 0, pending = false, exitedThisBar = false })
local EVIDENCE = {
	implementationStatus = { pass = true, fail = true },
	physicsDependence = { fixtures_verified = true, history_verified = true, not_verified = true },
	marketEvidence = { development_only_no_fresh_holdout = true },
}

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function isInteger(x) return finite(x) and x % 1 == 0 end
local function r6(x) if x == nil then return nil end if x == 0 then return 0 end return tonumber(string.format("%.6g", x)) end
local function r10(x) if x == nil then return nil end if x == 0 then return 0 end return tonumber(string.format("%.10g", x)) end
local function round6(values) if values == nil then return nil end local out = table.create(#values) for i = 1, #values do out[i] = r6(values[i]) end return out end
local function sign(x) if x == nil then return nil end if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end

local function partitionOf(t, split)
	if t < split.trainEndT then return 1 end
	if t < split.validationEndT then return 2 end
	assert(t >= split.testStartT, "SpringStudy: a row falls between validationEndT and testStartT")
	return 3
end

-- EMA baseline inputs (handover section 8): close-to-close returns, EMAs of spans 3/12/48 initialised at the first
-- valid return, reset on the same segment breaks as the physical policy. Causal: row i uses closes up to row i.
local function baselineInputs(records)
	local out, prevObs, prevClose, emas = table.create(#records), nil, nil, nil
	for i, rec in records do
		local obs = { t = rec.bar.t, day = rec.bar.day, reset = rec.feature.reset }
		if SpringPolicy.segmentBreak(prevObs, obs) then prevClose, emas = nil, nil end
		prevObs = obs
		local close = rec.bar.c
		local valid = false
		if prevClose ~= nil and finite(close) and close > 0 then
			local r = close / prevClose - 1
			if emas == nil then
				emas = { r, r, r }
			else
				for k = 1, 3 do local alpha = 2 / (EMA_SPANS[k] + 1); emas[k] += alpha * (r - emas[k]) end
			end
			valid = true
		end
		prevClose = close
		out[i] = { valid = valid, ema = if valid then { emas[1], emas[2], emas[3] } else nil }
	end
	return out
end

local function baselineCalibrate(inputs, records, lastTraining, p)
	local cal = p.calibration
	local members, prev, warmup = {}, nil, 0
	for i = 1, lastTraining do
		local obs = { t = records[i].bar.t, day = records[i].bar.day, reset = records[i].feature.reset }
		local broke = SpringPolicy.segmentBreak(prev, obs)
		prev = obs
		warmup = SpringPolicy.nextWarmup(warmup, broke, inputs[i].valid)
		if inputs[i].valid and warmup >= cal.segmentPositionMin then members[#members + 1] = i end
	end
	local n = #members
	local coordinates, active = {}, true
	for k = 1, 3 do
		local sum = 0
		for _, i in members do sum += inputs[i].ema[k] end
		local mean = if n > 0 then sum / n else 0
		local squares = 0
		for _, i in members do local d = inputs[i].ema[k] - mean; squares += d * d end
		local std = if n > 0 then math.sqrt(squares / n) else 0
		local rms = math.sqrt(mean * mean + std * std)
		local isActive = n > 0 and std > math.max(cal.dropAbsolute, cal.dropRelative * rms)
		active = active and isActive
		coordinates[k] = { span = EMA_SPANS[k], mean = mean, std = std, rms = rms, active = isActive }
	end
	local result = { schema = "spring-ema-baseline-calibration-v1", n = n, coordinates = coordinates, available = false,
		note = "market-only performance comparator with its own training-only calibration; never measured physics" }
	if n < cal.minSamples then result.unavailableReason = "insufficient_calibration_samples"; return result end
	if not active then result.unavailableReason = "inactive_ema_coordinate"; return result end
	local absolute = table.create(n)
	for j, i in members do
		local s = 0
		for k = 1, 3 do s += math.clamp(inputs[i].ema[k] / coordinates[k].std, -cal.clip, cal.clip) / cal.clip end
		absolute[j] = math.abs(s / 3)
	end
	table.sort(absolute)
	local rank = SpringSignals.nearestRank(n, cal.quantile)
	local entry = math.clamp(absolute[rank], cal.entryMin, cal.entryMax)
	result.available = true
	result.thresholds = { quantile = cal.quantile, unclamped = absolute[rank], rank = rank, n = n, entry = entry,
		exit = cal.exitRatio * entry, bankDeadband = cal.deadbandRatio * entry }
	return result
end

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

local function newCounts()
	return { rows = 0, intents = {}, finals = {}, setups = { positive = 0, negative = 0, none = 0 }, fills = {},
		bars = { long = 0, short = 0, flat = 0 }, invalid = 0 }
end
local function bump(map, key) map[key] = (map[key] or 0) + 1 end

-- One ledger over rows [first, last]. The machine is warmed on all earlier rows with a flat context (intents
-- discarded) and then reset at the boundary (contract SpringStudy section).
local function runLedger(records, first, last, makeMachine, stepMachine, keep, physical)
	local machine = makeMachine()
	for i = 1, first - 1 do stepMachine(machine, i, FLAT) end
	if first > 1 then machine:resetBoundary() end
	local ledger = Execution.new()
	local rows, raw = if keep then table.create(last - first + 1) else nil, if keep then table.create(last - first + 1) else nil
	for i = first, last do
		local rec = records[i]
		local row = ledger:stepIntent(rec.bar, { volatility = rec.feature.volatility, ready = rec.feature.ready }, function(ctx)
			return stepMachine(machine, i, ctx)
		end)
		if keep then
			rows[#rows + 1] = compactRow(row, physical)
			local d = row.intent.diagnostics or {}
			local fills = {}
			for _, f in row.executions do fills[#fills + 1] = f.action .. ":" .. tostring(f.source) end
			raw[#raw + 1] = { valid = d.valid, score = d.score, setup = d.setup or "none", intent = row.intent.action,
				intentSource = row.intent.source, final = row.signal, finalSource = row.signalSource,
				fills = table.concat(fills, ","), executions = row.executions, position = row.position,
				contributions = d.nodeContributions }
		end
	end
	local res = ledger:result()
	return { summary = trimSummary(res.summary, #res.rows), trades = trimTrades(res.trades), rows = rows, raw = raw }
end

local function compare(rawA, rawB, part, bucket)
	local c = { rows = 0, bothScored = 0, meanAbsScoreDiff = 0, signDisagreements = 0, setupDifferences = 0,
		intentActionDifferences = 0, emittedActionDifferences = 0, emittedLongSide = 0, emittedShortSide = 0, emittedCloseSide = 0,
		finalActionDifferences = 0, executedFillDifferences = 0 }
	local sumAbs = 0
	for i = 1, #rawA do
		if bucket == 0 or part[i] == bucket then
			local a, b = rawA[i], rawB[i]
			c.rows += 1
			if a.valid and b.valid and a.score ~= nil and b.score ~= nil then
				c.bothScored += 1
				sumAbs += math.abs(a.score - b.score)
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
	end
	c.meanAbsScoreDiff = if c.bothScored > 0 then sumAbs / c.bothScored else nil
	return c
end

function SpringStudy.evaluate(records, split, descriptor, protocol)
	local p = SpringPolicy.validateProtocol(protocol)
	SpringState.checkDescriptor(descriptor)
	assert(type(records) == "table" and #records > 0, "SpringStudy: records required")
	assert(type(split) == "table" and finite(split.trainEndT) and finite(split.validationEndT) and finite(split.testStartT),
		"SpringStudy: split {trainEndT, validationEndT, testStartT} required")
	local N = #records

	-- Timeline and contiguous chronological partitions.
	local timeline, part, ranges = table.create(N), table.create(N), { {}, {}, {} }
	for i, rec in records do
		local pc = partitionOf(rec.bar.t, split)
		assert(i == 1 or pc >= part[i - 1], "SpringStudy: partitions must be chronological")
		part[i] = pc
		timeline[i] = { t = rec.bar.t, a = rec.bar.availableT, l = rec.bar.label, d = rec.bar.day, p = pc }
		ranges[pc].first = ranges[pc].first or i
		ranges[pc].last = i
	end
	for k = 1, 3 do assert(ranges[k].first, "SpringStudy: partition " .. PARTITIONS[k] .. " is empty") end

	-- Narrow samples: recorded variants, then the zero and frozen interventions.
	local samples = {}
	for _, variant in VARIANTS do
		local list = table.create(N)
		for i, rec in records do list[i] = SpringState.fromRecord(rec, variant, descriptor, variant .. ":" .. i) end
		samples[variant] = list
	end
	local training = table.move(samples.coupled, 1, ranges[1].last, 1, table.create(ranges[1].last))
	local calibration = SpringSignals.calibrate(training, descriptor, p)
	local frozenIndex = if calibration.firstSampleId then tonumber(string.match(calibration.firstSampleId, ":(%d+)$")) else nil
	local zeros = table.create(24, 0)
	local frozenX, frozenV = zeros, zeros
	if frozenIndex then frozenX, frozenV = samples.coupled[frozenIndex].x, samples.coupled[frozenIndex].v end
	samples.zero, samples.frozen = table.create(N), table.create(N)
	for i, rec in records do
		local b = rec.bar
		samples.zero[i] = SpringState.synthetic(descriptor, "zero:" .. i, b.t, b.availableT, b.day, rec.feature.reset, zeros, zeros)
		samples.frozen[i] = SpringState.synthetic(descriptor, "frozen:" .. i, b.t, b.availableT, b.day, rec.feature.reset, frozenX, frozenV)
	end

	-- Market-only EMA baseline adapter (never enters SpringSignals).
	local inputs = baselineInputs(records)
	local baseCal = baselineCalibrate(inputs, records, ranges[1].last, p)
	local baseDiag, baseObs = table.create(N), table.create(N)
	for i, rec in records do
		baseDiag[i] = baselineDiagnostics(inputs[i], baseCal, p.calibration.clip)
		baseObs[i] = { id = "ema:" .. i, t = rec.bar.t, availableT = rec.bar.availableT, day = rec.bar.day, reset = rec.feature.reset }
	end

	local function availableT(i) local b = records[i].bar return if b.availableT ~= nil then b.availableT else b.t + p.availabilityLag end

	local function machinesFor(def)
		if def.physical then
			local list = samples[def.variant or def.id]
			return function() return SpringSignals.new(calibration, p) end,
				function(machine, i, ctx) return machine:step(list[i], ctx) end
		elseif def.id == "ema_baseline" then
			local stub = { resetBoundary = function() end }
			return function()
					if baseCal.available then return SpringPolicy.new(baseCal.thresholds, p, "baseline") end
					return stub
				end,
				function(machine, i, ctx)
					if machine == stub then
						return { action = "HOLD", source = "baseline", reason = "baseline_calibration_unavailable",
							availableT = availableT(i), sampleId = "ema:" .. i, diagnostics = { valid = false, reason = "baseline_calibration_unavailable", setup = "none" } }
					end
					local intent = machine:step(baseDiag[i], baseObs[i], ctx)
					-- The shared policy names invalid inputs invalid_physics_state; for the baseline that means no prior close.
					if intent.action == "HOLD" and intent.reason == "invalid_physics_state" then intent.reason = baseDiag[i].reason end
					return intent
				end
		end
		local stub = { resetBoundary = function() end }
		return function() return stub end,
			function(_, i)
				return { action = "HOLD", source = "baseline", reason = "no_trade_comparator", availableT = availableT(i),
					sampleId = "no_trade:" .. i, diagnostics = { valid = true, setup = "none" } }
			end
	end

	-- Run every ledger.
	local runs, raws = table.create(#RUN_DEFS), {}
	for k, def in RUN_DEFS do
		local make, step = machinesFor(def)
		local full = runLedger(records, 1, N, make, step, true, def.physical)
		local partitions = {}
		for pc = 1, 3 do
			local ledger = runLedger(records, ranges[pc].first, ranges[pc].last, make, step, false, def.physical)
			partitions[PARTITIONS[pc]] = { summary = ledger.summary, trades = ledger.trades,
				startsFlat = true, warmedOnEarlierRows = ranges[pc].first - 1 }
		end
		local counts = { all = newCounts(), training_retrospective = newCounts(), validation = newCounts(), evaluation = newCounts() }
		for i, r in full.raw do
			for _, bucket in { counts.all, counts[PARTITIONS[part[i]]] } do
				bucket.rows += 1
				bump(bucket.intents, r.intent .. ":" .. tostring(r.intentSource))
				bump(bucket.finals, r.final .. ":" .. tostring(r.finalSource))
				bump(bucket.setups, r.setup)
				if r.valid == false then bucket.invalid += 1 end
				for _, f in r.executions do bump(bucket.fills, f.action .. ":" .. tostring(f.source) .. ":" .. tostring(f.reason)) end
				if r.position == 1 then bucket.bars.long += 1 elseif r.position == -1 then bucket.bars.short += 1 else bucket.bars.flat += 1 end
			end
		end
		raws[def.id] = full.raw
		runs[k] = {
			id = def.id, kind = def.kind, label = def.label, header = def.header, physical = def.physical,
			thresholds = if def.physical then (if calibration.available then calibration.thresholds else nil)
				elseif def.id == "ema_baseline" then baseCal.thresholds else nil,
			fullHistory = { label = "full_history_development", summary = full.summary, trades = full.trades, rows = full.rows },
			partitions = partitions,
			counts = counts,
		}
	end

	-- Paired comparisons against the coupled run, on the continuous full-history rows.
	local comparisons = {}
	for _, def in RUN_DEFS do
		if def.id ~= "coupled" then
			local byPart = { all = compare(raws.coupled, raws[def.id], part, 0) }
			for pc = 1, 3 do byPart[PARTITIONS[pc]] = compare(raws.coupled, raws[def.id], part, pc) end
			comparisons["coupled_vs_" .. def.id] = byPart
		end
	end

	-- Ledger comparison by partition (each partition ledger starts flat).
	local performance = {}
	for pc = 1, 3 do
		local name = PARTITIONS[pc]
		local rowsOut = {}
		local ema, none = nil, nil
		for _, run in runs do
			if run.id == "ema_baseline" then ema = run.partitions[name].summary.netReturn end
			if run.id == "no_trade" then none = run.partitions[name].summary.netReturn end
		end
		for _, run in runs do
			local s = run.partitions[name].summary
			rowsOut[run.id] = { netReturn = s.netReturn, vsNoTrade = s.netReturn - none, vsEmaBaseline = s.netReturn - ema,
				maxDrawdown = s.maxDrawdown, tradeCount = s.tradeCount, fees = s.totalFees, borrow = s.totalBorrow,
				turnover = s.totalTurnover, exposureFraction = s.exposureFraction }
		end
		performance[name] = rowsOut
	end
	local postTraining = {}
	for _, run in runs do
		local v, e = run.partitions.validation.summary.netReturn, run.partitions.evaluation.summary.netReturn
		postTraining[run.id] = (1 + v) * (1 + e) - 1
	end
	performance.postTrainingCompounded = { note = "validation ledger then evaluation ledger, each starting flat; training excluded",
		netReturn = postTraining }

	-- Invariants and evidence.
	local problems = {}
	if not calibration.available then table.insert(problems, "calibration unavailable: " .. tostring(calibration.unavailableReason)) end
	local maxSumError = 0
	for _, r in raws.coupled do
		if r.valid and r.contributions then
			local s = 0
			for _, v in r.contributions do s += v end
			maxSumError = math.max(maxSumError, math.abs(s - r.score))
		end
	end
	if maxSumError > 1e-12 then table.insert(problems, "contribution sum error " .. maxSumError) end
	local zeroNonZero = 0
	for _, r in raws.zero do if r.score ~= nil and r.score ~= 0 then zeroNonZero += 1 end end
	if zeroNonZero > 0 then table.insert(problems, zeroNonZero .. " zero-run rows scored non-zero") end
	for _, run in runs do
		if #run.fullHistory.rows ~= N then table.insert(problems, run.id .. " full-history row count mismatch") end
	end
	local fixture = fixtureCheck(calibration, descriptor, p)
	if not fixture.pass then table.insert(problems, "fixture self-check failed") end
	local zc = comparisons.coupled_vs_zero.all
	local dependence = if zc.emittedActionDifferences > 0 and fixture.pass then "history_verified"
		elseif fixture.pass then "fixtures_verified" else "not_verified"

	local coupledEmitted, zeroEmitted = 0, 0
	for _, r in raws.coupled do if r.intent ~= "HOLD" and r.intentSource == "physics" then coupledEmitted += 1 end end
	for _, r in raws.zero do if r.intent ~= "HOLD" and r.intentSource == "physics" then zeroEmitted += 1 end end

	local states = {}
	for _, variant in VARIANTS do
		local xs, vs = table.create(N), table.create(N)
		for i = 1, N do
			local s = samples[variant][i]
			xs[i] = if s.valid then round6(s.x) else false
			vs[i] = if s.valid then round6(s.v) else false
		end
		states[variant] = { x = xs, v = vs }
	end

	local counts = {}
	for pc = 1, 3 do counts[PARTITIONS[pc]] = ranges[pc].last - ranges[pc].first + 1 end

	return {
		schema = SpringStudy.SCHEMA,
		studyVersion = SpringStudy.VERSION,
		protocol = p,
		newNativeSteps = 0,
		recordCount = N,
		descriptor = descriptor,
		calibration = calibration,
		baselineCalibration = baseCal,
		split = { trainEndT = split.trainEndT, validationEndT = split.validationEndT, testStartT = split.testStartT,
			counts = counts, ranges = { { ranges[1].first, ranges[1].last }, { ranges[2].first, ranges[2].last }, { ranges[3].first, ranges[3].last } } },
		inspectedDataStatus = "all 30 sessions were inspected before this indicator was designed; validation and evaluation are development segments, not a fresh holdout",
		timeline = timeline,
		states = states,
		frozenState = { sampleId = calibration.firstSampleId, x = round6(frozenX), v = round6(frozenV) },
		runs = runs,
		comparisons = comparisons,
		performance = performance,
		evidence = {
			implementationStatus = if #problems == 0 then "pass" else "fail",
			implementationProblems = problems,
			physicsDependence = dependence,
			physicsDependenceCounts = {
				coupledVsZeroEmittedActionDifferences = zc.emittedActionDifferences,
				coupledVsZeroIntentDifferences = zc.intentActionDifferences,
				coupledVsZeroFinalDifferences = zc.finalActionDifferences,
				denominatorRows = zc.rows,
				coupledPhysicsActionsEmitted = coupledEmitted,
				zeroPhysicsActionsEmitted = zeroEmitted,
				maxContributionSumError = maxSumError,
			},
			fixtureCheck = fixture,
			marketEvidence = "development_only_no_fresh_holdout",
			tradingApproval = "experimental - not approved for trading",
		},
		limitations = {
			"Lean SpringStudy (lean-1) written after phase 1 was cut short; not yet independently reviewed.",
			"All 30 sessions were inspected before this indicator was designed: no fresh holdout exists.",
			"Training-partition rows are retrospective in-sample: the calibration used those same rows.",
			"Fast directional nodes 1/4/7 carry +0.12 x rangeActivity (always positive): a structural long tilt (contract D3); see calibration.scoreSummary.",
			"The data has 0 intraday gaps: missing-interval resets are exercised by fixtures only.",
			"Display rows are rounded to 6 significant digits (prices/equity to 10); decisions and ledgers ran at full precision.",
			"Ledger: next-open fills, 1 bp fee + 1 bp slippage per fill, 3%/yr short borrow, full-equity sizing, no margin or liquidity model; a favourable gap through a target fills at the target price.",
			"Simulated historical executions only; no live orders.",
		},
	}
end

function SpringStudy.validateResult(result)
	if type(result) ~= "table" then return false, "result must be a table" end
	if result.schema ~= SpringStudy.SCHEMA then return false, "schema must be " .. SpringStudy.SCHEMA end
	if result.newNativeSteps ~= 0 then return false, "newNativeSteps must be 0" end
	local N = result.recordCount
	if not isInteger(N) or N < 1 then return false, "recordCount must be a positive integer" end
	if type(result.timeline) ~= "table" or #result.timeline ~= N then return false, "timeline must hold recordCount rows" end
	if type(result.descriptor) ~= "table" or result.descriptor.schema ~= "spring-v2-descriptor-1" then return false, "descriptor missing" end
	if type(result.states) ~= "table" then return false, "states missing" end
	for _, variant in VARIANTS do
		local s = result.states[variant]
		if type(s) ~= "table" or type(s.x) ~= "table" or #s.x ~= N or type(s.v) ~= "table" or #s.v ~= N then
			return false, "states." .. variant .. " must hold recordCount x and v rows"
		end
	end
	if type(result.runs) ~= "table" or #result.runs ~= #RUN_DEFS then return false, "runs must hold " .. #RUN_DEFS .. " runs" end
	for k, run in result.runs do
		if run.id ~= RUN_IDS[k] then return false, "run " .. k .. " must be " .. RUN_IDS[k] end
		if HEADERS[run.kind] == nil or type(run.header) ~= "string" or string.sub(run.header, 1, #HEADERS[run.kind]) ~= HEADERS[run.kind] then
			return false, "run " .. run.id .. " header does not match its kind"
		end
		local rows = run.fullHistory and run.fullHistory.rows
		if type(rows) ~= "table" or #rows ~= N then return false, "run " .. run.id .. " must hold recordCount rows" end
		for i = 1, N, 97 do
			local r = rows[i]
			if type(r) ~= "table" or type(r.fa) ~= "string" or type(r.ia) ~= "string" or (r.po ~= -1 and r.po ~= 0 and r.po ~= 1) or not finite(r.eq) then
				return false, "run " .. run.id .. " row " .. i .. " is malformed"
			end
		end
		for _, name in PARTITIONS do
			if type(run.partitions) ~= "table" or type(run.partitions[name]) ~= "table" or type(run.partitions[name].summary) ~= "table" then
				return false, "run " .. run.id .. " partition " .. name .. " missing"
			end
		end
	end
	local e = result.evidence
	if type(e) ~= "table" then return false, "evidence missing" end
	for field, allowed in EVIDENCE do
		if not allowed[e[field]] then return false, "evidence." .. field .. " has an unknown value " .. tostring(e[field]) end
	end
	return true, nil
end

function SpringStudy.runs(result)
	local out = table.create(#result.runs)
	for k, run in result.runs do
		out[k] = { id = run.id, kind = run.kind, label = run.label, header = run.header, rowCount = #run.fullHistory.rows }
	end
	return out
end

local function findRun(result, runId)
	for _, run in result.runs do if run.id == runId then return run end end
	error("SpringStudy: unknown run " .. tostring(runId))
end

function SpringStudy.displayRow(result, runId, index)
	local run = findRun(result, runId)
	local r = run.fullHistory.rows[index]
	assert(r, "SpringStudy: row " .. tostring(index) .. " out of range")
	local tl = result.timeline[index]
	local x, v = nil, nil
	if run.physical then
		if run.id == "zero" then
			x, v = table.create(24, 0), table.create(24, 0)
		elseif run.id == "frozen" then
			x, v = result.frozenState.x, result.frozenState.v
		else
			local s = result.states[run.id]
			if s.x[index] then x, v = s.x[index], s.v[index] end
		end
	end
	local executions = {}
	for k, f in r.ex or {} do
		executions[k] = { t = f.t, action = f.a, side = f.sd, price = f.p, reason = f.r, source = f.s, signalT = f.st }
	end
	local st = r.st
	return {
		index = index, t = tl.t, availableT = tl.a, label = tl.l, day = tl.d, partition = PARTITIONS[tl.p],
		runId = run.id, runKind = run.kind, runLabel = run.label, header = run.header,
		sampleId = if run.physical then run.id .. ":" .. index else nil,
		x = x, v = v,
		diagnostics = { valid = r.ok ~= false, reason = r.rs, score = r.s, bankScores = r.b,
			nodeContributions = if run.physical then r.c else nil },
		thresholds = run.thresholds,
		policy = { setup = r.su, blocked = r.bl, warmup = st and st[1], posConfirm = st and st[2], negConfirm = st and st[3],
			longExit = st and st[4], shortExit = st and st[5] },
		intent = { action = r.ia, source = r.is, reason = r.ir },
		final = { action = r.fa, source = r.fs, reason = r.fr, overridden = r.ov == true, riskConditions = r.rc or {} },
		pending = if r.pe then { action = r.pe.a, source = r.pe.s, reason = r.pe.r, signalT = r.pe.t } else nil,
		position = r.po, holdBars = r.hb, equity = r.eq, stop = r.sp, target = r.tg,
		executions = executions,
		evidence = { implementationStatus = result.evidence.implementationStatus, physicsDependence = result.evidence.physicsDependence,
			marketEvidence = result.evidence.marketEvidence },
	}
end

return SpringStudy
