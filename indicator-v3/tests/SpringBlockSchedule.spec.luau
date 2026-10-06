-- SpringBlockSchedule spec (spring-live-contract.md section 1b, L18/L19). Self-running:
--   luau.exe tests/SpringBlockSchedule.spec.luau        (cwd does not matter; requires resolve relative to this file)
-- Pure Luau, no Roblox API. The REAL 469-session list comes from an optional fixture derived from the downloaded market
-- data via indicator-v2/bridge.mjs loadDataset({symbol:'SPY',train:20,validation:5,test:444,end:'2026-10-02'}).
-- The fixture (and the small generator used during development) is NOT included in the public repository because it is
-- derived from market data. Place it at indicator-v3/data/SpringRealSessions.luau (or tests/SpringRealSessions.luau) to
-- run the real-list tests; it carries a digest and a reference model for N = 1, 2, 3, 6, 8, 10 lanes.
-- Without the fixture the synthetic tests still run and the real-list tests are reported as skipped.
local loaded, SBS = pcall(require, "../src/SpringBlockSchedule")
assert(loaded and type(SBS) == "table", "SpringBlockSchedule must load without Roblox globals: " .. tostring(SBS))

local passed = 0
local function test(name, fn)
	fn()
	passed += 1
	print("PASS " .. name)
end
local function rejects(fn, fragment)
	local ok, err = pcall(fn)
	assert(not ok, "expected a rejection containing '" .. fragment .. "'")
	assert(string.find(tostring(err), fragment, 1, true), "wrong rejection: " .. tostring(err) .. " (expected '" .. fragment .. "')")
	return tostring(err)
end
local function measure(text) print("MEASURE " .. text) end

local function deepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in v do out[k] = deepCopy(x) end
	return out
end
local function deepFreeze(t)
	for _, v in t do if type(v) == "table" then deepFreeze(v) end end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end
local function arrayEquals(a, b)
	if #a ~= #b then return false end
	for i = 1, #a do if a[i] ~= b[i] then return false end end
	return true
end
local function join(a) return table.concat(a, ",") end

