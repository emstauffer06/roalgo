-- Structural data audit (plan sections 2.3 and 6; Task 2 acceptance). CLI only.
-- Run from the project root:
--   luau lab/cli/audit.luau
--
-- Loads hourly-original (O14/R50) and hourly-combined (H14) through lab/generated/Sources, builds each paired
-- Dataset with Calendar.default(), classifies every origin with Targets.classify (structural only: no return
-- is computed for any period), and reproduces the plan's tables exactly:
--   O14/R50 paired input bars 8,850/4,022/7,015; New York dates 564/252/439; eligible origins per symbol
--   2,646/1,249/2,186 (totals 19,887 / 1,255 / 6,081); non-overlapping origins 564/252/439
--   H14 paired 31,292/4,022/7,015; dates 2,012/252/439; eligible 9,103/1,249/2,186; non-overlap 2,003/252/439
-- and checks that H14's validation/final paired-input, eligible-origin and non-overlap timestamp arrays equal
-- O14's element by element. Plan facts are asserted too: O14 SPY-only 75 / QQQ-only 0 timestamps, exactly one
-- origin removed by strict continuity, no O14 date without an eligible origin, and nine H14 training dates
-- without one. Every number is also
-- cross-checked against the independent Node audit (lab/generated/NodeStructureAudit.luau, written by
-- tools/prepare-lab.mjs with Intl dates and its own pairing code).
--
-- Split convention for paired input bars and dates: by decision time t+3600 against the decision half of the
-- section 2.4 inequalities (< validationStart train, < testStart validation, < datasetEnd final). Eligible
-- origins use the full 2.4 rule with outcome purge. Bar-start and New York date conventions are computed too
-- and must agree (every boundary is a New York midnight; no paired bar starts in the hour before one).
--
-- Prints one JSON object to stdout. Any mismatch raises an error after printing (non-zero exit).
local Sources = require("../generated/Sources")
local NodeAudit = require("../generated/NodeStructureAudit")
local Calendar = require("../src/Data/Calendar")
local Dataset = require("../src/Data/Dataset")
local Targets = require("../src/Data/Targets")
local Config = require("../src/Config")

local cfg = Config.values
local SPLITS = { "train", "validation", "final" }
local BAR = cfg.barSeconds
local H = cfg.horizonHours
local WARMUP = cfg.warmupObservations
local S = cfg.splits

local EXPECTED = {
	O14 = {
		pairedInputBars = { 8850, 4022, 7015 },
		nyDates = { 564, 252, 439 },
		eligibleOrigins = { 2646, 1249, 2186 },
		nonOverlappingOrigins = { 564, 252, 439 },
		-- Section 6: one non-overlapping origin per New York date, so no date lacks an eligible origin.
		datesWithoutEligibleOrigin = { 0, 0, 0 },
		total = { pairedInputBars = 19887, nyDates = 1255, eligibleOrigins = 6081 },
		-- Section 1: SPY has 75 extra timestamps, QQQ none; section 2.3: one candidate removed by continuity.
		facts = { spyOnly = 75, qqqOnly = 0, endpointOnlyIntermediateGaps = 1 },
	},
	H14 = {
		pairedInputBars = { 31292, 4022, 7015 },
		nyDates = { 2012, 252, 439 },
		eligibleOrigins = { 9103, 1249, 2186 },
		nonOverlappingOrigins = { 2003, 252, 439 },
		-- Section 2.3: nine H14 training dates have no eligible origin.
		datesWithoutEligibleOrigin = { 9, 0, 0 },
		total = { pairedInputBars = 42329, nyDates = 2703, eligibleOrigins = 12538, nonOverlappingOrigins = 2694 },
		facts = {},
	},
}

-- Tables carrying this metatable encode as JSON arrays even when empty.
local ARRAY = {}
local mismatches: { string } = setmetatable({}, ARRAY) :: any
local function mismatch(msg: string)
	table.insert(mismatches, msg)
end

