--!strict
-- Fixture-only America/New_York calendar for Context.spec. NOT the production Calendar.
-- Implements Types.Calendar from a hard-coded table of real New York UTC-offset transitions, copied from
-- Node 24 Intl.DateTimeFormat("en-US", {timeZone = "America/New_York"}) on 2026-10-05 for 2015-2026.
-- Instants outside the table raise an error so a fixture can never silently use a guessed offset.
local Types = require("../src/Types")

-- {UTC instant at which the offset starts, offset seconds (New York minus UTC)}
local TRANSITIONS: { { number } } = {
	{ 1425798000, -14400 }, -- 2015-03-08T07:00:00Z
	{ 1446357600, -18000 }, -- 2015-11-01T06:00:00Z
	{ 1457852400, -14400 }, -- 2016-03-13T07:00:00Z
	{ 1478412000, -18000 }, -- 2016-11-06T06:00:00Z
	{ 1489302000, -14400 }, -- 2017-03-12T07:00:00Z
	{ 1509861600, -18000 }, -- 2017-11-05T06:00:00Z
	{ 1520751600, -14400 }, -- 2018-03-11T07:00:00Z
	{ 1541311200, -18000 }, -- 2018-11-04T06:00:00Z
	{ 1552201200, -14400 }, -- 2019-03-10T07:00:00Z
	{ 1572760800, -18000 }, -- 2019-11-03T06:00:00Z
	{ 1583650800, -14400 }, -- 2020-03-08T07:00:00Z
	{ 1604210400, -18000 }, -- 2020-11-01T06:00:00Z
	{ 1615705200, -14400 }, -- 2021-03-14T07:00:00Z
	{ 1636264800, -18000 }, -- 2021-11-07T06:00:00Z
	{ 1647154800, -14400 }, -- 2022-03-13T07:00:00Z
	{ 1667714400, -18000 }, -- 2022-11-06T06:00:00Z
	{ 1678604400, -14400 }, -- 2023-03-12T07:00:00Z
	{ 1699164000, -18000 }, -- 2023-11-05T06:00:00Z
	{ 1710054000, -14400 }, -- 2024-03-10T07:00:00Z
	{ 1730613600, -18000 }, -- 2024-11-03T06:00:00Z
	{ 1741503600, -14400 }, -- 2025-03-09T07:00:00Z
	{ 1762063200, -18000 }, -- 2025-11-02T06:00:00Z
	{ 1772953200, -14400 }, -- 2026-03-08T07:00:00Z
	{ 1793512800, -18000 }, -- 2026-11-01T06:00:00Z
}
local OFFSET_AT_RANGE_START = -18000 -- EST on 2015-01-01
local RANGE_START = 1420070400 -- 2015-01-01T00:00:00Z
local RANGE_END = 1798761600 -- 2027-01-01T00:00:00Z

local function offsetAt(t: number): number
	if t < RANGE_START or t >= RANGE_END then
		error("ContextCalendar: instant " .. tostring(t) .. " is outside the fixture DST table", 3)
	end
	local off = OFFSET_AT_RANGE_START
	for _, tr in TRANSITIONS do
		if t >= tr[1] then
			off = tr[2]
		else
			break
		end
	end
	return off
end

-- Proleptic Gregorian day arithmetic (H. Hinnant's days_from_civil / civil_from_days).
local function daysFromCivil(y: number, m: number, d: number): number
	local yy = if m <= 2 then y - 1 else y
	local era = (if yy >= 0 then yy else yy - 399) // 400
	local yoe = yy - era * 400
	local mp = (m + 9) % 12
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z0: number): (number, number, number)
	local z = z0 + 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return (if m <= 2 then y + 1 else y), m, d
end

local function splitDateKey(dateKey: number): (number, number, number)
	local y, m, d = dateKey // 10000, (dateKey // 100) % 100, dateKey % 100
	local day = daysFromCivil(y, m, d)
	local y2, m2, d2 = civilFromDays(day)
	if y2 ~= y or m2 ~= m or d2 ~= d then
		error("ContextCalendar: invalid dateKey " .. tostring(dateKey), 3)
	end
	return y, m, d
end

local Calendar = {}
Calendar.__index = Calendar

function Calendar.localTime(_self: any, t: number): Types.LocalTime
	local off = offsetAt(t)
	local localSeconds = t + off
	local dayNumber = localSeconds // 86400
	local sod = localSeconds - dayNumber * 86400
	local y, m, d = civilFromDays(dayNumber)
	return {
		dateKey = y * 10000 + m * 100 + d,
		dayNumber = dayNumber,
		hour = sod // 3600,
		minute = (sod % 3600) // 60,
		offsetSeconds = off,
	}
end

-- UTC seconds of a New York wall-clock time. Raises on a nonexistent wall time; an ambiguous (fall-back)
-- wall time needs preferOffset (-14400 for the first, EDT occurrence; -18000 for the second, EST one).
local function nyToUtc(y: number, m: number, d: number, h: number, mi: number, preferOffset: number?): number
	local localSeconds = daysFromCivil(y, m, d) * 86400 + h * 3600 + mi * 60
	local matches = {}
	for _, off in { -14400, -18000 } do
		local u = localSeconds - off
		if offsetAt(u) == off then
			table.insert(matches, u)
			if preferOffset == off then
				return u
			end
		end
	end
	if #matches ~= 1 then
		error(string.format("ContextCalendar: wall time %04d-%02d-%02d %02d:%02d has %d UTC matches", y, m, d, h, mi, #matches), 2)
	end
	return matches[1]
end

function Calendar.nextMidnightAfter(_self: any, dateKey: number): number
	local y, m, d = splitDateKey(dateKey)
	local y2, m2, d2 = civilFromDays(daysFromCivil(y, m, d) + 1)
	return nyToUtc(y2, m2, d2, 0, 0)
end

function Calendar.dateString(_self: any, dateKey: number): string
	local y, m, d = splitDateKey(dateKey)
	return string.format("%04d-%02d-%02d", y, m, d)
end

local M = {}

function M.new(): Types.Calendar
	return (setmetatable({}, Calendar) :: any) :: Types.Calendar
end

-- UTC seconds for a UTC wall time.
function M.utc(y: number, m: number, d: number, h: number?, mi: number?): number
	return daysFromCivil(y, m, d) * 86400 + (h or 0) * 3600 + (mi or 0) * 60
end

-- UTC seconds for a New York wall time (see nyToUtc for preferOffset).
function M.ny(y: number, m: number, d: number, h: number?, mi: number?, preferOffset: number?): number
	return nyToUtc(y, m, d, h or 0, mi or 0, preferOffset)
end

M.daysFromCivil = daysFromCivil
M.civilFromDays = civilFromDays

return M
