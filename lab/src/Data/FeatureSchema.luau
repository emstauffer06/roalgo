--!strict
-- Feature identity per profile (plan sections 2.1 and 3): column order, names, continuous/bounded flags,
-- formulas, units, availability rules and bounds. Schemas are frozen; names are stable identifiers.
--
--   O14, H14  identical 14-column formula: 6 SPY, 6 QQQ, clock sin/cos (12 continuous, 2 bounded)
--   R50       14 base, 13 SPY context, 13 QQQ context, 5 IWM, 5 TLT (28 continuous, 22 bounded)
--   R60       R50, then SPY 4 regime probabilities + mask, QQQ 4 probabilities + mask (28 continuous, 32 bounded)
--
-- Continuous columns are z-scored on observed training values then clipped (Scaler). Bounded columns keep
-- their defined values within [lower, upper]; masks, coverage and age sentinels are always observed.
local Types = require("../Types")

type FeatureSchema = Types.FeatureSchema

export type Column = {
	index: number,
	name: string,
	block: string,
	continuous: boolean,
	transform: string, -- "zscore-clip" | "bounded"
	formula: string,
	units: string,
	availability: string,
	-- true when the column is defined for every paired input (base values, clock, masks, coverage, ages,
	-- regime block): its observed flag must be true. Only optional columns may be unobserved.
	alwaysObserved: boolean,
	lower: number?,
	upper: number?,
}

export type Schema = FeatureSchema & {
	columns: { Column },
	offsets: { [string]: number },
}

local VERSION = "mrl-features-1"

local FeatureSchema = {}
FeatureSchema.VERSION = VERSION
FeatureSchema.PROFILES = table.freeze({ "O14", "R50", "H14", "R60" })


-- Spec rows: {name suffix, kind ("c" continuous, "b" bounded), formula, units, availability}.
-- availability == ALWAYS marks an always-observed column (alwaysObserved = true). The base fourteen are also
-- always observed: a base value that cannot be computed is a run failure, never a missing value.
local ALWAYS = "always observed"

local BASE_SYMBOL: { { string } } = {
	{ "ret_1h", "c", "ln(C / previous C); 0 at a segment start", "log return", "current and immediately preceding paired bar of the same segment" },
	{ "body", "c", "ln(C / O)", "log ratio", "current completed bar" },
	{ "range", "c", "ln(H / L)", "log ratio", "current completed bar" },
	{ "close_location", "c", "2(C - L)/(H - L) - 1; 0 when H = L", "unitless", "current completed bar" },
	{ "log1p_volume", "c", "ln(1 + V); negative volume rejected", "log shares", "current completed bar" },
	{ "vwap_displacement", "c", "ln(C / VWAP); nonpositive VWAP rejected", "log ratio", "current completed bar" },
}

local CONTEXT_SYMBOL: { { string } } = {
	{ "ctx_realized_variation", "c", "sqrt(sum r_j^2), r_j over the twelve expected five-minute children", "log return", "all twelve children t+300j completed by t+3600" },
	{ "ctx_ret_last15m", "c", "ln(C11 / C8)", "log return", "all twelve children" },
	{ "ctx_path_efficiency", "b", "abs(sum r_j) / sum abs(r_j); 0 when the denominator is 0", "fraction", "all twelve children; else 0 with complete-mask 0" },
	{ "ctx_volume_share_last15m", "b", "(V9 + V10 + V11) / sum V_j; 0 when total volume is 0", "fraction", "all twelve children; else 0 with complete-mask 0" },
	{ "ctx_5m_complete_mask", "b", "1 when all twelve expected five-minute children exist, else 0", "mask", ALWAYS },
	{ "ctx_5m_coverage", "b", "observed expected children / 12, including partial hours", "fraction", ALWAYS },
	{ "ctx_relative_volume", "c", "ln(1 + V) minus mean ln(1 + V) over the previous <= 20 observed dates at this New York hour", "log shares", "at least five prior same-hour observations, current date excluded" },
	{ "ctx_relative_volume_mask", "b", "1 when ctx_relative_volume meets its history requirement", "mask", ALWAYS },
	{ "ctx_prev_day_ret", "c", "ln(Cday / Oday) of the latest completed daily bar", "log return", "daily bar from a strictly earlier New York date, at most seven calendar dates old, available at its next New York midnight" },
	{ "ctx_daily_vol20", "c", "sqrt(mean((q - mean q)^2)) over twenty prior close-to-close daily log returns", "log return", "twenty returns from twenty-one available daily bars, latest bar fresh" },
	{ "ctx_prev_day_mask", "b", "availability of ctx_prev_day_ret", "mask", ALWAYS },
	{ "ctx_daily_vol_mask", "b", "availability of ctx_daily_vol20", "mask", ALWAYS },
	{ "ctx_daily_age", "b", "min(calendar-date difference, 7) / 7 of the latest available daily bar; 1 if missing or stale", "fraction", ALWAYS },
}

