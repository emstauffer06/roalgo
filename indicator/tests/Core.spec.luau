local loaded, Core = pcall(require, "../src/Core")
assert(loaded and type(Core) == "table", "Core module must implement the finance contract")
local passed = 0
local function test(name, run)
	run()
	passed += 1
	print("PASS " .. name)
end
local function near(a, b, tolerance)
	assert(math.abs(a - b) <= (tolerance or 1e-10), tostring(a) .. " differs from " .. tostring(b))
end
local function bar(i, o, h, l, c, day)
	return { t = 100000 + i * 300, label = "bar " .. i, day = day or "2024-01-02", o = o, h = h, l = l, c = c, v = 1000 }
end
local bull = { fast = 0.8, medium = 0.4, slow = 0.1, velocity = 0.1, energy = 0.1, agreement = 1 }
local bear = { fast = -0.8, medium = -0.4, slow = 0.1, velocity = -0.1, energy = 0.1, agreement = -1 }
local function feature(reset, efficiency)
	return { drive = 0.7, volatility = 0.01, volumeRatio = 1, ready = true, reset = reset or false, efficiency = efficiency or 1 }
end
local function make(extra)
	local config = { feeBps = 0, slippageBps = 0, stopVol = 2, targetVol = 3, minStopFraction = 0, maxHoldBars = 24 }
	for k, v in extra or {} do config[k] = v end
	return Core.new(config)
end
local function step(core, i, o, h, l, c, physical, f)
	return core:step(bar(i, o, h, l, c), f or feature(), physical or bull)
end

