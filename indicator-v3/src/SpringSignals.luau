-- Spring Indicator physical scorer, protocol spring-consensus-v1 (handover 6.2, contract D1-D3).
-- Sees only narrow SpringState samples: measured x/v plus observation identity. Never a market record,
-- price, return, label, raw feature, drive or force, and never a market fallback.
--   calibrate: training-only, equilibrium-referenced scaling (z = clamp(value / populationStd, -5, 5)),
--              near-constant coordinates dropped, nearest-rank 0.65 quantile entry threshold.
--   score:     node -> bank -> total consensus with contributions that sum to the total score.
--   new/step:  score(sample) then the shared SpringPolicy with source "physics".
local SpringPolicy = if script then require(script.Parent.SpringPolicy) else require("./SpringPolicy")
local SpringState = if script then require(script.Parent.SpringState) else require("./SpringState")

local SpringSignals = {}
SpringSignals.CALIBRATION_SCHEMA = "spring-calibration-v1"

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function deepFreeze(t)
	for _, v in t do if type(v) == "table" then deepFreeze(v) end end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end

-- Nearest rank: the sorted element at max(1, ceil(q * n)). The epsilon only absorbs binary rounding of q * n.
function SpringSignals.nearestRank(n, quantile)
	assert(type(n) == "number" and n >= 1 and n % 1 == 0, "SpringSignals: positive integer count required")
	assert(finite(quantile) and quantile > 0 and quantile <= 1, "SpringSignals: quantile in (0,1] required")
	return math.clamp(math.ceil(quantile * n - 1e-9), 1, n)
end

-- Scores measured x/v against frozen coordinate statistics. Only eligible directional nodes vote.
local function scoreValues(x, v, coordinates, eligible, cal)
	local clip = cal.clip
	local zX, zV, nodeScores, contributions = table.create(24, 0), table.create(24, 0), table.create(24, 0), table.create(24, 0)
	local bankScores, clipped = table.create(3, 0), 0
	for b = 1, 3 do
		local ids = eligible[b]
		local count, sum = #ids, 0
		for _, i in ids do
			local cx, cv = coordinates[i], coordinates[24 + i]
			local rawX = x[i] / cx.std
			if math.abs(rawX) > clip then clipped += 1 end
			local zx = math.clamp(rawX, -clip, clip)
			local zv, nodeScore = 0, 0
			if cv.active then
				local rawV = v[i] / cv.std
				if math.abs(rawV) > clip then clipped += 1 end
				zv = math.clamp(rawV, -clip, clip)
				nodeScore = cal.xWeight * zx / clip + cal.vWeight * zv / clip
			else
				nodeScore = zx / clip
			end
			zX[i], zV[i], nodeScores[i] = zx, zv, nodeScore
			contributions[i] = nodeScore / count / 3
			sum += nodeScore
		end
		bankScores[b] = sum / count
	end
	local score = (bankScores[1] + bankScores[2] + bankScores[3]) / 3
	assert(finite(score), "SpringSignals: non-finite score")
	return { valid = true, zX = zX, zV = zV, nodeScores = nodeScores, nodeContributions = contributions,
		bankScores = bankScores, score = score, clipped = clipped }
end

