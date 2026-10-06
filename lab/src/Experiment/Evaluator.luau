--!strict
-- Joins immutable forecasts with separately stored outcomes and computes the plan's Section 6 metrics.
--
-- Population: the union of outcome records over every model passed in, keyed by (symbol, t). Records for the
-- same (symbol, t) from different models must agree exactly (eligible flag, actual, reason) or scoring fails.
-- A model is identified by modelKey = runId..":"..modelId; its forecast for an origin is found by the exact id
-- modelKey..":"..symbol..":"..t, so equal timestamps across models and symbols never collide. An eligible
-- origin without that forecast is counted as missing (and blocks a "complete" comparison); it is never dropped.
-- comparison.status is "incomplete" when any scored model misses an eligible origin, "complete" only when
-- opts.requiredModels was declared and nothing is missing, "undeclared" when nothing is missing but no required
-- list was given (an entirely absent model would be invisible), and "empty" when no origin is eligible.
-- Callers evaluate one structural population at a time (H14's longer training history is scored separately).
--
-- Splits: eligible labels must satisfy the plan's split rule (upper bounds exclusive); an eligible outcome
-- that violates it is an error. Excluded origins are attributed to the split of their decision time.
--
-- Direction: only nonzero actuals count; a zero prediction is neither up nor down and is incorrect, and the
-- number of such zero predictions is reported. Benchmarks are scored on the same rows: always-up and the
-- per-symbol majority direction of eligible training actuals (ties -> "up").
-- Correlation is nil when n < 2 or either series is constant. Forecast dispersion is the population standard
-- deviation of predictions. Breakdowns (month, origin hour, segment age) need opts.originInfo(t).
local Types = require("../Types")
local Config = require("../Config")
local Ledger = require("./Ledger")

type Forecast = Types.Forecast
type Outcome = Types.Outcome
type Splits = Types.Splits

export type OriginInfo = { date: any, month: string, hour: number, segmentAge: number }

export type PointMetrics = {
	n: number,
	rmse: number?,
	mae: number?,
	rmseBps: number?,
	maeBps: number?,
	directionCorrect: number,
	directionTotal: number,
	directionAccuracy: number?,
	zeroPredictions: number,
	zeroActuals: number,
	alwaysUpAccuracy: number?,
	correlation: number?,
	meanPrediction: number?,
	meanActual: number?,
	forecastDispersion: number?,
}

export type ScoreOptions = {
	splits: Splits?,
	barSeconds: number?,
	horizonHours: number?,
	failures: { any }?,
	requiredModels: { string }?,
	originInfo: ((t: number) -> OriginInfo)?,
	trainingMajority: { [string]: string }?,
	subset: string?, -- "all" (default) | "nonOverlap"
}

local Evaluator = {}

local SPLIT_ORDER: { [string]: number } = { train = 1, validation = 2, final = 3, none = 4 }
Evaluator.SPLITS = table.freeze({ "train", "validation", "final", "none" })

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function fail(msg: string): never
	error("Evaluator: " .. msg, 0)
end

local function guard<T...>(fn: (T...) -> any, ...: T...): any
	local ok, res = pcall(fn, ...)
	if not ok then
		error(res, 3)
	end
	return res
end

---------------------------------------------------------------------------------------------------
-- Split rules
---------------------------------------------------------------------------------------------------

local function checkSplits(s: any): Splits
	if type(s) ~= "table" or not isFinite(s.validationStart) or not isFinite(s.testStart) or not isFinite(s.datasetEnd)
		or not (s.validationStart < s.testStart and s.testStart < s.datasetEnd) then
		fail("splits must be finite and ordered validationStart < testStart < datasetEnd")
	end
	return s
end

-- Split of a decision time alone (used to attribute excluded origins).
function Evaluator.decisionSplit(decisionTime: number, splits: Splits?): Types.SplitName
	local s = checkSplits(splits or Config.values.splits)
	if decisionTime < s.validationStart then
		return "train"
	elseif decisionTime < s.testStart then
		return "validation"
	elseif decisionTime < s.datasetEnd then
		return "final"
	end
	return "none"
end

-- Plan Section 2.4: a label belongs to a split only when both decision and outcome satisfy its bounds.
function Evaluator.labelSplit(decisionTime: number, outcomeTime: number, splits: Splits?): Types.SplitName
	local s = checkSplits(splits or Config.values.splits)
	if decisionTime < s.validationStart and outcomeTime < s.validationStart then
		return "train"
	elseif decisionTime >= s.validationStart and decisionTime < s.testStart and outcomeTime < s.testStart then
		return "validation"
	elseif decisionTime >= s.testStart and outcomeTime < s.datasetEnd then
		return "final"
	end
	return "none"
end

---------------------------------------------------------------------------------------------------
-- Point metrics
---------------------------------------------------------------------------------------------------

local function isConstant(values: { number }): boolean
	local first = values[1]
	for i = 2, #values do
		if values[i] ~= first then
			return false
		end
	end
	return true
end

-- rows: {{prediction: number, actual: number}}; every value must be finite.
function Evaluator.pointMetrics(rows: { { prediction: number, actual: number } }): PointMetrics
	local n = #rows
	local sae, sse, sumP, sumA = 0, 0, 0, 0
	local correct, total, zeroPred, zeroAct, up = 0, 0, 0, 0, 0
	local preds: { number }, acts: { number } = {}, {}
	for i, r in rows do
		local p: number, a: number = r.prediction, r.actual
		if not isFinite(p) or not isFinite(a) then
			error("Evaluator: prediction and actual must be finite numbers (row " .. i .. ")", 2)
		end
		local e = p - a
		sae += math.abs(e)
		sse += e * e
		sumP += p
		sumA += a
		preds[i] = p
		acts[i] = a
		if a == 0 then
			zeroAct += 1
		else
			total += 1
			if a > 0 then
				up += 1
			end
			if p == 0 then
				zeroPred += 1
			elseif (p > 0) == (a > 0) then
				correct += 1
			end
		end
	end
	local m: PointMetrics = {
		n = n,
		directionCorrect = correct,
		directionTotal = total,
		zeroPredictions = zeroPred,
		zeroActuals = zeroAct,
	}
	if n == 0 then
		return m
	end
	m.mae = sae / n
	m.rmse = math.sqrt(sse / n)
	m.maeBps = (m.mae :: number) * 10000
	m.rmseBps = (m.rmse :: number) * 10000
	if total > 0 then
		m.directionAccuracy = correct / total
		m.alwaysUpAccuracy = up / total
	end
	local meanP, meanA = sumP / n, sumA / n
	m.meanPrediction = meanP
	m.meanActual = meanA
	local constP, constA = isConstant(preds), isConstant(acts)
	if constP then
		m.forecastDispersion = 0
	else
		local vp = 0
		for _, p in preds do
			vp += (p - meanP) * (p - meanP)
		end
		m.forecastDispersion = math.sqrt(vp / n)
	end
	if n >= 2 and not constP and not constA then
		-- Correlation is scale-invariant; dividing each deviation by the largest one keeps the sums in [1, n]
		-- so tiny or huge magnitudes cannot underflow/overflow into NaN or Inf (tools/validate-results.mjs
		-- uses the same form).
		local sp, sa = 0, 0
		for i = 1, n do
			sp = math.max(sp, math.abs(preds[i] - meanP))
			sa = math.max(sa, math.abs(acts[i] - meanA))
		end
		if sp > 0 and sa > 0 then
			local cov, vp, va = 0, 0, 0
			for i = 1, n do
				local dp, da = (preds[i] - meanP) / sp, (acts[i] - meanA) / sa
				cov += dp * da
				vp += dp * dp
				va += da * da
			end
			m.correlation = cov / (math.sqrt(vp) * math.sqrt(va))
		end
	end
	return m
end

---------------------------------------------------------------------------------------------------
-- Non-overlapping subset
---------------------------------------------------------------------------------------------------

local function timing(opts: any?): (number, number)
	local bar = (opts and opts.barSeconds) or Config.values.barSeconds
	local horizon = (opts and opts.horizonHours) or Config.values.horizonHours
	if not isFinite(bar) or bar <= 0 or not isFinite(horizon) or horizon <= 0 then
		fail("barSeconds and horizonHours must be positive")
	end
	return bar, horizon
end

-- origins: timestamps t, or records with t (and optionally decisionTime/outcomeTime, which must match t).
-- Sorts, de-duplicates, then accepts an origin only when its decision time is at or after the previous
-- selected origin's outcome time. Returns the selected timestamps in ascending order.
function Evaluator.nonOverlap(origins: { any }, opts: { barSeconds: number?, horizonHours: number? }?): { number }
	return guard(function()
		local bar, horizon = timing(opts)
		local seen: { [number]: boolean } = {}
		local ts: { number } = {}
		for i, o in origins do
			local t = if type(o) == "table" then o.t else o
			if not isFinite(t) then
				fail("origin " .. i .. " has a non-finite timestamp")
			end
			if type(o) == "table" then
				if o.decisionTime ~= nil and o.decisionTime ~= t + bar then
					fail("origin " .. i .. " decisionTime does not equal t + barSeconds")
				end
				if o.outcomeTime ~= nil and o.outcomeTime ~= t + (horizon + 1) * bar then
					fail("origin " .. i .. " outcomeTime does not equal decisionTime + horizon")
				end
			end
			if not seen[t] then
				seen[t] = true
				table.insert(ts, t)
			end
		end
		table.sort(ts)
		local selected: { number } = {}
		local lastOutcome = -math.huge
		for _, t in ts do
			local decision = t + bar
			if decision >= lastOutcome then
				table.insert(selected, t)
				lastOutcome = decision + horizon * bar
			end
		end
		return selected
	end)
end

---------------------------------------------------------------------------------------------------
-- Joining
---------------------------------------------------------------------------------------------------

type PopRow = {
	symbol: string,
	t: number,
	eligible: boolean,
	actual: number?,
	reason: string?,
	split: string,
	info: OriginInfo?,
}

type Prepared = {
	splits: Splits,
	forecastById: { [string]: Forecast },
	failureById: { [string]: any },
	models: { string },
	rows: { PopRow },
	majority: { [string]: string },
	subset: string,
	required: { string }, -- declared required model keys, sorted, unique
}

local function validModelKey(key: any): boolean
	if type(key) ~= "string" then
		return false
	end
	local runId, modelId = string.match(key, "^([^:]+):([^:]+)$")
	return runId ~= nil and Ledger.isName(runId) and Ledger.isName(modelId)
end

local function prepare(forecasts: { Forecast }, outcomes: { Outcome }, opts: ScoreOptions?): Prepared
	local o: ScoreOptions = opts or {}
	local splits = checkSplits(o.splits or Config.values.splits)
	local bar, horizon = timing(o)
	local subset = o.subset or "all"
	if subset ~= "all" and subset ~= "nonOverlap" then
		fail("subset must be 'all' or 'nonOverlap'")
	end
	local modelSet: { [string]: boolean } = {}

	local forecastById: { [string]: Forecast } = {}
	for i, f in forecasts do
		local fr = f :: any
		if type(fr) ~= "table" then
			fail("forecast " .. i .. " is not a table")
		end
		local ok, parsed = pcall(Ledger.parseId, fr.id)
		if not ok then
			fail("forecast " .. i .. " has a malformed id " .. tostring(fr.id))
		end
		if parsed.runId ~= fr.runId or parsed.modelId ~= fr.modelId or parsed.symbol ~= fr.symbol or parsed.t ~= fr.t then
			fail("forecast " .. fr.id .. " fields disagree with its id")
		end
		if not isFinite(fr.prediction) then
			fail("forecast " .. fr.id .. " has a non-finite prediction")
		end
		if fr.decisionTime ~= fr.t + bar or fr.outcomeTime ~= fr.decisionTime + horizon * bar then
			fail("forecast " .. fr.id .. " has inconsistent decision/outcome times")
		end
		if forecastById[fr.id] then
			fail("duplicate forecast id " .. fr.id)
		end
		forecastById[fr.id] = f
		modelSet[parsed.runId .. ":" .. parsed.modelId] = true
	end

	local failureById: { [string]: any } = {}
	for i, fl in o.failures or {} do
		local ok, parsed = pcall(Ledger.parseId, (fl :: any).id)
		if not ok then
			fail("failure " .. i .. " has a malformed id")
		end
		if failureById[fl.id] then
			fail("duplicate failure id " .. fl.id)
		end
		if forecastById[fl.id] then
			fail("id " .. fl.id .. " is both a forecast and a failure")
		end
		failureById[fl.id] = fl
		modelSet[parsed.runId .. ":" .. parsed.modelId] = true
	end

	local seenOutcome: { [string]: boolean } = {}
	local pop: { [string]: PopRow } = {}
	local popList: { PopRow } = {}
	for i, oc in outcomes do
		local ok, parsed = pcall(Ledger.validateOutcome, oc, nil)
		if not ok then
			fail("outcome " .. i .. " invalid: " .. tostring(parsed))
		end
		local ocr = oc :: any
		if seenOutcome[ocr.forecastId] then
			fail("duplicate outcome for " .. ocr.forecastId)
		end
		seenOutcome[ocr.forecastId] = true
		modelSet[parsed.runId .. ":" .. parsed.modelId] = true
		local pk = parsed.symbol .. "@" .. tostring(parsed.t)
		local existing = pop[pk]
		if existing then
			if existing.eligible ~= ocr.eligible or existing.actual ~= ocr.actual or existing.reason ~= ocr.exclusionReason then
				fail("inconsistent outcomes for " .. pk .. " across models")
			end
		else
			local decision = parsed.t + bar
			local outcomeTime = decision + horizon * bar
			local split
			if ocr.eligible then
				split = Evaluator.labelSplit(decision, outcomeTime, splits)
				if split == "none" then
					fail("eligible outcome for " .. pk .. " violates the split boundaries")
				end
			else
				split = Evaluator.decisionSplit(decision, splits)
			end
			local row: PopRow = {
				symbol = parsed.symbol,
				t = parsed.t,
				eligible = ocr.eligible,
				actual = ocr.actual,
				reason = ocr.exclusionReason,
				split = split,
			}
			pop[pk] = row
			table.insert(popList, row)
		end
	end

	for id in forecastById do
		if not seenOutcome[id] then
			fail("forecast " .. id .. " has no outcome record")
		end
	end

	local requiredSet: { [string]: boolean } = {}
	local required: { string } = {}
	for _, mk in o.requiredModels or {} do
		if not validModelKey(mk) then
			fail("required model key must be runId:modelId, got " .. tostring(mk))
		end
		modelSet[mk] = true
		if not requiredSet[mk] then
			requiredSet[mk] = true
			table.insert(required, mk)
		end
	end
	table.sort(required)

	-- Training majority direction from the full eligible training population (before any subsetting).
	local majority: { [string]: string } = {}
	if o.trainingMajority then
		for sym, dir in o.trainingMajority do
			if dir ~= "up" and dir ~= "down" then
				fail("trainingMajority values must be 'up' or 'down'")
			end
			majority[sym] = dir
		end
	else
		local ups: { [string]: number } = {}
		local downs: { [string]: number } = {}
		for _, row in popList do
			if row.eligible and row.split == "train" then
				local a = row.actual :: number
				if a > 0 then
					ups[row.symbol] = (ups[row.symbol] or 0) + 1
				elseif a < 0 then
					downs[row.symbol] = (downs[row.symbol] or 0) + 1
				end
			end
		end
		local symbols: { [string]: boolean } = {}
		for s in ups do
			symbols[s] = true
		end
		for s in downs do
			symbols[s] = true
		end
		for s in symbols do
			majority[s] = if (ups[s] or 0) >= (downs[s] or 0) then "up" else "down"
		end
	end

	if subset == "nonOverlap" then
		local bySplit: { [string]: { number } } = {}
		for _, row in popList do
			if row.eligible then
				bySplit[row.split] = bySplit[row.split] or {}
				table.insert(bySplit[row.split], row.t)
			end
		end
		local keep: { [string]: { [number]: boolean } } = {}
		for split, ts in bySplit do
			keep[split] = {}
			for _, t in Evaluator.nonOverlap(ts, { barSeconds = bar, horizonHours = horizon }) do
				keep[split][t] = true
			end
		end
		local filtered = {}
		for _, row in popList do
			if row.eligible and keep[row.split][row.t] then
				table.insert(filtered, row)
			end
		end
		popList = filtered
	end

	if o.originInfo then
		local infoFn = o.originInfo
		for _, row in popList do
			local info = infoFn(row.t)
			if type(info) ~= "table" or type(info.month) ~= "string" or not isFinite(info.hour)
				or not isFinite(info.segmentAge) or (type(info.date) ~= "string" and not isFinite(info.date)) then
				fail("originInfo(" .. tostring(row.t) .. ") must return {date, month, hour, segmentAge}")
			end
			row.info = info
		end
	end

	table.sort(popList, function(a: PopRow, b: PopRow)
		if a.t ~= b.t then
			return a.t < b.t
		end
		return a.symbol < b.symbol
	end)

	local models = {}
	for mk in modelSet do
		table.insert(models, mk)
	end
	table.sort(models)

	return {
		splits = splits,
		forecastById = forecastById,
		failureById = failureById,
		models = models,
		rows = popList,
		majority = majority,
		subset = subset,
		required = required,
	}
end

local function splitKey(modelKey: string): (string, string)
	local runId, modelId = string.match(modelKey, "^([^:]+):([^:]+)$")
	return runId :: string, modelId :: string
end

---------------------------------------------------------------------------------------------------
-- Scoring
---------------------------------------------------------------------------------------------------

local function zeroReasons(): { [string]: number }
	local t = {}
	for _, r in Types.EXCLUSION_REASONS do
		t[r] = 0
	end
	return t
end

local function bucketize(eligibleRows: { PopRow }, scoredByT: { [number]: { prediction: number, actual: number } }, field: string)
	local buckets: { [any]: { key: any, eligible: number, missing: number, rows: { any } } } = {}
	local keys = {}
	for _, row in eligibleRows do
		local k = (row.info :: any)[field]
		local b = buckets[k]
		if not b then
			b = { key = k, eligible = 0, missing = 0, rows = {} }
			buckets[k] = b
			table.insert(keys, k)
		end
		b.eligible += 1
		local s = scoredByT[row.t]
		if s then
			table.insert(b.rows, s)
		else
			b.missing += 1
		end
	end
	table.sort(keys)
	local out = {}
	for _, k in keys do
		local b = buckets[k]
		local m = Evaluator.pointMetrics(b.rows)
		table.insert(out, table.freeze({
			key = k,
			eligible = b.eligible,
			missing = b.missing,
			n = m.n,
			rmse = m.rmse,
			mae = m.mae,
			directionCorrect = m.directionCorrect,
			directionTotal = m.directionTotal,
			directionAccuracy = m.directionAccuracy,
			meanPrediction = m.meanPrediction,
			meanActual = m.meanActual,
		}))
	end
	return table.freeze(out)
end

-- Scores every model in the population per symbol and split. See the header for the rules.
function Evaluator.score(forecasts: { Forecast }, outcomes: { Outcome }, opts: ScoreOptions?)
	return guard(function()
		local p = prepare(forecasts, outcomes, opts)
		local combos: { [string]: { symbol: string, split: string, rows: { PopRow } } } = {}
		local comboKeys = {}
		for _, row in p.rows do
			local ck = row.symbol .. "|" .. row.split
			local c = combos[ck]
			if not c then
				c = { symbol = row.symbol, split = row.split, rows = {} }
				combos[ck] = c
				table.insert(comboKeys, ck)
			end
			table.insert(c.rows, row)
		end
		table.sort(comboKeys, function(a: string, b: string)
			local ca, cb = combos[a], combos[b]
			if ca.symbol ~= cb.symbol then
				return ca.symbol < cb.symbol
			end
			return SPLIT_ORDER[ca.split] < SPLIT_ORDER[cb.split]
		end)

		local population = {}
		for _, ck in comboKeys do
			local c = combos[ck]
			local eligible, excluded = 0, zeroReasons()
			for _, row in c.rows do
				if row.eligible then
					eligible += 1
				else
					excluded[row.reason :: string] += 1
				end
			end
			population[c.split] = population[c.split] or {}
			population[c.split][c.symbol] = table.freeze({ eligible = eligible, excluded = table.freeze(excluded) })
		end

		local groups = {}
		local byKey = {}
		local incomplete = {}
		for _, mk in p.models do
			local runId, modelId = splitKey(mk)
			for _, ck in comboKeys do
				local c = combos[ck]
				local eligible, issuedEligible, issuedExcluded, missing, failures = 0, 0, 0, 0, 0
				local excluded = zeroReasons()
				local scored = {}
				local scoredByT: { [number]: { prediction: number, actual: number } } = {}
				local eligibleRows: { PopRow } = {}
				for _, row in c.rows do
					local id = mk .. ":" .. row.symbol .. ":" .. tostring(row.t)
					local f = p.forecastById[id]
					if p.failureById[id] then
						failures += 1
					end
					if row.eligible then
						eligible += 1
						table.insert(eligibleRows, row)
						if f then
							issuedEligible += 1
							local s = { prediction = f.prediction, actual = row.actual :: number, t = row.t }
							table.insert(scored, s)
							scoredByT[row.t] = s
						else
							missing += 1
						end
					else
						excluded[row.reason :: string] += 1
						if f then
							issuedExcluded += 1
						end
					end
				end
				local m = Evaluator.pointMetrics(scored)
				local majorityDir = p.majority[c.symbol]
				local majorityAcc: number? = nil
				if majorityDir and m.directionTotal > 0 then
					local hits = 0
					for _, s in scored do
						if s.actual ~= 0 and ((s.actual > 0) == (majorityDir == "up")) then
							hits += 1
						end
					end
					majorityAcc = hits / m.directionTotal
				end
				local breakdowns = nil
				if opts and opts.originInfo then
					breakdowns = table.freeze({
						month = bucketize(eligibleRows, scoredByT, "month"),
						hour = bucketize(eligibleRows, scoredByT, "hour"),
						segmentAge = bucketize(eligibleRows, scoredByT, "segmentAge"),
					})
				end
				local group = table.freeze({
					modelKey = mk,
					runId = runId,
					modelId = modelId,
					symbol = c.symbol,
					split = c.split,
					subset = p.subset,
					eligible = eligible,
					issued = issuedEligible + issuedExcluded,
					issuedEligible = issuedEligible,
					issuedExcluded = issuedExcluded,
					missing = missing,
					failures = failures,
					excluded = table.freeze(excluded),
					n = m.n,
					rmse = m.rmse,
					mae = m.mae,
					rmseBps = m.rmseBps,
					maeBps = m.maeBps,
					directionCorrect = m.directionCorrect,
					directionTotal = m.directionTotal,
					directionAccuracy = m.directionAccuracy,
					zeroPredictions = m.zeroPredictions,
					zeroActuals = m.zeroActuals,
					alwaysUpAccuracy = m.alwaysUpAccuracy,
					trainingMajorityDirection = majorityDir,
					trainingMajorityAccuracy = majorityAcc,
					correlation = m.correlation,
					meanPrediction = m.meanPrediction,
					meanActual = m.meanActual,
					forecastDispersion = m.forecastDispersion,
					breakdowns = breakdowns,
				})
				table.insert(groups, group)
				byKey[mk .. "|" .. c.symbol .. "|" .. c.split] = group
				if missing > 0 then
					table.insert(incomplete, table.freeze({
						modelKey = mk, runId = runId, modelId = modelId, symbol = c.symbol, split = c.split,
						missing = missing, failures = failures,
					}))
				end
			end
		end

		-- "complete" is certified only against a declared required-model list: a model that left no forecast,
		-- failure or outcome at all is invisible unless it is declared, so without a declaration the status is
		-- "undeclared". An empty eligible population certifies nothing ("empty").
		local eligibleTotal = 0
		for _, row in p.rows do
			if row.eligible then
				eligibleTotal += 1
			end
		end
		local status
		if #incomplete > 0 then
			status = "incomplete"
		elseif eligibleTotal == 0 then
			status = "empty"
		elseif #p.required == 0 then
			status = "undeclared"
		else
			status = "complete"
		end

		return table.freeze({
			groups = table.freeze(groups),
			byKey = table.freeze(byKey),
			comparison = table.freeze({
				status = status,
				incompleteGroups = table.freeze(incomplete),
				requiredModels = table.freeze(table.clone(p.required)),
			}),
			population = table.freeze(population),
			trainingMajority = table.freeze(p.majority),
			subset = p.subset,
			models = table.freeze(p.models),
		})
	end, forecasts, outcomes, opts)
end

---------------------------------------------------------------------------------------------------
-- Population identity across runs (plan Task 7: identical eligible timestamp sets, not matching counts)
---------------------------------------------------------------------------------------------------

-- Eligible origin keys "SYMBOL@t" per run and label split, read from outcome records alone. A run's models share
-- one population, so keys are de-duplicated per run. Lists are sorted by t, then symbol.
function Evaluator.eligibleOrigins(outcomes: { Outcome }, opts: ScoreOptions?): { [string]: { [string]: { string } } }
	return guard(function()
		local o: ScoreOptions = opts or {}
		local splits = checkSplits(o.splits or Config.values.splits)
		local bar, horizon = timing(o)
		local seen: { [string]: boolean } = {}
		local byRun: { [string]: { [string]: { { symbol: string, t: number } } } } = {}
		for i, oc in outcomes do
			local ok, parsed = pcall(Ledger.validateOutcome, oc, nil)
			if not ok then
				fail("outcome " .. i .. " invalid: " .. tostring(parsed))
			end
			if (oc :: any).eligible then
				local decision = parsed.t + bar
				local split = Evaluator.labelSplit(decision, decision + horizon * bar, splits)
				if split == "none" then
					fail("eligible outcome " .. (oc :: any).forecastId .. " violates the split boundaries")
				end
				local key = parsed.runId .. "|" .. parsed.symbol .. "@" .. tostring(parsed.t)
				if not seen[key] then
					seen[key] = true
					local runSets = byRun[parsed.runId] or {}
					byRun[parsed.runId] = runSets
					local list = runSets[split] or {}
					runSets[split] = list
					table.insert(list, { symbol = parsed.symbol, t = parsed.t })
				end
			end
		end
		local out = {}
		for runId, runSets in byRun do
			local sets = {}
			for split, list in runSets do
				table.sort(list, function(a: { symbol: string, t: number }, b: { symbol: string, t: number }): boolean
					if a.t ~= b.t then
						return a.t < b.t
					end
					return a.symbol < b.symbol
				end)
				local keys = {}
				for i, e in list do
					keys[i] = e.symbol .. "@" .. tostring(e.t)
				end
				sets[split] = keys
			end
			out[runId] = sets
		end
		return out
	end)
end

-- Raises unless every listed run has exactly the same eligible origin set in each named split (default: train,
-- validation and final). H14 against O14 passes splitNames = {"validation", "final"}: its training population is
-- longer by design. The error names the first origin found in one run but not the other.
function Evaluator.assertSameEligibleOrigins(outcomes: { Outcome }, runIds: { string }, splitNames: { string }?,
	opts: ScoreOptions?): boolean
	return guard(function()
		if type(runIds) ~= "table" or #runIds < 2 then
			fail("assertSameEligibleOrigins needs at least two run ids")
		end
		local sets = Evaluator.eligibleOrigins(outcomes, opts)
		for _, runId in runIds do
			if sets[runId] == nil then
				fail("run " .. tostring(runId) .. " has no eligible outcome records")
			end
		end
		local reference = runIds[1]
		for _, split in splitNames or { "train", "validation", "final" } do
			if split ~= "train" and split ~= "validation" and split ~= "final" then
				fail("unknown split " .. tostring(split))
			end
			local a: { string } = sets[reference][split] or {}
			local inA: { [string]: boolean } = {}
			for _, k in a do
				inA[k] = true
			end
			for i = 2, #runIds do
				local other = runIds[i]
				local b: { string } = sets[other][split] or {}
				local inB: { [string]: boolean } = {}
				for _, k in b do
					inB[k] = true
					if not inA[k] then
						fail(string.format("eligible population mismatch in %s: %s is eligible in %s but not in %s", tostring(split), k,
							tostring(other), tostring(reference)))
					end
				end
				for _, k in a do
					if not inB[k] then
						fail(string.format("eligible population mismatch in %s: %s is eligible in %s but not in %s", tostring(split), k,
							tostring(reference), tostring(other)))
					end
				end
			end
		end
		return true
	end)
end

-- Joined eligible rows (one per model per eligible symbol/origin) for the paired bootstrap.
-- prediction is nil where the model's forecast is missing. date comes from opts.originInfo when given.
function Evaluator.join(forecasts: { Forecast }, outcomes: { Outcome }, opts: ScoreOptions?): { any }
	return guard(function()
		local p = prepare(forecasts, outcomes, opts)
		local out = {}
		for _, row in p.rows do
			if row.eligible then
				for _, mk in p.models do
					local runId, modelId = splitKey(mk)
					local id = mk .. ":" .. row.symbol .. ":" .. tostring(row.t)
					local f = p.forecastById[id]
					table.insert(out, table.freeze({
						forecastId = id,
						modelKey = mk,
						runId = runId,
						modelId = modelId,
						symbol = row.symbol,
						t = row.t,
						split = row.split,
						date = if row.info then row.info.date else nil,
						prediction = if f then f.prediction else nil,
						actual = row.actual,
					}))
				end
			end
		end
		return table.freeze(out)
	end, forecasts, outcomes, opts)
end

-- Flat, JSON-encodable metric records (one per model/symbol/split group) for export and host validation.
function Evaluator.metricRecords(result: any): { any }
	local out = {}
	for _, g in result.groups do
		local r = {}
		for k, v in g do
			if k ~= "breakdowns" and k ~= "modelKey" then
				r[k] = v
			end
		end
		r.excluded = table.clone(g.excluded)
		table.insert(out, r)
	end
	return out
end

-- Flat breakdown records: one per group per dimension bucket.
function Evaluator.breakdownRecords(result: any): { any }
	local out = {}
	for _, g in result.groups do
		if g.breakdowns then
			for _, dim in { "month", "hour", "segmentAge" } do
				for _, b in g.breakdowns[dim] do
					local r = table.clone(b)
					r.runId, r.modelId, r.symbol, r.split, r.subset, r.dimension = g.runId, g.modelId, g.symbol, g.split, g.subset, dim
					table.insert(out, r)
				end
			end
		end
	end
	return out
end

-- originInfo from a Dataset's pairs: month and date are New York calendar labels from the pair metadata.
function Evaluator.originInfoFromPairs(pairs: { Types.Pair }): (t: number) -> OriginInfo
	local byT: { [number]: OriginInfo } = {}
	for _, pair in pairs do
		byT[pair.t] = table.freeze({
			date = pair.dateNY,
			month = string.sub(pair.dateNY, 1, 7),
			hour = pair.hourNY,
			segmentAge = pair.segmentOffset,
		}) :: any
	end
	return function(t: number): OriginInfo
		local info = byT[t]
		if not info then
			error("Evaluator: no pair metadata for origin " .. tostring(t), 2)
		end
		return info
	end
end

return table.freeze(Evaluator)
