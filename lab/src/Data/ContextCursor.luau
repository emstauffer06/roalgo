--!strict
-- Bounded as-of access to the supplemental source groups for R50 (plan Section 3 "Rich input contract for R50",
-- Section 7 "CausalContext"). Pure Luau: no engine globals.
--
-- ContextCursor.new(sources, calendar) validates and copies every source once (columnar, so later caller
-- mutation cannot reach it) and builds timestamp indices. cursor:advance(decisionTime) moves forward only and
-- returns a CausalContext that exposes ONLY rows whose availability time is <= decisionTime:
--   five-minute bar  available at start + 300
--   hourly bar       available at start + 3600 (own-symbol SPY/QQQ native hourly, and IWM/TLT context)
--   daily bar        available at calendar:nextMidnightAfter(NY date of the bar), never start + 86400
-- A CausalContext holds no data arrays; its accessors return frozen copies of single rows or small derived
-- lists, and it raises once the cursor has advanced again (stale context).
--
-- The same-hour volume history (R50 position 7) is a rolling buffer fed from every own-symbol native hourly
-- row as it becomes available, including pre-2021 combined rows and rows that never belong to a pair. It
-- depends only on which source rows are available by the current decision time, so it survives physical
-- segment resets, and a new cursor advanced to a resume time reconstructs it exactly from past records.
--
-- Invalid, duplicated, misaligned or out-of-order rows are audit errors raised at construction; they are never
-- turned into missingness.
local Types = require("../Types")

type Bar = Types.Bar
type Calendar = Types.Calendar

local MAX_SAME_HOUR_DATES = 20

export type Sources = {
	fiveMinute: { SPY: { Bar }, QQQ: { Bar } },
	hourly: { SPY: { Bar }, QQQ: { Bar } },
	daily: { SPY: { Bar }, QQQ: { Bar } },
	context: { IWM: { Bar }, TLT: { Bar } },
}

-- One completed daily bar with its New York identity and availability time.
export type DailyEntry = {
	bar: Bar,
	dateKey: number,
	dayNumber: number,
	availableAt: number,
}

-- As-of view at one decision time. Every accessor raises when used after the cursor advanced again.
export type CausalContext = {
	decisionTime: number,
	-- Five-minute bar of SPY/QQQ starting exactly at `start`, if it exists and start + 300 <= decisionTime.
	fiveMinuteAt: (self: CausalContext, symbol: string, start: number) -> Bar?,
	-- Own-symbol native hourly bar of SPY/QQQ starting exactly at `start`, if start + 3600 <= decisionTime.
	hourlyAt: (self: CausalContext, symbol: string, start: number) -> Bar?,
	-- ln(1 + V) of the latest available bar at New York hour `hourNY` on each of up to the twenty most recent
	-- NY dates strictly before currentDateKey, oldest first. One value per date (the later bar of a repeated
	-- DST fall-back hour). currentDateKey must not precede the date of any available hourly row.
	sameHourHistory: (self: CausalContext, symbol: string, hourNY: number, currentDateKey: number) -> { number },
	-- Up to maxCount most recent available daily bars of SPY/QQQ whose NY date is strictly before
	-- beforeDateKey, oldest first.
	dailyHistory: (self: CausalContext, symbol: string, beforeDateKey: number, maxCount: number) -> { DailyEntry },
	-- Latest IWM/TLT hourly bar u with u + 3600 <= decisionTime.
	contextLatest: (self: CausalContext, symbol: string) -> Bar?,
	-- IWM/TLT hourly bar starting exactly at `start`, if start + 3600 <= decisionTime.
	contextAt: (self: CausalContext, symbol: string, start: number) -> Bar?,
}

type Series = {
	label: string,
	count: number,
	t: { number },
	o: { number },
	h: { number },
	l: { number },
	c: { number },
	v: { number },
	n: { number },
	w: { number },
	index: { [number]: number },
	-- daily only
	dateKey: { number }?,
	dayNumber: { number }?,
	availableAt: { number }?,
}

type HourBuffer = { dates: { number }, values: { number } }

type CursorState = {
	calendar: Calendar,
	fiveMinute: { [string]: Series },
	hourly: { [string]: Series },
	daily: { [string]: Series },
	context: { [string]: Series },
	decisionTime: number?,
	generation: number,
	hourlyPtr: { [string]: number },
	dailyPtr: { [string]: number },
	contextPtr: { [string]: number },
	sameHour: { [string]: { [number]: HourBuffer } },
	lastHourlyDate: { [string]: number },
}