local CROSS_ASSET: { { string } } = {
	{ "ret_1h", "c", "ln(C_u / C_(u-3600))", "log return", "latest bar u with u+3600 <= decision, age <= 7200 s, predecessor u-3600 on the same New York date" },
	{ "range", "c", "ln(H_u / L_u)", "log ratio", "same usable-context rule" },
	{ "log1p_volume", "c", "ln(1 + V_u)", "log shares", "same usable-context rule" },
	{ "usable_mask", "b", "1 when a usable context observation exists, else 0", "mask", ALWAYS },
	{ "age", "b", "min(age, 7200) / 7200; 1 if there is no usable observation", "fraction", ALWAYS },
}

local REGIME: { { string } } = {
	{ "regime_p1", "b", "one-step probability of Markov state 1 (frozen training P)", "probability", ALWAYS },
	{ "regime_p2", "b", "one-step probability of Markov state 2", "probability", ALWAYS },
	{ "regime_p3", "b", "one-step probability of Markov state 3", "probability", ALWAYS },
	{ "regime_p4", "b", "one-step probability of Markov state 4", "probability", ALWAYS },
	{ "regime_mask", "b", "1 from the fourth observation of a segment (state available), else 0 (pi * P used)", "mask", ALWAYS },
}

local function addBlock(columns: { Column }, block: string, prefix: string, specs: { { string } }, allAlways: boolean?)
	for _, s in specs do
		local continuous = s[2] == "c"
		local index = #columns + 1
		local lower, upper = nil, nil
		if not continuous then
			lower, upper = 0, 1
		end
		table.insert(columns, table.freeze({
			index = index,
			name = prefix .. "_" .. s[1],
			block = block,
			continuous = continuous,
			transform = if continuous then "zscore-clip" else "bounded",
			formula = s[3],
			units = s[4],
			availability = s[5],
			alwaysObserved = allAlways == true or s[5] == ALWAYS,
			lower = lower,
			upper = upper,
		}) :: Column)
	end
end

local function baseColumns(columns: { Column })
	addBlock(columns, "spy", "spy", BASE_SYMBOL, true)
	addBlock(columns, "qqq", "qqq", BASE_SYMBOL, true)
	for _, c in {
		{ "clock_sin", "sin(2*pi*h/24), h = New York bar-start hour" },
		{ "clock_cos", "cos(2*pi*h/24), h = New York bar-start hour" },
	} do
		table.insert(columns, table.freeze({
			index = #columns + 1,
			name = c[1],
			block = "clock",
			continuous = false,
			transform = "bounded",
			formula = c[2],
			units = "unitless",
			availability = ALWAYS,
			alwaysObserved = true,
			lower = -1,
			upper = 1,
		}) :: Column)
	end
end

local function make(profileId: string): Schema
	local columns: { Column } = {}
	local offsets: { [string]: number } = { base = 1 }
	baseColumns(columns)
	if profileId == "R50" or profileId == "R60" then
		offsets.spyContext = #columns + 1
		addBlock(columns, "spyContext", "spy", CONTEXT_SYMBOL)
		offsets.qqqContext = #columns + 1
		addBlock(columns, "qqqContext", "qqq", CONTEXT_SYMBOL)
		offsets.iwm = #columns + 1
		addBlock(columns, "iwm", "iwm", CROSS_ASSET)
		offsets.tlt = #columns + 1
		addBlock(columns, "tlt", "tlt", CROSS_ASSET)
	end
	if profileId == "R60" then
		offsets.spyRegime = #columns + 1
		addBlock(columns, "spyRegime", "spy", REGIME)
		offsets.qqqRegime = #columns + 1
		addBlock(columns, "qqqRegime", "qqq", REGIME)
	end
	local names, continuous = {}, {}
	for i, c in columns do
		names[i] = c.name
		continuous[i] = c.continuous
	end
	return table.freeze({
		profileId = profileId,
		dimension = #columns,
		names = table.freeze(names),
		continuous = table.freeze(continuous),
		version = VERSION,
		columns = table.freeze(columns),
		offsets = table.freeze(offsets),
	}) :: any
end

local EXPECTED_DIMENSION = { O14 = 14, H14 = 14, R50 = 50, R60 = 60 }
local cache: { [string]: Schema } = {}

function FeatureSchema.get(profileId: string): Schema
	local expected = EXPECTED_DIMENSION[profileId]
	if expected == nil then
		error("FeatureSchema: unknown profile " .. tostring(profileId), 2)
	end
	local s = cache[profileId]
	if s == nil then
		s = make(profileId)
		if s.dimension ~= expected then
			error(string.format("FeatureSchema: %s built %d columns, expected %d", profileId, s.dimension, expected), 2)
		end
		cache[profileId] = s
	end
	return s
end

-- Assert a vector/row length at a module boundary.
function FeatureSchema.assertDimension(schema: FeatureSchema, n: number)
	if type(schema) ~= "table" or n ~= schema.dimension then
		error(string.format("FeatureSchema: %s dimension %s, expected %s", tostring(schema and schema.profileId), tostring(n), tostring(schema and schema.dimension)), 2)
	end
end

return FeatureSchema
