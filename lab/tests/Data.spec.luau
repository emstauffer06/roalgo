-- Data contract tests (plan Task 2): New York calendar against the Intl fixture, paired dataset, segments,
-- validation, and the evaluator-only eight-hour target policy. Synthetic fixtures only.
local Test = require("./Test")
local Calendar = require("../src/Data/Calendar")
local Dataset = require("../src/Data/Dataset")
local Targets = require("../src/Data/Targets")
local Fx = require("../fixtures/data_bars")

local suite = Test.suite("Data")
local HOUR = 3600
local T0 = Fx.T0

local function build(spy, qqq)
	return Dataset.new(spy, qqq or Fx.copy(spy), Calendar.default())
end

-- Calendar ---------------------------------------------------------------------------------------------

Test.case(suite, "Calendar.default matches every Intl-computed instant in the generated fixture", function()
	local fixture = require("../generated/CalendarFixture")
	local cal = Calendar.default()
	Test.truthy(#fixture.instants > 3000, "fixture has the DST-adjacent hours and ~3000 samples")
	for _, row in fixture.instants do
		local t, dateKey, hour, minute, offset = row[1], row[2], row[3], row[4], row[5]
		local lt = cal:localTime(t)
		Test.eq(lt.dateKey, dateKey, "dateKey at " .. t)
		Test.eq(lt.hour, hour, "hour at " .. t)
		Test.eq(lt.minute, minute, "minute at " .. t)
		Test.eq(lt.offsetSeconds, offset, "offset at " .. t)
	end
end)

Test.case(suite, "2024-03-08T14:00Z and 2024-03-11T13:00Z are both 09:00 New York; November transition", function()
	local fixture = require("../generated/CalendarFixture")
	local cal = Calendar.default()
	local a = cal:localTime(1709906400) -- 2024-03-08T14:00:00Z
	local b = cal:localTime(1710162000) -- 2024-03-11T13:00:00Z
	Test.eq(a.hour, 9, "EST 09:00")
	Test.eq(b.hour, 9, "EDT 09:00")
	Test.eq(a.dateKey, 20240308)
	Test.eq(b.dateKey, 20240311)
	Test.eq(a.offsetSeconds, -18000)
	Test.eq(b.offsetSeconds, -14400)
	local sawNovember = false
	for _, n in fixture.named do
		local lt = cal:localTime(n.t)
		Test.eq(lt.dateKey, n.dateKey, n.label)
		Test.eq(lt.hour, n.hour, n.label)
		Test.eq(lt.minute, n.minute, n.label)
		Test.eq(lt.offsetSeconds, n.offsetSeconds, n.label)
		if string.sub(n.label, 1, 7) == "2024-11" then
			sawNovember = true
		end
	end
	Test.truthy(sawNovember, "a November transition fixture is present")
	-- The repeated autumn hour: 05:59:59Z is 01:59:59 EDT, 06:00:00Z is 01:00 EST.
	Test.eq(cal:localTime(1730613599).hour, 1)
	Test.eq(cal:localTime(1730613600).hour, 1)
	Test.eq(cal:localTime(1730613600).offsetSeconds, -18000)
end)

Test.case(suite, "nextMidnightAfter matches Intl for every fixture date, including both DST changes", function()
	local fixture = require("../generated/CalendarFixture")
	local cal = Calendar.default()
	Test.truthy(#fixture.midnights >= 380, "about 400 dates")
	for _, m in fixture.midnights do
		Test.eq(cal:nextMidnightAfter(m[1]), m[2], "next midnight after " .. m[1])
	end
	Test.eq(cal:nextMidnightAfter(20240309), 1710046800, "2024-03-10 00:00 EST")
	Test.eq(cal:nextMidnightAfter(20240310), 1710129600, "2024-03-11 00:00 EDT (not +86400)")
	Test.eq(cal:nextMidnightAfter(20241103), 1730696400, "2024-11-04 00:00 EST")
	Test.eq(cal:nextMidnightAfter(20231231), Fx.SPLITS.validationStart)
	Test.eq(cal:nextMidnightAfter(20261002), Fx.SPLITS.datasetEnd)
end)

Test.case(suite, "dateString, dayNumber and civil-date arithmetic", function()
	local cal = Calendar.default()
	Test.eq(cal:dateString(20240102), "2024-01-02")
	Test.eq(cal:dateString(20240229), "2024-02-29")
	Test.throws(function() cal:dateString(20230229) end, "invalid date")
	Test.throws(function() cal:nextMidnightAfter(20241301) end, "invalid date")
	Test.eq(Calendar.dayNumberOf(19700101), 0)
	Test.eq(Calendar.dayNumberOf(20000301) - Calendar.dayNumberOf(20000228), 2, "2000 is a leap year")
	Test.eq(Calendar.dayNumberOf(19000301) - Calendar.dayNumberOf(19000228), 1, "1900 is not")
	Test.eq(Calendar.dateKeyOf(Calendar.dayNumberOf(20261002)), 20261002)
	local a = cal:localTime(1710046800) -- 2024-03-10 00:00 EST
	local b = cal:localTime(1710129600) -- 2024-03-11 00:00 EDT
	Test.eq(b.dayNumber - a.dayNumber, 1, "dayNumber is gap-free across the spring change")
	Test.eq(a.dayNumber, Calendar.dayNumberOf(20240310))
end)

Test.case(suite, "Calendar rejects malformed tables and instants outside its coverage", function()
	local cal = Calendar.default()
	Test.throws(function() cal:localTime(cal.coverageStart - 1) end, "coverage")
	Test.throws(function() cal:localTime(cal.coverageEnd) end, "coverage")
	Test.throws(function() cal:localTime(0 / 0) end, "Calendar")
	Test.throws(function() Calendar.new({}) end, "Calendar")
	Test.throws(function()
		Calendar.new({ { utcStartSeconds = 10, offsetSeconds = 0 }, { utcStartSeconds = 10, offsetSeconds = 3600 } })
	end, "increasing")
	-- A custom table works with the same arithmetic (here UTC itself).
	local utc = Calendar.new({ { utcStartSeconds = 0, offsetSeconds = 0 } })
	local lt = utc:localTime(31536000 + 3 * HOUR + 120) -- 1971-01-01T03:02:00Z
	Test.eq(lt.dateKey, 19710101)
	Test.eq(lt.hour, 3)
	Test.eq(lt.minute, 2)
	Test.eq(lt.dayNumber, 365)
end)

-- Dataset ----------------------------------------------------------------------------------------------

Test.case(suite, "pairs by timestamp intersection, never by row index, and keeps unpaired native bars", function()
	local spy = Fx.targetBars()
	table.insert(spy, 1, Fx.makeBar(T0 - HOUR, 0.5)) -- SPY-only bar before the day starts
	local qqq = Fx.targetBars({ 4 }) -- QQQ lacks T0+3h
	local ds = build(spy, qqq)
	Test.eq(ds:count(), 12)
	local expectT = {}
	for i = 0, 12 do
		if i ~= 3 then
			table.insert(expectT, T0 + i * HOUR)
		end
	end
	for i, t in expectT do
		local p = ds:get(i)
		Test.eq(p.index, i)
		Test.eq(p.t, t)
		Test.eq(p.spy[1], t, "SPY bar aligned by timestamp")
		Test.eq(p.qqq[1], t, "QQQ bar aligned by timestamp")
		Test.eq(ds:indexOf(t), i)
	end
	Test.eq(ds:indexOf(T0 + 3 * HOUR), nil, "unpaired timestamp has no paired index")
	Test.eq(ds:symbolBarAt("SPY", T0 + 3 * HOUR)[1], T0 + 3 * HOUR, "SPY-only bar is still available")
	Test.eq(ds:symbolBarAt("SPY", T0 - HOUR)[5], 0.5)
	Test.eq(ds:symbolBarAt("QQQ", T0 + 3 * HOUR), nil)
	Test.throws(function() ds:symbolBarAt("IWM", T0) end, "symbol")
	local stats = ds:stats()
	Test.eq(stats.spyOnly, 2)
	Test.eq(stats.qqqOnly, 0)
	Test.eq(#ds:pairs(), 12)
end)

Test.case(suite, "pair metadata: decision time, New York date and hour", function()
	local ds = build(Fx.targetBars())
	local p = ds:get(1)
	Test.eq(p.decisionTime, T0 + HOUR)
	Test.eq(p.dateNY, "2024-01-02")
	Test.eq(p.dateKey, 20240102)
	Test.eq(p.hourNY, 4)
	Test.eq(p.dayNumber, Calendar.dayNumberOf(20240102))
	Test.eq(ds:get(13).hourNY, 16)
	Test.eq(ds:get(14), nil)
	Test.eq(ds:get(0), nil)
end)

Test.case(suite, "segments start on the first pair, a New York date change, or any delta other than 3600", function()
	-- Evening run 16:00 .. 04:00 next day (date change after 23:00), then a 2-hour gap, then 3 more bars.
	local bars = Fx.hourlyRun(Fx.EVENING_T0, 13)
	local last = bars[#bars][1]
	for k = 1, 3 do
		table.insert(bars, Fx.makeBar(last + HOUR + k * HOUR, 100))
	end
	local ds = build(bars)
	local ids, offs = {}, {}
	for i = 1, ds:count() do
		ids[i] = ds:get(i).segmentId
		offs[i] = ds:get(i).segmentOffset
	end
	-- 16..23 NY on 01-02 (8 bars), 00..04 on 01-03 (5 bars), gap, 3 bars.
	Test.deepEq(ids, { 1, 1, 1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3 })
	Test.deepEq(offs, { 1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 1, 2, 3 })
end)

Test.case(suite, "rejects invalid sources instead of dropping rows", function()
	local function rejects(mutate, needle)
		local spy = Fx.targetBars()
		mutate(spy)
		Test.throws(function() build(spy, Fx.targetBars()) end, needle)
	end
	rejects(function(b) b[5][1] = b[4][1] end, "increasing") -- duplicate timestamp
	rejects(function(b) b[5][1] = b[3][1] - 1 end, "increasing") -- out of order
	rejects(function(b) b[2][8] = 0 end, "vwap") -- bad VWAP
	rejects(function(b) b[2][8] = -1 end, "vwap")
	rejects(function(b) b[3][2] = 0 end, "open")
	rejects(function(b) b[3][3] = -2 end, "high")
	rejects(function(b) b[3][4] = 0 end, "low")
	rejects(function(b) b[3][5] = 0 end, "close")
	rejects(function(b) b[3][6] = -1 end, "volume")
	rejects(function(b) b[3][5] = 0 / 0 end, "finite")
	rejects(function(b) b[3][6] = math.huge end, "finite")
	rejects(function(b) b[3][7] = -1 end, "trade_count")
	rejects(function(b) b[3][9] = 1 end, "8 fields")
	rejects(function(b) b[3][8] = nil end, "8 fields")
	rejects(function(b) b[3][3] = "1" :: any end, "finite")
	Test.throws(function() Dataset.new(Fx.targetBars(), Fx.targetBars(), nil :: any) end, "calendar")
end)

Test.case(suite, "Dataset.load checks each loader module's schema order, symbol and row count", function()
	-- Review finding: load forwarded module.bars unchecked, so swapped SPY/QQQ modules or a reordered column
	-- schema would silently produce a wrong dataset.
	local SCHEMA = { "timestamp_unix", "open", "high", "low", "close", "volume", "trade_count", "vwap" }
	local function mod(symbol: string, bars: { any }, schema: { string }?, count: number?)
		return { metadata = { symbol = symbol, count = count or #bars }, schema = schema or table.clone(SCHEMA), bars = bars }
	end
	local cal = Calendar.default()
	local ds = Dataset.load(mod("SPY", Fx.targetBars()), mod("QQQ", Fx.targetBars()), cal)
	Test.eq(ds:count(), 13)
	Test.eq(ds:get(4).spy[5], Fx.targetBars()[4][5])
	Test.throws(function() Dataset.load(mod("QQQ", Fx.targetBars()), mod("SPY", Fx.targetBars()), cal) end, "symbol", "swapped modules")
	local reordered = table.clone(SCHEMA)
	reordered[5], reordered[8] = "vwap", "close"
	Test.throws(function() Dataset.load(mod("SPY", Fx.targetBars(), reordered), mod("QQQ", Fx.targetBars()), cal) end, "schema", "column order")
	Test.throws(function() Dataset.load(mod("SPY", Fx.targetBars()), mod("QQQ", Fx.targetBars(), nil, 14), cal) end, "count", "row count")
	Test.throws(function() Dataset.load({ bars = Fx.targetBars() }, mod("QQQ", Fx.targetBars()), cal) end, "schema", "no schema")
end)

Test.case(suite, "stores frozen copies: later caller mutation cannot change the dataset", function()
	local spy = Fx.targetBars()
	local ds = build(spy)
	spy[4][5] = 999
	Test.near(ds:get(4).spy[5], math.exp(0.003), 0, "copy is unaffected")
	Test.throws(function() (ds:get(4) :: any).t = 0 end)
	Test.throws(function() (ds:get(4).spy :: any)[5] = 1 end)
	Test.throws(function() (ds:pairs() :: any)[1] = nil end)
end)

-- Targets ----------------------------------------------------------------------------------------------

Test.case(suite, "plan fixture: origin index 4 is eligible and both returns equal 0.008", function()
	local bars = Fx.targetBars()
	local expectedReturn = 0.008
	Test.truthy(math.abs(math.log(bars[12][5] / bars[4][5]) - expectedReturn) < 1e-12)
	Test.eq((bars[12][1] + HOUR) - (bars[4][1] + HOUR), 28800)
	local ds = build(bars)
	local r = Targets.lookup(ds, ds:get(4), Fx.SPLITS, 4)
	Test.eq(r.eligible, true)
	Test.eq(r.reason, nil)
	Test.eq(r.split, "validation")
	Test.near(r.spy, expectedReturn, 1e-12, "SPY return")
	Test.near(r.qqq, expectedReturn, 1e-12, "QQQ return")
	Test.eq(r.decisionTime, T0 + 4 * HOUR)
	Test.eq(r.targetT, T0 + 11 * HOUR)
	Test.eq(r.outcomeTime - r.decisionTime, 28800)
	Test.throws(function() (r :: any).spy = 0 end, nil, "outcome record is frozen")
end)

Test.case(suite, "removing index 7 gives missing_intermediate_hour although the endpoint exists", function()
	local ds = build(Fx.targetBars({ 7 }))
	local origin = ds:get(ds:indexOf(T0 + 3 * HOUR))
	Test.eq(origin.segmentOffset, 4, "origin is still warmed")
	Test.truthy(ds:indexOf(T0 + 11 * HOUR) ~= nil, "row-index+8 style endpoint exists")
	local r = Targets.lookup(ds, origin, Fx.SPLITS, 4)
	Test.eq(r.eligible, false)
	Test.eq(r.reason, "missing_intermediate_hour")
	Test.eq(r.spy, nil)
	Test.eq(r.qqq, nil)
end)

Test.case(suite, "missing_target when hours 1-7 exist but the k=8 endpoint does not", function()
	local ds = build(Fx.targetBars())
	local r = Targets.lookup(ds, ds:get(6), Fx.SPLITS, 4) -- T0+5h: hours T0+6h..T0+12h exist, T0+13h does not
	Test.eq(r.reason, "missing_target")
	Test.eq(Targets.lookup(ds, ds:get(7), Fx.SPLITS, 4).reason, "missing_intermediate_hour")
end)

Test.case(suite, "insufficient_warmup for the first three observations of a segment", function()
	local ds = build(Fx.targetBars())
	for i = 1, 3 do
		local r = Targets.lookup(ds, ds:get(i), Fx.SPLITS, 4)
		Test.eq(r.eligible, false)
		Test.eq(r.reason, "insufficient_warmup", "origin " .. i)
	end
	Test.eq(Targets.lookup(ds, ds:get(4), Fx.SPLITS, 4).eligible, true)
	-- Warmup is a parameter: with 2 observations origin 2 has hours 1-8 and becomes eligible.
	Test.eq(Targets.lookup(ds, ds:get(2), Fx.SPLITS, 2).eligible, true)
end)

Test.case(suite, "different_local_date when the target bar starts on the next New York date", function()
	-- 16:00 .. 04:00; the 20:00 origin (offset 5) has hours 21:00 .. 04:00 present but its target is 01-03.
	local ds = build(Fx.hourlyRun(Fx.EVENING_T0, 13))
	local origin = ds:get(5)
	Test.eq(origin.hourNY, 20)
	Test.eq(origin.segmentOffset, 5)
	local r = Targets.lookup(ds, origin, Fx.SPLITS, 4)
	Test.eq(r.reason, "different_local_date")
	Test.eq(r.eligible, false)
end)

Test.case(suite, "split_boundary: an outcome reaching the next split start is purged (exclusive bound)", function()
	local ds = build(Fx.targetBars())
	local origin = ds:get(4) -- decision T0+4h, outcome T0+12h
	local crossing = { validationStart = T0 + 12 * HOUR, testStart = T0 + 30 * HOUR, datasetEnd = T0 + 60 * HOUR }
	local r = Targets.lookup(ds, origin, crossing, 4)
	Test.eq(r.eligible, false)
	Test.eq(r.reason, "split_boundary")
	Test.eq(r.split, "none")
	local justInside = { validationStart = T0 + 12 * HOUR + 1, testStart = T0 + 30 * HOUR, datasetEnd = T0 + 60 * HOUR }
	local ok = Targets.lookup(ds, origin, justInside, 4)
	Test.eq(ok.eligible, true)
	Test.eq(ok.split, "train")
end)

Test.case(suite, "splitOf follows section 2.4 inequalities with exclusive upper bounds", function()
	local S = Fx.SPLITS
	local vs, ts, de = S.validationStart, S.testStart, S.datasetEnd
	Test.eq(Targets.splitOf(vs - 9 * HOUR, vs - HOUR, S), "train")
	Test.eq(Targets.splitOf(vs - 8 * HOUR, vs, S), "none", "training outcome reaching validation start")
	Test.eq(Targets.splitOf(vs - HOUR, vs + 7 * HOUR, S), "none", "label crossing into validation")
	Test.eq(Targets.splitOf(vs, vs + 8 * HOUR, S), "validation", "decision at validation start")
	Test.eq(Targets.splitOf(ts - 9 * HOUR, ts - HOUR, S), "validation")
	Test.eq(Targets.splitOf(ts - 8 * HOUR, ts, S), "none", "validation outcome reaching test start")
	Test.eq(Targets.splitOf(ts, ts + 8 * HOUR, S), "final")
	Test.eq(Targets.splitOf(de - 9 * HOUR, de - HOUR, S), "final")
	Test.eq(Targets.splitOf(de - 8 * HOUR, de, S), "none", "final outcome reaching dataset end")
	Test.eq(Targets.splitOf(de, de + 8 * HOUR, S), "none")
	Test.throws(function() Targets.splitOf(vs, vs + 8 * HOUR, { validationStart = ts, testStart = vs, datasetEnd = de }) end, "order")
end)

Test.case(suite, "reason priority: invalid_input, warmup, intermediate, target, date, split", function()
	local ds = build(Fx.targetBars())
	-- A pair that does not belong to this dataset is invalid_input even though it is also not warmed.
	local foreign = table.clone(ds:get(1)) :: any
	foreign.spy = table.clone(ds:get(1).spy)
	foreign.spy[5] = 1.5
	Test.eq(Targets.lookup(ds, foreign, Fx.SPLITS, 4).reason, "invalid_input")
	local stranger = table.clone(ds:get(2)) :: any
	stranger.t = T0 - 50 * HOUR
	Test.eq(Targets.lookup(ds, stranger, Fx.SPLITS, 4).reason, "invalid_input")
	-- Not warmed and missing hours: warmup wins.
	local short = build(Fx.targetBars({ 7 }))
	Test.eq(Targets.lookup(short, short:get(2), Fx.SPLITS, 4).reason, "insufficient_warmup")
	-- Missing intermediate and missing endpoint: intermediate wins.
	Test.eq(Targets.lookup(ds, ds:get(10), Fx.SPLITS, 4).reason, "missing_intermediate_hour")
	-- Different date and outside every split: date wins.
	local ev = build(Fx.hourlyRun(Fx.EVENING_T0, 13))
	local none = { validationStart = 1, testStart = 2, datasetEnd = 3 }
	Test.eq(Targets.lookup(ev, ev:get(5), none, 4).reason, "different_local_date")
	-- Everything else fine but outside every split: split_boundary.
	Test.eq(Targets.lookup(ds, ds:get(4), none, 4).reason, "split_boundary")
end)

Test.case(suite, "classify is structural only: it never computes a return", function()
	local ds = build(Fx.targetBars())
	local c = Targets.classify(ds, ds:get(4), Fx.SPLITS, 4)
	Test.eq(c.eligible, true)
	Test.eq(c.spy, nil)
	Test.eq(c.qqq, nil)
	Test.eq(c.targetT, T0 + 11 * HOUR)
	-- Changing the endpoint price changes lookup's value but never classify's structure.
	local bars = Fx.targetBars()
	bars[12][5] = 7
	bars[12][2], bars[12][3], bars[12][4], bars[12][8] = 7, 7, 7, 7
	local ds2 = build(bars)
	Test.deepEq(Targets.classify(ds2, ds2:get(4), Fx.SPLITS, 4), c)
	Test.truthy(Targets.lookup(ds2, ds2:get(4), Fx.SPLITS, 4).spy ~= Targets.lookup(ds, ds:get(4), Fx.SPLITS, 4).spy)
end)

Test.case(suite, "lookup validates its arguments", function()
	local ds = build(Fx.targetBars())
	Test.throws(function() Targets.lookup(ds, ds:get(4), nil :: any, 4) end, "splits")
	Test.throws(function() Targets.lookup(ds, ds:get(4), Fx.SPLITS, 0) end, "warmup")
	Test.throws(function() Targets.lookup(ds, nil :: any, Fx.SPLITS, 4) end, "pair")
end)

return suite