function SpringSignals.calibrate(trainingSamples, descriptor, protocol)
	local p = SpringPolicy.validateProtocol(protocol)
	SpringState.checkDescriptor(descriptor)
	assert(descriptor.protocolId == p.id, "SpringSignals: descriptor protocol mismatch")
	assert(type(trainingSamples) == "table", "SpringSignals: training sample array required")
	local cal = p.calibration

	-- D1 membership: valid samples whose segment position (the policy's warm-up count) is >= 12.
	local members, invalid, warm = {}, 0, 0
	local prev, warmup = nil, 0
	for i = 1, #trainingSamples do
		local s = SpringState.checkSample(trainingSamples[i])
		local broke = SpringPolicy.segmentBreak(prev, s)
		prev = { t = s.t, day = s.day }
		warmup = SpringPolicy.nextWarmup(warmup, broke, s.valid)
		if not s.valid then
			invalid += 1
		elseif warmup < cal.segmentPositionMin then
			warm += 1
		else
			members[#members + 1] = s
		end
	end
	local n = #members

	local coordinates = {}
	if n > 0 then
		for k = 1, 48 do
			local node = (k - 1) % 24 + 1
			local kind = if k <= 24 then "x" else "v"
			local sum = 0
			for _, s in members do sum += s[kind][node] end
			local mean = sum / n
			local squares = 0
			for _, s in members do local d = s[kind][node] - mean; squares += d * d end
			local std = math.sqrt(squares / n) -- population std (divide by n), as in Learning.luau
			local rms = math.sqrt(mean * mean + std * std)
			local active = std > math.max(cal.dropAbsolute, cal.dropRelative * rms)
			local clipCount = 0
			if active then
				for _, s in members do if math.abs(s[kind][node] / std) > cal.clip then clipCount += 1 end end
			end
			coordinates[k] = {
				node = node, kind = kind, name = descriptor.stateNames[k],
				mean = mean, std = std, rms = rms, active = active,
				directional = descriptor.nodes[node].directional,
				clipCount = clipCount, clipFraction = clipCount / n,
			}
		end
	end

	local eligible = table.create(3)
	for b = 1, 3 do
		local ids = {}
		if n > 0 then
			for _, id in descriptor.banks[b].directional do
				if coordinates[id].active then table.insert(ids, id) end
			end
		end
		eligible[b] = ids
	end

	local unavailableReason = nil
	if n < cal.minSamples then
		unavailableReason = "insufficient_calibration_samples"
	else
		local short = {}
		for b = 1, 3 do
			if #eligible[b] < cal.minEligiblePerBank then table.insert(short, descriptor.banks[b].name) end
		end
		if #short > 0 then unavailableReason = "insufficient_eligible_nodes:" .. table.concat(short, ",") end
	end

	local thresholds, scoreSummary = nil, nil
	if unavailableReason == nil then
		local absolute = table.create(n)
		local sum, positive = 0, 0
		local bankSums, bankPositive = { 0, 0, 0 }, { 0, 0, 0 }
		local lowest, highest = math.huge, -math.huge
		for j, s in members do
			local d = scoreValues(s.x, s.v, coordinates, eligible, cal)
			absolute[j] = math.abs(d.score)
			sum += d.score
			if d.score > 0 then positive += 1 end
			lowest, highest = math.min(lowest, d.score), math.max(highest, d.score)
			for b = 1, 3 do
				bankSums[b] += d.bankScores[b]
				if d.bankScores[b] > 0 then bankPositive[b] += 1 end
			end
		end
		table.sort(absolute)
		local rank = SpringSignals.nearestRank(n, cal.quantile)
		local unclamped = absolute[rank]
		local entry = math.clamp(unclamped, cal.entryMin, cal.entryMax)
		thresholds = {
			quantile = cal.quantile, unclamped = unclamped, rank = rank, n = n,
			entry = entry, exit = cal.exitRatio * entry, bankDeadband = cal.deadbandRatio * entry,
		}
		scoreSummary = {
			mean = sum / n, positiveShare = positive / n, min = lowest, max = highest,
			bankMeans = { bankSums[1] / n, bankSums[2] / n, bankSums[3] / n },
			bankPositiveShares = { bankPositive[1] / n, bankPositive[2] / n, bankPositive[3] / n },
		}
	end

	return deepFreeze({
		schema = SpringSignals.CALIBRATION_SCHEMA,
		protocolId = p.id,
		available = unavailableReason == nil,
		unavailableReason = unavailableReason,
		n = n,
		inputCount = #trainingSamples,
		excludedInvalid = invalid,
		excludedWarmup = warm,
		firstSampleId = if n > 0 then members[1].id else nil,
		lastSampleId = if n > 0 then members[n].id else nil,
		coordinates = coordinates,
		eligible = eligible,
		thresholds = thresholds,
		scoreSummary = scoreSummary,
	})
end

local function checkCalibration(calibration)
	assert(type(calibration) == "table" and calibration.schema == SpringSignals.CALIBRATION_SCHEMA and table.isfrozen(calibration),
		"SpringSignals: a frozen calibration from SpringSignals.calibrate is required")
	assert(calibration.protocolId == SpringPolicy.PROTOCOL_ID, "SpringSignals: calibration protocol mismatch")
	return calibration
end

-- Diagnostics for one narrow sample. Invalid samples and unavailable calibrations give {valid=false, reason}.
function SpringSignals.score(sample, calibration)
	SpringState.checkSample(sample)
	checkCalibration(calibration)
	if not calibration.available then
		return { valid = false, reason = "calibration_unavailable" }
	end
	if not sample.valid then
		return { valid = false, reason = sample.invalidReason }
	end
	return scoreValues(sample.x, sample.v, calibration.coordinates, calibration.eligible, SpringPolicy.protocol().calibration)
end

local Machine = {}
Machine.__index = Machine

function SpringSignals.new(calibration, protocol)
	local p = SpringPolicy.validateProtocol(protocol)
	checkCalibration(calibration)
	local policy = if calibration.available then SpringPolicy.new(calibration.thresholds, p, "physics") else nil
	return setmetatable({ calibration = calibration, policy = policy }, Machine)
end

-- The intent's availability time. A sample keeps the bar's own availableT (also when it mismatches t + 300, which makes
-- the sample invalid). Only a bar with no availableT falls back to t + 300, exactly as Execution does (contract D9), so
-- such a bar yields the D7 invalid-state intent instead of aborting the run. The sample itself stays invalid.
local function intentAvailableT(sample)
	if sample.availableT ~= nil then return sample.availableT end
	return sample.t + SpringPolicy.protocol().availabilityLag
end

-- The physical wrapper: the only directional input is the copied x/v sample.
function Machine:step(sample, positionContext)
	SpringState.checkSample(sample)
	if self.policy == nil then
		-- Unavailable calibration: every intent is HOLD with an explicit reason; never a market fallback.
		SpringPolicy.checkPositionContext(positionContext)
		return {
			action = "HOLD", source = "physics", reason = "calibration_unavailable",
			availableT = intentAvailableT(sample), sampleId = sample.id,
			diagnostics = {
				valid = false, reason = "calibration_unavailable:" .. tostring(self.calibration.unavailableReason),
				setup = "none", state = self:state(), blocked = "calibration_unavailable",
			},
		}
	end
	local diagnostics = SpringSignals.score(sample, self.calibration)
	local observation = { id = sample.id, t = sample.t, availableT = intentAvailableT(sample), day = sample.day, reset = sample.reset }
	return self.policy:step(diagnostics, observation, positionContext)
end

function Machine:resetBoundary()
	if self.policy then self.policy:resetBoundary() end
end

function Machine:state()
	if self.policy then return self.policy:state() end
	return { warmup = 0, posConfirm = 0, negConfirm = 0, longExit = 0, shortExit = 0 }
end

return SpringSignals
