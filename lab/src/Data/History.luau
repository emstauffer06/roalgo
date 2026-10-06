--!strict
-- Lag buffer for the raw comparator (plan section 3, "Lag baseline").
--
-- History.new(maxLag, dimension) keeps the last maxLag transformed D-value inputs of the current segment.
-- push(vec) stores a copy of the newest input; reset() clears the buffer at a segment start.
-- vector(lags) returns (dimension + 1) * lags numbers laid out as
--
--   [ lag 1 values (D) | lag 2 values (D) | ... | lag L values (D) | lag-1 mask, lag-2 mask, ..., lag-L mask ]
--
-- Lag 1 is the most recent push (the current input: call push before vector; vector on an empty buffer is
-- an error), lag 2 the one before it, and so on. A lag the segment has not reached yet is zero-padded (after
-- transformation) with mask 0; a real vector has mask 1. These lag masks are separate from any per-feature
-- masks inside an R50/R60 input.
-- Dimensions: (D+1)*L, e.g. 15/60/120 for D=14 and 51/204/408 for D=50 with L in {1, 4, 8}.

export type History = {
	maxLag: number,
	dimension: number,
	reset: (self: any) -> (),
	push: (self: any, vec: { number }) -> (),
	vector: (self: any, lags: number) -> { number },
	count: (self: any) -> number,
}

local History = {}
History.__index = History

local function isPositiveInteger(x: any): boolean
	return type(x) == "number" and x >= 1 and x == math.floor(x) and x ~= math.huge
end

function History.outputDimension(dimension: number, lags: number): number
	return (dimension + 1) * lags
end

function History.new(maxLag: number, dimension: number): History
	if not isPositiveInteger(maxLag) then
		error("History: maxLag must be a positive integer", 2)
	end
	if not isPositiveInteger(dimension) then
		error("History: dimension must be a positive integer", 2)
	end
	local self = setmetatable({
		maxLag = maxLag,
		dimension = dimension,
		_buffer = {},
		_head = 0,
		_count = 0,
	}, History)
	return self :: any
end

function History.reset(self: any)
	table.clear(self._buffer)
	self._head = 0
	self._count = 0
end

function History.push(self: any, vec: { number })
	local d = self.dimension
	if type(vec) ~= "table" or #vec ~= d then
		error(string.format("History: input dimension %s, expected %d", if type(vec) == "table" then tostring(#vec) else "?", d), 2)
	end
	local copy = table.create(d)
	for i = 1, d do
		local x = vec[i]
		if type(x) ~= "number" or x ~= x or x == math.huge or x == -math.huge then
			error("History: input value " .. i .. " is not a finite number", 2)
		end
		copy[i] = x
	end
	self._head = self._head % self.maxLag + 1
	self._buffer[self._head] = table.freeze(copy)
	self._count = math.min(self._count + 1, self.maxLag)
end

function History.vector(self: any, lags: number): { number }
	if not isPositiveInteger(lags) or lags > self.maxLag then
		error(string.format("History: lags must be an integer in 1..%d, got %s", self.maxLag, tostring(lags)), 2)
	end
	if self._count == 0 then
		-- Lag 1 is the current input; an empty buffer here means the caller skipped its push.
		error("History: no input since reset; push the current input before vector()", 2)
	end
	local d = self.dimension
	local out = table.create((d + 1) * lags, 0)
	for k = 1, lags do
		if k <= self._count then
			local vec = self._buffer[(self._head - k) % self.maxLag + 1]
			table.move(vec, 1, d, (k - 1) * d + 1, out)
			out[lags * d + k] = 1
		end
	end
	return out
end

-- Number of real vectors held (at most maxLag).
function History.count(self: any): number
	return self._count
end

return History
