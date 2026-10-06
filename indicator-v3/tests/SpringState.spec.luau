local loaded, SpringState = pcall(require, "../src/SpringState")
assert(loaded and type(SpringState) == "table", "SpringState must implement the narrow saved-v2 state boundary")
local loadedFixtures, Fixtures = pcall(require, "./SpringFixtures")
assert(loadedFixtures and type(Fixtures) == "table", "SpringFixtures must provide synthetic fixtures")
local passed = 0
local function test(n, f) f(); passed += 1; print("PASS " .. n) end
local function rejects(f, fragment)
	local ok, err = pcall(f)
	assert(not ok, "expected a rejection containing '" .. fragment .. "'")
	assert(string.find(tostring(err), fragment, 1, true), "wrong rejection: " .. tostring(err) .. " (expected '" .. fragment .. "')")
end
local protocol = Fixtures.protocol()
local T0 = Fixtures.T0

local function describeWith(mutate)
	local config, names, drives, proto = Fixtures.nativeConfig(), Fixtures.stateNames(), Fixtures.driveNames(), Fixtures.deepCopy(protocol)
	local out = mutate(config, names, drives, proto)
	if out then config, names, drives, proto = out.config or config, out.names or names, out.drives or drives, out.protocol or proto end
	return SpringState.describe(config, names, drives, proto)
end

