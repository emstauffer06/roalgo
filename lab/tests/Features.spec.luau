-- Causal feature tests (plan Task 2 and section 3): base fourteen features, schemas, the observed-value
-- Scaler and the lag History. Synthetic fixtures only.
local Test = require("./Test")
local Calendar = require("../src/Data/Calendar")
local Dataset = require("../src/Data/Dataset")
local Features = require("../src/Data/Features")
local FeatureSchema = require("../src/Data/FeatureSchema")
local Scaler = require("../src/Data/Scaler")
local History = require("../src/Data/History")
local Fx = require("../fixtures/data_bars")

local suite = Test.suite("Features")
local HOUR = 3600
local T0 = Fx.T0
local TWO_PI = 2 * math.pi

local function build(spy, qqq)
	return Dataset.new(spy, qqq or Fx.copy(spy), Calendar.default())
end

-- A hand-made pair for direct Features.compute calls (bypassing Dataset validation on purpose).
local function rawPair(t: number, spy, qqq, segmentId: number?, offset: number?, hourNY: number?)
	return {
		index = 1,
		t = t,
		decisionTime = t + HOUR,
		dateNY = "2024-01-02",
		dateKey = 20240102,
		dayNumber = 19724,
		hourNY = hourNY or 5,
		segmentId = segmentId or 1,
		segmentOffset = offset or 2,
		spy = spy,
		qqq = qqq,
	}
end

-- Base features ----------------------------------------------------------------------------------------

