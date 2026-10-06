-- Spring indicator harness runner (generated from spring-runner/Runner.template.luau by spring-runner-lib.mjs).
-- Runs the real Luau modules copied into ./src: SpringPolicy.protocol(id) (the canonical protocol table),
-- SpringState.describe, then SpringStudy.evaluate and SpringStudy.validateResult. No Engine, VerifiedStepper,
-- Mechanics, PhysicsView, Learning or Features module is present in this directory, so no native step can be
-- taken from here.
-- Output protocol (stdout, ASCII only): exactly one "@@HARNESS <json>" line, then exactly one "@@JSON <json>" line.
local SpringJson = require("./SpringJson")
local SpringPolicy = require("./src/SpringPolicy")
local SpringState = require("./src/SpringState")
local SpringStudy = require("./src/SpringStudy")
local input = require("./Input")

local function deepFreeze(t)
	for _, v in t do
		if type(v) == "table" then
			deepFreeze(v)
		end
	end
	if not table.isfrozen(t) then
		table.freeze(t)
	end
	return t
end

assert(type(SpringPolicy.protocol) == "function", "SpringPolicy.protocol is required")
assert(type(SpringState.describe) == "function", "SpringState.describe is required")
assert(type(SpringStudy.evaluate) == "function", "SpringStudy.evaluate is required")
assert(type(SpringStudy.validateResult) == "function", "SpringStudy.validateResult is required")

collectgarbage("collect")
local heapStartKB = collectgarbage("count")
local loadStart = os.clock()
local records = table.create(input.recordCount)
local function append(chunk)
	for _, record in chunk do
		records[#records + 1] = record
	end
end
--[[@@DATA_REQUIRES@@]]
local loadSeconds = os.clock() - loadStart
assert(#records == input.recordCount, "harness: expected " .. input.recordCount .. " records, loaded " .. #records)
-- Inputs are read-only for every module: any write raises instead of silently changing evidence.
deepFreeze(records)
deepFreeze(input)
collectgarbage("collect")
local heapLoadedKB = collectgarbage("count")

local protocol = SpringPolicy.protocol(input.protocolId)
assert(type(protocol) == "table" and protocol.id == input.protocolId, "SpringPolicy.protocol returned a different protocol id")

local describeStart = os.clock()
local descriptor = SpringState.describe(input.nativeConfig, input.stateNames, input.driveNames, protocol)
local describeSeconds = os.clock() - describeStart

local evaluateStart = os.clock()
local result = SpringStudy.evaluate(records, input.split, descriptor, protocol)
local evaluateSeconds = os.clock() - evaluateStart
assert(type(result) == "table", "SpringStudy.evaluate must return a table")
local valid, reason = SpringStudy.validateResult(result)
assert(valid == true, "SpringStudy.validateResult rejected the result: " .. tostring(reason))
local heapAfterEvaluateKB = collectgarbage("count")
collectgarbage("collect")
local heapLiveAfterEvaluateKB = collectgarbage("count")

local encodeStart = os.clock()
local encoded = SpringJson.encode(result)
local encodeSeconds = os.clock() - encodeStart

print("@@HARNESS " .. SpringJson.encode({
	recordCount = #records,
	dataModules = input.dataModuleCount,
	inputRecordsFrozen = table.isfrozen(records) and table.isfrozen(records[1]) and table.isfrozen(records[1].bar),
	loadSeconds = loadSeconds,
	describeSeconds = describeSeconds,
	evaluateSeconds = evaluateSeconds,
	encodeSeconds = encodeSeconds,
	heapStartKB = heapStartKB,
	heapLoadedKB = heapLoadedKB,
	heapAfterEvaluateKB = heapAfterEvaluateKB,
	heapLiveAfterEvaluateKB = heapLiveAfterEvaluateKB,
	resultBytes = #encoded,
	luauVersionGlobal = _VERSION,
	protocol = protocol,
}))
print("@@JSON " .. encoded)
