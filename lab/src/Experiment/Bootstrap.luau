--!strict
-- Paired moving-block bootstrap over ordered observed dates (plan Section 6, "Overlap and uncertainty").
--
-- Input rows come from Evaluator.join: {modelKey, symbol, t, date, split, prediction?, actual}.
-- * The observed dates are the distinct row dates of the compared population, sorted ascending.
-- * One replicate draws ceil(m / L) block starts uniformly from 1..m-L+1 (Prng:nextInteger, in order), lays the
--   blocks of L consecutive observed dates end to end and truncates the list to the original date count m.
-- * A sampled date carries every origin, both assets and every model of that date together; the metric
--   difference metric(modelA) - metric(modelB) is recomputed on each replicate.
-- * lower/upper are the 2.5th/97.5th percentiles of the replicate differences (linear interpolation between
--   order statistics: h = (R-1)p + 1). The estimate is the difference on the original sample.
-- * Comparing a model whose forecast is missing on any compared origin is an error (an incomplete pairing is
--   never silently narrowed). So are a duplicated (model, symbol, t) row, an origin t whose rows carry two
--   different dates, and a compared symbol with no rows. Deterministic for a given seed via Util/Prng.
-- Metrics: "normalizedRmse" (mean over symbols of RMSE_s / targetScales[s]; the plan's selection-style
-- statistic), "normalizedMae", "rmse" and "mae" (pooled over the selected symbols), or a function
-- (rows) -> number evaluated on one model's rows.
local Types = require("../Types")
local Config = require("../Config")
local Prng = require("../Util/Prng")

local Bootstrap = {}

Bootstrap.DEFAULT_BLOCK_LENGTH = Config.values.bootstrap.blockDates :: number
Bootstrap.DEFAULT_REPLICATES = Config.values.bootstrap.replicates :: number

export type CompareOptions = {
	seed: number,
	blockLength: number?,
	replicates: number?,
	metric: any, -- "normalizedRmse" | "normalizedMae" | "rmse" | "mae" | (rows) -> number
	targetScales: { [string]: number }?,
	modelA: string,
	modelB: string,
	symbols: { string }?,
	split: string?,
}

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function fail(msg: string): never
	error("Bootstrap: " .. msg, 0)
end

local function isPositiveInteger(x: any): boolean
	return isFinite(x) and x >= 1 and x == math.floor(x)
end

-- Percentile of an ascending array (type 7 / linear interpolation).
function Bootstrap.percentile(sorted: { number }, p: number): number
	local n = #sorted
	if n == 0 then
		error("Bootstrap: percentile of an empty sample", 2)
	end
	if not isFinite(p) or p < 0 or p > 1 then
		error("Bootstrap: percentile p must be in [0,1]", 2)
	end
	local h = (n - 1) * p + 1
	local lo = math.floor(h)
	if lo >= n then
		return sorted[n]
	end
	local frac = h - lo
	return sorted[lo] + frac * (sorted[lo + 1] - sorted[lo])
end

-- Distinct dates in ascending order and the rows of each date (in input order).
function Bootstrap.orderedDates(rows: { any }): ({ any }, { [any]: { any } })
	local dates = {}
	local rowsByDate: { [any]: { any } } = {}
	local dateType: string? = nil
	for i, row in rows do
		local d = row.date
		local dt = type(d)
		if (dt ~= "string" and dt ~= "number") or (dt == "number" and not isFinite(d)) then
			error("Bootstrap: row " .. i .. " lacks a date (string or number)", 2)
		end
		if dateType == nil then
			dateType = dt
		elseif dateType ~= dt then
			error("Bootstrap: rows mix string and number dates", 2)
		end
		local list = rowsByDate[d]
		if not list then
			list = {}
			rowsByDate[d] = list
			table.insert(dates, d)
		end
		table.insert(list, row)
	end
	table.sort(dates)
	return dates, rowsByDate
end

-- One replicate's date indices: blocks of blockLength consecutive indices, truncated to m.
function Bootstrap.sampleDateIndices(m: number, blockLength: number, prng: Types.Prng): { number }
	if not isPositiveInteger(m) or not isPositiveInteger(blockLength) then
		error("Bootstrap: date count and blockLength must be positive integers", 2)
	end
	if blockLength > m then
		error(string.format("Bootstrap: blockLength %d exceeds the %d observed dates", blockLength, m), 2)
	end
	local out: { number } = {}
	local maxStart = m - blockLength + 1
	while #out < m do
		local start = prng:nextInteger(1, maxStart)
		for j = 0, blockLength - 1 do
			if #out >= m then
				break
			end
			table.insert(out, start + j)
		end
	end
	return out
end

