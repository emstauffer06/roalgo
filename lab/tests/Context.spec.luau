-- Context.spec: R50 causal context features (ContextCursor + SupplementalFeatures).
-- Normative source: plan Section 3 "Rich input contract for R50" / "Rich scaling, masks, and feature identity",
-- Section 7 "CausalContext", and the Task 2 context bullets. Synthetic fixtures only.
local Test = require("./Test")
local Types = require("../src/Types")
local ContextCursor = require("../src/Data/ContextCursor")
local SupplementalFeatures = require("../src/Data/SupplementalFeatures")
local CalFixture = require("../fixtures/context_calendar")
local B = require("../fixtures/context_bars")
local Scenario = require("../fixtures/context_scenario")

local cal = CalFixture.new()
local ny = CalFixture.ny
local ln = math.log
local suite = Test.suite("Context")

-- 1-based offsets of each block inside the 50-value R50 row.
local SPY0, QQQ0, IWM0, TLT0 = 14, 27, 40, 45

local function cursorAt(sources: any, T: number): any
	local cursor = ContextCursor.new(sources, cal)
	return cursor:advance(T), cursor
end

-- Per-symbol 13-value block for a bar starting at t, evaluated at decision t + 3600. The other symbol's slot
-- in the pair holds a decoy bar with a very different volume, so reading the wrong symbol's current bar shows.
local function block(sources: any, symbol: string, t: number, bar: { number }): ({ number }, { boolean })
	local ctx = cursorAt(sources, t + 3600)
	local decoy = B.flat(t, 1, 987654321)
	local spy, qqq = if symbol == "SPY" then bar else decoy, if symbol == "QQQ" then bar else decoy
	return SupplementalFeatures.symbolBlock(ctx, symbol, B.pair(cal, 1, t, spy, qqq))
end

