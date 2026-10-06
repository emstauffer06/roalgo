--!strict
-- Two-head ridge readout (plan Section 5, "Ridge regression"; Task 4).
--
--   design-column means and population scales fitted on training rows; columns with std < 1e-12 dropped;
--   targets centred; intercept unpenalised;
--   A = Z^T Z / n + lambda I,  B = Z^T (Y - mean Y) / n   on the standardised retained columns Z;
--   beta = CholeskySolve(A, B), one factorisation shared by both heads;
--   prediction = mean(Y) + z(row) * beta;
--   a candidate whose relative residual ||A beta - B|| / max(1, ||B||) exceeds 1e-8 is rejected with an error.
--
-- Sufficient statistics (Ridge.Stats) are accumulated in ONE streaming pass with Welford's co-moment update:
--   d = x - mean_old;  mean += d / n;  C += ((n-1)/n) d d^T   (and the same for the target cross-moments).
-- Why this method: it never stores the n x p design (p up to 536, n up to ~9,100), so seven lambdas reuse one pass;
-- it avoids the catastrophic cancellation of the textbook sum(x x^T) - n m m^T form (that form's relative error grows
-- like eps * (mean/std)^2 and turns an exactly constant column such as a lag mask of ones into a tiny nonzero
-- variance that would survive the 1e-12 threshold); and an exactly constant column produces d == 0 from the second
-- row on, so its co-moment is exactly 0 and it is dropped deterministically. Its error is comparable to a two-pass
-- computation for the bounded, standardised inputs used here (Chan, Golub & LeVeque 1983); the stability test in
-- Ridge.spec exercises a 1e5 column offset.
local Types = require("../Types")
local Cholesky = require("./Cholesky")

export type RidgeModel = Types.RidgeModel

export type FitDiagnostics = {
	n: number,
	lambda: number,
	retainedCount: number,
	dropped: { number },
	residual: number,
	minPivot: number?,
}

local Ridge = {}

Ridge.SCHEMA_VERSION = "mrl-ridge-1"
Ridge.FORMAT = "mrl-ridge-model"
Ridge.CONSTANT_STD_THRESHOLD = 1e-12 -- plan Section 5 / config scaler.constantStdThreshold
Ridge.RESIDUAL_TOLERANCE = 1e-8 -- plan Section 5

local function isFiniteNumber(x: any): boolean
	return type(x) == "number" and x - x == 0
end

local function isPositiveInteger(x: any): boolean
	return type(x) == "number" and x >= 1 and x == math.floor(x) and x - x == 0
end

local function deepFreeze<T>(t: T): T
	if type(t) == "table" and not table.isfrozen(t :: any) then
		for _, v in t :: any do
			deepFreeze(v)
		end
		table.freeze(t :: any)
	end
	return t
end

