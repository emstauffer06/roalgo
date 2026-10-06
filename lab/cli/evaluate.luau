-- Evaluate the frozen final-period forecasts of every included profile together (plan sections 6, Task 7/9).
--   luau.exe --codegen -O2 lab/cli/evaluate.luau -a final
-- Precondition (enforced by tools/run-lab.mjs evaluate): every profile is locked and its final ledger was
-- exported and hashed. Forecasts are read from the exported ledgers (generated chunks), never recomputed.
-- Emits "@@ROW" outcome records and one "@@JSON" result: metrics (all origins and the non-overlapping subset),
-- breakdowns, population identity, comparison status and paired moving-block bootstrap intervals.
local Common = require("./Common")
local Config = require("../src/Config")
local Targets = require("../src/Data/Targets")
local Evaluator = require("../src/Experiment/Evaluator")
local Bootstrap = require("../src/Experiment/Bootstrap")

local phase = ...
assert(phase == "final", "evaluate: only the final phase is evaluated here")
local cfg = Config.values
local splits = cfg.splits
local PROFILES = { "O14", "R50", "H14" }
local MODELS = { "ZERO", "MEAN", "RAW", "RAW8", "RAW_PHYSICS", "PHYSICS", "MARKOV" }

local allForecasts, allOutcomes, allFailures = {}, {}, {}
local perProfile = {}
local scales = {}
local pairsByProfile = {}
for _, profileId in PROFILES do
	local runId = profileId .. "-a1"
	local artifact = require(Common.RUN_ROOT .. runId .. "/luau/model")
	scales[profileId] = { SPY = artifact.trainingTargetStd[1], QQQ = artifact.trainingTargetStd[2] }
	local forecasts = Common.loadRunChunks(runId .. "/luau/predictions-final")
	local failures = Common.loadRunChunks(runId .. "/luau/failures-final")
	local ds = Common.dataset(profileId)
	pairsByProfile[profileId] = ds:pairs()

	-- Outcomes: one record per forecast id (and per failure id), from the evaluator-only target lookup.
	local outcomes = {}
	local lookupCache = {}
	local function outcomeFor(t)
		if lookupCache[t] == nil then
			local idx = ds:indexOf(t)
			assert(idx, "evaluate: forecast origin not in the paired stream")
			lookupCache[t] = Targets.lookup(ds, ds:get(idx), splits, cfg.warmupObservations)
		end
		return lookupCache[t]
	end
	local function addOutcome(id, symbol, t)
		local o = outcomeFor(t)
		local rec = { forecastId = id, eligible = o.eligible }
		if o.eligible then
			rec.actual = if symbol == "SPY" then o.spy else o.qqq
		else
			rec.exclusionReason = o.reason
		end
		table.insert(outcomes, rec)
		Common.emit("@@ROW", rec)
	end
	for _, f in forecasts do
		addOutcome(f.id, f.symbol, f.t)
	end
	for _, f in failures do
		addOutcome(f.id, f.symbol, f.t)
	end

	-- Structural completeness: every final-period origin that is eligible by timestamps alone must carry an
	-- outcome record for every required model and symbol (a forecast or a failure), so an origin skipped by
	-- predict can never silently leave the population. Also counts unwarmed final observations.
	local issued = {}
	for _, f in forecasts do
		issued[f.id] = true
	end
	for _, f in failures do
		issued[f.id] = true
	end
	local structural = { eligible = 0, insufficientWarmup = 0, otherExcluded = 0 }
	for _, p in pairsByProfile[profileId] do
		if p.decisionTime >= splits.testStart and p.decisionTime < splits.datasetEnd then
			local c = Targets.classify(ds, p, splits, cfg.warmupObservations)
			if c.eligible and c.split == "final" then
				structural.eligible += 1
				for _, m in MODELS do
					for _, sym in { "SPY", "QQQ" } do
						local id = runId .. ":" .. m .. ":" .. sym .. ":" .. tostring(p.t)
						assert(issued[id], "evaluate: eligible final origin has no forecast or failure record: " .. id)
					end
				end
			elseif c.reason == "insufficient_warmup" then
				structural.insufficientWarmup += 1
			else
				structural.otherExcluded += 1
			end
		end
	end

	-- Training-majority direction per symbol from eligible TRAINING targets only.
	local up, down = { SPY = 0, QQQ = 0 }, { SPY = 0, QQQ = 0 }
	for _, p in pairsByProfile[profileId] do
		if p.decisionTime >= splits.validationStart then
			break
		end
		local o = Targets.lookup(ds, p, splits, cfg.warmupObservations)
		if o.eligible and o.split == "train" then
			for _, sym in { "SPY", "QQQ" } do
				local a = if sym == "SPY" then o.spy else o.qqq
				if a > 0 then
					up[sym] += 1
				elseif a < 0 then
					down[sym] += 1
				end
			end
		end
	end
	local majority = {
		SPY = if up.SPY >= down.SPY then "up" else "down",
		QQQ = if up.QQQ >= down.QQQ then "up" else "down",
	}

	local required = {}
	for _, m in MODELS do
		table.insert(required, runId .. ":" .. m)
	end
	local info = Evaluator.originInfoFromPairs(pairsByProfile[profileId])
	local opts = { splits = splits, requiredModels = required, originInfo = info, trainingMajority = majority, failures = failures }
	local all = Evaluator.score(forecasts, outcomes, opts)
	local nonOverlapOpts = table.clone(opts)
	nonOverlapOpts.subset = "nonOverlap"
	local nonOverlap = Evaluator.score(forecasts, outcomes, nonOverlapOpts)
	perProfile[profileId] = {
		runId = runId,
		forecasts = #forecasts,
		failures = #failures,
		outcomes = #outcomes,
		structuralFinalOrigins = structural,
		comparisonStatus = all.comparison.status,
		incompleteGroups = all.comparison.incompleteGroups,
		population = all.population,
		trainingMajority = majority,
		metrics = Evaluator.metricRecords(all),
		breakdowns = Evaluator.breakdownRecords(all),
		nonOverlapMetrics = Evaluator.metricRecords(nonOverlap),
		trainingTargetStd = artifact.trainingTargetStd,
	}
	for _, f in forecasts do
		table.insert(allForecasts, f)
	end
	for _, f in failures do
		table.insert(allFailures, f)
	end
	for _, o in outcomes do
		table.insert(allOutcomes, o)
	end