local function popStd(xs: { number }): number
	local m = 0
	for _, x in xs do
		m += x
	end
	m /= #xs
	local s = 0
	for _, x in xs do
		s += (x - m) ^ 2
	end
	return math.sqrt(s / #xs)
end

local function mean(xs: { number }): number
	local m = 0
	for _, x in xs do
		m += x
	end
	return m / #xs
end

local function rowsDiffer(a: { number }, b: { number }): boolean
	for i = 1, #a do
		if a[i] ~= b[i] then
			return true
		end
	end
	return false
end

-- Asserts an unavailable continuous/bounded value: 0 and observed=false.
local function unavailable(v: { number }, o: { boolean }, i: number, what: string)
	Test.eq(v[i], 0, what .. " value")
	Test.eq(o[i], false, what .. " observed")
end

-- Asserts an always-observed mask/coverage/age value.
local function always(v: { number }, o: { boolean }, i: number, expected: number, what: string)
	Test.near(v[i], expected, 1e-15, what .. " value")
	Test.eq(o[i], true, what .. " observed")
end

------------------------------------------------------------------------------------------------------------
-- Fixture calendar sanity (the fake Calendar must reproduce real New York facts).
------------------------------------------------------------------------------------------------------------

Test.case(suite, "fixture calendar reproduces 09:00 New York across the March 2024 change", function()
	local a = cal:localTime(1709906400) -- 2024-03-08T14:00:00Z
	local b = cal:localTime(1710162000) -- 2024-03-11T13:00:00Z
	Test.eq(a.hour, 9, "EST 09:00")
	Test.eq(b.hour, 9, "EDT 09:00")
	Test.eq(a.dateKey, 20240308)
	Test.eq(b.dateKey, 20240311)
	Test.eq(cal:nextMidnightAfter(20240309), 1710046800, "2024-03-10T05:00Z")
	Test.eq(cal:nextMidnightAfter(20240310), 1710129600, "2024-03-11T04:00Z (23-hour day)")
	Test.eq(cal:nextMidnightAfter(20241102), 1730606400, "2024-11-03T04:00Z")
	Test.eq(cal:nextMidnightAfter(20241103), 1730696400, "2024-11-04T05:00Z (25-hour day)")
end)

------------------------------------------------------------------------------------------------------------
-- ContextCursor: audit validation
------------------------------------------------------------------------------------------------------------

Test.case(suite, "cursor rejects missing groups and invalid rows as audit errors", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local function with(mutate: (any) -> ()): () -> ()
		return function()
			local s = B.emptySources()
			mutate(s)
			ContextCursor.new(s, cal)
		end
	end
	Test.throws(with(function(s) s.context.TLT = nil end), "context.TLT", "missing group")
	Test.throws(with(function(s) s.fiveMinute.SPY = { { t0, 1, 1, 1, 1, 1, 1 } } end), "8 fields", "short row")
	Test.throws(with(function(s) s.fiveMinute.SPY = { { t0, 1, 1, 1, 0 / 0, 1, 1, 1 } } end), "non-finite", "NaN")
	Test.throws(with(function(s) s.hourly.QQQ = { { t0, 1, math.huge, 1, 1, 1, 1, 1 } } end), "non-finite", "Inf")
	Test.throws(with(function(s) s.context.IWM = { { t0, 1, 1, 1, 0, 1, 1, 1 } } end), "nonpositive price", "zero close")
	Test.throws(with(function(s) s.context.IWM = { { t0, 1, 1, 1, 1, 1, 1, -1 } } end), "nonpositive price", "negative vwap")
	Test.throws(with(function(s) s.hourly.SPY = { { t0, 1, 1, 1, 1, -5, 1, 1 } } end), "negative volume", "volume")
	Test.throws(with(function(s) s.hourly.SPY = { { t0, 1, 1, 1, 1, 5, -1, 1 } } end), "negative trade count", "trades")
	Test.throws(with(function(s) s.hourly.SPY = { { t0, 1, 1, 2, 1, 5, 1, 1 } } end), "high below low", "high<low")
	Test.throws(with(function(s) s.hourly.SPY = { { t0, 1, 2, 1, 3, 5, 1, 1 } } end), "outside", "close above high")
	Test.throws(with(function(s) s.fiveMinute.QQQ = { B.flat(t0 + 0.5, 100) } end), "integer", "fractional t")
	Test.throws(with(function(s) s.fiveMinute.QQQ = { B.flat(t0 + 60, 100) } end), "not aligned", "five-minute grid")
	Test.throws(with(function(s) s.context.TLT = { B.flat(t0 + 300, 100) } end), "not aligned", "hourly grid")
	Test.throws(function() ContextCursor.new(B.emptySources(), {} :: any) end, "calendar", "calendar contract")
end)

Test.case(suite, "duplicate or out-of-order context rows raise errors, not missingness", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local function try(group: string, symbol: string, rows: { any }): () -> ()
		return function()
			local s = B.emptySources()
			s[group][symbol] = rows
			ContextCursor.new(s, cal)
		end
	end
	Test.throws(try("context", "IWM", { B.flat(t0, 100), B.flat(t0, 100) }), "not strictly increasing", "IWM duplicate")
	Test.throws(try("context", "TLT", { B.flat(t0, 100), B.flat(t0 - 3600, 100) }), "not strictly increasing", "TLT order")
	Test.throws(try("fiveMinute", "SPY", { B.flat(t0 + 300, 1), B.flat(t0 + 300, 1) }), "not strictly increasing", "5m dup")
	Test.throws(try("hourly", "QQQ", { B.flat(t0, 1), B.flat(t0 - 3600, 1) }), "not strictly increasing", "hourly order")
	local d1 = ny(2024, 1, 3, 0, 0)
	Test.throws(try("daily", "SPY", { B.flat(d1, 1), B.flat(d1, 1) }), "not strictly increasing", "daily duplicate")
	Test.throws(try("daily", "QQQ", { B.flat(d1 + 3600, 1) }), "New York midnight", "daily start not at NY midnight")
	-- valid rows pass
	local s = B.emptySources()
	s.daily.SPY = { B.flat(d1, 1), B.flat(ny(2024, 1, 4, 0, 0), 1) }
	s.context.IWM = { B.flat(t0, 100), B.flat(t0 + 3600, 100) }
	ContextCursor.new(s, cal)
end)

------------------------------------------------------------------------------------------------------------
-- ContextCursor: causality and monotonicity
------------------------------------------------------------------------------------------------------------

Test.case(suite, "advance is monotone and a stale context cannot be used", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	s.fiveMinute.SPY = { B.flat(t0, 100) }
	local cursor = ContextCursor.new(s, cal)
	local ctx1 = cursor:advance(t0 + 3600)
	Test.truthy(ctx1:fiveMinuteAt("SPY", t0), "available row")
	cursor:advance(t0 + 3600) -- equal decision time is allowed
	Test.throws(function() cursor:advance(t0 + 3599) end, "backwards", "decreasing decision time")
	Test.throws(function() cursor:advance(0 / 0) end, "finite", "NaN decision time")
	Test.throws(function() ctx1:fiveMinuteAt("SPY", t0) end, "stale", "context from an earlier advance")
	Test.throws(function() cursor:advance(t0 + 7200):fiveMinuteAt("XYZ", t0) end, "symbol", "unknown symbol")
end)

Test.case(suite, "context exposes only rows whose availability time is <= the decision time", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	s.fiveMinute.SPY = { B.flat(t0 + 3300, 100), B.flat(t0 + 3600, 101) }
	s.hourly.SPY = { B.flat(t0 - 3600, 99), B.flat(t0, 100) }
	s.context.IWM = { B.flat(t0 - 3600, 50), B.flat(t0, 51) }
	local before = cursorAt(s, t0 + 3599)
	Test.eq(before:fiveMinuteAt("SPY", t0 + 3300), nil, "5m bar ending after decision")
	Test.eq(before:hourlyAt("SPY", t0), nil, "hourly bar ending after decision")
	Test.eq(before:contextAt("IWM", t0), nil, "context bar ending after decision")
	Test.eq(before:contextLatest("IWM")[1], t0 - 3600, "latest completed context bar")
	local at = cursorAt(s, t0 + 3600)
	Test.eq(at:fiveMinuteAt("SPY", t0 + 3300)[5], 100, "5m bar ending exactly at decision")
	Test.eq(at:fiveMinuteAt("SPY", t0 + 3600), nil, "next hour's first child")
	Test.eq(at:hourlyAt("SPY", t0)[5], 100, "hourly bar ending at decision")
	Test.eq(at:contextLatest("IWM")[1], t0, "latest context")
	-- the context object carries no data arrays, only its decision time and accessor functions
	for k, v in at do
		Test.truthy(k == "decisionTime" or type(v) == "function", "unexpected context field " .. tostring(k))
	end
	Test.eq(at.decisionTime, t0 + 3600)
	local row = at:hourlyAt("SPY", t0)
	Test.truthy(table.isfrozen(row), "returned bars are frozen copies")
	Test.truthy(table.isfrozen(at), "context is frozen")
end)

Test.case(suite, "cursor copies sources: caller mutation after construction changes nothing", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	local closes, opens, vols = {}, {}, {}
	for j = 1, 12 do
		opens[j], closes[j], vols[j] = 100 + j, 100.5 + j, 10 + j
	end
	s.fiveMinute.SPY = B.children(t0, opens, closes, vols)
	local reference = { block(B.deepCopy(s), "SPY", t0, B.flat(t0, 100, 1000)) }
	local cursor = ContextCursor.new(s, cal)
	s.fiveMinute.SPY[12][5] = 999
	table.remove(s.fiveMinute.SPY, 3)
	local v = SupplementalFeatures.symbolBlock(cursor:advance(t0 + 3600), "SPY", B.pair(cal, 1, t0, B.flat(t0, 100, 1000), B.flat(t0, 100, 1000)))
	Test.deepEq(v, reference[1], "values unchanged by caller mutation")
end)

------------------------------------------------------------------------------------------------------------
-- Daily availability: next New York midnight, DST-aware, never +86400
------------------------------------------------------------------------------------------------------------

Test.case(suite, "daily bar becomes available at the next NY midnight across the March 2024 DST change", function()
	local s = B.emptySources()
	local start = ny(2024, 3, 10, 0, 0) -- 2024-03-10T05:00Z, a 23-hour New York day
	Test.eq(start, 1710046800)
	s.daily.SPY = { B.flat(start, 100) }
	local avail = 1710129600 -- 2024-03-11T04:00Z = 00:00 EDT
	Test.eq(#cursorAt(s, avail - 1):dailyHistory("SPY", 20240312, 5), 0, "one second before midnight")
	Test.eq(#cursorAt(s, avail):dailyHistory("SPY", 20240312, 5), 1, "at midnight")
	Test.truthy(start + 86400 > avail, "a fixed +86400 would be one hour late here")
	local entry = cursorAt(s, avail):dailyHistory("SPY", 20240312, 5)[1]
	Test.eq(entry.dateKey, 20240310)
	Test.eq(entry.availableAt, avail)
end)

Test.case(suite, "daily bar becomes available at the next NY midnight across the November 2024 DST change", function()
	local s = B.emptySources()
	local start = ny(2024, 11, 3, 0, 0) -- 2024-11-03T04:00Z, a 25-hour New York day
	Test.eq(start, 1730606400)
	s.daily.QQQ = { B.flat(start, 100) }
	local avail = 1730696400 -- 2024-11-04T05:00Z = 00:00 EST
	Test.eq(#cursorAt(s, start + 86400):dailyHistory("QQQ", 20241105, 5), 0, "a fixed +86400 would leak it an hour early")
	Test.eq(#cursorAt(s, avail - 1):dailyHistory("QQQ", 20241105, 5), 0, "one second before midnight")
	Test.eq(#cursorAt(s, avail):dailyHistory("QQQ", 20241105, 5), 1, "at midnight")
end)

------------------------------------------------------------------------------------------------------------
-- Five-minute children (positions 1-6)
------------------------------------------------------------------------------------------------------------

local function completeHour(t0: number): ({ number }, { number }, { number })
	local closes = { 101, 102, 101.5, 103, 103, 102, 104, 105, 104.5, 106, 105, 107 }
	local opens = { 100 }
	for j = 2, 12 do
		opens[j] = closes[j - 1] + 0.25 -- opens differ from previous closes
	end
	local vols = {}
	for j = 1, 12 do
		vols[j] = 10 * j
	end
	return opens, closes, vols
end

Test.case(suite, "complete hour: exact twelve starts, x0=O0 then closes, all four values observed", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local opens, closes, vols = completeHour(t0)
	local s = B.emptySources()
	s.fiveMinute.SPY = B.children(t0, opens, closes, vols)
	local v, o = block(s, "SPY", t0, B.flat(t0, 100, 1000))
	local x = { 100 }
	for j = 1, 12 do
		x[j + 1] = closes[j]
	end
	local sumSq, sumAbs = 0, 0
	for k = 1, 12 do
		local r = ln(x[k + 1] / x[k])
		sumSq += r * r
		sumAbs += math.abs(r)
	end
	Test.near(v[1], math.sqrt(sumSq), 1e-12, "intrahour realized variation")
	Test.near(v[2], ln(107 / 104.5), 1e-12, "final fifteen-minute return ln(C11/C8)")
	Test.near(v[3], math.abs(ln(107 / 100)) / sumAbs, 1e-12, "path efficiency")
	Test.near(v[4], 330 / 780, 1e-12, "final fifteen-minute volume share")
	for i = 1, 4 do
		Test.eq(o[i], true, "position " .. i .. " observed")
	end
	always(v, o, 5, 1, "complete mask")
	always(v, o, 6, 1, "coverage")
	local alt = 0
	for j = 1, 12 do
		alt += ln(closes[j] / opens[j]) ^ 2
	end
	Test.truthy(math.abs(math.sqrt(alt) - v[1]) > 1e-4, "fixture distinguishes the x0=O0 convention from per-child open/close")
end)

Test.case(suite, "falling complete hour: path efficiency is abs(net)/sum abs, positive and within [0, 1]", function()
	local t0 = ny(2024, 1, 3, 11, 0)
	-- Net fall from O0 = 100 to C11 = 96 with an up-move inside, so sum(r) < 0 and |sum(r)| < sum|r|.
	local closes = { 99.5, 99, 99.6, 98.8, 98.5, 98.9, 98.2, 97.6, 97.9, 97.1, 96.4, 96 }
	local opens = { 100 }
	for j = 2, 12 do
		opens[j] = closes[j - 1] - 0.1
	end
	local vols = {}
	for j = 1, 12 do
		vols[j] = 5 + j
	end
	local s = B.emptySources()
	s.fiveMinute.QQQ = B.children(t0, opens, closes, vols)
	local v, o = block(s, "QQQ", t0, B.flat(t0, 100, 1000))
	local x = { 100 }
	for j = 1, 12 do
		x[j + 1] = closes[j]
	end
	local sumR, sumAbs = 0, 0
	for k = 1, 12 do
		local r = ln(x[k + 1] / x[k])
		sumR += r
		sumAbs += math.abs(r)
	end
	Test.truthy(sumR < 0, "fixture has a net fall")
	Test.near(v[3], math.abs(ln(96 / 100)) / sumAbs, 1e-12, "path efficiency of a falling hour")
	Test.truthy(v[3] > 0 and v[3] < 1, "path efficiency within (0, 1) for a mixed falling path")
	Test.eq(o[3], true)
	Test.near(v[2], ln(96 / 97.9), 1e-12, "final fifteen-minute return ln(C11/C8) of a falling hour")
end)

Test.case(suite, "partial hour (7/12): coverage kept, positions 1-4 unavailable together", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local opens, closes, vols = completeHour(t0)
	local s = B.emptySources()
	s.fiveMinute.QQQ = B.children(t0, opens, closes, vols, { [0] = true, [3] = true, [5] = true, [8] = true, [11] = true })
	Test.eq(#s.fiveMinute.QQQ, 7)
	local v, o = block(s, "QQQ", t0, B.flat(t0, 100, 1000))
	for i = 1, 4 do
		unavailable(v, o, i, "position " .. i)
	end
	always(v, o, 5, 0, "complete mask")
	always(v, o, 6, 7 / 12, "coverage")
end)

Test.case(suite, "empty hour: coverage 0, mask 0, positions 1-4 unavailable", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local v, o = block(B.emptySources(), "SPY", t0, B.flat(t0, 100, 1000))
	for i = 1, 4 do
		unavailable(v, o, i, "position " .. i)
	end
	always(v, o, 5, 0, "complete mask")
	always(v, o, 6, 0, "coverage")
end)

Test.case(suite, "zero-volume flat hour: zero share and zero efficiency are observed values", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local p, z = {}, {}
	for j = 1, 12 do
		p[j], z[j] = 100, 0
	end
	local s = B.emptySources()
	s.fiveMinute.SPY = B.children(t0, p, p, z)
	local v, o = block(s, "SPY", t0, B.flat(t0, 100, 0))
	for i = 1, 4 do
		Test.eq(v[i], 0, "position " .. i .. " value")
		Test.eq(o[i], true, "position " .. i .. " observed (real zero)")
	end
	always(v, o, 5, 1, "complete mask")
	always(v, o, 6, 1, "coverage")
end)

Test.case(suite, "nearby rows outside the hour never substitute for a missing expected start", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local opens, closes, vols = completeHour(t0)
	local s = B.emptySources()
	local rows = B.children(t0, opens, closes, vols, { [0] = true })
	table.insert(rows, B.flat(t0 - 300, 100, 50)) -- previous hour's last child
	table.insert(rows, B.flat(t0 + 3600, 100, 50)) -- next hour's first child
	s.fiveMinute.SPY = B.sortByT(rows)
	local v, o = block(s, "SPY", t0, B.flat(t0, 100, 1000))
	always(v, o, 6, 11 / 12, "coverage counts only expected starts")
	always(v, o, 5, 0, "complete mask")
	for i = 1, 4 do
		unavailable(v, o, i, "position " .. i)
	end
end)

Test.case(suite, "a five-minute bar ending after the decision cannot change current features", function()
	local t0 = ny(2024, 1, 3, 10, 0)
	local opens, closes, vols = completeHour(t0)
	local s = B.emptySources()
	s.fiveMinute.SPY = B.children(t0, opens, closes, vols)
	table.insert(s.fiveMinute.SPY, B.oc(t0 + 3600, 107, 108, 40)) -- ends at t0+3900 > decision
	local bar = B.flat(t0, 100, 1000)
	local base = { block(s, "SPY", t0, bar) }
	local future = B.deepCopy(s)
	future.fiveMinute.SPY[13] = B.oc(t0 + 3600, 300, 900, 1e9)
	Test.deepEq({ block(future, "SPY", t0, bar) }, base, "future child mutation")
	-- control: the last expected child (ending exactly at the decision) does matter
	local control = B.deepCopy(s)
	control.fiveMinute.SPY[12] = B.oc(t0 + 3300, 105, 110, 120)
	local cv = block(control, "SPY", t0, bar)
	Test.truthy(cv[2] ~= base[1][2], "control: mutating child 11 changes ln(C11/C8)")
end)

------------------------------------------------------------------------------------------------------------
-- Relative same-hour volume (positions 7-8)
------------------------------------------------------------------------------------------------------------

Test.case(suite, "relative volume: up to twenty previous dates at the same NY hour, from unpaired own-symbol rows", function()
	local days = Scenario.weekdays(2024, 1, 2, 2024, 2, 6)
	Test.eq(#days, 26)
	local s = B.emptySources()
	for i = 1, 25 do
		local D = days[i]
		table.insert(s.hourly.SPY, B.flat(ny(D.y, D.m, D.d, 10, 0), 100, 1000 + 37 * i))
		table.insert(s.hourly.SPY, B.flat(ny(D.y, D.m, D.d, 11, 0), 100, 1e6)) -- other hour, ignored
	end
	local D = days[26]
	local t = ny(D.y, D.m, D.d, 10, 0)
	local cur = B.flat(t, 100, 5000)
	table.insert(s.hourly.SPY, cur)
	-- QQQ has no rows at all, so none of these history rows belongs to a paired observation.
	local v, o = block(s, "SPY", t, cur)
	local hist = {}
	for i = 6, 25 do
		table.insert(hist, ln(1 + 1000 + 37 * i))
	end
	Test.near(v[7], ln(5001) - mean(hist), 1e-12, "relative volume over the last twenty dates")
	Test.eq(o[7], true)
	always(v, o, 8, 1, "relative-volume mask")
	local ctx = cursorAt(s, t + 3600)
	local h = ctx:sameHourHistory("SPY", 10, D.y * 10000 + D.m * 100 + D.d)
	Test.eq(#h, 20, "at most twenty")
	Test.near(h[1], ln(1 + 1000 + 37 * 6), 1e-15, "oldest retained")
	-- Without a same-hour entry for the current date the buffer holds 21 earlier dates; still only twenty used.
	local noCurrent = B.deepCopy(s)
	table.remove(noCurrent.hourly.SPY) -- drop the current 10:00 bar
	local h2 = cursorAt(noCurrent, t + 3600):sameHourHistory("SPY", 10, D.y * 10000 + D.m * 100 + D.d)
	Test.eq(#h2, 20, "twenty without a current-date entry")
	Test.near(h2[1], ln(1 + 1000 + 37 * 6), 1e-15, "oldest retained without a current-date entry")
	local v2 = block(noCurrent, "SPY", t, cur)
	Test.near(v2[7], v[7], 1e-15, "same value without the current-date entry")
end)

Test.case(suite, "relative volume needs at least five prior observations", function()
	local days = Scenario.weekdays(2024, 1, 2, 2024, 1, 9)
	local function run(prior: number): ({ number }, { boolean })
		local s = B.emptySources()
		for i = 1, prior do
			local D = days[i]
			table.insert(s.hourly.QQQ, B.flat(ny(D.y, D.m, D.d, 10, 0), 100, 100 * i))
		end
		local D = days[prior + 1]
		local t = ny(D.y, D.m, D.d, 10, 0)
		local cur = B.flat(t, 100, 777)
		table.insert(s.hourly.QQQ, cur)
		return block(s, "QQQ", t, cur)
	end
	local v4, o4 = run(4)
	unavailable(v4, o4, 7, "four prior observations")
	always(v4, o4, 8, 0, "mask with four")
	local v5, o5 = run(5)
	Test.near(v5[7], ln(778) - mean({ ln(101), ln(201), ln(301), ln(401), ln(501) }), 1e-12, "five prior")
	always(v5, o5, 8, 1, "mask with five")
end)

Test.case(suite, "same-hour history admits an hourly row only once it has completed (start + 3600 <= decision)", function()
	local d1 = ny(2024, 1, 3, 10, 0)
	local d2 = ny(2024, 1, 4, 10, 0)
	local s = B.emptySources()
	s.hourly.SPY = { B.flat(d1, 100, 500), B.flat(d2, 100, 900) }
	-- Query with the following date key so that neither row is excluded as "current date".
	local before = cursorAt(s, d2 + 3599):sameHourHistory("SPY", 10, 20240105)
	Test.eq(#before, 1, "the 2024-01-04 10:00 bar is still in progress one second before it completes")
	Test.near(before[1], ln(501), 1e-15, "only the completed 2024-01-03 bar")
	local at = cursorAt(s, d2 + 3600):sameHourHistory("SPY", 10, 20240105)
	Test.eq(#at, 2, "the 2024-01-04 10:00 bar is admitted exactly at its completion")
	Test.near(at[2], ln(901), 1e-15, "newest last")
end)

Test.case(suite, "current date is excluded from its own relative-volume history (fall-back duplicate hour)", function()
	local s = B.emptySources()
	local prior = Scenario.weekdays(2024, 10, 28, 2024, 11, 1)
	Test.eq(#prior, 5)
	for i, D in prior do
		table.insert(s.hourly.SPY, B.flat(ny(D.y, D.m, D.d, 1, 0), 100, 100 * i))
	end
	local first = ny(2024, 11, 3, 1, 0, -14400) -- 01:00 EDT (05:00Z)
	local second = ny(2024, 11, 3, 1, 0, -18000) -- 01:00 EST (06:00Z), same NY date and hour
	Test.eq(second - first, 3600)
	table.insert(s.hourly.SPY, B.flat(first, 100, 99999))
	local cur = B.flat(second, 100, 700)
	table.insert(s.hourly.SPY, cur)
	local nextDay = ny(2024, 11, 4, 1, 0)
	local nextBar = B.flat(nextDay, 100, 800)
	table.insert(s.hourly.SPY, nextBar)
	local cursor = ContextCursor.new(s, cal)
	local pair = B.pair(cal, 1, second, cur, cur)
	Test.eq(pair.hourNY, 1)
	Test.eq(pair.dateKey, 20241103)
	local priorLogs = { ln(101), ln(201), ln(301), ln(401), ln(501) }
	local v, o = SupplementalFeatures.symbolBlock(cursor:advance(second + 3600), "SPY", pair)
	Test.near(v[7], ln(701) - mean(priorLogs), 1e-12, "same-date 01:00 EDT bar excluded")
	always(v, o, 8, 1, "mask")
	-- Decision recorded: a duplicated NY date-hour contributes one observation, its later bar.
	local v2 = SupplementalFeatures.symbolBlock(cursor:advance(nextDay + 3600), "SPY", B.pair(cal, 2, nextDay, nextBar, nextBar))
	table.insert(priorLogs, ln(701))
	Test.near(v2[7], ln(801) - mean(priorLogs), 1e-12, "next date sees one value for 2024-11-03")
end)

------------------------------------------------------------------------------------------------------------
-- Daily context (positions 9-13)
------------------------------------------------------------------------------------------------------------

local function dailyBars(days: { any }): { { number } }
	local rows = {}
	for k, D in days do
		local c = 100 * math.exp(0.01 * math.sin(k))
		local o = c * (1 - 0.003 * math.cos(k))
		table.insert(rows, B.oc(ny(D.y, D.m, D.d, 0, 0), o, c, 1e6))
	end
	return rows
end

Test.case(suite, "previous-day return and volatility of twenty returns from twenty-one prior daily bars", function()
	local days = Scenario.weekdays(2024, 2, 1, 2024, 3, 5) -- 23 prior weekdays, then today (03-05)
	Test.eq(#days, 24)
	local s = B.emptySources()
	s.daily.SPY = dailyBars(days)
	local t = ny(2024, 3, 5, 10, 0)
	local v, o = block(s, "SPY", t, B.flat(t, 100, 1000))
	local last = s.daily.SPY[23]
	Test.near(v[9], ln(last[5] / last[2]), 1e-15, "previous-day intraday return")
	Test.eq(o[9], true)
	local q = {}
	for k = 4, 23 do -- twenty returns from bars 3..23 (twenty-one bars)
		table.insert(q, ln(s.daily.SPY[k][5] / s.daily.SPY[k - 1][5]))
	end
	Test.eq(#q, 20)
	Test.near(v[10], popStd(q), 1e-12, "population std of twenty close-to-close returns")
	Test.eq(o[10], true)
	always(v, o, 11, 1, "previous-day mask")
	always(v, o, 12, 1, "volatility mask")
	always(v, o, 13, 1 / 7, "daily age (one calendar date)")
end)

Test.case(suite, "twenty prior daily bars: volatility unavailable, previous-day return available", function()
	local days = Scenario.weekdays(2024, 2, 6, 2024, 3, 5)
	Test.eq(#days, 21) -- 20 prior + today
	local s = B.emptySources()
	s.daily.QQQ = dailyBars(days)
	local t = ny(2024, 3, 5, 10, 0)
	local v, o = block(s, "QQQ", t, B.flat(t, 100, 1000))
	Test.eq(o[9], true, "previous-day return observed")
	unavailable(v, o, 10, "volatility")
	always(v, o, 11, 1, "previous-day mask")
	always(v, o, 12, 0, "volatility mask")
end)

Test.case(suite, "daily freshness: seven calendar dates accepted, eight rejected, ages", function()
	local s = B.emptySources()
	s.daily.SPY = dailyBars(Scenario.weekdays(2024, 1, 29, 2024, 3, 6)) -- 28 bars ending Wed 03-06
	local t7 = ny(2024, 3, 13, 10, 0) -- seven calendar dates later
	local v7, o7 = block(s, "SPY", t7, B.flat(t7, 100, 1000))
	always(v7, o7, 11, 1, "seven dates: previous-day mask")
	always(v7, o7, 12, 1, "seven dates: volatility mask")
	always(v7, o7, 13, 1, "seven dates: age min(7,7)/7")
	local t8 = ny(2024, 3, 14, 10, 0) -- eight calendar dates later: stale
	local v8, o8 = block(s, "SPY", t8, B.flat(t8, 100, 1000))
	unavailable(v8, o8, 9, "stale previous-day return")
	unavailable(v8, o8, 10, "stale volatility")
	always(v8, o8, 11, 0, "stale previous-day mask")
	always(v8, o8, 12, 0, "stale volatility mask")
	always(v8, o8, 13, 1, "stale age sentinel")
	local tMon = ny(2024, 3, 11, 10, 0) -- Monday after Wednesday's latest bar... five dates
	local vm, om = block(s, "SPY", tMon, B.flat(tMon, 100, 1000))
	always(vm, om, 13, 5 / 7, "age five dates")
end)

Test.case(suite, "mutating today's daily bar cannot change current features", function()
	local days = Scenario.weekdays(2024, 2, 1, 2024, 3, 5)
	local s = B.emptySources()
	s.daily.SPY = dailyBars(days)
	local t = ny(2024, 3, 5, 15, 0)
	local bar = B.flat(t, 100, 1000)
	local base = { block(s, "SPY", t, bar) }
	local today = B.deepCopy(s)
	today.daily.SPY[24] = B.oc(today.daily.SPY[24][1], 1, 1000, 1e12)
	Test.deepEq({ block(today, "SPY", t, bar) }, base, "today's daily bar")
	local yesterday = B.deepCopy(s)
	yesterday.daily.SPY[23] = B.oc(yesterday.daily.SPY[23][1], 1, 1000, 1e12)
	Test.truthy(block(yesterday, "SPY", t, bar)[9] ~= base[1][9], "control: yesterday's bar matters")
end)

Test.case(suite, "a daily bar of the current bar's own NY date is excluded even when available at a midnight decision", function()
	local days = Scenario.weekdays(2024, 3, 1, 2024, 3, 5)
	local s = B.emptySources()
	s.daily.SPY = dailyBars(days)
	local t = ny(2024, 3, 5, 23, 0) -- 23:00 NY bar; decision is 00:00 on 03-06
	Test.eq(t + 3600, cal:nextMidnightAfter(20240305), "today's daily bar is available exactly at this decision")
	local v, o = block(s, "SPY", t, B.flat(t, 100, 1000))
	local prev = s.daily.SPY[#s.daily.SPY - 1] -- 03-04
	Test.near(v[9], ln(prev[5] / prev[2]), 1e-15, "uses the strictly earlier date")
	always(v, o, 13, 1 / 7, "age from 03-05 to 03-04")
end)

------------------------------------------------------------------------------------------------------------
-- IWM/TLT context (five values each)
------------------------------------------------------------------------------------------------------------

Test.case(suite, "usable IWM context: return, range, log volume, mask and age", function()
	local u = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	-- u opens at 200.9, not at the predecessor's close 200.5, so ln(Cu/C(u-3600)) differs from ln(Cu/Ou).
	s.context.IWM = { B.bar(u - 3600, 200, 201, 199, 200.5, 300), B.bar(u, 200.9, 203, 198, 202, 450) }
	local ctx = cursorAt(s, u + 3600)
	local v, o = SupplementalFeatures.contextBlock(ctx, cal, "IWM")
	Test.near(v[1], ln(202 / 200.5), 1e-15, "ln(Cu/C(u-3600))")
	Test.truthy(math.abs(ln(202 / 200.9) - v[1]) > 1e-3, "fixture distinguishes close-to-close from open-to-close")
	Test.near(v[2], ln(203 / 198), 1e-15, "ln(Hu/Lu)")
	Test.near(v[3], ln(451), 1e-15, "ln(1+Vu)")
	for i = 1, 3 do
		Test.eq(o[i], true)
	end
	always(v, o, 4, 1, "usable mask")
	always(v, o, 5, 0, "age 0")
	local tv, to = SupplementalFeatures.contextBlock(ctx, cal, "TLT")
	for i = 1, 3 do
		unavailable(tv, to, i, "absent TLT position " .. i)
	end
	always(tv, to, 4, 0, "absent TLT mask")
	always(tv, to, 5, 1, "absent TLT age sentinel")
end)

Test.case(suite, "context exactly 7200 s old is accepted; 7201 s is rejected", function()
	local u = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	s.context.TLT = { B.oc(u - 3600, 95, 95.5, 10), B.oc(u, 95.8, 96, 20) } -- u opens away from C(u-3600)
	local v, o = SupplementalFeatures.contextBlock(cursorAt(s, u + 3600 + 7200), cal, "TLT")
	always(v, o, 4, 1, "7200 s mask")
	always(v, o, 5, 1, "7200 s age = min(7200,7200)/7200")
	Test.near(v[1], ln(96 / 95.5), 1e-15, "values present (close-to-close return)")
	local v2, o2 = SupplementalFeatures.contextBlock(cursorAt(s, u + 3600 + 7201), cal, "TLT")
	for i = 1, 3 do
		unavailable(v2, o2, i, "7201 s position " .. i)
	end
	always(v2, o2, 4, 0, "7201 s mask")
	always(v2, o2, 5, 1, "7201 s age sentinel")
	local v3, o3 = SupplementalFeatures.contextBlock(cursorAt(s, u + 3600 + 3600), cal, "TLT")
	always(v3, o3, 5, 0.5, "3600 s age")
end)

Test.case(suite, "a 59-hour-old TLT bar is masked in the builder row", function()
	local s = B.emptySources()
	local fri18, fri19 = ny(2024, 3, 1, 18, 0), ny(2024, 3, 1, 19, 0)
	s.context.TLT = { B.oc(fri18, 95, 95.2, 10), B.oc(fri19, 95.2, 95.4, 10) }
	local t = ny(2024, 3, 4, 6, 0) -- Monday 06:00-07:00 NY
	Test.eq((t + 3600) - (fri19 + 3600), 59 * 3600, "59 hours old")
	s.context.IWM = { B.oc(t - 3600, 200, 201, 5), B.oc(t, 201, 202, 6) }
	local spy, qqq = B.flat(t, 500, 1000), B.flat(t, 430, 900)
	s.hourly.SPY, s.hourly.QQQ = { spy }, { qqq }
	local row = SupplementalFeatures.new(s, cal):row(B.pair(cal, 1, t, spy, qqq), B.base14(1))
	for i = 1, 3 do
		unavailable(row.values, row.observed, TLT0 + i, "TLT position " .. i)
	end
	always(row.values, row.observed, TLT0 + 4, 0, "TLT mask")
	always(row.values, row.observed, TLT0 + 5, 1, "TLT age sentinel")
	always(row.values, row.observed, IWM0 + 4, 1, "IWM fresh and usable")
end)

Test.case(suite, "missing hourly predecessor is masked; no backward search for another pair", function()
	local u = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	s.context.IWM = { B.oc(u - 7200, 200, 201, 5), B.oc(u, 201, 202, 6) } -- u-3600 missing
	local v, o = SupplementalFeatures.contextBlock(cursorAt(s, u + 3600), cal, "IWM")
	for i = 1, 3 do
		unavailable(v, o, i, "position " .. i)
	end
	always(v, o, 4, 0, "mask")
	always(v, o, 5, 1, "age sentinel")
end)

Test.case(suite, "a predecessor on a different NY date is masked", function()
	local u = ny(2024, 1, 4, 0, 0) -- 00:00 NY; predecessor is 23:00 on 2024-01-03
	local s = B.emptySources()
	s.context.IWM = { B.oc(u - 3600, 200, 201, 5), B.oc(u, 201, 202, 6) }
	local v, o = SupplementalFeatures.contextBlock(cursorAt(s, u + 3600), cal, "IWM")
	unavailable(v, o, 1, "return across dates")
	always(v, o, 4, 0, "mask")
	always(v, o, 5, 1, "age sentinel")
end)

------------------------------------------------------------------------------------------------------------
-- Builder (50-value FeatureRow)
------------------------------------------------------------------------------------------------------------

Test.case(suite, "layout: 50 columns, 28 continuous and 22 bounded", function()
	Test.eq(SupplementalFeatures.DIMENSION, 50)
	Test.eq(SupplementalFeatures.PROFILE_ID, "R50")
	local names = SupplementalFeatures.contextNames()
	Test.eq(#names, 36, "supplemental names")
	Test.eq(names[1], "spy_ctx_realized_variation")
	Test.eq(names[14], "qqq_ctx_realized_variation")
	Test.eq(names[27], "iwm_ret_1h")
	Test.eq(names[36], "tlt_age")
	local flags = SupplementalFeatures.contextContinuous()
	Test.eq(#flags, 36)
	local continuous = 12 -- the twelve O14 continuous columns
	for _, f in flags do
		if f then
			continuous += 1
		end
	end
	Test.eq(continuous, 28, "continuous")
	Test.eq(50 - continuous, 22, "bounded")
end)

Test.case(suite, "builder column layout matches FeatureSchema R50 (names and continuous flags of columns 15..50)", function()
	local FeatureSchema = require("../src/Data/FeatureSchema")
	local schema = FeatureSchema.get("R50")
	Test.eq(schema.dimension, SupplementalFeatures.DIMENSION, "dimension")
	local names = SupplementalFeatures.contextNames()
	local flags = SupplementalFeatures.contextContinuous()
	for i = 1, 36 do
		Test.eq(names[i], schema.names[14 + i], "name of column " .. (14 + i))
		Test.eq(flags[i], schema.continuous[14 + i], "continuous flag of column " .. (14 + i))
	end
	Test.eq(schema.offsets.spyContext, SPY0 + 1, "SPY block offset")
	Test.eq(schema.offsets.qqqContext, QQQ0 + 1, "QQQ block offset")
	Test.eq(schema.offsets.iwm, IWM0 + 1, "IWM block offset")
	Test.eq(schema.offsets.tlt, TLT0 + 1, "TLT block offset")
end)

Test.case(suite, "builder emits exactly 50 values and flags in base/SPY/QQQ/IWM/TLT order", function()
	local src, pairs = Scenario.build(cal)
	local p = pairs[40]
	local base = B.base14(40)
	local builder = SupplementalFeatures.new(src, cal)
	local row = builder:row(p, base)
	Test.eq(#row.values, 50, "values")
	Test.eq(#row.observed, 50, "observed")
	Test.eq(row.profileId, "R50")
	Test.eq(row.t, p.t)
	Test.eq(row.decisionTime, p.decisionTime)
	for i = 1, 14 do
		Test.eq(row.values[i], base[i], "base value " .. i)
		Test.eq(row.observed[i], true, "base observed " .. i)
	end
	local ctx = cursorAt(src, p.decisionTime)
	local blocks = {
		{ SPY0, SupplementalFeatures.symbolBlock(ctx, "SPY", p) },
		{ QQQ0, SupplementalFeatures.symbolBlock(ctx, "QQQ", p) },
		{ IWM0, SupplementalFeatures.contextBlock(ctx, cal, "IWM") },
		{ TLT0, SupplementalFeatures.contextBlock(ctx, cal, "TLT") },
	}
	for _, b in blocks do
		local off, vals = b[1], b[2]
		for i, x in vals do
			Test.eq(row.values[off + i], x, "block value at " .. (off + i))
		end
	end
	Test.truthy(table.isfrozen(row.values) and table.isfrozen(row.observed), "row arrays frozen")
end)

Test.case(suite, "masks, coverage and ages stay observed when every supplemental source is missing", function()
	local t = ny(2024, 1, 3, 10, 0)
	local s = B.emptySources()
	local spy, qqq = B.flat(t, 500, 1000), B.flat(t, 430, 900)
	s.hourly.SPY, s.hourly.QQQ = { spy }, { qqq }
	local row = SupplementalFeatures.new(s, cal):row(B.pair(cal, 1, t, spy, qqq), B.base14(2))
	local v, o = row.values, row.observed
	for _, off in { SPY0, QQQ0 } do
		for _, i in { 1, 2, 3, 4, 7, 9, 10 } do
			unavailable(v, o, off + i, "symbol position " .. i)
		end
		always(v, o, off + 5, 0, "complete mask")
		always(v, o, off + 6, 0, "coverage")
		always(v, o, off + 8, 0, "relative-volume mask")
		always(v, o, off + 11, 0, "previous-day mask")
		always(v, o, off + 12, 0, "volatility mask")
		always(v, o, off + 13, 1, "daily age sentinel")
	end
	for _, off in { IWM0, TLT0 } do
		for i = 1, 3 do
			unavailable(v, o, off + i, "context position " .. i)
		end
		always(v, o, off + 4, 0, "context mask")
		always(v, o, off + 5, 1, "context age sentinel")
	end
end)

Test.case(suite, "builder rejects bad base vectors, unordered pairs and pairs that disagree with the hourly source", function()
	local src, pairs = Scenario.build(cal)
	local builder = SupplementalFeatures.new(src, cal)
	Test.throws(function() builder:row(pairs[1], { 1, 2, 3 }) end, "baseValues", "short base")
	local nanBase = B.base14(1)
	nanBase[5] = 0 / 0
	Test.throws(function() builder:row(pairs[1], nanBase) end, "baseValues", "NaN base")
	builder:row(pairs[2], B.base14(2))
	Test.throws(function() builder:row(pairs[2], B.base14(2)) end, "strictly increasing", "repeated pair")
	Test.throws(function() builder:row(pairs[1], B.base14(1)) end, "strictly increasing", "earlier pair")
	local bad = table.clone(pairs[3])
	bad.spy = table.clone(bad.spy)
	bad.spy[5] *= 1.01
	Test.throws(function() builder:row(bad, B.base14(3)) end, "disagrees", "pair bar differs from hourly source")
	local wrongDecision = table.clone(pairs[4])
	wrongDecision.decisionTime += 1
	Test.throws(function() builder:row(wrongDecision, B.base14(4)) end, "decisionTime", "decision time")
	local wrongDate = table.clone(pairs[5])
	wrongDate.dateKey = 20200101
	Test.throws(function() builder:row(wrongDate, B.base14(5)) end, "calendar", "pair date metadata")
end)

Test.case(suite, "rolling buffers survive daily physical resets and initialize from earlier unpaired rows", function()
	local src, pairs, pairStart = Scenario.build(cal)
	local builder = SupplementalFeatures.new(src, cal)
	local segmentStarts = 0
	local checked = { SPY = 0, QQQ = 0 }
	local short = {}
	for k, p in pairs do
		local row = builder:row(p, B.base14(k))
		-- independent recomputation of position 7 from each symbol's own raw hourly source
		for _, spec in { { "SPY", SPY0, p.spy }, { "QQQ", QQQ0, p.qqq } } do
			local sym, off, current = spec[1], spec[2], spec[3]
			local hist: { [number]: number } = {}
			local order = {}
			for _, r in src.hourly[sym] do
				local lt = cal:localTime(r[1])
				if lt.hour == p.hourNY and lt.dateKey < p.dateKey then
					if hist[lt.dateKey] == nil then
						table.insert(order, lt.dateKey)
					end
					hist[lt.dateKey] = ln(1 + r[6])
				end
			end
			local vals = {}
			for i = math.max(1, #order - 19), #order do
				table.insert(vals, hist[order[i]])
			end
			if #vals >= 5 then
				Test.near(row.values[off + 7], ln(1 + current[6]) - mean(vals), 1e-12, sym .. " relative volume pair " .. k)
				Test.eq(row.values[off + 8], 1)
				checked[sym] += 1
			else
				Test.eq(row.values[off + 8], 0)
				Test.eq(row.observed[off + 7], false)
				table.insert(short, sym .. "@" .. p.dateNY .. "T" .. p.hourNY)
			end
		end
		if p.segmentOffset == 1 then
			segmentStarts += 1
			Test.eq(row.values[SPY0 + 8], 1, "relative volume available at a segment start " .. k)
			if p.dateKey >= 20240305 then
				Test.eq(row.values[SPY0 + 12], 1, "daily volatility available at a segment start " .. k)
			end
		end
		if k == 1 then
			Test.truthy(p.t >= pairStart, "pair stream starts after the earlier rows")
		end
	end
	Test.truthy(segmentStarts >= 15, "fixture has many daily resets")
	Test.eq(checked.SPY, #pairs, "every SPY pair had enough earlier same-hour history")
	-- QQQ has no Monday 04:00 bars in the scenario, so on Tuesday 2024-02-27 its 04:00 history holds only
	-- 2024-02-20..23 (four dates): the one QQQ row below the five-observation minimum.
	Test.eq(checked.QQQ, #pairs - 1, "QQQ rows with enough history")
	Test.deepEq(short, { "QQQ@2024-02-27T4" }, "the only short-history row")
end)

Test.case(suite, "resume reconstructs identical buffers and rows from past-only records", function()
	local src, pairs = Scenario.build(cal)
	local fresh = SupplementalFeatures.new(src, cal)
	local freshRows = {}
	for k, p in pairs do
		freshRows[k] = fresh:row(p, B.base14(k))
	end
	local resumePoints = {}
	for k, p in pairs do
		if p.dateKey == 20240307 and p.segmentOffset == 1 then
			table.insert(resumePoints, k) -- a segment boundary
		end
	end
	table.insert(resumePoints, resumePoints[1] + 5) -- and a mid-segment point
	Test.truthy(resumePoints[1] > 50, "resume point is deep into the stream")
	for _, k in resumePoints do
		local replay = SupplementalFeatures.new(src, cal)
		for i = 1, k do
			replay:row(pairs[i], B.base14(i))
		end
		local resumed = SupplementalFeatures.new(src, cal, { resumeAt = pairs[k].decisionTime })
		Test.deepEq(resumed:bufferSnapshot(), replay:bufferSnapshot(), "buffer state at resume point " .. k)
		Test.throws(function() resumed:row(pairs[k - 1], B.base14(k - 1)) end, "resume", "pair before resume point")
		for i = k, #pairs do
			Test.deepEq(resumed:row(pairs[i], B.base14(i)), freshRows[i], "row " .. i .. " after resume at " .. k)
		end
	end
	-- resuming at the previous decision time gives the same rows
	local k = resumePoints[1]
	local early = SupplementalFeatures.new(src, cal, { resumeAt = pairs[k - 1].decisionTime })
	for i = k, k + 20 do
		Test.deepEq(early:row(pairs[i], B.base14(i)), freshRows[i], "early resume row " .. i)
	end
end)

Test.case(suite, "future source mutations cannot change rows through the cut (builder level)", function()
	local src, pairs, pairStart = Scenario.build(cal)
	local k = 120
	local cut = pairs[k].decisionTime
	local mutated = Scenario.mutateAfter(src, cal, cut)
	local pairsB = B.pairsFrom(cal, mutated.hourly.SPY, mutated.hourly.QQQ, pairStart)
	for i = 1, k do
		Test.deepEq(pairsB[i], pairs[i], "pair stream through the cut is unchanged")
	end
	local a = SupplementalFeatures.new(src, cal)
	local b = SupplementalFeatures.new(mutated, cal)
	local differs = false
	for i = 1, #pairs do
		local ra = a:row(pairs[i], B.base14(i))
		local rb = b:row(pairsB[i], B.base14(i))
		if i <= k then
			Test.deepEq(rb, ra, "row " .. i .. " through the cut")
		elseif rowsDiffer(ra.values, rb.values) then
			differs = true
		end
	end
	Test.truthy(differs, "control: the mutation does change rows after the cut")
end)

return suite
