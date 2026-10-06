local loaded, SpringPolicy = pcall(require, "../src/SpringPolicy")
assert(loaded and type(SpringPolicy) == "table", "SpringPolicy must implement the shared spring-consensus-v1 action rules")
local loadedFixtures, Fixtures = pcall(require, "./SpringFixtures")
assert(loadedFixtures and type(Fixtures) == "table", "SpringFixtures must provide synthetic fixtures")
local passed = 0
local function test(n, f) f(); passed += 1; print("PASS " .. n) end
local function rejects(f, fragment)
	local ok, err = pcall(f)
	assert(not ok, "expected a rejection containing '" .. fragment .. "'")
	assert(string.find(tostring(err), fragment, 1, true), "wrong rejection: " .. tostring(err) .. " (expected '" .. fragment .. "')")
end

-- Synthetic diagnostics (fixture values, not historical evidence). entry 0.2 -> exit 0.09, bankDeadband 0.05.
local protocol = SpringPolicy.protocol()
local ENTRY = 0.2
local THRESHOLDS = { entry = ENTRY, exit = 0.45 * ENTRY, bankDeadband = 0.25 * ENTRY }
local EXIT, DEAD = THRESHOLDS.exit, THRESHOLDS.bankDeadband
local function diag(score, banks) return { valid = true, score = score, bankScores = banks or { score, score, score } } end
local POS, NEG, NONE = diag(0.3), diag(-0.3), diag(0)
local WEAK = diag(0.03)     -- within the exit band on both sides, no bank vote either way
local INVALID = { valid = false, reason = "non_finite_state" }
local FLAT = Fixtures.context(0)
local LONG, SHORT = Fixtures.context(1), Fixtures.context(-1)

-- Drives one policy along a synthetic timeline: contiguous 5-minute bars unless a gap/overnight/reset is requested.
local function driver(source)
	local policy = SpringPolicy.new(THRESHOLDS, protocol, source or "physics")
	local k, t, day = 0, Fixtures.T0, 1
	local self = { policy = policy }
	function self.step(d, ctx, opts)
		opts = opts or {}
		k += 1
		if k > 1 then
			if opts.overnight then day += 1; t += 61500 elseif opts.gap then t += 600 else t += 300 end
		end
		local observation = { id = "fixture:" .. k, t = t, availableT = t + 300, day = string.format("fixture-day-%02d", day), reset = k == 1 or opts.reset == true }
		local intent = policy:step(d, observation, ctx or FLAT)
		assert(intent.availableT == t + 300 and intent.sampleId == "fixture:" .. k)
		return intent
	end
	function self.run(n, d, ctx)
		local last
		for _ = 1, n do last = self.step(d, ctx) end
		return last
	end
	return self
end
local function expect(intent, action, source, reason)
	assert(intent.action == action and intent.source == source and intent.reason == reason,
		string.format("expected %s/%s/%s, got %s/%s/%s", action, source, reason, intent.action, intent.source, intent.reason))
	return intent
end
local function warmed(source)
	local dr = driver(source)
	for k = 1, 12 do expect(dr.step(NONE), "HOLD", source or "physics", if k < 12 then "warmup" else "no_setup") end
	assert(dr.policy:state().warmup == 12)
	return dr
end
-- Asserts the full five-counter snapshot (intent.diagnostics.state or policy:state()).
local function expectState(s, warmup, posConfirm, negConfirm, longExit, shortExit)
	if s.diagnostics then s = s.diagnostics.state end
	assert(s.warmup == warmup and s.posConfirm == posConfirm and s.negConfirm == negConfirm and s.longExit == longExit and s.shortExit == shortExit,
		string.format("expected state %d/%d/%d/%d/%d, got %d/%d/%d/%d/%d", warmup, posConfirm, negConfirm, longExit, shortExit,
			s.warmup, s.posConfirm, s.negConfirm, s.longExit, s.shortExit))
	local keys = 0
	for _ in s do keys += 1 end
	assert(keys == 5, "state snapshot has exactly five counters")
end

