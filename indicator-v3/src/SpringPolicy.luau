-- Spring Indicator shared action policy, protocol spring-consensus-v1 (handover 6.3, contract D4/D7/D12).
-- A pure state machine: bank scores + observation identity + execution position context -> SignalIntent.
-- It never receives a market record. The physical wrapper (SpringSignals) and the market-only baseline
-- (SpringStudy) both call it, so their hysteresis cannot drift apart.
-- This module also owns the canonical, frozen protocol table; every Spring module validates against it.
local SpringPolicy = {}
SpringPolicy.__index = SpringPolicy

local PROTOCOL_ID = "spring-consensus-v1"
SpringPolicy.PROTOCOL_ID = PROTOCOL_ID

local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function deepFreeze(t)
	for _, v in t do if type(v) == "table" then deepFreeze(v) end end
	if not table.isfrozen(t) then table.freeze(t) end
	return t
end

-- Any change to a value below is a new protocol version, never an edit of this one.
local PROTOCOL = deepFreeze({
	id = PROTOCOL_ID,
	stateSchema = "roalgo-mechanics-v2-1",
	descriptorSchema = "spring-v2-descriptor-1",
	nodeCount = 24,
	nodesPerBank = 8,
	stateDimension = 51,
	edgeCount = 37,
	bankNames = { "Fast", "Medium", "Slow" },
	driveNames = { "trend", "immediateReturn", "rangeActivity", "volume", "peerRelative", "hourlyContext", "dailyTrend", "regimeStress" },
	directionalChannels = { "immediateReturn", "trend", "hourlyContext", "dailyTrend" },
	directionalNodes = { { 1, 4, 7 }, { 9, 11, 12, 14, 15 }, { 17, 19, 20, 22, 23 } },
	dominantCoefficient = 0.72,
	barSeconds = 300,
	availabilityLag = 300,
	calibration = {
		minSamples = 100,
		minEligiblePerBank = 2,
		segmentPositionMin = 12,
		std = "population",
		dropAbsolute = 1e-6,
		dropRelative = 1e-4,
		clip = 5,
		xWeight = 0.8,
		vWeight = 0.2,
		quantile = 0.65,
		entryMin = 0.10,
		entryMax = 0.35,
		exitRatio = 0.45,
		deadbandRatio = 0.25,
	},
	policy = {
		warmup = 12,
		entryConfirmations = 2,
		exitConfirmations = 2,
		bankVotes = 2,
		cooldownBars = 3, -- barsSinceExit 0, 1 and 2 block entries; 3 may begin confirmation
	},
})

-- Returns the canonical deep-frozen protocol table for an id (default spring-consensus-v1).
function SpringPolicy.protocol(id)
	id = if id == nil then PROTOCOL_ID else id
	assert(id == PROTOCOL_ID, "SpringPolicy: unknown protocol " .. tostring(id))
	return PROTOCOL
end

local function sameValue(actual, expected, path)
	if type(expected) == "table" then
		assert(type(actual) == "table", "SpringPolicy: protocol mismatch at " .. path)
		for k, v in expected do sameValue(actual[k], v, path .. "." .. tostring(k)) end
		for k in actual do
			assert(expected[k] ~= nil, "SpringPolicy: protocol mismatch, unexpected field " .. path .. "." .. tostring(k))
		end
	else
		assert(actual == expected, "SpringPolicy: protocol mismatch at " .. path)
	end
end

-- Accepts the canonical table or an exact (e.g. JSON round-tripped) copy; anything else is an error.
function SpringPolicy.validateProtocol(protocol)
	assert(type(protocol) == "table", "SpringPolicy: protocol table required")
	assert(protocol.id == PROTOCOL_ID, "SpringPolicy: protocol id must be " .. PROTOCOL_ID .. ", got " .. tostring(protocol.id))
	if protocol ~= PROTOCOL then sameValue(protocol, PROTOCOL, "protocol") end
	return PROTOCOL
end