Test.case(suite, "fourteen values in plan order: six SPY, six QQQ, then the New York clock", function()
	local spy = {
		Fx.bar(T0, 99, 100.5, 98.5, 100, 500, 5, 99.5),
		Fx.bar(T0 + HOUR, 101, 103, 100.5, 102, 1000, 10, 101.5),
	}
	local qqq = {
		Fx.bar(T0, 50, 51, 49, 50, 200, 2, 50),
		Fx.bar(T0 + HOUR, 50.5, 50.75, 49.5, 49.75, 0, 0, 50.2),
	}
	local ds = build(spy, qqq)
	local v = Features.compute(ds:get(2), ds:get(1))
	Test.eq(#v, 14)
	local expected = {
		math.log(102 / 100), math.log(102 / 101), math.log(103 / 100.5), 2 * (102 - 100.5) / (103 - 100.5) - 1,
		math.log(1 + 1000), math.log(102 / 101.5),
		math.log(49.75 / 50), math.log(49.75 / 50.5), math.log(50.75 / 49.5), 2 * (49.75 - 49.5) / (50.75 - 49.5) - 1,
		math.log(1 + 0), math.log(49.75 / 50.2),
		math.sin(TWO_PI * 5 / 24), math.cos(TWO_PI * 5 / 24),
	}
	for i = 1, 14 do
		Test.eq(v[i], expected[i], "feature " .. i)
	end
	Test.eq(ds:get(2).hourNY, 5, "clock uses the New York bar-start hour")
	Test.eq(v[11], 0, "zero volume is a real observed zero")
end)

Test.case(suite, "segment start, nil previous, or a previous pair from another segment gives a zero return", function()
	local ds = build(Fx.targetBars())
	Test.eq(Features.compute(ds:get(1), nil)[1], 0)
	Test.eq(Features.compute(ds:get(1), nil)[7], 0)
	local other = rawPair(T0 - HOUR, Fx.makeBar(T0 - HOUR, 50), Fx.makeBar(T0 - HOUR, 50), 99)
	local v = Features.compute(ds:get(1), other :: any)
	Test.eq(v[1], 0, "different segment: no return")
	Test.eq(v[7], 0)
	local w = Features.compute(ds:get(2), ds:get(1))
	Test.near(w[1], 0.001, 1e-15, "same segment one-hour return")
end)

Test.case(suite, "a gap never yields a close-to-close return across it", function()
	local bars = Fx.targetBars({ 6 }) -- hour T0+5h missing
	-- Make the price jump across the gap so a bridging return would be visible.
	for k = 6, #bars do
		local b = bars[k]
		for f = 2, 5 do
			b[f] *= 2
		end
		b[8] *= 2
	end
	local ds = build(bars)
	local sawGap = false
	for i = 2, ds:count() do
		local cur, prev = ds:get(i), ds:get(i - 1)
		local v = Features.compute(cur, prev)
		if cur.segmentId ~= prev.segmentId then
			sawGap = true
			Test.eq(v[1], 0, "no SPY return across the gap")
			Test.eq(v[7], 0, "no QQQ return across the gap")
		else
			Test.eq(v[1], math.log(cur.spy[5] / prev.spy[5]))
		end
	end
	Test.truthy(sawGap, "fixture contains a gap")
end)

Test.case(suite, "a same-segment previous pair must be the immediately preceding hour", function()
	local ds = build(Fx.targetBars())
	Test.throws(function() Features.compute(ds:get(4), ds:get(2)) end, "preceding")
end)

Test.case(suite, "a pair after its segment start needs its preceding pair: never a silent zero return", function()
	-- Review finding: a nil (or other-segment) previous pair used to give ret_1h = 0 at ANY segment offset, so
	-- a caller that lost its previous pair silently zeroed two features instead of failing.
	local ds = build(Fx.targetBars())
	local mid = ds:get(5)
	Test.eq(mid.segmentOffset, 5)
	Test.throws(function() Features.compute(mid, nil) end, "preceding", "nil previous mid-segment")
	local other = rawPair(mid.t - HOUR, Fx.makeBar(mid.t - HOUR, 1), Fx.makeBar(mid.t - HOUR, 1), 99)
	Test.throws(function() Features.compute(mid, other :: any) end, "preceding", "other-segment previous mid-segment")
	Test.throws(function() Features.baseRow(mid, nil, "O14") end, "preceding", "baseRow too")
	-- A segment start cannot take a previous pair of its own segment (contradictory metadata).
	local start = rawPair(T0 + HOUR, Fx.makeBar(T0 + HOUR, 1), Fx.makeBar(T0 + HOUR, 1), 1, 1)
	local before = rawPair(T0, Fx.makeBar(T0, 1), Fx.makeBar(T0, 1), 1, 1)
	Test.throws(function() Features.compute(start :: any, before :: any) end, "segment start", "start with same-segment previous")
	-- The previous pair's offset must be exactly one less.
	local skewed = rawPair(T0, Fx.makeBar(T0, 1), Fx.makeBar(T0, 1), 1, 3)
	Test.throws(function() Features.compute(rawPair(T0 + HOUR, Fx.makeBar(T0 + HOUR, 1), Fx.makeBar(T0 + HOUR, 1), 1, 2) :: any, skewed :: any) end, "preceding")
	Test.throws(function() Features.compute(rawPair(T0, Fx.makeBar(T0, 1), Fx.makeBar(T0, 1), 1, 0) :: any, nil) end, "segmentOffset")
	-- Every pair of a real dataset still computes with its dataset predecessor.
	for i = 1, ds:count() do
		Features.compute(ds:get(i), ds:get(i - 1))
	end
end)

Test.case(suite, "zero range: close location is zero when high equals low", function()
	local ds = build(Fx.targetBars())
	local v = Features.compute(ds:get(3), ds:get(2))
	Test.eq(v[3], 0, "range")
	Test.eq(v[4], 0, "close location")
	Test.eq(v[10], 0)
end)

Test.case(suite, "rejects bad VWAP, nonpositive prices, negative or non-finite volume and non-finite fields", function()
	local function rejects(mutate, needle)
		local good = Fx.bar(T0, 100, 101, 99, 100, 10, 1, 100)
		local bad = table.clone(good)
		mutate(bad)
		Test.throws(function() Features.compute(rawPair(T0, bad, good) :: any, nil) end, needle)
		Test.throws(function() Features.compute(rawPair(T0, good, bad) :: any, nil) end, needle)
	end
	rejects(function(b) b[8] = 0 end, "vwap")
	rejects(function(b) b[8] = -100 end, "vwap")
	rejects(function(b) b[2] = 0 end, "open")
	rejects(function(b) b[4] = -1 end, "low")
	rejects(function(b) b[5] = 0 end, "close")
	rejects(function(b) b[6] = -1 end, "volume")
	rejects(function(b) b[6] = math.huge end, "finite")
	rejects(function(b) b[3] = 0 / 0 end, "finite")
	-- A previous close is validated when it is used.
	local good = Fx.bar(T0 + HOUR, 100, 101, 99, 100, 10, 1, 100)
	local prev = rawPair(T0, Fx.bar(T0, 100, 101, 99, 0 / 0, 10, 1, 100), good, 1, 1)
	Test.throws(function() Features.compute(rawPair(T0 + HOUR, good, good) :: any, prev :: any) end, "finite")
	Test.throws(function() Features.compute(rawPair(T0, good, good, 1, 1, 24) :: any, nil) end, "hour")
end)

Test.case(suite, "future-invariance contract: mutating a future pair cannot change current features", function()
	local ds = build(Fx.targetBars())
	local currentPair, previousPair = ds:get(5), ds:get(4)
	local first = Features.compute(currentPair, previousPair)
	-- currentPair and previousPair are fixed; mutate a separate future fixture.
	local futurePair = { spy = table.clone(ds:get(6).spy), qqq = table.clone(ds:get(6).qqq) }
	for _, field in ipairs({ 2, 3, 4, 5, 8 }) do
		futurePair.spy[field] = futurePair.spy[field] * 100
	end
	local second = Features.compute(currentPair, previousPair)
	for i = 1, #first do
		Test.eq(first[i], second[i], "feature " .. i)
	end
	-- A dataset whose future bars differ radically gives identical features through t.
	local altered = Fx.targetBars()
	for k = 6, #altered do
		for f = 2, 5 do
			altered[k][f] *= 50
		end
		altered[k][6] = 7
		altered[k][8] *= 50
	end
	local ds2 = build(altered)
	for i = 1, 5 do
		local a = Features.compute(ds:get(i), if i > 1 then ds:get(i - 1) else nil)
		local b = Features.compute(ds2:get(i), if i > 1 then ds2:get(i - 1) else nil)
		Test.deepEq(a, b, "pair " .. i)
	end
end)

Test.case(suite, "baseRow wraps O14/H14 values with every observed flag true", function()
	local ds = build(Fx.targetBars())
	local row = Features.baseRow(ds:get(2), ds:get(1), "O14")
	Test.eq(#row.values, 14)
	Test.eq(#row.observed, 14)
	for i = 1, 14 do
		Test.eq(row.observed[i], true)
	end
	Test.deepEq(row.values, Features.compute(ds:get(2), ds:get(1)))
	Test.eq(row.t, T0 + HOUR)
	Test.eq(row.decisionTime, T0 + 2 * HOUR)
	Test.eq(row.profileId, "O14")
	Test.deepEq(Features.baseRow(ds:get(2), ds:get(1), "H14").values, row.values, "H14 uses the identical formula")
	Test.throws(function() Features.baseRow(ds:get(2), ds:get(1), "R50") end, "profile")
end)

-- Feature schemas --------------------------------------------------------------------------------------

Test.case(suite, "O14 and H14 share the identical fourteen-column formula", function()
	local o, h = FeatureSchema.get("O14"), FeatureSchema.get("H14")
	Test.eq(o.dimension, 14)
	Test.eq(h.dimension, 14)
	Test.deepEq(o.names, h.names)
	Test.deepEq(o.continuous, h.continuous)
	Test.eq(o.version, h.version)
	for i = 1, 14 do
		Test.eq(o.continuous[i], i <= 12, "column " .. i)
	end
	Test.deepEq(o.names, {
		"spy_ret_1h", "spy_body", "spy_range", "spy_close_location", "spy_log1p_volume", "spy_vwap_displacement",
		"qqq_ret_1h", "qqq_body", "qqq_range", "qqq_close_location", "qqq_log1p_volume", "qqq_vwap_displacement",
		"clock_sin", "clock_cos",
	})
end)

Test.case(suite, "R50 is exactly 50 columns: 14 base, 13 SPY, 13 QQQ, 5 IWM, 5 TLT; 28 continuous, 22 bounded", function()
	local r = FeatureSchema.get("R50")
	Test.eq(r.dimension, 50)
	Test.eq(#r.names, 50)
	Test.eq(#r.continuous, 50)
	local cont = {}
	for i, c in r.continuous do
		if c then
			table.insert(cont, i)
		end
	end
	Test.deepEq(cont, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15, 16, 21, 23, 24, 28, 29, 34, 36, 37, 41, 42, 43, 46, 47, 48 })
	Test.eq(#cont, 28)
	Test.eq(50 - #cont, 22)
	local o = FeatureSchema.get("O14")
	for i = 1, 14 do
		Test.eq(r.names[i], o.names[i], "R50 starts with the base fourteen")
	end
	Test.eq(r.names[15], "spy_ctx_realized_variation")
	Test.eq(r.names[27], "spy_ctx_daily_age")
	Test.eq(r.names[28], "qqq_ctx_realized_variation")
	Test.eq(r.names[40], "qqq_ctx_daily_age")
	Test.deepEq({ table.unpack(r.names, 41, 50) }, {
		"iwm_ret_1h", "iwm_range", "iwm_log1p_volume", "iwm_usable_mask", "iwm_age",
		"tlt_ret_1h", "tlt_range", "tlt_log1p_volume", "tlt_usable_mask", "tlt_age",
	})
	Test.eq(r.offsets.spyContext, 15)
	Test.eq(r.offsets.qqqContext, 28)
	Test.eq(r.offsets.iwm, 41)
	Test.eq(r.offsets.tlt, 46)
	for i = 1, 50 do
		local col = r.columns[i]
		Test.eq(col.index, i)
		Test.eq(col.name, r.names[i])
		Test.truthy(type(col.formula) == "string" and #col.formula > 0, "formula recorded")
		if not r.continuous[i] then
			Test.truthy(col.lower ~= nil and col.upper ~= nil, "bounded column " .. i .. " has bounds")
		end
	end
end)

Test.case(suite, "R60 appends four probabilities and a mask per symbol; names unique; assertDimension", function()
	local r60 = FeatureSchema.get("R60")
	Test.eq(r60.dimension, 60)
	local r50 = FeatureSchema.get("R50")
	for i = 1, 50 do
		Test.eq(r60.names[i], r50.names[i])
		Test.eq(r60.continuous[i], r50.continuous[i])
	end
	for i = 51, 60 do
		Test.eq(r60.continuous[i], false, "regime columns are bounded")
	end
	Test.eq(r60.names[55], "spy_regime_mask")
	Test.eq(r60.names[60], "qqq_regime_mask")
	for _, id in { "O14", "H14", "R50", "R60" } do
		local s = FeatureSchema.get(id)
		local seen = {}
		for _, n in s.names do
			Test.falsy(seen[n], "duplicate name " .. n)
			seen[n] = true
		end
		Test.eq(s.profileId, id)
		Test.truthy(#s.version > 0)
		FeatureSchema.assertDimension(s, s.dimension)
		Test.throws(function() FeatureSchema.assertDimension(s, s.dimension + 1) end, "dimension")
	end
	Test.throws(function() FeatureSchema.get("X99") end, "profile")
	Test.throws(function() (FeatureSchema.get("R50").names :: any)[1] = "x" end)
end)

-- Scaler -----------------------------------------------------------------------------------------------

local function row(profileId: string, values: { number }, observed: { boolean }?, t: number?)
	local obs = observed or table.create(#values, true)
	local tt = t or 1600000000
	return { values = values, observed = obs, t = tt, decisionTime = tt + HOUR, profileId = profileId }
end

local function o14(seed: number, t: number?)
	local v = {}
	for i = 1, 12 do
		v[i] = seed * i * 0.01
	end
	v[13], v[14] = 0.5, -0.5
	return row("O14", v, nil, t)
end

local function r50Row(fill: (number) -> number, observed: { boolean }?, t: number?)
	local schema = FeatureSchema.get("R50")
	local v = {}
	for i = 1, 50 do
		v[i] = if schema.continuous[i] then fill(i) else 0
	end
	return row("R50", v, observed, t)
end

Test.case(suite, "Scaler fits observed training values only (Welford, population std); real zeros count", function()
	local schema = FeatureSchema.get("R50")
	-- Column 15 (SPY realized variation) observed in three rows with values 0, 2, 4; unobserved in a fourth
	-- whose stored value is 0 and must not enter the fit.
	local rows = {}
	for k, x in { 0, 2, 4, 100 } do
		local obs = table.create(50, true)
		if k == 4 then
			obs[15] = false
		end
		local r = r50Row(function(i) return if i == 15 then (if k == 4 then 0 else x) else k end, obs)
		table.insert(rows, r)
	end
	local s = Scaler.fit(rows, schema)
	local d = s:diagnostics()
	Test.eq(d.columns[15].count, 3, "unobserved value omitted")
	Test.near(d.columns[15].mean, 2, 1e-15)
	Test.near(d.columns[15].std, math.sqrt(8 / 3), 1e-15, "population std")
	Test.eq(d.columns[1].count, 4)
	Test.near(d.columns[1].mean, 2.5, 1e-15)
	Test.eq(d.columns[13].count, 0, "bounded columns are not fitted")
end)

Test.case(suite, "unavailable continuous values become zero after scaling while masks are retained", function()
	local schema = FeatureSchema.get("R50")
	local rows = {}
	for k = 1, 5 do
		table.insert(rows, r50Row(function(i) return i + k end))
	end
	local s = Scaler.fit(rows, schema)
	local obs = table.create(50, true)
	obs[15], obs[16] = false, false -- five-minute values unavailable
	local r = r50Row(function(i) return if i == 15 or i == 16 then 0 else i + 3 end, obs)
	r.values[19] = 0 -- complete mask 0
	r.values[20] = 0.5 -- coverage 6/12
	r.values[27] = 1 -- daily age sentinel
	local out = s:transform(r, "validation")
	Test.eq(#out, 50)
	Test.eq(out[15], 0, "unavailable -> 0 after scaling")
	Test.eq(out[16], 0)
	Test.near(out[1], 0, 1e-12, "observed mean value scales to zero")
	Test.eq(out[19], 0, "mask passes through")
	Test.eq(out[20], 0.5, "coverage passes through")
	Test.eq(out[27], 1, "age sentinel passes through")
	-- An observed real zero is not missing: it is standardized.
	local z = r50Row(function(i) return if i == 15 then 0 else i + 3 end)
	Test.truthy(s:transform(z)[15] ~= 0, "observed zero is scaled, not treated as missing")
end)

Test.case(suite, "a column never observed in training stays zero in every split", function()
	local schema = FeatureSchema.get("R50")
	local rows = {}
	for k = 1, 4 do
		local obs = table.create(50, true)
		obs[41] = false -- IWM return never observed in training
		table.insert(rows, r50Row(function(i) return if i == 41 then 0 else i * k end, obs))
	end
	local s = Scaler.fit(rows, schema)
	local d = s:diagnostics()
	Test.eq(d.columns[41].neverObserved, true)
	Test.deepEq(d.neverObservedColumns, { 41 })
	for _, split in { "train", "validation", "final" } do
		local r = r50Row(function(i) return i * 2 end, nil, 1750000000)
		r.values[41] = 0.05 -- a validation/final value appears
		Test.eq(s:transform(r, split)[41], 0, "never-observed column in " .. split)
	end
end)

Test.case(suite, "z-scores are clipped to [-4, 4] and clipping is counted per column and split", function()
	local schema = FeatureSchema.get("O14")
	local rows = {}
	for k = 1, 10 do
		table.insert(rows, o14(k % 2 == 0 and 1 or -1))
	end
	local s = Scaler.fit(rows, schema) -- every continuous column: mean 0, std 0.01*i
	local big = o14(1000)
	local out = s:transform(big, "validation")
	for i = 1, 12 do
		Test.eq(out[i], 4, "clipped high " .. i)
	end
	local out2 = s:transform(o14(-1000), "validation")
	Test.eq(out2[3], -4, "clipped low")
	local inside = s:transform(o14(2), "train")
	Test.near(inside[5], 2, 1e-12, "unclipped z")
	Test.eq(out[13], 0.5, "clock passes through")
	Test.eq(out[14], -0.5)
	local d = s:diagnostics()
	Test.eq(d.clipping.validation.rows, 2)
	Test.eq(d.clipping.validation.clippedHigh[1], 1)
	Test.eq(d.clipping.validation.clippedLow[3], 1)
	Test.eq(d.clipping.train.rows, 1)
	Test.eq(d.clipping.train.clippedHigh[5], 0)
	Test.near(d.clipping.validation.rate[1], 1, 1e-15, "two observed, two clipped")
end)

Test.case(suite, "a constant training column outputs zero and is flagged", function()
	local schema = FeatureSchema.get("O14")
	local rows = {}
	for k = 1, 5 do
		local r = o14(k)
		r.values[2] = 0.25
		table.insert(rows, r)
	end
	local s = Scaler.fit(rows, schema)
	local d = s:diagnostics()
	Test.eq(d.columns[2].constant, true)
	Test.deepEq(d.constantColumns, { 2 })
	local r = o14(3)
	r.values[2] = 9
	local out = s:transform(r)
	Test.eq(out[2], 0, "constant column emits zero")
	Test.eq(#out, 14, "declared column count preserved")
end)

Test.case(suite, "bounded columns pass through unchanged and must stay within their declared bounds", function()
	local schema = FeatureSchema.get("O14")
	local s = Scaler.fit({ o14(1), o14(2), o14(3) }, schema)
	local r = o14(2)
	r.values[13] = 1
	r.values[14] = -1
	local out = s:transform(r)
	Test.eq(out[13], 1)
	Test.eq(out[14], -1)
	r.values[13] = 1.5
	Test.throws(function() s:transform(r) end, "bounds")
	local nan = o14(2)
	nan.values[4] = 0 / 0
	Test.throws(function() s:transform(nan) end, "finite")
end)

Test.case(suite, "serialize/deserialize round-trips exactly", function()
	local schema = FeatureSchema.get("R50")
	local rows = {}
	for k = 1, 7 do
		local obs = table.create(50, true)
		obs[23] = k % 3 ~= 0
		obs[41] = false
		table.insert(rows, r50Row(function(i) return math.sin(i * k) * 0.01 + i end, obs))
	end
	local s = Scaler.fit(rows, schema)
	local t = s:serialize()
	-- Plain data only (numbers, booleans, strings, arrays).
	local function plain(x)
		if type(x) == "table" then
			for _, v in x do
				plain(v)
			end
		else
			Test.truthy(type(x) == "number" or type(x) == "boolean" or type(x) == "string", "plain value")
		end
	end
	plain(t)
	local s2 = Scaler.deserialize(t, schema)
	Test.deepEq(s2:serialize(), t)
	for k = 1, 5 do
		local r = r50Row(function(i) return math.cos(i + k) * 3 + i end, nil, 1750000000)
		Test.deepEq(s2:transform(r), s:transform(r), "identical transform " .. k)
	end
	Test.throws(function() Scaler.deserialize(t, FeatureSchema.get("O14")) end, "profile")
	local bad = table.clone(t)
	bad.means = table.clone(t.means)
	table.remove(bad.means)
	Test.throws(function() Scaler.deserialize(bad, schema) end, "Scaler")
end)

Test.case(suite, "Scaler.fit rejects validation-period rows by default and mismatched rows", function()
	local schema = FeatureSchema.get("O14")
	local late = o14(1, Fx.SPLITS.validationStart - HOUR) -- decisionTime == validationStart
	Test.throws(function() Scaler.fit({ o14(1), late }, schema) end, "training")
	Test.throws(function() Scaler.fit({ row("R50", table.create(14, 0)) }, schema) end, "profile")
	Test.throws(function() Scaler.fit({ row("O14", table.create(13, 0)) }, schema) end, "dimension")
	Test.throws(function() Scaler.fit({}, schema) end, "no training rows")
	-- An explicit fitting window can be passed for synthetic fixtures.
	local ok = Scaler.fit({ o14(1, 1750000000), o14(2, 1750000000) }, schema, { fitBefore = 1800000000 })
	Test.eq(#ok:transform(o14(1)), 14)
end)

Test.case(suite, "Scaler.fit rejects a sparse rows array instead of silently fitting a prefix", function()
	-- Review finding: ipairs stopped at the first hole, so rows after it were dropped from the fit while
	-- rowCount still reported #rows.
	local schema = FeatureSchema.get("O14")
	local holeInside: { any } = { o14(1), o14(2), nil :: any, o14(100) }
	Test.throws(function() Scaler.fit(holeInside, schema) end, "dense", "hole before the last row")
	local trailing: { any } = { o14(1), o14(2) }
	trailing[4] = o14(100)
	Test.throws(function() Scaler.fit(trailing, schema) end, "dense", "row beyond the border")
	local keyed: { any } = { o14(1), o14(2) }
	keyed.extra = o14(3)
	Test.throws(function() Scaler.fit(keyed, schema) end, "dense", "non-integer key")
end)

Test.case(suite, "always-observed columns (base, clock, masks, coverage, ages) must be flagged observed", function()
	-- Review finding: a mask/coverage/age column flagged unobserved was silently emitted as 0, erasing the
	-- signal the plan says must survive missingness. Only optional columns may be unobserved.
	local schema = FeatureSchema.get("R50")
	local always = {}
	for i, c in schema.columns do
		if c.alwaysObserved then
			table.insert(always, i)
		end
	end
	Test.deepEq(always, {
		1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14,
		19, 20, 22, 25, 26, 27,
		32, 33, 35, 38, 39, 40,
		44, 45, 49, 50,
	})
	for _, id in { "O14", "H14" } do
		for i, c in FeatureSchema.get(id).columns do
			Test.eq(c.alwaysObserved, true, id .. " column " .. i)
		end
	end
	for i = 51, 60 do
		Test.eq(FeatureSchema.get("R60").columns[i].alwaysObserved, true, "R60 regime column " .. i)
	end
	local rows = {}
	for k = 1, 5 do
		table.insert(rows, r50Row(function(i) return i + k end))
	end
	local s = Scaler.fit(rows, schema)
	for _, j in { 19, 20, 27, 44, 50, 13, 1 } do
		local r = r50Row(function(i) return i + 3 end)
		r.observed[j] = false
		Test.throws(function() s:transform(r) end, "always observed", "transform column " .. j)
	end
	local badFit = table.clone(rows)
	badFit[2] = r50Row(function(i) return i + 2 end)
	badFit[2].observed[25] = false
	Test.throws(function() Scaler.fit(badFit, schema) end, "always observed", "fit")
	-- Optional bounded columns (path efficiency, volume share) may still be unavailable: 0 out.
	local opt = r50Row(function(i) return i + 3 end)
	opt.observed[17], opt.observed[18] = false, false
	opt.values[17], opt.values[18] = 0, 0
	local out = s:transform(opt)
	Test.eq(out[17], 0)
	Test.eq(out[18], 0)
end)

Test.case(suite, "R50 schema identity agrees with the SupplementalFeatures row builder", function()
	-- FeatureSchema is the authority; a drift in the builder's names or continuous flags must fail here.
	local SupplementalFeatures = require("../src/Data/SupplementalFeatures")
	local schema = FeatureSchema.get("R50")
	local names, cont = SupplementalFeatures.contextNames(), SupplementalFeatures.contextContinuous()
	Test.eq(#names, 36)
	Test.eq(#cont, 36)
	for k = 1, 36 do
		Test.eq(names[k], schema.names[14 + k], "name " .. (14 + k))
		Test.eq(cont[k], schema.continuous[14 + k], "continuous flag " .. (14 + k))
	end
	Test.eq(SupplementalFeatures.DIMENSION, schema.dimension)
end)

-- History ----------------------------------------------------------------------------------------------

Test.case(suite, "History layout: current first, earlier inputs next, then one mask per lag", function()
	local h = History.new(8, 2)
	h:push({ 1, 2 })
	h:push({ 3, 4 })
	Test.deepEq(h:vector(1), { 3, 4, 1 })
	Test.deepEq(h:vector(3), { 3, 4, 1, 2, 0, 0, 1, 1, 0 }, "zero padding with mask 0")
	h:reset()
	-- Review finding: an empty buffer used to give an all-zero vector with lag-1 mask 0. Lag 1 is the current
	-- input, so a vector before the current push is a caller error, not padding.
	Test.throws(function() h:vector(2) end, "push", "no current input since reset")
	h:push({ 7, 8 })
	Test.deepEq(h:vector(3), { 7, 8, 0, 0, 0, 0, 1, 0, 0 }, "reset clears every earlier lag")
	h:reset()
	Test.throws(function() History.new(8, 2):vector(1) end, "push", "fresh buffer")
	for k = 1, 10 do
		h:push({ k, -k })
	end
	local v = h:vector(8)
	Test.eq(v[1], 10, "most recent first")
	Test.eq(v[15], 3, "eighth lag is the eighth most recent")
	for k = 17, 24 do
		Test.eq(v[k], 1)
	end
end)

Test.case(suite, "History dimensions: (D+1)*L = 15/60/120 for D=14 and 51/204/408 for D=50", function()
	for _, case in { { 14, { 15, 60, 120 } }, { 50, { 51, 204, 408 } }, { 60, { 61, 244, 488 } } } do
		local D, dims = case[1], case[2]
		local h = History.new(8, D)
		h:push(table.create(D, 0.5))
		for i, L in { 1, 4, 8 } do
			Test.eq(#h:vector(L), dims[i], string.format("D=%d L=%d", D, L))
			Test.eq(History.outputDimension(D, L), dims[i])
		end
	end
	Test.eq(History.outputDimension(14, 8) + 48, 168, "O14/H14 RAW+PHYSICS")
	Test.eq(History.outputDimension(50, 8) + 48, 456, "R50 RAW+PHYSICS")
	Test.eq(History.outputDimension(60, 8) + 48, 536, "R60 RAW+PHYSICS")
end)

Test.case(suite, "History copies inputs and rejects bad dimensions or lags", function()
	local h = History.new(4, 3)
	local x = { 1, 2, 3 }
	h:push(x)
	x[1] = 99
	Test.eq(h:vector(1)[1], 1, "stored a copy")
	Test.throws(function() h:push({ 1, 2 }) end, "dimension")
	Test.throws(function() h:push({ 1, 0 / 0, 3 }) end, "finite")
	Test.throws(function() h:vector(5) end, "lags")
	Test.throws(function() h:vector(0) end, "lags")
	Test.throws(function() History.new(0, 3) end, "maxLag")
end)

return suite