end

-- Identical eligible final populations across profiles (sets, not counts).
Evaluator.assertSameEligibleOrigins(allOutcomes, { "O14-a1", "R50-a1", "H14-a1" }, { "final" }, { splits = splits })

-- Paired moving-block bootstrap over ordered New York dates.
local joined = Evaluator.join(allForecasts, allOutcomes, { splits = splits, originInfo = Evaluator.originInfoFromPairs(pairsByProfile.O14) })
local function compare(label, a, b, scaleProfile, symbols, primary)
	local opts = {
		seed = cfg.bootstrap.seed,
		blockLength = cfg.bootstrap.blockDates,
		replicates = cfg.bootstrap.replicates,
		metric = "normalizedRmse",
		targetScales = scales[scaleProfile],
		modelA = a,
		modelB = b,
		symbols = symbols,
		split = "final",
	}
	local ok, interval = pcall(Bootstrap.compare, joined, opts)
	return {
		label = label,
		primary = primary == true,
		modelA = a,
		modelB = b,
		symbols = symbols or { "SPY", "QQQ" },
		scaleProfile = scaleProfile,
		ok = ok,
		interval = if ok then interval else nil,
		error = if ok then nil else tostring(interval),
	}
end
local comparisons = {
	compare("R50 RAW+PHYSICS - R50 RAW-RIDGE (PRIMARY)", "R50-a1:RAW_PHYSICS", "R50-a1:RAW", "R50", nil, true),
	compare("R50 RAW+PHYSICS - R50 RAW-RIDGE, SPY", "R50-a1:RAW_PHYSICS", "R50-a1:RAW", "R50", { "SPY" }),
	compare("R50 RAW+PHYSICS - R50 RAW-RIDGE, QQQ", "R50-a1:RAW_PHYSICS", "R50-a1:RAW", "R50", { "QQQ" }),
	compare("R50 RAW+PHYSICS - R50 exact eight-lag RAW", "R50-a1:RAW_PHYSICS", "R50-a1:RAW8", "R50"),
	compare("R50 RAW+PHYSICS - R50 MARKOV", "R50-a1:RAW_PHYSICS", "R50-a1:MARKOV", "R50"),
	compare("R50 RAW+PHYSICS - R50 ZERO", "R50-a1:RAW_PHYSICS", "R50-a1:ZERO", "R50"),
	compare("R50 PHYSICS-RIDGE - R50 RAW-RIDGE (diagnostic)", "R50-a1:PHYSICS", "R50-a1:RAW", "R50"),
	compare("O14 RAW+PHYSICS - O14 RAW-RIDGE (reference)", "O14-a1:RAW_PHYSICS", "O14-a1:RAW", "O14"),
	compare("H14 RAW+PHYSICS - H14 RAW-RIDGE", "H14-a1:RAW_PHYSICS", "H14-a1:RAW", "H14"),
	compare("R50 RAW+PHYSICS - O14 RAW+PHYSICS (extra information)", "R50-a1:RAW_PHYSICS", "O14-a1:RAW_PHYSICS", "O14"),
	compare("R50 RAW-RIDGE - O14 RAW-RIDGE (extra information, raw)", "R50-a1:RAW", "O14-a1:RAW", "O14"),
	compare("H14 RAW+PHYSICS - O14 RAW+PHYSICS (training history)", "H14-a1:RAW_PHYSICS", "O14-a1:RAW_PHYSICS", "O14"),
	compare("H14 RAW-RIDGE - O14 RAW-RIDGE (training history, raw)", "H14-a1:RAW", "O14-a1:RAW", "O14"),
}

Common.result({
	phase = phase,
	profiles = perProfile,
	comparisons = comparisons,
	bootstrap = cfg.bootstrap,
	note = "Each paired origin has two targets; overlapping eight-hour forecasts are not independent trials. Secondary comparisons are exploratory.",
})
