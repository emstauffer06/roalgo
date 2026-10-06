--!strict
-- Eight-hour target lookup (plan sections 2.2, 2.4 and Task 7). EVALUATOR-FACING LAYER ONLY.
-- This is the one Data module allowed to look forward in time; no other Data module may require it
-- (tools/prepare-lab.test.mjs checks that). Feature construction and physical inputs must never call it.
--
-- For the origin pair at bar start t:
--   decisionTime = t + 3600, targetT = t + 8*3600, outcomeTime = targetT + 3600
--   return[symbol] = ln(close[symbol, targetT] / close[symbol, t])
-- Every timestamp is looked up exactly (t + k*3600), never as row index + k.
--
-- Exclusion reasons, in this fixed priority order (Types.EXCLUSION_REASONS):
--   invalid_input             the pair is not this dataset's pair at t, or a needed close is not finite/positive
--   insufficient_warmup       segmentOffset < warmup (four consecutive paired observations in version 1)
--   missing_intermediate_hour some paired hour t + k*3600, k = 1..7, is absent
--   missing_target            the k = 8 endpoint t + 8*3600 is absent
--   different_local_date      the target bar starts on a different New York date than the origin
--   split_boundary            decision/outcome do not satisfy any split (exclusive upper bounds, outcome purge)
--
-- Targets.classify is structural only: it never reads a price beyond validity checks and never computes a
-- return, so it may be used to count eligible origins in sealed periods. Targets.lookup adds the returns.
local Types = require("../Types")

type Dataset = Types.Dataset
type Pair = Types.Pair
type Splits = Types.Splits
type SplitName = Types.SplitName
type OutcomePair = Types.OutcomePair

local BAR_SECONDS = 3600
local HORIZON = 8
local CLOSE = Types.Bar.CLOSE

local Targets = {}

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function checkSplits(splits: any)
	if type(splits) ~= "table" then
		error("Targets: splits table required", 3)
	end
	local vs, ts, de = splits.validationStart, splits.testStart, splits.datasetEnd
	if not (isFinite(vs) and isFinite(ts) and isFinite(de)) then
		error("Targets: splits need finite validationStart, testStart and datasetEnd", 3)
	end
	if not (vs < ts and ts < de) then
		error("Targets: split boundaries out of order", 3)
	end
end

local function splitOf(decisionTime: number, outcomeTime: number, splits: Splits): SplitName
	local vs, ts, de = splits.validationStart, splits.testStart, splits.datasetEnd
	if decisionTime < vs and outcomeTime < vs then
		return "train"
	elseif decisionTime >= vs and decisionTime < ts and outcomeTime < ts then
		return "validation"
	elseif decisionTime >= ts and outcomeTime < de then
		return "final"
	end
	return "none"
end

-- Section 2.4: training decision < vs and outcome < vs; validation vs <= decision < ts and outcome < ts;
-- final ts <= decision and outcome < datasetEnd. Anything else (including a label that reaches the next
-- boundary) is "none".
function Targets.splitOf(decisionTime: number, outcomeTime: number, splits: Splits): SplitName
	checkSplits(splits)
	if not (isFinite(decisionTime) and isFinite(outcomeTime)) then
		error("Targets: decisionTime and outcomeTime must be finite numbers", 2)
	end
	return splitOf(decisionTime, outcomeTime, splits)
end

local function frozen(o: OutcomePair): OutcomePair
	table.freeze(o :: any)
	return o
end

local function validClose(bar: any): boolean
	return type(bar) == "table" and isFinite(bar[CLOSE]) and bar[CLOSE] > 0
end

local function sameBar(a: any, b: any): boolean
	if rawequal(a, b) then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k = 1, 8 do
		if a[k] ~= b[k] then
			return false
		end
	end
	return true
end

