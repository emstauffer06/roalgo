-- Spring Indicator narrow state boundary (protocol spring-consensus-v1; handover section 5, contract D13/D24).
-- describe() validates the saved v2 native configuration and state layout and returns a deep-frozen descriptor.
-- fromRecord() allocates a NEW narrow sample that copies only bar.t, bar.availableT, bar.day, feature.reset
-- and the 48 measured x/v values. Nothing else from bar/feature/states (never drive, force, energy, banks,
-- prices, labels or raw features) is read, and no table of the record is reachable from the sample.
local SpringPolicy = if script then require(script.Parent.SpringPolicy) else require("./SpringPolicy")

local SpringState = {}
SpringState.DESCRIPTOR_SCHEMA = "spring-v2-descriptor-1"
SpringState.VARIANTS = table.freeze({ "coupled", "independent", "numeric" })
SpringState.SAMPLE_KEYS = table.freeze({ "id", "t", "availableT", "day", "reset", "valid", "invalidReason", "x", "v" })

local VARIANT_SET = { coupled = true, independent = true, numeric = true }
local SAMPLE_KEY_SET = {}
for _, k in SpringState.SAMPLE_KEYS do SAMPLE_KEY_SET[k] = true end

-- Saved v2 layout facts (contract section 2, handover 6.1 drive-cycle table). Node (bank b, column c) is dominated by
-- channel V2_BANK_CHANNELS[b][(c - 1) % 3 + 1]: Fast immediateReturn/rangeActivity/volume, Medium trend/peerRelative/
-- hourlyContext, Slow dailyTrend/regimeStress/trend. Measured x = displacement / D with D = 64.
local V2_D = 64
local V2_BANK_CHANNELS = table.freeze({ table.freeze({ 2, 3, 4 }), table.freeze({ 1, 5, 6 }), table.freeze({ 7, 8, 1 }) })

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function deepFreeze(t)
	for _, v in t do if type(v) == "table" then deepFreeze(v) end end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end
local function isInteger(x) return finite(x) and x % 1 == 0 end

-- The 51 v2 state names derived from the configuration: <Node>.x (1..24), <Node>.v (25..48), <Bank>.energy (49..51).
function SpringState.expectedStateNames(nativeConfig)
	local names = table.create(51)
	for i = 1, 24 do
		names[i] = nativeConfig.nodes[i].name .. ".x"
		names[24 + i] = nativeConfig.nodes[i].name .. ".v"
	end
	for b = 1, 3 do names[48 + b] = nativeConfig.bankNames[b] .. ".energy" end
	return names
end

local function v2EdgeSet()
	local set = {}
	for bank = 1, 3 do for col = 1, 7 do local a = (bank - 1) * 8 + col; set[a .. ":" .. (a + 1)] = true end end
	for i = 1, 16 do set[i .. ":" .. (i + 8)] = true end
	return set
end

