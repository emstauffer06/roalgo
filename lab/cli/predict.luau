-- Issue frozen forecasts for a phase (plan Task 9). Reads NO targets.
--   luau.exe --codegen -O2 lab/cli/predict.luau -a <O14|R50|H14> <final|validation>
-- Requires the profile's locked model module (runs/<P>-a1/luau/model.luau, generated from model.json and
-- markov-model.json by tools/run-lab.mjs lock) and the phase's physics states. Before forecasting it rebuilds the
-- saved reference rows from the development stream and requires predictions identical within 1e-12.
-- Every warmed origin (segmentOffset >= warmup) of the phase gets a forecast from every model, whether or not
-- its eight-hour target will later be scoreable. A model that cannot produce a value emits a failure record.
local Common = require("./Common")
local Config = require("../src/Config")
local History = require("../src/Data/History")
local Ridge = require("../src/Model/Ridge")
local Markov = require("../src/Model/Markov")
local Ledger = require("../src/Experiment/Ledger")

local profileId, phase = ...
assert(Common.PROFILES[profileId], "predict: profile must be O14, R50 or H14")
assert(phase == "final" or phase == "validation", "predict: phase must be final or validation")
local cfg = Config.values
local splits = cfg.splits
local runId = profileId .. "-a1"
local artifact = require(Common.RUN_ROOT .. runId .. "/luau/model")
assert(artifact.runId == runId and artifact.profileId == profileId, "predict: model artifact identity mismatch")

local ds = Common.dataset(profileId)
local pairs = ds:pairs()
local inputs, inputIndex = Common.loadInputs(profileId)
assert(inputIndex.sha256 == artifact.inputsSha256, "predict: inputs differ from the ones the model was fitted on")
local devStates, _, devIndex = Common.loadStates(profileId, "dev")
-- (an if-expression would keep only the first return value, so pick the phase name first)
local phaseStates, phaseKeys, phaseIndex = devStates, nil, devIndex
if phase == "final" then
	phaseStates, phaseKeys, phaseIndex = Common.loadStates(profileId, "final")
end
assert(phaseIndex.inputsSha256 == inputIndex.sha256 and devIndex.inputsSha256 == inputIndex.sha256, "predict: physics states were driven by different inputs")
assert(devIndex.sha256 == artifact.statesSha256, "predict: development states differ from the ones the model was fitted on")
local preset = artifact.preset
local stateKey = profileId .. ":" .. preset

local models = {}
for name, entry in artifact.models do
	models[name] = Ridge.deserialize(entry.model)
end
local markov = Markov.deserialize(artifact.markov)
local lagSel = artifact.rawLag

local function concat(a, b)
	local out = table.create(#a + #b)
	table.move(a, 1, #a, 1, out)
	table.move(b, 1, #b, #a + 1, out)
	return out
end
local function designs(lagVectors, state)
	return {
		RAW = lagVectors[lagSel],
		RAW8 = lagVectors[8],
		RAW_PHYSICS = if state then concat(lagVectors[8], state) else nil,
		PHYSICS = state,
	}
end
local MODEL_OF = { RAW = "RAW-RIDGE", RAW8 = "RAW8-RIDGE", RAW_PHYSICS = "RAW+PHYSICS", PHYSICS = "PHYSICS-RIDGE" }

-- Walk the stream once, building lag vectors causally.
local hist = History.new(cfg.maxLag, inputIndex.dimension)
local refByT = {}
for name, entry in artifact.models do
	for _, ref in entry.referencePredictions do
		refByT[ref.t] = refByT[ref.t] or {}
		refByT[ref.t][name] = ref.prediction
	end
end
local refChecked = 0
local ledger = Ledger.new({ runId = runId })
local failures = 0
local SYMBOLS = { "SPY", "QQQ" }
local counts = { origins = 0 }
for idx, p in pairs do
	local inp = inputs[idx]
	assert(inp[1] == idx and inp[2] == p.t, "predict: input row mismatch at " .. idx)
	if p.segmentOffset == 1 then
		hist:reset()
	end
	hist:push(inp[6])
	if p.decisionTime >= splits.datasetEnd then
		break
	end
	local lagVectors = nil
	if refByT[p.t] then
		lagVectors = { [1] = hist:vector(1), [4] = hist:vector(4), [8] = hist:vector(8) }
		local d = designs(lagVectors, devStates[p.t] and devStates[p.t][stateKey])
		for name, expected in refByT[p.t] do
			local short = nil
			for k, v in MODEL_OF do
				if v == name then
					short = k
				end
			end
			local got = Ridge.predict(models[name], d[short])
			for h = 1, 2 do
				assert(math.abs(got[h] - expected[h]) <= 1e-12, string.format("predict: reference prediction differs for %s at t=%d", name, p.t))
			end
			refChecked += 1
		end
	end
	local inPhase = if phase == "final"
		then p.decisionTime >= splits.testStart and p.decisionTime < splits.datasetEnd
		else p.decisionTime >= splits.validationStart and p.decisionTime < splits.testStart
	if inPhase and p.segmentOffset >= cfg.warmupObservations then
		counts.origins += 1
		lagVectors = lagVectors or { [1] = hist:vector(1), [4] = hist:vector(4), [8] = hist:vector(8) }
		local st = phaseStates[p.t]
		local state = st and st[stateKey]
		local d = designs(lagVectors, state)
		local preds = {
			ZERO = { 0, 0 },
			MEAN = { artifact.trainingTargetMean[1], artifact.trainingTargetMean[2] },
		}
		for short, name in MODEL_OF do
			if d[short] then
				preds[short] = Ridge.predict(models[name], d[short])
			end
		end
		local window = table.move(pairs, idx - 3, idx, 1, {})
		local states = Markov.states(markov, window)
		if states then
			preds.MARKOV = Markov.predict(markov, states, cfg.markov.horizon)
		end
		for _, modelId in { "ZERO", "MEAN", "RAW", "RAW8", "RAW_PHYSICS", "PHYSICS", "MARKOV" } do
			local pr = preds[modelId]
			for h, symbol in SYMBOLS do
				local base = {
					id = Ledger.forecastId(runId, modelId, symbol, p.t),
					runId = runId,
					modelId = modelId,
					symbol = symbol,
					t = p.t,
					decisionTime = p.decisionTime,
					outcomeTime = p.decisionTime + cfg.horizonHours * cfg.barSeconds,
					modelHash = artifact.modelSha256,
					dataHash = phaseIndex.sha256,
				}
				if pr then
					base.prediction = pr[h]
					ledger:append(base)
					Common.emit("@@ROW", base)
				else
					failures += 1
					local f = {
						id = base.id,
						runId = runId,
						modelId = modelId,
						symbol = symbol,
						t = p.t,
						decisionTime = p.decisionTime,
						reason = if modelId == "MARKOV" then "markov_state_unavailable" else "physics_state_missing",
						phase = phase,
					}
					ledger:appendFailure(f)
					local rec = table.clone(f)
					rec.failure = true
					Common.emit("@@ROW", rec)
				end
			end
		end
	end
end
assert(refChecked > 0, "predict: no reference rows were re-checked")

Common.result({
	runId = runId,
	profileId = profileId,
	phase = phase,
	preset = preset,
	origins = counts.origins,
	forecasts = ledger:count(),
	failures = failures,
	referenceChecks = refChecked,
	inputsSha256 = inputIndex.sha256,
	statesSha256 = phaseIndex.sha256,
	modelSha256 = artifact.modelSha256,
})