-- The dataset's own pair at pair.t, when the caller's pair really is that pair.
local function canonical(dataset: Dataset, pair: any): Pair?
	local index = dataset:indexOf(pair.t)
	if index == nil then
		return nil
	end
	local own = dataset:get(index)
	if own == nil then
		return nil
	end
	if rawequal(own, pair) then
		return own
	end
	if pair.index ~= own.index or pair.segmentId ~= own.segmentId or pair.segmentOffset ~= own.segmentOffset then
		return nil
	end
	if pair.dateKey ~= own.dateKey or not sameBar(pair.spy, own.spy) or not sameBar(pair.qqq, own.qqq) then
		return nil
	end
	return own
end

type Classified = { result: OutcomePair, origin: Pair?, target: Pair? }

local function classify(dataset: Dataset, pair: any, splits: Splits, warmup: number): Classified
	if type(dataset) ~= "table" or type((dataset :: any).indexOf) ~= "function" then
		error("Targets: dataset required", 3)
	end
	checkSplits(splits)
	if type(warmup) ~= "number" or warmup < 1 or warmup ~= math.floor(warmup) then
		error("Targets: warmup must be a positive integer", 3)
	end
	if type(pair) ~= "table" or not isFinite(pair.t) then
		error("Targets: pair with a finite bar-start t required", 3)
	end
	local t: number = pair.t
	local decisionTime = t + BAR_SECONDS
	local targetT = t + HORIZON * BAR_SECONDS
	local outcomeTime = targetT + BAR_SECONDS
	local split = splitOf(decisionTime, outcomeTime, splits)
	local function result(reason: string?): OutcomePair
		return frozen({
			eligible = reason == nil,
			reason = reason,
			split = split,
			spy = nil,
			qqq = nil,
			decisionTime = decisionTime,
			outcomeTime = outcomeTime,
			targetT = targetT,
		})
	end

	local origin = canonical(dataset, pair)
	if origin == nil or not validClose(origin.spy) or not validClose(origin.qqq) then
		return { result = result("invalid_input") }
	end
	local targetIndex = dataset:indexOf(targetT)
	local target = if targetIndex ~= nil then dataset:get(targetIndex) else nil
	if target ~= nil and (not validClose(target.spy) or not validClose(target.qqq)) then
		return { result = result("invalid_input") }
	end
	if origin.segmentOffset < warmup then
		return { result = result("insufficient_warmup") }
	end
	for k = 1, HORIZON - 1 do
		if dataset:indexOf(t + k * BAR_SECONDS) == nil then
			return { result = result("missing_intermediate_hour") }
		end
	end
	if target == nil then
		return { result = result("missing_target") }
	end
	if target.dateKey ~= origin.dateKey then
		return { result = result("different_local_date") }
	end
	if split == "none" then
		return { result = result("split_boundary") }
	end
	return { result = result(nil), origin = origin, target = target }
end

-- Structural eligibility only (no returns). Safe for counting sealed-period origins.
function Targets.classify(dataset: Dataset, pair: Pair, splits: Splits, warmup: number): OutcomePair
	return classify(dataset, pair, splits, warmup).result
end

-- Eligibility plus the two eight-hour log returns for an eligible origin. Evaluator use only.
function Targets.lookup(dataset: Dataset, pair: Pair, splits: Splits, warmup: number): OutcomePair
	local c = classify(dataset, pair, splits, warmup)
	if not c.result.eligible then
		return c.result
	end
	local origin, target = c.origin :: Pair, c.target :: Pair
	local spy = math.log(target.spy[CLOSE] / origin.spy[CLOSE])
	local qqq = math.log(target.qqq[CLOSE] / origin.qqq[CLOSE])
	local r = c.result
	if not (isFinite(spy) and isFinite(qqq)) then
		return frozen({
			eligible = false,
			reason = "invalid_input",
			split = r.split,
			decisionTime = r.decisionTime,
			outcomeTime = r.outcomeTime,
			targetT = r.targetT,
		})
	end
	return frozen({
		eligible = true,
		reason = nil,
		split = r.split,
		spy = spy,
		qqq = qqq,
		decisionTime = r.decisionTime,
		outcomeTime = r.outcomeTime,
		targetT = r.targetT,
	})
end

return Targets
