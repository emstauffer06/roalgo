--!strict
-- Four-state observable financial Markov reward model, fitted independently for SPY and QQQ
-- (plan Section 5, "Financial Markov baseline"; Task 4). Not MarkovJunior, not an HMM.
--
-- State inputs at a paired observation with segmentOffset >= 4, from the four most recent same-segment paired closes
-- c1..c4 (oldest first): r0 = ln(c4/c3), r1 = ln(c3/c2), r2 = ln(c2/c1); v = sqrt((r0^2 + r1^2 + r2^2) / 3).
-- tau = median of v over every state-bearing training observation (even count: mean of the two middle values).
--   state 1: r0 >= 0 and v <= tau     state 2: r0 < 0 and v <= tau
--   state 3: r0 >= 0 and v >  tau     state 4: r0 < 0 and v >  tau
-- Transitions N_ij: consecutive state-bearing observations exactly 3600 s apart in the same segment (and NY date),
-- both completed (t + 3600) strictly before validation_start. Rewards: the current one-hour return r0.
--   P_ij = (N_ij + 1) / (sum_j N_ij + 4)          (row-stochastic; row i = transitions FROM i)
--   globalReward = mean r0 over state-bearing training observations
--   mu_j = (sum r0 in state j + 20 * globalReward) / (count_j + 20)
--   pi_j = (count_j + 1) / (total + 4)            (plan Section 3 R60 prior; Laplace-smoothed state frequency)
--   forecast = sum_{k=1..8} p_k . mu,  p_0 = one-hot(current state),  p_k = p_(k-1) P   (exact finite sums)
--
-- The training stream must be an explicit, boundary-checked slice: contiguous paired indices, starting at a segment
-- boundary, every pair completed strictly before options.validationStart. Fit rejects anything else rather than
-- filtering it, so a final-inclusive Dataset can never be passed by accident.
local Types = require("../Types")

type Pair = Types.Pair

export type SymbolRecord = {
	symbol: string,
	tau: number,
	stateBearingCount: number,
	stateCounts: { number },
	rewardSums: { number },
	transitionCounts: { { number } },
	transitionTotal: number,
	P: { { number } },
	mu: { number },
	pi: { number },
	globalReward: number,
}

export type Provenance = {
	trainingPairCount: number,
	firstT: number,
	lastT: number,
	sourceHashes: { [string]: string },
}

export type MarkovModel = {
	format: string,
	stateDefinitionVersion: string,
	stateCount: number,
	laplace: number,
	rewardShrinkage: number,
	horizon: number,
	validationStart: number,
	spy: SymbolRecord,
	qqq: SymbolRecord,
	provenance: Provenance,
}

export type FitOptions = {
	validationStart: number,
	sourceHashes: { [string]: string }?,
}

local Markov = {}

Markov.STATE_COUNT = 4
Markov.LAPLACE = 1
Markov.REWARD_SHRINKAGE = 20
Markov.RETURNS_FOR_VOLATILITY = 3
Markov.HORIZON = 8
Markov.WARMUP = 4
Markov.BAR_SECONDS = 3600
Markov.STATE_DEFINITION_VERSION = "mrl-markov-states-1:r0-sign,v3-rms,tau-train-median"
Markov.FORMAT = "mrl-markov-model-1"
Markov.ROW_SUM_TOLERANCE = 1e-12

local SYMBOLS = { "SPY", "QQQ" }
local KEYS = { "spy", "qqq" }
local TIME, CLOSE = 1, 5
local S = 4

local function isFiniteNumber(x: any): boolean
	return type(x) == "number" and x - x == 0
end

local function isInteger(x: any): boolean
	return isFiniteNumber(x) and x == math.floor(x)
end

local function deepFreeze<T>(t: T): T
	if type(t) == "table" and not table.isfrozen(t :: any) then
		for _, v in t :: any do
			deepFreeze(v)
		end
		table.freeze(t :: any)
	end
	return t
end

