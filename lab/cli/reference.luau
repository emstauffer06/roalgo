-- Reference design rows for verifying, inside Studio, that the exported model artifacts reconstruct the frozen
-- final forecasts (plan Task 9). Reads no targets. Added after evaluation; it does not alter any locked file.
--   luau.exe --codegen -O2 lab/cli/reference.luau -a <O14|R50|H14> <count>
local Common = require("./Common")
local Config = require("../src/Config")
local History = require("../src/Data/History")

local profileId, countArg = ...
local count = tonumber(countArg) or 25
local cfg = Config.values
local splits = cfg.splits
local artifact = require(Common.RUN_ROOT .. profileId .. "-a1/luau/model")
local ds = Common.dataset(profileId)
local pairs = ds:pairs()
local inputs, inputIndex = Common.loadInputs(profileId)
local finalStates = Common.loadStates(profileId, "final")
local stateKey = profileId .. ":" .. artifact.preset
local hist = History.new(cfg.maxLag, inputIndex.dimension)

local warmed = {}
for idx, p in pairs do
	if p.segmentOffset == 1 then
		hist:reset()
	end
	hist:push(inputs[idx][6])
	if p.decisionTime >= splits.testStart and p.decisionTime < splits.datasetEnd and p.segmentOffset >= cfg.warmupObservations then
		table.insert(warmed, { t = p.t, lag = { [1] = hist:vector(1), [4] = hist:vector(4), [8] = hist:vector(8) }, state = finalStates[p.t][stateKey] })
	end
end
local step = math.max(1, math.floor(#warmed / count))
for k = 1, #warmed, step do
	local w = warmed[k]
	local rawPhysics = table.clone(w.lag[8])
	table.move(w.state, 1, #w.state, #rawPhysics + 1, rawPhysics)
	Common.emit("@@ROW", {
		t = w.t,
		designs = { RAW = w.lag[artifact.rawLag], RAW8 = w.lag[8], RAW_PHYSICS = rawPhysics, PHYSICS = w.state },
	})
end
Common.result({ profileId = profileId, warmed = #warmed, step = step })
