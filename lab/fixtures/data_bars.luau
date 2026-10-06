--!strict
-- Synthetic hourly bar fixtures for Data.spec and Features.spec (plan Task 2). Every builder returns fresh
-- tables, so a spec may mutate what it receives. Bars use the Types.Bar layout:
--   {timestamp_unix, open, high, low, close, volume, trade_count, vwap}
-- All timestamps are real New York dates; the values are synthetic, never market data.

local HOUR = 3600

local Fixtures = {}

Fixtures.HOUR = HOUR
-- 2024-01-02T09:00:00Z = 04:00 New York (EST). Bars T0 .. T0+12h are 04:00 .. 16:00 on 2024-01-02.
Fixtures.T0 = 1704186000
-- 2024-01-02T21:00:00Z = 16:00 New York. Bars EVENING_T0 .. +12h run 16:00 on 01-02 to 04:00 on 01-03.
Fixtures.EVENING_T0 = 1704229200

function Fixtures.makeBar(t: number, close: number): { number }
	return { t, close, close, close, close, 100, 10, close }
end

function Fixtures.bar(t: number, o: number, h: number, l: number, c: number, v: number, n: number, vwap: number): { number }
	return { t, o, h, l, c, v, n, vwap }
end

-- The plan's target fixture: bars i = 0..12 at T0 + i*3600 with close exp(i*0.001). skip lists 1-based
-- positions (in the full 13-bar run) to leave out.
function Fixtures.targetBars(skip: { number }?): { { number } }
	local omit = {}
	for _, k in skip or {} do
		omit[k] = true
	end
	local bars = {}
	for i = 0, 12 do
		if not omit[i + 1] then
			table.insert(bars, Fixtures.makeBar(Fixtures.T0 + i * HOUR, math.exp(i * 0.001)))
		end
	end
	return bars
end

-- n consecutive hourly bars from t0 with close = base * exp(step * i).
function Fixtures.hourlyRun(t0: number, n: number, base: number?, step: number?): { { number } }
	local b, s = base or 100, step or 0.001
	local bars = {}
	for i = 0, n - 1 do
		table.insert(bars, Fixtures.makeBar(t0 + i * HOUR, b * math.exp(s * i)))
	end
	return bars
end

-- Deep copy of a bar list.
function Fixtures.copy(bars: { { number } }): { { number } }
	local out = {}
	for i, b in bars do
		out[i] = table.clone(b)
	end
	return out
end

-- Production split boundaries (section 2.4), duplicated here as literals so a config edit cannot silently
-- change what the fixtures assert.
Fixtures.SPLITS = table.freeze({
	validationStart = 1704085200, -- 2024-01-01T05:00:00Z
	testStart = 1735707600, -- 2025-01-01T05:00:00Z
	datasetEnd = 1791000000, -- 2026-10-03T04:00:00Z
})

return Fixtures
