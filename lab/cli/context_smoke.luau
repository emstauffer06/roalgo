-- R50 context smoke run on the real cached sources (CLI only; not packaged into Studio).
--
-- Usage, from the project root:
--   luau.exe --codegen -O2 lab/cli/context_smoke.luau            builds R50 rows for the first 3,000 pairs
--   luau.exe --codegen -O2 lab/cli/context_smoke.luau -a 500     ... for the first 500 pairs
--   luau.exe --codegen -O2 lab/cli/context_smoke.luau -a structure
--   luau.exe --codegen -O2 lab/cli/context_smoke.luau -a full        audit: build every pair's R50 row
--
-- Row mode prints coverage/mask/age summary statistics and observed-value counts only: no targets, no returns
-- over the forecast horizon, no performance. The first 3,000 original-hourly pairs are all training-period
-- inputs (they end in 2022).
-- Full mode builds the R50 row of every original-hourly pair (all splits) and prints only the number of rows
-- built and the time taken: it proves the builder's audit checks (pair bar == combined native hourly row,
-- calendar metadata, finite 50-value rows) hold over the whole stream. It prints no feature statistics, so
-- nothing about validation or final-period inputs is summarised.
-- Structure mode counts expected five-minute children per original native hourly bar using timestamps only
-- (no prices), for comparison with SUPPLEMENT.md's independent Node audit
-- (SPY 18,217 complete / 1,745 partial / 0 empty; QQQ 18,969 / 918 / 0).
local Sources = require("../generated/Sources")
local Calendar = require("../src/Data/Calendar")
local Dataset = require("../src/Data/Dataset")
local Features = require("../src/Data/Features")
local ContextCursor = require("../src/Data/ContextCursor")
local SupplementalFeatures = require("../src/Data/SupplementalFeatures")

local arg = ...
local mode = if arg == "structure" then "structure" elseif arg == "full" then "full" else "rows"
local limit = if mode == "rows" then (tonumber(arg) or 3000) else nil

local clock0 = os.clock()
local cal = Calendar.default()
local function load(group: string, symbol: string): { any }
	return Sources.get(group, symbol).load()
end
local sources = {
	fiveMinute = { SPY = load("five-minute", "SPY"), QQQ = load("five-minute", "QQQ") },
	hourly = { SPY = load("hourly-combined", "SPY"), QQQ = load("hourly-combined", "QQQ") },
	daily = { SPY = load("daily-context", "SPY"), QQQ = load("daily-context", "QQQ") },
	context = { IWM = load("hourly-context", "IWM"), TLT = load("hourly-context", "TLT") },
}
local original = { SPY = load("hourly-original", "SPY"), QQQ = load("hourly-original", "QQQ") }
print(string.format("loaded sources in %.1f s", os.clock() - clock0))

local function pct(n: number, d: number): string
	return string.format("%d/%d (%.2f%%)", n, d, if d > 0 then 100 * n / d else 0)
end

