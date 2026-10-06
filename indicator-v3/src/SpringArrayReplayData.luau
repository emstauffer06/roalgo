-- Recorded endpoints only: no services, Instances, physics, interpolation or decision recomputation.
-- append takes envelope.chunk after the caller has verified the archive's identity and hashes.
-- Each lane follows its sealed warmup + recorded block queue on a common integer bar-tick timeline.
-- Warmup and idle poses were not archived; their samples deliberately contain no state vectors.
local Data = {}
Data.__index = Data
Data.SCHEMA = "roalgo-spring-array-replay-data-1"

local STATE_VALUES, STATE_BYTES, STATE_HEX = 51, 408, 816
local function check(ok, message) assert(ok, "SpringArrayReplayData: " .. message) end
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function integer(x) return finite(x) and x % 1 == 0 end
local function arrayCount(value, name)
	check(type(value) == "table", name .. " must be an array")
	local n, count = #value, 0
	for k in value do
		check(integer(k) and k >= 1 and k <= n, name .. " has a non-array key or hole")
		count += 1
	end
	check(count == n, name .. " has a hole")
	return n
end

local function blockAt(queue, tick)
	local low, high = 1, #queue
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local b = queue[mid]
		if tick < b.startTick then high = mid - 1
		elseif tick > b.endTick then low = mid + 1
		else return b end
	end
	return nil
end

local function firstAllRecorded(queues, totalTicks)
	local tick = 1
	while tick <= totalTicks do
		local nextTick = tick
		for _, queue in queues do
			local b = blockAt(queue, tick)
			if not b then return nil end -- This lane has finished; it never resumes.
			nextTick = math.max(nextTick, b.recordedTick)
		end
		if nextTick == tick then return tick end
		tick = nextTick
	end
	return nil
end