------------------------------------------------------------------------------------------------------------------------
-- Synthetic session lists
local function dayOf(i) return string.format("2031-%02d-%02d", (i - 1) // 28 + 1, (i - 1) % 28 + 1) end
local function makeSessions(lengths)
	local out, nextBar = {}, 1
	for i, n in lengths do
		out[i] = { day = dayOf(i), firstIndex = nextBar, lastIndex = nextBar + n - 1 }
		nextBar += n
	end
	return out
end
local function daysOf(first, last)
	local out = {}
	for i = first, last do out[#out + 1] = dayOf(i) end
	return out
end
-- Eleven uneven sessions: starts 1,4,9,11,15,21,22,25,27,31,33 and 37 bars in all.
local ELEVEN = makeSessions({ 3, 5, 2, 4, 6, 1, 3, 2, 4, 2, 5 })
-- Twelve uneven sessions (4,4,2,4,4 | 4,3,4,4,4 | 4,1): 42 bars in all, the last session is a single bar.
local TWELVE = makeSessions({ 4, 4, 2, 4, 4, 4, 3, 4, 4, 4, 4, 1 })

local BLOCK_FIELDS = { "id", "lane", "slot", "firstSession", "lastSession", "firstIndex", "lastIndex", "bars", "warmSessions", "warmFirstSession",
	"warmLastSession", "warmFirstIndex", "warmLastIndex", "warmBars", "steppedBars" }
-- spec = { id, lane, slot, firstSession, lastSession, firstIndex, lastIndex, bars, warmSessions, warmFirstSession, warmLastSession,
--          warmFirstIndex, warmLastIndex, warmBars, steppedBars } in BLOCK_FIELDS order, plus days
local function expectBlock(b, values, days, label)
	for k, name in BLOCK_FIELDS do
		assert(b[name] == values[k], label .. ": " .. name .. " is " .. tostring(b[name]) .. ", expected " .. tostring(values[k]))
	end
	assert(arrayEquals(b.days, days), label .. ": days " .. join(b.days) .. " expected " .. join(days))
end

------------------------------------------------------------------------------------------------------------------------
-- Independent bar-level model of what the lanes would do. It reads the schedule's block ranges and re-derives the
-- semantics bar by bar (which session each bar belongs to, how often it is decided, what each lane steps and when it
-- restarts from rest). It returns a list of problems; empty means every rule held. It shares no code with verify().
local function audit(schedule, sessions)
	local problems = {}
	local function bad(text) if #problems < 8 then problems[#problems + 1] = text end end
	local total = sessions[#sessions].lastIndex
	local config = schedule.config
	local sessionOf = table.create(total)
	for s, sess in sessions do
		for i = sess.firstIndex, sess.lastIndex do sessionOf[i] = s end
	end
	local decided = table.create(total, 0)
	local listed = {}
	for lane = 1, config.lanes do
		local previousLast = 0
		for position, id in schedule.laneQueues[lane] do
			listed[id] = (listed[id] or 0) + 1
			local b = schedule.blocks[id]
			if b == nil then
				bad("lane " .. lane .. " lists unknown block " .. tostring(id))
				continue
			end
			if b.lane ~= lane or (id - 1) % config.lanes + 1 ~= lane then bad("block " .. id .. " is queued on lane " .. lane .. " but is not round-robin") end
			if b.firstIndex <= previousLast then bad("lane " .. lane .. " queue is not in time order at block " .. id) end
			previousLast = b.lastIndex
			-- The lane restarts from rest and steps warmFirstIndex..lastIndex without a break.
			local firstSession = sessionOf[b.firstIndex]
			local wantWarm = math.min(config.warmupSessions, firstSession - 1)
			local warmSeen, warmBars = {}, 0
			for i = b.warmFirstIndex, b.firstIndex - 1 do
				local s = sessionOf[i]
				if s == nil then bad("block " .. id .. " warm-up bar " .. i .. " does not exist"); break end
				if warmSeen[s] == nil then warmSeen[s] = 0 end
				warmSeen[s] += 1
				warmBars += 1
			end
			local seenCount, wantBars = 0, 0
			for s, n in warmSeen do
				seenCount += 1
				if s < firstSession - wantWarm or s >= firstSession then bad("block " .. id .. " warm-up uses session " .. s .. " which is not just before it") end
				if n ~= sessions[s].lastIndex - sessions[s].firstIndex + 1 then bad("block " .. id .. " warm-up covers session " .. s .. " only partly") end
			end
			for s = firstSession - wantWarm, firstSession - 1 do wantBars += sessions[s].lastIndex - sessions[s].firstIndex + 1 end
			if seenCount ~= wantWarm or warmBars ~= wantBars then
				bad("block " .. id .. " warm-up has " .. warmBars .. " bars in " .. seenCount .. " sessions, expected " .. wantBars .. " in " .. wantWarm)
			end
			if id == 1 and (warmBars ~= 0 or b.firstIndex ~= 1) then bad("the first block must start at bar 1 with no warm-up") end
			-- The block's own bars: whole sessions, decided here.
			for i = b.firstIndex, b.lastIndex do
				if decided[i] == nil then bad("block " .. id .. " decides bar " .. i .. " which does not exist"); break end
				decided[i] += 1
			end
			if sessionOf[b.firstIndex] and sessions[sessionOf[b.firstIndex]].firstIndex ~= b.firstIndex then bad("block " .. id .. " starts mid-session") end
			if sessionOf[b.lastIndex] and sessions[sessionOf[b.lastIndex]].lastIndex ~= b.lastIndex then bad("block " .. id .. " ends mid-session") end
		end
	end
	for id in schedule.blocks do
		if listed[id] ~= 1 then bad("block " .. id .. " is in " .. tostring(listed[id] or 0) .. " lane queues") end
	end
	for i = 1, total do
		if decided[i] ~= 1 then bad("bar " .. i .. " is decided " .. decided[i] .. " times"); break end
	end
	local previous = 0
	for k, id in schedule.decisionOrder do
		local b = schedule.blocks[id]
		if b == nil or b.firstIndex <= previous then bad("decisionOrder is not in time order at position " .. k); break end
		previous = b.firstIndex
	end
	if #schedule.decisionOrder ~= #schedule.blocks then bad("decisionOrder does not list every block") end
	return problems
end
local function assertAudit(schedule, sessions, label)
	local ok, problems = pcall(audit, schedule, sessions)
	assert(ok, label .. ": audit raised " .. tostring(problems))
	assert(#problems == 0, label .. ": audit found " .. join(problems))
end

------------------------------------------------------------------------------------------------------------------------
test("build: hand-computed blocks, lanes, slots and warm-up for 12 uneven sessions on 2 lanes", function()
	local sch = SBS.build(TWELVE, { lanes = 2 })
	assert(sch.schema == SBS.SCHEMA and #sch.blocks == 3)
	assert(sch.config.lanes == 2 and sch.config.blockSessions == 5 and sch.config.warmupSessions == 1, "defaults 5 and 1")
	expectBlock(sch.blocks[1], { 1, 1, 1, 1, 5, 1, 18, 18, 0, 1, 0, 1, 0, 0, 18 }, daysOf(1, 5), "block 1")
	expectBlock(sch.blocks[2], { 2, 2, 1, 6, 10, 19, 37, 19, 1, 5, 5, 15, 18, 4, 23 }, daysOf(6, 10), "block 2")
	expectBlock(sch.blocks[3], { 3, 1, 2, 11, 12, 38, 42, 5, 1, 10, 10, 34, 37, 4, 9 }, daysOf(11, 12), "block 3")
	assert(arrayEquals(sch.laneQueues[1], { 1, 3 }) and arrayEquals(sch.laneQueues[2], { 2 }) and #sch.laneQueues == 2)
	assert(arrayEquals(sch.decisionOrder, { 1, 2, 3 }))
	local st = sch.stats
	assert(st.sessions == 12 and st.bars == 42 and st.blocks == 3 and st.lanes == 2)
	assert(st.warmupBars == 8 and st.steppedBars == 50, "warm-up is block 2's 4 bars plus block 3's 4 bars")
	assert(st.overheadFraction == 8 / 42, "overhead is warm-up bars over decided bars, got " .. st.overheadFraction)
	assert(arrayEquals(st.perLaneBars, { 27, 23 }), "lane 1 steps 18 + 9, lane 2 steps 23: " .. join(st.perLaneBars))
	assert(arrayEquals(st.perLaneDecidedBars, { 23, 19 }) and arrayEquals(st.perLaneBlocks, { 2, 1 }) and st.maxLaneBars == 27)
	assert(SBS.verify(sch, TWELVE) == true)
	assertAudit(sch, TWELVE, "twelve")
end)

test("build: warm-up is the two immediately preceding sessions (K=3, W=2, 3 lanes), clamped at bar 1", function()
	local sch = SBS.build(ELEVEN, { lanes = 3, blockSessions = 3, warmupSessions = 2 })
	assert(#sch.blocks == 4)
	expectBlock(sch.blocks[1], { 1, 1, 1, 1, 3, 1, 10, 10, 0, 1, 0, 1, 0, 0, 10 }, daysOf(1, 3), "block 1")
	expectBlock(sch.blocks[2], { 2, 2, 1, 4, 6, 11, 21, 11, 2, 2, 3, 4, 10, 7, 18 }, daysOf(4, 6), "block 2")
	expectBlock(sch.blocks[3], { 3, 3, 1, 7, 9, 22, 30, 9, 2, 5, 6, 15, 21, 7, 16 }, daysOf(7, 9), "block 3")
	expectBlock(sch.blocks[4], { 4, 1, 2, 10, 11, 31, 37, 7, 2, 8, 9, 25, 30, 6, 13 }, daysOf(10, 11), "block 4")
	assert(arrayEquals(sch.laneQueues[1], { 1, 4 }) and arrayEquals(sch.laneQueues[2], { 2 }) and arrayEquals(sch.laneQueues[3], { 3 }))
	assert(sch.stats.warmupBars == 20 and arrayEquals(sch.stats.perLaneBars, { 23, 18, 16 }) and sch.stats.maxLaneBars == 23)
	assert(sch.stats.overheadFraction == 20 / 37)
	-- A warm-up longer than the history before the block is clamped to bar 1: block 2 can only warm up on sessions 1..3.
	local clamped = SBS.build(ELEVEN, { lanes = 3, blockSessions = 3, warmupSessions = 4 })
	expectBlock(clamped.blocks[2], { 2, 2, 1, 4, 6, 11, 21, 11, 3, 1, 3, 1, 10, 10, 21 }, daysOf(4, 6), "clamped block 2")
	expectBlock(clamped.blocks[3], { 3, 3, 1, 7, 9, 22, 30, 9, 4, 3, 6, 9, 21, 13, 22 }, daysOf(7, 9), "clamped block 3")
	expectBlock(clamped.blocks[4], { 4, 1, 2, 10, 11, 31, 37, 7, 4, 6, 9, 21, 30, 10, 17 }, daysOf(10, 11), "clamped block 4")
	assert(clamped.stats.warmupBars == 33)
	assert(SBS.verify(sch, ELEVEN) and SBS.verify(clamped, ELEVEN))
	assertAudit(sch, ELEVEN, "K3W2")
	assertAudit(clamped, ELEVEN, "K3W4")
end)

test("build: only the first block lacks a warm-up, and its warm-up range is empty (first = last + 1)", function()
	for _, lanes in { 1, 2, 5 } do
		local sch = SBS.build(ELEVEN, { lanes = lanes })
		local first = sch.blocks[1]
		assert(first.firstIndex == 1 and first.warmSessions == 0 and first.warmBars == 0, "first block starts at the capture reset with no warm-up")
		assert(first.warmFirstIndex == 1 and first.warmLastIndex == 0 and first.warmFirstSession == 1 and first.warmLastSession == 0)
		local steps = 0
		for _ = first.warmFirstIndex, first.warmLastIndex do steps += 1 end
		assert(steps == 0, "an empty warm-up range runs zero iterations")
		for id = 2, #sch.blocks do
			local b = sch.blocks[id]
			assert(b.warmSessions == 1 and b.warmBars > 0, "block " .. id .. " must have a one-session warm-up")
			assert(b.warmLastIndex == b.firstIndex - 1 and b.warmLastSession == b.firstSession - 1)
		end
	end
end)

test("build: warmupSessions = 0 gives no warm-up anywhere and zero overhead", function()
	local sch = SBS.build(ELEVEN, { lanes = 3, blockSessions = 3, warmupSessions = 0 })
	assert(sch.stats.warmupBars == 0 and sch.stats.overheadFraction == 0 and sch.stats.steppedBars == 37)
	for _, b in sch.blocks do
		assert(b.warmSessions == 0 and b.warmBars == 0 and b.warmFirstIndex == b.firstIndex and b.warmLastIndex == b.firstIndex - 1 and b.steppedBars == b.bars)
	end
	assert(arrayEquals(sch.stats.perLaneBars, { 17, 11, 9 }) and arrayEquals(sch.stats.perLaneBars, sch.stats.perLaneDecidedBars))
	assert(SBS.verify(sch, ELEVEN))
	assertAudit(sch, ELEVEN, "W0")
end)

test("build: blockSessions larger than the run gives one block on lane 1 and empty queues for the other lanes", function()
	local sch = SBS.build(ELEVEN, { lanes = 3, blockSessions = 20 })
	assert(#sch.blocks == 1 and sch.blocks[1].firstSession == 1 and sch.blocks[1].lastSession == 11 and sch.blocks[1].bars == 37)
	assert(#sch.laneQueues == 3 and arrayEquals(sch.laneQueues[1], { 1 }) and #sch.laneQueues[2] == 0 and #sch.laneQueues[3] == 0)
	assert(arrayEquals(sch.stats.perLaneBars, { 37, 0, 0 }) and sch.stats.maxLaneBars == 37 and sch.stats.warmupBars == 0)
	assert(SBS.verify(sch, ELEVEN))
	assertAudit(sch, ELEVEN, "single block")
end)

test("build: more lanes than blocks leaves the surplus lanes with empty queues", function()
	local sch = SBS.build(ELEVEN, { lanes = 6, blockSessions = 3, warmupSessions = 2 })
	assert(#sch.blocks == 4 and #sch.laneQueues == 6)
	for lane = 1, 4 do assert(arrayEquals(sch.laneQueues[lane], { lane }), "lane " .. lane) end
	assert(#sch.laneQueues[5] == 0 and #sch.laneQueues[6] == 0)
	assert(arrayEquals(sch.stats.perLaneBars, { 10, 18, 16, 13, 0, 0 }) and sch.stats.maxLaneBars == 18 and arrayEquals(sch.stats.perLaneBlocks, { 1, 1, 1, 1, 0, 0 }))
	assert(SBS.verify(sch, ELEVEN))
	assertAudit(sch, ELEVEN, "surplus lanes")
end)

test("build: blockSessions = 1 makes every session a block, round-robin over 4 lanes", function()
	local sch = SBS.build(ELEVEN, { lanes = 4, blockSessions = 1 })
	assert(#sch.blocks == 11)
	local lanes, slots = { 1, 2, 3, 4, 1, 2, 3, 4, 1, 2, 3 }, { 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3 }
	local starts = { 1, 4, 9, 11, 15, 21, 22, 25, 27, 31, 33 }
	local warmFirst = { 1, 1, 4, 9, 11, 15, 21, 22, 25, 27, 31 }
	local warmBars = { 0, 3, 5, 2, 4, 6, 1, 3, 2, 4, 2 }
	for id = 1, 11 do
		local b = sch.blocks[id]
		assert(b.lane == lanes[id] and b.slot == slots[id], "block " .. id .. " lane/slot " .. b.lane .. "/" .. b.slot)
		assert(b.firstSession == id and b.lastSession == id and b.firstIndex == starts[id])
		assert(b.warmFirstIndex == warmFirst[id] and b.warmBars == warmBars[id], "block " .. id .. " warm-up " .. b.warmFirstIndex .. "/" .. b.warmBars)
	end
	assert(arrayEquals(sch.laneQueues[1], { 1, 5, 9 }) and arrayEquals(sch.laneQueues[2], { 2, 6, 10 }) and arrayEquals(sch.laneQueues[3], { 3, 7, 11 }) and arrayEquals(sch.laneQueues[4], { 4, 8 }))
	assert(SBS.verify(sch, ELEVEN))
	assertAudit(sch, ELEVEN, "K1")
end)

test("build: a run that is an exact multiple of blockSessions has no short last block; otherwise the last one is shorter", function()
	local ten = makeSessions({ 3, 3, 3, 3, 3, 3, 3, 3, 3, 3 })
	local even = SBS.build(ten, { lanes = 2 })
	assert(#even.blocks == 2 and even.blocks[1].lastSession - even.blocks[1].firstSession == 4 and even.blocks[2].lastSession - even.blocks[2].firstSession == 4)
	local odd = SBS.build(makeSessions({ 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3 }), { lanes = 2 })
	assert(#odd.blocks == 3 and odd.blocks[3].firstSession == 11 and odd.blocks[3].lastSession == 11 and odd.blocks[3].bars == 3)
	assert(odd.blocks[3].warmFirstSession == 10 and odd.blocks[3].warmBars == 3)
	local one = SBS.build(makeSessions({ 5 }), { lanes = 4 })
	assert(#one.blocks == 1 and one.blocks[1].bars == 5 and one.stats.warmupBars == 0 and one.stats.overheadFraction == 0)
end)

test("build: round-robin lane for 11 blocks on 3 lanes, queues in time order, decisionOrder is time order", function()
	local sch = SBS.build(makeSessions({ 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2 }), { lanes = 3, blockSessions = 1 })
	assert(#sch.blocks == 11)
	local want = { 1, 2, 3, 1, 2, 3, 1, 2, 3, 1, 2 }
	for id = 1, 11 do assert(sch.blocks[id].lane == want[id], "block " .. id) end
	assert(arrayEquals(sch.laneQueues[1], { 1, 4, 7, 10 }) and arrayEquals(sch.laneQueues[2], { 2, 5, 8, 11 }) and arrayEquals(sch.laneQueues[3], { 3, 6, 9 }))
	assert(arrayEquals(sch.decisionOrder, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }))
	for id = 2, 11 do assert(sch.blocks[id].firstIndex == sch.blocks[id - 1].lastIndex + 1) end
	for lane = 1, 3 do
		for k = 2, #sch.laneQueues[lane] do assert(sch.laneQueues[lane][k] > sch.laneQueues[lane][k - 1]) end
	end
end)

test("build: deterministic, leaves its input untouched, and returns a deep-frozen schedule", function()
	local frozenInput = deepFreeze(deepCopy(ELEVEN))
	local a = SBS.build(frozenInput, { lanes = 3, blockSessions = 3 })
	local b = SBS.build(deepCopy(ELEVEN), { lanes = 3, blockSessions = 3 })
	assert(table.isfrozen(a) and table.isfrozen(a.blocks) and table.isfrozen(a.blocks[1]) and table.isfrozen(a.blocks[1].days))
	assert(table.isfrozen(a.laneQueues) and table.isfrozen(a.laneQueues[1]) and table.isfrozen(a.decisionOrder) and table.isfrozen(a.stats) and table.isfrozen(a.stats.perLaneBars) and table.isfrozen(a.config))
	assert(not pcall(function() a.blocks[1].lane = 9 end) and not pcall(function() a.stats.bars = 1 end) and not pcall(function() table.insert(a.laneQueues[1], 99) end))
	local function flat(s, prefix, out)
		for k, v in s do
			if type(v) == "table" then flat(v, prefix .. tostring(k) .. ".", out)
			elseif type(v) ~= "function" then out[prefix .. tostring(k)] = v end
		end
		return out
	end
	local fa, fb = flat(a, "", {}), flat(b, "", {})
	local count = 0
	for k, v in fa do
		count += 1
		assert(fb[k] == v, "build is not deterministic at " .. k)
	end
	for k in fb do assert(fa[k] ~= nil, "second build has an extra field " .. k) end
	assert(count == 100, "flat leaf count " .. count .. " (schema 1, config 3, 4 blocks x 15, 11 days, 4 queue entries, 4 order entries, 8 stats scalars, 9 per-lane values)")
	assert(ELEVEN[1].firstIndex == 1 and #ELEVEN == 11, "the input list must be unchanged")
end)

test("etaSeconds: busiest lane over the per-lane rate, as a stats closure and as a module function; bad rates rejected", function()
	local sch = SBS.build(ELEVEN, { lanes = 3, blockSessions = 3, warmupSessions = 2 })
	assert(sch.stats.maxLaneBars == 23)
	assert(sch.stats.etaSeconds(1) == 23 and sch.stats.etaSeconds(2) == 11.5 and sch.stats.etaSeconds(23) == 1)
	assert(SBS.etaSeconds(sch, 4) == 5.75 and SBS.etaSeconds(sch, 4) == sch.stats.etaSeconds(4))
	for _, bad in { 0, -1, math.huge, 0 / 0, "3" :: any, true :: any } do
		rejects(function() sch.stats.etaSeconds(bad) end, "barsPerSecondPerLane")
		rejects(function() SBS.etaSeconds(sch, bad) end, "barsPerSecondPerLane")
	end
	rejects(function() SBS.etaSeconds({}, 1) end, "stats.maxLaneBars")
end)

test("build rejects a malformed session list", function()
	local function good() return makeSessions({ 3, 3, 3 }) end
	rejects(function() SBS.build(nil :: any, { lanes = 2 }) end, "sessions must be an array")
	rejects(function() SBS.build({}, { lanes = 2 }) end, "sessions is empty")
	local holes = good()
	holes[5] = good()[1]
	rejects(function() SBS.build(holes, { lanes = 2 }) end, "dense")
	local noDay = good()
	noDay[2].day = nil :: any
	rejects(function() SBS.build(noDay, { lanes = 2 }) end, "no day string")
	local badIndex = good()
	badIndex[2].firstIndex = 4.5
	rejects(function() SBS.build(badIndex, { lanes = 2 }) end, "integer firstIndex and lastIndex")
	local inverted = good()
	inverted[2].lastIndex = inverted[2].firstIndex - 1
	rejects(function() SBS.build(inverted, { lanes = 2 }) end, "empty or inverted")
	local gap = good()
	gap[2].firstIndex += 1
	gap[2].lastIndex += 1
	rejects(function() SBS.build(gap, { lanes = 2 }) end, "gap or overlap")
	local overlap = good()
	overlap[2].firstIndex -= 1
	rejects(function() SBS.build(overlap, { lanes = 2 }) end, "gap or overlap")
	local late = makeSessions({ 3, 3 })
	for _, s in late do s.firstIndex += 1; s.lastIndex += 1 end
	rejects(function() SBS.build(late, { lanes = 2 }) end, "contiguous from bar 1")
	local sameDay = good()
	sameDay[3].day = sameDay[2].day
	rejects(function() SBS.build(sameDay, { lanes = 2 }) end, "days must ascend")
	local backwards = good()
	backwards[2].day, backwards[3].day = backwards[3].day, backwards[2].day
	rejects(function() SBS.build(backwards, { lanes = 2 }) end, "days must ascend")
end)

test("build rejects malformed options (typos, non-integers, out-of-range counts)", function()
	rejects(function() SBS.build(ELEVEN, nil :: any) end, "options table")
	rejects(function() SBS.build(ELEVEN, {}) end, "lanes must be an integer")
	for _, lanes in { 0, -2, 1.5, 0 / 0, math.huge, "6" :: any } do
		rejects(function() SBS.build(ELEVEN, { lanes = lanes }) end, "lanes must be an integer")
	end
	rejects(function() SBS.build(ELEVEN, { lanes = 2, blockSessions = 0 }) end, "blockSessions must be an integer")
	rejects(function() SBS.build(ELEVEN, { lanes = 2, blockSessions = 2.5 }) end, "blockSessions must be an integer")
	rejects(function() SBS.build(ELEVEN, { lanes = 2, warmupSessions = -1 }) end, "warmupSessions must be an integer")
	rejects(function() SBS.build(ELEVEN, { lanes = 2, warmupSessions = 0.5 }) end, "warmupSessions must be an integer")
	rejects(function() SBS.build(ELEVEN, { lanes = 2, warmup = 3 }) end, "unknown option 'warmup'")
	rejects(function() SBS.build(ELEVEN, { lanes = 2, blocksessions = 3 }) end, "unknown option 'blocksessions'")
end)

------------------------------------------------------------------------------------------------------------------------
-- verify: positive sweep with the independent audit, then mutation sensitivity.
local function lcg(seed)
	local x = seed
	return function(n)
		x = (x * 48271) % 2147483647
		return x % n
	end
end

test("sweep: build -> verify -> independent audit over 300 random session lists and (lanes, blockSessions, warmupSessions)", function()
	local rand = lcg(20261005)
	local trials, blocksTotal = 0, 0
	for _ = 1, 300 do
		local count = 1 + rand(40)
		local lengths = {}
		for i = 1, count do
			local r = rand(10)
			lengths[i] = if r < 7 then 78 elseif r < 8 then 42 else 1 + rand(78)
		end
		local sessions = makeSessions(lengths)
		local opts = { lanes = 1 + rand(10), blockSessions = 1 + rand(8), warmupSessions = rand(4) }
		local sch = SBS.build(sessions, opts)
		local tag = "trial " .. trials .. " " .. count .. " sessions lanes=" .. opts.lanes .. " K=" .. opts.blockSessions .. " W=" .. opts.warmupSessions
		local ok, err = pcall(SBS.verify, sch, sessions)
		assert(ok and err == true, tag .. ": verify rejected a built schedule: " .. tostring(err))
		assertAudit(sch, sessions, tag)
		assert(#sch.blocks == math.ceil(count / opts.blockSessions), tag .. ": block count")
		trials += 1
		blocksTotal += #sch.blocks
	end
	assert(trials == 300 and blocksTotal > 300)
end)

local function mutated(schedule, mutate)
	local copy = deepCopy(schedule)
	mutate(copy)
	return copy
end

-- A control first: an unmutated deep copy must verify, otherwise every "rejected" below could be a copy artefact.
local function baseline(sessions, opts)
	local sch = SBS.build(sessions, opts)
	local control = deepCopy(sch)
	assert(SBS.verify(control, sessions) == true, "control copy must verify")
	return sch
end

test("verify: named plausible bugs are each rejected with the rule they break (K=5, W=2, 3 lanes, 22 sessions)", function()
	local sessions = makeSessions({ 4, 4, 2, 4, 4, 4, 3, 4, 4, 4, 4, 1, 4, 4, 2, 4, 4, 4, 3, 4, 4, 4 })
	local good = baseline(sessions, { lanes = 3, blockSessions = 5, warmupSessions = 2 })
	assert(#good.blocks == 5 and good.blocks[3].warmSessions == 2 and good.blocks[5].lane == 2)
	local cases = {
		{ "overlap: block 2 starts one bar before its predecessor ends", "overlap", function(m)
			m.blocks[2].firstIndex -= 1
		end },
		{ "gap: block 3 starts one bar late", "gap", function(m)
			m.blocks[3].firstIndex += 1
		end },
		{ "gap: bars of a whole session are decided by no block", "gap", function(m)
			local b = m.blocks[4]
			b.firstIndex += 4
			b.firstSession += 1
		end },
		{ "a block runs one bar into its successor", "session boundary", function(m)
			m.blocks[2].lastIndex += 1
			m.blocks[2].bars += 1
		end },
		{ "a block stops one bar short", "session boundary", function(m)
			m.blocks[2].lastIndex -= 1
			m.blocks[2].bars -= 1
		end },
		{ "mid-session split that still tiles the bars (2 bars move from block 1 to block 2)", "session boundary", function(m)
			m.blocks[1].lastIndex += 2
			m.blocks[1].bars += 2
			m.blocks[2].firstIndex += 2
			m.blocks[2].bars -= 2
		end },
		{ "the last block is dropped (bars after block 4 are never decided)", "block count", function(m)
			table.remove(m.blocks)
		end },
		{ "a middle block is dropped", "block count", function(m)
			table.remove(m.blocks, 3)
		end },
		{ "an extra block is appended", "block count", function(m)
			table.insert(m.blocks, deepCopy(m.blocks[#m.blocks]))
		end },
		{ "wrong order: blocks 2 and 3 are swapped in the list", "time order", function(m)
			m.blocks[2], m.blocks[3] = m.blocks[3], m.blocks[2]
		end },
		{ "wrong order: blocks are listed newest first", "time order", function(m)
			local reversed = {}
			for i = #m.blocks, 1, -1 do reversed[#reversed + 1] = m.blocks[i] end
			m.blocks = reversed
		end },
		{ "the first block is given a warm-up (reaches before bar 1)", "no warm-up", function(m)
			local b = m.blocks[1]
			b.warmSessions, b.warmFirstSession, b.warmFirstIndex, b.warmBars, b.steppedBars = 1, 0, 0, 1, b.steppedBars + 1
		end },
		{ "missing warm-up: block 3 starts from rest and decides immediately", "missing warm-up", function(m)
			local b = m.blocks[3]
			b.warmSessions, b.warmFirstSession, b.warmFirstIndex, b.warmBars, b.steppedBars = 0, b.firstSession, b.firstIndex, 0, b.bars
		end },
		{ "warm-up one session too short (a one-session warm-up where two are configured)", "warm-up covers", function(m)
			local b = m.blocks[3]
			local keep = sessions[b.firstSession - 1]
			b.warmSessions, b.warmFirstSession, b.warmFirstIndex = 1, b.firstSession - 1, keep.firstIndex
			b.warmBars = b.firstIndex - keep.firstIndex
			b.steppedBars = b.warmBars + b.bars
		end },
		{ "warm-up one session too long", "warm-up covers", function(m)
			local b = m.blocks[3]
			b.warmSessions, b.warmFirstSession = 3, b.firstSession - 3
		end },
		{ "warm-up taken from earlier sessions, not the immediately preceding ones", "immediately", function(m)
			local b = m.blocks[3]
			b.warmFirstSession -= 1
			b.warmLastSession -= 1
		end },
		{ "warm-up bars shifted one bar early", "immediately before the block", function(m)
			local b = m.blocks[3]
			b.warmFirstIndex -= 1
			b.warmLastIndex -= 1
		end },
		{ "warm-up overlaps the first decided bar", "immediately before the block", function(m)
			local b = m.blocks[3]
			b.warmLastIndex += 1
		end },
		{ "warm-up bar count stale", "warmBars/steppedBars", function(m)
			m.blocks[3].warmBars += 1
		end },
		{ "lane = id % lanes (0-based wrap)", "round-robin", function(m)
			for _, b in m.blocks do b.lane = b.id % 3 end
		end },
		{ "every block on lane 1", "round-robin", function(m)
			for _, b in m.blocks do b.lane = 1 end
		end },
		{ "one block on the wrong lane", "round-robin", function(m)
			m.blocks[4].lane = 2
		end },
		{ "lane queue reversed", "time order", function(m)
			m.laneQueues[1][1], m.laneQueues[1][2] = m.laneQueues[1][2], m.laneQueues[1][1]
		end },
		{ "a block is missing from its lane queue", "queue holds", function(m)
			table.remove(m.laneQueues[2])
		end },
		{ "a block is queued on the wrong lane", "queue", function(m)
			local moved = table.remove(m.laneQueues[1], 1)
			table.insert(m.laneQueues[3], moved)
			table.sort(m.laneQueues[3])
		end },
		{ "a lane queue is lost", "exactly 3 queues", function(m)
			table.remove(m.laneQueues)
		end },
		{ "decisionOrder grouped by lane instead of time", "decisionOrder position", function(m)
			m.decisionOrder = { 1, 4, 2, 5, 3 }
		end },
		{ "decisionOrder reversed", "decisionOrder position", function(m)
			m.decisionOrder = { 5, 4, 3, 2, 1 }
		end },
		{ "decisionOrder misses a block", "decisionOrder must list", function(m)
			table.remove(m.decisionOrder)
		end },
		{ "block days copied from the warm-up session", "block 2 day 1", function(m)
			m.blocks[2].days[1] = m.blocks[1].days[#m.blocks[1].days]
		end },
		{ "block bar count stale", "block 2 bars", function(m)
			m.blocks[2].bars += 1
		end },
		{ "config says warm-up 1 but blocks carry 2", "warm-up covers", function(m)
			m.config.warmupSessions = 1
		end },
		{ "config says 4 sessions per block but the blocks hold 5 (22 sessions would need 6 blocks)", "block count", function(m)
			m.config.blockSessions = 4
		end },
		{ "config lanes does not match the queues", "lane", function(m)
			m.config.lanes = 4
		end },
		{ "stats: warm-up bars omit the clamp-free blocks", "stats.warmupBars", function(m)
			m.stats.warmupBars -= m.blocks[2].warmBars
		end },
		{ "stats: overhead computed against stepped bars", "stats.overheadFraction", function(m)
			m.stats.overheadFraction = m.stats.warmupBars / m.stats.steppedBars
		end },
		{ "stats: per-lane bars exclude the warm-up", "stats.perLaneBars", function(m)
			m.stats.perLaneBars = deepCopy(m.stats.perLaneDecidedBars)
		end },
		{ "stats: busiest lane replaced by the mean", "stats.maxLaneBars", function(m)
			m.stats.maxLaneBars = m.stats.steppedBars / 3
		end },
		{ "stats: eta uses total stepped bars instead of the busiest lane", "stats.etaSeconds", function(m)
			local total = m.stats.steppedBars
			m.stats.etaSeconds = function(rate) return total / rate end
		end },
		{ "stats: eta is not a function", "stats.etaSeconds must be a function", function(m)
			m.stats.etaSeconds = 5
		end },
		{ "stats: lane count wrong", "stats.lanes", function(m)
			m.stats.lanes = 4
		end },
		{ "wrong schema", "schema", function(m)
			m.schema = "spring-block-schedule-0"
		end },
	}
	for _, case in cases do
		local label, fragment, mutate = case[1], case[2], case[3]
		local bad = mutated(good, mutate)
		local err = rejects(function() SBS.verify(bad, sessions) end, fragment)
		assert(string.find(err, "SpringBlockSchedule.verify", 1, true), label .. ": error must name verify")
	end
	measure("named mutations killed " .. #cases .. " of " .. #cases)
end)

test("verify: a schedule built for one session list is rejected against another", function()
	local a = makeSessions({ 4, 4, 2, 4, 4, 4, 3, 4, 4, 4, 4, 1 })
	local sch = baseline(a, { lanes = 3 })
	-- Same session count, one session one bar longer: every later block shifts.
	local longer = makeSessions({ 4, 4, 3, 4, 4, 4, 3, 4, 4, 4, 4, 1 })
	rejects(function() SBS.verify(sch, longer) end, "session boundary")
	-- Same bars, one session split in two: boundaries and block count change.
	local split = makeSessions({ 4, 4, 1, 1, 4, 4, 4, 3, 4, 4, 4, 4, 1 })
	rejects(function() SBS.verify(sch, split) end, "")
	-- A different day label (same bars).
	local renamed = deepCopy(a)
	renamed[7].day = renamed[7].day .. "x" -- still ascending: "2031-01-07x" sorts between 01-07 and 01-08
	rejects(function() SBS.verify(sch, renamed) end, "block 2 day 2")
	-- Fewer sessions.
	rejects(function() SBS.verify(sch, makeSessions({ 4, 4, 2, 4, 4 })) end, "block count")
	-- Same block count but a different block size: 12 sessions give 3 blocks for K = 5 and for K = 4, so the size rule is what catches it.
	local five = baseline(a, { lanes = 3, blockSessions = 5 })
	local claimsFour = mutated(five, function(m) m.config.blockSessions = 4 end)
	rejects(function() SBS.verify(claimsFour, a) end, "only the last block may differ")
	-- A short block that is not the last one.
	local fourBlocks = SBS.build(a, { lanes = 3, blockSessions = 4 })
	local claimsFive = mutated(fourBlocks, function(m) m.config.blockSessions = 5 end)
	rejects(function() SBS.verify(claimsFive, a) end, "only the last block may differ")
	-- verify validates its sessions argument as build does.
	rejects(function() SBS.verify(sch, {}) end, "sessions is empty")
	rejects(function() SBS.verify(nil :: any, a) end, "schedule must be a table")
end)

test("verify: every single-field edit of a schedule is rejected (exhaustive mutation scan, synthetic and real-shaped)", function()
	local function paths(root)
		local out = {}
		local function walk(node, trail)
			for k, v in node do
				local here = table.clone(trail)
				here[#here + 1] = k
				if type(v) == "table" then walk(v, here) else out[#out + 1] = { here, type(v) } end
			end
		end
		walk(root, {})
		return out
	end
	local function navigate(root, trail, upto)
		local node = root
		for i = 1, upto do node = node[trail[i]] end
		return node
	end
	local function scan(good, sessions, label)
		local killed, total = 0, 0
		local function expectRejected(mutant, what)
			total += 1
			local ok, err = pcall(SBS.verify, mutant, sessions)
			assert(not ok, label .. ": SURVIVOR " .. what .. " (verify returned " .. tostring(err) .. ")")
			killed += 1
		end
		local function isArray(t) return #t > 0 end
		for _, entry in paths(good) do
			local trail, kind = entry[1], entry[2]
			local what = table.concat(trail, ".")
			if kind == "number" then
				for _, delta in { 1, -1 } do
					local m = deepCopy(good)
					local parent = navigate(m, trail, #trail - 1)
					parent[trail[#trail]] += delta
					expectRejected(m, what .. " " .. (if delta > 0 then "+1" else "-1"))
				end
			elseif kind == "string" then
				local m = deepCopy(good)
				local parent = navigate(m, trail, #trail - 1)
				parent[trail[#trail]] = parent[trail[#trail]] .. "x"
				expectRejected(m, what .. " appended")
			elseif kind == "function" then
				local m = deepCopy(good)
				local parent = navigate(m, trail, #trail - 1)
				parent[trail[#trail]] = function() return 0 end
				expectRejected(m, what .. " replaced")
			end
			-- Removal of the field (or the array element).
			local m = deepCopy(good)
			local parent = navigate(m, trail, #trail - 1)
			local key = trail[#trail]
			if type(key) == "number" and isArray(parent) then table.remove(parent, key) else parent[key] = nil end
			expectRejected(m, what .. " removed")
		end
		-- Adjacent swaps in every array.
		local function swaps(node, trail)
			if isArray(node) then
				for i = 1, #node - 1 do
					if node[i] ~= node[i + 1] then
						local m = deepCopy(good)
						local arr = navigate(m, trail, #trail)
						arr[i], arr[i + 1] = arr[i + 1], arr[i]
						expectRejected(m, table.concat(trail, ".") .. " swap " .. i)
					end
				end
			end
			for k, v in node do
				if type(v) == "table" then
					local here = table.clone(trail)
					here[#here + 1] = k
					swaps(v, here)
				end
			end
		end
		swaps(good, {})
		assert(killed == total and total > 100)
		return total
	end
	local small = scan(baseline(TWELVE, { lanes = 2 }), TWELVE, "twelve/2 lanes")
	local multi = scan(baseline(ELEVEN, { lanes = 3, blockSessions = 3, warmupSessions = 2 }), ELEVEN, "eleven/3 lanes K3 W2")
	local hundred = {}
	local rand = lcg(7)
	for i = 1, 31 do hundred[i] = if rand(5) == 0 then 42 else 78 end
	local sessions31 = makeSessions(hundred)
	local big = scan(baseline(sessions31, { lanes = 4 }), sessions31, "31 sessions/4 lanes")
	measure("exhaustive single-edit mutants killed " .. (small + multi + big) .. " of " .. (small + multi + big) .. " (" .. small .. " + " .. multi .. " + " .. big .. "), 0 survivors")
end)

test("audit (the independent bar-level model) can fail: it flags overlap, gap, missing warm-up and wrong order", function()
	local sessions = makeSessions({ 4, 4, 2, 4, 4, 4, 3, 4, 4, 4, 4, 1 })
	local good = SBS.build(sessions, { lanes = 2 })
	assertAudit(good, sessions, "control")
	local function flags(label, mutate)
		local bad = mutated(good, mutate)
		local ok, problems = pcall(audit, bad, sessions)
		assert(not ok or #problems > 0, label .. ": the audit passed a broken schedule")
	end
	flags("overlap", function(m) m.blocks[1].lastIndex += 2 end)
	flags("gap", function(m) m.blocks[2].firstIndex += 1 end)
	flags("missing warm-up", function(m)
		local b = m.blocks[2]
		b.warmFirstIndex, b.warmLastIndex = b.firstIndex, b.firstIndex - 1
	end)
	flags("warm-up from the wrong session", function(m)
		local b = m.blocks[3]
		b.warmFirstIndex -= 2
		b.warmLastIndex -= 2
	end)
	flags("wrong lane order", function(m) m.laneQueues[1][1], m.laneQueues[1][2] = m.laneQueues[1][2], m.laneQueues[1][1] end)
	flags("decision order", function(m) m.decisionOrder = { 2, 1, 3 } end)
	flags("first block with warm-up", function(m) m.blocks[1].warmFirstIndex = 0 end)
end)

------------------------------------------------------------------------------------------------------------------------
-- The real 469-session list.
local function loadReal()
	local candidates = {
		"../data/SpringRealSessions", -- a staged copy next to src/ and tests/
		"./SpringRealSessions",
	}
	for _, path in candidates do
		local ok, value = pcall(require, path)
		if ok and type(value) == "table" then return value end
	end
	return nil
end
local real = loadReal()
local RS = real and real.sessions
local skipped = 0
local function realTest(name, fn)
	if real then
		test(name, fn)
	else
		skipped += 1
		print("SKIP " .. name .. " (optional real-session fixture not present)")
	end
end

local function fnv1a(sessions)
	local h = 2166136261
	local text = {}
	for i, s in sessions do text[i] = s.day .. "," .. s.firstIndex .. "," .. s.lastIndex .. ";" end
	local all = table.concat(text)
	for i = 1, #all do
		h = bit32.bxor(h, string.byte(all, i))
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296 -- h * 0x01000193 mod 2^32 without losing precision
	end
	return h
end

realTest("fixture: the real list is the live run's 469 sessions / 36,402 bars, unmodified since the node helper wrote it", function()
	assert(#RS == 469 and real.bars == 36402 and RS[469].lastIndex == 36402)
	assert(real.dataHash == "b8a3ce225720691e172ab8216b85bcdff634fb1172ced5325db6d5d4fbb41a26", "live dataHash b8a3ce22...bb41a26 of the contract EXPECT block")
	assert(RS[1].day == "2024-11-18" and RS[1].firstIndex == 1 and RS[1].lastIndex == 78)
	assert(RS[30].day == "2024-12-31" and RS[30].lastIndex == 2268, "30 lead-in sessions end at row 2268")
	assert(RS[31].day == "2025-01-02" and RS[31].firstIndex == 2269 and RS[31].lastIndex == 2346, "the forward test starts at row 2269")
	assert(RS[469].day == "2026-10-02")
	assert(fnv1a(RS) == real.digest, "fixture digest mismatch: " .. fnv1a(RS) .. " vs " .. tostring(real.digest))
	assert(real.digest == 3402029439, "digest of the exact 469-session list measured from loadDataset on 2026-10-05")
	local early = {}
	for i, s in RS do
		local n = s.lastIndex - s.firstIndex + 1
		assert(n == 78 or n == 42, "session " .. s.day .. " has " .. n .. " bars")
		if n == 42 then early[#early + 1] = i .. ":" .. s.day end
	end
	assert(join(early) == "9:2024-11-29,26:2024-12-24,155:2025-07-03,258:2025-11-28,276:2025-12-24", "early closes: " .. join(early))
	measure("real list: 469 sessions, 36402 bars, early-close sessions " .. join(early))
end)

local REAL_LITERALS = {
	[6] = { perLaneBars = { 7374, 7380, 7488, 7374, 7020, 6984 }, perLaneBlocks = { 16, 16, 16, 16, 15, 15 }, maxLaneBars = 7488 },
	[8] = { perLaneBars = { 5538, 5580, 5616, 5580, 5616, 5502, 5112, 5076 }, perLaneBlocks = { 12, 12, 12, 12, 12, 12, 11, 11 }, maxLaneBars = 5616 },
	[10] = { perLaneBars = { 4566, 4572, 4680, 4602, 4212, 4140, 4212, 4212, 4212, 4212 }, perLaneBlocks = { 10, 10, 10, 10, 9, 9, 9, 9, 9, 9 }, maxLaneBars = 4680 },
}

realTest("real list: block count, overhead and per-lane bars for N = 6, 8, 10 match the node reference model and pinned literals", function()
	assert(real.expected ~= nil, "fixture lacks the node reference model")
	for _, n in { 6, 8, 10 } do
		local sch = SBS.build(RS, { lanes = n })
		local st, ref, lit = sch.stats, real.expected[n], REAL_LITERALS[n]
		assert(st.sessions == 469 and st.bars == 36402 and st.blocks == 94 and st.lanes == n)
		assert(st.blocks == ref.blocks and st.blocks == 94, "blocks: 468/5 -> 93 full blocks and one of 4 sessions")
		assert(st.warmupBars == ref.warmupBars and st.warmupBars == 7218, "warm-up bars " .. st.warmupBars)
		assert(st.steppedBars == 36402 + 7218 and st.overheadFraction == 7218 / 36402)
		assert(arrayEquals(st.perLaneBars, ref.perLaneBars), "N=" .. n .. " per-lane bars " .. join(st.perLaneBars) .. " vs node " .. join(ref.perLaneBars))
		assert(arrayEquals(st.perLaneDecidedBars, ref.perLaneDecidedBars) and arrayEquals(st.perLaneBlocks, ref.perLaneBlocks))
		assert(st.maxLaneBars == ref.maxLaneBars)
		assert(arrayEquals(st.perLaneBars, lit.perLaneBars) and arrayEquals(st.perLaneBlocks, lit.perLaneBlocks) and st.maxLaneBars == lit.maxLaneBars)
		local sum = 0
		for _, v in st.perLaneBars do sum += v end
		assert(sum == st.steppedBars, "lane workloads add up to decided + warm-up bars")
		local shorts = 0
		for _, b in sch.blocks do
			if b.lastSession - b.firstSession + 1 < 5 then shorts += 1 end
		end
		assert(shorts == ref.shortBlocks and shorts == 1)
		assert(SBS.verify(sch, RS) == true)
		assertAudit(sch, RS, "real N=" .. n)
		measure(string.format("N=%d: %d blocks (%d full + 1 of %d sessions), warm-up %d bars on %d decided = overhead %.4f (%.2f%%), stepped %d",
			n, st.blocks, st.blocks - 1, sch.blocks[94].lastSession - sch.blocks[94].firstSession + 1, st.warmupBars, st.bars, st.overheadFraction, st.overheadFraction * 100, st.steppedBars))
		measure(string.format("N=%d: per-lane stepped bars {%s}, decided {%s}, blocks {%s}, busiest lane %d (ideal even split %.1f), eta at 3.13 bars/s/lane = %.0f s",
			n, join(st.perLaneBars), join(st.perLaneDecidedBars), join(st.perLaneBlocks), st.maxLaneBars, st.steppedBars / n, st.etaSeconds(3.13)))
	end
	for _, n in { 1, 2, 3 } do
		local sch, ref = SBS.build(RS, { lanes = n }), real.expected[n]
		assert(arrayEquals(sch.stats.perLaneBars, ref.perLaneBars) and sch.stats.warmupBars == ref.warmupBars and sch.stats.maxLaneBars == ref.maxLaneBars, "N=" .. n)
		assert(SBS.verify(sch, RS))
	end
end)

realTest("real list: the lead-in ends exactly on a block boundary, and warm-up follows the real preceding session length", function()
	local sch = SBS.build(RS, { lanes = 8 })
	local sixth, seventh = sch.blocks[6], sch.blocks[7]
	assert(sixth.firstSession == 26 and sixth.lastSession == 30 and sixth.lastIndex == 2268, "block 6 is the last lead-in block")
	assert(seventh.firstSession == 31 and seventh.firstIndex == 2269 and seventh.days[1] == "2025-01-02", "block 7 is the first forward-test block")
	assert(seventh.warmSessions == 1 and seventh.warmFirstIndex == 2191 and seventh.warmLastIndex == 2268 and seventh.warmBars == 78, "block 7 warms up on 2024-12-31")
	-- Session 155 is 2025-07-03 (an early close, 42 bars) and block 32 starts right after it (session 156 = 5 * 31 + 1):
	-- that block warms up on exactly 42 bars, not on 78. Block 6 (sessions 26..30) decides the 2024-12-24 early close instead.
	local b32 = sch.blocks[32]
	assert(RS[155].day == "2025-07-03" and RS[155].lastIndex - RS[155].firstIndex + 1 == 42 and b32.firstSession == 156)
	assert(b32.warmFirstSession == 155 and b32.warmBars == 42 and b32.warmFirstIndex == RS[155].firstIndex and b32.warmLastIndex == RS[155].lastIndex)
	assert(sixth.days[1] == "2024-12-24" and sixth.bars == 42 + 4 * 78 and sixth.warmFirstSession == 25 and sixth.warmBars == 78)
	assert(sch.blocks[1].warmBars == 0 and sch.blocks[1].firstIndex == 1)
	local last = sch.blocks[94]
	assert(last.firstSession == 466 and last.lastSession == 469 and last.lastIndex == 36402 and last.days[4] == "2026-10-02")
	local wantBars = 0
	for s = 466, 469 do wantBars += RS[s].lastIndex - RS[s].firstIndex + 1 end
	assert(last.bars == wantBars and last.warmFirstSession == 465 and last.warmBars == RS[465].lastIndex - RS[465].firstIndex + 1)
	assert(last.lane == (94 - 1) % 8 + 1 and last.lane == 6 and last.slot == 12)
	for id = 2, 94 do
		local b = sch.blocks[id]
		assert(b.warmBars == RS[b.firstSession - 1].lastIndex - RS[b.firstSession - 1].firstIndex + 1, "block " .. id .. " warm-up must equal the preceding session")
	end
	-- Blocks 1..6 decide exactly rows 1..2268, blocks 7..94 exactly rows 2269..36402.
	local leadIn, forward = 0, 0
	for id, b in sch.blocks do
		if id <= 6 then leadIn += b.bars else forward += b.bars end
	end
	assert(leadIn == 2268 and forward == 34134)
	measure("lead-in = blocks 1-6 (2268 rows, 30 sessions), forward test = blocks 7-94 (34134 rows, 439 sessions); block 94 holds 4 sessions / " .. last.bars .. " bars on lane " .. last.lane)
end)

realTest("real list: sweep of lanes 1..16, blockSessions {1,3,5,10,469,1000}, warmupSessions {0,1,2,5} passes verify and the independent audit", function()
	local frozen = deepFreeze(deepCopy(RS))
	local builds = 0
	for lanes = 1, 16 do
		for _, k in { 1, 3, 5, 10, 469, 1000 } do
			for _, w in { 0, 1, 2, 5 } do
				local sch = SBS.build(frozen, { lanes = lanes, blockSessions = k, warmupSessions = w })
				assert(SBS.verify(sch, frozen) == true)
				assertAudit(sch, frozen, "lanes=" .. lanes .. " K=" .. k .. " W=" .. w)
				assert(#sch.blocks == math.ceil(469 / k))
				builds += 1
			end
		end
	end
	assert(builds == 16 * 6 * 4)
	measure("real-list sweep: " .. builds .. " schedules verified and audited")
end)

realTest("real list: exhaustive single-edit scan of the N=8 schedule (every block field, queue, order entry and stat)", function()
	local sch = SBS.build(RS, { lanes = 8 })
	local control = deepCopy(sch)
	assert(SBS.verify(control, RS) == true)
	local killed, total = 0, 0
	local function reject(mutant, what)
		total += 1
		local ok, err = pcall(SBS.verify, mutant, RS)
		assert(not ok, "SURVIVOR " .. what .. " (verify returned " .. tostring(err) .. ")")
		killed += 1
	end
	for id = 1, 94 do
		for _, name in BLOCK_FIELDS do
			for _, delta in { 1, -1 } do
				local m = deepCopy(sch)
				m.blocks[id][name] += delta
				reject(m, "block " .. id .. "." .. name .. " " .. delta)
			end
		end
		local m = deepCopy(sch)
		m.blocks[id].days[1] = m.blocks[id].days[1] .. "x"
		reject(m, "block " .. id .. " day")
	end
	for lane = 1, 8 do
		for k = 1, #sch.laneQueues[lane] do
			local m = deepCopy(sch)
			m.laneQueues[lane][k] += 1
			reject(m, "queue " .. lane .. "/" .. k)
		end
	end
	for k = 1, 93 do
		local m = deepCopy(sch)
		m.decisionOrder[k], m.decisionOrder[k + 1] = m.decisionOrder[k + 1], m.decisionOrder[k]
		reject(m, "decisionOrder swap " .. k)
	end
	assert(killed == total and total > 1800, "mutants " .. total)
	measure("real N=8 exhaustive scan: " .. killed .. " of " .. total .. " single-edit mutants rejected")
end)

print("SpringBlockSchedule: " .. passed .. " tests passed" .. (if skipped > 0 then ", " .. skipped .. " real-list tests skipped (no fixture)" else ""))
