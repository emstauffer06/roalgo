-- CLI benchmark for the ridge readout and the Markov fit (plan Section 5: "Benchmark accumulation and Cholesky on the actual required
-- dimension"). Synthetic dense design rows from a fixed LCG; no market data is read. Not a spec.
-- Run from the project root:
--   luau --codegen -O2 lab/fixtures/dev/ModelBench.luau
-- os.clock is used only for timing diagnostics.
local Ridge = require("../../src/Model/Ridge")
local Cholesky = require("../../src/Model/Cholesky")
local Markov = require("../../src/Model/Markov")

local state = 20261004
local function rnd(): number
	state = (1664525 * state + 1013904223) % 4294967296
	return state / 4294967296
end

local LAMBDAS = { 0.00001, 0.0001, 0.001, 0.01, 0.1, 1, 10 }

local function bench(label: string, p: number, n: number)
	-- Dense values in [-4, 4] (the clipped input range), with four constant 1.0 columns standing in for lag masks
	-- that are always 1 at eligible origins.
	local rows, ys = table.create(n), table.create(n)
	for i = 1, n do
		local row = table.create(p, 0)
		for j = 1, p do
			row[j] = if j % 100 == 0 then 1 else (rnd() - 0.5) * 8
		end
		rows[i] = row
		ys[i] = { (rnd() - 0.5) * 0.02, (rnd() - 0.5) * 0.03 }
	end
	local t0 = os.clock()
	local stats = Ridge.Stats.new(p, 2)
	for i = 1, n do
		stats:add(rows[i], ys[i])
	end
	local t1 = os.clock()
	local _, diag = Ridge.fitFromStats(stats, LAMBDAS[1])
	local t2 = os.clock()
	local worst = 0
	for _, lambda in LAMBDAS do
		local _, d = Ridge.fitFromStats(stats, lambda)
		worst = math.max(worst, d.residual)
	end
	local t3 = os.clock()
	-- Factorisation alone, on an SPD matrix of the retained size.
	local r = diag.retainedCount
	local A = table.create(r)
	for a = 1, r do
		A[a] = table.create(r, 0)
	end
	for a = 1, r do
		for b = 1, a do
			local v = (rnd() - 0.5) * 0.01
			A[a][b] = v
			A[b][a] = v
		end
		A[a][a] = 1 + r * 0.01
	end
	local t4 = os.clock()
	Cholesky.factor(A)
	local t5 = os.clock()
	print(string.format(
		"%-22s p=%d n=%d retained=%d | accumulate %.3f s | one fit (A, factor, solve, residual) %.3f s | seven fits %.3f s | factor only %.3f s | max residual %.2e",
		label, p, n, r, t1 - t0, t2 - t1, t3 - t2, t5 - t4, worst))
end

bench("R50 RAW+PHYSICS", 456, 2646)
bench("O14/H14 RAW+PHYSICS", 168, 9103)
bench("R60 RAW+PHYSICS (opt)", 536, 2646)

-- Markov.fit at the H14 training size (31,292 paired bars on 2,012 dates; synthetic 16-hour days, ~15.55 per date).
do
	local pairs = {}
	local segmentId = 0
	local t0 = 1451883600 -- 2016-01-04T05:00:00Z, synthetic
	local spy, qqq = 200, 100
	local day = 0
	while #pairs < 31292 do
		day += 1
		segmentId += 1
		local hours = if day % 20 == 0 then 8 else 16
		for k = 1, hours do
			if #pairs >= 31292 then
				break
			end
			local t = t0 + (day - 1) * 86400 + (k - 1) * 3600
			spy *= math.exp((rnd() - 0.5) * 0.004)
			qqq *= math.exp((rnd() - 0.5) * 0.006)
			local index = #pairs + 1
			pairs[index] = {
				index = index, t = t, decisionTime = t + 3600, dateKey = day, segmentId = segmentId, segmentOffset = k,
				spy = { t, spy, spy, spy, spy, 1, 1, spy }, qqq = { t, qqq, qqq, qqq, qqq, 1, 1, qqq },
			}
		end
	end
	local t1 = os.clock()
	local model = Markov.fit(pairs :: any, { validationStart = 1704085200 })
	local t2 = os.clock()
	print(string.format("Markov.fit             pairs=%d dates=%d state-bearing=%d transitions=%d | fit %.3f s",
		#pairs, day, model.spy.stateBearingCount, model.spy.transitionTotal, t2 - t1))
end
