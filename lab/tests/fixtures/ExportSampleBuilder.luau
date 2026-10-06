-- Builds the cross-language export sample (stored in ExportSample.luau by tools/gen-result-fixtures.mjs):
-- a synthetic run exported through ResultStore exactly as the plugin bridge would publish it, plus the Luau
-- metrics (all eligible origins and the non-overlapping subset) that tools/validate-results.mjs must reproduce
-- within 1e-10. Synthetic data only.
local Json = require("../../src/Util/Json")
local Evaluator = require("../../src/Experiment/Evaluator")
local ResultStore = require("../../src/Experiment/ResultStore")
local SyntheticRun = require("./SyntheticRun")

local ExportSampleBuilder = {}
ExportSampleBuilder.MAX_PAGE_BYTES = 4096

function ExportSampleBuilder.build(): string
	local run = SyntheticRun.build({ dropPhysics = true })
	local required = {}
	for _, model in SyntheticRun.MODELS do
		table.insert(required, run.runId .. ":" .. model)
	end
	local scoreOpts = {
		splits = run.splits, failures = run.failures, originInfo = run.originInfo, requiredModels = required,
	}
	local result = Evaluator.score(run.forecasts, run.outcomes, scoreOpts)
	-- the plan's deterministic non-overlapping subset is exported in the same metrics artifact
	local nonOverlapOpts = table.clone(scoreOpts)
	nonOverlapOpts.subset = "nonOverlap"
	local nonOverlap = Evaluator.score(run.forecasts, run.outcomes, nonOverlapOpts)
	local metrics = Evaluator.metricRecords(result)
	for _, r in Evaluator.metricRecords(nonOverlap) do
		table.insert(metrics, r)
	end
	local store = ResultStore.new({ runId = run.runId, maxPageBytes = ExportSampleBuilder.MAX_PAGE_BYTES })
	store:put("forecasts", run.forecasts)
	store:put("outcomes", run.outcomes)
	store:put("failures", run.failures)
	store:put("metrics", metrics)
	local kinds = {}
	for _, kind in store:kinds() do
		local manifest = Json.decode(store:manifestJson(kind))
		local pages = {}
		for i = 1, manifest.pageCount do
			pages[i] = store:page(kind, i)
		end
		kinds[kind] = { manifest = manifest, pages = pages }
	end
	return Json.encode({
		format = "mrl-export-sample-1",
		runId = run.runId,
		splits = run.splits,
		barSeconds = 3600,
		horizonHours = 8,
		maxPageBytes = ExportSampleBuilder.MAX_PAGE_BYTES,
		comparisonStatus = result.comparison.status,
		kinds = kinds,
	})
end

return ExportSampleBuilder