local function copyArray(a: { number }): { number }
	local out = table.create(#a, 0)
	for i = 1, #a do
		out[i] = a[i]
	end
	return out
end

--------------------------------------------------------------------------------------------------
-- Streaming sufficient statistics.

type StatsData = {
	p: number,
	heads: number,
	n: number,
	mean: { number },
	ymean: { number },
	C: { { number } }, -- C[i][j], j <= i: sum over rows of (x_i - mean_i)(x_j - mean_j)
	Cxy: { { number } }, -- Cxy[h][i]: sum of (x_i - mean_i)(y_h - ymean_h)
	Cyy: { number }, -- Cyy[h]: sum of (y_h - ymean_h)^2
	delta: { number }, -- scratch, length p
	dy: { number }, -- scratch, length heads
}

local Stats = {}
Stats.__index = Stats

export type Stats = typeof(setmetatable({} :: StatsData, Stats))

function Stats.new(p: number, heads: number): Stats
	if not isPositiveInteger(p) then
		error("Ridge: column count must be a positive integer", 2)
	end
	if not isPositiveInteger(heads) then
		error("Ridge: head count must be a positive integer", 2)
	end
	local C: { { number } } = {}
	for i = 1, p do
		C[i] = table.create(i, 0)
	end
	local Cxy: { { number } } = {}
	for h = 1, heads do
		Cxy[h] = table.create(p, 0)
	end
	local data: StatsData = {
		p = p,
		heads = heads,
		n = 0,
		mean = table.create(p, 0),
		ymean = table.create(heads, 0),
		C = C,
		Cxy = Cxy,
		Cyy = table.create(heads, 0),
		delta = table.create(p, 0),
		dy = table.create(heads, 0),
	}
	return setmetatable(data, Stats)
end

-- Adds one training row (p design values) and its targets (one per head). The whole row is validated before any
-- state changes, so a rejected row leaves the accumulator untouched.
function Stats.add(self: Stats, row: { number }, y: { number })
	local p, heads = self.p, self.heads
	if type(row) ~= "table" or #row ~= p then
		error(string.format("Ridge: row has %s values, expected %d", if type(row) == "table" then tostring(#row) else "no", p), 2)
	end
	if type(y) ~= "table" or #y ~= heads then
		error(string.format("Ridge: target has %s values, expected %d", if type(y) == "table" then tostring(#y) else "no", heads), 2)
	end
	for j = 1, p do
		if not isFiniteNumber(row[j]) then
			error(string.format("Ridge: non-finite design value at row %d column %d", self.n + 1, j), 2)
		end
	end
	for h = 1, heads do
		if not isFiniteNumber(y[h]) then
			error(string.format("Ridge: non-finite target at row %d head %d", self.n + 1, h), 2)
		end
	end
	local n = self.n + 1
	self.n = n
	local mean, d = self.mean, self.delta
	for j = 1, p do
		local dj = row[j] - mean[j]
		d[j] = dj
		mean[j] += dj / n
	end
	local ymean, dy = self.ymean, self.dy
	for h = 1, heads do
		local dh = y[h] - ymean[h]
		dy[h] = dh
		ymean[h] += dh / n
	end
	local f = (n - 1) / n
	local C = self.C
	for i = 1, p do
		local di = d[i]
		if di ~= 0 then
			local wi = di * f
			local Ci = C[i]
			for j = 1, i do
				Ci[j] += wi * d[j]
			end
		end
	end
	local Cxy, Cyy = self.Cxy, self.Cyy
	for h = 1, heads do
		local wh = dy[h] * f
		if wh ~= 0 then
			local Ch = Cxy[h]
			for i = 1, p do
				Ch[i] += d[i] * wh
			end
			Cyy[h] += dy[h] * wh
		end
	end
end

function Stats.count(self: Stats): number
	return self.n
end

function Stats.columnMeans(self: Stats): { number }
	return copyArray(self.mean)
end

function Stats.columnStds(self: Stats): { number }
	local out = table.create(self.p, 0)
	for j = 1, self.p do
		out[j] = if self.n > 0 then math.sqrt(self.C[j][j] / self.n) else 0
	end
	return out
end

function Stats.targetMeans(self: Stats): { number }
	return copyArray(self.ymean)
end

-- Population standard deviation of each training target (the selection denominator).
function Stats.targetStds(self: Stats): { number }
	local out = table.create(self.heads, 0)
	for h = 1, self.heads do
		out[h] = if self.n > 0 then math.sqrt(self.Cyy[h] / self.n) else 0
	end
	return out
end

Ridge.Stats = Stats

--------------------------------------------------------------------------------------------------
-- Fitting.

-- Numerical acceptance gate applied to every solved candidate: finite coefficients and
-- relative residual ||A beta - B|| / max(1, ||B||) <= 1e-8 (per head). Returns the residual or raises an explicit
-- rejection; a rejected candidate is never refitted with a different lambda. Exposed so the rejection path is testable.
function Ridge.assertSolution(A: { { number } }, beta: { { number } }, B: { { number } }, lambda: number): number
	for a = 1, #beta do
		for h = 1, #beta[a] do
			if not isFiniteNumber(beta[a][h]) then
				error(string.format("Ridge: candidate rejected (lambda=%.17g): non-finite coefficient", lambda), 0)
			end
		end
	end
	local residual = Cholesky.relativeResidual(A, beta, B)
	if not (residual <= Ridge.RESIDUAL_TOLERANCE) then
		error(string.format("Ridge: candidate rejected (lambda=%.17g): relative residual %.17g exceeds %.17g", lambda,
			residual, Ridge.RESIDUAL_TOLERANCE), 0)
	end
	return residual
end

function Ridge.fitFromStats(stats: Stats, lambda: number): (RidgeModel, FitDiagnostics)
	if getmetatable(stats :: any) ~= Stats then
		error("Ridge: fitFromStats expects a Ridge.Stats accumulator", 2)
	end
	if not isFiniteNumber(lambda) or lambda < 0 then
		error("Ridge: lambda must be a finite number >= 0", 2)
	end
	local n = stats.n
	if n < 1 then
		error("Ridge: no training rows", 2)
	end
	local p, heads = stats.p, stats.heads
	local C = stats.C
	-- Finite rows can still overflow the co-moments near the double range. A NaN variance would compare false against
	-- the constant-column threshold and be dropped as if constant, so non-finite statistics are an explicit error.
	for j = 1, p do
		if not isFiniteNumber(stats.mean[j]) or not isFiniteNumber(C[j][j]) then
			error(string.format("Ridge: non-finite sufficient statistics at design column %d (overflow)", j), 2)
		end
	end
	for h = 1, heads do
		if not isFiniteNumber(stats.ymean[h]) or not isFiniteNumber(stats.Cyy[h]) then
			error(string.format("Ridge: non-finite sufficient statistics at target head %d (overflow)", h), 2)
		end
	end
	local retained, means, scales, dropped = {}, {}, {}, {}
	for j = 1, p do
		local s = math.sqrt(C[j][j] / n)
		if s >= Ridge.CONSTANT_STD_THRESHOLD then
			table.insert(retained, j)
			table.insert(means, stats.mean[j])
			table.insert(scales, s)
		else
			table.insert(dropped, j)
		end
	end
	local r = #retained
	local beta: { { number } } = {}
	local residual = 0
	local minPivot: number? = nil
	if r > 0 then
		local A: { { number } } = {}
		for a = 1, r do
			A[a] = table.create(r, 0)
		end
		for a = 1, r do
			local Ca = C[retained[a]]
			local sa = scales[a]
			local Aa = A[a]
			for b = 1, a do
				local v = Ca[retained[b]] / n / (sa * scales[b])
				Aa[b] = v
				A[b][a] = v
			end
			Aa[a] += lambda
		end
		local B: { { number } } = {}
		for a = 1, r do
			local row = table.create(heads, 0)
			local ja, sa = retained[a], scales[a]
			for h = 1, heads do
				row[h] = stats.Cxy[h][ja] / n / sa
			end
			B[a] = row
		end
		local ok, L, pivot = pcall(Cholesky.factor, A)
		if not ok then
			error(string.format("Ridge: candidate rejected (lambda=%.17g): %s", lambda, tostring(L)), 2)
		end
		minPivot = pivot
		beta = Cholesky.solveFactored(L, B)
		local okCheck, checked = pcall(Ridge.assertSolution, A, beta, B, lambda)
		if not okCheck then
			error(checked, 2)
		end
		residual = checked
	end
	local model: RidgeModel = {
		retained = retained,
		means = means,
		scales = scales,
		targetMeans = copyArray(stats.ymean),
		beta = beta,
		lambda = lambda,
		schemaVersion = Ridge.SCHEMA_VERSION,
		inputDimension = p,
	}
	local diagnostics: FitDiagnostics = {
		n = n,
		lambda = lambda,
		retainedCount = r,
		dropped = dropped,
		residual = residual,
		minPivot = minPivot,
	}
	return deepFreeze(model), deepFreeze(diagnostics)
end

-- Convenience: rows is n x p, Y is n x heads.
function Ridge.fit(rows: { { number } }, Y: { { number } }, lambda: number): (RidgeModel, FitDiagnostics)
	if type(rows) ~= "table" or #rows == 0 then
		error("Ridge: no training rows", 2)
	end
	if type(Y) ~= "table" or #Y ~= #rows then
		error(string.format("Ridge: %d rows but %s target rows", #rows, if type(Y) == "table" then tostring(#Y) else "no"), 2)
	end
	local first, firstY = rows[1], Y[1]
	if type(first) ~= "table" or type(firstY) ~= "table" then
		error("Ridge: rows and targets must be arrays of arrays", 2)
	end
	local stats = Stats.new(#first, #firstY)
	for i = 1, #rows do
		stats:add(rows[i], Y[i])
	end
	return Ridge.fitFromStats(stats, lambda)
end

function Ridge.predict(model: RidgeModel, row: { number }): { number }
	local p = model.inputDimension
	if type(row) ~= "table" or #row ~= p then
		error(string.format("Ridge: row has %s values, expected %d", if type(row) == "table" then tostring(#row) else "no", p), 2)
	end
	for j = 1, p do
		if not isFiniteNumber(row[j]) then
			error(string.format("Ridge: non-finite input value at column %d", j), 2)
		end
	end
	local heads = #model.targetMeans
	local out = table.create(heads, 0)
	for h = 1, heads do
		out[h] = model.targetMeans[h]
	end
	local retained, means, scales, beta = model.retained, model.means, model.scales, model.beta
	for a = 1, #retained do
		local z = (row[retained[a]] - means[a]) / scales[a]
		local b = beta[a]
		for h = 1, heads do
			out[h] += z * b[h]
		end
	end
	return out
end

--------------------------------------------------------------------------------------------------
-- Artifacts. serialize returns a plain JSON-safe table (strings, finite numbers, arrays); written with %.17g (or any
-- shortest round-trip formatter) and parsed back, deserialize reproduces the model bit for bit.

function Ridge.serialize(model: RidgeModel): { [string]: any }
	local beta: { { number } } = {}
	for a = 1, #model.beta do
		beta[a] = copyArray(model.beta[a])
	end
	return {
		format = Ridge.FORMAT,
		schemaVersion = model.schemaVersion,
		inputDimension = model.inputDimension,
		lambda = model.lambda,
		retained = copyArray(model.retained),
		means = copyArray(model.means),
		scales = copyArray(model.scales),
		targetMeans = copyArray(model.targetMeans),
		beta = beta,
	}
end

local function artifactError(reason: string): never
	error("Ridge: artifact " .. reason, 3)
end

local function finiteArray(v: any, name: string, length: number?): { number }
	if type(v) ~= "table" then
		artifactError(name .. " must be an array")
	end
	if length ~= nil and #v ~= length then
		artifactError(string.format("%s must have %d entries, has %d", name, length, #v))
	end
	local out = table.create(#v, 0)
	for i = 1, #v do
		if not isFiniteNumber(v[i]) then
			artifactError(string.format("%s[%d] is not a finite number", name, i))
		end
		out[i] = v[i]
	end
	return out
end

function Ridge.deserialize(t: { [string]: any }): RidgeModel
	if type(t) ~= "table" then
		artifactError("must be a table")
	end
	if t.format ~= Ridge.FORMAT then
		artifactError("format must be " .. Ridge.FORMAT)
	end
	if t.schemaVersion ~= Ridge.SCHEMA_VERSION then
		artifactError("schemaVersion must be " .. Ridge.SCHEMA_VERSION)
	end
	local p = t.inputDimension
	if not isPositiveInteger(p) then
		artifactError("inputDimension must be a positive integer")
	end
	if not isFiniteNumber(t.lambda) or t.lambda < 0 then
		artifactError("lambda must be finite and >= 0")
	end
	local retained = finiteArray(t.retained, "retained", nil)
	local r = #retained
	for a = 1, r do
		local j = retained[a]
		if not isPositiveInteger(j) or j > p or (a > 1 and j <= retained[a - 1]) then
			artifactError("retained must be strictly increasing column indices within inputDimension")
		end
	end
	local means = finiteArray(t.means, "means", r)
	local scales = finiteArray(t.scales, "scales", r)
	for a = 1, r do
		if not (scales[a] >= Ridge.CONSTANT_STD_THRESHOLD) then
			artifactError(string.format("scales[%d] is below the constant-column threshold", a))
		end
	end
	local targetMeans = finiteArray(t.targetMeans, "targetMeans", nil)
	local heads = #targetMeans
	if heads < 1 then
		artifactError("targetMeans must have at least one head")
	end
	if type(t.beta) ~= "table" or #t.beta ~= r then
		artifactError(string.format("beta must have %d rows", r))
	end
	local beta: { { number } } = {}
	for a = 1, r do
		beta[a] = finiteArray(t.beta[a], "beta[" .. a .. "]", heads)
	end
	local model: RidgeModel = {
		retained = retained,
		means = means,
		scales = scales,
		targetMeans = targetMeans,
		beta = beta,
		lambda = t.lambda,
		schemaVersion = t.schemaVersion,
		inputDimension = p,
	}
	return deepFreeze(model)
end

return table.freeze(Ridge)
