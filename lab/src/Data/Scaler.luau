--!strict
-- Training-fitted, mask-aware input transform (plan section 3, "Original hourly inputs" and "Rich scaling,
-- masks, and feature identity"). Distinct from Ridge's design-column scaler.
--
-- Scaler.fit(rows, schema, options?)
--   * For each continuous column: Welford mean and POPULATION standard deviation over the rows' OBSERVED
--     values only (observed[j] == true). Unobserved entries never enter the fit; an observed real zero does.
--   * std < constantStdThreshold (1e-12): the column is flagged constant and always emits 0.
--   * A continuous column with no observed training value is flagged neverObserved and emits 0 in every
--     split, even when a later split observes it (it is never fitted on validation/final data).
--   * Rows must be training rows: decisionTime < options.fitBefore (default: config validationStart), passed
--     as a dense array (a hole is an error, never a silently shortened fit).
--   * Columns the schema marks alwaysObserved (base, clock, masks, coverage, ages, regime block) must carry
--     observed = true in fit and transform rows; only optional columns may be unobserved.
-- scaler:transform(row, splitName?) -> {number} of the schema's declared length:
--   * continuous, observed:   z = (x - mean)/std clipped to [-clip, clip] (clip = 4); clips counted per
--                             column and split
--   * continuous, unobserved: 0, applied AFTER scaling (the explicit masks in the row stay as they are)
--   * bounded:                passed through unchanged (must lie within the schema bounds); 0 if unobserved
-- scaler:serialize() / Scaler.deserialize(t, schema) round-trip exactly (plain numbers/booleans/strings).
-- scaler:diagnostics() reports per-column fit statistics, constant/never-observed columns and clipping.
-- transform's only side effect is the clipping counters; fitted parameters are frozen.
local Types = require("../Types")
local Config = require("../Config")

type FeatureRow = Types.FeatureRow
type FeatureSchema = Types.FeatureSchema

local FORMAT = "mrl-scaler-1"
local BOUND_TOLERANCE = 1e-12

export type ScalerOptions = { clip: number?, constantStdThreshold: number?, fitBefore: number? }

export type Scaler = {
	transform: (self: any, row: FeatureRow, splitName: string?) -> { number },
	serialize: (self: any) -> { [string]: any },
	diagnostics: (self: any) -> { [string]: any },
}

local Scaler = {}
Scaler.__index = Scaler

local function isFinite(x: any): boolean
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function checkSchema(schema: any)
	if type(schema) ~= "table" or type(schema.dimension) ~= "number" or type(schema.continuous) ~= "table"
		or type(schema.names) ~= "table" or #schema.continuous ~= schema.dimension or #schema.names ~= schema.dimension then
		error("Scaler: a feature schema with names and continuous flags is required", 3)
	end
end

local function checkRow(row: any, schema: any, label: string)
	if type(row) ~= "table" or type(row.values) ~= "table" or type(row.observed) ~= "table" then
		error("Scaler: " .. label .. " must be a FeatureRow", 3)
	end
	if row.profileId ~= schema.profileId then
		error(string.format("Scaler: %s profile %s does not match schema profile %s", label, tostring(row.profileId), tostring(schema.profileId)), 3)
	end
	local d = schema.dimension
	if #row.values ~= d or #row.observed ~= d then
		error(string.format("Scaler: %s dimension %s/%s, expected %s", label, tostring(#row.values), tostring(#row.observed), tostring(d)), 3)
	end
	for j = 1, d do
		if not isFinite(row.values[j]) then
			error(string.format("Scaler: %s column %d (%s) is not a finite number", label, j, tostring(schema.names[j])), 3)
		end
		if type(row.observed[j]) ~= "boolean" then
			error(string.format("Scaler: %s observed flag %d must be a boolean", label, j), 3)
		end
	end
	-- Base values, clock, masks, coverage and age sentinels are always observed (plan section 3); flagging
	-- one unobserved would silently zero a signal that missingness must not erase.
	if type(schema.columns) == "table" then
		for j = 1, d do
			local c = schema.columns[j]
			if c and c.alwaysObserved and row.observed[j] ~= true then
				error(string.format("Scaler: %s column %d (%s) is always observed but flagged unobserved", label, j, tostring(schema.names[j])), 3)
			end
		end
	end
end

type Params = {
	profileId: string,
	schemaVersion: string,
	dimension: number,
	names: { string },
	continuous: { boolean },
	clip: number,
	constantStdThreshold: number,
	fitBefore: number,
	rowCount: number,
	means: { number },
	stds: { number },
	counts: { number },
	constant: { boolean },
	neverObserved: { boolean },
}

local function build(params: Params, schema: any): Scaler
	local lower, upper = table.create(params.dimension), table.create(params.dimension)
	if type(schema.columns) == "table" then
		for j = 1, params.dimension do
			local c = schema.columns[j]
			if c then
				lower[j], upper[j] = c.lower, c.upper
			end
		end
	end
	local self = setmetatable({
		_p = table.freeze(params),
		_schema = schema,
		_lower = lower,
		_upper = upper,
		_clip = {},
		_splitOrder = {},
	}, Scaler)
	return self :: any
end

local function copyArray<T>(a: { T }): { T }
	return table.move(a, 1, #a, 1, table.create(#a))
end

function Scaler.fit(rows: { FeatureRow }, schema: FeatureSchema, options: ScalerOptions?): Scaler
	checkSchema(schema)
	local opts: ScalerOptions = options or {}
	local clip = opts.clip or Config.values.scaler.clip
	local threshold = opts.constantStdThreshold or Config.values.scaler.constantStdThreshold
	local fitBefore = opts.fitBefore or Config.values.splits.validationStart
	if not (isFinite(clip) and clip > 0 and isFinite(threshold) and threshold >= 0 and isFinite(fitBefore)) then
		error("Scaler: invalid options", 2)
	end
	if type(rows) ~= "table" or #rows == 0 then
		error("Scaler: no training rows", 2)
	end
	-- A hole would make ipairs stop early and silently drop every later row from the fit.
	local rowTotal = #rows
	local keyCount = 0
	for k in rows do
		if type(k) ~= "number" or k < 1 or k > rowTotal or k ~= math.floor(k) then
			error("Scaler: training rows must be a dense array (unexpected key " .. tostring(k) .. ")", 2)
		end
		keyCount += 1
	end
	if keyCount ~= rowTotal then
		error(string.format("Scaler: training rows must be a dense array (%d rows for length %d)", keyCount, rowTotal), 2)
	end
	local d = schema.dimension
	local counts, means, m2 = table.create(d, 0), table.create(d, 0), table.create(d, 0)
	for r = 1, rowTotal do
		local row = rows[r]
		checkRow(row, schema, "training row " .. r)
		if not isFinite(row.decisionTime) or row.decisionTime >= fitBefore then
			error(string.format("Scaler: training row %s decisionTime %s is not before fitBefore %s", tostring(r), tostring(row.decisionTime), tostring(fitBefore)), 2)
		end
		for j = 1, d do
			if schema.continuous[j] and row.observed[j] then
				local x = row.values[j]
				local n = counts[j] + 1
				counts[j] = n
				local delta = x - means[j]
				means[j] += delta / n
				m2[j] += delta * (x - means[j])
			end
		end
	end
	local stds, constant, never = table.create(d, 0), table.create(d, false), table.create(d, false)
	for j = 1, d do
		if schema.continuous[j] then
			if counts[j] == 0 then
				never[j] = true
			else
				stds[j] = math.sqrt(m2[j] / counts[j])
				constant[j] = stds[j] < threshold
			end
		end
	end
	return build({
		profileId = schema.profileId,
		schemaVersion = schema.version,
		dimension = d,
		names = copyArray(schema.names),
		continuous = copyArray(schema.continuous),
		clip = clip,
		constantStdThreshold = threshold,
		fitBefore = fitBefore,
		rowCount = rowTotal,
		means = means,
		stds = stds,
		counts = counts,
		constant = constant,
		neverObserved = never,
	}, schema)
end

local function splitStats(self: any, split: string)
	local s = self._clip[split]
	if s == nil then
		local d = self._p.dimension
		s = {
			rows = 0,
			observed = table.create(d, 0),
			clippedLow = table.create(d, 0),
			clippedHigh = table.create(d, 0),
		}
		self._clip[split] = s
		table.insert(self._splitOrder, split)
	end
	return s
end

function Scaler.transform(self: any, row: FeatureRow, splitName: string?): { number }
	local p: Params = self._p
	checkRow(row, self._schema, "row")
	local stats = splitStats(self, splitName or "unspecified")
	stats.rows += 1
	local d = p.dimension
	local out = table.create(d, 0)
	for j = 1, d do
		local x = row.values[j]
		if p.continuous[j] then
			if row.observed[j] and not p.neverObserved[j] then
				stats.observed[j] += 1
				if not p.constant[j] then
					local z = (x - p.means[j]) / p.stds[j]
					if z > p.clip then
						z = p.clip
						stats.clippedHigh[j] += 1
					elseif z < -p.clip then
						z = -p.clip
						stats.clippedLow[j] += 1
					end
					out[j] = z
				end
			end
		elseif row.observed[j] then
			local lo, hi = self._lower[j], self._upper[j]
			if (lo ~= nil and x < lo - BOUND_TOLERANCE) or (hi ~= nil and x > hi + BOUND_TOLERANCE) then
				error(string.format("Scaler: bounded column %d (%s) value %s is outside its declared bounds", j, p.names[j], tostring(x)), 2)
			end
			out[j] = x
		end
	end
	return out
end

function Scaler.serialize(self: any): { [string]: any }
	local p: Params = self._p
	return {
		format = FORMAT,
		profileId = p.profileId,
		schemaVersion = p.schemaVersion,
		dimension = p.dimension,
		names = copyArray(p.names),
		continuous = copyArray(p.continuous),
		clip = p.clip,
		constantStdThreshold = p.constantStdThreshold,
		fitBefore = p.fitBefore,
		rowCount = p.rowCount,
		means = copyArray(p.means),
		stds = copyArray(p.stds),
		counts = copyArray(p.counts),
		constant = copyArray(p.constant),
		neverObserved = copyArray(p.neverObserved),
	}
end

function Scaler.deserialize(t: any, schema: FeatureSchema): Scaler
	checkSchema(schema)
	local function bad(msg: string): never
		error("Scaler: cannot deserialize: " .. msg, 3)
	end
	if type(t) ~= "table" or t.format ~= FORMAT then
		bad("format is not " .. FORMAT)
	end
	if t.profileId ~= schema.profileId then
		bad(string.format("serialized profile %s does not match schema profile %s", tostring(t.profileId), tostring(schema.profileId)))
	end
	if t.schemaVersion ~= schema.version or t.dimension ~= schema.dimension then
		bad("schema version or dimension differs")
	end
	local d = schema.dimension
	for _, key in { "names", "continuous", "means", "stds", "counts", "constant", "neverObserved" } do
		if type(t[key]) ~= "table" or #t[key] ~= d then
			bad(key .. " must have " .. d .. " entries")
		end
	end
	for j = 1, d do
		if t.names[j] ~= schema.names[j] or t.continuous[j] ~= schema.continuous[j] then
			bad("column " .. j .. " identity differs from the schema")
		end
		if not (isFinite(t.means[j]) and isFinite(t.stds[j]) and t.stds[j] >= 0 and isFinite(t.counts[j]) and t.counts[j] >= 0) then
			bad("column " .. j .. " has invalid statistics")
		end
		local never = schema.continuous[j] and t.counts[j] == 0
		local constant = schema.continuous[j] and t.counts[j] > 0 and t.stds[j] < t.constantStdThreshold
		if t.neverObserved[j] ~= never or t.constant[j] ~= constant then
			bad("column " .. j .. " flags are inconsistent with its statistics")
		end
	end
	if not (isFinite(t.clip) and t.clip > 0 and isFinite(t.constantStdThreshold) and isFinite(t.fitBefore) and isFinite(t.rowCount)) then
		bad("invalid clip, threshold, fitBefore or rowCount")
	end
	return build({
		profileId = t.profileId,
		schemaVersion = t.schemaVersion,
		dimension = d,
		names = copyArray(t.names),
		continuous = copyArray(t.continuous),
		clip = t.clip,
		constantStdThreshold = t.constantStdThreshold,
		fitBefore = t.fitBefore,
		rowCount = t.rowCount,
		means = copyArray(t.means),
		stds = copyArray(t.stds),
		counts = copyArray(t.counts),
		constant = copyArray(t.constant),
		neverObserved = copyArray(t.neverObserved),
	}, schema)
end

function Scaler.diagnostics(self: any): { [string]: any }
	local p: Params = self._p
	local columns, constantColumns, neverColumns = {}, {}, {}
	for j = 1, p.dimension do
		columns[j] = {
			index = j,
			name = p.names[j],
			continuous = p.continuous[j],
			count = p.counts[j],
			mean = p.means[j],
			std = p.stds[j],
			constant = p.constant[j],
			neverObserved = p.neverObserved[j],
		}
		if p.constant[j] then
			table.insert(constantColumns, j)
		end
		if p.neverObserved[j] then
			table.insert(neverColumns, j)
		end
	end
	local clipping = {}
	for _, split in self._splitOrder do
		local s = self._clip[split]
		local rate = table.create(p.dimension, 0)
		for j = 1, p.dimension do
			if s.observed[j] > 0 then
				rate[j] = (s.clippedLow[j] + s.clippedHigh[j]) / s.observed[j]
			end
		end
		clipping[split] = {
			rows = s.rows,
			observed = copyArray(s.observed),
			clippedLow = copyArray(s.clippedLow),
			clippedHigh = copyArray(s.clippedHigh),
			rate = rate,
		}
	end
	return {
		profileId = p.profileId,
		schemaVersion = p.schemaVersion,
		rowCount = p.rowCount,
		clip = p.clip,
		constantStdThreshold = p.constantStdThreshold,
		fitBefore = p.fitBefore,
		columns = columns,
		constantColumns = constantColumns,
		neverObservedColumns = neverColumns,
		clipping = clipping,
	}
end

return Scaler