test("describe accepts the saved v2 config and derives exactly the 13 declared directional nodes", function()
	local d = Fixtures.descriptor()
	assert(d.schema == "spring-v2-descriptor-1" and d.protocolId == "spring-consensus-v1" and d.nodeCount == 24)
	assert(d.D == 64 and d.spacing == 256 and #d.nodes == 24 and #d.edges == 37 and #d.stateNames == 51 and #d.driveNames == 8)
	local expected = { 1, 4, 7, 9, 11, 12, 14, 15, 17, 19, 20, 22, 23 }
	assert(#d.directional == #expected)
	for i, id in expected do assert(d.directional[i] == id, "directional set mismatch at " .. i) end
	local banks = { { "Fast", { 1, 4, 7 } }, { "Medium", { 9, 11, 12, 14, 15 } }, { "Slow", { 17, 19, 20, 22, 23 } } }
	for b, spec in banks do
		assert(d.banks[b].name == spec[1] and #d.banks[b].nodes == 8 and d.banks[b].nodes[1] == (b - 1) * 8 + 1 and d.banks[b].nodes[8] == b * 8)
		assert(#d.banks[b].directional == #spec[2])
		for i, id in spec[2] do assert(d.banks[b].directional[i] == id) end
	end
	-- Dominant channels measured on the saved config (contract section 2), all +0.72.
	local dominant = { "immediateReturn", "rangeActivity", "volume", "immediateReturn", "rangeActivity", "volume", "immediateReturn", "rangeActivity",
		"trend", "peerRelative", "hourlyContext", "trend", "peerRelative", "hourlyContext", "trend", "peerRelative",
		"dailyTrend", "regimeStress", "trend", "dailyTrend", "regimeStress", "trend", "dailyTrend", "regimeStress" }
	local directionalSet = {}
	for _, id in expected do directionalSet[id] = true end
	for i, n in d.nodes do
		assert(n.index == i and n.bank == math.ceil(i / 8) and n.bankName == d.banks[n.bank].name)
		assert(n.dominantName == dominant[i], "node " .. i .. " dominant " .. n.dominantName)
		assert(d.driveNames[n.dominantChannel] == n.dominantName and n.dominantCoefficient == 0.72 and n.projection[n.dominantChannel] == 0.72)
		assert(n.directional == (directionalSet[i] == true))
		assert(#n.projection == 8 and n.omega > 0)
		assert(d.xIndex[i] == i and d.vIndex[i] == 24 + i)
	end
	assert(d.xIndex[17] == 17 and d.vIndex[17] == 41)
	assert(d.stateNames[1] == "Fast01.x" and d.stateNames[25] == "Fast01.v" and d.stateNames[41] == "Slow01.v")
	assert(d.stateNames[49] == "Fast.energy" and d.stateNames[51] == "Slow.energy")
	assert(d.edges[1].a == 1 and d.edges[1].b == 2 and d.edges[37].a == 16 and d.edges[37].b == 24)
end)

test("descriptor is deep-frozen and shares no table with its source config", function()
	local config = Fixtures.nativeConfig()
	local d = SpringState.describe(config, Fixtures.stateNames(), Fixtures.driveNames(), protocol)
	Fixtures.assertDeepFrozen(d)
	assert(not pcall(function() d.nodes[1].omega = 99 end))
	assert(not pcall(function() table.insert(d.directional, 2) end))
	assert(not pcall(function() d.banks[1].directional[1] = 2 end))
	local configTables = Fixtures.tables(config)
	for t in Fixtures.tables(d) do assert(not configTables[t], "descriptor shares a table with the config") end
	config.nodes[1].omega = 99
	config.nodes[1].projection[2] = 0.5
	assert(d.nodes[1].omega == 4.25 and d.nodes[1].projection[2] == 0.72)
end)

test("rejects v3-shaped input presented as v2", function()
	local v3 = Fixtures.v3Config(48)
	assert(#v3.nodes == 48 and #Fixtures.v3StateNames(v3) == 107)
	rejects(function() SpringState.describe(v3, Fixtures.v3StateNames(v3), Fixtures.driveNames(), protocol) end, "v3-shaped input")
	local v3small = Fixtures.v3Config(24)
	assert(#v3small.nodes == 24 and #Fixtures.v3StateNames(v3small) == 59)
	rejects(function() SpringState.describe(v3small, Fixtures.v3StateNames(v3small), Fixtures.driveNames(), protocol) end, "v3-shaped input")
	rejects(function() SpringState.describe(Fixtures.nativeConfig(), Fixtures.v3StateNames(v3small), Fixtures.driveNames(), protocol) end, "v3-shaped input")
	rejects(function() SpringState.describe(Fixtures.nativeConfig(), Fixtures.v3StateNames(v3), Fixtures.driveNames(), protocol) end, "v3-shaped input")
	-- A 24-node v3 config with v2-length names still fails on its schema, and on its node names if relabelled.
	rejects(function() SpringState.describe(v3small, Fixtures.stateNames(), Fixtures.driveNames(), protocol) end, "config schema")
	v3small.schema = "roalgo-mechanics-v2-1"
	rejects(function() SpringState.describe(v3small, Fixtures.stateNames(), Fixtures.driveNames(), protocol) end, "bankChannels")
	v3small.bankChannels = Fixtures.nativeConfig().bankChannels
	rejects(function() SpringState.describe(v3small, Fixtures.stateNames(), Fixtures.driveNames(), protocol) end, "name")
	rejects(function() SpringState.describe(v3, Fixtures.stateNames(), v3.driveNames, protocol) end, "v3-shaped input")
end)

test("rejects any config, state-name, drive-name, edge, projection or protocol mismatch", function()
	describeWith(function() end) -- baseline: the unmutated copies pass
	local cases = {
		{ "node count", function(c) table.remove(c.nodes) end },
		{ "banks must be 1-8/9-16/17-24", function(c) c.nodes[9].bank = 1 end },
		{ "name Fast02 ~= Fast01", function(c) c.nodes[1].name = "Fast02" end },
		{ "column mismatch", function(c) c.nodes[3].column = 4 end },
		{ "omega", function(c) c.nodes[5].omega = 0 / 0 end },
		{ "declared directional node 4", function(c) c.nodes[4].projection[2], c.nodes[4].projection[3] = 0.12, 0.72 end },
		{ "declared directional node 9", function(c) c.nodes[9].projection[1] = -0.72 end },
		{ "node 2 in bank Fast has directional dominant channel immediateReturn but is not declared", function(c)
			c.nodes[2].projection = { 0, 0.72, 0.12, 0, -0.08, 0, 0.08, 0 }
		end },
		{ "node 18 in bank Slow has directional dominant channel dailyTrend", function(c)
			c.nodes[18].projection = { -0.12, 0, 0.08, 0, 0.08, 0, 0.72, 0 }
		end },
		{ "dominant projection -0.72 ~= +0.72", function(c) c.nodes[3].projection[4] = -0.72 end },
		{ "projection L1", function(c) c.nodes[5].projection[3] = 0.8 end },
		{ "projection must have 8 terms", function(c) table.insert(c.nodes[6].projection, 0) end },
		{ "no unique dominant", function(c) c.nodes[2].projection = { 0, 0, 0.5, -0.5, 0, 0, 0, 0 } end },
		{ "37 edges", function(c) table.remove(c.edges) end },
		{ "edge 1:3 is not in the v2 topology", function(c) c.edges[2].a, c.edges[2].b = 1, 3 end },
		{ "edge 1:2 is not in the v2 topology", function(c) c.edges[2].a, c.edges[2].b = 1, 2 end },
		{ "config schema", function(c) c.schema = "roalgo-mechanics-v3-1" end },
		{ "bank 2 name", function(c) c.bankNames[2] = "Mid" end },
		{ "displacement scale D", function(c) c.D = 0 end },
		{ "state name 1 is Fast02.x", function(_, n) n[1], n[2] = n[2], n[1] end },
		{ "state name 49", function(_, n) n[49] = "Fast.velocity" end },
		{ "state name 25", function(_, n) n[25] = "Fast01.x" end },
		{ "state names count 50", function(_, n) table.remove(n) end },
		{ "drive name 1 is immediateReturn", function(_, _, dn) dn[1], dn[2] = dn[2], dn[1] end },
		{ "8 drive names", function(_, _, dn) table.insert(dn, "extra") end },
		{ "protocol mismatch at protocol.calibration.quantile", function(_, _, _, p) p.calibration.quantile = 0.6 end },
		{ "protocol mismatch at protocol.directionalNodes", function(_, _, _, p) p.directionalNodes[1][2] = 5 end },
		{ "protocol id", function(_, _, _, p) p.id = "spring-consensus-v2" end },
		-- Every implemented validation branch has a case (review 2026-10-05: these were unguarded).
		{ "node 3 omega", function(c) c.nodes[3].omega = -1 end },
		{ "node 4 omega", function(c) c.nodes[4].omega = 0 end },
		{ "node 3 y/z", function(c) c.nodes[3].z = 0 / 0 end },
		{ "node 7 y/z", function(c) c.nodes[7].y = math.huge end },
		{ "node 5 index mismatch", function(c) c.nodes[5].index = 6 end },
		{ "finite positive spacing", function(c) c.spacing = 0 end },
		{ "finite positive spacing", function(c) c.spacing = nil end },
		{ "drive name 8 is regimeStres", function(_, _, dn) dn[8] = "regimeStres" end },
		{ "bank 3 name", function(c) c.bankNames[3] = "Slw" end },
		{ "bank 1 name", function(c) c.bankNames[1] = "Quick" end },
		-- The dominant channel must be the node's own v2 bank-cycle channel, not just any directional channel.
		{ "node 1 dominant channel trend is not its v2 bank-cycle channel immediateReturn", function(c)
			c.nodes[1].projection, c.nodes[9].projection = c.nodes[9].projection, c.nodes[1].projection
		end },
		{ "node 11 dominant channel dailyTrend is not its v2 bank-cycle channel hourlyContext", function(c)
			c.nodes[11].projection, c.nodes[17].projection = c.nodes[17].projection, c.nodes[11].projection
		end },
		{ "node 19 dominant channel hourlyContext is not its v2 bank-cycle channel trend", function(c)
			c.nodes[19].projection = { 0.08, 0, -0.08, 0, 0, 0.72, 0.12, 0 }
		end },
		{ "bankChannels must equal the saved v2 drive cycle", function(c) c.bankChannels = { { 1, 1, 1 }, { 1, 1, 1 }, { 1, 1, 1 } } end },
		{ "bankChannels must equal the saved v2 drive cycle", function(c) c.bankChannels[2][3] = 1 end },
		{ "bankChannels must equal the saved v2 drive cycle", function(c) table.insert(c.bankChannels[3], 2) end },
		{ "bankChannels must equal the saved v2 drive cycle", function(c) c.bankChannels = nil end },
		{ "displacement scale D 32 ~= 64", function(c) c.D = 32 end },
		{ "state names must be a 51-name array", function(_, n) n.extra = "Fast.price" end },
	}
	for _, case in cases do rejects(function() describeWith(case[2]) end, case[1]) end
	-- The saved v2 cycle itself: every node's dominant channel is bankChannels[bank][(column - 1) % 3 + 1].
	local d, config = Fixtures.descriptor(), Fixtures.nativeConfig()
	for i, n in d.nodes do assert(n.dominantChannel == config.bankChannels[n.bank][(config.nodes[i].column - 1) % 3 + 1]) end
end)

test("describe checks the saved names of all three variants when given a per-variant map", function()
	local function names() return Fixtures.stateNames() end
	local array = Fixtures.descriptor()
	local mapped = SpringState.describe(Fixtures.nativeConfig(), { coupled = names(), independent = names(), numeric = names() },
		Fixtures.driveNames(), protocol)
	Fixtures.deepEqual(mapped, array)
	local permuted = names(); permuted[30], permuted[31] = permuted[31], permuted[30]
	rejects(function()
		SpringState.describe(Fixtures.nativeConfig(), { coupled = names(), independent = permuted, numeric = names() }, Fixtures.driveNames(), protocol)
	end, "independent state name 30 is Fast07.v")
	rejects(function()
		SpringState.describe(Fixtures.nativeConfig(), { coupled = names(), numeric = names() }, Fixtures.driveNames(), protocol)
	end, "state names for variant independent required")
	rejects(function()
		SpringState.describe(Fixtures.nativeConfig(), { coupled = names(), independent = names(), numeric = names(), drive = names() }, Fixtures.driveNames(), protocol)
	end, "map key drive is not a variant")
	local v3 = Fixtures.v3Config(24)
	rejects(function()
		SpringState.describe(Fixtures.nativeConfig(), { coupled = names(), independent = names(), numeric = Fixtures.v3StateNames(v3) }, Fixtures.driveNames(), protocol)
	end, "v3-shaped input (24 nodes, 59 numeric state names)")
end)

test("describe neither freezes nor aliases the caller's inputs", function()
	local config, names, drives = Fixtures.nativeConfig(), Fixtures.stateNames(), Fixtures.driveNames()
	local d = SpringState.describe(config, names, drives, protocol)
	for _, t in { config, config.nodes, config.nodes[1], config.nodes[1].projection, config.edges, config.edges[1], config.bankChannels, names, drives } do
		assert(not table.isfrozen(t), "describe froze a caller table")
	end
	local callerTables = Fixtures.tables({ config, names, drives })
	for t in Fixtures.tables(d) do assert(not callerTables[t], "descriptor shares a table with the caller's inputs") end
	drives[1] = "changed"; names[1] = "changed"
	assert(d.driveNames[1] == "trend" and d.stateNames[1] == "Fast01.x")
end)

local function fixtureXV(scale)
	local x, v = table.create(24), table.create(24)
	for i = 1, 24 do x[i] = scale * i / 100; v[i] = -scale * i / 1000 end
	return x, v
end

test("fromRecord copies only t, availableT, day, reset and the 48 measured x/v values per variant", function()
	local d = Fixtures.descriptor()
	local cx, cv = fixtureXV(1)
	local ix, iv = fixtureXV(2)
	local nx, nv = fixtureXV(3)
	local record = Fixtures.record({ t = T0 + 600, day = "fixture-day-03", reset = true,
		variants = { coupled = { x = cx, v = cv }, independent = { x = ix, v = iv }, numeric = { x = nx, v = nv } } })
	for variant, pair in { coupled = { cx, cv }, independent = { ix, iv }, numeric = { nx, nv } } do
		local s = SpringState.fromRecord(record, variant, d, variant .. ":7")
		SpringState.checkSample(s)
		assert(s.id == variant .. ":7" and s.t == T0 + 600 and s.availableT == T0 + 900 and s.day == "fixture-day-03" and s.reset == true)
		assert(s.valid == true and s.invalidReason == nil and #s.x == 24 and #s.v == 24)
		local vector = record.states[variant].vector
		for i = 1, 24 do
			assert(s.x[i] == pair[1][i] and s.x[i] == vector[i], "x copy " .. i)
			assert(s.v[i] == pair[2][i] and s.v[i] == vector[24 + i], "v copy " .. i)
		end
		assert(s.x[17] == vector[17] and s.v[17] == vector[41])
		for k in s do assert(table.find(SpringState.SAMPLE_KEYS, k), "unexpected key " .. k) end
	end
end)

test("negative isolation shape: no bar, feature, drive, force, label or record table is reachable from a sample", function()
	local descriptor = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local record = Fixtures.record({ x = x, v = v })
	local sample = SpringState.fromRecord(record, "coupled", descriptor, "fixture-1")
	assert(sample.bar == nil and sample.feature == nil and sample.drive == nil)
	assert(sample.force == nil and sample.label == nil)
	assert(sample.states == nil and sample.nodes == nil and sample.energy == nil and sample.banks == nil and sample.raw == nil)
	local before = sample.x[1]
	record.states.coupled.vector[1] = before + 100
	assert(sample.x[1] == before)
	local recordTables = Fixtures.tables(record)
	for t in Fixtures.tables(sample) do assert(not recordTables[t], "a record table is reachable from the sample") end
	for _, value in sample do assert(value ~= record.bar.label, "label leaked into the sample") end
	-- Channels a table walk cannot see: a metatable (an __index closure over the record) and hash keys hidden in x/v.
	assert(getmetatable(sample) == nil and getmetatable(sample.x) == nil and getmetatable(sample.v) == nil, "sample carries a metatable")
	for _, values in { sample.x, sample.v } do
		local count = 0
		for k in values do
			assert(type(k) == "number" and k % 1 == 0 and k >= 1 and k <= 24, "non-array key in x/v: " .. tostring(k))
			count += 1
		end
		assert(count == 24)
	end
	local keys = {}
	for k in sample do table.insert(keys, k) end
	table.sort(keys)
	assert(table.concat(keys, ",") == "availableT,day,id,reset,t,v,valid,x", "sample keys: " .. table.concat(keys, ","))
	for _, field in { "c", "o", "h", "l", "close", "price", "label", "volatility", "regime", "contexts", "raw", "drive", "force" } do
		assert(sample[field] == nil and rawget(sample, field) == nil, "sample exposes " .. field)
	end
end)

test("x/v come only from states.<variant>.vector: decoy node x/v, drive, force and energies are never read", function()
	local descriptor = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local record = Fixtures.record({ x = x, v = v })
	for _, variant in SpringState.VARIANTS do
		local state = record.states[variant]
		for i = 1, 24 do
			local node = state.nodes[i]
			node.x, node.v, node.drive, node.force = 1000 + i, -1000 - i, 3 * i, -7 * i
		end
		for b = 1, 3 do state.banks[b].displacement, state.banks[b].velocity = 50 * b, -50 * b end
		state.energy = 123
	end
	for _, variant in SpringState.VARIANTS do
		local s = SpringState.fromRecord(record, variant, descriptor, variant .. ":1")
		assert(s.valid)
		for i = 1, 24 do assert(s.x[i] == x[i] and s.v[i] == v[i], variant .. " x/v did not come from the vector at " .. i) end
	end
	-- And the vector really is the source: changing it changes the sample.
	record.states.coupled.vector[3], record.states.coupled.vector[24 + 5] = 0.75, -0.5
	local changed = SpringState.fromRecord(record, "coupled", descriptor, "coupled:1")
	assert(changed.x[3] == 0.75 and changed.v[5] == -0.5)
end)

test("mutation isolation in both directions", function()
	local descriptor = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local record = Fixtures.record({ t = T0 + 300, x = x, v = v })
	local sample = SpringState.fromRecord(record, "coupled", descriptor, "coupled:2")
	local snapshot = Fixtures.deepCopy(sample)
	-- Record -> sample: corrupt the original after adaptation.
	local state = record.states.coupled
	state.vector[1] += 100; state.vector[25] -= 100; state.vector[48] = 0 / 0; state.names[1] = "Changed.x"
	record.bar.t, record.bar.availableT, record.bar.day, record.feature.reset = 1, 2, "other", true
	Fixtures.deepEqual(sample, snapshot)
	-- Sample -> record: corrupt the copy; the original checkpoint object is unchanged.
	local record2 = Fixtures.record({ t = T0 + 300, x = x, v = v })
	local original = Fixtures.deepCopy(record2)
	local sample2 = SpringState.fromRecord(record2, "coupled", descriptor, "coupled:2")
	sample2.x[1], sample2.v[24], sample2.t, sample2.day = 99, -99, 0, "x"
	table.insert(sample2.x, 5)
	Fixtures.deepEqual(record2, original)
	local again = SpringState.fromRecord(record2, "coupled", descriptor, "coupled:2")
	assert(again.x ~= sample2.x and again.x[1] == x[1] and #again.x == 24)
end)

test("invalid samples carry an explicit reason and no measurements", function()
	local d = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local function invalid(record, reason, variant)
		local s = SpringState.fromRecord(record, variant or "coupled", d, "coupled:9")
		assert(s.valid == false and s.invalidReason == reason, "expected " .. reason .. ", got " .. tostring(s.invalidReason))
		assert(s.x == nil and s.v == nil and s.t == record.bar.t and type(s.day) == "string" and type(s.reset) == "boolean")
		SpringState.checkSample(s)
		return s
	end
	local nanX = table.clone(x); nanX[3] = 0 / 0
	invalid(Fixtures.record({ x = nanX, v = v }), "non_finite_state")
	local infV = table.clone(v); infV[24] = math.huge
	invalid(Fixtures.record({ x = x, v = infV }), "non_finite_state")
	local swapped = Fixtures.stateNames(); swapped[1], swapped[2] = swapped[2], swapped[1]
	invalid(Fixtures.record({ x = x, v = v, names = swapped }), "names_mismatch")
	local v3 = Fixtures.v3Config(24)
	local v3Record = Fixtures.record({ x = x, v = v })
	v3Record.states.coupled.names = Fixtures.v3StateNames(v3)
	for i = 52, 59 do v3Record.states.coupled.vector[i] = 0.1 end
	invalid(v3Record, "names_mismatch")
	local short = Fixtures.record({ x = x, v = v })
	table.remove(short.states.coupled.vector)
	invalid(short, "malformed_vector")
	local late = invalid(Fixtures.record({ t = T0, availableT = T0 + 600, x = x, v = v }), "availability_mismatch")
	assert(late.availableT == T0 + 600)
	local early = invalid(Fixtures.record({ t = T0, availableT = T0, x = x, v = v }), "availability_mismatch")
	assert(early.availableT == T0)
	local missingAvailability = Fixtures.record({ x = x, v = v })
	missingAvailability.bar.availableT = nil
	assert(invalid(missingAvailability, "availability_mismatch").availableT == nil)
	-- A non-finite availableT is dropped (NaN cannot be JSON-encoded), never kept in the sample.
	for _, bad in { 0 / 0, math.huge, -math.huge, "1800000300" } do
		local r = Fixtures.record({ x = x, v = v })
		r.bar.availableT = bad
		assert(invalid(r, "availability_mismatch").availableT == nil)
		local s = SpringState.synthetic(d, "fixture:9", T0, bad, "fixture-day-01", false, x, v)
		assert(s.valid == false and s.invalidReason == "availability_mismatch" and s.availableT == nil and s.x == nil)
		SpringState.checkSample(s)
	end
	invalid(Fixtures.record({ x = x, v = v, omit = { numeric = true } }), "missing_variant", "numeric")
	local noStates = Fixtures.record({ x = x, v = v }); noStates.states = nil
	invalid(noStates, "missing_variant")
	local ok = SpringState.fromRecord(Fixtures.record({ x = x, v = v }), "coupled", d, "coupled:9")
	assert(ok.valid == true and ok.invalidReason == nil)
end)

test("corrupt metadata and programming errors fail explicitly", function()
	local d = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local r = Fixtures.record({ x = x, v = v }); r.bar.t = nil
	rejects(function() SpringState.fromRecord(r, "coupled", d, "coupled:1") end, "finite bar.t")
	r = Fixtures.record({ x = x, v = v }); r.feature.reset = nil
	rejects(function() SpringState.fromRecord(r, "coupled", d, "coupled:1") end, "boolean feature.reset")
	r = Fixtures.record({ x = x, v = v }); r.bar.day = nil
	rejects(function() SpringState.fromRecord(r, "coupled", d, "coupled:1") end, "bar.day")
	rejects(function() SpringState.fromRecord(Fixtures.record({ x = x, v = v }), "drive", d, "coupled:1") end, "unknown variant")
	rejects(function() SpringState.fromRecord(Fixtures.record({ x = x, v = v }), "coupled", d, "") end, "sample id")
	rejects(function() SpringState.fromRecord(Fixtures.record({ x = x, v = v }), "coupled", Fixtures.deepCopy(d), "coupled:1") end, "frozen descriptor")
	rejects(function() SpringState.fromRecord({ states = {} }, "coupled", d, "coupled:1") end, "record with bar and feature")
end)

test("synthetic copies x/v, validates availability and finiteness", function()
	local d = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local s = SpringState.synthetic(d, "zero:1", T0, T0 + 300, "fixture-day-01", true, x, v)
	assert(s.valid and s.x ~= x and s.v ~= v and s.x[5] == x[5] and s.v[5] == v[5])
	x[5] = 77
	assert(s.x[5] == 5 / 100)
	local nanX = table.clone(x); nanX[1] = 0 / 0
	local bad = SpringState.synthetic(d, "fixture:2", T0, T0 + 300, "fixture-day-01", false, nanX, v)
	assert(not bad.valid and bad.invalidReason == "non_finite_state" and bad.x == nil)
	local late = SpringState.synthetic(d, "fixture:3", T0, T0 + 301, "fixture-day-01", false, x, v)
	assert(not late.valid and late.invalidReason == "availability_mismatch")
	rejects(function() SpringState.synthetic(d, "fixture:4", T0, T0 + 300, "fixture-day-01", false, { 1, 2 }, v) end, "24 x and 24 v")
	rejects(function() SpringState.synthetic(d, "fixture:5", T0, T0 + 300, "fixture-day-01", nil, x, v) end, "reset")
end)

test("checkSample rejects market records and widened samples", function()
	local d = Fixtures.descriptor()
	local x, v = fixtureXV(1)
	local record = Fixtures.record({ x = x, v = v })
	rejects(function() SpringState.checkSample(record) end, "is not allowed")
	local s = SpringState.fromRecord(record, "coupled", d, "coupled:1")
	SpringState.checkSample(s)
	local widened = Fixtures.deepCopy(s); widened.drive = { 1 }
	rejects(function() SpringState.checkSample(widened) end, "sample field 'drive' is not allowed")
	local forged = Fixtures.deepCopy(s); forged.availableT = s.t
	rejects(function() SpringState.checkSample(forged) end, "available at t + 300")
	local smuggled = Fixtures.deepCopy(s); smuggled.valid = false; smuggled.invalidReason = "non_finite_state"
	rejects(function() SpringState.checkSample(smuggled) end, "no measurements")
	-- Hidden channels (review 2026-10-05): a metatable, a hash key inside x/v, a short or non-finite array.
	local withMeta = Fixtures.deepCopy(s)
	setmetatable(withMeta, { __index = function(_, k) return record.bar[k] end })
	rejects(function() SpringState.checkSample(withMeta) end, "metatable is not allowed")
	local metaX = Fixtures.deepCopy(s); setmetatable(metaX.x, {})
	rejects(function() SpringState.checkSample(metaX) end, "24 x and 24 v values")
	local hidden = Fixtures.deepCopy(s); hidden.x.close = record.bar.c
	assert(#hidden.x == 24)
	rejects(function() SpringState.checkSample(hidden) end, "plain 24-value arrays (key 'close')")
	local extraV = Fixtures.deepCopy(s); extraV.v[0] = 1
	rejects(function() SpringState.checkSample(extraV) end, "plain 24-value arrays (key '0')")
	local shortX = Fixtures.deepCopy(s); shortX.x[24] = nil
	rejects(function() SpringState.checkSample(shortX) end, "24 x and 24 v values")
	local nanX = Fixtures.deepCopy(s); nanX.x[3] = 0 / 0
	rejects(function() SpringState.checkSample(nanX) end, "values must be finite")
	local infV = Fixtures.deepCopy(s); infV.v[7] = -math.huge
	rejects(function() SpringState.checkSample(infV) end, "values must be finite")
	local nanAvailability = SpringState.fromRecord(Fixtures.record({ x = x, v = v, availableT = T0 + 600 }), "coupled", d, "coupled:1")
	SpringState.checkSample(nanAvailability)
	nanAvailability.availableT = 0 / 0
	rejects(function() SpringState.checkSample(nanAvailability) end, "availableT must be finite or absent")
end)

print("SpringState: " .. passed .. " tests passed")
