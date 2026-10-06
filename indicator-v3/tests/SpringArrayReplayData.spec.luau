-- Self-running pure Luau test: luau.exe tests/SpringArrayReplayData.spec.luau
local loaded, Data = pcall(require, "../src/SpringArrayReplayData")
assert(loaded and type(Data) == "table" and type(Data.new) == "function",
	"SpringArrayReplayData must load: " .. tostring(Data))

local passed = 0
local function test(name, fn) fn(); passed += 1; print("PASS " .. name) end
local function rejects(fn, fragment)
	local ok, err = pcall(fn)
	assert(not ok, "expected rejection: " .. fragment)
	assert(string.find(string.lower(tostring(err)), string.lower(fragment), 1, true), "wrong rejection: " .. tostring(err))
end
local function copy(x)
	if type(x) ~= "table" then return x end
	local out = {}; for k, v in x do out[k] = copy(v) end; return out
end
local function freeze(x)
	for _, v in x do if type(v) == "table" then freeze(v) end end
	return table.freeze(x)
end
local function seal()
	return { schema = "roalgo-spring-lane-capture-1", runId = "fixture", lanes = 3,
		schedule = { schema = "spring-block-schedule-1", maxLaneBars = 8, warmupBars = 6, steppedBars = 18,
			blocks = {
				{ id=1, lane=1, firstIndex=1, lastIndex=3, warmFirstIndex=1, warmLastIndex=0 },
				{ id=2, lane=2, firstIndex=4, lastIndex=6, warmFirstIndex=3, warmLastIndex=3 },
				{ id=3, lane=3, firstIndex=7, lastIndex=8, warmFirstIndex=5, warmLastIndex=6 },
				{ id=4, lane=1, firstIndex=9, lastIndex=10, warmFirstIndex=8, warmLastIndex=8 },
				{ id=5, lane=2, firstIndex=11, lastIndex=12, warmFirstIndex=9, warmLastIndex=10 },
			} } }
end
local function hex(row, variant, special)
	local packed = buffer.create(408)
	for i=1,51 do buffer.writef64(packed, (i-1)*8, row*100 + variant*10 + i/8) end
	if special then for i,v in special do buffer.writef64(packed, (i-1)*8, v) end end
	local out = table.create(408)
	for i=0,407 do out[i+1] = string.format("%02x", buffer.readu8(packed, i)) end
	return table.concat(out)
end
local function chunk(first, last)
	local c = { schema="roalgo-spring-live-chunk-1", runId="fixture", firstIndex=first, lastIndex=last,
		count=last-first+1, bars={}, states={ coupled={}, independent={} } }
	for row=first,last do
		local i=row-first+1
		c.bars[i]={t=1000+row*300,label="row "..row}
		c.states.coupled[i]=hex(row,1)
		c.states.independent[i]=hex(row,2)
	end
	return c
end
local function ready()
	local d=Data.new(seal(),12)
	d:append(chunk(1,5)); d:append(chunk(6,12)); return d:finish()
end