test("protocol is canonical, deep-frozen, and only exact copies validate", function()
	Fixtures.assertDeepFrozen(protocol)
	assert(protocol.id == "spring-consensus-v1" and SpringPolicy.protocol("spring-consensus-v1") == protocol)
	rejects(function() SpringPolicy.protocol("spring-consensus-v2") end, "unknown protocol")
	local P, C = protocol.policy, protocol.calibration
	assert(P.warmup == 12 and P.entryConfirmations == 2 and P.exitConfirmations == 2 and P.bankVotes == 2 and P.cooldownBars == 3)
	assert(C.minSamples == 100 and C.minEligiblePerBank == 2 and C.segmentPositionMin == 12 and C.std == "population")
	assert(C.dropAbsolute == 1e-6 and C.dropRelative == 1e-4 and C.clip == 5 and C.xWeight == 0.8 and C.vWeight == 0.2)
	assert(C.quantile == 0.65 and C.entryMin == 0.10 and C.entryMax == 0.35 and C.exitRatio == 0.45 and C.deadbandRatio == 0.25)
	assert(protocol.barSeconds == 300 and protocol.availabilityLag == 300)
	assert(SpringPolicy.validateProtocol(Fixtures.deepCopy(protocol)) == protocol)
	local mutations = {
		{ "protocol.policy.warmup", function(p) p.policy.warmup = 11 end },
		{ "protocol.calibration.quantile", function(p) p.calibration.quantile = 0.6 end },
		{ "protocol.directionalNodes", function(p) p.directionalNodes[1][1] = 2 end },
		{ "unexpected field protocol.extra", function(p) p.extra = true end },
		{ "protocol.calibration.clip", function(p) p.calibration.clip = nil end },
		{ "protocol id", function(p) p.id = "spring-consensus-v0" end },
	}
	for _, m in mutations do
		local copy = Fixtures.deepCopy(protocol)
		m[2](copy)
		rejects(function() SpringPolicy.validateProtocol(copy) end, m[1])
		rejects(function() SpringPolicy.new(THRESHOLDS, copy, "physics") end, "protocol")
	end
end)

test("thresholds must follow the protocol bounds and ratios; source must be physics or baseline", function()
	rejects(function() SpringPolicy.new({ entry = 0.2, exit = 0.1, bankDeadband = 0.05 }, protocol, "physics") end, "exit must equal")
	rejects(function() SpringPolicy.new({ entry = 0.2, exit = 0.09, bankDeadband = 0.04 }, protocol, "physics") end, "bankDeadband must equal")
	rejects(function() SpringPolicy.new({ entry = 0.09, exit = 0.45 * 0.09, bankDeadband = 0.25 * 0.09 }, protocol, "physics") end, "outside protocol bounds")
	rejects(function() SpringPolicy.new({ entry = 0.36, exit = 0.45 * 0.36, bankDeadband = 0.25 * 0.36 }, protocol, "physics") end, "outside protocol bounds")
	SpringPolicy.new({ entry = 0.10, exit = 0.45 * 0.10, bankDeadband = 0.25 * 0.10 }, protocol, "baseline")
	SpringPolicy.new({ entry = 0.35, exit = 0.45 * 0.35, bankDeadband = 0.25 * 0.35 }, protocol, "physics")
	rejects(function() SpringPolicy.new(THRESHOLDS, protocol, "market") end, "source must be physics or baseline")
	rejects(function() SpringPolicy.new(THRESHOLDS, protocol, "risk") end, "source must be physics or baseline")
end)

test("segment breaks follow D12: reset or a same-day missing interval, never overnight alone", function()
	local function o(t, day, reset) return { t = t, day = day, reset = reset == true } end
	local T = Fixtures.T0
	assert(SpringPolicy.segmentBreak(nil, o(T, "d1")) == true)
	assert(SpringPolicy.segmentBreak(o(T, "d1"), o(T + 300, "d1")) == false)
	assert(SpringPolicy.segmentBreak(o(T, "d1"), o(T + 600, "d1")) == true)
	assert(SpringPolicy.segmentBreak(o(T, "d1"), o(T + 301, "d1")) == true)
	assert(SpringPolicy.segmentBreak(o(T, "d1"), o(T + 61500, "d2")) == false)
	assert(SpringPolicy.segmentBreak(o(T, "d1"), o(T + 300, "d1", true)) == true)
	assert(SpringPolicy.segmentBreak(o(T, "d1"), o(T + 61500, "d2", true)) == true)
	rejects(function() SpringPolicy.segmentBreak(o(T, "d1"), o(T, "d1")) end, "increase strictly")
	rejects(function() SpringPolicy.segmentBreak(o(T, "d1"), o(T - 300, "d1")) end, "increase strictly")
	assert(SpringPolicy.nextWarmup(5, false, true) == 6 and SpringPolicy.nextWarmup(5, true, true) == 1)
	assert(SpringPolicy.nextWarmup(5, false, false) == 0 and SpringPolicy.nextWarmup(5, true, false) == 0)
end)

test("positive setup -> BUY with exact two-observation confirmation; earliest entry is observation 13", function()
	local dr = driver()
	for k = 1, 11 do
		local i = expect(dr.step(POS), "HOLD", "physics", "warmup")
		assert(i.diagnostics.blocked == "warmup" and i.diagnostics.setup == "positive" and i.diagnostics.state.warmup == k)
		assert(i.diagnostics.state.posConfirm == 0)
	end
	local twelfth = expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	assert(twelfth.diagnostics.state.posConfirm == 1 and twelfth.diagnostics.state.warmup == 12 and twelfth.diagnostics.blocked == nil)
	local buy = expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup")
	assert(buy.diagnostics.score == 0.3 and buy.diagnostics.setup == "positive")
	assert(buy.diagnostics.state.posConfirm == 0 and buy.diagnostics.state.negConfirm == 0 and buy.diagnostics.state.warmup == 13)
end)

