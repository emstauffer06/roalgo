--!strict
-- Synthetic bar/pair helpers for Context.spec. Synthetic values only; no real market data.
local Types = require("../src/Types")

type Bar = Types.Bar

local B = {}

function B.bar(t: number, o: number, h: number, l: number, c: number, v: number, n: number?, w: number?): Bar
	return { t, o, h, l, c, v, n or 1, w or c }
end

-- A valid bar from open/close: high/low are the open/close extremes, vwap their midpoint.
function B.oc(t: number, o: number, c: number, v: number): Bar
	return { t, o, math.max(o, c), math.min(o, c), c, v, 1, (o + c) / 2 }
end

function B.flat(t: number, p: number, v: number?): Bar
	return { t, p, p, p, p, v or 100, 1, p }
end

function B.emptySources(): any
	return {
		fiveMinute = { SPY = {}, QQQ = {} },
		hourly = { SPY = {}, QQQ = {} },
		daily = { SPY = {}, QQQ = {} },
		context = { IWM = {}, TLT = {} },
	}
end

function B.deepCopy(x: any): any
	if type(x) ~= "table" then
		return x
	end
	local out = {}
	for k, v in x do
		out[k] = B.deepCopy(v)
	end
	return out
end

-- Twelve five-minute children of the hour starting at hourStart. opens/closes/volumes are indexed j+1
-- (j = 0..11); omit is a set of 0-based j to leave out.
function B.children(hourStart: number, opens: { number }, closes: { number }, volumes: { number }, omit: { [number]: boolean }?): { Bar }
	local rows = {}
	for j = 0, 11 do
		if not (omit and omit[j]) then
			table.insert(rows, B.oc(hourStart + 300 * j, opens[j + 1], closes[j + 1], volumes[j + 1]))
		end
	end
	return rows
end

function B.sortByT(rows: { Bar }): { Bar }
	table.sort(rows, function(a: Bar, b: Bar): boolean
		return a[1] < b[1]
	end)
	return rows
end

function B.pair(calendar: Types.Calendar, index: number, t: number, spy: Bar, qqq: Bar, segmentId: number?, segmentOffset: number?): Types.Pair
	local lt = calendar:localTime(t)
	return {
		index = index,
		t = t,
		decisionTime = t + 3600,
		dateNY = calendar:dateString(lt.dateKey),
		dateKey = lt.dateKey,
		dayNumber = lt.dayNumber,
		hourNY = lt.hour,
		segmentId = segmentId or 1,
		segmentOffset = segmentOffset or 1,
		spy = spy,
		qqq = qqq,
	}
end

-- Paired stream: timestamps present in both hourly series at or after fromT, with the plan's segment rule
-- (new segment on the first pair, a New York date change, or a delta other than 3600 s).
function B.pairsFrom(calendar: Types.Calendar, spyRows: { Bar }, qqqRows: { Bar }, fromT: number?): { Types.Pair }
	local q: { [number]: Bar } = {}
	for _, r in qqqRows do
		q[r[1]] = r
	end
	local out: { Types.Pair } = {}
	local segmentId, segmentOffset = 0, 0
	local prev: Types.Pair? = nil
	for _, s in spyRows do
		local t = s[1]
		local qq = q[t]
		if qq and (fromT == nil or t >= fromT) then
			local p = B.pair(calendar, #out + 1, t, s, qq)
			if prev == nil or prev.dateKey ~= p.dateKey or t - prev.t ~= 3600 then
				segmentId += 1
				segmentOffset = 1
			else
				segmentOffset += 1
			end
			p.segmentId = segmentId
			p.segmentOffset = segmentOffset
			table.insert(out, p)
			prev = p
		end
	end
	return out
end

-- Fourteen finite placeholder base values (the real O14 vector comes from Features.compute).
function B.base14(k: number): { number }
	local v = {}
	for i = 1, 14 do
		v[i] = math.sin(k * 0.37 + i) * 0.5
	end
	return v
end

return B
