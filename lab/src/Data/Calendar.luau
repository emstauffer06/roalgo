--!strict
-- New York calendar facts from a generated UTC-offset table (plan sections 3 and 2.2).
--
-- The table comes from lab/generated/NyOffsets.luau, written by tools/prepare-lab.mjs with Node
-- Intl.DateTimeFormat(timeZone = "America/New_York"). No fixed offset or DST rule is coded here: localTime
-- binary-searches the table for the offset in force at t, then converts days to a civil date with the
-- proleptic-Gregorian days_from_civil / civil_from_days arithmetic (Howard Hinnant's algorithms).
--
-- Calendar.new(transitions, options?) accepts any sorted list of {utcStartSeconds, offsetSeconds}; an
-- instant before the first entry, or at/after options.coverageEnd, is an error, never a guessed offset.
local Types = require("../Types")

type LocalTime = Types.LocalTime
type Transition = { utcStartSeconds: number, offsetSeconds: number }

local SECONDS_PER_DAY = 86400

export type Calendar = Types.Calendar & {
	coverageStart: number,
	coverageEnd: number,
	zone: string,
}

local Calendar = {}
Calendar.__index = Calendar

local function fail(msg: string): never
	error("Calendar: " .. msg, 3)
end

local function isInteger(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge and x == math.floor(x)
end

-- Days since 1970-01-01 of a proleptic-Gregorian civil date.
local function daysFromCivil(y: number, m: number, d: number): number
	local yy = if m <= 2 then y - 1 else y
	local era = yy // 400
	local yoe = yy - era * 400
	local mp = (m + 9) % 12 -- March = 0 .. February = 11
	local doy = (153 * mp + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(days: number): (number, number, number)
	local z = days + 719468
	local era = z // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	local y = yoe + era * 400 + (if m <= 2 then 1 else 0)
	return y, m, d
end

-- Splits and validates a yyyymmdd key; returns its day number.
local function dayNumberOfKey(dateKey: any): number
	if not isInteger(dateKey) or dateKey <= 0 then
		fail("invalid date key " .. tostring(dateKey))
	end
	local y = dateKey // 10000
	local m = (dateKey // 100) % 100
	local d = dateKey % 100
	if m < 1 or m > 12 or d < 1 or d > 31 then
		fail("invalid date " .. tostring(dateKey))
	end
	local days = daysFromCivil(y, m, d)
	local y2, m2, d2 = civilFromDays(days)
	if y2 ~= y or m2 ~= m or d2 ~= d then
		fail("invalid date " .. tostring(dateKey))
	end
	return days
end

local function keyOfDays(days: number): number
	local y, m, d = civilFromDays(days)
	return y * 10000 + m * 100 + d
end

-- Static helpers (no table needed).
function Calendar.dayNumberOf(dateKey: number): number
	return dayNumberOfKey(dateKey)
end

function Calendar.dateKeyOf(dayNumber: number): number
	if not isInteger(dayNumber) then
		fail("dayNumber must be an integer")
	end
	return keyOfDays(dayNumber)
end

function Calendar.new(transitions: { Transition }, options: { coverageEnd: number?, zone: string? }?): Calendar
	if type(transitions) ~= "table" or #transitions == 0 then
		fail("transitions must be a non-empty array")
	end
	local starts = table.create(#transitions) :: { number }
	local offsets = table.create(#transitions) :: { number }
	for i, tr in transitions do
		if type(tr) ~= "table" or not isInteger(tr.utcStartSeconds) or not isInteger(tr.offsetSeconds) then
			fail("transition " .. i .. " must have integer utcStartSeconds and offsetSeconds")
		end
		if math.abs(tr.offsetSeconds) >= SECONDS_PER_DAY then
			fail("transition " .. i .. " offset out of range")
		end
		if i > 1 and tr.utcStartSeconds <= starts[i - 1] then
			fail("transition utcStartSeconds must be strictly increasing")
		end
		starts[i] = tr.utcStartSeconds
		offsets[i] = tr.offsetSeconds
	end
	local opts: { coverageEnd: number?, zone: string? } = options or {}
	local coverageEnd = opts.coverageEnd or math.huge
	if coverageEnd ~= math.huge and (not isInteger(coverageEnd) or coverageEnd <= starts[#starts]) then
		fail("coverageEnd must be an integer after the last transition")
	end
	local self = setmetatable({
		_starts = table.freeze(starts),
		_offsets = table.freeze(offsets),
		coverageStart = starts[1],
		coverageEnd = coverageEnd,
		zone = opts.zone or "custom",
	}, Calendar)
	return table.freeze(self) :: any
end

local defaultCalendar: Calendar? = nil

-- The production America/New_York calendar from the generated Intl table.
function Calendar.default(): Calendar
	if defaultCalendar == nil then
		local ny = require("../../generated/NyOffsets") :: any
		defaultCalendar = Calendar.new(ny.transitions, { coverageEnd = ny.coverageEnd, zone = ny.zone })
	end
	return defaultCalendar :: Calendar
end

-- Offset in force at UTC instant t (binary search for the last entry starting at or before t).
local function offsetAt(self: any, t: number): number
	if type(t) ~= "number" or t ~= t then
		fail("t must be a number, got " .. tostring(t))
	end
	local starts = self._starts
	if t < starts[1] or t >= self.coverageEnd then
		fail(string.format("t=%s is outside the offset table coverage [%d, %s)", tostring(t), starts[1], tostring(self.coverageEnd)))
	end
	local lo, hi = 1, #starts
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if starts[mid] <= t then
			lo = mid
		else
			hi = mid - 1
		end
	end
	return self._offsets[lo]
end

function Calendar.localTime(self: any, t: number): LocalTime
	local offset = offsetAt(self, t)
	local localSeconds = math.floor(t) + offset
	local days = localSeconds // SECONDS_PER_DAY
	local secondOfDay = localSeconds - days * SECONDS_PER_DAY
	return {
		dateKey = keyOfDays(days),
		dayNumber = days,
		hour = secondOfDay // 3600,
		minute = (secondOfDay % 3600) // 60,
		offsetSeconds = offset,
	}
end

-- UTC seconds of 00:00 local time on the calendar date after dateKey (daily-bar availability time).
function Calendar.nextMidnightAfter(self: any, dateKey: number): number
	local days = dayNumberOfKey(dateKey) + 1
	local localMidnight = days * SECONDS_PER_DAY
	-- The offset at the UTC instant numerically equal to the local midnight is within a day of the answer;
	-- two refinements settle on the offset actually in force at the answer.
	local t = localMidnight - offsetAt(self, localMidnight)
	t = localMidnight - offsetAt(self, t)
	if t + offsetAt(self, t) ~= localMidnight then
		fail("local midnight after " .. tostring(dateKey) .. " does not exist in this table")
	end
	return t
end

function Calendar.dateString(_self: any, dateKey: number): string
	dayNumberOfKey(dateKey)
	return string.format("%04d-%02d-%02d", dateKey // 10000, (dateKey // 100) % 100, dateKey % 100)
end

return Calendar
