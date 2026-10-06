--!strict
-- Shared contracts for the Roblox market reservoir lab.
-- Owner: integration. Change this file and every consumer together.
--
-- Module rules (apply to every file under lab/src except Physics/, UI/, Studio/ and Main.server.luau):
--   * Pure Luau. No game, script, workspace, Instance, Vector3, CFrame, Random, task, os.time, os.date, HttpService.
--   * Require siblings only with relative require-by-string ("./X", "../Model/Y"). This resolves identically in
--     the Luau CLI (files) and in Studio (ModuleScripts mirrored from the same tree).
--   * Randomness is injected (see Prng). Time-zone facts come from Calendar (generated from Node Intl data).
--   * Errors are raised with error("<Module>: <reason>", 2); never swallow a failure into a numeric zero.

-- One provider-native bar: {timestamp_unix (UTC bar start, s), open, high, low, close, volume, trade_count, vwap}
export type Bar = { number }

-- Column indices into Bar.
export type BarColumns = {
	T: number, OPEN: number, HIGH: number, LOW: number, CLOSE: number,
	VOLUME: number, TRADES: number, VWAP: number,
}

-- New York local facts for one UTC instant.
export type LocalTime = {
	dateKey: number, -- yyyymmdd as an integer, e.g. 20240102
	dayNumber: number, -- days since 1970-01-01 of the NY calendar date (monotone, gap-free)
	hour: number, -- 0..23 NY wall-clock hour
	minute: number,
	offsetSeconds: number, -- NY minus UTC, e.g. -18000 (EST) or -14400 (EDT)
}

export type Calendar = {
	localTime: (self: Calendar, t: number) -> LocalTime,
	-- UTC seconds of 00:00 New York on the calendar date after dateKey (daily-bar availability time).
	nextMidnightAfter: (self: Calendar, dateKey: number) -> number,
	dateString: (self: Calendar, dateKey: number) -> string, -- "YYYY-MM-DD"
}

-- One paired hourly observation (both symbols have a bar starting at t).
export type Pair = {
	index: number, -- 1-based position in the paired stream
	t: number, -- bar start, UTC seconds
	decisionTime: number, -- t + 3600
	dateNY: string, -- "YYYY-MM-DD" of the bar start in New York
	dateKey: number,
	dayNumber: number,
	hourNY: number,
	segmentId: number, -- increments on first pair, NY date change, or delta ~= 3600
	segmentOffset: number, -- 1 for the first pair of a segment, 2 for the next, ...
	spy: Bar,
	qqq: Bar,
}

export type Dataset = {
	count: (self: Dataset) -> number,
	get: (self: Dataset, index: number) -> Pair?,
	indexOf: (self: Dataset, t: number) -> number?, -- paired index of the pair starting at t
	pairs: (self: Dataset) -> { Pair }, -- read-only view; callers must not mutate
	symbolBarAt: (self: Dataset, symbol: string, t: number) -> Bar?, -- per-symbol native bar (may exist unpaired)
}

export type SplitName = "train" | "validation" | "final" | "none"

export type Splits = {
	validationStart: number,
	testStart: number,
	datasetEnd: number,
}

export type FeatureSchema = {
	profileId: string, -- "O14" | "R50" | "H14" | "R60"
	dimension: number,
	names: { string },
	continuous: { boolean }, -- true: z-scored on observed training values then clipped
	version: string,
}

export type FeatureRow = {
	values: { number }, -- untransformed; unavailable entries hold 0 and observed=false
	observed: { boolean },
	t: number,
	decisionTime: number,
	profileId: string,
}

export type OutcomePair = {
	eligible: boolean,
	reason: string?, -- insufficient_warmup | missing_intermediate_hour | missing_target |
	-- different_local_date | split_boundary | invalid_input
	split: SplitName,
	spy: number?, -- ln(close[t+8h]/close[t])
	qqq: number?,
	decisionTime: number,
	outcomeTime: number,
	targetT: number,
}

-- Physics state row exported from Studio (one per paired observation, eligible or not).
export type StateRow = {
	index: number,
	t: number,
	segmentId: number,
	profileId: string,
	featureSchemaHash: string,
	input: { number },
	state: { number }, -- 48 values: 24 x/3 then 24 v/(3*omega_i)
	valid: boolean,
}

export type Forecast = {
	id: string, -- runId..":"..modelId..":"..symbol..":"..tostring(t)
	runId: string,
	modelId: string,
	symbol: string,
	t: number,
	decisionTime: number,
	outcomeTime: number,
	prediction: number,
	modelHash: string,
	dataHash: string,
}

export type Outcome = {
	forecastId: string,
	eligible: boolean,
	actual: number?,
	exclusionReason: string?,
}

export type RidgeModel = {
	retained: { number }, -- indices of design columns kept (training std >= 1e-12)
	means: { number }, -- per retained column
	scales: { number }, -- per retained column (population std)
	targetMeans: { number }, -- one per output head
	beta: { { number } }, -- #retained rows x heads
	lambda: number,
	schemaVersion: string,
	inputDimension: number,
}

export type Candidate = {
	profileId: string,
	family: string, -- RAW-RIDGE | PHYSICS-RIDGE | RAW+PHYSICS
	config: string, -- e.g. "L8" or "P2"
	lag: number?,
	preset: string?,
	lambda: number,
	score: number?, -- mean over symbols of validation RMSE / training target std
	status: string, -- ok | rejected:<reason>
}

export type Interval = {
	estimate: number,
	lower: number,
	upper: number,
	seed: number,
	blockLength: number,
	replicateCount: number,
}

export type Progress = {
	phase: string,
	runId: string,
	processed: number,
	total: number,
	segment: number,
	status: string,
	error: string?,
}

-- Injected pseudo-random source (pure code must not construct Roblox Random).
export type Prng = {
	nextNumber: (self: Prng) -> number, -- uniform [0,1)
	nextInteger: (self: Prng, lo: number, hi: number) -> number, -- inclusive
}

return {
	Bar = table.freeze({ T = 1, OPEN = 2, HIGH = 3, LOW = 4, CLOSE = 5, VOLUME = 6, TRADES = 7, VWAP = 8 }) :: BarColumns,
	EXCLUSION_REASONS = table.freeze({
		"invalid_input",
		"insufficient_warmup",
		"missing_intermediate_hour",
		"missing_target",
		"different_local_date",
		"split_boundary",
	}),
}
