-- Synthetic forecast/outcome fixture shared by Experiment.spec, Export.spec and the cross-language export sample.
-- Every value here is generated from a fixed PRNG seed; no real market data is read.
--
-- Layout: seven synthetic dates (labels 2020-09-28 .. 2020-10-04), origins at labelled hours 8..13
-- (segment offsets 4..9), two symbols, three models in one run, sharing every timestamp. Custom splits:
-- dates 0-2 train, 3-4 validation, 5-6 final. Exclusions: hour offset 5 of every date -> missing_target,
-- date 2 offset 4 -> missing_intermediate_hour, plus one date-2 origin at 20:00 whose outcome crosses into
-- validation -> split_boundary (decision split = train).
-- opts.dropPhysics: replaces the PHYSICS forecast for (date 3, offset 2, QQQ) with a failure record.
local Prng = require("../../src/Util/Prng")
local Ledger = require("../../src/Experiment/Ledger")

local SyntheticRun = {}

SyntheticRun.RUN = "fixture-run"
SyntheticRun.MODELS = { "O14-RAW_RIDGE", "O14-PHYSICS", "O14-MARKOV" }
SyntheticRun.SYMBOLS = { "SPY", "QQQ" }
SyntheticRun.BASE = 1601251200 -- 2020-09-28T00:00:00Z
SyntheticRun.DATES = { "2020-09-28", "2020-09-29", "2020-09-30", "2020-10-01", "2020-10-02", "2020-10-03", "2020-10-04" }
SyntheticRun.SPLITS = table.freeze({
	validationStart = 1601251200 + 3 * 86400,
	testStart = 1601251200 + 5 * 86400,
	datasetEnd = 1601251200 + 7 * 86400,
})
SyntheticRun.DROPPED = { date = 3, offset = 2, symbol = "QQQ", model = "O14-PHYSICS" }

export type Origin = { t: number, date: string, month: string, hour: number, segmentAge: number, dayIndex: number,
	offset: number, eligible: boolean, reason: string? }

local function originsList(): { Origin }
	local list = {}
	for d = 0, 6 do
		local date = SyntheticRun.DATES[d + 1]
		for h = 0, 5 do
			local reason: string? = nil
			if h == 5 then
				reason = "missing_target"
			elseif d == 2 and h == 4 then
				reason = "missing_intermediate_hour"
			end
			table.insert(list, {
				t = SyntheticRun.BASE + d * 86400 + (8 + h) * 3600,
				date = date,
				month = string.sub(date, 1, 7),
				hour = 8 + h,
				segmentAge = 4 + h,
				dayIndex = d,
				offset = h,
				eligible = reason == nil,
				reason = reason,
			})
		end
		if d == 2 then
			table.insert(list, {
				t = SyntheticRun.BASE + d * 86400 + 20 * 3600,
				date = date,
				month = string.sub(date, 1, 7),
				hour = 20,
				segmentAge = 16,
				dayIndex = d,
				offset = 12,
				eligible = false,
				reason = "split_boundary",
			})
		end
	end
	return list
end

-- Returns {runId, splits, origins, forecasts, outcomes, failures, originInfo, actualOf}
function SyntheticRun.build(opts: { dropPhysics: boolean? }?)
	local dropPhysics = opts ~= nil and opts.dropPhysics == true
	local prng = Prng.new(101)
	local origins = originsList()
	local ledger = Ledger.new({ runId = SyntheticRun.RUN })
	local outcomes = Ledger.newOutcomes({ runId = SyntheticRun.RUN })
	local actualOf: { [string]: number } = {}
	local infoByT: { [number]: Origin } = {}
	for _, o in origins do
		infoByT[o.t] = o
		for _, symbol in SyntheticRun.SYMBOLS do
			local actual = (prng:nextNumber() - 0.5) * 0.02
			if o.dayIndex == 1 and o.offset == 0 and symbol == "SPY" then
				actual = 0 -- a zero realised return (excluded from direction accuracy)
			end
			actualOf[symbol .. "@" .. tostring(o.t)] = actual
			for _, model in SyntheticRun.MODELS do
				local prediction
				if model == "O14-RAW_RIDGE" then
					prediction = 0.3 * actual + (prng:nextNumber() - 0.5) * 0.004
					if o.dayIndex == 0 and o.offset == 1 and symbol == "QQQ" then
						prediction = 0 -- a zero prediction (incorrect for a nonzero target)
					end
				elseif model == "O14-PHYSICS" then
					prediction = 0.4 * actual + (prng:nextNumber() - 0.5) * 0.004
				else
					prediction = if symbol == "SPY" then 0.0001 else -0.0002 -- constant: zero variance
				end
				local id = Ledger.forecastId(SyntheticRun.RUN, model, symbol, o.t)
				local drop = dropPhysics
					and model == SyntheticRun.DROPPED.model
					and symbol == SyntheticRun.DROPPED.symbol
					and o.dayIndex == SyntheticRun.DROPPED.date
					and o.offset == SyntheticRun.DROPPED.offset
				if drop then
					ledger:appendFailure({
						runId = SyntheticRun.RUN, modelId = model, symbol = symbol, t = o.t,
						reason = "rail_saturation", detail = "synthetic failure (d\u{e9}calage)",
					})
				else
					ledger:append({
						id = id, runId = SyntheticRun.RUN, modelId = model, symbol = symbol, t = o.t,
						decisionTime = o.t + 3600, outcomeTime = o.t + 9 * 3600, prediction = prediction,
						modelHash = "model-" .. model, dataHash = "data-synthetic",
					})
				end
				if o.eligible then
					outcomes:add({ forecastId = id, eligible = true, actual = actual })
				else
					outcomes:add({ forecastId = id, eligible = false, exclusionReason = o.reason })
				end
			end
		end
	end
	local function originInfo(t: number)
		local o = infoByT[t]
		if not o then
			error("SyntheticRun: unknown origin " .. tostring(t))
		end
		return { date = o.date, month = o.month, hour = o.hour, segmentAge = o.segmentAge }
	end
	return {
		runId = SyntheticRun.RUN,
		splits = SyntheticRun.SPLITS,
		origins = origins,
		forecasts = ledger:page(1, ledger:count()),
		outcomes = outcomes:page(1, outcomes:count()),
		failures = ledger:failurePage(1, ledger:failureCount()),
		originInfo = originInfo,
		actualOf = actualOf,
	}
end

return SyntheticRun