if mode == "structure" then
	local cursor = ContextCursor.new(sources, cal)
	for _, sym in { "SPY", "QQQ" } do
		-- Each symbol's own original bars, in time order; a fresh cursor per symbol keeps advance monotone.
		local c = if sym == "SPY" then cursor else ContextCursor.new(sources, cal)
		local complete, partial, empty = 0, 0, 0
		for _, bar in original[sym] do
			local t = bar[1]
			local ctx = c:advance(t + 3600)
			local n = 0
			for j = 0, 11 do
				if ctx:fiveMinuteAt(sym, t + 300 * j) ~= nil then
					n += 1
				end
			end
			if n == 12 then
				complete += 1
			elseif n == 0 then
				empty += 1
			else
				partial += 1
			end
		end
		print(string.format("%s original hourly bars %d: complete %d, partial %d, empty %d", sym, #original[sym], complete, partial, empty))
	end
	print(string.format("done in %.1f s", os.clock() - clock0))
	return
end

local ds = Dataset.new(original.SPY, original.QQQ, cal)

if mode == "full" then
	local builder = SupplementalFeatures.new(sources, cal)
	local clockFull = os.clock()
	local built = 0
	for k = 1, ds:count() do
		local pair = ds:get(k) :: any
		local row = builder:row(pair, Features.compute(pair, ds:get(k - 1)))
		if #row.values ~= 50 or #row.observed ~= 50 then
			error("context_smoke: row " .. k .. " is not 50-dimensional")
		end
		built += 1
	end
	print(string.format("full audit: built %d of %d R50 rows without an audit error in %.1f s", built, ds:count(), os.clock() - clockFull))
	return
end

local n = math.min(limit :: number, ds:count())
local clock1 = os.clock()
local builder = SupplementalFeatures.new(sources, cal)
print(string.format("cursor built and validated in %.1f s", os.clock() - clock1))

local names = SupplementalFeatures.contextNames()
local observedCount = table.create(50, 0)
local coverageHist = { SPY = table.create(13, 0), QQQ = table.create(13, 0) } -- index children+1
local dailyAgeHist = { SPY = {}, QQQ = {} } -- key: age value * 7 (1..7), plus "stale/missing"
local ctxAgeHist = { IWM = {}, TLT = {} }
local maskSum = {}
for _, off in { 14, 27 } do
	for _, p in { 5, 8, 11, 12 } do
		maskSum[off + p] = 0
	end
end
maskSum[44], maskSum[49] = 0, 0
local segmentStarts, segmentStartRelVol = 0, 0

local clock2 = os.clock()
for k = 1, n do
	local pair = ds:get(k) :: any
	local prev = ds:get(k - 1)
	local row = builder:row(pair, Features.compute(pair, prev))
	if #row.values ~= 50 or #row.observed ~= 50 then
		error("context_smoke: row " .. k .. " is not 50-dimensional")
	end
	for i = 1, 50 do
		if row.observed[i] then
			observedCount[i] += 1
		end
	end
	for i in maskSum do
		maskSum[i] += row.values[i]
	end
	for sym, off in { SPY = 14, QQQ = 27 } do
		local children = math.floor(row.values[off + 6] * 12 + 0.5)
		coverageHist[sym][children + 1] += 1
		local key = if row.values[off + 11] == 1 then tostring(math.floor(row.values[off + 13] * 7 + 0.5)) else "stale/missing"
		dailyAgeHist[sym][key] = (dailyAgeHist[sym][key] or 0) + 1
	end
	for sym, off in { IWM = 40, TLT = 45 } do
		local key = if row.values[off + 4] == 1 then string.format("%gs", row.values[off + 5] * 7200) else "unusable"
		ctxAgeHist[sym][key] = (ctxAgeHist[sym][key] or 0) + 1
	end
	if pair.segmentOffset == 1 then
		segmentStarts += 1
		if row.values[14 + 8] == 1 and row.values[27 + 8] == 1 then
			segmentStartRelVol += 1
		end
	end
end
local elapsed = os.clock() - clock2

local first, last = ds:get(1) :: any, ds:get(n) :: any
print(string.format("R50 rows: %d pairs, %s .. %s, %.2f s (%.0f rows/s)", n, first.dateNY, last.dateNY, elapsed, n / elapsed))
for _, sym in { "SPY", "QQQ" } do
	local parts = {}
	for c = 0, 12 do
		if coverageHist[sym][c + 1] > 0 then
			table.insert(parts, string.format("%d/12:%d", c, coverageHist[sym][c + 1]))
		end
	end
	print(sym .. " five-minute coverage: " .. table.concat(parts, " "))
	local ages = {}
	for key, count in dailyAgeHist[sym] do
		table.insert(ages, { key, count })
	end
	table.sort(ages, function(a, b)
		return a[1] < b[1]
	end)
	local ageParts = {}
	for _, kv in ages do
		table.insert(ageParts, kv[1] .. ":" .. kv[2])
	end
	print(sym .. " daily age (calendar dates): " .. table.concat(ageParts, " "))
end
for _, sym in { "IWM", "TLT" } do
	local ages = {}
	for key, count in ctxAgeHist[sym] do
		table.insert(ages, key .. ":" .. count)
	end
	table.sort(ages)
	print(sym .. " context age: " .. table.concat(ages, " "))
end
print("mask rates (mean over rows):")
for _, i in { 19, 22, 25, 26, 32, 35, 38, 39, 44, 49 } do
	print(string.format("  %-30s %s", names[i - 14], pct(math.floor(maskSum[i] + 0.5), n)))
end
print("observed counts for continuous columns:")
local cont = SupplementalFeatures.contextContinuous()
for i = 15, 50 do
	if cont[i - 14] then
		print(string.format("  %-30s %s", names[i - 14], pct(observedCount[i], n)))
	end
end
print(string.format("segment starts %d; both relative-volume masks = 1 at %d of them", segmentStarts, segmentStartRelVol))
print(string.format("done in %.1f s", os.clock() - clock0))
