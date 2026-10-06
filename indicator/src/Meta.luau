-- Experimental logistic entry filter. Scores are not calibrated probabilities.
-- Fit only closed, unfiltered executed trades; all transforms are training-only.
local Meta = {}
local DIMENSIONS = 9
local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < math.huge
end
local function sigmoid(x)
	x = math.clamp(x, -30, 30)
	return 1 / (1 + math.exp(-x))
end
local function validVector(vector)
	if type(vector) ~= "table" or #vector ~= DIMENSIONS then return false end
	for _, value in vector do if not finite(value) then return false end end
	return true
end
function Meta.vector(feature, state)
	return {
		feature.drive, feature.volatility * 100,
		math.log(math.max(feature.volumeRatio, 1e-6)), feature.efficiency,
		state.fast, state.slow, state.velocity, state.energy, state.fast - state.slow,
	}
end
function Meta.score(model, vector)
	assert(validVector(vector), "meta vector must contain nine finite values")
	local z = model.weights[1]
	for j = 1, DIMENSIONS do
		local scaled = math.clamp((vector[j] - model.means[j]) / model.scales[j], -8, 8)
		z += model.weights[j + 1] * scaled
	end
	return sigmoid(z)
end
function Meta.fit(trades, options)
	options = options or {}
	local samples, latest, positives = {}, 0, 0
	local cutoff = options.cutoff
	if cutoff ~= nil then assert(finite(cutoff), "meta cutoff must be finite") end
	for _, trade in trades do
		local availableT = if finite(trade.exitAvailableT) then trade.exitAvailableT else (if finite(trade.exitT) then trade.exitT + 1 else nil)
		if not trade.metaFiltered and finite(trade.exitT) and finite(trade.entryT)
			and finite(trade.signalT) and trade.signalT < trade.entryT and trade.entryT <= trade.exitT
			and finite(availableT) and availableT > trade.exitT
			and (cutoff == nil or (trade.exitT < cutoff and availableT <= cutoff)) and finite(trade.netReturn) and validVector(trade.vector) then
			local label = if trade.netReturn > 0 then 1 else 0
			table.insert(samples, { vector = table.clone(trade.vector), label = label })
			latest = math.max(latest, availableT)
			positives += label
		end
	end
	local n = #samples
	if n < 30 then return nil, "Need at least 30 closed unfiltered trades before cutoff; found " .. n end
	if positives == 0 or positives == n then return nil, "Training labels contain only one outcome class" end
	local means, scales = table.create(DIMENSIONS, 0), table.create(DIMENSIONS, 0)
	for _, sample in samples do
		for j = 1, DIMENSIONS do means[j] += sample.vector[j] / n end
	end
	for _, sample in samples do
		for j = 1, DIMENSIONS do scales[j] += (sample.vector[j] - means[j]) ^ 2 / n end
	end
	for j = 1, DIMENSIONS do scales[j] = math.max(math.sqrt(scales[j]), 1e-6) end
	local weights = table.create(DIMENSIONS + 1, 0)
	local epochs, rate, penalty = options.epochs or 180, options.learningRate or 0.08, options.l2 or 0.01
	assert(finite(epochs) and epochs >= 1 and epochs <= 2000 and epochs % 1 == 0, "invalid meta epochs")
	assert(finite(rate) and rate > 0 and rate <= 1 and finite(penalty) and penalty >= 0, "invalid meta fit settings")
	local model = {
		means = means, scales = scales, weights = weights, sampleCount = n,
		cutoff = cutoff or latest, threshold = 0.55, calibrated = false,
		positiveCount = positives, featureCount = DIMENSIONS, label = "experimental logistic score",
	}
	for _ = 1, epochs do
		local gradient = table.create(DIMENSIONS + 1, 0)
		for _, sample in samples do
			local errorValue = Meta.score(model, sample.vector) - sample.label
			gradient[1] += errorValue / n
			for j = 1, DIMENSIONS do
				local value = math.clamp((sample.vector[j] - means[j]) / scales[j], -8, 8)
				gradient[j + 1] += errorValue * value / n
			end
		end
		weights[1] -= rate * gradient[1]
		for j = 2, DIMENSIONS + 1 do weights[j] -= rate * (gradient[j] + penalty * weights[j]) end
	end
	return model, nil
end
return Meta
