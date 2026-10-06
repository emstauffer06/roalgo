--!strict
-- R50 FeatureRow construction (plan Section 3 "Rich input contract for R50" and "Rich scaling, masks, and
-- feature identity"). Pure Luau: no engine globals.
--
-- Row layout (50 values, untransformed):
--   1..14   O14 base values from Features.compute, passed in by the caller (all observed)
--   15..27  SPY context block (13)      28..40  QQQ context block (13)
--   41..45  IWM context block (5)       46..50  TLT context block (5)
-- Per-symbol block positions:
--   1 intrahour realized variation sqrt(sum r_j^2)        8 relative-volume-available mask
--   2 final-fifteen-minute return ln(C11/C8)              9 previous completed daily bar ln(Cday/Oday)
--   3 path efficiency |sum r_j| / sum |r_j|               10 daily volatility of twenty close-to-close returns
--   4 final-fifteen-minute volume share (V9+V10+V11)/sum V  11 previous-day-return mask
--   5 five-minute-complete mask                           12 daily-volatility mask
--   6 five-minute coverage (observed expected children)/12  13 daily age min(dateDiff,7)/7, 1 if missing/stale
--   7 relative hourly volume ln(1+V) - mean ln(1+V) over <=20 previous NY dates at the same NY hour
-- IWM/TLT positions: 1 ln(Cu/C(u-3600)), 2 ln(Hu/Lu), 3 ln(1+Vu), 4 usable mask, 5 min(age,7200)/7200 or 1.
--
-- Unavailable values are 0 with observed=false. Masks, coverage and ages are always observed=true.
-- The builder reads context only through a ContextCursor, so a row can depend only on source rows available
-- by its decision time. Rolling buffers live in the cursor and never depend on segments (physical resets).
local Types = require("../Types")
local ContextCursor = require("./ContextCursor")

type Bar = Types.Bar
type Pair = Types.Pair
type FeatureRow = Types.FeatureRow
type CausalContext = ContextCursor.CausalContext

local BAR = Types.Bar
local T_, OPEN, HIGH, LOW, CLOSE, VOLUME = BAR.T, BAR.OPEN, BAR.HIGH, BAR.LOW, BAR.CLOSE, BAR.VOLUME

local SupplementalFeatures = {}

SupplementalFeatures.PROFILE_ID = "R50"
SupplementalFeatures.DIMENSION = 50
SupplementalFeatures.BASE_DIMENSION = 14
SupplementalFeatures.SYMBOL_BLOCK = 13
SupplementalFeatures.CONTEXT_BLOCK = 5
SupplementalFeatures.FORMULA_VERSION = "r50-context-1"
SupplementalFeatures.CHILDREN = 12
SupplementalFeatures.RELATIVE_VOLUME_MIN = 5
SupplementalFeatures.RELATIVE_VOLUME_MAX = 20
SupplementalFeatures.DAILY_RETURNS = 20
SupplementalFeatures.DAILY_MAX_AGE_DATES = 7
SupplementalFeatures.CONTEXT_MAX_AGE_SECONDS = 7200

-- Block-local names, in order (matching FeatureSchema's R50 names as of 2026-10-05; FeatureSchema is the
-- authority), and which entries are continuous (z-scored by the input Scaler).
SupplementalFeatures.SYMBOL_BLOCK_NAMES = table.freeze({
	"ctx_realized_variation", "ctx_ret_last15m", "ctx_path_efficiency", "ctx_volume_share_last15m",
	"ctx_5m_complete_mask", "ctx_5m_coverage", "ctx_relative_volume", "ctx_relative_volume_mask",
	"ctx_prev_day_ret", "ctx_daily_vol20", "ctx_prev_day_mask", "ctx_daily_vol_mask", "ctx_daily_age",
})
SupplementalFeatures.SYMBOL_BLOCK_CONTINUOUS = table.freeze({
	true, true, false, false, false, false, true, false, true, true, false, false, false,
})
SupplementalFeatures.CONTEXT_BLOCK_NAMES = table.freeze({ "ret_1h", "range", "log1p_volume", "usable_mask", "age" })
SupplementalFeatures.CONTEXT_BLOCK_CONTINUOUS = table.freeze({ true, true, true, false, false })

-- Names of the 36 supplemental columns (positions 15..50), e.g. "spy_ctx_realized_variation", "tlt_age".
function SupplementalFeatures.contextNames(): { string }
	local out = {}
	for _, sym in { "SPY", "QQQ" } do
		for _, n in SupplementalFeatures.SYMBOL_BLOCK_NAMES do
			table.insert(out, string.lower(sym) .. "_" .. n)
		end
	end
	for _, sym in { "IWM", "TLT" } do
		for _, n in SupplementalFeatures.CONTEXT_BLOCK_NAMES do
			table.insert(out, string.lower(sym) .. "_" .. n)
		end
	end
	return out
end

-- Continuous flags of the 36 supplemental columns (positions 15..50).
function SupplementalFeatures.contextContinuous(): { boolean }
	local out = {}
	for _ = 1, 2 do
		for _, f in SupplementalFeatures.SYMBOL_BLOCK_CONTINUOUS do
			table.insert(out, f)
		end
	end
	for _ = 1, 2 do
		for _, f in SupplementalFeatures.CONTEXT_BLOCK_CONTINUOUS do
			table.insert(out, f)
		end
	end
	return out
end

local function fail(msg: string): never
	error("SupplementalFeatures: " .. msg, 3)
end

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function checkFinite(values: { number }, what: string)
	for i, x in values do
		if not isFinite(x) then
			fail(what .. " position " .. i .. " is non-finite")
		end
	end
end

-- Thirteen-value block for SPY or QQQ at pair (decision pair.t + 3600). ctx must be advanced to
-- pair.decisionTime. The current bar volume comes from the pair's native hourly bar.
function SupplementalFeatures.symbolBlock(ctx: CausalContext, symbol: string, pair: Pair): ({ number }, { boolean })
	if ctx.decisionTime ~= pair.decisionTime then
		fail("context decision time does not match the pair")
	end
	local current: Bar
	if symbol == "SPY" then
		current = pair.spy
	elseif symbol == "QQQ" then
		current = pair.qqq
	else
		fail("unknown symbol " .. tostring(symbol))
	end
	local v = table.create(13, 0)
	local o = table.create(13, false)
	local t = pair.t

	-- Positions 1-6: the twelve expected five-minute starts t + 300j, j = 0..11 (exact timestamps only).
	local kids: { Bar } = {}
	local present = 0
	for j = 0, 11 do
		local b = ctx:fiveMinuteAt(symbol, t + 300 * j)
		if b ~= nil then
			present += 1
			kids[j + 1] = b
		end
	end
	if present == 12 then
		-- x0 = O0, x(j+1) = Cj; r_j = ln(x(j+1)/x_j)
		local sumSq, sumR, sumAbs, totalV = 0, 0, 0, 0
		local prevX = kids[1][OPEN]
		for j = 1, 12 do
			local x = kids[j][CLOSE]
			local r = math.log(x / prevX)
			sumSq += r * r
			sumR += r
			sumAbs += math.abs(r)
			totalV += kids[j][VOLUME]
			prevX = x
		end
		v[1] = math.sqrt(sumSq)
		v[2] = math.log(kids[12][CLOSE] / kids[9][CLOSE])
		v[3] = if sumAbs > 0 then math.abs(sumR) / sumAbs else 0
		v[4] = if totalV > 0 then (kids[10][VOLUME] + kids[11][VOLUME] + kids[12][VOLUME]) / totalV else 0
		o[1], o[2], o[3], o[4] = true, true, true, true
		v[5] = 1
	end
	o[5] = true
	v[6] = present / 12
	o[6] = true

	-- Positions 7-8: relative hourly volume vs previous observed NY dates at the same NY bar-start hour.
	local history = ctx:sameHourHistory(symbol, pair.hourNY, pair.dateKey)
	if #history >= SupplementalFeatures.RELATIVE_VOLUME_MIN then
		local sum = 0
		for _, x in history do
			sum += x
		end
		v[7] = math.log(1 + current[VOLUME]) - sum / #history
		o[7] = true
		v[8] = 1
	end
	o[8] = true

	-- Positions 9-13: completed daily bars from strictly earlier NY dates, freshness <= 7 calendar dates.
	local daily = ctx:dailyHistory(symbol, pair.dateKey, SupplementalFeatures.DAILY_RETURNS + 1)
	local latest = daily[#daily]
	local age = 1
	if latest ~= nil then
		local diff = pair.dayNumber - latest.dayNumber
		if diff < 1 then
			fail("daily bar is not from a strictly earlier New York date")
		end
		age = math.min(diff, SupplementalFeatures.DAILY_MAX_AGE_DATES) / SupplementalFeatures.DAILY_MAX_AGE_DATES
		if diff <= SupplementalFeatures.DAILY_MAX_AGE_DATES then
			v[9] = math.log(latest.bar[CLOSE] / latest.bar[OPEN])
			o[9] = true
			v[11] = 1
			if #daily == SupplementalFeatures.DAILY_RETURNS + 1 then
				local q: { number } = {}
				local m: number = 0
				for k = 2, #daily do
					local r = math.log(daily[k].bar[CLOSE] / daily[k - 1].bar[CLOSE])
					q[k - 1] = r
					m += r
				end
				m /= #q
				local s: number = 0
				for _, r in q do
					s += (r - m) * (r - m)
				end
				v[10] = math.sqrt(s / #q)
				o[10] = true
				v[12] = 1
			end
		end
	end
	o[11], o[12] = true, true
	v[13] = age
	o[13] = true
	return v, o
end

-- Five-value block for IWM or TLT at ctx.decisionTime.
function SupplementalFeatures.contextBlock(ctx: CausalContext, calendar: Types.Calendar, symbol: string): ({ number }, { boolean })
	local v = { 0, 0, 0, 0, 1 }
	local o = { false, false, false, true, true }
	local u = ctx:contextLatest(symbol)
	if u == nil then
		return v, o
	end
	local age = ctx.decisionTime - (u[T_] + 3600)
	if age > SupplementalFeatures.CONTEXT_MAX_AGE_SECONDS then
		return v, o
	end
	-- Only the predecessor exactly one hour earlier on the same NY date; never search further back.
	local pred = ctx:contextAt(symbol, u[T_] - 3600)
	if pred == nil or calendar:localTime(pred[T_]).dateKey ~= calendar:localTime(u[T_]).dateKey then
		return v, o
	end
	v[1] = math.log(u[CLOSE] / pred[CLOSE])
	v[2] = math.log(u[HIGH] / u[LOW])
	v[3] = math.log(1 + u[VOLUME])
	v[4] = 1
	v[5] = math.min(age, SupplementalFeatures.CONTEXT_MAX_AGE_SECONDS) / SupplementalFeatures.CONTEXT_MAX_AGE_SECONDS
	o[1], o[2], o[3] = true, true, true
	return v, o
end

type BuilderState = {
	cursor: ContextCursor.ContextCursor,
	calendar: Types.Calendar,
	lastT: number?,
	resumeAt: number?,
}

local Builder = {}
Builder.__index = Builder

export type Builder = typeof(setmetatable({} :: BuilderState, Builder))

export type Options = {
	-- Reconstruct rolling context as of this decision time by scanning only source records available by it.
	-- Later rows must have decisionTime >= resumeAt.
	resumeAt: number?,
}

function SupplementalFeatures.new(sources: ContextCursor.Sources, calendar: Types.Calendar, opts: Options?): Builder
	local cursor = ContextCursor.new(sources, calendar)
	local state: BuilderState = { cursor = cursor, calendar = calendar, lastT = nil, resumeAt = nil }
	if opts ~= nil and opts.resumeAt ~= nil then
		if not isFinite(opts.resumeAt) then
			fail("resumeAt must be a finite number")
		end
		cursor:advance(opts.resumeAt)
		state.resumeAt = opts.resumeAt
	end
	return setmetatable(state, Builder)
end

local function sameBar(a: Bar, b: Bar): boolean
	for f = 1, 8 do
		if a[f] ~= b[f] then
			return false
		end
	end
	return true
end

-- Emits the 50-value R50 row for pair. Pairs must arrive in strictly increasing t order (the shared O14/R50
-- stream); baseValues are the pair's 14 O14 values.
function Builder.row(self: Builder, pair: Pair, baseValues: { number }): FeatureRow
	if type(pair) ~= "table" or not isFinite(pair.t) then
		fail("pair.t must be a finite number")
	end
	if pair.decisionTime ~= pair.t + 3600 then
		fail("pair.decisionTime must equal pair.t + 3600")
	end
	if self.lastT ~= nil and pair.t <= self.lastT then
		fail("pairs must arrive in strictly increasing t order")
	end
	if self.resumeAt ~= nil and pair.decisionTime < self.resumeAt then
		fail("pair decision time precedes the resume point")
	end
	local lt = self.calendar:localTime(pair.t)
	if lt.dateKey ~= pair.dateKey or lt.hour ~= pair.hourNY or lt.dayNumber ~= pair.dayNumber then
		fail("pair dateKey/hourNY/dayNumber disagree with the calendar")
	end
	if type(baseValues) ~= "table" or #baseValues ~= SupplementalFeatures.BASE_DIMENSION then
		fail("baseValues must hold exactly 14 values")
	end
	for i = 1, SupplementalFeatures.BASE_DIMENSION do
		if not isFinite(baseValues[i]) then
			fail("baseValues position " .. i .. " is non-finite")
		end
	end

	local ctx = self.cursor:advance(pair.decisionTime)
	for _, sym in { "SPY", "QQQ" } do
		local native = ctx:hourlyAt(sym, pair.t)
		local bar = if sym == "SPY" then pair.spy else pair.qqq
		if native == nil or not sameBar(native, bar) then
			fail("pair " .. sym .. " bar at " .. tostring(pair.t) .. " disagrees with the native hourly source")
		end
	end

	local values: { number } = {}
	local observed: { boolean } = {}
	for i = 1, SupplementalFeatures.BASE_DIMENSION do
		values[i] = baseValues[i]
		observed[i] = true
	end
	local function append(v: { number }, o: { boolean })
		for i = 1, #v do
			table.insert(values, v[i])
			table.insert(observed, o[i])
		end
	end
	append(SupplementalFeatures.symbolBlock(ctx, "SPY", pair))
	append(SupplementalFeatures.symbolBlock(ctx, "QQQ", pair))
	append(SupplementalFeatures.contextBlock(ctx, self.calendar, "IWM"))
	append(SupplementalFeatures.contextBlock(ctx, self.calendar, "TLT"))
	if #values ~= SupplementalFeatures.DIMENSION or #observed ~= SupplementalFeatures.DIMENSION then
		fail("row dimension " .. #values .. " is not 50")
	end
	checkFinite(values, "row")
	self.lastT = pair.t
	local row: FeatureRow = {
		values = table.freeze(values) :: any,
		observed = table.freeze(observed) :: any,
		t = pair.t,
		decisionTime = pair.decisionTime,
		profileId = SupplementalFeatures.PROFILE_ID,
	}
	return table.freeze(row) :: any
end

-- Deep copy of the rolling context state (for resume verification and checkpoints).
function Builder.bufferSnapshot(self: Builder): any
	return self.cursor:snapshot()
end

return SupplementalFeatures
