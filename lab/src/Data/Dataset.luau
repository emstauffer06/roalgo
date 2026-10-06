--!strict
-- Paired SPY/QQQ hourly stream with New York metadata and segments (plan sections 1, 2.2 and 3).
--
-- Dataset.new(spyBars, qqqBars, calendar) validates each source, then pairs by timestamp intersection
-- (never by row index). Validation is strict and fails loudly: a rejected row is a run failure to
-- investigate, not a row to drop.
--   * each bar has exactly 8 finite numeric fields {t, open, high, low, close, volume, trade_count, vwap}
--   * timestamps strictly increase (no duplicates, no reordering) and are integers
--   * open, high, low, close and vwap are positive; volume and trade_count are non-negative
-- Segments: a new segment starts on the first pair, on a New York date change, or when the timestamp delta
-- from the previous pair is anything other than 3600 s. segmentOffset counts pairs within the segment.
--
-- The dataset stores frozen copies of every bar, so later mutation of the caller's tables (or the shared
-- require cache) cannot change it. Per-symbol timestamp->bar maps keep unpaired native bars reachable
-- through symbolBarAt. This module never looks forward; target lookup lives in Targets.luau.
local Types = require("../Types")

type Bar = Types.Bar
type Pair = Types.Pair

local BAR_SECONDS = 3600
local FIELD_NAMES = { "timestamp", "open", "high", "low", "close", "volume", "trade_count", "vwap" }

export type Dataset = Types.Dataset & {
	stats: (self: any) -> { spyCount: number, qqqCount: number, pairedCount: number, spyOnly: number, qqqOnly: number, segmentCount: number },
}