test("completed-bar BUY enters at next open without duplicate positions", function()
	local core = make()
	local first = step(core, 1, 100, 101, 99, 100)
	assert(first.signal == "BUY" and not first.position and #first.executions == 0)
	local second = step(core, 2, 101, 102, 100, 101)
	assert(second.position and #second.executions == 1 and second.executions[1].side == "BUY")
	near(second.executions[1].price, 101)
	local third = step(core, 3, 101, 102, 100, 101)
	assert(third.signal == "HOLD" and #third.executions == 0)
	assert(#core:result().trades == 0)
end)

test("costs charge adverse slippage and fees on both executed sides", function()
	local core = make({ feeBps = 10, slippageBps = 10 })
	step(core, 1, 100, 100.5, 99.5, 100)
	step(core, 2, 100, 100.5, 99.5, 100, bear)
	step(core, 3, 100, 100.5, 99.5, 100, bear)
	local result = core:result()
	local trade = result.trades[1]
	near(trade.entryPrice, 100.1)
	near(trade.exitPrice, 99.9)
	near(result.summary.netReturn, -0.003992011984019883, 1e-12)
	assert(trade.entryFee > 0 and trade.exitFee > 0 and trade.netReturn < 0)
	near(result.summary.totalFees, trade.totalFees)
end)

test("signal volatility fixes barriers despite later volatility changes", function()
	local core = make()
	step(core, 1, 100, 101, 99, 100)
	local f = feature(); f.volatility = 0.5
	step(core, 2, 100, 101, 99, 100, bull, f)
	step(core, 3, 100, 100.5, 97, 99, bear, f)
	local trade = core:result().trades[1]
	near(trade.exitRawPrice, 98)
	assert(trade.reason == "stop")
end)

test("stop gap exits at worse opening price", function()
	local core = make()
	step(core, 1, 100, 101, 99, 100)
	step(core, 2, 100, 101, 99, 100)
	step(core, 3, 95, 97, 94, 96)
	local trade = core:result().trades[1]
	near(trade.exitRawPrice, 95)
	assert(trade.reason == "stop-gap")
	assert(trade.exitAvailableT == trade.exitT + 300)
end)

test("both barriers use stop first and record ambiguity", function()
	local core = make()
	step(core, 1, 100, 101, 99, 100)
	step(core, 2, 100, 104, 97, 101)
	local result = core:result()
	near(result.trades[1].exitRawPrice, 98)
	assert(result.trades[1].ambiguous and result.summary.ambiguousBars == 1)
	assert(not result.rows[2].position)
end)

test("target executes at barrier rather than bar high", function()
	local core = make()
	step(core, 1, 100, 101, 99, 100)
	step(core, 2, 100, 106, 99, 105)
	near(core:result().trades[1].exitRawPrice, 103)
end)

test("chop blocks entries but never suppresses an exit", function()
	local core = make()
	assert(step(core, 1, 100, 101, 99, 100, bull, feature(false, 0.01)).signal == "HOLD")
	step(core, 2, 100, 101, 99, 100)
	assert(step(core, 3, 100, 101, 99, 100, bear, feature(false, 0.01)).signal == "SELL")
	step(core, 4, 101, 102, 100, 101, bear)
	assert(#core:result().trades == 1)
end)

test("holding timeout signals at close and exits next open", function()
	local core = make({ maxHoldBars = 2 })
	step(core, 1, 100, 101, 99, 100)
	step(core, 2, 100, 101, 99, 100)
	local row = step(core, 3, 100, 101, 99, 100)
	assert(row.signal == "SELL" and row.reason == "holding timeout")
	step(core, 4, 101, 102, 100, 101)
	near(core:result().trades[1].exitRawPrice, 101)
end)

test("reset cancels pending BUY and closes existing exposure at observed open", function()
	local core = make()
	step(core, 1, 100, 101, 99, 100)
	local reset = feature(true); reset.ready = false; reset.resetReason = "missing-bar"; reset.gapSeconds = 600
	local canceled = step(core, 3, 105, 106, 104, 105, bull, reset)
	assert(not canceled.position and #canceled.executions == 0)
	step(core, 4, 105, 106, 104, 105)
	step(core, 5, 105, 106, 104, 105)
	local closed = step(core, 8, 110, 111, 109, 110, bull, reset)
	assert(not closed.position and #closed.executions == 1)
	assert(core:result().trades[1].reason == "missing-bar reset")
	near(core:result().trades[1].exitRawPrice, 110)
end)

test("final open exposure is marked without inventing an executed sale", function()
	local core = make()
	step(core, 1, 100, 101, 99, 100)
	step(core, 2, 100, 102, 99, 101)
	local result = core:result()
	assert(result.summary.openPosition and result.summary.tradeCount == 0)
	near(result.summary.netReturn, 0.01)
	assert(result.summary.openPositionDetails.markPrice == 101)
	near(result.summary.exposure, 0.5)
end)

test("feature warmup and gaps restart causal estimates", function()
	local core = Core.new({ minWarmup = 3 })
	assert(not core:features(bar(1, 100, 101, 99, 100)).ready)
	assert(not core:features(bar(2, 100, 102, 99, 101)).ready)
	assert(core:features(bar(3, 101, 103, 100, 102)).ready)
	local gap = core:features(bar(5, 120, 121, 119, 120))
	assert(gap.reset and not gap.ready and gap.warmupBars == 1 and gap.resetReason == "missing-bar")
	near(gap.returnValue, 0)
	local session = core:features(bar(6, 120, 121, 119, 120, "2024-01-03"))
	assert(session.reset and session.resetReason == "session")
end)

test("volatility responds to return scale and drive stays finite", function()
	local low, high = Core.new(), Core.new()
	local p, q, fl, fh = 100, 100, nil, nil
	for i = 1, 30 do
		local sign = if i % 3 == 0 then -1 else 1
		p *= math.exp(sign * 0.001); q *= math.exp(sign * 0.002)
		fl = low:features(bar(i, p, p * 1.001, p * 0.999, p))
		fh = high:features(bar(i, q, q * 1.001, q * 0.999, q))
	end
	near(fh.volatility / fl.volatility, 2, 1e-9)
	assert(fl.drive == fl.drive and math.abs(fl.drive) <= 2)
end)

test("future rows cannot revise past features decisions or equity", function()
	local function run(count)
		local core, numeric = Core.new({ minWarmup = 3 }), Core.numeric()
		for i = 1, count do
			local c = 100 + i * 0.15 + math.sin(i) * 0.03
			local b = bar(i, c - 0.1, c + 0.04, c - 0.14, c)
			local f = core:features(b)
			core:step(b, f, numeric:step(f.drive, f.reset))
		end
		return core:result()
	end
	local prefix, full = run(25), run(50)
	for i, row in prefix.rows do
		local other = full.rows[i]
		near(row.feature.volatility, other.feature.volatility)
		near(row.fast, other.fast); near(row.equity, other.equity)
		assert(row.signal == other.signal and row.reason == other.reason and row.position == other.position)
	end
end)

test("numeric response is causal directional and resets", function()
	local n = Core.numeric()
	local first = n:step(1, true)
	assert(first.fast > first.medium and first.medium > first.slow and first.slow > 0)
	for _ = 1, 10 do n:step(-1, false) end
	local repeated = n:step(1, true)
	near(first.fast, repeated.fast); near(first.slow, repeated.slow)
	assert(repeated.agreement == 1 and repeated.energy >= 0)
end)

test("invalid market and physical data fail explicitly", function()
	local core = make()
	assert(not pcall(function() core:features(bar(1, 100, 99, 101, 100)) end))
	local bad = table.clone(bull); bad.fast = 0 / 0
	assert(not pcall(function() step(core, 1, 100, 101, 99, 100, bad) end))
end)

test("meta gate blocks in-sample rows and honors frozen scores", function()
	local model = { cutoff = 100900, means = table.create(9, 0), scales = table.create(9, 1), weights = table.create(10, 0), sampleCount = 30 }
	model.weights[1] = -5
	local core = make({ metaModel = model })
	assert(step(core, 1, 100, 101, 99, 100).signal == "HOLD")
	assert(step(core, 2, 100, 101, 99, 100).signal == "HOLD")
	assert(step(core, 3, 100, 101, 99, 100).signal == "HOLD")
	local rejected = step(core, 4, 100, 101, 99, 100)
	assert(rejected.signal == "HOLD" and rejected.metaScore < 0.55)
	model.weights[1] = 5
	local acceptedCore = make({ metaModel = model })
	local accepted = step(acceptedCore, 4, 100, 101, 99, 100)
	assert(accepted.signal == "BUY" and accepted.metaScore > 0.55)
end)

print("Core: " .. passed .. " behavioral tests passed")