-- D12: a segment break is a recorded reset, or a missing interval inside one session (same day, t - prevT > 300).
-- An overnight boundary alone is not a break. The first observation of a stream starts a segment.
-- Reads only t, day and reset, and asserts strictly increasing time.
function SpringPolicy.segmentBreak(prevObservation, observation)
	assert(type(observation) == "table" and finite(observation.t), "SpringPolicy: observation with finite t required")
	assert(type(observation.day) == "string" and type(observation.reset) == "boolean", "SpringPolicy: observation day and reset required")
	if prevObservation == nil then return true end
	assert(type(prevObservation) == "table" and finite(prevObservation.t) and type(prevObservation.day) == "string",
		"SpringPolicy: previous observation with finite t and day required")
	assert(observation.t > prevObservation.t, "SpringPolicy: observation time must increase strictly")
	if observation.reset then return true end
	return observation.day == prevObservation.day and observation.t - prevObservation.t > PROTOCOL.barSeconds
end

-- The single warm-up/segment-position rule shared by the policy and by calibration membership (D1):
-- a break or an invalid observation returns the count to 0; a valid observation then adds 1.
function SpringPolicy.nextWarmup(warmup, broke, valid)
	assert(finite(warmup) and warmup >= 0 and type(broke) == "boolean" and type(valid) == "boolean", "SpringPolicy: warm-up arguments")
	if broke or not valid then warmup = 0 end
	if valid then warmup += 1 end
	return warmup
end

local DIAGNOSTIC_KEYS = { valid = true, reason = true, score = true, bankScores = true, nodeContributions = true,
	nodeScores = true, zX = true, zV = true, clipped = true }
local OBSERVATION_KEYS = { id = true, t = true, availableT = true, day = true, reset = true }
local CONTEXT_KEYS = { position = true, pending = true, exitedThisBar = true, barsSinceExit = true }