local function zeros(n: number): { number }
	return table.create(n, 0)
end

local function zeroMatrix(n: number): { { number } }
	local m: { { number } } = {}
	for i = 1, n do
		m[i] = zeros(n)
	end
	return m
end

function Markov.classify(r0: number, v: number, tau: number): number
	if v <= tau then
		return if r0 >= 0 then 1 else 2
	end
	return if r0 >= 0 then 3 else 4
end

local function checkedClose(pair: any, key: string, where: string): number
	local b = pair[key]
	if type(b) ~= "table" then
		error(string.format("Markov: invalid close (%s bar missing at %s)", key, where), 4)
	end
	local c = b[CLOSE]
	if not isFiniteNumber(c) or c <= 0 then
		error(string.format("Markov: invalid close for %s at %s: %s", key, where, tostring(c)), 4)
	end
	if b[TIME] ~= pair.t then
		error(string.format("Markov: %s bar timestamp does not match pair t at %s", key, where), 4)
	end
	return c
end

-- r0 and v for one symbol from four consecutive same-segment pairs w[1..4] (oldest first).
local function stateInputs(w: { any }, key: string): (number, number)
	local where = "t=" .. tostring(w[4].t)
	local c1 = checkedClose(w[1], key, where)
	local c2 = checkedClose(w[2], key, where)
	local c3 = checkedClose(w[3], key, where)
	local c4 = checkedClose(w[4], key, where)
	local r0 = math.log(c4 / c3)
	local r1 = math.log(c3 / c2)
	local r2 = math.log(c2 / c1)
	return r0, math.sqrt((r0 * r0 + r1 * r1 + r2 * r2) / 3)
end