local ContextCursor = {}
ContextCursor.__index = ContextCursor

export type ContextCursor = typeof(setmetatable({} :: CursorState, ContextCursor))

ContextCursor.FIVE_MINUTE_SECONDS = 300
ContextCursor.HOUR_SECONDS = 3600
ContextCursor.MAX_SAME_HOUR_DATES = MAX_SAME_HOUR_DATES

local function fail(msg: string): never
	error("ContextCursor: " .. msg, 3)
end

-- Preallocated numeric array (typed wrapper around table.create).
local function numbers(n: number): { number }
	return table.create(n) :: any
end

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- Validates one source array and copies it into columns. grid > 0 requires t % grid == 0.
local function loadSeries(label: string, rows: any, grid: number): Series
	if type(rows) ~= "table" then
		fail("sources." .. label .. " must be an array of bars")
	end
	local count = #rows
	for k in rows do
		if type(k) ~= "number" or k < 1 or k > count or k ~= math.floor(k) then
			fail("sources." .. label .. " must be a dense array of bars")
		end
	end
	local s: Series = {
		label = label,
		count = count,
		t = numbers(count),
		o = numbers(count),
		h = numbers(count),
		l = numbers(count),
		c = numbers(count),
		v = numbers(count),
		n = numbers(count),
		w = numbers(count),
		index = {},
	}
	local prevT = -math.huge
	for i = 1, count do
		local r = rows[i]
		local where = label .. " row " .. i
		if type(r) ~= "table" then
			fail(where .. " is not a bar")
		end
		if #r ~= 8 then
			fail(string.format("%s has %d fields; expected 8 fields", where, #r))
		end
		for f = 1, 8 do
			if not isFinite(r[f]) then
				fail(where .. " field " .. f .. " is non-finite or not a number")
			end
		end
		local t, o, h, l, c, v, n, w = r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]
		if t ~= math.floor(t) then
			fail(where .. " timestamp is not an integer")
		end
		if grid > 0 and t % grid ~= 0 then
			fail(where .. " timestamp " .. tostring(t) .. " is not aligned to " .. grid .. " s")
		end
		if t <= prevT then
			fail(where .. " timestamp " .. tostring(t) .. " is not strictly increasing (duplicate or out of order)")
		end
		if o <= 0 or h <= 0 or l <= 0 or c <= 0 or w <= 0 then
			fail(where .. " has a nonpositive price or vwap")
		end
		if h < l then
			fail(where .. " has high below low")
		end
		if o < l or o > h or c < l or c > h then
			fail(where .. " has open/close outside [low, high]")
		end
		if v < 0 then
			fail(where .. " has negative volume")
		end
		if n < 0 then
			fail(where .. " has negative trade count")
		end
		prevT = t
		s.t[i], s.o[i], s.h[i], s.l[i], s.c[i], s.v[i], s.n[i], s.w[i] = t, o, h, l, c, v, n, w
		s.index[t] = i
	end
	return s
end

local function addDailyIdentity(s: Series, calendar: Calendar)
	local dateKeys, dayNumbers, avail = numbers(s.count), numbers(s.count), numbers(s.count)
	local prevKey, prevAvail = -math.huge, -math.huge
	for i = 1, s.count do
		local lt = calendar:localTime(s.t[i])
		if lt.hour ~= 0 or lt.minute ~= 0 then
			fail(s.label .. " row " .. i .. " does not start at New York midnight")
		end
		if lt.dateKey <= prevKey then
			fail(s.label .. " row " .. i .. " repeats or reorders a New York date")
		end
		local a = calendar:nextMidnightAfter(lt.dateKey)
		if not isFinite(a) or a <= s.t[i] or a <= prevAvail then
			fail(s.label .. " row " .. i .. " has an invalid availability time from the calendar")
		end
		dateKeys[i], dayNumbers[i], avail[i] = lt.dateKey, lt.dayNumber, a
		prevKey, prevAvail = lt.dateKey, a
	end
	s.dateKey, s.dayNumber, s.availableAt = dateKeys, dayNumbers, avail
end

local function group(sources: any, name: string, symbols: { string }, grid: number): { [string]: Series }
	local g = sources[name]
	if type(g) ~= "table" then
		fail("sources." .. name .. " is missing")
	end
	local out = {}
	for _, sym in symbols do
		out[sym] = loadSeries(name .. "." .. sym, g[sym], grid)
	end
	return out
end

local function rowOf(s: Series, i: number): Bar
	return table.freeze({ s.t[i], s.o[i], s.h[i], s.l[i], s.c[i], s.v[i], s.n[i], s.w[i] })
end

function ContextCursor.new(sources: Sources, calendar: Calendar): ContextCursor
	if type(sources) ~= "table" then
		fail("sources must be a table")
	end
	local cal: any = calendar
	if type(cal) ~= "table" or type(cal.localTime) ~= "function" or type(cal.nextMidnightAfter) ~= "function" then
		fail("calendar must implement Types.Calendar (localTime, nextMidnightAfter)")
	end
	local state: CursorState = {
		calendar = calendar,
		fiveMinute = group(sources, "fiveMinute", { "SPY", "QQQ" }, 300),
		hourly = group(sources, "hourly", { "SPY", "QQQ" }, 3600),
		daily = group(sources, "daily", { "SPY", "QQQ" }, 0),
		context = group(sources, "context", { "IWM", "TLT" }, 3600),
		decisionTime = nil,
		generation = 0,
		hourlyPtr = { SPY = 0, QQQ = 0 },
		dailyPtr = { SPY = 0, QQQ = 0 },
		contextPtr = { IWM = 0, TLT = 0 },
		sameHour = { SPY = {}, QQQ = {} },
		lastHourlyDate = {},
	}
	addDailyIdentity(state.daily.SPY, calendar)
	addDailyIdentity(state.daily.QQQ, calendar)
	return setmetatable(state, ContextCursor)
end

-- Adds one newly available own-symbol hourly row to the same-hour buffers.
local function pushSameHour(self: ContextCursor, symbol: string, s: Series, i: number)
	local lt = self.calendar:localTime(s.t[i])
	local buffers = self.sameHour[symbol]
	local buf = buffers[lt.hour]
	if buf == nil then
		buf = { dates = {}, values = {} }
		buffers[lt.hour] = buf
	end
	local value = math.log(1 + s.v[i])
	local n = #buf.dates
	if n > 0 and buf.dates[n] == lt.dateKey then
		buf.values[n] = value -- repeated NY date-hour (DST fall-back): keep the later bar
	elseif n > 0 and buf.dates[n] > lt.dateKey then
		fail("hourly." .. symbol .. " New York dates went backwards")
	else
		table.insert(buf.dates, lt.dateKey)
		table.insert(buf.values, value)
		-- Twenty earlier dates plus at most one entry for the current date.
		if #buf.dates > MAX_SAME_HOUR_DATES + 1 then
			table.remove(buf.dates, 1)
			table.remove(buf.values, 1)
		end
	end
	local last = self.lastHourlyDate[symbol]
	if last == nil or lt.dateKey > last then
		self.lastHourlyDate[symbol] = lt.dateKey
	end
end

local function checkSymbol(map: { [string]: any }, symbol: any, what: string)
	if type(symbol) ~= "string" or map[symbol] == nil then
		fail("unknown " .. what .. " symbol " .. tostring(symbol))
	end
end

-- Moves the cursor forward to decisionTime and returns the as-of context for it.
function ContextCursor.advance(self: ContextCursor, decisionTime: number): CausalContext
	if not isFinite(decisionTime) then
		fail("decisionTime must be a finite number")
	end
	local prev = self.decisionTime
	if prev ~= nil and decisionTime < prev then
		fail(string.format("advance went backwards from %.17g to %.17g", prev, decisionTime))
	end
	local T = decisionTime
	for _, sym in { "SPY", "QQQ" } do
		local hs = self.hourly[sym]
		local p = self.hourlyPtr[sym]
		while p < hs.count and hs.t[p + 1] + 3600 <= T do
			p += 1
			pushSameHour(self, sym, hs, p)
		end
		self.hourlyPtr[sym] = p
		local ds = self.daily[sym]
		local avail = ds.availableAt :: { number }
		local d = self.dailyPtr[sym]
		while d < ds.count and avail[d + 1] <= T do
			d += 1
		end
		self.dailyPtr[sym] = d
	end
	for _, sym in { "IWM", "TLT" } do
		local cs = self.context[sym]
		local p = self.contextPtr[sym]
		while p < cs.count and cs.t[p + 1] + 3600 <= T do
			p += 1
		end
		self.contextPtr[sym] = p
	end
	self.decisionTime = T
	self.generation += 1
	local generation = self.generation
	local cursor = self

	local function live()
		if cursor.generation ~= generation then
			fail("stale CausalContext: the cursor has advanced since it was created")
		end
	end

	local ctx = {
		decisionTime = T,
		fiveMinuteAt = function(_: any, symbol: string, start: number): Bar?
			live()
			checkSymbol(cursor.fiveMinute, symbol, "five-minute")
			local s = cursor.fiveMinute[symbol]
			local i = s.index[start]
			if i ~= nil and s.t[i] + 300 <= T then
				return rowOf(s, i)
			end
			return nil
		end,
		hourlyAt = function(_: any, symbol: string, start: number): Bar?
			live()
			checkSymbol(cursor.hourly, symbol, "hourly")
			local s = cursor.hourly[symbol]
			local i = s.index[start]
			if i ~= nil and s.t[i] + 3600 <= T then
				return rowOf(s, i)
			end
			return nil
		end,
		sameHourHistory = function(_: any, symbol: string, hourNY: number, currentDateKey: number): { number }
			live()
			checkSymbol(cursor.sameHour, symbol, "hourly")
			local last = cursor.lastHourlyDate[symbol]
			if last ~= nil and currentDateKey < last then
				fail("sameHourHistory: currentDateKey precedes an available hourly row's date")
			end
			local buf = cursor.sameHour[symbol][hourNY]
			local out = {}
			if buf == nil then
				return out
			end
			local hi = #buf.dates
			while hi > 0 and buf.dates[hi] >= currentDateKey do
				hi -= 1
			end
			for i = math.max(1, hi - MAX_SAME_HOUR_DATES + 1), hi do
				table.insert(out, buf.values[i])
			end
			return out
		end,
		dailyHistory = function(_: any, symbol: string, beforeDateKey: number, maxCount: number): { DailyEntry }
			live()
			checkSymbol(cursor.daily, symbol, "daily")
			local s = cursor.daily[symbol]
			local keys = s.dateKey :: { number }
			local days = s.dayNumber :: { number }
			local avail = s.availableAt :: { number }
			local picked = {}
			local i = cursor.dailyPtr[symbol]
			while i >= 1 and #picked < maxCount do
				if keys[i] < beforeDateKey then
					table.insert(picked, i)
				end
				i -= 1
			end
			local out: { DailyEntry } = {}
			for k = #picked, 1, -1 do
				local j = picked[k]
				local entry: DailyEntry = { bar = rowOf(s, j), dateKey = keys[j], dayNumber = days[j], availableAt = avail[j] }
				table.insert(out, table.freeze(entry) :: any)
			end
			return out
		end,
		contextLatest = function(_: any, symbol: string): Bar?
			live()
			checkSymbol(cursor.context, symbol, "context")
			local p = cursor.contextPtr[symbol]
			if p > 0 then
				return rowOf(cursor.context[symbol], p)
			end
			return nil
		end,
		contextAt = function(_: any, symbol: string, start: number): Bar?
			live()
			checkSymbol(cursor.context, symbol, "context")
			local s = cursor.context[symbol]
			local i = s.index[start]
			if i ~= nil and s.t[i] + 3600 <= T then
				return rowOf(s, i)
			end
			return nil
		end,
	}
	return (table.freeze(ctx) :: any) :: CausalContext
end

-- Deep copy of the rolling state (decision time, per-source positions, same-hour buffers). Two cursors that
-- reached the same decision time over the same sources have equal snapshots, however they got there.
function ContextCursor.snapshot(self: ContextCursor): any
	local sameHour = {}
	for sym, hours in self.sameHour do
		local copy = {}
		for hour, buf in hours do
			copy[hour] = { dates = table.clone(buf.dates), values = table.clone(buf.values) }
		end
		sameHour[sym] = copy
	end
	return {
		decisionTime = self.decisionTime,
		hourlyPtr = table.clone(self.hourlyPtr),
		dailyPtr = table.clone(self.dailyPtr),
		contextPtr = table.clone(self.contextPtr),
		sameHour = sameHour,
		lastHourlyDate = table.clone(self.lastHourlyDate),
	}
end

return ContextCursor