-- Minimal deterministic JSON encoder (sorted object keys; arrays are tables with 1..n keys).
local function encode(v: any, indent: string): string
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			error("audit: non-finite number in output", 2)
		end
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v)
		end
		return string.format("%.17g", v)
	elseif t == "string" then
		return '"' .. string.gsub(v, '[%c"\\]', function(c)
			if c == '"' then
				return '\\"'
			elseif c == "\\" then
				return "\\\\"
			elseif c == "\n" then
				return "\\n"
			end
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	end
	local next = indent .. "  "
	local n = #v
	if n == 0 and getmetatable(v) == ARRAY then
		return "[]"
	end
	local isArray = n > 0
	for k in v do
		if type(k) ~= "number" or k < 1 or k > n or k ~= math.floor(k) then
			isArray = false
			break
		end
	end
	if isArray then
		local allNumbers = true
		for _, x in v do
			if type(x) ~= "number" then
				allNumbers = false
				break
			end
		end
		local parts = {}
		for i = 1, n do
			parts[i] = encode(v[i], next)
		end
		if allNumbers then
			return "[" .. table.concat(parts, ", ") .. "]"
		end
		return "[\n" .. next .. table.concat(parts, ",\n" .. next) .. "\n" .. indent .. "]"
	end
	local keys = {}
	for k in v do
		table.insert(keys, tostring(k))
	end
	if #keys == 0 then
		return "{}"
	end
	table.sort(keys)
	local parts = {}
	for i, k in keys do
		parts[i] = encode(k, next) .. ": " .. encode(v[k], next)
	end
	return "{\n" .. next .. table.concat(parts, ",\n" .. next) .. "\n" .. indent .. "}"
end

local calendar = Calendar.default()

local function boundaryDate(t: number): number?
	local lt = calendar:localTime(t)
	if lt.hour == 0 and lt.minute == 0 and t + lt.offsetSeconds == (t + lt.offsetSeconds) // 86400 * 86400 then
		return lt.dateKey
	end
	return nil
end
local vsDate, tsDate, deDate = boundaryDate(S.validationStart), boundaryDate(S.testStart), boundaryDate(S.datasetEnd)

local function bucket(x: number, a: number, b: number, c: number): string
	if x < a then
		return "train"
	elseif x < b then
		return "validation"
	elseif x < c then
		return "final"
	end
	return "none"
end

local function counter(): { [string]: number }
	return { train = 0, validation = 0, final = 0, none = 0 }
end

local function auditProfile(profileId: string, groupId: string)
	local spyRows = Sources.get(groupId, "SPY").load()
	local qqqRows = Sources.get(groupId, "QQQ").load()
	local ds = Dataset.new(spyRows, qqqRows, calendar)
	local stats = ds:stats()

	local conventions = { decisionTime = counter(), barStart = counter(), nyDate = counter() }
	local inputs = { train = {}, validation = {}, final = {}, none = {} } -- paired input timestamps by split
	local dates = { train = {}, validation = {}, final = {}, none = {} }
	local dateCount = { train = 0, validation = 0, final = 0 }
	local eligible = { train = {}, validation = {}, final = {} }
	local eligibleDates = { train = {}, validation = {}, final = {} }
	local reasons = { train = {}, validation = {}, final = {}, none = {} }
	local maxOffset, endpointOnly = 0, 0

	for _, p in ds:pairs() do
		local s = bucket(p.t + BAR, S.validationStart, S.testStart, S.datasetEnd)
		conventions.decisionTime[s] += 1
		table.insert(inputs[s], p.t)
		conventions.barStart[bucket(p.t, S.validationStart, S.testStart, S.datasetEnd)] += 1
		local byDate = if vsDate and tsDate and deDate then bucket(p.dateKey, vsDate, tsDate, deDate) else "none"
		conventions.nyDate[byDate] += 1
		if s ~= "none" and not dates[s][p.dateKey] then
			dates[s][p.dateKey] = true
			dateCount[s] += 1
		end
		local c = Targets.classify(ds, p, S, WARMUP)
		if c.eligible then
			table.insert(eligible[c.split], p.t)
			eligibleDates[c.split][p.dateKey] = true
			maxOffset = math.max(maxOffset, p.segmentOffset)
		else
			local r = reasons[s]
			r[c.reason :: string] = (r[c.reason :: string] or 0) + 1
			if c.reason == "missing_intermediate_hour" then
				-- Would this origin be eligible if the strict continuity rule were dropped?
				local ti = ds:indexOf(c.targetT)
				local target = if ti then ds:get(ti) else nil
				if target and target.dateKey == p.dateKey and Targets.splitOf(c.decisionTime, c.outcomeTime, S) ~= "none" then
					endpointOnly += 1
				end
			end
		end
	end

	-- Section 6: accept an origin only if its decision time is at or after the previous selected outcome time.
	local function nonOverlap(arr: { number }): { number }
		local selected, lastOutcome = {}, -math.huge
		for _, t in arr do
			if t + BAR >= lastOutcome then
				table.insert(selected, t)
				lastOutcome = t + (H + 1) * BAR
			end
		end
		return selected
	end
	local nonOverlapping = { train = nonOverlap(eligible.train), validation = nonOverlap(eligible.validation), final = nonOverlap(eligible.final) }

	local splitsOut = {}
	local total = { pairedInputBars = 0, nyDates = 0, eligibleOrigins = 0, nonOverlappingOrigins = 0 }
	for _, s in SPLITS do
		local without = 0
		for d in dates[s] do
			if not eligibleDates[s][d] then
				without += 1
			end
		end
		local row = {
			pairedInputBars = conventions.decisionTime[s],
			nyDates = dateCount[s],
			eligibleOrigins = #eligible[s],
			nonOverlappingOrigins = #nonOverlapping[s],
			datesWithoutEligibleOrigin = without,
		}
		splitsOut[s] = row
		for k in total do
			total[k] += row[k]
		end
	end

	return {
		profileId = profileId,
		source = groupId,
		manifestSha256 = Sources.groups[groupId].manifestSha256,
		symbolCounts = { SPY = stats.spyCount, QQQ = stats.qqqCount },
		pairedTotal = stats.pairedCount,
		spyOnly = stats.spyOnly,
		qqqOnly = stats.qqqOnly,
		segments = stats.segmentCount,
		conventions = conventions,
		splits = splitsOut,
		total = total,
		reasonsByInputSplit = reasons,
		maxEligibleSegmentOffset = maxOffset,
		endpointOnlyIntermediateGaps = endpointOnly,
		eligibleTimestamps = eligible,
		inputTimestamps = inputs,
		nonOverlappingTimestamps = nonOverlapping,
	}
end

local function compareToPlan(id: string, p: any)
	local e = EXPECTED[id]
	for _, key in { "pairedInputBars", "nyDates", "eligibleOrigins", "nonOverlappingOrigins", "datesWithoutEligibleOrigin" } do
		for i, s in SPLITS do
			if p.splits[s][key] ~= e[key][i] then
				mismatch(string.format("%s %s %s: plan %d, Luau %d", id, s, key, e[key][i], p.splits[s][key]))
			end
		end
	end
	for key, v in e.total do
		if p.total[key] ~= v then
			mismatch(string.format("%s total %s: plan %d, Luau %d", id, key, v, p.total[key]))
		end
	end
	for key, v in e.facts do
		if p[key] ~= v then
			mismatch(string.format("%s %s: plan %d, Luau %s", id, key, v, tostring(p[key])))
		end
	end
end

local function sameArray(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

local function compareToNode(id: string, p: any)
	local n = NodeAudit.profiles[id]
	if n == nil then
		mismatch("Node audit has no profile " .. id)
		return
	end
	if n.manifestSha256 ~= p.manifestSha256 then
		mismatch(id .. " Node audit used a different source manifest")
	end
	for _, key in { "pairedTotal", "spyOnly", "qqqOnly", "segments", "maxEligibleSegmentOffset", "endpointOnlyIntermediateGaps" } do
		if n[key] ~= p[key] then
			mismatch(string.format("%s %s: Node %s, Luau %s", id, key, tostring(n[key]), tostring(p[key])))
		end
	end
	for _, s in SPLITS do
		for key, v in p.splits[s] do
			if n.splits[s][key] ~= v then
				mismatch(string.format("%s %s %s: Node %s, Luau %s", id, s, key, tostring(n.splits[s][key]), tostring(v)))
			end
		end
		if not sameArray(n.eligibleTimestamps[s], p.eligibleTimestamps[s]) then
			mismatch(string.format("%s %s eligible timestamps differ from the Node audit", id, s))
		end
	end
	for conv, counts in p.conventions do
		for s, v in counts do
			if n.conventions[conv][s] ~= v then
				mismatch(string.format("%s convention %s %s: Node %s, Luau %d", id, conv, s, tostring(n.conventions[conv][s]), v))
			end
		end
	end
	for s, rs in p.reasonsByInputSplit do
		local nr = n.reasonsByInputSplit[s] or {}
		for reason, v in rs do
			if nr[reason] ~= v then
				mismatch(string.format("%s %s %s: Node %s, Luau %d", id, s, reason, tostring(nr[reason]), v))
			end
		end
		for reason, v in nr do
			if rs[reason] ~= v then
				mismatch(string.format("%s %s %s: Node %d, Luau %s", id, s, reason, v, tostring(rs[reason])))
			end
		end
	end
end

local started = os.clock()
local profiles = {
	O14 = auditProfile("O14", "hourly-original"),
	H14 = auditProfile("H14", "hourly-combined"),
}
compareToPlan("O14", profiles.O14)
compareToPlan("H14", profiles.H14)
compareToNode("O14", profiles.O14)
compareToNode("H14", profiles.H14)

-- Section 2.3: H14's validation/final paired-input, eligible-origin and non-overlap timestamp arrays are
-- exactly identical to O14's (element by element, not only counts).
local identity = {}
for _, kind in { "inputTimestamps", "eligibleTimestamps", "nonOverlappingTimestamps" } do
	for _, s in { "validation", "final" } do
		local same = sameArray(profiles.H14[kind][s], profiles.O14[kind][s])
		identity[kind .. "." .. s] = same
		if not same then
			mismatch(string.format("H14 %s %s differ from O14", s, kind))
		end
	end
end

local crossChecks = {
	h14ValidationEqualsO14 = sameArray(profiles.H14.eligibleTimestamps.validation, profiles.O14.eligibleTimestamps.validation),
	h14FinalEqualsO14 = sameArray(profiles.H14.eligibleTimestamps.final, profiles.O14.eligibleTimestamps.final),
	h14ValidationFinalArraysEqualO14 = identity,
	splitConventionsAgree = true,
	maxEligibleSegmentOffsetAtMostEight = profiles.O14.maxEligibleSegmentOffset <= 8 and profiles.H14.maxEligibleSegmentOffset <= 8,
	nodeAuditMatchesPlan = NodeAudit.matchesPlan == true,
}
if not crossChecks.h14ValidationEqualsO14 then
	mismatch("H14 validation eligible timestamps differ from O14")
end
if not crossChecks.h14FinalEqualsO14 then
	mismatch("H14 final eligible timestamps differ from O14")
end
for id, p in profiles do
	for _, conv in { "barStart", "nyDate" } do
		for s, v in p.conventions.decisionTime do
			if p.conventions[conv][s] ~= v then
				crossChecks.splitConventionsAgree = false
				mismatch(string.format("%s %s convention disagrees with decision-time for %s", id, conv, s))
			end
		end
	end
end
if not crossChecks.nodeAuditMatchesPlan then
	mismatch("the Node audit itself does not match the plan")
end

-- Output: the arrays are summarised (count/first/last); they were compared element by element above.
local function summarise(p: any)
	local out = table.clone(p)
	for _, kind in { "eligibleTimestamps", "inputTimestamps", "nonOverlappingTimestamps" } do
		local e = {}
		for _, s in SPLITS do
			local a = p[kind][s]
			e[s] = { count = #a, first = a[1], last = a[#a] }
		end
		out[kind] = e
	end
	return out
end

local report = {
	auditVersion = "mrl-luau-structure-audit-1",
	generatedBy = "lab/cli/audit.luau",
	calendar = { zone = calendar.zone, coverageStart = calendar.coverageStart, coverageEnd = calendar.coverageEnd },
	config = { sourceSha256 = Config.sourceSha256, splits = { validationStart = S.validationStart, testStart = S.testStart, datasetEnd = S.datasetEnd }, warmup = WARMUP, horizonHours = H },
	splitConvention = "decision time t+3600 vs the decision half of section 2.4 (bar-start and NY-date conventions agree)",
	profiles = { O14 = summarise(profiles.O14), H14 = summarise(profiles.H14) },
	profileCoverage = { O14 = { "O14", "R50" }, H14 = { "H14" } },
	crossChecks = crossChecks,
	mismatches = mismatches,
	ok = #mismatches == 0,
	elapsedSeconds = math.floor((os.clock() - started) * 1000) / 1000,
}
print(encode(report, ""))
if #mismatches > 0 then
	error(string.format("audit: %d mismatch(es); first: %s", #mismatches, mismatches[1]), 0)
end
