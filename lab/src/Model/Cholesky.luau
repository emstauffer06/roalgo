--!strict
-- Cholesky factorisation A = L L^T and triangular solves for symmetric positive definite systems
-- (plan Section 5, "Ridge regression"). No matrix inversion is ever formed.
--
-- Matrices are row arrays: A[i][j]. The factor L is stored as a jagged lower triangle: L[i] has exactly i entries.
-- A right-hand side B is n x m (one column per output head), so one factorisation serves every head.
--
-- Checks (plan: "finite entries, symmetry, positive pivots"):
--   * every entry finite;
--   * |A[i][j] - A[j][i]| <= 1e-12 * max(1, |A[i][j]|, |A[j][i]|);
--   * every pivot d_j = A[j][j] - sum_k L[j][k]^2 must exceed n * eps * |A[j][j]|. Each subtracted square is at most
--     about A[j][j], so the rounding error of d_j is of order n * eps * A[j][j]; a pivot at or below that bound is
--     indistinguishable from zero and is reported as a non-positive pivot rather than producing a meaningless
--     solution. The bound is per column (not max_i A[i][i]) because Cholesky is invariant to diagonal scaling: a
--     max-diagonal bound falsely rejected well-conditioned but badly scaled matrices such as diag(1e17, 1). For the
--     standardised ridge system every diagonal is 1 + lambda, so the two bounds coincide there.

local Cholesky = {}

local EPSILON = 2.220446049250313e-16 -- 2^-52
Cholesky.SYMMETRY_TOLERANCE = 1e-12
Cholesky.EPSILON = EPSILON

local function isFiniteNumber(x: any): boolean
	return type(x) == "number" and x - x == 0
end

-- Returns L (jagged lower triangle) and the smallest accepted pivot (before the square root).
function Cholesky.factor(A: { { number } }): ({ { number } }, number)
	if type(A) ~= "table" then
		error("Cholesky: matrix must be a table", 2)
	end
	local n = #A
	if n == 0 then
		error("Cholesky: matrix must be square and non-empty", 2)
	end
	for i = 1, n do
		local row = A[i]
		if type(row) ~= "table" or #row ~= n then
			error(string.format("Cholesky: matrix must be square (row %d has %s entries, expected %d)", i,
				if type(row) == "table" then tostring(#row) else "no", n), 2)
		end
		for j = 1, n do
			if not isFiniteNumber(row[j]) then
				error(string.format("Cholesky: non-finite entry at (%d,%d)", i, j), 2)
			end
		end
	end
	for i = 1, n do
		local Ai = A[i]
		for j = 1, i - 1 do
			local a, b = Ai[j], A[j][i]
			if math.abs(a - b) > Cholesky.SYMMETRY_TOLERANCE * math.max(1, math.abs(a), math.abs(b)) then
				error(string.format("Cholesky: matrix is not symmetric at (%d,%d): %.17g vs %.17g", i, j, a, b), 2)
			end
		end
	end
	local L: { { number } } = {}
	local minPivot = math.huge
	for j = 1, n do
		local Aj = A[j]
		local Lj: { number } = table.create(j, 0)
		for k = 1, j - 1 do
			local Lk = L[k]
			local s = Aj[k] -- lower triangle of A
			for m = 1, k - 1 do
				s -= Lj[m] * Lk[m]
			end
			Lj[k] = s / Lk[k]
		end
		local d = Aj[j]
		for m = 1, j - 1 do
			local v = Lj[m]
			d -= v * v
		end
		local tolerance = n * EPSILON * math.abs(Aj[j])
		if not (d > tolerance) then
			error(string.format("Cholesky: non-positive pivot at column %d (pivot %.17g, tolerance %.17g)", j, d, tolerance), 2)
		end
		if d < minPivot then
			minPivot = d
		end
		Lj[j] = math.sqrt(d)
		L[j] = Lj
	end
	return L, minPivot
end

-- Solves L L^T X = B by forward then backward substitution. B is n x m; returns a new n x m matrix.
function Cholesky.solveFactored(L: { { number } }, B: { { number } }): { { number } }
	local n = #L
	if n == 0 then
		error("Cholesky: empty factor", 2)
	end
	for i = 1, n do
		local Li = L[i]
		if type(Li) ~= "table" or #Li ~= i or not isFiniteNumber(Li[i]) or not (Li[i] > 0) then
			error(string.format("Cholesky: invalid factor row %d", i), 2)
		end
	end
	if type(B) ~= "table" or #B ~= n then
		error(string.format("Cholesky: right-hand side must have %d rows", n), 2)
	end
	local m = if type(B[1]) == "table" then #B[1] else 0
	if m < 1 then
		error("Cholesky: right-hand side must have at least one column", 2)
	end
	for i = 1, n do
		local Bi = B[i]
		if type(Bi) ~= "table" or #Bi ~= m then
			error(string.format("Cholesky: right-hand side row %d must have %d columns", i, m), 2)
		end
		for h = 1, m do
			if not isFiniteNumber(Bi[h]) then
				error(string.format("Cholesky: non-finite right-hand side at (%d,%d)", i, h), 2)
			end
		end
	end
	-- Forward: L Y = B.
	local Y: { { number } } = {}
	for i = 1, n do
		local Li = L[i]
		local Bi = B[i]
		local yi: { number } = table.create(m, 0)
		for h = 1, m do
			local s = Bi[h]
			for k = 1, i - 1 do
				s -= Li[k] * Y[k][h]
			end
			yi[h] = s / Li[i]
		end
		Y[i] = yi
	end
	-- Backward: L^T X = Y, where (L^T)[i][k] = L[k][i].
	local X: { { number } } = {}
	for i = n, 1, -1 do
		local yi = Y[i]
		local xi: { number } = table.create(m, 0)
		local diag = L[i][i]
		for h = 1, m do
			local s = yi[h]
			for k = i + 1, n do
				s -= L[k][i] * X[k][h]
			end
			xi[h] = s / diag
		end
		X[i] = xi
	end
	return X
end

function Cholesky.solve(A: { { number } }, B: { { number } }): { { number } }
	local L = Cholesky.factor(A)
	if type(B) ~= "table" or #B ~= #A then
		error(string.format("Cholesky: right-hand side must have %d rows", #A), 2)
	end
	return Cholesky.solveFactored(L, B)
end

-- Plan check: max over output columns h of ||A x_h - b_h||_2 / max(1, ||b_h||_2).
function Cholesky.relativeResidual(A: { { number } }, X: { { number } }, B: { { number } }): number
	local n = #A
	local m = #B[1]
	local worst = 0
	for h = 1, m do
		local rr, bb = 0, 0
		for i = 1, n do
			local Ai = A[i]
			local s = -B[i][h]
			for k = 1, n do
				s += Ai[k] * X[k][h]
			end
			rr += s * s
			bb += B[i][h] * B[i][h]
		end
		local rel = math.sqrt(rr) / math.max(1, math.sqrt(bb))
		if rel ~= rel then
			return math.huge
		end
		worst = math.max(worst, rel)
	end
	return worst
end

return table.freeze(Cholesky)
