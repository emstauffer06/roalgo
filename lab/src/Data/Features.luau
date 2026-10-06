--!strict
-- Causal base features for O14 and H14 (and the first fourteen R50 columns), plan section 3.
--
-- Features.compute(current, previous?) uses only the current completed bar and, for the one-hour return,
-- the immediately preceding pair of the same segment. Per symbol, in this order:
--   1 one-hour return     ln(C / previous C)        0 at a segment start (segmentOffset 1)
--   2 body                ln(C / O)
--   3 range               ln(H / L)
--   4 close location      2(C - L)/(H - L) - 1      0 when H == L
--   5 volume              ln(1 + V)                 negative volume rejected
--   6 VWAP displacement   ln(C / VWAP)              nonpositive VWAP rejected
-- Output: six SPY, six QQQ, then sin(2*pi*h/24), cos(2*pi*h/24) with h the New York bar-start hour.
-- Non-finite fields and nonpositive OHLC/VWAP raise an error: a rejected input is a run failure, never a
-- reason to drop the row or to emit zeros. Pure: no state, no future data.
-- previous: at a segment start (segmentOffset 1) pass nil or any pair of another segment; after it, pass the
-- immediately preceding pair of the same segment (t - 3600, same New York date, segmentOffset - 1). Anything
-- else raises: a lost predecessor must never turn into a zero one-hour return.
local Types = require("../Types")

type Pair = Types.Pair
type Bar = Types.Bar
type FeatureRow = Types.FeatureRow

local BAR_SECONDS = 3600
local TWO_PI = 2 * math.pi
local FIELD_NAMES = { "timestamp", "open", "high", "low", "close", "volume", "trade_count", "vwap" }

local Features = {}

Features.DIMENSION = 14

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function checkBar(bar: any, label: string)
	if type(bar) ~= "table" then
		error("Features: " .. label .. " bar missing", 3)
	end
	for k = 1, 8 do
		if not isFinite(bar[k]) then
			error(string.format("Features: %s %s is not a finite number", label, FIELD_NAMES[k]), 3)
		end
	end
	for _, k in { 2, 3, 4, 5, 8 } do
		if bar[k] <= 0 then
			error(string.format("Features: %s %s must be positive", label, FIELD_NAMES[k]), 3)
		end
	end
	if bar[6] < 0 then
		error("Features: " .. label .. " volume must be non-negative", 3)
	end
end

local function symbolFeatures(out: { number }, base: number, bar: Bar, previousClose: number?)
	local o, h, l, c, v, vwap = bar[2], bar[3], bar[4], bar[5], bar[6], bar[8]
	out[base + 1] = if previousClose ~= nil then math.log(c / previousClose) else 0
	out[base + 2] = math.log(c / o)
	out[base + 3] = math.log(h / l)
	out[base + 4] = if h == l then 0 else 2 * (c - l) / (h - l) - 1
	out[base + 5] = math.log(1 + v)
	out[base + 6] = math.log(c / vwap)
end

function Features.compute(current: Pair, previous: Pair?): { number }
	if type(current) ~= "table" or not isFinite(current.t) then
		error("Features: current pair required", 2)
	end
	checkBar(current.spy, "SPY")
	checkBar(current.qqq, "QQQ")
	local h = current.hourNY
	if type(h) ~= "number" or h < 0 or h > 23 or h ~= math.floor(h) then
		error("Features: hourNY must be an integer 0..23, got " .. tostring(h), 2)
	end
	local offset = current.segmentOffset
	if type(offset) ~= "number" or offset < 1 or offset ~= math.floor(offset) then
		error("Features: current.segmentOffset must be a positive integer, got " .. tostring(offset), 2)
	end
	local samePrevious = previous ~= nil and previous.segmentId == current.segmentId
	local prevSpy: number?, prevQqq: number? = nil, nil
	if offset == 1 then
		-- Segment start: the return is 0. A previous pair of the same segment contradicts the metadata.
		if samePrevious then
			error("Features: a segment start (segmentOffset 1) cannot have a previous pair from its own segment", 2)
		end
	elseif not samePrevious then
		-- Never fall back to a zero return after the segment start: the caller lost the preceding pair.
		error(string.format("Features: pair at segmentOffset %d needs the immediately preceding pair of its segment", offset), 2)
	else
		local prev = previous :: Pair
		-- Same segment: it must be the immediately preceding hour on the same New York date.
		if prev.t ~= current.t - BAR_SECONDS or prev.dateKey ~= current.dateKey or prev.segmentOffset ~= offset - 1 then
			error("Features: previous pair is not the immediately preceding pair of this segment", 2)
		end
		checkBar(prev.spy, "previous SPY")
		checkBar(prev.qqq, "previous QQQ")
		prevSpy, prevQqq = prev.spy[5], prev.qqq[5]
	end
	local out = table.create(14, 0)
	symbolFeatures(out, 0, current.spy, prevSpy)
	symbolFeatures(out, 6, current.qqq, prevQqq)
	out[13] = math.sin(TWO_PI * h / 24)
	out[14] = math.cos(TWO_PI * h / 24)
	for i = 1, 14 do
		if not isFinite(out[i]) then
			error("Features: feature " .. i .. " is not finite", 2)
		end
	end
	return out
end

-- O14/H14 FeatureRow: the fourteen values with every observed flag true.
function Features.baseRow(current: Pair, previous: Pair?, profileId: string): FeatureRow
	if profileId ~= "O14" and profileId ~= "H14" then
		error("Features: baseRow builds O14/H14 rows only, got profile " .. tostring(profileId), 2)
	end
	local values = Features.compute(current, previous)
	return {
		values = values,
		observed = table.create(14, true),
		t = current.t,
		decisionTime = current.t + BAR_SECONDS,
		profileId = profileId,
	}
end

return Features
