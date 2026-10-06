-- Prepare a profile's causal input stream (plan section 3, Task 2/6 "fit input scaling on training inputs and
-- freeze it before native feature generation").
--   luau.exe --codegen -O2 lab/cli/prepare.luau -a <O14|R50|H14>
-- Emits one "@@ROW {i,t,seg,off,split,x}" line per paired observation (every observation, eligible or not)
-- and one "@@JSON {...}" summary with the schema, the frozen scaler and diagnostics. Reads no targets.
local Common = require("./Common")
local Features = require("../src/Data/Features")
local FeatureSchema = require("../src/Data/FeatureSchema")
local Scaler = require("../src/Data/Scaler")
local SupplementalFeatures = require("../src/Data/SupplementalFeatures")
local Config = require("../src/Config")

local profileId = ...
assert(Common.PROFILES[profileId], "prepare: profile must be O14, R50 or H14")
local clock0 = os.clock()
local cal = Common.calendar()
local ds = Common.dataset(profileId)
local schema = FeatureSchema.get(profileId)
local pairs = ds:pairs()
local builder = if profileId == "R50" then SupplementalFeatures.new(Common.r50Sources(), cal) else nil

local rows = table.create(#pairs)
for idx, p in pairs do
	local prev = if idx > 1 then pairs[idx - 1] else nil
	if prev and prev.segmentId ~= p.segmentId then
		prev = nil
	end
	if builder then
		rows[idx] = builder:row(p, Features.compute(p, prev))
	else
		rows[idx] = Features.baseRow(p, prev, profileId)
	end
end
FeatureSchema.assertDimension(schema, #rows[1].values)

local training = {}
for _, row in rows do
	if row.decisionTime < Config.values.splits.validationStart then
		table.insert(training, row)
	end
end
local scaler = Scaler.fit(training, schema)

local counts = { train = 0, validation = 0, final = 0, none = 0 }
local observedBySplit = { train = table.create(schema.dimension, 0), validation = table.create(schema.dimension, 0), final = table.create(schema.dimension, 0), none = table.create(schema.dimension, 0) }
for idx, p in pairs do
	local split = Common.inputSplit(p.decisionTime)
	counts[split] += 1
	local row = rows[idx]
	for j = 1, schema.dimension do
		if row.observed[j] then
			observedBySplit[split][j] += 1
		end
	end
	local x = scaler:transform(row, split)
	Common.emit("@@ROW", { i = idx, t = p.t, seg = p.segmentId, off = p.segmentOffset, split = split, x = x })
end

Common.result({
	profileId = profileId,
	pairs = #pairs,
	counts = counts,
	trainingRows = #training,
	schema = {
		profileId = schema.profileId,
		dimension = schema.dimension,
		names = schema.names,
		continuous = schema.continuous,
		version = schema.version,
		formulaVersion = if builder then SupplementalFeatures.FORMULA_VERSION else "base-14",
	},
	scaler = scaler:serialize(),
	diagnostics = scaler:diagnostics(),
	observedBySplit = observedBySplit,
	datasetStats = ds:stats(),
	configSha256 = Config.sourceSha256,
	seconds = os.clock() - clock0,
})
