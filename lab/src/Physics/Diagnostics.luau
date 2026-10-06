--!strict
-- Mechanical gates and throughput (plan Task 3, section 6 mechanism checks). ENGINE CODE.
-- Every function here uses only inputs (never targets). Results are diagnostics, not model inputs.

local Reservoir = require("./Reservoir")
local ExplicitRunner = require("./ExplicitRunner")

local Diagnostics = {}

local function buildRunner(parent: Instance, physics: any, presetId: string, projection: { { number } }, drive: number, name: string)
	local r = Reservoir.build(parent, {
		physics = physics,
		presetId = presetId,
		projection = projection,
		driveDisplacement = drive,
		name = name,
	})
	local runner = ExplicitRunner.new({ r }, {
		dt = physics.dt,
		stepsPerBar = physics.stepsPerBar,
		settleSteps = physics.settleSteps,
	})
	return r, runner
end

-- Runs a sequence of inputs from a reset and returns the 48-value states.
local function trajectory(runner: any, inputs: { { number } }): { { number } }
	runner:resetSegment()
	local out = table.create(#inputs)
	for i, v in inputs do
		out[i] = runner:stepBar({ v })[1]
	end
	return out
end

local function maxAndMedianAbsDiff(a: { { number } }, b: { { number } })
	local diffs = {}
	local maxd = 0
	for i = 1, #a do
		for k = 1, #a[i] do
			local d = math.abs(a[i][k] - b[i][k])
			table.insert(diffs, d)
			if d > maxd then
				maxd = d
			end
		end
	end
	table.sort(diffs)
	local n = #diffs
	local median = if n == 0 then 0 elseif n % 2 == 1 then diffs[(n + 1) // 2] else 0.5 * (diffs[n // 2] + diffs[n // 2 + 1])
	return maxd, median
end

-- Repeatability: soft resets on one reservoir vs a complete rebuild, same inputs (plan Task 3 / section 6).
-- The inputs run as ONE continuous segment from a single reset (no intermediate resets). The pipeline's
-- recorded mechanism checks (tools/mechanism-jobs.mjs R1-R3) cover repeated real segments instead.
function Diagnostics.repeatability(parent: Instance, physics: any, presetId: string, projection: { { number } }, drive: number, inputs: { { number } }, repeats: number)
	local runs = {}
	local r, runner = buildRunner(parent, physics, presetId, projection, drive, "RepeatSoft")
	for k = 1, repeats do
		runs[k] = trajectory(runner, inputs)
	end
	runner:destroy()
	r:destroy()
	local rebuilt = {}
	for k = 1, repeats do
		local r2, runner2 = buildRunner(parent, physics, presetId, projection, drive, "RepeatRebuild" .. k)
		rebuilt[k] = trajectory(runner2, inputs)
		runner2:destroy()
		r2:destroy()
	end
	local softMax, softMedian = 0, 0
	for k = 2, repeats do
		local m, med = maxAndMedianAbsDiff(runs[1], runs[k])
		softMax = math.max(softMax, m)
		softMedian = math.max(softMedian, med)
	end
	local rebuildMax, rebuildMedian = 0, 0
	for k = 1, repeats do
		local m, med = maxAndMedianAbsDiff(runs[1], rebuilt[k])
		rebuildMax = math.max(rebuildMax, m)
		rebuildMedian = math.max(rebuildMedian, med)
	end
	local gate = physics.repeatability
	return {
		presetId = presetId,
		bars = #inputs,
		repeats = repeats,
		softResetMaxAbs = softMax,
		softResetMedianAbs = softMedian,
		rebuildMaxAbs = rebuildMax,
		rebuildMedianAbs = rebuildMedian,
		softPasses = softMax <= gate.maxAbs and softMedian <= gate.median,
		rebuildPasses = rebuildMax <= gate.maxAbs and rebuildMedian <= gate.median,
	}
end

-- Superposition: responses to u, 2u and u+v after identical resets (plan Task 3).
-- Deviation is reported relative to the response RMS; a negligible value means a nearly linear range.
function Diagnostics.superposition(parent: Instance, physics: any, presetId: string, projection: { { number } }, drive: number, u: { { number } }, v: { { number } })
	local r, runner = buildRunner(parent, physics, presetId, projection, drive, "Superposition")
	local function scaled(a: { { number } }, s: number, b: { { number } }?, t: number?)
		local out = table.create(#a)
		for i = 1, #a do
			local row = table.create(#a[i], 0)
			for j = 1, #a[i] do
				row[j] = s * a[i][j] + (if b then (t :: number) * b[i][j] else 0)
			end
			out[i] = row
		end
		return out
	end
	local ru = trajectory(runner, u)
	local r2u = trajectory(runner, scaled(u, 2))
	local rv = trajectory(runner, v)
	local ruv = trajectory(runner, scaled(u, 1, v, 1))
	runner:destroy()
	r:destroy()
	local sumSq, homDev, addDev, n = 0, 0, 0, 0
	for i = 1, #ru do
		for k = 1, #ru[i] do
			sumSq += ru[i][k] ^ 2 + rv[i][k] ^ 2
			homDev += (r2u[i][k] - 2 * ru[i][k]) ^ 2
			addDev += (ruv[i][k] - ru[i][k] - rv[i][k]) ^ 2
			n += 1
		end
	end
	local rms = math.sqrt(sumSq / (2 * n))
	return {
		presetId = presetId,
		responseRms = rms,
		homogeneityDeviationRms = math.sqrt(homDev / n),
		additivityDeviationRms = math.sqrt(addDev / n),
		homogeneityRelative = if rms > 0 then math.sqrt(homDev / n) / rms else 0,
		additivityRelative = if rms > 0 then math.sqrt(addDev / n) / rms else 0,
	}
end

-- Drive calibration probe: saturation fraction and state variance for one drive value over input segments.
-- segments: array of input arrays (each a segment that starts with a reset).
function Diagnostics.calibrate(parent: Instance, physics: any, presetId: string, projection: { { number } }, drive: number, segments: { { { number } } })
	local r, runner = buildRunner(parent, physics, presetId, projection, drive, "Calibrate")
	local saturated, measured = 0, 0
	local sum, sumSq = table.create(48, 0), table.create(48, 0)
	local maxAbsX = 0
	for _, seg in segments do
		runner:resetSegment()
		for _, v in seg do
			local s = runner:stepBar({ v })[1]
			for i = 1, 24 do
				local x = math.abs(s[i] * 3)
				measured += 1
				if x >= physics.saturationThreshold then
					saturated += 1
				end
				maxAbsX = math.max(maxAbsX, x)
			end
			for k = 1, 48 do
				sum[k] += s[k]
				sumSq[k] += s[k] * s[k]
			end
		end
	end
	runner:destroy()
	r:destroy()
	local bars = measured / 24
	local meanVar = 0
	for k = 1, 48 do
		local m = sum[k] / bars
		meanVar += sumSq[k] / bars - m * m
	end
	local fraction = saturated / math.max(1, measured)
	return {
		presetId = presetId,
		drive = drive,
		bars = bars,
		saturatedFraction = fraction,
		maxAbsX = maxAbsX,
		meanStateVariance = meanVar / 48,
		passes = fraction <= physics.maxSaturationFraction,
	}
end

return Diagnostics
