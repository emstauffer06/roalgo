--!strict
-- Optional R60 regime block (plan Section 3, "Optional regime inputs for R60"; disabled by default in config).
--
-- Ten bounded values appended to the R50 row, SPY then QQQ, each: four one-step state probabilities + one mask.
--   segmentOffset 1..3 (no state yet):  pi * P  with pi_j = (count_j + 1) / (total + 4), mask 0
--   segmentOffset >= 4 (state i):       row i of the frozen P, mask 1
-- No z-scaling is applied to these columns. The Markov artifact must be fitted on training only and frozen before
-- any R60 state is generated; this module never updates it.
local Markov = require("./Markov")

type MarkovModel = Markov.MarkovModel

local RegimeFeatures = {}

RegimeFeatures.DIMENSION = 10
RegimeFeatures.VERSION = "mrl-regime-block-1"
RegimeFeatures.NAMES = table.freeze({
	"spy_regime_p1",
	"spy_regime_p2",
	"spy_regime_p3",
	"spy_regime_p4",
	"spy_regime_mask",
	"qqq_regime_p1",
	"qqq_regime_p2",
	"qqq_regime_p3",
	"qqq_regime_p4",
	"qqq_regime_mask",
})
-- Bounded columns: none is z-scored at the physical input stage.
RegimeFeatures.CONTINUOUS = table.freeze(table.create(10, false))

local KEYS = { "spy", "qqq" }
local S = Markov.STATE_COUNT

-- (pi P)_j = sum_i pi_i P_ij (row vector times row-stochastic matrix).
local function priorStep(rec: any): { number }
	local out = table.create(S, 0)
	for i = 1, S do
		local w = rec.pi[i]
		local row = rec.P[i]
		for j = 1, S do
			out[j] += w * row[j]
		end
	end
	return out
end

-- states: {spyState, qqqState} from Markov.states, or nil for the first three observations of a segment.
function RegimeFeatures.compute(model: MarkovModel, states: { number }?, segmentOffset: number): { number }
	if type(segmentOffset) ~= "number" or segmentOffset < 1 or segmentOffset ~= math.floor(segmentOffset) then
		error("RegimeFeatures: segmentOffset must be a positive integer", 2)
	end
	local warmed = segmentOffset >= Markov.WARMUP
	if not warmed and states ~= nil then
		error("RegimeFeatures: a state cannot exist before the fourth observation of a segment", 2)
	end
	if warmed and states == nil then
		error("RegimeFeatures: missing state at segmentOffset >= 4 (Markov.states must supply one)", 2)
	end
	local out = table.create(RegimeFeatures.DIMENSION, 0)
	for s, key in KEYS do
		local rec = (model :: any)[key]
		local base = (s - 1) * (S + 1)
		if warmed then
			local st = (states :: { number })[s]
			if type(st) ~= "number" or st < 1 or st > S or st ~= math.floor(st) then
				error(string.format("RegimeFeatures: state %s is out of range 1..4", tostring(st)), 2)
			end
			local row = rec.P[st]
			for j = 1, S do
				out[base + j] = row[j]
			end
			out[base + S + 1] = 1
		else
			local prior = priorStep(rec)
			for j = 1, S do
				out[base + j] = prior[j]
			end
			out[base + S + 1] = 0
		end
	end
	return out
end

return table.freeze(RegimeFeatures)