-- stateNames is either one 51-name array or a map {coupled=, independent=, numeric=} of the names saved for each
-- variant (contract section 2: rebuild the 51 names from the config and require equality for all three variants).
function SpringState.describe(nativeConfig, stateNames, driveNames, protocol)
	local p = SpringPolicy.validateProtocol(protocol)
	local function fail(message) error("SpringState.describe: " .. message, 2) end
	if type(nativeConfig) ~= "table" or type(nativeConfig.nodes) ~= "table" then fail("native config with nodes required") end
	if type(stateNames) ~= "table" then fail("state names required") end
	local nameSets = {}
	if stateNames[1] == nil and next(stateNames) ~= nil then
		for key in stateNames do
			if not VARIANT_SET[key] then fail("state names map key " .. tostring(key) .. " is not a variant") end
		end
		for _, variant in SpringState.VARIANTS do
			if type(stateNames[variant]) ~= "table" then fail("state names for variant " .. variant .. " required") end
			table.insert(nameSets, { label = variant .. " ", names = stateNames[variant] })
		end
	else
		table.insert(nameSets, { label = "", names = stateNames })
	end
	local nodeCount = #nativeConfig.nodes
	for _, set in nameSets do
		local count = #set.names
		if nodeCount == 48 or count == 59 or count == 107 then
			fail("v3-shaped input (" .. nodeCount .. " nodes, " .. count .. " " .. set.label .. "state names) is not the saved v2 layout")
		end
	end
	if nativeConfig.schema ~= p.stateSchema then fail("config schema " .. tostring(nativeConfig.schema) .. " is not " .. p.stateSchema) end
	if nodeCount ~= p.nodeCount then fail("node count " .. nodeCount .. " ~= 24") end
	if type(driveNames) ~= "table" or #driveNames ~= #p.driveNames then fail("8 drive names required") end
	for i, name in p.driveNames do
		if driveNames[i] ~= name then fail("drive name " .. i .. " is " .. tostring(driveNames[i]) .. ", expected " .. name) end
	end
	if type(nativeConfig.bankNames) ~= "table" or #nativeConfig.bankNames ~= 3 then fail("three bank names required") end
	for b, name in p.bankNames do
		if nativeConfig.bankNames[b] ~= name then fail("bank " .. b .. " name mismatch") end
	end
	if not (finite(nativeConfig.D) and nativeConfig.D > 0) then fail("finite positive displacement scale D required") end
	if nativeConfig.D ~= V2_D then fail("displacement scale D " .. nativeConfig.D .. " ~= 64 (saved v2 layout)") end
	if not (finite(nativeConfig.spacing) and nativeConfig.spacing > 0) then fail("finite positive spacing required") end
	local function sameCycle(actual, expected)
		if type(actual) ~= "table" then return false end
		for key in actual do if expected[key] == nil then return false end end
		for i, value in expected do
			if type(value) == "table" then
				if not sameCycle(actual[i], value) then return false end
			elseif actual[i] ~= value then
				return false
			end
		end
		return true
	end
	if not sameCycle(nativeConfig.bankChannels, V2_BANK_CHANNELS) then
		fail("bankChannels must equal the saved v2 drive cycle {{2,3,4},{1,5,6},{7,8,1}}")
	end

	local channelIndex, directionalChannel = {}, {}
	for i, name in p.driveNames do channelIndex[name] = i end
	for _, name in p.directionalChannels do directionalChannel[channelIndex[name]] = true end
	local declaredBank = {}
	for b, ids in p.directionalNodes do for _, id in ids do declaredBank[id] = b end end

	local nodes = table.create(24)
	for i = 1, 24 do
		local n = nativeConfig.nodes[i]
		if type(n) ~= "table" then fail("node " .. i .. " missing") end
		local bank, column = math.ceil(i / 8), (i - 1) % 8 + 1
		if n.index ~= i then fail("node " .. i .. " index mismatch") end
		if n.bank ~= bank then fail("node " .. i .. " is not in bank " .. bank .. " (banks must be 1-8/9-16/17-24)") end
		if n.column ~= column then fail("node " .. i .. " column mismatch") end
		local expectedName = p.bankNames[bank] .. string.format("%02d", column)
		if n.name ~= expectedName then fail("node " .. i .. " name " .. tostring(n.name) .. " ~= " .. expectedName) end
		if not (finite(n.omega) and n.omega > 0) then fail("node " .. i .. " omega must be finite and positive") end
		if not (finite(n.y) and finite(n.z)) then fail("node " .. i .. " y/z must be finite") end
		local projection = n.projection
		if type(projection) ~= "table" or #projection ~= 8 then fail("node " .. i .. " projection must have 8 terms") end
		local l1, dominant, largest = 0, 0, -1
		for c = 1, 8 do
			local value = projection[c]
			if not finite(value) then fail("node " .. i .. " projection term " .. c .. " is not finite") end
			l1 += math.abs(value)
			if math.abs(value) > largest then dominant, largest = c, math.abs(value) end
		end
		if math.abs(l1 - 1) > 1e-9 then fail("node " .. i .. " projection L1 " .. l1 .. " ~= 1") end
		for c = 1, 8 do
			if c ~= dominant and math.abs(projection[c]) >= largest - 1e-12 then fail("node " .. i .. " has no unique dominant projection term") end
		end
		local coefficient = projection[dominant]
		local declared = declaredBank[i] ~= nil
		if declared and not (math.abs(coefficient - p.dominantCoefficient) <= 1e-12 and directionalChannel[dominant]) then
			fail("declared directional node " .. i .. " has dominant " .. coefficient .. " on " .. p.driveNames[dominant] .. "; +0.72 on a directional channel required")
		end
		if not declared and directionalChannel[dominant] then
			fail("node " .. i .. " in bank " .. p.bankNames[bank] .. " has directional dominant channel " .. p.driveNames[dominant] .. " but is not declared directional")
		end
		if math.abs(coefficient - p.dominantCoefficient) > 1e-12 then
			fail("node " .. i .. " dominant projection " .. coefficient .. " ~= +0.72")
		end
		local cycleChannel = V2_BANK_CHANNELS[bank][(column - 1) % 3 + 1]
		if dominant ~= cycleChannel then
			fail("node " .. i .. " dominant channel " .. p.driveNames[dominant] .. " is not its v2 bank-cycle channel " .. p.driveNames[cycleChannel])
		end
		local copy = table.create(8)
		for c = 1, 8 do copy[c] = projection[c] end
		nodes[i] = {
			index = i, name = expectedName, bank = bank, bankName = p.bankNames[bank],
			omega = n.omega, y = n.y, z = n.z, projection = copy,
			dominantChannel = dominant, dominantName = p.driveNames[dominant], dominantCoefficient = coefficient,
			directional = declared,
		}
	end

	if type(nativeConfig.edges) ~= "table" or #nativeConfig.edges ~= p.edgeCount then fail("37 edges required") end
	local wanted, seen, edges = v2EdgeSet(), {}, table.create(37)
	for k = 1, #nativeConfig.edges do
		local e = nativeConfig.edges[k]
		if type(e) ~= "table" or not isInteger(e.a) or not isInteger(e.b) or e.a < 1 or e.b > 24 or e.a >= e.b then
			fail("edge " .. k .. " must join two node indexes a < b")
		end
		local key = e.a .. ":" .. e.b
		if seen[key] or not wanted[key] then fail("edge " .. key .. " is not in the v2 topology") end
		seen[key] = true
		edges[k] = { a = e.a, b = e.b }
	end

	local expected = SpringState.expectedStateNames(nativeConfig)
	for _, set in nameSets do
		local names = set.names
		if #names ~= p.stateDimension then fail(set.label .. "state names count " .. #names .. " ~= 51") end
		for key in names do
			if not (isInteger(key) and key >= 1 and key <= p.stateDimension) then fail(set.label .. "state names must be a 51-name array") end
		end
		for i = 1, p.stateDimension do
			if names[i] ~= expected[i] then fail(set.label .. "state name " .. i .. " is " .. tostring(names[i]) .. ", expected " .. expected[i]) end
		end
	end

	local banks, directional = table.create(3), {}
	for b = 1, 3 do
		local ids, dir = table.create(8), {}
		for col = 1, 8 do ids[col] = (b - 1) * 8 + col end
		for _, id in p.directionalNodes[b] do table.insert(dir, id); table.insert(directional, id) end
		banks[b] = { name = p.bankNames[b], nodes = ids, directional = dir }
	end
	local xIndex, vIndex, driveCopy = table.create(24), table.create(24), table.create(8)
	for i = 1, 24 do xIndex[i] = i; vIndex[i] = 24 + i end
	for i = 1, 8 do driveCopy[i] = p.driveNames[i] end
	return deepFreeze({
		schema = SpringState.DESCRIPTOR_SCHEMA,
		protocolId = p.id,
		nodeCount = 24,
		D = nativeConfig.D,
		spacing = nativeConfig.spacing,
		nodes = nodes,
		edges = edges,
		banks = banks,
		directional = directional,
		driveNames = driveCopy,
		stateNames = expected,
		xIndex = xIndex,
		vIndex = vIndex,
	})
