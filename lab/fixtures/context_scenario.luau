--!strict
-- Multi-day synthetic scenario for builder-level Context tests (resume, future invariance, physical resets).
-- Deterministic closed-form prices; synthetic only. Crosses the 2024-03-10 DST change.
local Types = require("../src/Types")
local CalFixture = require("./context_calendar")
local B = require("./context_bars")

type Bar = Types.Bar

local S = {}

local SYMBOLS: { [string]: { base: number, phase: number } } = {
	SPY = { base = 500, phase = 0.0 },
	QQQ = { base = 430, phase = 1.3 },
	IWM = { base = 200, phase = 2.1 },
	TLT = { base = 95, phase = 0.7 },
}

local function price(symbol: string, t: number): number
	local cfg = SYMBOLS[symbol]
	return cfg.base * math.exp(0.01 * math.sin(t / 9000 + cfg.phase) + 0.004 * math.sin(t / 1700 + 2 * cfg.phase))
end

type Day = { y: number, m: number, d: number, wd: number, day: number }

-- Weekdays (wd: 1 = Monday .. 5 = Friday) between two dates inclusive.
function S.weekdays(y1: number, m1: number, d1: number, y2: number, m2: number, d2: number): { Day }
	local out: { Day } = {}
	for day = CalFixture.daysFromCivil(y1, m1, d1), CalFixture.daysFromCivil(y2, m2, d2) do
		local wd = (day + 4) % 7 -- 1970-01-01 was a Thursday; 0 = Sunday
		if wd ~= 0 and wd ~= 6 then
			local y, m, d = CalFixture.civilFromDays(day)
			table.insert(out, { y = y, m = m, d = d, wd = wd, day = day })
		end
	end
	return out
end

local function hourBar(symbol: string, t: number, volume: number): Bar
	local o, c = price(symbol, t), price(symbol, t + 3600)
	return B.bar(t, o, math.max(o, c) * 1.001, math.min(o, c) * 0.999, c, volume, 100, (o + c) / 2)
end

-- Returns sources, pairs, pairStart. Hourly rows start a week before the pair stream (like the 2016-2021
-- combined rows before the original 2021 stream), so same-hour history exists before the first pair.
function S.build(calendar: Types.Calendar): (any, { Types.Pair }, number)
	local src = B.emptySources()
	local days = S.weekdays(2024, 2, 19, 2024, 3, 15)
	for di, D in days do
		for h = 4, 19 do
			local t = CalFixture.ny(D.y, D.m, D.d, h, 0)
			for _, sym in { "SPY", "QQQ" } do
				local skip = sym == "QQQ" and ((D.wd == 1 and h == 4) or (D.m == 3 and D.d == 6 and h == 12))
				if not skip then
					local v = 5000 + ((t // 3600) % 11) * 311 + h * 13 + (if sym == "QQQ" then 7 else 0)
					table.insert(src.hourly[sym], hourBar(sym, t, v))
					if not (D.wd == 5 and h == 19) then -- Friday 19:00 hours have no five-minute children
						for j = 0, 11 do
							if (h * 7 + j + di) % 29 ~= 0 then -- a rotating missing child gives partial hours
								local s = t + 300 * j
								local co = price(sym, s) * (1 + 0.0002 * math.sin(j + di))
								local cc = price(sym, s + 300)
								table.insert(src.fiveMinute[sym], B.oc(s, co, cc, 100 + ((s // 300) % 13) * 37))
							end
						end
					end
				end
			end
			if not (D.wd == 3 and h == 9) then
				table.insert(src.context.IWM, hourBar("IWM", t, 2000 + h))
			end
			if h >= 7 and h <= 17 and not (D.wd == 2 and h == 11) then
				table.insert(src.context.TLT, hourBar("TLT", t, 900 + h))
			end
		end
	end
	for _, D in S.weekdays(2024, 2, 1, 2024, 3, 15) do
		local t = CalFixture.ny(D.y, D.m, D.d, 0, 0)
		for _, sym in { "SPY", "QQQ" } do
			local o, c = price(sym, t + 34200), price(sym, t + 57600)
			table.insert(src.daily[sym], B.bar(t, o, math.max(o, c) * 1.002, math.min(o, c) * 0.998, c, 1e7 + D.day, 1000, (o + c) / 2))
		end
	end
	local pairStart = CalFixture.ny(2024, 2, 26, 0, 0)
	return src, B.pairsFrom(calendar, src.hourly.SPY, src.hourly.QQQ, pairStart), pairStart
end

local function scaled(row: Bar): Bar
	local r = table.clone(row)
	for _, k in { 2, 3, 4, 5, 8 } do
		r[k] = r[k] * 1.5
	end
	r[6] = r[6] * 3 + 1
	return r
end

-- Deep copy of sources in which every row that becomes available after cutT is radically changed:
-- prices x1.5 and volume x3+1, and every not-yet-available TLT row is deleted.
function S.mutateAfter(sources: any, calendar: Types.Calendar, cutT: number): any
	local out = B.deepCopy(sources)
	local function each(rows: { Bar }, availability: (Bar) -> number)
		for i, r in rows do
			if availability(r) > cutT then
				rows[i] = scaled(r)
			end
		end
	end
	for _, sym in { "SPY", "QQQ" } do
		each(out.fiveMinute[sym], function(r) return r[1] + 300 end)
		each(out.hourly[sym], function(r) return r[1] + 3600 end)
		each(out.daily[sym], function(r) return calendar:nextMidnightAfter(calendar:localTime(r[1]).dateKey) end)
	end
	each(out.context.IWM, function(r) return r[1] + 3600 end)
	local kept = {}
	for _, r in out.context.TLT do
		if r[1] + 3600 <= cutT then
			table.insert(kept, r)
		end
	end
	out.context.TLT = kept
	return out
end

return S
