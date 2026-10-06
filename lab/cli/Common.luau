-- Shared CLI loading for the lab pipeline (CLI only; uses the generated chunk loaders).
local Sources = require("../generated/Sources")
local Calendar = require("../src/Data/Calendar")
local Dataset = require("../src/Data/Dataset")
local Config = require("../src/Config")
local Json = require("../src/Util/Json")

local Common = {}

Common.PROFILES = { O14 = true, R50 = true, H14 = true }

local cache = {}
function Common.load(group: string, symbol: string)
	local key = group .. "/" .. symbol
	if not cache[key] then
		cache[key] = Sources.get(group, symbol).load()
	end
	return cache[key]
end

local calendar
function Common.calendar()
	calendar = calendar or Calendar.default()
	return calendar
end

-- The paired hourly stream a profile uses: original for O14/R50, combined (2016+) for H14.
function Common.dataset(profileId: string)
	assert(Common.PROFILES[profileId], "Common: unknown profile " .. tostring(profileId))
	local group = if profileId == "H14" then "hourly-combined" else "hourly-original"
	return Dataset.new(Common.load(group, "SPY"), Common.load(group, "QQQ"), Common.calendar())
end

function Common.r50Sources()
	return {
		fiveMinute = { SPY = Common.load("five-minute", "SPY"), QQQ = Common.load("five-minute", "QQQ") },
		hourly = { SPY = Common.load("hourly-combined", "SPY"), QQQ = Common.load("hourly-combined", "QQQ") },
		daily = { SPY = Common.load("daily-context", "SPY"), QQQ = Common.load("daily-context", "QQQ") },
		context = { IWM = Common.load("hourly-context", "IWM"), TLT = Common.load("hourly-context", "TLT") },
	}
end

-- Split label of an input observation by its decision time (the convention that reproduces plan 2.3).
function Common.inputSplit(decisionTime: number): string
	local s = Config.values.splits
	if decisionTime < s.validationStart then
		return "train"
	elseif decisionTime < s.testStart then
		return "validation"
	elseif decisionTime < s.datasetEnd then
		return "final"
	end
	return "none"
end

Common.EXPERIMENT = "exp-20261005"
Common.RUN_ROOT = "../../runs/"

-- Loads a chunked run-data directory written by tools/run-lab.mjs (path relative to runs/).
function Common.loadRunChunks(relDir: string)
	local base = Common.RUN_ROOT .. relDir
	local index = require(base .. "/index")
	local rows = table.create(index.count)
	for _, name in index.chunks do
		for _, r in require(base .. "/" .. name) do
			table.insert(rows, r)
		end
	end
	assert(#rows == index.count, "Common: " .. relDir .. " row count mismatch")
	return rows, index
end

-- Profile inputs: by pair index i -> {t, seg, off, splitCode, x}.
function Common.loadInputs(profileId: string)
	local rows, index = Common.loadRunChunks(Common.EXPERIMENT .. "/luau/inputs_" .. profileId)
	return rows, index
end

-- Profile physics states for a phase: map t -> {[key] = 48 values}, plus the key order.
function Common.loadStates(profileId: string, phase: string)
	local rel = Common.EXPERIMENT .. "/luau/states_" .. profileId .. "-" .. phase
	local rows, index = Common.loadRunChunks(rel)
	local keys = require(Common.RUN_ROOT .. rel .. "/keys")
	local byT = {}
	for _, r in rows do
		local s = {}
		for k, key in keys do
			assert(#r[2 + k] == 48, "Common: state width")
			s[key] = r[2 + k]
		end
		byT[r[2]] = s
	end
	return byT, keys, index
end

function Common.emit(tag: string, value: any)
	print(tag .. " " .. Json.encode(value))
end

function Common.result(value: any)
	Common.emit("@@JSON", value)
end

return Common