-- Concatenates the rows of the sampled dates (each sampled date contributes all of its rows).
function Bootstrap.expand(dates: { any }, rowsByDate: { [any]: { any } }, indices: { number }): { any }
	local out = {}
	for _, i in indices do
		local d = dates[i]
		if d == nil then
			error("Bootstrap: sampled index " .. tostring(i) .. " out of range", 2)
		end
		for _, row in rowsByDate[d] do
			table.insert(out, row)
		end
	end
	return out
end

local BUILTIN = { normalizedRmse = true, normalizedMae = true, rmse = true, mae = true }

type SymStats = { n: number, sseA: number, saeA: number, sseB: number, saeB: number }

local function metricFromStats(metric: string, perSymbol: { [string]: SymStats }, symbols: { string },
	scales: { [string]: number }): (number, number)
	if metric == "rmse" or metric == "mae" then
		local n, a, b = 0, 0, 0
		for _, s in symbols do
			local st = perSymbol[s]
			n += st.n
			if metric == "rmse" then
				a += st.sseA
				b += st.sseB
			else
				a += st.saeA
				b += st.saeB
			end
		end
		if metric == "rmse" then
			return math.sqrt(a / n), math.sqrt(b / n)
		end
		return a / n, b / n
	end
	local a, b = 0, 0
	for _, s in symbols do
		local st = perSymbol[s]
		if st.n == 0 then
			fail("a resample has no rows for symbol " .. s)
		end
		if metric == "normalizedRmse" then
			a += math.sqrt(st.sseA / st.n) / scales[s]
			b += math.sqrt(st.sseB / st.n) / scales[s]
		else
			a += (st.saeA / st.n) / scales[s]
			b += (st.saeB / st.n) / scales[s]
		end
	end
	return a / #symbols, b / #symbols
end