local function finiteArray(values, count, what)
	assert(type(values) == "table" and #values == count, "SpringPolicy: " .. what .. " must have " .. count .. " values")
	for k in values do assert(type(k) == "number" and k >= 1 and k <= count and k % 1 == 0, "SpringPolicy: " .. what .. " must be an array") end
	for i = 1, count do
		assert(finite(values[i]) and math.abs(values[i]) <= 1 + 1e-12, "SpringPolicy: " .. what .. " values must be finite in [-1,1]")
	end
end

local function checkDiagnostics(d)
	assert(type(d) == "table", "SpringPolicy: diagnostics table required")
	for k in d do
		assert(DIAGNOSTIC_KEYS[k], "SpringPolicy: diagnostics field '" .. tostring(k) .. "' is not allowed; a market record never reaches the policy")
	end
	assert(type(d.valid) == "boolean", "SpringPolicy: diagnostics.valid boolean required")
	if d.valid then
		assert(finite(d.score) and math.abs(d.score) <= 1 + 1e-12, "SpringPolicy: finite total score in [-1,1] required")
		finiteArray(d.bankScores, 3, "bankScores")
		if d.nodeContributions ~= nil then finiteArray(d.nodeContributions, 24, "nodeContributions") end
	else
		assert(type(d.reason) == "string" and #d.reason > 0, "SpringPolicy: invalid diagnostics require a reason")
	end
end

local function checkObservation(o)
	assert(type(o) == "table", "SpringPolicy: observation table required")
	for k in o do assert(OBSERVATION_KEYS[k], "SpringPolicy: observation field '" .. tostring(k) .. "' is not allowed") end
	assert(type(o.id) == "string" and #o.id > 0, "SpringPolicy: observation id required")
	assert(finite(o.t) and finite(o.availableT), "SpringPolicy: finite observation t and availableT required")
	assert(type(o.day) == "string" and type(o.reset) == "boolean", "SpringPolicy: observation day and reset required")
end

function SpringPolicy.checkPositionContext(c)
	assert(type(c) == "table", "SpringPolicy: position context table required")
	for k in c do assert(CONTEXT_KEYS[k], "SpringPolicy: position context field '" .. tostring(k) .. "' is not allowed") end
	assert(c.position == -1 or c.position == 0 or c.position == 1, "SpringPolicy: position must be -1, 0 or 1")
	assert(type(c.pending) == "boolean" and type(c.exitedThisBar) == "boolean", "SpringPolicy: pending and exitedThisBar booleans required")
	local b = c.barsSinceExit
	assert(b == nil or (finite(b) and b >= 0 and b % 1 == 0), "SpringPolicy: barsSinceExit must be nil or a non-negative integer")
	assert(not c.exitedThisBar or b == 0, "SpringPolicy: an exit bar has barsSinceExit 0 (D4)")
	return c
end

local function checkThresholds(t)
	assert(type(t) == "table", "SpringPolicy: thresholds table required")
	local cal = PROTOCOL.calibration
	assert(finite(t.entry) and t.entry >= cal.entryMin and t.entry <= cal.entryMax, "SpringPolicy: entry threshold outside protocol bounds")
	assert(finite(t.exit) and math.abs(t.exit - cal.exitRatio * t.entry) <= 1e-12, "SpringPolicy: exit must equal 0.45 x entry")
	assert(finite(t.bankDeadband) and math.abs(t.bankDeadband - cal.deadbandRatio * t.entry) <= 1e-12, "SpringPolicy: bankDeadband must equal 0.25 x entry")
	return t.entry, t.exit, t.bankDeadband
end

function SpringPolicy.new(thresholds, protocol, source)
	SpringPolicy.validateProtocol(protocol)
	assert(source == "physics" or source == "baseline", "SpringPolicy: source must be physics or baseline")
	local entry, exit, deadband = checkThresholds(thresholds)
	return setmetatable({
		source = source,
		thresholds = table.freeze({ entry = entry, exit = exit, bankDeadband = deadband }),
		warmup = 0, posConfirm = 0, negConfirm = 0, longExit = 0, shortExit = 0,
		last = nil,
	}, SpringPolicy)
end

function SpringPolicy:state()
	return { warmup = self.warmup, posConfirm = self.posConfirm, negConfirm = self.negConfirm, longExit = self.longExit, shortExit = self.shortExit }
end

-- Ledger boundary: clears entry confirmation and exit counters; keeps the warm-up count and the last observation,
-- so the next observation is not mistaken for a segment start.
function SpringPolicy:resetBoundary()
	self.posConfirm, self.negConfirm, self.longExit, self.shortExit = 0, 0, 0, 0
end

local function clearCounters(self)
	self.posConfirm, self.negConfirm, self.longExit, self.shortExit = 0, 0, 0, 0
end

local function copyArray(values)
	if values == nil then return nil end
	local out = table.create(#values)
	for i = 1, #values do out[i] = values[i] end
	return out
end

local function votes(bankScores, threshold, sign)
	local count = 0
	for i = 1, 3 do if sign * bankScores[i] >= threshold then count += 1 end end
	return count
end

local function intent(self, action, source, reason, observation, d, setup, blocked)
	return {
		action = action, source = source, reason = reason,
		availableT = observation.availableT, sampleId = observation.id,
		diagnostics = {
			valid = d.valid,
			reason = if d.valid then nil else d.reason,
			score = if d.valid then d.score else nil,
			bankScores = if d.valid then copyArray(d.bankScores) else nil,
			nodeContributions = if d.valid then copyArray(d.nodeContributions) else nil,
			setup = setup,
			state = self:state(),
			blocked = blocked,
		},
	}
end

function SpringPolicy:step(diagnostics, observation, positionContext)
	checkDiagnostics(diagnostics)
	checkObservation(observation)
	local ctx = SpringPolicy.checkPositionContext(positionContext)
	local P = PROTOCOL.policy
	local broke = SpringPolicy.segmentBreak(self.last, observation)
	self.last = { t = observation.t, day = observation.day }
	self.warmup = SpringPolicy.nextWarmup(self.warmup, broke, diagnostics.valid)
	if broke or not diagnostics.valid then clearCounters(self) end

	if not diagnostics.valid then
		-- D7: an invalid state is a data-safety condition, never a directional prediction.
		if ctx.position ~= 0 then
			return intent(self, "CLOSE", "risk", "invalid_physics_state", observation, diagnostics, "none", nil)
		end
		return intent(self, "HOLD", self.source, "invalid_physics_state", observation, diagnostics, "none", "invalid_physics_state")
	end

	local entry, exit, deadband = self.thresholds.entry, self.thresholds.exit, self.thresholds.bankDeadband
	local score, banks = diagnostics.score, diagnostics.bankScores
	local setup = "none"
	if score >= entry and votes(banks, deadband, 1) >= P.bankVotes then
		setup = "positive"
	elseif score <= -entry and votes(banks, deadband, -1) >= P.bankVotes then
		setup = "negative"
	end

	if ctx.position == 1 then
		-- Exit counters run regardless of warm-up; entry counters stay 0 while positioned.
		self.posConfirm, self.negConfirm, self.shortExit = 0, 0, 0
		self.longExit = if score <= exit then self.longExit + 1 else 0
		if votes(banks, deadband, -1) >= P.bankVotes then
			return intent(self, "CLOSE", self.source, self.source .. "_bank_reversal", observation, diagnostics, setup, nil)
		elseif self.longExit >= P.exitConfirmations then
			return intent(self, "CLOSE", self.source, self.source .. "_loss_of_conviction", observation, diagnostics, setup, nil)
		end
		return intent(self, "HOLD", self.source, "holding_long", observation, diagnostics, setup, nil)
	elseif ctx.position == -1 then
		self.posConfirm, self.negConfirm, self.longExit = 0, 0, 0
		self.shortExit = if score >= -exit then self.shortExit + 1 else 0
		if votes(banks, deadband, 1) >= P.bankVotes then
			return intent(self, "CLOSE", self.source, self.source .. "_bank_reversal", observation, diagnostics, setup, nil)
		elseif self.shortExit >= P.exitConfirmations then
			return intent(self, "CLOSE", self.source, self.source .. "_loss_of_conviction", observation, diagnostics, setup, nil)
		end
		return intent(self, "HOLD", self.source, "holding_short", observation, diagnostics, setup, nil)
	end

	-- Flat: exit counters reset; entries are blocked by pending orders, the exit bar and the cooldown, then warm-up.
	self.longExit, self.shortExit = 0, 0
	local blocked = nil
	if ctx.pending then
		blocked = "pending"
	elseif ctx.exitedThisBar then
		blocked = "exited_this_bar"
	elseif ctx.barsSinceExit ~= nil and ctx.barsSinceExit < P.cooldownBars then
		blocked = "cooldown"
	elseif self.warmup < P.warmup then
		blocked = "warmup"
	end
	if blocked then
		self.posConfirm, self.negConfirm = 0, 0
		return intent(self, "HOLD", self.source, blocked, observation, diagnostics, setup, blocked)
	end
	if setup == "positive" then
		self.posConfirm += 1
		self.negConfirm = 0
	elseif setup == "negative" then
		self.negConfirm += 1
		self.posConfirm = 0
	else
		self.posConfirm, self.negConfirm = 0, 0
	end
	if self.posConfirm >= P.entryConfirmations then
		self.posConfirm, self.negConfirm = 0, 0
		return intent(self, "BUY", self.source, "confirmed_positive_setup", observation, diagnostics, setup, nil)
	elseif self.negConfirm >= P.entryConfirmations then
		self.posConfirm, self.negConfirm = 0, 0
		return intent(self, "SELL", self.source, "confirmed_negative_setup", observation, diagnostics, setup, nil)
	end
	local reason = if setup == "positive" then "positive_setup_unconfirmed"
		elseif setup == "negative" then "negative_setup_unconfirmed"
		else "no_setup"
	return intent(self, "HOLD", self.source, reason, observation, diagnostics, setup, nil)
end

return SpringPolicy