function Data.new(laneSeal, totalRows)
	check(integer(totalRows) and totalRows >= 1, "totalRows must be a positive integer")
	check(type(laneSeal) == "table" and laneSeal.schema == "roalgo-spring-lane-capture-1", "lane seal schema mismatch")
	check(type(laneSeal.runId) == "string" and #laneSeal.runId > 0, "lane seal runId required")
	local count, schedule = laneSeal.lanes, laneSeal.schedule
	check(integer(count) and count >= 1 and count <= 64, "schedule lane count must be in 1..64")
	check(type(schedule) == "table" and schedule.schema == "spring-block-schedule-1", "schedule schema mismatch")
	local n = arrayCount(schedule.blocks, "schedule blocks")
	check(n >= 1, "schedule has no blocks")
	local queues, lengths = table.create(count), table.create(count, 0)
	for lane = 1, count do queues[lane] = {} end
	local nextRow, warmupBars = 1, 0
	for id, b in schedule.blocks do
		check(type(b) == "table" and b.id == id, "schedule block IDs must be sequential")
		check(integer(b.lane) and b.lane >= 1 and b.lane <= count, "schedule block lane out of range")
		check(integer(b.firstIndex) and b.firstIndex == nextRow and integer(b.lastIndex)
			and b.lastIndex >= b.firstIndex and b.lastIndex <= totalRows, "schedule recorded coverage has a gap, overlap or invalid range")
		check(integer(b.warmFirstIndex) and b.warmFirstIndex >= 1 and b.warmFirstIndex <= b.firstIndex
			and b.warmLastIndex == b.firstIndex - 1, "schedule warmup range must immediately precede its recorded block")
		local warm = b.firstIndex - b.warmFirstIndex
		local start = lengths[b.lane] + 1
		local entry = table.freeze({ id = id, lane = b.lane, firstIndex = b.firstIndex, lastIndex = b.lastIndex,
			warmFirstIndex = b.warmFirstIndex, startTick = start, recordedTick = start + warm,
			endTick = start + warm + b.lastIndex - b.firstIndex })
		table.insert(queues[b.lane], entry)
		lengths[b.lane] = entry.endTick
		warmupBars += warm
		nextRow = b.lastIndex + 1
	end
	check(nextRow == totalRows + 1, "schedule recorded coverage does not reach totalRows")
	local totalTicks = 0
	for _, length in lengths do totalTicks = math.max(totalTicks, length) end
	check(integer(schedule.maxLaneBars) and schedule.maxLaneBars == totalTicks, "schedule maxLaneBars differs from its block queues")
	check(schedule.warmupBars == nil or schedule.warmupBars == warmupBars, "schedule warmupBars differs from its block queues")
	check(schedule.steppedBars == nil or schedule.steppedBars == totalRows + warmupBars, "schedule steppedBars differs from its block queues")
	for _, queue in queues do table.freeze(queue) end
	table.freeze(queues)
	return setmetatable({ runId = laneSeal.runId, totalRows = totalRows, laneCount = count, totalTicks = totalTicks,
		firstAllRecordedTick = firstAllRecorded(queues, totalTicks), _queues = queues, _blockCount = n,
		_warmupBars = warmupBars, _loadedRows = 0, _chunks = 0, _finished = false,
		_times = table.create(totalRows), _labels = table.create(totalRows),
		_coupled = buffer.create(totalRows * STATE_BYTES), _independent = buffer.create(totalRows * STATE_BYTES) }, Data)
end

local function decodeInto(hex, target, offset, name)
	check(type(hex) == "string" and #hex == STATE_HEX and string.find(hex, "[^0-9a-fA-F]") == nil,
		name .. " state must contain exactly 816 hexadecimal characters")
	for i = 0, STATE_BYTES - 1 do
		buffer.writeu8(target, offset + i, tonumber(string.sub(hex, i * 2 + 1, i * 2 + 2), 16))
	end
	for i = 0, STATE_VALUES - 1 do
		check(finite(buffer.readf64(target, offset + i * 8)), name .. " state contains a non-finite value")
	end
end

function Data:append(chunk)
	check(not self._finished, "cannot append after finish: builder is finished")
	check(type(chunk) == "table" and chunk.schema == "roalgo-spring-live-chunk-1", "chunk schema mismatch")
	check(chunk.runId == self.runId, "chunk runId differs from lane seal")
	check(integer(chunk.firstIndex) and chunk.firstIndex == self._loadedRows + 1, "chunk coverage must be contiguous")
	check(integer(chunk.count) and chunk.count >= 1 and integer(chunk.lastIndex)
		and chunk.lastIndex == chunk.firstIndex + chunk.count - 1 and chunk.lastIndex <= self.totalRows, "chunk count or range is invalid")
	local count = chunk.count
	check(arrayCount(chunk.bars, "chunk bars count") == count, "chunk bars count mismatch")
	check(type(chunk.states) == "table", "chunk states required")
	for _, variant in { "coupled", "independent" } do
		check(arrayCount(chunk.states[variant], "chunk " .. variant .. " state count") == count, "chunk " .. variant .. " state count mismatch")
	end
	-- Decode and validate a complete chunk before committing anything. An invalid append can be retried.
	local coupled, independent = buffer.create(count * STATE_BYTES), buffer.create(count * STATE_BYTES)
	local times, labels = table.create(count), table.create(count)
	local prevT = self._times[self._loadedRows]
	for i = 1, count do
		local bar = chunk.bars[i]
		check(type(bar) == "table" and finite(bar.t) and (prevT == nil or bar.t > prevT), "bar time must be finite and strictly increasing")
		check(type(bar.label) == "string", "bar label must be a string")
		times[i], labels[i], prevT = bar.t, bar.label, bar.t
		local offset = (i - 1) * STATE_BYTES
		decodeInto(chunk.states.coupled[i], coupled, offset, "coupled row " .. (chunk.firstIndex + i - 1))
		decodeInto(chunk.states.independent[i], independent, offset, "independent row " .. (chunk.firstIndex + i - 1))
	end
	local offset = self._loadedRows * STATE_BYTES
	buffer.copy(self._coupled, offset, coupled)
	buffer.copy(self._independent, offset, independent)
	for i = 1, count do
		local row = self._loadedRows + i
		self._times[row], self._labels[row] = times[i], labels[i]
	end
	self._loadedRows = chunk.lastIndex
	self._chunks += 1
	return self
end

function Data:finish()
	check(self._loadedRows == self.totalRows, "saved row coverage is incomplete")
	self._finished = true
	return self
end

local function readVector(packed, row)
	local offset, out = (row - 1) * STATE_BYTES, table.create(STATE_VALUES)
	for i = 1, STATE_VALUES do out[i] = buffer.readf64(packed, offset + (i - 1) * 8) end
	return out
end

function Data:sample(laneIndex, globalTick)
	check(self._finished, "finish must succeed before sampling")
	check(integer(laneIndex) and laneIndex >= 1 and laneIndex <= self.laneCount, "lane index out of range")
	check(integer(globalTick) and globalTick >= 1 and globalTick <= self.totalTicks, "global tick out of range")
	local b = blockAt(self._queues[laneIndex], globalTick)
	if not b then return { phase = "idle", lane = laneIndex } end
	local recorded = globalTick >= b.recordedTick
	local row = if recorded then b.firstIndex + globalTick - b.recordedTick else b.warmFirstIndex + globalTick - b.startTick
	local sample = { phase = if recorded then "recorded" else "warmup", lane = laneIndex, blockId = b.id,
		rowIndex = row, label = self._labels[row], t = self._times[row] }
	if recorded then
		sample.coupled = readVector(self._coupled, row)
		sample.independent = readVector(self._independent, row)
	end
	return sample
end

-- Invert only the unique recorded range; the same source row can also appear
-- in another block's warmup, where no endpoint state was archived.
function Data:locateRow(rowIndex)
	check(self._finished, "finish must succeed before locating rows")
	check(integer(rowIndex) and rowIndex >= 1 and rowIndex <= self.totalRows, "row index out of range")
	for lane, queue in self._queues do
		for _, block in queue do
			if rowIndex >= block.firstIndex and rowIndex <= block.lastIndex then
				return { lane = lane, tick = block.recordedTick + rowIndex - block.firstIndex, blockId = block.id }
			end
		end
	end
	error("SpringArrayReplayData: recorded row missing from validated schedule", 2)
end

function Data:stats()
	return { schema = Data.SCHEMA, runId = self.runId, loadedRows = self._loadedRows, totalRows = self.totalRows,
		laneCount = self.laneCount, totalTicks = self.totalTicks, firstAllRecordedTick = self.firstAllRecordedTick,
		blocks = self._blockCount, warmupBars = self._warmupBars, chunks = self._chunks, finished = self._finished,
		stateBytes = self._loadedRows * STATE_BYTES * 2, allocatedStateBytes = self.totalRows * STATE_BYTES * 2,
		stateValues = STATE_VALUES, variants = { "coupled", "independent" }, recordedEndpointsOnly = true }
end

return Data
