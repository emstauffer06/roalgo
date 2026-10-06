-- Fit, validate and select a profile's readouts (plan sections 2.1, 5, Task 6). Uses training labels for
-- fitting and validation labels for selection only; never reads final-period targets.
--   luau.exe --codegen -O2 lab/cli/fit.luau -a <O14|R50|H14>
-- Emits "@@ROW" validation forecast records and one "@@JSON" result with every candidate, the selection,
-- serialized models, the Markov artifact and validation summaries.
local Common = require("./Common")
local Config = require("../src/Config")
local Types = require("../src/Types")
local History = require("../src/Data/History")
local Targets = require("../src/Data/Targets")
local Ridge = require("../src/Model/Ridge")
local Markov = require("../src/Model/Markov")
local Selection = require("../src/Model/Selection")
local Sources = require("../generated/Sources")

local profileId = ...
assert(Common.PROFILES[profileId], "fit: profile must be O14, R50 or H14")
local cfg = Config.values
local splits = cfg.splits
local clock0 = os.clock()

local ds = Common.dataset(profileId)
local pairs = ds:pairs()
local inputs, inputIndex = Common.loadInputs(profileId)
assert(#inputs == #pairs, "fit: input stream length differs from the paired stream")
local statesByT, stateKeys, stateIndex = Common.loadStates(profileId, "dev")
assert(stateIndex.inputsSha256 == inputIndex.sha256, "fit: physics states were driven by different inputs than the lag features")
local D = inputIndex.dimension

-- 1. Walk the stream causally: lag vectors from the identical transformed inputs used for physics.
local hist = History.new(cfg.maxLag, D)
local origins = { train = {}, validation = {} }
local markovTrainEnd = 0
for idx, p in pairs do
	local inp = inputs[idx]
	assert(inp[1] == idx and inp[2] == p.t and inp[4] == p.segmentOffset, "fit: input row does not match pair " .. idx)
	if p.segmentOffset == 1 then
		hist:reset()
	end
	hist:push(inp[6])
	if p.decisionTime < splits.validationStart then
		markovTrainEnd = idx
	end
	if p.decisionTime >= splits.testStart then
		break -- final-period inputs are not touched here
	end
	local outcome = Targets.lookup(ds, p, splits, cfg.warmupObservations)
	if outcome.eligible and (outcome.split == "train" or outcome.split == "validation") then
		local s = statesByT[p.t]
		assert(s, "fit: missing physics state for eligible origin t=" .. p.t)
		table.insert(origins[outcome.split], {
			idx = idx,
			t = p.t,
			y = { outcome.spy :: number, outcome.qqq :: number },
			lag = { [1] = hist:vector(1), [4] = hist:vector(4), [8] = hist:vector(8) },
			phys = s,
			off = p.segmentOffset,
		})
	end
end

-- 2. Training target statistics.
local function targetStats(list)
	local mean, sq = { 0, 0 }, { 0, 0 }
	for _, o in list do
		for h = 1, 2 do
			mean[h] += o.y[h]
		end
	end
	for h = 1, 2 do
		mean[h] /= #list
	end
	for _, o in list do
		for h = 1, 2 do
			sq[h] += (o.y[h] - mean[h]) ^ 2
		end
	end
	return mean, { math.sqrt(sq[1] / #list), math.sqrt(sq[2] / #list) }
end
local trainMean, trainStd = targetStats(origins.train)
assert(trainStd[1] > 0 and trainStd[2] > 0, "fit: zero training target variance")

-- 3. Candidate machinery.
local function concat(a, b)
	local out = table.create(#a + #b)
	table.move(a, 1, #a, 1, out)
	table.move(b, 1, #b, #a + 1, out)
	return out
end
local designs = {
	RAW = function(o, lag) return o.lag[lag] end,
	PHYS = function(o, _, preset) return o.phys[profileId .. ":" .. preset] end,
	RAWPHYS = function(o, _, preset) return concat(o.lag[8], o.phys[profileId .. ":" .. preset]) end,
}
local function rmse(model, design)
	local se = { 0, 0 }
	for _, o in origins.validation do
		local pred = Ridge.predict(model, design(o))
		for h = 1, 2 do
			se[h] += (pred[h] - o.y[h]) ^ 2
		end
	end
	return { math.sqrt(se[1] / #origins.validation), math.sqrt(se[2] / #origins.validation) }
end

local candidates = { ["RAW-RIDGE"] = {}, ["RAW+PHYSICS"] = {}, ["PHYSICS-RIDGE"] = {} }
local fitted = {} -- key family|config|lambda -> {model, diag}
local function runFamily(family, config, lag, preset, design)
	local first = design(origins.train[1])
	local stats = Ridge.Stats.new(#first, 2)
	for _, o in origins.train do
		stats:add(design(o), o.y)
	end
	for _, lambda in cfg.lambdas do
		local metrics = { profileId = profileId, family = family, config = config, lag = lag, preset = preset, lambda = lambda }
		local ok, model, diag = pcall(Ridge.fitFromStats, stats, lambda)
		if ok then
			metrics.validationRmse = rmse(model, design)
			metrics.status = "ok"
			metrics.retained = diag.retainedCount
			metrics.residual = diag.residual
			metrics.dimension = #first
			fitted[family .. "|" .. config .. "|" .. lambda] = { model = model, diag = diag }
		else
			metrics.status = "rejected:" .. tostring(model)
		end
		table.insert(candidates[family], metrics)
	end
end

for _, lag in cfg.lags do
	runFamily("RAW-RIDGE", "L" .. lag, lag, nil, function(o) return designs.RAW(o, lag) end)
end
local presets = {}
for _, key in stateKeys do
	local preset = string.match(key, ":(P%d+)$")
	assert(preset, "fit: unexpected state key " .. key)
	table.insert(presets, preset)
end
assert(table.concat(presets, ",") == "P1,P2,P3", "fit: the declared physical presets are P1,P2,P3; found " .. table.concat(presets, ","))
for _, preset in presets do
	runFamily("RAW+PHYSICS", preset, 8, preset, function(o) return designs.RAWPHYS(o, nil, preset) end)
end

local function strip(list)
	local out = {}
	for _, c in list do
		table.insert(out, { profileId = c.profileId, family = c.family, config = c.config, lag = c.lag, preset = c.preset, lambda = c.lambda, validationRmse = c.validationRmse, status = c.status })
	end
	return out
end
local rankedRaw = Selection.rank(strip(candidates["RAW-RIDGE"]), trainStd)
local rankedPhys = Selection.rank(strip(candidates["RAW+PHYSICS"]), trainStd)
local bestRaw = Selection.best(rankedRaw)
local bestRawPhys = Selection.best(rankedPhys)
assert(bestRaw and bestRawPhys, "fit: every candidate of a family failed")

-- Exact eight-lag raw comparator: the L8 setting with its own validation-selected lambda.
local l8 = {}
for _, c in candidates["RAW-RIDGE"] do
	if c.config == "L8" then
		table.insert(l8, c)
	end
end
local bestRaw8 = Selection.best(Selection.rank(strip(l8), trainStd))
assert(bestRaw8, "fit: no eight-lag raw candidate")

-- Diagnostic PHYSICS-RIDGE at the physical configuration selected for RAW+PHYSICS.
local selPreset = bestRawPhys.preset :: string
runFamily("PHYSICS-RIDGE", selPreset, nil, selPreset, function(o) return designs.PHYS(o, nil, selPreset) end)
local bestPhysOnly = Selection.best(Selection.rank(strip(candidates["PHYSICS-RIDGE"]), trainStd))
assert(bestPhysOnly, "fit: no physics-only candidate")

-- Declared budget (plan section 5): 3 lags x 7 lambdas, 3 presets x 7 lambdas, 7 physics-only lambdas.
assert(#candidates["RAW-RIDGE"] == 21 and #candidates["RAW+PHYSICS"] == 21 and #candidates["PHYSICS-RIDGE"] == 7, "fit: candidate budget differs from the declared 21/21/7")

-- 4. Markov baseline on the boundary-checked training slice (contiguous from the dataset start). Its source is
-- the paired hourly price data, so O14 and R50 (same source, same definitions) share an identical artifact.
local trainingPairs = table.move(pairs, 1, markovTrainEnd, 1, {})
local hourlyGroup = if profileId == "H14" then "hourly-combined" else "hourly-original"
local groupInfo = Sources.groups[hourlyGroup]
local markov = Markov.fit(trainingPairs, {
	validationStart = splits.validationStart,
	sourceHashes = {
		group = hourlyGroup,
		manifest = groupInfo.manifestSha256,
		SPY = groupInfo.symbols.SPY.moduleSha256,
		QQQ = groupInfo.symbols.QQQ.moduleSha256,
	},
})

-- 5. Selected models, reload check, validation forecasts.
local function pick(family, c)
	return fitted[family .. "|" .. c.config .. "|" .. c.lambda]
end
local selected = {
	["RAW-RIDGE"] = { candidate = bestRaw, fit = pick("RAW-RIDGE", bestRaw), design = function(o) return designs.RAW(o, bestRaw.lag) end },
	["RAW8-RIDGE"] = { candidate = bestRaw8, fit = pick("RAW-RIDGE", bestRaw8), design = function(o) return designs.RAW(o, 8) end },
	["RAW+PHYSICS"] = { candidate = bestRawPhys, fit = pick("RAW+PHYSICS", bestRawPhys), design = function(o) return designs.RAWPHYS(o, nil, selPreset) end },
	["PHYSICS-RIDGE"] = { candidate = bestPhysOnly, fit = pick("PHYSICS-RIDGE", bestPhysOnly), design = function(o) return designs.PHYS(o, nil, selPreset) end },
}
local reference = {}
for k = 1, math.min(25, #origins.validation) do
	table.insert(reference, origins.validation[math.floor((k - 1) * #origins.validation / 25) + 1])
end
local serializedModels = {}
for name, sel in selected do
	local ser = Ridge.serialize(sel.fit.model)
	local back = Ridge.deserialize(ser)
	local refPreds = {}
	for _, o in reference do
		local a, b = Ridge.predict(sel.fit.model, sel.design(o)), Ridge.predict(back, sel.design(o))
		for h = 1, 2 do
			assert(math.abs(a[h] - b[h]) <= 1e-12, "fit: serialized model predictions differ for " .. name)
		end
		table.insert(refPreds, { t = o.t, prediction = a })
	end
	serializedModels[name] = { model = ser, candidate = sel.candidate, diag = sel.fit.diag, referencePredictions = refPreds }
end

local function markovForecast(o)
	local window = table.move(pairs, o.idx - 3, o.idx, 1, {})
	local st = Markov.states(markov, window)
	assert(st, "fit: Markov state missing at a warmed origin")
	return Markov.predict(markov, st, cfg.markov.horizon)
end
local summary = {}
local function addSummary(model, predict)
	local se, ae, hits, n, zeroPred = { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }, { 0, 0 }
	for _, o in origins.validation do
		local pred = predict(o)
		for h = 1, 2 do
			local e = pred[h] - o.y[h]
			se[h] += e * e
			ae[h] += math.abs(e)
			if o.y[h] ~= 0 then
				n[h] += 1
				if pred[h] ~= 0 and (pred[h] > 0) == (o.y[h] > 0) then
					hits[h] += 1
				end
			end
			if pred[h] == 0 then
				zeroPred[h] += 1
			end
			Common.emit("@@ROW", { model = model, symbol = if h == 1 then "SPY" else "QQQ", t = o.t, prediction = pred[h] })
		end
	end
	local m = #origins.validation
	summary[model] = {
		rmse = { math.sqrt(se[1] / m), math.sqrt(se[2] / m) },
		mae = { ae[1] / m, ae[2] / m },
		direction = { hits[1] / n[1], hits[2] / n[2] },
		zeroPredictions = zeroPred,
		score = Selection.score({ math.sqrt(se[1] / m), math.sqrt(se[2] / m) }, trainStd),
	}
end
addSummary("ZERO", function() return { 0, 0 } end)
addSummary("MEAN", function() return { trainMean[1], trainMean[2] } end)
addSummary("MARKOV", markovForecast)
for name, sel in selected do
	addSummary(name, function(o) return Ridge.predict(sel.fit.model, sel.design(o)) end)
end

Common.result({
	profileId = profileId,
	origins = { train = #origins.train, validation = #origins.validation },
	trainingTargetMean = trainMean,
	trainingTargetStd = trainStd,
	stateKeys = stateKeys,
	inputsSha256 = inputIndex.sha256,
	statesSha256 = stateIndex.sha256,
	candidates = candidates,
	ranked = { ["RAW-RIDGE"] = rankedRaw, ["RAW+PHYSICS"] = rankedPhys },
	selected = {
		rawRidge = { config = bestRaw.config, lambda = bestRaw.lambda, score = bestRaw.score },
		raw8 = { config = bestRaw8.config, lambda = bestRaw8.lambda, score = bestRaw8.score },
		rawPhysics = { config = bestRawPhys.config, lambda = bestRawPhys.lambda, score = bestRawPhys.score },
		physicsOnly = { config = bestPhysOnly.config, lambda = bestPhysOnly.lambda, score = bestPhysOnly.score },
		preset = selPreset,
	},
	models = serializedModels,
	markov = Markov.serialize(markov),
	validationSummary = summary,
	budget = {
		rawRidge = #candidates["RAW-RIDGE"],
		rawPhysics = #candidates["RAW+PHYSICS"],
		physicsOnly = #candidates["PHYSICS-RIDGE"],
	},
	seconds = os.clock() - clock0,
})