test("negative setup -> SELL at observation 13", function()
	local dr = driver()
	for _ = 1, 11 do expect(dr.step(NEG), "HOLD", "physics", "warmup") end
	assert(expect(dr.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed").diagnostics.state.negConfirm == 1)
	local sell = expect(dr.step(NEG), "SELL", "physics", "confirmed_negative_setup")
	assert(sell.diagnostics.setup == "negative" and sell.diagnostics.state.negConfirm == 0)
end)

test("confirmation requires two consecutive same-sign setups", function()
	local dr = warmed()
	assert(expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed").diagnostics.state.posConfirm == 1)
	assert(expect(dr.step(NONE), "HOLD", "physics", "no_setup").diagnostics.state.posConfirm == 0)
	expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	local flip = expect(dr.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed")
	assert(flip.diagnostics.state.posConfirm == 0 and flip.diagnostics.state.negConfirm == 1)
	expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup")
	expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed") -- counters were zeroed by the entry
end)

test("setup boundaries: score >= entry with at least two banks >= bankDeadband (sign-reversed for negative)", function()
	local dr = warmed()
	local function setupOf(d) return dr.step(d).diagnostics.setup end
	assert(setupOf(diag(ENTRY, { DEAD, DEAD, -0.9 })) == "positive")
	assert(setupOf(diag(ENTRY - 1e-12, { 0.5, 0.5, 0.5 })) == "none")
	assert(setupOf(diag(0.5, { 0.9, DEAD - 1e-12, -0.5 })) == "none")
	assert(setupOf(diag(-ENTRY, { -DEAD, -DEAD, 0.9 })) == "negative")
	assert(setupOf(diag(-ENTRY + 1e-12, { -0.5, -0.5, -0.5 })) == "none")
	assert(setupOf(diag(-0.5, { -0.9, -DEAD + 1e-12, 0.5 })) == "none")
	-- Setup is reported before position gating.
	assert(dr.step(POS, LONG).diagnostics.setup == "positive")
end)

test("long CLOSE by two-observation loss of conviction (score <= exit)", function()
	local dr = driver()
	local first = expect(dr.step(WEAK, LONG), "HOLD", "physics", "holding_long")
	assert(first.diagnostics.state.longExit == 1 and first.diagnostics.state.shortExit == 0)
	assert(expect(dr.step(POS, LONG), "HOLD", "physics", "holding_long").diagnostics.state.longExit == 0)
	expect(dr.step(WEAK, LONG), "HOLD", "physics", "holding_long")
	local close = expect(dr.step(diag(EXIT, { EXIT, EXIT, EXIT }), LONG), "CLOSE", "physics", "physics_loss_of_conviction")
	assert(close.diagnostics.state.longExit == 2)
	local justAbove = driver()
	justAbove.step(diag(EXIT + 1e-12), LONG)
	expect(justAbove.step(diag(EXIT + 1e-12), LONG), "HOLD", "physics", "holding_long")
end)

test("long CLOSE by one-observation bank reversal (two banks <= -bankDeadband)", function()
	local dr = driver()
	expect(dr.step(diag(0.3, { 0.95, -DEAD, -DEAD }), LONG), "CLOSE", "physics", "physics_bank_reversal")
	local one = driver()
	expect(one.step(diag(0.3, { 0.95, -DEAD, 0 }), LONG), "HOLD", "physics", "holding_long")
	expect(one.step(diag(0.3, { 0.95, -DEAD + 1e-12, -0.9 }), LONG), "HOLD", "physics", "holding_long")
end)

test("short CLOSE by loss of conviction (score >= -exit twice) and by bank reversal (two banks >= bankDeadband)", function()
	local dr = driver()
	assert(expect(dr.step(WEAK, SHORT), "HOLD", "physics", "holding_short").diagnostics.state.shortExit == 1)
	assert(expect(dr.step(NEG, SHORT), "HOLD", "physics", "holding_short").diagnostics.state.shortExit == 0)
	expect(dr.step(diag(-EXIT, { -EXIT, -EXIT, -EXIT }), SHORT), "HOLD", "physics", "holding_short")
	expect(dr.step(diag(-EXIT, { -EXIT, -EXIT, -EXIT }), SHORT), "CLOSE", "physics", "physics_loss_of_conviction")
	local below = driver()
	below.step(diag(-EXIT - 1e-12), SHORT)
	expect(below.step(diag(-EXIT - 1e-12), SHORT), "HOLD", "physics", "holding_short")
	local reversal = driver()
	expect(reversal.step(diag(-0.3, { -0.95, DEAD, DEAD }), SHORT), "CLOSE", "physics", "physics_bank_reversal")
	expect(driver().step(diag(-0.3, { -0.95, DEAD, 0 }), SHORT), "HOLD", "physics", "holding_short")
end)

test("long and short exit counters are separate and reset when flat", function()
	local dr = driver()
	local a = dr.step(NONE, LONG) -- score 0 is inside both exit bands
	assert(a.action == "HOLD" and a.diagnostics.state.longExit == 1 and a.diagnostics.state.shortExit == 0)
	local b = dr.step(NONE, SHORT)
	assert(b.action == "HOLD" and b.diagnostics.state.shortExit == 1 and b.diagnostics.state.longExit == 0, "a shared counter would close here")
	expect(dr.step(NONE, SHORT), "CLOSE", "physics", "physics_loss_of_conviction")
	local flat = driver()
	flat.step(WEAK, LONG)
	local f = flat.step(NONE, FLAT)
	assert(f.diagnostics.state.longExit == 0 and f.diagnostics.state.shortExit == 0)
	expect(flat.step(WEAK, LONG), "HOLD", "physics", "holding_long")
end)

test("warm-up never postpones a safety exit", function()
	local dr = driver()
	local first = expect(dr.step(diag(0.3, { 0.9, -0.5, -0.5 }), LONG), "CLOSE", "physics", "physics_bank_reversal")
	assert(first.diagnostics.state.warmup == 1)
	local conviction = driver()
	conviction.step(WEAK, LONG)
	assert(expect(conviction.step(WEAK, LONG), "CLOSE", "physics", "physics_loss_of_conviction").diagnostics.state.warmup == 2)
	local gap = warmed()
	gap.step(WEAK, LONG)
	gap.step(POS, LONG, { gap = true })
	local afterGap = expect(gap.step(diag(-0.3, { -0.9, -0.5, 0.5 }), LONG), "CLOSE", "physics", "physics_bank_reversal")
	assert(afterGap.diagnostics.state.warmup == 2)
	expect(driver().step(INVALID, SHORT), "CLOSE", "risk", "invalid_physics_state")
end)

test("cooldown arithmetic: barsSinceExit 0,1,2 blocked, 3 begins confirmation, 4 earliest entry; nil = no cooldown", function()
	local dr = warmed()
	local exitBar = expect(dr.step(POS, Fixtures.context(0, { exitedThisBar = true, barsSinceExit = 0 })), "HOLD", "physics", "exited_this_bar")
	assert(exitBar.diagnostics.blocked == "exited_this_bar" and exitBar.diagnostics.state.posConfirm == 0)
	for bars = 1, 2 do
		local i = expect(dr.step(POS, Fixtures.context(0, { barsSinceExit = bars })), "HOLD", "physics", "cooldown")
		assert(i.diagnostics.blocked == "cooldown" and i.diagnostics.state.posConfirm == 0)
	end
	local three = expect(dr.step(POS, Fixtures.context(0, { barsSinceExit = 3 })), "HOLD", "physics", "positive_setup_unconfirmed")
	assert(three.diagnostics.state.posConfirm == 1)
	expect(dr.step(POS, Fixtures.context(0, { barsSinceExit = 4 })), "BUY", "physics", "confirmed_positive_setup")
	local never = warmed()
	never.step(NEG, Fixtures.context(0))
	expect(never.step(NEG, Fixtures.context(0)), "SELL", "physics", "confirmed_negative_setup")
	local late = warmed()
	late.step(NEG, Fixtures.context(0, { barsSinceExit = 10 }))
	expect(late.step(NEG, Fixtures.context(0, { barsSinceExit = 11 })), "SELL", "physics", "confirmed_negative_setup")
	-- Confirmation accumulated before a cooldown is reset by it.
	local reset = warmed()
	reset.step(POS, Fixtures.context(0))
	reset.step(POS, Fixtures.context(0, { barsSinceExit = 2 }))
	expect(reset.step(POS, Fixtures.context(0, { barsSinceExit = 3 })), "HOLD", "physics", "positive_setup_unconfirmed")
end)

test("pending orders and the exit bar suppress entries and reset confirmation", function()
	local dr = warmed()
	dr.step(POS)
	local pending = expect(dr.step(POS, Fixtures.context(0, { pending = true })), "HOLD", "physics", "pending")
	assert(pending.diagnostics.blocked == "pending" and pending.diagnostics.state.posConfirm == 0)
	expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup")
	local exited = warmed()
	exited.step(NEG)
	expect(exited.step(NEG, Fixtures.context(0, { exitedThisBar = true, barsSinceExit = 0 })), "HOLD", "physics", "exited_this_bar")
	-- pending takes precedence in the reason when several blocks hold
	expect(exited.step(NEG, Fixtures.context(0, { pending = true, barsSinceExit = 1 })), "HOLD", "physics", "pending")
end)

test("an invalid sample clears confirmation, restarts warm-up and never enters", function()
	local dr = warmed()
	assert(dr.step(POS).diagnostics.state.posConfirm == 1)
	local smuggled = { valid = false, reason = "non_finite_state", score = 0.9, bankScores = { 0.9, 0.9, 0.9 } }
	local bad = expect(dr.step(smuggled), "HOLD", "physics", "invalid_physics_state")
	assert(bad.diagnostics.blocked == "invalid_physics_state" and bad.diagnostics.setup == "none")
	assert(bad.diagnostics.valid == false and bad.diagnostics.reason == "non_finite_state" and bad.diagnostics.score == nil and bad.diagnostics.bankScores == nil)
	local s = bad.diagnostics.state
	assert(s.warmup == 0 and s.posConfirm == 0 and s.negConfirm == 0 and s.longExit == 0 and s.shortExit == 0)
	for _ = 1, 11 do expect(dr.step(POS), "HOLD", "physics", "warmup") end
	expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup")
	local repeated = warmed()
	for _ = 1, 20 do assert(repeated.step(INVALID).action == "HOLD") end
end)

test("invalid while positioned -> risk CLOSE invalid_physics_state (both sources); flat -> HOLD", function()
	for _, source in { "physics", "baseline" } do
		expect(driver(source).step(INVALID, LONG), "CLOSE", "risk", "invalid_physics_state")
		expect(driver(source).step(INVALID, SHORT), "CLOSE", "risk", "invalid_physics_state")
		expect(driver(source).step(INVALID, FLAT), "HOLD", source, "invalid_physics_state")
	end
	local dr = driver()
	dr.step(WEAK, LONG)
	local close = expect(dr.step(INVALID, LONG), "CLOSE", "risk", "invalid_physics_state")
	assert(close.diagnostics.state.longExit == 0)
end)

test("an intraday gap resets warm-up and counters; overnight alone does not", function()
	local gap = warmed()
	gap.step(POS)
	local afterGap = expect(gap.step(POS, FLAT, { gap = true }), "HOLD", "physics", "warmup")
	assert(afterGap.diagnostics.state.warmup == 1 and afterGap.diagnostics.state.posConfirm == 0)
	local overnight = warmed()
	overnight.step(POS)
	local buy = expect(overnight.step(POS, FLAT, { overnight = true }), "BUY", "physics", "confirmed_positive_setup")
	assert(buy.diagnostics.state.warmup == 14)
	local recorded = warmed()
	recorded.step(POS)
	expect(recorded.step(POS, FLAT, { reset = true }), "HOLD", "physics", "warmup")
	for _ = 2, 11 do expect(recorded.step(POS), "HOLD", "physics", "warmup") end
	expect(recorded.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	local afterReset = expect(recorded.step(POS), "BUY", "physics", "confirmed_positive_setup")
	assert(afterReset.diagnostics.state.warmup == 13, "earliest entry is the 13th observation after a mid-stream reset")
	local exitGap = driver()
	exitGap.step(WEAK, LONG)
	local cleared = expect(exitGap.step(WEAK, LONG, { gap = true }), "HOLD", "physics", "holding_long")
	assert(cleared.diagnostics.state.longExit == 1)
	local exitOvernight = driver()
	exitOvernight.step(WEAK, LONG)
	expect(exitOvernight.step(WEAK, LONG, { overnight = true }), "CLOSE", "physics", "physics_loss_of_conviction")
end)

test("resetBoundary keeps warm-up and the last observation but clears every counter", function()
	local dr = warmed()
	dr.step(POS)
	dr.policy:resetBoundary()
	local s = dr.policy:state()
	assert(s.warmup == 13 and s.posConfirm == 0 and s.negConfirm == 0 and s.longExit == 0 and s.shortExit == 0)
	local next = expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed")
	assert(next.diagnostics.state.warmup == 14, "the observation after a ledger boundary is not a segment start")
	expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup")
	local exits = driver()
	exits.step(WEAK, LONG)
	exits.policy:resetBoundary()
	expect(exits.step(WEAK, LONG), "HOLD", "physics", "holding_long")
	local short = driver()
	short.step(WEAK, SHORT)
	short.policy:resetBoundary()
	assert(short.policy:state().shortExit == 0)
end)

test("no same-observation reversal: positioned observations never emit BUY or SELL and keep entry counters at 0", function()
	local dr = warmed()
	local close = expect(dr.step(NEG, LONG), "CLOSE", "physics", "physics_bank_reversal")
	assert(close.diagnostics.setup == "negative" and close.diagnostics.state.negConfirm == 0)
	for _, d in { NEG, NEG, POS, POS, NONE } do
		local i = dr.step(d, LONG)
		assert(i.action ~= "BUY" and i.action ~= "SELL" and i.diagnostics.state.posConfirm == 0 and i.diagnostics.state.negConfirm == 0)
		local j = dr.step(d, SHORT)
		assert(j.action ~= "BUY" and j.action ~= "SELL" and j.diagnostics.state.posConfirm == 0 and j.diagnostics.state.negConfirm == 0)
	end
	expect(dr.step(NEG, Fixtures.context(0, { exitedThisBar = true, barsSinceExit = 0 })), "HOLD", "physics", "exited_this_bar")
	-- Confirmation gathered while flat does not survive a positioned observation.
	local carried = warmed()
	assert(carried.step(POS).diagnostics.state.posConfirm == 1)
	local held = carried.step(POS, LONG)
	assert(held.diagnostics.state.posConfirm == 0 and held.diagnostics.state.negConfirm == 0)
	expect(carried.step(POS, FLAT), "HOLD", "physics", "positive_setup_unconfirmed")
	assert(carried.step(NEG).diagnostics.state.negConfirm == 1)
	assert(carried.step(NEG, SHORT).diagnostics.state.negConfirm == 0)
	expect(carried.step(NEG, FLAT), "HOLD", "physics", "negative_setup_unconfirmed")
end)

test("inputs outside the narrow interface are rejected", function()
	local dr = warmed()
	rejects(function() dr.step({ valid = true, score = 0.3, bankScores = { 0.3, 0.3, 0.3 }, bar = { c = 100 } }) end, "diagnostics field 'bar' is not allowed")
	rejects(function() dr.step({ valid = true, score = 0.3, bankScores = { 0.3, 0.3, 0.3 }, feature = {} }) end, "diagnostics field 'feature'")
	rejects(function() dr.step({ valid = true, score = 0.3, bankScores = { 0.3, 0.3 } }) end, "bankScores must have 3")
	rejects(function() dr.step({ valid = true, score = 0 / 0, bankScores = { 0, 0, 0 } }) end, "finite total score")
	rejects(function() dr.step({ valid = true, score = 1.5, bankScores = { 0, 0, 0 } }) end, "finite total score")
	rejects(function() dr.step({ valid = true, score = 0.1, bankScores = { 0, 0, math.huge } }) end, "bankScores values")
	rejects(function() dr.step({ valid = true, score = 0.1, bankScores = { 0, 0, 1.5 } }) end, "bankScores values must be finite in [-1,1]")
	rejects(function() dr.step({ valid = true, score = 0.1, bankScores = { -1.01, 0, 0 } }) end, "bankScores values must be finite in [-1,1]")
	rejects(function() dr.step({ valid = true, score = 0.1, bankScores = { 0, 0, 0, close = 100 } }) end, "bankScores must be an array")
	rejects(function() dr.step({ valid = true, score = 0.1, bankScores = { 0, 0, 0 }, nodeContributions = { 1 } }) end, "nodeContributions must have 24")
	rejects(function() dr.step({ valid = false }) end, "require a reason")
	local policy = SpringPolicy.new(THRESHOLDS, protocol, "physics")
	local o = { id = "fixture:1", t = Fixtures.T0, availableT = Fixtures.T0 + 300, day = "fixture-day-01", reset = true }
	rejects(function() policy:step(NONE, { id = o.id, t = o.t, availableT = o.availableT, day = o.day, reset = true, label = "x" }, FLAT) end, "observation field 'label'")
	rejects(function() policy:step(NONE, { id = o.id, t = o.t, day = o.day, reset = true }, FLAT) end, "availableT")
	rejects(function() policy:step(NONE, o, { position = 2, pending = false, exitedThisBar = false }) end, "position must be")
	rejects(function() policy:step(NONE, o, { position = 0, pending = false, exitedThisBar = false, price = 100 }) end, "context field 'price'")
	rejects(function() policy:step(NONE, o, { position = 0, pending = false, exitedThisBar = true }) end, "barsSinceExit 0")
	rejects(function() policy:step(NONE, o, { position = 0, pending = false, exitedThisBar = false, barsSinceExit = 1.5 }) end, "non-negative integer")
	rejects(function() policy:step(NONE, o, { position = 0, pending = false, exitedThisBar = false, barsSinceExit = -1 }) end, "non-negative integer")
	rejects(function() policy:step(NONE, o, { position = 0, exitedThisBar = false }) end, "pending and exitedThisBar")
end)

test("intents copy diagnostics, echo availability identity and label the caller's source", function()
	local dr = warmed()
	local banks, contributions = { 0.3, 0.3, 0.3 }, table.create(24, 0.3 / 24)
	local i = dr.step({ valid = true, score = 0.3, bankScores = banks, nodeContributions = contributions })
	banks[1], contributions[1] = -1, -1
	assert(i.diagnostics.bankScores[1] == 0.3 and i.diagnostics.nodeContributions[1] == 0.3 / 24)
	assert(i.diagnostics.bankScores ~= banks and i.diagnostics.nodeContributions ~= contributions)
	local snapshot = dr.policy:state()
	snapshot.warmup = 0
	assert(dr.policy:state().warmup == 13)
	local base = warmed("baseline")
	base.step(POS)
	expect(base.step(POS), "BUY", "baseline", "confirmed_positive_setup")
	base.step(WEAK, LONG)
	expect(base.step(WEAK, LONG), "CLOSE", "baseline", "baseline_loss_of_conviction")
	expect(base.step(diag(-0.3, { -0.9, 0.5, 0.5 }), SHORT), "CLOSE", "baseline", "baseline_bank_reversal")
end)

-- Review 2026-10-05: the counter bookkeeping was only asserted on the positive/long side. Every rule below is the
-- negative/short mirror, with the full five-counter snapshot asserted after each step.
test("negative and short-side counter bookkeeping mirrors the positive and long side", function()
	-- Non-consecutive negative setups do not confirm.
	local a = warmed()
	expectState(expect(a.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed"), 13, 0, 1, 0, 0)
	expectState(expect(a.step(NONE), "HOLD", "physics", "no_setup"), 14, 0, 0, 0, 0)
	expectState(expect(a.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed"), 15, 0, 1, 0, 0)
	expectState(expect(a.step(NEG), "SELL", "physics", "confirmed_negative_setup"), 16, 0, 0, 0, 0)
	-- An opposite (positive) setup clears negConfirm.
	local b = warmed()
	b.step(NEG)
	expectState(expect(b.step(POS), "HOLD", "physics", "positive_setup_unconfirmed"), 14, 1, 0, 0, 0)
	expectState(expect(b.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed"), 15, 0, 1, 0, 0)
	-- Each entry block between two negative setups clears negConfirm; a SELL then needs two fresh observations.
	local blocks = { { "pending", { pending = true } }, { "exited_this_bar", { exitedThisBar = true, barsSinceExit = 0 } },
		{ "cooldown", { barsSinceExit = 1 } }, { "cooldown", { barsSinceExit = 2 } } }
	for _, block in blocks do
		local c = warmed()
		expectState(c.step(NEG), 13, 0, 1, 0, 0)
		expectState(expect(c.step(NEG, Fixtures.context(0, block[2])), "HOLD", "physics", block[1]), 14, 0, 0, 0, 0)
		expectState(expect(c.step(NEG, Fixtures.context(0, { barsSinceExit = 3 })), "HOLD", "physics", "negative_setup_unconfirmed"), 15, 0, 1, 0, 0)
		expect(c.step(NEG, Fixtures.context(0, { barsSinceExit = 4 })), "SELL", "physics", "confirmed_negative_setup")
	end
	-- A flat observation clears a stale shortExit, so a re-entered short needs two fresh weak observations.
	local d = driver()
	expectState(expect(d.step(WEAK, SHORT), "HOLD", "physics", "holding_short"), 1, 0, 0, 0, 1)
	expectState(d.step(NONE, FLAT), 2, 0, 0, 0, 0)
	expectState(expect(d.step(WEAK, SHORT), "HOLD", "physics", "holding_short"), 3, 0, 0, 0, 1)
	expectState(expect(d.step(WEAK, SHORT), "CLOSE", "physics", "physics_loss_of_conviction"), 4, 0, 0, 0, 2)
	-- An intraday gap and an invalid sample clear shortExit (positioned and flat).
	local e = driver()
	e.step(WEAK, SHORT)
	expectState(expect(e.step(WEAK, SHORT, { gap = true }), "HOLD", "physics", "holding_short"), 1, 0, 0, 0, 1)
	local e2 = driver()
	e2.step(WEAK, SHORT)
	expectState(expect(e2.step(INVALID, SHORT), "CLOSE", "risk", "invalid_physics_state"), 0, 0, 0, 0, 0)
	expectState(expect(e2.step(WEAK, SHORT), "HOLD", "physics", "holding_short"), 1, 0, 0, 0, 1)
	local e3 = driver()
	e3.step(WEAK, SHORT)
	expectState(expect(e3.step(INVALID, FLAT), "HOLD", "physics", "invalid_physics_state"), 0, 0, 0, 0, 0)
	-- An invalid sample and an intraday gap clear negConfirm.
	local j = warmed()
	j.step(NEG)
	expectState(expect(j.step(INVALID), "HOLD", "physics", "invalid_physics_state"), 0, 0, 0, 0, 0)
	local g = warmed()
	g.step(NEG)
	expectState(expect(g.step(NEG, FLAT, { gap = true }), "HOLD", "physics", "warmup"), 1, 0, 0, 0, 0)
	-- A ledger boundary clears negConfirm (and keeps warm-up).
	local f = warmed()
	f.step(NEG)
	f.policy:resetBoundary()
	expectState(f.policy:state(), 13, 0, 0, 0, 0)
	expectState(expect(f.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed"), 14, 0, 1, 0, 0)
	expect(f.step(NEG), "SELL", "physics", "confirmed_negative_setup")
	local fs = driver()
	fs.step(WEAK, SHORT)
	fs.policy:resetBoundary()
	expectState(fs.policy:state(), 1, 0, 0, 0, 0)
	expectState(expect(fs.step(WEAK, SHORT), "HOLD", "physics", "holding_short"), 2, 0, 0, 0, 1)
	-- Positioned observations clear the entry counters of both signs.
	local i1 = warmed()
	i1.step(NEG)
	expectState(i1.step(NONE, LONG), 14, 0, 0, 1, 0)
	expectState(expect(i1.step(NEG), "HOLD", "physics", "negative_setup_unconfirmed"), 15, 0, 1, 0, 0)
	local i2 = warmed()
	i2.step(POS)
	expectState(i2.step(NONE, SHORT), 14, 0, 0, 0, 1)
	expectState(expect(i2.step(POS), "HOLD", "physics", "positive_setup_unconfirmed"), 15, 1, 0, 0, 0)
	-- A long observation zeroes shortExit and a short observation zeroes longExit.
	local i3 = driver()
	expectState(i3.step(WEAK, SHORT), 1, 0, 0, 0, 1)
	expectState(i3.step(POS, LONG), 2, 0, 0, 0, 0)
	expectState(i3.step(WEAK, LONG), 3, 0, 0, 1, 0)
	expectState(i3.step(NEG, SHORT), 4, 0, 0, 0, 0)
	expectState(i3.step(WEAK, SHORT), 5, 0, 0, 0, 1)
	expectState(i3.step(WEAK, LONG), 6, 0, 0, 1, 0)
end)

test("both exit conditions on one observation report the bank reversal (long and short)", function()
	local long = driver()
	expectState(expect(long.step(WEAK, LONG), "HOLD", "physics", "holding_long"), 1, 0, 0, 1, 0)
	expectState(expect(long.step(diag(0, { -DEAD, -DEAD, DEAD }), LONG), "CLOSE", "physics", "physics_bank_reversal"), 2, 0, 0, 2, 0)
	local short = driver()
	expectState(expect(short.step(WEAK, SHORT), "HOLD", "physics", "holding_short"), 1, 0, 0, 0, 1)
	expectState(expect(short.step(diag(0, { DEAD, DEAD, -DEAD }), SHORT), "CLOSE", "physics", "physics_bank_reversal"), 2, 0, 0, 0, 2)
	local base = driver("baseline")
	base.step(WEAK, LONG)
	expect(base.step(diag(0, { -DEAD, -DEAD, DEAD }), LONG), "CLOSE", "baseline", "baseline_bank_reversal")
end)

test("an intraday gap on a later session resets warm-up; the overnight boundary before it does not", function()
	local dr = warmed()
	expectState(expect(dr.step(POS, FLAT, { overnight = true }), "HOLD", "physics", "positive_setup_unconfirmed"), 13, 1, 0, 0, 0)
	expectState(expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup"), 14, 0, 0, 0, 0)
	expectState(expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed"), 15, 1, 0, 0, 0)
	expectState(expect(dr.step(POS, FLAT, { gap = true }), "HOLD", "physics", "warmup"), 1, 0, 0, 0, 0)
	for k = 2, 11 do expectState(expect(dr.step(POS), "HOLD", "physics", "warmup"), k, 0, 0, 0, 0) end
	expectState(expect(dr.step(POS), "HOLD", "physics", "positive_setup_unconfirmed"), 12, 1, 0, 0, 0)
	expect(dr.step(POS), "BUY", "physics", "confirmed_positive_setup")
	local late = warmed()
	for _ = 1, 3 do late.step(NONE, FLAT, { overnight = true }); late.step(NONE) end
	expectState(late.policy:state(), 18, 0, 0, 0, 0)
	expectState(expect(late.step(NONE, FLAT, { gap = true }), "HOLD", "physics", "warmup"), 1, 0, 0, 0, 0)
	local held = warmed()
	held.step(NONE, FLAT, { overnight = true })
	held.step(WEAK, LONG)
	expectState(expect(held.step(WEAK, LONG, { gap = true }), "HOLD", "physics", "holding_long"), 1, 0, 0, 1, 0)
end)

print("SpringPolicy: " .. passed .. " tests passed")