local Dataset = {}
Dataset.__index = Dataset

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- Returns frozen copies of the bars and a timestamp -> bar map.
local function validateSource(bars: any, label: string): ({ Bar }, { [number]: Bar })
	if type(bars) ~= "table" then
		error("Dataset: " .. label .. " bars must be an array", 3)
	end
	local copies = table.create(#bars) :: { Bar }
	local byT = {} :: { [number]: Bar }
	local prevT = -math.huge
	for i, item in ipairs(bars) do
		local where = string.format("%s row %d", label, i)
		local bar = item :: any
		if type(bar) ~= "table" or #bar ~= 8 or bar[9] ~= nil then
			error("Dataset: " .. where .. " must have exactly 8 fields", 3)
		end
		for k = 1, 8 do
			if not isFinite(bar[k]) then
				error(string.format("Dataset: %s field %d (%s) is not a finite number", where, k, FIELD_NAMES[k]), 3)
			end
		end
		local t = bar[1]
		if t ~= math.floor(t) then
			error("Dataset: " .. where .. " timestamp must be an integer", 3)
		end
		if t <= prevT then
			error(string.format("Dataset: %s timestamps must be strictly increasing (%s after %s)", label, tostring(t), tostring(prevT)), 3)
		end
		for _, k in { 2, 3, 4, 5, 8 } do
			if bar[k] <= 0 then
				error(string.format("Dataset: %s %s must be positive", where, FIELD_NAMES[k]), 3)
			end
		end
		if bar[6] < 0 then
			error("Dataset: " .. where .. " volume must be non-negative", 3)
		end
		if bar[7] < 0 then
			error("Dataset: " .. where .. " trade_count must be non-negative", 3)
		end
		prevT = t
		local copy: Bar = { bar[1], bar[2], bar[3], bar[4], bar[5], bar[6], bar[7], bar[8] }
		table.freeze(copy :: any)
		copies[i] = copy
		byT[t] = copy
	end
	if #copies == 0 then
		error("Dataset: " .. label .. " has no bars", 3)
	end
	-- ipairs stops at the first hole; a sparse array would hide rows.
	for k in bars do
		if type(k) ~= "number" or k < 1 or k > #copies or k ~= math.floor(k) then
			error("Dataset: " .. label .. " must be a dense array", 3)
		end
	end
	return copies, byT
end

function Dataset.new(spyBars: { Bar }, qqqBars: { Bar }, calendar: Types.Calendar): Dataset
	if type(calendar) ~= "table" or type((calendar :: any).localTime) ~= "function" then
		error("Dataset: a calendar (Types.Calendar) is required", 2)
	end
	local spy, spyByT = validateSource(spyBars, "SPY")
	local qqq, qqqByT = validateSource(qqqBars, "QQQ")

	local pairList = {} :: { Pair }
	local indexByT = {} :: { [number]: number }
	local i, j = 1, 1
	local segmentId, segmentOffset = 0, 0
	local prev: Pair? = nil
	while i <= #spy and j <= #qqq do
		local ts, tq = spy[i][1], qqq[j][1]
		if ts < tq then
			i += 1
		elseif tq < ts then
			j += 1
		else
			local lt = calendar:localTime(ts)
			local fresh = prev == nil or lt.dateKey ~= (prev :: Pair).dateKey or ts - (prev :: Pair).t ~= BAR_SECONDS
			if fresh then
				segmentId += 1
				segmentOffset = 1
			else
				segmentOffset += 1
			end
			local index = #pairList + 1
			local pair: Pair = {
				index = index,
				t = ts,
				decisionTime = ts + BAR_SECONDS,
				dateNY = calendar:dateString(lt.dateKey),
				dateKey = lt.dateKey,
				dayNumber = lt.dayNumber,
				hourNY = lt.hour,
				segmentId = segmentId,
				segmentOffset = segmentOffset,
				spy = spy[i],
				qqq = qqq[j],
			}
			table.freeze(pair :: any)
			pairList[index] = pair
			indexByT[ts] = index
			prev = pair
			i += 1
			j += 1
		end
	end

	local self = setmetatable({
		_pairs = table.freeze(pairList),
		_indexByT = indexByT,
		_bySymbol = { SPY = spyByT, QQQ = qqqByT },
		_stats = table.freeze({
			spyCount = #spy,
			qqqCount = #qqq,
			pairedCount = #pairList,
			spyOnly = #spy - #pairList,
			qqqOnly = #qqq - #pairList,
			segmentCount = segmentId,
		}),
	}, Dataset)
	return table.freeze(self) :: any
end

-- The exported loaders' declared column order (Types.Bar).
local SCHEMA = { "timestamp_unix", "open", "high", "low", "close", "volume", "trade_count", "vwap" }

-- A loader module must declare exactly this schema, the expected symbol, and its own row count.
local function checkModule(m: any, symbol: string)
	if type(m) ~= "table" or type(m.bars) ~= "table" then
		error("Dataset: load expects " .. symbol .. " loader module with a bars array", 3)
	end
	if type(m.schema) ~= "table" or #m.schema ~= #SCHEMA then
		error("Dataset: " .. symbol .. " loader module must declare the 8-column schema", 3)
	end
	for k, name in SCHEMA do
		if m.schema[k] ~= name then
			error(string.format("Dataset: %s loader schema column %d is %s, expected %s", symbol, k, tostring(m.schema[k]), name), 3)
		end
	end
	if type(m.metadata) ~= "table" or m.metadata.symbol ~= symbol then
		error(string.format("Dataset: loader passed as %s declares symbol %s", symbol, tostring(m.metadata and m.metadata.symbol)), 3)
	end
	if m.metadata.count ~= #m.bars then
		error(string.format("Dataset: %s loader declares count %s but holds %d bars", symbol, tostring(m.metadata.count), #m.bars), 3)
	end
end

-- Convenience for modules shaped like the exported loaders ({metadata, schema, bars}).
function Dataset.load(spyModule: any, qqqModule: any, calendar: Types.Calendar): Dataset
	checkModule(spyModule, "SPY")
	checkModule(qqqModule, "QQQ")
	return Dataset.new(spyModule.bars, qqqModule.bars, calendar)
end

function Dataset.count(self: any): number
	return #self._pairs
end

function Dataset.get(self: any, index: number): Pair?
	return self._pairs[index]
end

function Dataset.indexOf(self: any, t: number): number?
	return self._indexByT[t]
end

-- Frozen array of frozen pairs; read-only.
function Dataset.pairs(self: any): { Pair }
	return self._pairs
end

function Dataset.symbolBarAt(self: any, symbol: string, t: number): Bar?
	local map = self._bySymbol[symbol]
	if map == nil then
		error("Dataset: unknown symbol " .. tostring(symbol) .. " (expected SPY or QQQ)", 2)
	end
	return map[t]
end

function Dataset.stats(self: any)
	return self._stats
end

return Dataset