-- Paired moving-block bootstrap of metric(modelA) - metric(modelB). Returns a frozen Types.Interval.
function Bootstrap.compare(joined: { any }, opts: CompareOptions): Types.Interval
	local ok, result = pcall(function(): Types.Interval
		if type(opts) ~= "table" then
			fail("options table required")
		end
		if opts.seed == nil then
			fail("seed is required")
		end
		local prng = Prng.new(opts.seed)
		local blockLength = opts.blockLength or Bootstrap.DEFAULT_BLOCK_LENGTH
		local replicates = opts.replicates or Bootstrap.DEFAULT_REPLICATES
		if not isPositiveInteger(blockLength) then
			fail("blockLength must be a positive integer")
		end
		if not isPositiveInteger(replicates) then
			fail("replicates must be a positive integer")
		end
		local metric = opts.metric
		local custom = type(metric) == "function"
		if not custom and not BUILTIN[metric] then
			fail("unknown metric " .. tostring(metric))
		end
		local modelA, modelB = opts.modelA, opts.modelB
		if type(modelA) ~= "string" or type(modelB) ~= "string" then
			fail("modelA and modelB model keys are required")
		end

		-- symbols compared
		local symbols: { string } = {}
		if opts.symbols then
			for _, s in opts.symbols do
				table.insert(symbols, s)
			end
		elseif (metric == "normalizedRmse" or metric == "normalizedMae") and opts.targetScales then
			for s in opts.targetScales do
				table.insert(symbols, s)
			end
		else
			local seen = {}
			for _, row in joined do
				if (row.modelKey == modelA or row.modelKey == modelB) and not seen[row.symbol] then
					seen[row.symbol] = true
					table.insert(symbols, row.symbol)
				end
			end
		end
		table.sort(symbols)
		if #symbols == 0 then
			fail("no symbols to compare")
		end
		local symbolSet: { [string]: boolean } = {}
		for _, s in symbols do
			symbolSet[s] = true
		end
		local scales = opts.targetScales or {}
		if metric == "normalizedRmse" or metric == "normalizedMae" then
			for _, s in symbols do
				local v = scales[s]
				if not isFinite(v) or v <= 0 then
					fail("targetScales must give a positive finite scale for " .. s)
				end
			end
		end

		-- rows of the compared population and the pairing check
		local rows = {}
		local pairing: { [string]: { a: boolean, b: boolean } } = {}
		local seenRow: { [string]: boolean } = {}
		local dateOfT: { [number]: any } = {}
		for i, row in joined do
			if symbolSet[row.symbol] and (opts.split == nil or row.split == opts.split)
				and (row.modelKey == modelA or row.modelKey == modelB) then
				if not isFinite(row.actual) then
					fail("row " .. i .. " has no finite actual")
				end
				if not isFinite(row.t) then
					fail("row " .. i .. " has no finite origin timestamp t")
				end
				local pk = row.symbol .. "@" .. tostring(row.t)
				-- one row per model per symbol/origin: a duplicate would silently reweight the metric
				local rk = tostring(row.modelKey) .. "|" .. pk
				if seenRow[rk] then
					fail("duplicate row for " .. rk)
				end
				seenRow[rk] = true
				-- one date per origin: every row of an origin (both assets, both models) must move together
				local prior = dateOfT[row.t]
				if prior == nil then
					dateOfT[row.t] = row.date
				elseif prior ~= row.date then
					fail("origin " .. tostring(row.t) .. " carries two date labels (" .. tostring(prior) .. ", "
						.. tostring(row.date) .. ")")
				end
				local entry = pairing[pk]
				if not entry then
					entry = { a = false, b = false }
					pairing[pk] = entry
				end
				local has = isFinite(row.prediction)
				if row.prediction ~= nil and not has then
					fail("row " .. i .. " has a non-finite prediction")
				end
				if row.modelKey == modelA then
					if has then
						entry.a = true
					end
				end
				if row.modelKey == modelB then
					if has then
						entry.b = true
					end
				end
				table.insert(rows, row)
			end
		end
		if #rows == 0 then
			fail("no rows for the compared models")
		end
		-- every compared symbol must be present; a pooled metric would otherwise silently narrow to the others
		local symbolSeen: { [string]: boolean } = {}
		for _, row in rows do
			symbolSeen[row.symbol] = true
		end
		for _, s in symbols do
			if not symbolSeen[s] then
				fail("symbol " .. s .. " has no rows for the compared models")
			end
		end
		for pk, entry in pairing do
			if not entry.a then
				fail("incomplete pairing: " .. modelA .. " lacks a forecast for " .. pk)
			end
			if not entry.b then
				fail("incomplete pairing: " .. modelB .. " lacks a forecast for " .. pk)
			end
		end

		local dates, rowsByDate = Bootstrap.orderedDates(rows)
		local m = #dates
		if blockLength > m then
			fail(string.format("blockLength %d exceeds the %d observed dates", blockLength, m))
		end

		local differenceOf: (indices: { number }) -> number
		if custom then
			local fn = metric :: (rows: { any }) -> number
			differenceOf = function(indices)
				local sample = Bootstrap.expand(dates, rowsByDate, indices)
				local ra, rb = {}, {}
				for _, row in sample do
					if row.modelKey == modelA then
						table.insert(ra, row)
					end
					if row.modelKey == modelB then
						table.insert(rb, row)
					end
				end
				local va, vb = fn(ra), fn(rb)
				if not isFinite(va) or not isFinite(vb) then
					fail("custom metric returned a non-finite value")
				end
				return va - vb
			end
		else
			-- per-date, per-symbol sufficient statistics for both models
			local perDate: { { [string]: SymStats } } = {}
			for di, d in dates do
				local stats: { [string]: SymStats } = {}
				for _, s in symbols do
					stats[s] = { n = 0, sseA = 0, saeA = 0, sseB = 0, saeB = 0 }
				end
				for _, row in rowsByDate[d] do
					local st = stats[row.symbol]
					local e = row.prediction - row.actual
					if row.modelKey == modelA then
						st.n += 1
						st.sseA += e * e
						st.saeA += math.abs(e)
					end
					if row.modelKey == modelB then
						st.sseB += e * e
						st.saeB += math.abs(e)
					end
				end
				perDate[di] = stats
			end
			local metricName = metric :: string
			differenceOf = function(indices)
				local agg: { [string]: SymStats } = {}
				for _, s in symbols do
					agg[s] = { n = 0, sseA = 0, saeA = 0, sseB = 0, saeB = 0 }
				end
				for _, i in indices do
					for s, st in perDate[i] do
						local a = agg[s]
						a.n += st.n
						a.sseA += st.sseA
						a.saeA += st.saeA
						a.sseB += st.sseB
						a.saeB += st.saeB
					end
				end
				local va, vb = metricFromStats(metricName, agg, symbols, scales)
				return va - vb
			end
		end

		local all: { number } = {}
		for i = 1, m do
			all[i] = i
		end
		local estimate = differenceOf(all)
		local diffs: { number } = {}
		for r = 1, replicates do
			diffs[r] = differenceOf(Bootstrap.sampleDateIndices(m, blockLength, prng :: any))
		end
		table.sort(diffs)
		return table.freeze({
			estimate = estimate,
			lower = Bootstrap.percentile(diffs, 0.025),
			upper = Bootstrap.percentile(diffs, 0.975),
			seed = opts.seed,
			blockLength = blockLength,
			replicateCount = replicates,
		}) :: any
	end)
	if not ok then
		error(result, 2)
	end
	return result
end

return table.freeze(Bootstrap)