test("uneven warmup and later block transitions preserve lane, block, row and time", function()
	local d=ready()
	local expected={
		{1,2,3,"w8",9,10,"i","i"},
		{"w3",4,5,6,"w9","w10",11,12},
		{"w5","w6",7,8,"i","i","i","i"},
	}
	for lane, ticks in expected do for tick,want in ticks do
		local s=d:sample(lane,tick)
		assert(s.lane==lane)
		if type(want)=="number" then
			assert(s.phase=="recorded" and s.rowIndex==want, "wrong recorded endpoint")
			assert(s.t==1000+want*300 and s.label=="row "..want)
			assert(#s.coupled==51 and #s.independent==51)
			assert(s.coupled[1]==want*100+10.125 and s.independent[51]==want*100+26.375)
		elseif want=="i" then
			assert(s.phase=="idle" and s.coupled==nil and s.independent==nil and s.rowIndex==nil)
		else
			assert(s.phase=="warmup" and s.rowIndex==tonumber(string.sub(want,2)))
			assert(s.coupled==nil and s.independent==nil, "warmup must not borrow a recorded pose")
		end
	end end
	assert(d:sample(1,3).blockId==1 and d:sample(1,4).blockId==4 and d:sample(1,5).blockId==4)
	assert(d:sample(2,6).blockId==5 and d:sample(2,7).blockId==5)
	assert(d.totalRows==12 and d.totalTicks==8 and d.laneCount==3 and d.firstAllRecordedTick==3)
end)

test("exact float64 decoding preserves precision, signs and distinct variants", function()
	local c=chunk(1,12)
	c.states.coupled[1]=hex(1,1,{[1]=1.0000000000000002,[2]=-0,[51]=1e-300})
	c.states.independent[1]=string.upper(hex(1,2,{[1]=-123.45678901234567}))
	local d=Data.new(seal(),12); d:append(c); d:finish()
	local s=d:sample(1,1)
	assert(s.coupled[1]==1.0000000000000002 and 1/s.coupled[2]==-math.huge and s.coupled[51]==1e-300)
	assert(s.independent[1]==-123.45678901234567)
	assert(d:stats().stateBytes==9792, "two compact 408-byte states per saved row")
end)

test("read-only inputs and fresh samples cannot change future playback", function()
	local s,c=seal(),chunk(1,12)
	local d=Data.new(freeze(s),12); d:append(freeze(c)); d:finish()
	local sample=d:sample(1,1); sample.coupled[1]=999; sample.label="changed"
	assert(d:sample(1,1).coupled[1]==110.125 and d:sample(1,1).label=="row 1")
	local mutable=seal(); local source=chunk(1,12); local e=Data.new(mutable,12); e:append(source)
	mutable.schedule.blocks[1].lastIndex=12; source.bars[1].label="changed"; source.states.coupled[1]=hex(99,1)
	e:finish(); assert(e:sample(1,1).coupled[1]==110.125 and e:sample(1,1).label=="row 1")
end)

test("coverage rejects gaps, duplicate chunks, incorrect counts and premature finish", function()
	local d=Data.new(seal(),12)
	rejects(function() d:sample(1,1) end,"finish")
	rejects(function() d:append(chunk(2,4)) end,"contiguous")
	d:append(chunk(1,5))
	rejects(function() d:append(chunk(1,5)) end,"contiguous")
	rejects(function() d:finish() end,"coverage")
	local c=chunk(6,12); c.count=6; rejects(function() d:append(c) end,"count")
	d:append(chunk(6,12)); d:finish(); assert(d:finish()==d)
	rejects(function() d:append(chunk(1,1)) end,"finished")
end)

test("malformed and non-finite state rows reject the whole append", function()
	for _,bad in {"00",string.rep("g",816),false,hex(1,1,{[30]=math.huge}),hex(1,1,{[49]=0/0})} do
		local d=Data.new(seal(),12); local c=chunk(1,5); c.states.independent[4]=bad
		rejects(function() d:append(c) end,"state")
		assert(d:stats().loadedRows==0, "failed append must not advance coverage")
		d:append(chunk(1,12)); d:finish(); assert(d:sample(2,2).independent[1]==420.125)
	end
	local d=Data.new(seal(),12); local c=chunk(1,12); c.states.independent[12]=nil
	rejects(function() d:append(c) end,"count")
end)

test("time, label and run identity are checked before committing rows", function()
	for _,change in {
		function(c) c.bars[3].t=c.bars[2].t end,
		function(c) c.bars[3].t=0/0 end,
		function(c) c.bars[3].label={} end,
		function(c) c.runId="other" end,
	} do
		local d=Data.new(seal(),12); local c=chunk(1,12); change(c)
		local ok=pcall(function() d:append(c) end); assert(not ok and d:stats().loadedRows==0)
	end
	local d=Data.new(seal(),12); d:append(chunk(1,5)); local c=chunk(6,12); c.bars[1].t=2500
	rejects(function() d:append(c) end,"time")
end)

test("schedule rejects gaps, overlaps, invalid lanes, warmup ranges and false max ticks", function()
	for _,change in {
		function(s) s.schedule.blocks[2].firstIndex=5 end,
		function(s) s.schedule.blocks[2].firstIndex=3 end,
		function(s) s.schedule.blocks[2].lane=4 end,
		function(s) s.schedule.blocks[2].id=1 end,
		function(s) s.schedule.blocks[2].warmFirstIndex=0 end,
		function(s) s.schedule.blocks[2].warmLastIndex=4 end,
		function(s) s.schedule.maxLaneBars=9 end,
		function(s) s.schedule.warmupBars=7 end,
		function(s) s.schedule.blocks[5].lastIndex=11 end,
	} do
		local s=seal(); change(s)
		rejects(function() local d=Data.new(s,12); d:append(chunk(1,12)); d:finish() end,"schedule")
	end
end)

test("sample bounds reject invalid lanes and ticks without clamping", function()
	local d=ready()
	for _,pair in {{0,1},{4,1},{1,0},{1,9},{1,1.5},{1,0/0}} do
		rejects(function() d:sample(pair[1],pair[2]) end,"range")
	end
end)

test("locateRow round trips first, last and block-boundary rows without matching warmup copies", function()
	local d=ready()
	local expected={{1,1,1},{1,2,1},{1,3,1},{2,2,2},{2,3,2},{2,4,2},
		{3,3,3},{3,4,3},{1,5,4},{1,6,4},{2,7,5},{2,8,5}}
	for row,want in expected do
		local location=d:locateRow(row)
		assert(location.lane==want[1] and location.tick==want[2] and location.blockId==want[3],
			"wrong recorded location for row "..row)
		local sample=d:sample(location.lane,location.tick)
		assert(sample.phase=="recorded" and sample.rowIndex==row and sample.blockId==location.blockId)
	end
	-- These rows also occur in other lanes' warmup windows, which must never win.
	assert(d:sample(2,1).rowIndex==3 and d:sample(2,1).phase=="warmup")
	assert(d:sample(1,4).rowIndex==8 and d:sample(1,4).phase=="warmup")
	local location=d:locateRow(1); location.lane=99; location.tick=99
	assert(d:locateRow(1).lane==1 and d:locateRow(1).tick==1, "lookup result must not mutate schedule")
end)

test("locateRow rejects unfinished data and invalid rows without clamping", function()
	local d=Data.new(seal(),12)
	rejects(function() d:locateRow(1) end,"finish")
	d:append(chunk(1,12)); d:finish()
	for _,row in {0,-1,13,1.5,0/0,math.huge,-math.huge,"3",false} do
		rejects(function() d:locateRow(row) end,"row index out of range")
	end
	rejects(function() d:locateRow(nil) end,"row index out of range")
end)

test("no shared recorded tick is disclosed instead of invented", function()
	local s=seal(); s.lanes=4
	local d=Data.new(s,12); d:append(chunk(1,12)); d:finish()
	assert(d.firstAllRecordedTick==nil and d:sample(4,1).phase=="idle")
end)

print(string.format("SpringArrayReplayData: %d passed",passed))
