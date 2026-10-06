-- SpringBlockSchedule: round-robin block schedule for the multi-lane spring live capture
-- (spring-live-contract.md section 1b, decisions L16, L18, L19). Pure Luau: no Roblox API, no sibling modules, no clock.
--
-- The run's sessions are cut into blocks of `blockSessions` consecutive sessions (default 5; the last block may be
-- shorter). Block b goes to lane ((b - 1) % lanes) + 1. A lane steps its block from REST, starting `warmupSessions`
-- sessions (default 1) before the block's first session. Those warm-up bars are stepped and recorded but never decided.
-- The very first block starts at bar 1, which is the capture's own reset, so it has no warm-up. A warm-up that would
-- reach before bar 1 is clamped to bar 1, which is the same state as the continuous run (rest at the reset).
--
-- Rules, all enforced by verify() independently of build():
--   1. Every bar is DECIDED exactly once: the blocks partition bars 1..N contiguously, in time order, on session
--      boundaries (a block never starts or ends mid-session).
--   2. A block's warm-up is the immediately preceding session(s): bars warmFirstIndex..firstIndex-1, stepped by the
--      same lane right before the block's own bars. Only the first block has none (firstSession == 1).
--   3. Blocks are assigned round-robin. A lane queue lists that lane's block ids in time order.
--   4. decisionOrder is every block id in time order (block ids are time ranks, so it is 1..blocks).
--
-- Warm-up and every other range use inclusive 1-based bar and session indexes. An empty range is written
-- first = last + 1 (so `for i = warmFirstIndex, warmLastIndex` runs zero times for the first block).
--
-- Block fields: id, lane, slot (1-based position in its lane's queue), firstSession, lastSession, firstIndex,
-- lastIndex, bars, warmSessions, warmFirstSession, warmLastSession, warmFirstIndex, warmLastIndex, warmBars,
-- steppedBars (= warmBars + bars; the lane resets to rest and steps warmFirstIndex..lastIndex), days (decided days).
--
-- Stats: sessions, bars, blocks, lanes, warmupBars, steppedBars (= bars + warmupBars), overheadFraction
-- (= warmupBars / bars, the extra stepping relative to the decided bars), perLaneBars (STEPPED bars per lane, the
-- lane's real workload), perLaneDecidedBars, perLaneBlocks, maxLaneBars, etaSeconds(barsPerSecondPerLane) =
-- maxLaneBars / rate (lanes advance in lockstep, so the busiest lane sets the duration).
-- stats.etaSeconds is a function: drop it before JSON-encoding a schedule.
--
-- The returned schedule is deep-frozen. build() and verify() raise on bad input (the message names the rule).
local SpringBlockSchedule = {}

local SCHEMA = "spring-block-schedule-1"
SpringBlockSchedule.SCHEMA = SCHEMA
SpringBlockSchedule.DEFAULT_BLOCK_SESSIONS = 5
SpringBlockSchedule.DEFAULT_WARMUP_SESSIONS = 1

local KNOWN_OPTIONS = { lanes = true, blockSessions = true, warmupSessions = true }

local function fail(who, fmt, ...)
	error(string.format("%s: " .. fmt, who, ...), 0)
end

local function isInteger(x)
	return type(x) == "number" and x == x and x > -9007199254740992 and x < 9007199254740992 and x == math.floor(x)
end

local function deepFreeze(t)
	for _, v in t do
		if type(v) == "table" then deepFreeze(v) end
	end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end

-- Validates the session list (ordered, 1-based, contiguous bars starting at 1, ascending unique days).
-- Returns the total bar count.
local function checkSessions(sessions, who)
	if type(sessions) ~= "table" then
		fail(who, "sessions must be an array of {day, firstIndex, lastIndex}, got %s", type(sessions))
	end
	local n = #sessions
	if n < 1 then fail(who, "sessions is empty") end
	local count = 0
	for _ in sessions do count += 1 end
	if count ~= n then fail(who, "sessions must be a dense 1-based array (%s entries, length %s)", tostring(count), tostring(n)) end
	local nextFirst, previousDay = 1, nil
	for i = 1, n do
		local s = sessions[i]
		if type(s) ~= "table" then fail(who, "session %s is not a table", tostring(i)) end
		if type(s.day) ~= "string" or s.day == "" then fail(who, "session %s has no day string", tostring(i)) end
		if not isInteger(s.firstIndex) or not isInteger(s.lastIndex) then
			fail(who, "session %s (%s) needs integer firstIndex and lastIndex", tostring(i), s.day)
		end
		if s.lastIndex < s.firstIndex then
			fail(who, "session %s (%s) is empty or inverted (%s..%s)", tostring(i), s.day, tostring(s.firstIndex), tostring(s.lastIndex))
		end
		if s.firstIndex ~= nextFirst then
			fail(who, "session %s (%s) starts at bar %s but bar %s was expected (sessions must be contiguous from bar 1: gap or overlap)",
				tostring(i), s.day, tostring(s.firstIndex), tostring(nextFirst))
		end
		if previousDay ~= nil and not (s.day > previousDay) then
			fail(who, "session %s day %s is not after the previous session day %s (days must ascend)", tostring(i), s.day, previousDay)
		end
		previousDay, nextFirst = s.day, s.lastIndex + 1
	end
	return nextFirst - 1
end

-- Validates the options. Unknown names are rejected so a typo cannot silently fall back to a default.
local function readOptions(opts, who)
	if type(opts) ~= "table" then fail(who, "options table {lanes = N, blockSessions = 5, warmupSessions = 1} required") end
	for k in opts do
		if KNOWN_OPTIONS[k] ~= true then fail(who, "unknown option '%s'", tostring(k)) end
	end
	local lanes = opts.lanes
	if not isInteger(lanes) or lanes < 1 then fail(who, "lanes must be an integer >= 1, got %s", tostring(lanes)) end
	local blockSessions = opts.blockSessions
	if blockSessions == nil then blockSessions = SpringBlockSchedule.DEFAULT_BLOCK_SESSIONS end
	if not isInteger(blockSessions) or blockSessions < 1 then
		fail(who, "blockSessions must be an integer >= 1, got %s", tostring(blockSessions))
	end
	local warmupSessions = opts.warmupSessions
	if warmupSessions == nil then warmupSessions = SpringBlockSchedule.DEFAULT_WARMUP_SESSIONS end
	if not isInteger(warmupSessions) or warmupSessions < 0 then
		fail(who, "warmupSessions must be an integer >= 0, got %s", tostring(warmupSessions))
	end
	return lanes, blockSessions, warmupSessions
end

local function checkRate(rate, who)
	if type(rate) ~= "number" or rate ~= rate or rate <= 0 or rate == math.huge then
		fail(who, "barsPerSecondPerLane must be a finite number > 0, got %s", tostring(rate))
	end
end

function SpringBlockSchedule.build(sessions, opts)
	local who = "SpringBlockSchedule.build"
	local totalBars = checkSessions(sessions, who)
	local lanes, blockSessions, warmupSessions = readOptions(opts, who)
	local sessionCount = #sessions
	local blockCount = math.ceil(sessionCount / blockSessions)

	local blocks, decisionOrder, laneQueues = table.create(blockCount), table.create(blockCount), table.create(lanes)
	local perLaneBars, perLaneDecidedBars, perLaneBlocks = table.create(lanes, 0), table.create(lanes, 0), table.create(lanes, 0)
	for lane = 1, lanes do laneQueues[lane] = {} end
	local warmupBars = 0

	for id = 1, blockCount do
		local firstSession = (id - 1) * blockSessions + 1
		local lastSession = math.min(sessionCount, id * blockSessions)
		local lane = (id - 1) % lanes + 1
		local queue = laneQueues[lane]
		queue[#queue + 1] = id

		local warmSessions = math.min(warmupSessions, firstSession - 1)
		local warmFirstSession = firstSession - warmSessions
		local firstIndex, lastIndex = sessions[firstSession].firstIndex, sessions[lastSession].lastIndex
		local warmFirstIndex = sessions[warmFirstSession].firstIndex
		local bars, warmBars = lastIndex - firstIndex + 1, firstIndex - warmFirstIndex

		local days = table.create(lastSession - firstSession + 1)
		for s = firstSession, lastSession do days[#days + 1] = sessions[s].day end

		blocks[id] = {
			id = id,
			lane = lane,
			slot = #queue,
			firstSession = firstSession,
			lastSession = lastSession,
			firstIndex = firstIndex,
			lastIndex = lastIndex,
			bars = bars,
			warmSessions = warmSessions,
			warmFirstSession = warmFirstSession,
			warmLastSession = firstSession - 1,
			warmFirstIndex = warmFirstIndex,
			warmLastIndex = firstIndex - 1,
			warmBars = warmBars,
			steppedBars = warmBars + bars,
			days = days,
		}
		decisionOrder[id] = id
		warmupBars += warmBars
		perLaneBars[lane] += warmBars + bars
		perLaneDecidedBars[lane] += bars
		perLaneBlocks[lane] += 1
	end

	local maxLaneBars = 0
	for lane = 1, lanes do maxLaneBars = math.max(maxLaneBars, perLaneBars[lane]) end

	local schedule = {
		schema = SCHEMA,
		config = { lanes = lanes, blockSessions = blockSessions, warmupSessions = warmupSessions },
		blocks = blocks,
		laneQueues = laneQueues,
		decisionOrder = decisionOrder,
		stats = {
			sessions = sessionCount,
			bars = totalBars,
			blocks = blockCount,
			lanes = lanes,
			warmupBars = warmupBars,
			steppedBars = totalBars + warmupBars,
			overheadFraction = warmupBars / totalBars,
			perLaneBars = perLaneBars,
			perLaneDecidedBars = perLaneDecidedBars,
			perLaneBlocks = perLaneBlocks,
			maxLaneBars = maxLaneBars,
			etaSeconds = function(barsPerSecondPerLane)
				checkRate(barsPerSecondPerLane, "SpringBlockSchedule.stats.etaSeconds")
				return maxLaneBars / barsPerSecondPerLane
			end,
		},
	}
	return deepFreeze(schedule)
end

-- Estimated wall-clock seconds for the whole schedule at a given per-lane stepping rate (bars per second per lane).
function SpringBlockSchedule.etaSeconds(schedule, barsPerSecondPerLane)
	local who = "SpringBlockSchedule.etaSeconds"
	if type(schedule) ~= "table" or type(schedule.stats) ~= "table" or type(schedule.stats.maxLaneBars) ~= "number" then
		fail(who, "schedule with stats.maxLaneBars required")
	end
	checkRate(barsPerSecondPerLane, who)
	return schedule.stats.maxLaneBars / barsPerSecondPerLane
end

local function sameArray(a, b)
	if type(a) ~= "table" or type(b) ~= "table" then return false end
	local count = 0
	for _ in a do count += 1 end
	if count ~= #a or #a ~= #b then return false end
	for i = 1, #b do
		if a[i] ~= b[i] then return false end
	end
	return true
end

-- Re-derives every rule from `sessions` and the schedule's own config, never from build(). Returns true or raises.
function SpringBlockSchedule.verify(schedule, sessions)
	local who = "SpringBlockSchedule.verify"
	local totalBars = checkSessions(sessions, who)
	local sessionCount = #sessions
	if type(schedule) ~= "table" then fail(who, "schedule must be a table") end
	if schedule.schema ~= SCHEMA then fail(who, "schema %s is not %s", tostring(schedule.schema), SCHEMA) end
	local config = schedule.config
	if type(config) ~= "table" then fail(who, "schedule.config missing") end
	if config.lanes == nil or config.blockSessions == nil or config.warmupSessions == nil then
		fail(who, "config must carry lanes, blockSessions and warmupSessions")
	end
	local lanes, blockSessions, warmupSessions = readOptions(config, who)

	local blocks = schedule.blocks
	if type(blocks) ~= "table" then fail(who, "schedule.blocks missing") end
	local wantBlocks = math.ceil(sessionCount / blockSessions)
	if #blocks ~= wantBlocks then
		fail(who, "block count: %s sessions in blocks of %s need %s blocks, the schedule has %s (bars would be decided zero times or twice)",
			tostring(sessionCount), tostring(blockSessions), tostring(wantBlocks), tostring(#blocks))
	end

	local nextBar, nextSession, decidedTotal = 1, 1, 0
	local wantQueues, wantLaneBars, wantLaneDecided, wantLaneBlocks = {}, table.create(lanes, 0), table.create(lanes, 0), table.create(lanes, 0)
	for lane = 1, lanes do wantQueues[lane] = {} end
	local warmupBars = 0

	for i = 1, #blocks do
		local b = blocks[i]
		if type(b) ~= "table" then fail(who, "block at position %s is not a table", tostring(i)) end
		if b.id ~= i then fail(who, "block at position %s has id %s: blocks must be in time order with id = time rank", tostring(i), tostring(b.id)) end
		for _, name in { "lane", "slot", "firstSession", "lastSession", "firstIndex", "lastIndex", "bars", "warmSessions", "warmFirstSession",
			"warmLastSession", "warmFirstIndex", "warmLastIndex", "warmBars", "steppedBars" } do
			if not isInteger(b[name]) then fail(who, "block %s: %s must be an integer, got %s", tostring(i), name, tostring(b[name])) end
		end

		-- Rule 1: contiguous partition of the bars, on session boundaries.
		if b.firstIndex < nextBar then
			fail(who, "block %s starts at bar %s but bar %s is already decided by the previous block (overlap: decided twice)",
				tostring(i), tostring(b.firstIndex), tostring(nextBar - 1))
		elseif b.firstIndex > nextBar then
			fail(who, "block %s starts at bar %s but bars %s..%s are decided by no block (gap)",
				tostring(i), tostring(b.firstIndex), tostring(nextBar), tostring(b.firstIndex - 1))
		end
		if b.lastIndex < b.firstIndex then fail(who, "block %s is empty or inverted (%s..%s)", tostring(i), tostring(b.firstIndex), tostring(b.lastIndex)) end
		if b.firstSession ~= nextSession then
			fail(who, "block %s starts at session %s but session %s was expected (sessions skipped or repeated)",
				tostring(i), tostring(b.firstSession), tostring(nextSession))
		end
		if b.lastSession < b.firstSession or b.lastSession > sessionCount then
			fail(who, "block %s session range %s..%s is outside 1..%s", tostring(i), tostring(b.firstSession), tostring(b.lastSession), tostring(sessionCount))
		end
		-- Every block but the last holds exactly blockSessions sessions; contiguity then bounds the last one to 1..blockSessions.
		local span = b.lastSession - b.firstSession + 1
		if i < #blocks and span ~= blockSessions then
			fail(who, "block %s holds %s sessions, only the last block may differ from blockSessions = %s", tostring(i), tostring(span), tostring(blockSessions))
		end
		-- A block start is on a session boundary once the previous block ends on one (checked here) and bars are contiguous (above).
		if b.lastIndex ~= sessions[b.lastSession].lastIndex then
			fail(who, "block %s ends at bar %s, mid-session: its last session ends at bar %s (a block must end on a session boundary)",
				tostring(i), tostring(b.lastIndex), tostring(sessions[b.lastSession].lastIndex))
		end
		if b.bars ~= b.lastIndex - b.firstIndex + 1 then
			fail(who, "block %s bars = %s but its range holds %s", tostring(i), tostring(b.bars), tostring(b.lastIndex - b.firstIndex + 1))
		end
		local days = b.days
		if type(days) ~= "table" or #days ~= span then fail(who, "block %s days must list its %s decided sessions", tostring(i), tostring(span)) end
		for k = 1, span do
			if days[k] ~= sessions[b.firstSession + k - 1].day then
				fail(who, "block %s day %s is %s, the session list has %s", tostring(i), tostring(k), tostring(days[k]), sessions[b.firstSession + k - 1].day)
			end
		end

		-- Rule 2: warm-up = the immediately preceding session(s), none for the first block.
		local wantWarmSessions = math.min(warmupSessions, b.firstSession - 1)
		if b.warmSessions ~= wantWarmSessions then
			if b.firstSession == 1 then
				fail(who, "block %s starts at bar 1 (the capture reset) and must have no warm-up, it has %s session(s)", tostring(i), tostring(b.warmSessions))
			elseif wantWarmSessions > 0 and b.warmSessions == 0 then
				fail(who, "block %s has no warm-up but needs %s preceding session(s) (missing warm-up)", tostring(i), tostring(wantWarmSessions))
			end
			fail(who, "block %s warm-up covers %s session(s), expected %s", tostring(i), tostring(b.warmSessions), tostring(wantWarmSessions))
		end
		if b.warmLastSession ~= b.firstSession - 1 or b.warmFirstSession ~= b.firstSession - wantWarmSessions then
			fail(who, "block %s warm-up sessions %s..%s are not the %s session(s) immediately before session %s",
				tostring(i), tostring(b.warmFirstSession), tostring(b.warmLastSession), tostring(wantWarmSessions), tostring(b.firstSession))
		end
		local wantWarmFirstIndex = sessions[b.firstSession - wantWarmSessions].firstIndex
		if b.warmFirstIndex ~= wantWarmFirstIndex or b.warmLastIndex ~= b.firstIndex - 1 then
			fail(who, "block %s warm-up bars %s..%s are not the bars immediately before the block (expected %s..%s)",
				tostring(i), tostring(b.warmFirstIndex), tostring(b.warmLastIndex), tostring(wantWarmFirstIndex), tostring(b.firstIndex - 1))
		end
		local wantWarmBars = b.firstIndex - wantWarmFirstIndex
		if b.warmBars ~= wantWarmBars or b.steppedBars ~= wantWarmBars + b.bars then
			fail(who, "block %s warmBars/steppedBars are %s/%s, expected %s/%s", tostring(i), tostring(b.warmBars), tostring(b.steppedBars),
				tostring(wantWarmBars), tostring(wantWarmBars + b.bars))
		end

		-- Rule 3: round-robin lane and slot.
		local wantLane = (i - 1) % lanes + 1
		if b.lane ~= wantLane then
			fail(who, "block %s is on lane %s, round-robin over %s lanes gives lane %s", tostring(i), tostring(b.lane), tostring(lanes), tostring(wantLane))
		end
		local queue = wantQueues[wantLane]
		queue[#queue + 1] = i
		if b.slot ~= #queue then fail(who, "block %s slot is %s, expected %s", tostring(i), tostring(b.slot), tostring(#queue)) end

		nextBar, nextSession = b.lastIndex + 1, b.lastSession + 1
		decidedTotal += b.bars
		warmupBars += wantWarmBars
		wantLaneBars[wantLane] += wantWarmBars + b.bars
		wantLaneDecided[wantLane] += b.bars
		wantLaneBlocks[wantLane] += 1
	end
	if nextBar - 1 ~= totalBars or nextSession - 1 ~= sessionCount or decidedTotal ~= totalBars then
		fail(who, "blocks decide %s of %s bars (%s of %s sessions): every bar must be decided exactly once",
			tostring(decidedTotal), tostring(totalBars), tostring(nextSession - 1), tostring(sessionCount))
	end

	-- Lane queues: exactly `lanes` queues, each in time order, matching the round-robin assignment.
	local queues = schedule.laneQueues
	if type(queues) ~= "table" then fail(who, "schedule.laneQueues missing") end
	local queueKeys = 0
	for _ in queues do queueKeys += 1 end
	if queueKeys ~= lanes or #queues ~= lanes then fail(who, "laneQueues must hold exactly %s queues", tostring(lanes)) end
	for lane = 1, lanes do
		local queue, want = queues[lane], wantQueues[lane]
		if type(queue) ~= "table" then fail(who, "lane %s queue is not a table", tostring(lane)) end
		local keys, previousId = 0, 0
		for _ in queue do keys += 1 end
		if keys ~= #queue then fail(who, "lane %s queue is not a dense array", tostring(lane)) end
		for k = 1, #queue do
			local id = queue[k]
			if not isInteger(id) or id <= previousId then
				fail(who, "lane %s queue is not in strictly increasing time order at position %s (block %s after block %s)",
					tostring(lane), tostring(k), tostring(id), tostring(previousId))
			end
			previousId = id
		end
		if #queue ~= #want then
			fail(who, "lane %s queue holds %s block(s), round-robin gives %s", tostring(lane), tostring(#queue), tostring(#want))
		end
		for k = 1, #want do
			if queue[k] ~= want[k] then
				fail(who, "lane %s queue position %s holds block %s, round-robin assigns block %s", tostring(lane), tostring(k), tostring(queue[k]), tostring(want[k]))
			end
		end
	end

	-- Rule 4: decision order is every block in time order.
	local order = schedule.decisionOrder
	if type(order) ~= "table" or #order ~= #blocks then fail(who, "decisionOrder must list all %s blocks", tostring(#blocks)) end
	for k = 1, #blocks do
		if order[k] ~= blocks[k].id then
			fail(who, "decisionOrder position %s holds block %s, time order needs block %s", tostring(k), tostring(order[k]), tostring(blocks[k].id))
		end
	end

	-- Stats recomputed from the sessions and the verified blocks.
	local stats = schedule.stats
	if type(stats) ~= "table" then fail(who, "schedule.stats missing") end
	local function stat(name, want)
		if stats[name] ~= want then fail(who, "stats.%s is %s, recomputed %s", name, tostring(stats[name]), tostring(want)) end
	end
	local function statArray(name, want)
		if not sameArray(stats[name], want) then
			fail(who, "stats.%s differs from the recomputed per-lane values (%s)", name, table.concat(want, ","))
		end
	end
	local maxLaneBars = 0
	for lane = 1, lanes do maxLaneBars = math.max(maxLaneBars, wantLaneBars[lane]) end
	stat("sessions", sessionCount)
	stat("bars", totalBars)
	stat("blocks", #blocks)
	stat("lanes", lanes)
	stat("warmupBars", warmupBars)
	stat("steppedBars", totalBars + warmupBars)
	stat("overheadFraction", warmupBars / totalBars)
	statArray("perLaneBars", wantLaneBars)
	statArray("perLaneDecidedBars", wantLaneDecided)
	statArray("perLaneBlocks", wantLaneBlocks)
	stat("maxLaneBars", maxLaneBars)
	if type(stats.etaSeconds) ~= "function" then fail(who, "stats.etaSeconds must be a function") end
	local okEta, eta = pcall(stats.etaSeconds, 1)
	if not okEta or eta ~= maxLaneBars then fail(who, "stats.etaSeconds(1) is %s, expected maxLaneBars %s", tostring(eta), tostring(maxLaneBars)) end
	return true
end

return SpringBlockSchedule
