-- Plan Task 4: Cholesky solver, ridge readout and validation selection (plan Section 5).
-- Expected values come from the plan's exact fixtures, hand-derived closed forms, or the independent Node reference
-- lab/fixtures/dev/ridge-reference.mjs (two-pass + Gauss-Jordan); never from the module under test.
local Test = require("./Test")
local Config = require("../src/Config")
local Cholesky = require("../src/Model/Cholesky")
local Ridge = require("../src/Model/Ridge")
local Selection = require("../src/Model/Selection")
local Reference = require("../fixtures/ridge_reference")
local MiniJson = require("../fixtures/MiniJson")
local Json = require("../src/Util/Json")

-- Deterministic test PRNG (LCG mod 2^32; products stay below 2^53 so the arithmetic is exact).
local function lcg(seed: number)
	local state = seed
	return function(): number
		state = (1664525 * state + 1013904223) % 4294967296
		return state / 4294967296
	end
end

local function referenceCase(name: string): any
	for _, c in Reference.cases do
		if c.name == name then
			return c
		end
	end
	error("no reference case " .. name)
end

local function maxAbsDiff(a: { number }, b: { number }): number
	assert(#a == #b, "length mismatch")
	local m = 0
	for i = 1, #a do
		m = math.max(m, math.abs(a[i] - b[i]))
	end
	return m
end

--------------------------------------------------------------------------------------------------
local chol = Test.suite("Cholesky")

Test.case(chol, "exact 2x2 plan fixture", function()
	local A = { { 4, 1 }, { 1, 3 } }
	local B = { { 1, 0 }, { 2, 1 } }
	local W = Cholesky.solve(A, B)
	Test.near(W[1][1], 1 / 11, 1e-12, "W11")
	Test.near(W[2][1], 7 / 11, 1e-12, "W21")
	Test.near(W[1][2], -1 / 11, 1e-12, "W12")
	Test.near(W[2][2], 4 / 11, 1e-12, "W22")
end)

Test.case(chol, "factor is lower-triangular, reproduces A and is reusable", function()
	local A = { { 4, 1 }, { 1, 3 } }
	local L = Cholesky.factor(A)
	Test.eq(L[1][1], 2, "L11")
	Test.eq(L[2][1], 0.5, "L21")
	Test.near(L[2][2], math.sqrt(2.75), 1e-15, "L22")
	Test.eq(L[1][2], nil, "upper triangle is not stored")
	Test.deepEq(A, { { 4, 1 }, { 1, 3 } }, "A must not be modified")
	local W1 = Cholesky.solveFactored(L, { { 1, 0 }, { 2, 1 } })
	local W2 = Cholesky.solve(A, { { 1, 0 }, { 2, 1 } })
	Test.deepEq(W1, W2, "solveFactored and solve agree exactly")
end)

Test.case(chol, "singular and indefinite matrices fail with an explicit pivot error", function()
	Test.throws(function()
		Cholesky.solve({ { 1, 1 }, { 1, 1 } }, { { 1 }, { 1 } })
	end, "Cholesky: non-positive pivot")
	Test.throws(function()
		Cholesky.factor({ { 1, 2 }, { 2, 1 } })
	end, "Cholesky: non-positive pivot")
	Test.throws(function()
		Cholesky.factor({ { 0, 0 }, { 0, 1 } })
	end, "Cholesky: non-positive pivot")
end)

Test.case(chol, "rejects non-finite, asymmetric, non-square and mismatched inputs", function()
	Test.throws(function()
		Cholesky.factor({ { 4, 0 / 0 }, { 0 / 0, 3 } })
	end, "Cholesky: non-finite")
	Test.throws(function()
		Cholesky.factor({ { 4, math.huge }, { math.huge, 3 } })
	end, "Cholesky: non-finite")
	Test.throws(function()
		Cholesky.factor({ { 4, 1 }, { 1.5, 3 } })
	end, "Cholesky: matrix is not symmetric")
	Test.throws(function()
		Cholesky.factor({ { 4, 1 } })
	end, "Cholesky: matrix must be square")
	Test.throws(function()
		Cholesky.solve({ { 4, 1 }, { 1, 3 } }, { { 1 } })
	end, "Cholesky: right-hand side")
	Test.throws(function()
		Cholesky.solve({ { 4, 1 }, { 1, 3 } }, { { 1 }, { 0 / 0 } })
	end, "Cholesky: non-finite")
end)

Test.case(chol, "pivot test is relative to each column's own diagonal (badly scaled but well-conditioned SPD)", function()
	-- Cholesky is invariant to diagonal scaling, and the rounding error of pivot j is of order n*eps*A[j][j], not
	-- n*eps*max(diag). A max-diagonal threshold falsely calls these positive pivots "non-positive".
	local W = Cholesky.solve({ { 1e20, 0 }, { 0, 1 } }, { { 1e20 }, { 2 } })
	Test.eq(W[1][1], 1, "diagonal x1")
	Test.eq(W[2][1], 2, "diagonal x2")
	-- Scaled correlation 1e8/sqrt(1e17) = 0.316; exact solution {1, 2}; B = A x is exactly representable.
	-- x2 is attainable only to about eps * |A21 x1| / A22 = 2.2e-8 (1e8 * x1 cancels against 1e8 + 2 in any backward-stable
	-- solve), so it gets a 1e-7 tolerance; x1 and the relative residual are at rounding level.
	local A = { { 1e17, 1e8 }, { 1e8, 1 } }
	local B = { { 1e17 + 2e8 }, { 1e8 + 2 } }
	local V = Cholesky.solve(A, B)
	Test.near(V[1][1], 1, 1e-14, "coupled x1")
	Test.near(V[2][1], 2, 1e-7, "coupled x2")
	Test.truthy(Cholesky.relativeResidual(A, V, B) <= 1e-14, "backward-stable residual")
	-- Singular in the scaled sense is still rejected: [[1e20, 1e10], [1e10, 1]] has scaled correlation exactly 1.
	Test.throws(function()
		Cholesky.factor({ { 1e20, 1e10 }, { 1e10, 1 } })
	end, "Cholesky: non-positive pivot")
end)

Test.case(chol, "3x3 system with a known solution and a tiny residual", function()
	-- A = M^T M + I is symmetric positive definite; B = A X for a chosen X.
	local M = { { 2, -1, 0 }, { 1, 3, 1 }, { 0, 1, 4 } }
	local A = {}
	for i = 1, 3 do
		A[i] = {}
		for j = 1, 3 do
			local s = if i == j then 1 else 0
			for k = 1, 3 do
				s += M[k][i] * M[k][j]
			end
			A[i][j] = s
		end
	end
	local X = { { 1, -2 }, { 0.5, 3 }, { -1.25, 0 } }
	local B = {}
	for i = 1, 3 do
		B[i] = {}
		for h = 1, 2 do
			local s = 0
			for k = 1, 3 do
				s += A[i][k] * X[k][h]
			end
			B[i][h] = s
		end
	end
	local W = Cholesky.solve(A, B)
	for i = 1, 3 do
		for h = 1, 2 do
			Test.near(W[i][h], X[i][h], 1e-12, "W" .. i .. h)
		end
	end
	Test.truthy(Cholesky.relativeResidual(A, W, B) <= 1e-14, "residual of a well-conditioned solve")
	-- A deliberately wrong solution has a large residual.
	local wrong = { { 1, -2 }, { 0.5, 3 }, { -1.25, 1e-6 } }
	Test.truthy(Cholesky.relativeResidual(A, wrong, B) > 1e-8, "residual detects a wrong solution")
end)

--------------------------------------------------------------------------------------------------
local ridge = Test.suite("Ridge")

Test.case(ridge, "plan regression fixture: two heads and intercept, lambda=0", function()
	local model = Ridge.fit({ { -1 }, { 0 }, { 1 } }, { { -1, 3 }, { 1, 1 }, { 3, -1 } }, 0)
	local p = Ridge.predict(model, { 2 })
	Test.eq(#p, 2, "two heads")
	Test.near(p[1], 5, 1e-10, "SPY head")
	Test.near(p[2], -3, 1e-10, "QQQ head")
	Test.eq(model.lambda, 0)
	Test.eq(model.inputDimension, 1)
end)

Test.case(ridge, "known relationship: lambda=0 recovers intercept and slopes on full-rank data", function()
	local X = { { 0, 1 }, { 1, 0 }, { 2, 3 }, { -1, 2 }, { 3, -2 }, { 0.5, 0.25 } }
	local Y = {}
	for i, x in X do
		Y[i] = { 2 + 3 * x[1] - x[2], -1 + 0.5 * x[2] }
	end
	local model = Ridge.fit(X, Y, 0)
	local p = Ridge.predict(model, { 10, -7 })
	Test.near(p[1], 39, 1e-10, "2 + 3*10 + 7")
	Test.near(p[2], -4.5, 1e-10, "-1 + 0.5*(-7)")
	-- Original-unit slopes are beta / scale; intercept is targetMean - sum(slope * mean).
	local expectedSlopes = { { 3, 0 }, { -1, 0.5 } }
	local expectedIntercepts = { 2, -1 }
	for h = 1, 2 do
		local intercept = model.targetMeans[h]
		for a = 1, #model.retained do
			local slope = model.beta[a][h] / model.scales[a]
			Test.near(slope, expectedSlopes[a][h], 1e-12, "slope " .. a .. "," .. h)
			intercept -= slope * model.means[a]
		end
		Test.near(intercept, expectedIntercepts[h], 1e-12, "intercept " .. h)
	end
end)

Test.case(ridge, "independent reference fixture: internals and predictions", function()
	for _, case in Reference.cases do
		for _, fit in case.fits do
			local model = Ridge.fit(case.X, case.Y, fit.lambda)
			local label = case.name .. " lambda=" .. tostring(fit.lambda)
			Test.deepEq(model.retained, fit.retained, label .. " retained")
			Test.truthy(maxAbsDiff(model.means, fit.means) <= 1e-14, label .. " means")
			Test.truthy(maxAbsDiff(model.scales, fit.scales) <= 1e-14, label .. " scales")
			Test.truthy(maxAbsDiff(model.targetMeans, fit.targetMeans) <= 1e-14, label .. " target means")
			for a = 1, #fit.beta do
				Test.truthy(maxAbsDiff(model.beta[a], fit.beta[a]) <= 1e-10, label .. " beta row " .. a)
			end
			for q, query in case.queries do
				local p = Ridge.predict(model, query)
				Test.truthy(maxAbsDiff(p, fit.predictions[q]) <= 1e-10, label .. " prediction " .. q)
			end
		end
	end
end)

Test.case(ridge, "duplicated feature: singular at lambda=0, solvable with lambda>0", function()
	local case = referenceCase("duplicate")
	Test.throws(function()
		Ridge.fit(case.X, case.Y, 0)
	end, "Cholesky: non-positive pivot")
	for _, fit in case.fits do
		Test.truthy(fit.lambda > 0)
		local model = Ridge.fit(case.X, case.Y, fit.lambda)
		for q, query in case.queries do
			Test.truthy(maxAbsDiff(Ridge.predict(model, query), fit.predictions[q]) <= 1e-10, "duplicate prediction " .. q)
		end
	end
end)

Test.case(ridge, "adding a constant feature does not change predictions", function()
	local case = referenceCase("mixed")
	local Xc = {}
	for i, row in case.X do
		Xc[i] = { row[1], 3.25, row[2], row[3], row[4] }
	end
	for _, lambda in Config.values.lambdas do
		local base = Ridge.fit(case.X, case.Y, lambda)
		local withConst = Ridge.fit(Xc, case.Y, lambda)
		Test.deepEq(withConst.retained, { 1, 4, 5 }, "both constant columns dropped")
		for _, q in case.queries do
			local a = Ridge.predict(base, q)
			local b = Ridge.predict(withConst, { q[1], 1000, q[2], q[3], q[4] })
			Test.eq(b[1], a[1], "head 1 identical")
			Test.eq(b[2], a[2], "head 2 identical")
		end
	end
end)

Test.case(ridge, "constant columns are detected exactly (lag masks of ones, non-representable constants)", function()
	local X = {}
	local Y = {}
	local rnd = lcg(7)
	for i = 1, 50 do
		X[i] = { rnd() - 0.5, 1, 0.1, rnd() }
		Y[i] = { rnd(), rnd() }
	end
	local model, diag = Ridge.fit(X, Y, 0.01)
	Test.deepEq(model.retained, { 1, 4 }, "ones and 0.1 columns dropped")
	Test.deepEq(diag.dropped, { 2, 3 }, "dropped columns reported")
end)

Test.case(ridge, "an all-constant design leaves an intercept-only model predicting the training target mean", function()
	local X = { { 1, 0.1 }, { 1, 0.1 }, { 1, 0.1 } }
	local Y = { { 1, 4 }, { 2, 5 }, { 6, 9 } }
	local model, diag = Ridge.fit(X, Y, 0.1)
	Test.deepEq(model.retained, {})
	Test.deepEq(diag.dropped, { 1, 2 })
	Test.eq(diag.residual, 0)
	Test.deepEq(Ridge.predict(model, { 5, 5 }), { 3, 6 })
	local reloaded = Ridge.deserialize(MiniJson.decode(MiniJson.encode(Ridge.serialize(model))))
	Test.deepEq(Ridge.predict(reloaded, { 5, 5 }), { 3, 6 })
end)

Test.case(ridge, "permuting training rows changes results only within floating-point tolerance", function()
	local case = referenceCase("mixed")
	local order = { 5, 2, 9, 1, 7, 3, 8, 6, 4 }
	local Xp, Yp = {}, {}
	for i, k in order do
		Xp[i] = case.X[k]
		Yp[i] = case.Y[k]
	end
	for _, lambda in { 0, 0.1, 10 } do
		local a = Ridge.fit(case.X, case.Y, lambda)
		local b = Ridge.fit(Xp, Yp, lambda)
		for _, q in case.queries do
			local pa, pb = Ridge.predict(a, q), Ridge.predict(b, q)
			for h = 1, 2 do
				Test.near(pb[h], pa[h], 1e-12 * math.max(1, math.abs(pa[h])), "permuted prediction")
			end
		end
	end
end)

Test.case(ridge, "numerically stable under a large column offset", function()
	-- A naive sum-of-squares accumulation loses about eps*offset^2/var relative accuracy (~1e-6 here) and fails.
	local case = referenceCase("mixed")
	local offset = 1e5
	local Xs = {}
	for i, row in case.X do
		Xs[i] = { row[1] + offset, row[2], row[3], row[4] }
	end
	for _, lambda in { 0, 0.1 } do
		local a = Ridge.fit(case.X, case.Y, lambda)
		local b = Ridge.fit(Xs, case.Y, lambda)
		for _, q in case.queries do
			local pa = Ridge.predict(a, q)
			local pb = Ridge.predict(b, { q[1] + offset, q[2], q[3], q[4] })
			Test.truthy(maxAbsDiff(pa, pb) <= 1e-8, "offset-invariant prediction")
		end
	end
end)

Test.case(ridge, "seven lambdas reuse one streaming accumulation and match fresh fits exactly", function()
	local case = referenceCase("mixed")
	local stats = Ridge.Stats.new(4, 2)
	for i, row in case.X do
		stats:add(row, case.Y[i])
	end
	Test.eq(stats:count(), 9, "row count")
	Test.truthy(#Config.values.lambdas == 7)
	for _, lambda in Config.values.lambdas do
		local fromStats = Ridge.fitFromStats(stats, lambda)
		local direct = Ridge.fit(case.X, case.Y, lambda)
		Test.deepEq(Ridge.serialize(fromStats), Ridge.serialize(direct), "lambda " .. lambda)
	end
	-- Fitting does not consume or alter the accumulator.
	Test.deepEq(Ridge.serialize(Ridge.fitFromStats(stats, 1)), Ridge.serialize(Ridge.fitFromStats(stats, 1)))
	Test.eq(stats:count(), 9)
	local ym = stats:targetMeans()
	Test.near(ym[1], 1.3444444444444446, 1e-15, "target mean")
	local ys = stats:targetStds()
	local s2 = 0
	for _, y in case.Y do
		s2 += (y[2] - ym[2]) ^ 2
	end
	Test.near(ys[2], math.sqrt(s2 / 9), 1e-15, "population target std")
end)

Test.case(ridge, "statistics and fit reject invalid input explicitly", function()
	local stats = Ridge.Stats.new(2, 2)
	Test.throws(function()
		stats:add({ 1 }, { 1, 2 })
	end, "Ridge: row has 1 values")
	Test.throws(function()
		stats:add({ 1, 0 / 0 }, { 1, 2 })
	end, "Ridge: non-finite design value")
	Test.throws(function()
		stats:add({ 1, 2 }, { 1, math.huge })
	end, "Ridge: non-finite target")
	Test.throws(function()
		stats:add({ 1, 2 }, { 1 })
	end, "Ridge: target has 1 values")
	Test.eq(stats:count(), 0, "rejected rows are not counted")
	Test.throws(function()
		Ridge.fitFromStats(stats, 1)
	end, "Ridge: no training rows")
	stats:add({ 1, 2 }, { 0, 0 })
	stats:add({ 2, 1 }, { 1, 1 })
	Test.throws(function()
		Ridge.fitFromStats(stats, -1)
	end, "Ridge: lambda")
	Test.throws(function()
		Ridge.fitFromStats(stats, 0 / 0)
	end, "Ridge: lambda")
	Test.throws(function()
		Ridge.fit({}, {}, 1)
	end, "Ridge: no training rows")
	Test.throws(function()
		Ridge.Stats.new(0, 2)
	end, "Ridge: column count")
end)

Test.case(ridge, "overflowing sufficient statistics are an explicit error, never a silently dropped column or NaN model", function()
	-- Finite inputs near the double range overflow the co-moments to Inf/NaN. A NaN variance compares false against
	-- the 1e-12 threshold, so without a check the column would be dropped as if constant.
	local stats = Ridge.Stats.new(2, 2)
	for i, row in { { 1e308, 0 }, { -1e308, 1 }, { 1e308, 2 }, { 0, 3 } } do
		stats:add(row, { i % 2, 1 })
	end
	Test.throws(function()
		Ridge.fitFromStats(stats, 0.1)
	end, "Ridge: non-finite sufficient statistics")
	-- Overflowing targets with an all-constant design must not freeze a NaN target mean into an intercept-only model.
	local t = Ridge.Stats.new(1, 1)
	for _, y in { 1e308, -1e308, 1e308 } do
		t:add({ 5 }, { y })
	end
	Test.throws(function()
		Ridge.fitFromStats(t, 0.1)
	end, "Ridge: non-finite sufficient statistics")
end)

Test.case(ridge, "near-collinear unregularised design is rejected, never silently re-regularised", function()
	-- Columns differ by 1e-9: the second pivot is at rounding level, below n*eps*max(diag).
	local X, Y = {}, {}
	local rnd = lcg(11)
	for i = 1, 40 do
		local x = rnd()
		X[i] = { x, x + 1e-9 * (rnd() - 0.5) }
		Y[i] = { rnd(), rnd() }
	end
	local ok, err = pcall(Ridge.fit, X, Y, 0)
	Test.falsy(ok, "lambda=0 must be rejected")
	Test.truthy(string.find(tostring(err), "Ridge: candidate rejected (lambda=0)", 1, true), "rejection names the candidate")
	Test.truthy(string.find(tostring(err), "Cholesky: non-positive pivot", 1, true), "rejection gives the numerical cause")
	-- The same design with the smallest production lambda is accepted and reports a small residual.
	local _, diag = Ridge.fit(X, Y, 1e-5)
	Test.truthy(diag.residual <= 1e-8, "residual within tolerance")
end)

Test.case(ridge, "residual gate rejects an inaccurate solution with an explicit error", function()
	local A = { { 4, 1 }, { 1, 3 } }
	local B = { { 1, 0 }, { 2, 1 } }
	local exact = { { 1 / 11, -1 / 11 }, { 7 / 11, 4 / 11 } }
	Test.truthy(Ridge.assertSolution(A, exact, B, 0.1) <= 1e-15, "exact solution passes")
	Test.throws(function()
		Ridge.assertSolution(A, { { 1 / 11, -1 / 11 }, { 7 / 11, 4 / 11 + 1e-7 } }, B, 0.1)
	end, "Ridge: candidate rejected (lambda=0.10000000000000001): relative residual")
	Test.throws(function()
		Ridge.assertSolution(A, { { 0 / 0, 0 }, { 0, 0 } }, B, 0.1)
	end, "non-finite coefficient")
end)

Test.case(ridge, "diagnostics report residual, counts and dropped columns", function()
	local case = referenceCase("mixed")
	local _, diag = Ridge.fit(case.X, case.Y, 0.1)
	Test.truthy(diag.residual <= 1e-8, "relative residual <= 1e-8")
	Test.eq(diag.n, 9)
	Test.eq(diag.retainedCount, 3)
	Test.deepEq(diag.dropped, { 2 })
	Test.truthy(diag.minPivot > 0, "positive pivots")
end)

Test.case(ridge, "predict validates its input and the model is frozen", function()
	local case = referenceCase("mixed")
	local X = table.clone(case.X)
	for i, row in X do
		X[i] = table.clone(row)
	end
	local model = Ridge.fit(X, case.Y, 0.1)
	local before = Ridge.predict(model, case.queries[1])
	X[1][1] = 1000 -- caller mutation after fit
	Test.deepEq(Ridge.predict(model, case.queries[1]), before, "caller mutation cannot change the model")
	Test.truthy(table.isfrozen(model) and table.isfrozen(model.beta) and table.isfrozen(model.beta[1]), "frozen")
	Test.throws(function()
		Ridge.predict(model, { 1, 2, 3 })
	end, "Ridge: row has 3 values")
	Test.throws(function()
		Ridge.predict(model, { 1, 2, 0 / 0, 4 })
	end, "Ridge: non-finite")
end)

Test.case(ridge, "JSON round trip reproduces the model and identical predictions", function()
	for _, case in Reference.cases do
		for _, fit in case.fits do
			local model = Ridge.fit(case.X, case.Y, fit.lambda)
			local text = MiniJson.encode(Ridge.serialize(model))
			local reloaded = Ridge.deserialize(MiniJson.decode(text))
			Test.deepEq(Ridge.serialize(reloaded), Ridge.serialize(model), "serialized form identical")
			for q, query in case.queries do
				local a, b = Ridge.predict(model, query), Ridge.predict(reloaded, query)
				Test.eq(b[1], a[1], "identical head 1")
				Test.eq(b[2], a[2], "identical head 2")
				Test.truthy(maxAbsDiff(b, fit.predictions[q]) <= 1e-10, "still matches the reference")
			end
			Test.truthy(table.isfrozen(reloaded), "deserialized model frozen")
		end
	end
end)

Test.case(ridge, "round trip through the production Util/Json serializer (model.json path)", function()
	-- MiniJson is a test helper; this proves the serializer that actually writes model.json preserves every model.
	for _, case in Reference.cases do
		for _, fit in case.fits do
			local model = Ridge.fit(case.X, case.Y, fit.lambda)
			local text = Json.encode(Ridge.serialize(model))
			local reloaded = Ridge.deserialize(Json.decode(text))
			Test.eq(Json.encode(Ridge.serialize(reloaded)), text, "byte-identical re-encoding")
			for q, query in case.queries do
				local a, b = Ridge.predict(model, query), Ridge.predict(reloaded, query)
				Test.eq(b[1], a[1], "identical head 1")
				Test.eq(b[2], a[2], "identical head 2")
				Test.truthy(maxAbsDiff(b, fit.predictions[q]) <= 1e-10, "still matches the independent reference")
			end
		end
	end
	local interceptOnly = Ridge.fit({ { 1 }, { 1 } }, { { 1, 2 }, { 3, 4 } }, 0.1)
	local back = Ridge.deserialize(Json.decode(Json.encode(Ridge.serialize(interceptOnly))))
	Test.deepEq(Ridge.predict(back, { 7 }), { 2, 3 }, "intercept-only model survives an empty retained set")
end)

Test.case(ridge, "deserialize rejects malformed artifacts", function()
	local case = referenceCase("mixed")
	local good = Ridge.serialize(Ridge.fit(case.X, case.Y, 0.1))
	local function mutated(f: (any) -> ()): any
		local t = MiniJson.decode(MiniJson.encode(good))
		f(t)
		return t
	end
	Test.throws(function()
		Ridge.deserialize(mutated(function(t)
			t.retained[1] = 9
		end))
	end, "Ridge: artifact")
	Test.throws(function()
		Ridge.deserialize(mutated(function(t)
			t.scales[2] = 0
		end))
	end, "Ridge: artifact")
	Test.throws(function()
		Ridge.deserialize(mutated(function(t)
			table.remove(t.beta)
		end))
	end, "Ridge: artifact")
	Test.throws(function()
		Ridge.deserialize(mutated(function(t)
			t.beta[1][1] = 0 / 0
		end))
	end, "Ridge: artifact")
	Test.throws(function()
		Ridge.deserialize(mutated(function(t)
			t.format = "something-else"
		end))
	end, "Ridge: artifact")
end)

Test.case(ridge, "frozen constants agree with config", function()
	Test.eq(Ridge.CONSTANT_STD_THRESHOLD, Config.values.scaler.constantStdThreshold, "std threshold")
	Test.eq(Ridge.RESIDUAL_TOLERANCE, 1e-8, "plan residual tolerance")
	Test.eq(Selection.TIE_TOLERANCE, Config.values.selection.tieTolerance, "tie tolerance")
end)

--------------------------------------------------------------------------------------------------
local sel = Test.suite("Selection")

local function rmse(model: any, X: { { number } }, Y: { { number } }): { number }
	local s = { 0, 0 }
	for i, row in X do
		local p = Ridge.predict(model, row)
		for h = 1, 2 do
			s[h] += (p[h] - Y[i][h]) ^ 2
		end
	end
	return { math.sqrt(s[1] / #X), math.sqrt(s[2] / #X) }
end

Test.case(sel, "validation, not training error, chooses the setting", function()
	-- 20 mostly irrelevant columns and few training rows: the smallest lambda fits training best but overfits.
	local rnd = lcg(20261004)
	local function noise(): number
		local s = 0
		for _ = 1, 12 do
			s += rnd()
		end
		return s - 6
	end
	local function sample(n: number): ({ { number } }, { { number } })
		local X, Y = {}, {}
		for i = 1, n do
			local row = {}
			for j = 1, 20 do
				row[j] = noise()
			end
			X[i] = row
			Y[i] = { 0.6 * row[1] + noise(), -0.4 * row[2] + noise() }
		end
		return X, Y
	end
	local Xt, Yt = sample(40)
	local Xv, Yv = sample(400)
	local stats = Ridge.Stats.new(20, 2)
	for i, row in Xt do
		stats:add(row, Yt[i])
	end
	local std = stats:targetStds()
	local candidates = {}
	local bestTrain, bestTrainLambda = math.huge, nil
	local bestVal, bestValLambda = math.huge, nil
	for _, lambda in Config.values.lambdas do
		local model = Ridge.fitFromStats(stats, lambda)
		local tr = rmse(model, Xt, Yt)
		local va = rmse(model, Xv, Yv)
		local trainScore = (tr[1] / std[1] + tr[2] / std[2]) / 2
		local valScore = (va[1] / std[1] + va[2] / std[2]) / 2
		if trainScore < bestTrain then
			bestTrain, bestTrainLambda = trainScore, lambda
		end
		if valScore < bestVal then
			bestVal, bestValLambda = valScore, lambda
		end
		table.insert(candidates, {
			profileId = "O14",
			family = "RAW-RIDGE",
			config = "L1",
			lag = 1,
			lambda = lambda,
			trainingRmse = tr, -- present but must be ignored by selection
			validationRmse = va,
		})
	end
	Test.eq(bestTrainLambda, Config.values.lambdas[1], "training error prefers the smallest penalty")
	Test.truthy(bestValLambda ~= bestTrainLambda, "fixture: validation prefers a different lambda")
	local ranked = Selection.rank(candidates, std)
	Test.eq(#ranked, 7)
	Test.eq(ranked[1].lambda, bestValLambda, "validation winner selected")
	Test.eq(ranked[1].status, "ok")
	Test.near(ranked[1].score :: number, bestVal, 1e-15, "score is mean normalized validation RMSE")
	Test.eq(Selection.best(ranked), ranked[1])
	for i = 2, #ranked do
		Test.truthy((ranked[i].score :: number) >= (ranked[i - 1].score :: number) - 1e-12, "ranked by score")
	end
end)

Test.case(sel, "score is the mean over symbols of validation RMSE / training target std", function()
	local ranked = Selection.rank({
		{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 0.02, 0.03 } },
	}, { 0.04, 0.05 })
	Test.near(ranked[1].score :: number, (0.5 + 0.6) / 2, 1e-15)
	Test.eq(ranked[1].profileId, "R50")
	Test.eq(ranked[1].family, "RAW-RIDGE")
	Test.eq(ranked[1].config, "L8")
	Test.eq(ranked[1].lag, 8)
end)

Test.case(sel, "ties within 1e-12 prefer larger lambda, then fewer lags", function()
	local function c(config: string, lag: number, lambda: number, r1: number)
		return { profileId = "R50", family = "RAW-RIDGE", config = config, lag = lag, lambda = lambda, validationRmse = { r1, 0.5 } }
	end
	local ranked = Selection.rank({
		c("L4", 4, 0.1, 0.5 - 4e-13), -- better by less than the tolerance: still a tie
		c("L8", 8, 1, 0.5),
		c("L4", 4, 1, 0.5),
		c("L1", 1, 10, 0.5 + 4e-12), -- worse by more than the tolerance: not a tie
	}, { 1, 1 })
	local order = {}
	for i, r in ranked do
		order[i] = r.config .. "@" .. tostring(r.lambda)
	end
	Test.deepEq(order, { "L4@1", "L8@1", "L4@0.1", "L1@10" })
end)

Test.case(sel, "ties between physical presets prefer the lower preset id", function()
	local function c(preset: string, lambda: number)
		return { profileId = "R50", family = "RAW+PHYSICS", config = preset, preset = preset, lambda = lambda, validationRmse = { 0.3, 0.4 } }
	end
	local ranked = Selection.rank({ c("P3", 1), c("P1", 1), c("P2", 1), c("P1", 0.1) }, { 1, 2 })
	local order = {}
	for i, r in ranked do
		order[i] = r.config .. "@" .. tostring(r.lambda)
	end
	Test.deepEq(order, { "P1@1", "P2@1", "P3@1", "P1@0.1" })
end)

Test.case(sel, "zero or non-finite training target variance is rejected", function()
	local cands = { { profileId = "O14", family = "RAW-RIDGE", config = "L1", lag = 1, lambda = 1, validationRmse = { 1, 1 } } }
	Test.throws(function()
		Selection.rank(cands, { 0, 1 })
	end, "Selection: zero training target variance")
	Test.throws(function()
		Selection.rank(cands, { 1, 0 / 0 })
	end, "Selection: training target std")
	Test.throws(function()
		Selection.rank(cands, { 1 })
	end, "validationRmse must have 1 values")
end)

Test.case(sel, "failed candidates are kept with their status, after every ok candidate", function()
	local ranked = Selection.rank({
		{ profileId = "R50", family = "RAW+PHYSICS", config = "P1", preset = "P1", lambda = 1, status = "rejected:cholesky_non_positive_pivot" },
		{ profileId = "R50", family = "RAW+PHYSICS", config = "P2", preset = "P2", lambda = 1, validationRmse = { 0 / 0, 1 } },
		{ profileId = "R50", family = "RAW+PHYSICS", config = "P3", preset = "P3", lambda = 1, validationRmse = { 1, 1 } },
		{ profileId = "R50", family = "RAW+PHYSICS", config = "P1", preset = "P1", lambda = 10, status = "mechanical_saturation" },
	}, { 1, 1 })
	Test.eq(#ranked, 4, "every candidate kept")
	Test.eq(ranked[1].config, "P3")
	Test.eq(ranked[1].status, "ok")
	Test.eq(ranked[2].status, "rejected:cholesky_non_positive_pivot")
	Test.eq(ranked[2].score, nil, "failed candidates have no score")
	Test.eq(ranked[3].status, "rejected:non_finite_validation_rmse")
	Test.eq(ranked[4].status, "rejected:mechanical_saturation")
	Test.eq(Selection.best(ranked), ranked[1])
	Test.eq(Selection.best(Selection.rank({ ranked[2] :: any }, { 1, 1 })), nil, "no ok candidate -> nil")
end)

Test.case(sel, "unlabelled or duplicated candidates are errors (the declared budget must stay exact)", function()
	-- Without labels the one-family/one-profile guard compares nil with nil and passes; a duplicated setting silently
	-- inflates the declared 21/21/7 candidate budget.
	Test.throws(function()
		Selection.rank({ { config = "L8", lag = 8, lambda = 1, validationRmse = { 1, 1 } } :: any }, { 1, 1 })
	end, "Selection: candidate 1 needs a profileId and a family")
	Test.throws(function()
		Selection.rank({
			{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 1, 1 } },
			{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 2, 2 } },
		}, { 1, 1 })
	end, "Selection: duplicate candidate")
	-- The same config at a different lambda, and a failed duplicate of nothing, are fine.
	local ranked = Selection.rank({
		{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 1, 1 } },
		{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 10, validationRmse = { 1, 1 } },
	}, { 1, 1 })
	Test.eq(#ranked, 2)
end)

Test.case(sel, "candidates from different profiles or families cannot be ranked together", function()
	Test.throws(function()
		Selection.rank({
			{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 1, 1 } },
			{ profileId = "R50", family = "RAW+PHYSICS", config = "P2", preset = "P2", lambda = 1, validationRmse = { 1, 1 } },
		}, { 1, 1 })
	end, "Selection: mixed")
	Test.throws(function()
		Selection.rank({
			{ profileId = "R50", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 1, 1 } },
			{ profileId = "O14", family = "RAW-RIDGE", config = "L8", lag = 8, lambda = 1, validationRmse = { 1, 1 } },
		}, { 1, 1 })
	end, "Selection: mixed")
end)

return { chol, ridge, sel }