local function median(values: { number }): number
	local sorted = table.clone(values)
	table.sort(sorted)
	local n = #sorted
	if n % 2 == 1 then
		return sorted[(n + 1) // 2]
	end
	return (sorted[n // 2] + sorted[n // 2 + 1]) / 2
end

local function validateSlice(pairs: { any }, validationStart: number)
	local first = pairs[1]
	if type(first) ~= "table" or first.segmentOffset ~= 1 then
		error("Markov: training slice must start at a segment boundary (segmentOffset 1)", 3)
	end
	for k, p in pairs do
		if type(p) ~= "table" or not isInteger(p.t) or not isInteger(p.index) or not isInteger(p.dateKey) then
			error(string.format("Markov: pair %d lacks an integer t, index or dateKey", k), 3)
		end
		if p.decisionTime ~= p.t + Markov.BAR_SECONDS then
			error(string.format("Markov: pair %d decisionTime must equal t + 3600", k), 3)
		end
		if not (p.decisionTime < validationStart) then
			error(string.format(
				"Markov: training slice is not boundary-checked: pair %d (t=%s) completes at %s, not strictly before validationStart %s",
				k, tostring(p.t), tostring(p.decisionTime), tostring(validationStart)), 3)
		end
		if not isInteger(p.segmentOffset) or p.segmentOffset < 1 or p.segmentId == nil then
			error(string.format("Markov: inconsistent segment fields at pair %d", k), 3)
		end
		if k > 1 then
			local q = pairs[k - 1]
			if p.index ~= q.index + 1 or not (p.t > q.t) then
				error(string.format("Markov: training slice is not contiguous at pair %d", k), 3)
			end
			if p.segmentId == q.segmentId then
				if p.t - q.t ~= Markov.BAR_SECONDS or p.segmentOffset ~= q.segmentOffset + 1 or p.dateKey ~= q.dateKey then
					error(string.format("Markov: inconsistent segment data at pair %d", k), 3)
				end
			elseif p.segmentOffset ~= 1 then
				error(string.format("Markov: inconsistent segment start at pair %d", k), 3)
			elseif p.dateKey == q.dateKey and p.t - q.t == Markov.BAR_SECONDS then
				-- Plan Section 3: a segment starts only on the first pair, a NY date change, or a delta other than
				-- 3600 s. Accepting any other break would silently delay states and drop transitions.
				error(string.format("Markov: spurious segment break at pair %d (same NY date, exactly 3600 s after the previous pair)", k), 3)
			end
		end
		-- Closes are validated where they are used (every pair is used by some window, or by none if its
		-- segment is shorter than four); validate all here so a corrupt bar is never silently skipped.
		checkedClose(p, "spy", "pair " .. k)
		checkedClose(p, "qqq", "pair " .. k)
	end
end

type Observation = {
	k: number,
	t: number,
	decisionTime: number,
	segmentId: any,
	dateKey: any,
	r0: { number },
	v: { number },
}

function Markov.fit(trainingPairs: { Pair }, options: FitOptions): MarkovModel
	if type(options) ~= "table" or not isFiniteNumber(options.validationStart) then
		error("Markov: options.validationStart must be a finite number", 2)
	end
	local validationStart = options.validationStart
	if type(trainingPairs) ~= "table" or #trainingPairs == 0 then
		error("Markov: empty training sample", 2)
	end
	local pairs = trainingPairs :: { any }
	validateSlice(pairs, validationStart)

	local observations: { Observation } = {}
	for k = Markov.WARMUP, #pairs do
		local p = pairs[k]
		local w1 = pairs[k - 3]
		if p.segmentOffset >= Markov.WARMUP and w1.segmentId == p.segmentId and p.t - w1.t == 3 * Markov.BAR_SECONDS then
			local w = { w1, pairs[k - 2], pairs[k - 1], p }
			local r0s, vs = {}, {}
			for s, key in KEYS do
				r0s[s], vs[s] = stateInputs(w, key)
			end
			table.insert(observations, {
				k = k,
				t = p.t,
				decisionTime = p.decisionTime,
				segmentId = p.segmentId,
				dateKey = p.dateKey,
				r0 = r0s,
				v = vs,
			})
		end
	end
	if #observations == 0 then
		error("Markov: no state-bearing training observations (every segment is shorter than four pairs)", 2)
	end

	local records: { SymbolRecord } = {}
	for s, key in KEYS do
		local vs = {}
		for i, o in observations do
			vs[i] = o.v[s]
		end
		local tau = median(vs)
		local states = {}
		local stateCounts, rewardSums = zeros(S), zeros(S)
		local rewardTotal = 0
		for i, o in observations do
			local st = Markov.classify(o.r0[s], o.v[s], tau)
			states[i] = st
			stateCounts[st] += 1
			rewardSums[st] += o.r0[s]
			rewardTotal += o.r0[s]
		end
		local N = zeroMatrix(S)
		local transitionTotal = 0
		for i = 2, #observations do
			local a, b = observations[i - 1], observations[i]
			if b.k == a.k + 1 and b.segmentId == a.segmentId and b.dateKey == a.dateKey
				and b.t - a.t == Markov.BAR_SECONDS and a.decisionTime < validationStart and b.decisionTime < validationStart
			then
				N[states[i - 1]][states[i]] += 1
				transitionTotal += 1
			end
		end
		local total = #observations
		local globalReward = rewardTotal / total
		local P = zeroMatrix(S)
		for i = 1, S do
			local rowTotal = 0
			for j = 1, S do
				rowTotal += N[i][j]
			end
			for j = 1, S do
				P[i][j] = (N[i][j] + Markov.LAPLACE) / (rowTotal + Markov.LAPLACE * S)
			end
		end
		local mu, pi = zeros(S), zeros(S)
		for j = 1, S do
			mu[j] = (rewardSums[j] + Markov.REWARD_SHRINKAGE * globalReward) / (stateCounts[j] + Markov.REWARD_SHRINKAGE)
			pi[j] = (stateCounts[j] + 1) / (total + S)
		end
		records[s] = {
			symbol = SYMBOLS[s],
			tau = tau,
			stateBearingCount = total,
			stateCounts = stateCounts,
			rewardSums = rewardSums,
			transitionCounts = N,
			transitionTotal = transitionTotal,
			P = P,
			mu = mu,
			pi = pi,
			globalReward = globalReward,
		}
	end

	local hashes: { [string]: string } = {}
	if options.sourceHashes ~= nil then
		for name, h in options.sourceHashes do
			if type(name) ~= "string" or type(h) ~= "string" then
				error("Markov: options.sourceHashes must map names to strings", 2)
			end
			hashes[name] = h
		end
	end
	local model: MarkovModel = {
		format = Markov.FORMAT,
		stateDefinitionVersion = Markov.STATE_DEFINITION_VERSION,
		stateCount = S,
		laplace = Markov.LAPLACE,
		rewardShrinkage = Markov.REWARD_SHRINKAGE,
		horizon = Markov.HORIZON,
		validationStart = validationStart,
		spy = records[1],
		qqq = records[2],
		provenance = {
			trainingPairCount = #pairs,
			firstT = pairs[1].t,
			lastT = pairs[#pairs].t,
			sourceHashes = hashes,
		},
	}
	return deepFreeze(model)
end

-- {spyState, qqqState} from the most recent paired observations (oldest first; the last one is the current pair).
-- nil exactly when the current pair is one of the first three observations of its segment (segmentOffset 1..3),
-- which have no state. When the current pair is warmed (segmentOffset >= 4) the caller must supply its four most
-- recent same-segment pairs; a shorter or segment-spanning window is an error, never a silent nil, because the plan
-- requires a Markov forecast at every warmed origin.
function Markov.states(model: MarkovModel, recentPairs: { Pair }): { number }?
	if type(recentPairs) ~= "table" then
		error("Markov: states expects an array of recent pairs", 2)
	end
	local n = #recentPairs
	if n > Markov.WARMUP then
		error("Markov: states expects at most four recent pairs (oldest first)", 2)
	end
	if n == 0 then
		error("Markov: states needs the current pair (got an empty window)", 2)
	end
	local w = recentPairs :: { any }
	for i = 1, n do
		if type(w[i]) ~= "table" or not isInteger(w[i].segmentOffset) or w[i].segmentOffset < 1 then
			error("Markov: recent pairs must carry an integer segmentOffset >= 1", 2)
		end
	end
	local sameSegment = n == Markov.WARMUP
	for i = 2, n do
		if w[i].segmentId ~= w[i - 1].segmentId then
			sameSegment = false
		end
	end
	if w[n].segmentOffset < Markov.WARMUP then
		if sameSegment then
			-- Four same-segment pairs ending below offset 4 contradict the segment numbering.
			error("Markov: inconsistent segmentOffset in recent pairs", 2)
		end
		return nil
	end
	if not sameSegment then
		error(string.format(
			"Markov: warmed pair (segmentOffset %d) needs its four most recent same-segment pairs; the window has %d pair(s)%s",
			w[n].segmentOffset, n, if n == Markov.WARMUP then " spanning segments" else ""), 2)
	end
	for i = 2, 4 do
		if w[i].t - w[i - 1].t ~= Markov.BAR_SECONDS or w[i].segmentOffset ~= w[i - 1].segmentOffset + 1
			or w[i].dateKey ~= w[i - 1].dateKey
		then
			error("Markov: inconsistent segment data in recent pairs", 2)
		end
	end
	local out = table.create(2, 0)
	for s, key in KEYS do
		local r0, v = stateInputs(w, key)
		out[s] = Markov.classify(r0, v, (model :: any)[key].tau)
	end
	return out
end

-- Plan Section 7 spells this Markov.state; both names refer to the same function.
Markov.state = Markov.states

local function validateChain(P: { { number } }, mu: { number }, level: number): number
	local n = #P
	if n < 1 or #mu ~= n then
		error("Markov: transition matrix and rewards must have matching sizes", level)
	end
	for i = 1, n do
		local row = P[i]
		if type(row) ~= "table" or #row ~= n then
			error(string.format("Markov: transition row %d must have %d entries", i, n), level)
		end
		local s = 0
		for j = 1, n do
			local p = row[j]
			if not isFiniteNumber(p) or p < 0 or p > 1 then
				error(string.format("Markov: transition row %d has an entry outside [0,1]", i), level)
			end
			s += p
		end
		if math.abs(s - 1) > Markov.ROW_SUM_TOLERANCE then
			error(string.format("Markov: transition row %d sums to %.17g, not 1", i, s), level)
		end
		if not isFiniteNumber(mu[i]) then
			error(string.format("Markov: reward %d is not finite", i), level)
		end
	end
	return n
end

-- Arithmetic kernel: sum_{k=1..horizon} (p_k . mu) with p_0 = one-hot(start), p_k = p_(k-1) P (row vector).
-- Accepts any horizon for fixtures; Markov.predict fixes the production horizon at 8.
function Markov.expectedRewardSum(P: { { number } }, mu: { number }, start: number, horizon: number): number
	local n = validateChain(P, mu, 3)
	if not isInteger(start) or start < 1 or start > n then
		error(string.format("Markov: state %s is out of range 1..%d", tostring(start), n), 2)
	end
	if not isInteger(horizon) or horizon < 1 then
		error("Markov: horizon must be a positive integer", 2)
	end
	local p = zeros(n)
	p[start] = 1
	local total = 0
	for _ = 1, horizon do
		local q = zeros(n)
		for i = 1, n do
			local pi = p[i]
			if pi ~= 0 then
				local row = P[i]
				for j = 1, n do
					q[j] += pi * row[j]
				end
			end
		end
		p = q
		local dot = 0
		for j = 1, n do
			dot += p[j] * mu[j]
		end
		total += dot
	end
	return total
end

-- Two expected eight-hour log returns {SPY, QQQ}. A missing state is an error, never a zero forecast.
function Markov.predict(model: MarkovModel, states: { number }, horizon: number): { number }
	if horizon ~= Markov.HORIZON then
		error(string.format("Markov: horizon must be 8 in production (got %s)", tostring(horizon)), 2)
	end
	if type(states) ~= "table" or #states ~= 2 then
		error("Markov: states must be {spyState, qqqState}; a missing state cannot be forecast", 2)
	end
	for s = 1, 2 do
		local st = states[s]
		if not isInteger(st) or st < 1 or st > S then
			error(string.format("Markov: state %s is out of range 1..4", tostring(st)), 2)
		end
	end
	return {
		Markov.expectedRewardSum(model.spy.P, model.spy.mu, states[1], Markov.HORIZON),
		Markov.expectedRewardSum(model.qqq.P, model.qqq.mu, states[2], Markov.HORIZON),
	}
end

-- The plan's pi per symbol {SPY pi, QQQ pi}: pi_j = (trainingStateCount_j + 1) / (totalTrainingStates + 4).
-- This is the Laplace-smoothed training state frequency used by the R60 regime block, not an eigenvector of P.
function Markov.stationaryPi(model: MarkovModel): { { number } }
	return { table.clone(model.spy.pi), table.clone(model.qqq.pi) }
end

--------------------------------------------------------------------------------------------------
-- Artifacts (markov-model.json content). serialize returns a JSON-safe plain table; deserialize validates shapes,
-- bounds, row sums and that P, mu and pi are consistent with the stored counts, then freezes the result.

local function copyMatrix(m: { { number } }): { { number } }
	local out: { { number } } = {}
	for i = 1, #m do
		out[i] = table.clone(m[i])
	end
	return out
end

local function serializeRecord(r: SymbolRecord): { [string]: any }
	return {
		symbol = r.symbol,
		tau = r.tau,
		stateBearingCount = r.stateBearingCount,
		stateCounts = table.clone(r.stateCounts),
		rewardSums = table.clone(r.rewardSums),
		transitionCounts = copyMatrix(r.transitionCounts),
		transitionTotal = r.transitionTotal,
		P = copyMatrix(r.P),
		mu = table.clone(r.mu),
		pi = table.clone(r.pi),
		globalReward = r.globalReward,
	}
end

function Markov.serialize(model: MarkovModel): { [string]: any }
	local hashes = {}
	for k, v in model.provenance.sourceHashes do
		hashes[k] = v
	end
	return {
		format = model.format,
		stateDefinitionVersion = model.stateDefinitionVersion,
		stateCount = model.stateCount,
		laplace = model.laplace,
		rewardShrinkage = model.rewardShrinkage,
		horizon = model.horizon,
		validationStart = model.validationStart,
		spy = serializeRecord(model.spy),
		qqq = serializeRecord(model.qqq),
		provenance = {
			trainingPairCount = model.provenance.trainingPairCount,
			firstT = model.provenance.firstT,
			lastT = model.provenance.lastT,
			sourceHashes = hashes,
		},
	}
end

local function artifactError(reason: string): never
	error("Markov: artifact " .. reason, 0)
end

local function numbers(v: any, name: string, length: number): { number }
	if type(v) ~= "table" or #v ~= length then
		artifactError(string.format("%s must be an array of %d numbers", name, length))
	end
	local out = table.create(length, 0)
	for i = 1, length do
		if not isFiniteNumber(v[i]) then
			artifactError(string.format("%s[%d] is not a finite number", name, i))
		end
		out[i] = v[i]
	end
	return out
end

local function close(a: number, b: number, relative: number, absolute: number): boolean
	return math.abs(a - b) <= math.max(absolute, relative * math.max(math.abs(a), math.abs(b)))
end

local function deserializeRecord(t: any, symbol: string): SymbolRecord
	if type(t) ~= "table" or t.symbol ~= symbol then
		artifactError("record for " .. symbol .. " is missing")
	end
	local name = symbol .. "."
	if not isFiniteNumber(t.tau) or t.tau < 0 then
		artifactError(name .. "tau must be finite and >= 0")
	end
	local stateCounts = numbers(t.stateCounts, name .. "stateCounts", S)
	local rewardSums = numbers(t.rewardSums, name .. "rewardSums", S)
	local mu = numbers(t.mu, name .. "mu", S)
	local pi = numbers(t.pi, name .. "pi", S)
	local total = 0
	for j = 1, S do
		if not isInteger(stateCounts[j]) or stateCounts[j] < 0 then
			artifactError(name .. "stateCounts must be non-negative integers")
		end
		total += stateCounts[j]
	end
	if total < 1 or t.stateBearingCount ~= total then
		artifactError(name .. "stateBearingCount must equal the sum of stateCounts (>= 1)")
	end
	if type(t.transitionCounts) ~= "table" or #t.transitionCounts ~= S or type(t.P) ~= "table" or #t.P ~= S then
		artifactError(name .. "transitionCounts and P must be 4 x 4")
	end
	local N: { { number } } = {}
	local P: { { number } } = {}
	local transitionTotal = 0
	for i = 1, S do
		N[i] = numbers(t.transitionCounts[i], name .. "transitionCounts[" .. i .. "]", S)
		P[i] = numbers(t.P[i], name .. "P[" .. i .. "]", S)
		local rowTotal, rowSum = 0, 0
		for j = 1, S do
			if not isInteger(N[i][j]) or N[i][j] < 0 then
				artifactError(name .. "transitionCounts must be non-negative integers")
			end
			rowTotal += N[i][j]
		end
		for j = 1, S do
			local p = P[i][j]
			if not (p > 0 and p < 1) then
				artifactError(string.format("%sP[%d][%d] is outside (0,1)", name, i, j))
			end
			if not close(p, (N[i][j] + Markov.LAPLACE) / (rowTotal + Markov.LAPLACE * S), 0, 1e-12) then
				artifactError(string.format("%sP[%d][%d] does not match the transition counts", name, i, j))
			end
			rowSum += p
		end
		if math.abs(rowSum - 1) > Markov.ROW_SUM_TOLERANCE then
			artifactError(string.format("%sP row %d does not sum to 1", name, i))
		end
		transitionTotal += rowTotal
	end
	if t.transitionTotal ~= transitionTotal then
		artifactError(name .. "transitionTotal must equal the sum of transitionCounts")
	end
	if not isFiniteNumber(t.globalReward) then
		artifactError(name .. "globalReward must be finite")
	end
	local g = t.globalReward
	for j = 1, S do
		local expectedMu = (rewardSums[j] + Markov.REWARD_SHRINKAGE * g) / (stateCounts[j] + Markov.REWARD_SHRINKAGE)
		if not close(mu[j], expectedMu, 1e-12, 1e-300) then
			artifactError(string.format("%smu[%d] does not match rewardSums/globalReward", name, j))
		end
		if not close(pi[j], (stateCounts[j] + 1) / (total + S), 0, 1e-12) then
			artifactError(string.format("%spi[%d] does not match stateCounts", name, j))
		end
	end
	return {
		symbol = symbol,
		tau = t.tau,
		stateBearingCount = total,
		stateCounts = stateCounts,
		rewardSums = rewardSums,
		transitionCounts = N,
		transitionTotal = transitionTotal,
		P = P,
		mu = mu,
		pi = pi,
		globalReward = g,
	}
end

function Markov.deserialize(t: { [string]: any }): MarkovModel
	if type(t) ~= "table" or t.format ~= Markov.FORMAT then
		artifactError("format must be " .. Markov.FORMAT)
	end
	if t.stateDefinitionVersion ~= Markov.STATE_DEFINITION_VERSION then
		artifactError("stateDefinitionVersion must be " .. Markov.STATE_DEFINITION_VERSION)
	end
	if t.stateCount ~= S or t.laplace ~= Markov.LAPLACE or t.rewardShrinkage ~= Markov.REWARD_SHRINKAGE
		or t.horizon ~= Markov.HORIZON
	then
		artifactError("fixed design constants differ from version 1")
	end
	if not isFiniteNumber(t.validationStart) then
		artifactError("validationStart must be finite")
	end
	local prov = t.provenance
	if type(prov) ~= "table" or not isInteger(prov.trainingPairCount) or prov.trainingPairCount < 1
		or not isFiniteNumber(prov.firstT) or not isFiniteNumber(prov.lastT) or type(prov.sourceHashes) ~= "table"
	then
		artifactError("provenance is incomplete")
	end
	-- A training-only fit has every pair completed (t + 3600) strictly before validationStart.
	if not (prov.firstT <= prov.lastT) or not (prov.lastT + Markov.BAR_SECONDS < t.validationStart) then
		artifactError("provenance is not a training-only fit (firstT <= lastT and lastT + 3600 < validationStart required)")
	end
	local hashes: { [string]: string } = {}
	for k, v in prov.sourceHashes do
		if type(k) ~= "string" or type(v) ~= "string" then
			artifactError("provenance.sourceHashes must map names to strings")
		end
		hashes[k] = v
	end
	local model: MarkovModel = {
		format = Markov.FORMAT,
		stateDefinitionVersion = Markov.STATE_DEFINITION_VERSION,
		stateCount = S,
		laplace = Markov.LAPLACE,
		rewardShrinkage = Markov.REWARD_SHRINKAGE,
		horizon = Markov.HORIZON,
		validationStart = t.validationStart,
		spy = deserializeRecord(t.spy, "SPY"),
		qqq = deserializeRecord(t.qqq, "QQQ"),
		provenance = {
			trainingPairCount = prov.trainingPairCount,
			firstT = prov.firstT,
			lastT = prov.lastT,
			sourceHashes = hashes,
		},
	}
	return deepFreeze(model)
end

return table.freeze(Markov)
