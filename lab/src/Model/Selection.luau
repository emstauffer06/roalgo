--!strict
-- Validation ranking and tie policy (plan Section 5, "Selection budget"; Tasks 4 and 6).
--
--   score = mean over symbols of (validation RMSE_s / training target std_s), shared lambda for both heads;
--   zero (or non-finite) training target variance is rejected;
--   scores within 1e-12 (absolute) of the best remaining score are ties, broken by larger lambda, then smaller lag
--   count or lower physical preset id (P1 < P2 < P3), then config string and input order for determinism;
--   failed candidates are kept, with status "rejected:<reason>" and no score, after every scored candidate.
--
-- One call ranks one family within one profile (e.g. R50 RAW-RIDGE's 21 settings); mixing them is an error so the
-- headline comparison can never be decided by a cross-family ranking. Every candidate must carry a profileId and a
-- family (otherwise the mixing guard would compare nil with nil), and each (config, lambda) setting may appear only
-- once, so the declared candidate budget stays exact. Training error is never consulted.
local Types = require("../Types")

export type Candidate = Types.Candidate

export type CandidateMetrics = {
	profileId: string,
	family: string,
	config: string,
	lag: number?,
	preset: string?,
	lambda: number,
	validationRmse: { number }?, -- one per symbol, same order as trainingTargetStd
	status: string?, -- nil or "ok" for a fitted candidate; anything else marks a failure reason
}

local Selection = {}

Selection.TIE_TOLERANCE = 1e-12 -- plan Section 5 / config selection.tieTolerance

local function isFiniteNumber(x: any): boolean
	return type(x) == "number" and x - x == 0
end

-- Freezes without narrowing the static type (the analyzer would otherwise treat the record as read-only).
local function freezeInPlace(t: any)
	table.freeze(t)
end

local function presetNumber(preset: string?): number?
	if type(preset) ~= "string" then
		return nil
	end
	local digits = string.match(preset, "^P(%d+)$")
	return if digits then tonumber(digits) else nil
end

type Entry = { candidate: Candidate, index: number }

-- True when a should be chosen before b among tied scores.
local function preferred(a: Entry, b: Entry): boolean
	local ca, cb = a.candidate, b.candidate
	if ca.lambda ~= cb.lambda then
		return ca.lambda > cb.lambda
	end
	if ca.lag ~= nil and cb.lag ~= nil and ca.lag ~= cb.lag then
		return (ca.lag :: number) < (cb.lag :: number)
	end
	if ca.preset ~= nil and cb.preset ~= nil and ca.preset ~= cb.preset then
		local na, nb = presetNumber(ca.preset), presetNumber(cb.preset)
		if na ~= nil and nb ~= nil and na ~= nb then
			return na < nb
		end
		return (ca.preset :: string) < (cb.preset :: string)
	end
	if ca.config ~= cb.config then
		return ca.config < cb.config
	end
	return a.index < b.index
end

local function rejectedStatus(status: string): string
	if string.sub(status, 1, 9) == "rejected:" then
		return status
	end
	return "rejected:" .. status
end

function Selection.score(validationRmse: { number }, trainingTargetStd: { number }): number
	local total = 0
	for s = 1, #trainingTargetStd do
		total += validationRmse[s] / trainingTargetStd[s]
	end
	return total / #trainingTargetStd
end

function Selection.rank(candidates: { CandidateMetrics }, trainingTargetStd: { number }): { Candidate }
	if type(trainingTargetStd) ~= "table" or #trainingTargetStd == 0 then
		error("Selection: training target std must list one value per symbol", 2)
	end
	for s = 1, #trainingTargetStd do
		local v = trainingTargetStd[s]
		if not isFiniteNumber(v) then
			error(string.format("Selection: training target std for symbol %d is not a finite number", s), 2)
		end
		if v <= 0 then
			error(string.format("Selection: zero training target variance for symbol %d", s), 2)
		end
	end
	if type(candidates) ~= "table" or #candidates == 0 then
		error("Selection: no candidates to rank", 2)
	end
	local profileId, family = candidates[1].profileId, candidates[1].family
	local scored: { Entry } = {}
	local failed: { Candidate } = {}
	local seen: { [string]: number } = {}
	for i, c in candidates do
		if type(c.profileId) ~= "string" or c.profileId == "" or type(c.family) ~= "string" or c.family == "" then
			error(string.format("Selection: candidate %d needs a profileId and a family", i), 2)
		end
		if c.profileId ~= profileId or c.family ~= family then
			error("Selection: mixed profiles or families in one ranking (rank each family within one profile)", 2)
		end
		if type(c.config) ~= "string" then
			error(string.format("Selection: candidate %d has no config", i), 2)
		end
		if not isFiniteNumber(c.lambda) then
			error(string.format("Selection: candidate %d lambda is not a finite number", i), 2)
		end
		-- Each (config, lambda) setting appears once in the declared budget; a repeat would inflate the count.
		local key = c.config .. "@" .. string.format("%.17g", c.lambda)
		if seen[key] ~= nil then
			error(string.format("Selection: duplicate candidate %s (entries %d and %d)", key, seen[key], i), 2)
		end
		seen[key] = i
		local status = "ok"
		local score: number? = nil
		if c.status ~= nil and c.status ~= "ok" then
			status = rejectedStatus(c.status)
		else
			local rm = c.validationRmse
			if type(rm) ~= "table" or #rm ~= #trainingTargetStd then
				error(string.format("Selection: candidate %d validationRmse must have %d values", i, #trainingTargetStd), 2)
			end
			for s = 1, #rm do
				if not isFiniteNumber(rm[s]) then
					status = "rejected:non_finite_validation_rmse"
				elseif rm[s] < 0 then
					status = "rejected:negative_validation_rmse"
				end
			end
			if status == "ok" then
				local value = Selection.score(rm, trainingTargetStd)
				if isFiniteNumber(value) then
					score = value
				else
					status = "rejected:non_finite_score"
				end
			end
		end
		local out: Candidate = {
			profileId = c.profileId,
			family = c.family,
			config = c.config,
			lag = c.lag,
			preset = c.preset,
			lambda = c.lambda,
			score = score,
			status = status,
		}
		if status == "ok" then
			table.insert(scored, { candidate = out, index = i })
		else
			table.insert(failed, out)
		end
	end
	-- Repeatedly take the preferred candidate among those tied with the best remaining score.
	local ranked: { Candidate } = {}
	local remaining = scored
	while #remaining > 0 do
		local best = math.huge
		for _, e in remaining do
			best = math.min(best, e.candidate.score :: number)
		end
		local pick: Entry? = nil
		local pickAt = 0
		for k, e in remaining do
			if (e.candidate.score :: number) - best <= Selection.TIE_TOLERANCE then
				if pick == nil or preferred(e, pick) then
					pick, pickAt = e, k
				end
			end
		end
		local chosen = (pick :: Entry).candidate
		freezeInPlace(chosen)
		table.insert(ranked, chosen)
		table.remove(remaining, pickAt)
	end
	for _, f in failed do
		freezeInPlace(f)
		table.insert(ranked, f)
	end
	freezeInPlace(ranked)
	return ranked
end

-- The selected candidate (first scored one), or nil when every candidate failed.
function Selection.best(ranked: { Candidate }): Candidate?
	for _, c in ranked do
		if c.status == "ok" then
			return c
		end
	end
	return nil
end

return table.freeze(Selection)