end

function SpringState.checkDescriptor(descriptor)
	assert(type(descriptor) == "table" and descriptor.schema == SpringState.DESCRIPTOR_SCHEMA and table.isfrozen(descriptor),
		"SpringState: a frozen descriptor from SpringState.describe is required")
	return descriptor
end

-- Validates the narrow sample shape. Any other field (bar, feature, states, drive, force, label...) is an error, and so
-- is a metatable (an __index closure could reach the record) or a non-array key hidden inside x or v.
function SpringState.checkSample(sample)
	assert(type(sample) == "table", "SpringState: sample table required")
	assert(getmetatable(sample) == nil, "SpringState: a sample is a plain table; a metatable is not allowed")
	for k in sample do
		assert(SAMPLE_KEY_SET[k], "SpringState: sample field '" .. tostring(k) .. "' is not allowed; only narrow samples reach the scorer")
	end
	assert(type(sample.id) == "string" and #sample.id > 0, "SpringState: sample id required")
	assert(finite(sample.t) and type(sample.day) == "string" and type(sample.reset) == "boolean", "SpringState: sample t, day and reset required")
	assert(sample.availableT == nil or finite(sample.availableT), "SpringState: sample availableT must be finite or absent")
	assert(type(sample.valid) == "boolean", "SpringState: sample.valid boolean required")
	if sample.valid then
		assert(sample.invalidReason == nil and sample.availableT == sample.t + SpringPolicy.protocol().availabilityLag,
			"SpringState: a valid sample is available at t + 300")
		for _, values in { sample.x, sample.v } do
			assert(type(values) == "table" and getmetatable(values) == nil and #values == 24, "SpringState: valid sample needs 24 x and 24 v values")
			for k in values do
				assert(isInteger(k) and k >= 1 and k <= 24, "SpringState: sample x/v must be plain 24-value arrays (key '" .. tostring(k) .. "')")
			end
			for i = 1, 24 do assert(finite(values[i]), "SpringState: valid sample values must be finite") end
		end
	else
		assert(type(sample.invalidReason) == "string" and sample.x == nil and sample.v == nil,
			"SpringState: an invalid sample carries a reason and no measurements")
	end
	return sample
end

local function build(id, t, availableT, day, reset, reason, x, v)
	if reason == nil and availableT ~= t + SpringPolicy.protocol().availabilityLag then reason = "availability_mismatch" end
	if reason ~= nil then x, v = nil, nil end
	return { id = id, t = t, availableT = availableT, day = day, reset = reset, valid = reason == nil, invalidReason = reason, x = x, v = v }
end

-- sampleId is "<variant>:<recordIndex>" (D24), supplied by the caller.
function SpringState.fromRecord(record, variant, descriptor, sampleId)
	SpringState.checkDescriptor(descriptor)
	assert(VARIANT_SET[variant], "SpringState.fromRecord: unknown variant " .. tostring(variant))
	assert(type(sampleId) == "string" and #sampleId > 0, "SpringState.fromRecord: sample id required")
	assert(type(record) == "table" and type(record.bar) == "table" and type(record.feature) == "table", "SpringState.fromRecord: record with bar and feature required")
	-- The allowlist (D13): bar.t, bar.availableT, bar.day, feature.reset and the x/v coordinates.
	local t, availableT, day, reset = record.bar.t, record.bar.availableT, record.bar.day, record.feature.reset
	assert(finite(t), "SpringState.fromRecord: finite bar.t required")
	assert(type(day) == "string" and #day > 0, "SpringState.fromRecord: bar.day required")
	assert(type(reset) == "boolean", "SpringState.fromRecord: boolean feature.reset required")
	if not finite(availableT) then availableT = nil end
	local states = record.states
	local state = if type(states) == "table" then states[variant] else nil
	local reason, x, v = nil, nil, nil
	if type(state) ~= "table" then
		reason = "missing_variant"
	else
		local names, vector = state.names, state.vector
		local expected = descriptor.stateNames
		if type(names) ~= "table" or #names ~= #expected then
			reason = "names_mismatch"
		else
			for i = 1, #expected do if names[i] ~= expected[i] then reason = "names_mismatch"; break end end
		end
		if reason == nil and (type(vector) ~= "table" or #vector ~= #expected) then reason = "malformed_vector" end
		if reason == nil then
			x, v = table.create(24), table.create(24)
			for i = 1, 24 do
				local xi, vi = vector[descriptor.xIndex[i]], vector[descriptor.vIndex[i]]
				if not finite(xi) or not finite(vi) then reason = "non_finite_state"; break end
				x[i], v[i] = xi, vi
			end
		end
	end
	return build(sampleId, t, availableT, day, reset, reason, x, v)
end

-- For zero/frozen interventions and fixtures. Copies x/v; non-finite values give an invalid sample.
function SpringState.synthetic(descriptor, id, t, availableT, day, reset, x, v)
	SpringState.checkDescriptor(descriptor)
	assert(type(id) == "string" and #id > 0, "SpringState.synthetic: sample id required")
	assert(finite(t) and type(day) == "string" and #day > 0 and type(reset) == "boolean", "SpringState.synthetic: finite t, day and reset required")
	assert(type(x) == "table" and #x == 24 and type(v) == "table" and #v == 24, "SpringState.synthetic: 24 x and 24 v values required")
	if not finite(availableT) then availableT = nil end
	local reason, cx, cv = nil, table.create(24), table.create(24)
	for i = 1, 24 do
		if not finite(x[i]) or not finite(v[i]) then reason = "non_finite_state"; break end
		cx[i], cv[i] = x[i], v[i]
	end
	return build(id, t, availableT, day, reset, reason, cx, cv)
end

return SpringState
