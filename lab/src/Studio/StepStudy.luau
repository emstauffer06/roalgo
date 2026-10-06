-- Characterises deferred WorldRoot:StepPhysics semantics with a metronome part (ENGINE CODE, temporary parts only).
local RunService = game:GetService("RunService")

local StepStudy = {}
local DT = 1 / 60

local function clockPart(parent, x)
	local p = Instance.new("Part")
	p.Name = "StudyClock"
	p.Size = Vector3.new(1, 1, 1)
	p.Anchored = false
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CFrame = CFrame.new(x or 300, 4000, 0)
	p.Parent = parent
	return p
end

local function hist(values)
	local h = {}
	for _, v in values do
		local k = string.format("%.2f", v)
		h[k] = (h[k] or 0) + 1
	end
	return h
end

-- args = {frames, callsPerFrame, resetEvery, extraParts}
function StepStudy.perFrame(ctx, args)
	local frames = args.frames or 200
	local callsPerFrame = args.callsPerFrame or 1
	local folder = Instance.new("Folder")
	folder.Name = "MarketReservoirStepStudy"
	folder.Parent = workspace
	local clock = clockPart(folder)
	local g = workspace.Gravity * DT
	local function count()
		return -clock.AssemblyLinearVelocity.Y / g
	end
	for _ = 1, 5 do
		RunService.Heartbeat:Wait()
	end
	local incs = {}
	local zeroAt = {}
	local fracAt = {}
	local prev = count()
	local t0 = os.clock()
	for f = 1, frames do
		for _ = 1, callsPerFrame do
			workspace:StepPhysics(DT, { clock })
		end
		RunService.Heartbeat:Wait()
		local c = count()
		local inc = c - prev
		prev = c
		table.insert(incs, inc)
		if math.abs(inc) < 1e-6 then
			table.insert(zeroAt, f)
		elseif math.abs(inc - math.floor(inc + 0.5)) > 1e-3 then
			table.insert(fracAt, f)
		end
	end
	for _ = 1, 20 do
		RunService.Heartbeat:Wait()
	end
	local tail = count() - prev
	local report = {
		context = ctx and ctx.context,
		frames = frames,
		callsPerFrame = callsPerFrame,
		requested = frames * callsPerFrame,
		completed = count(),
		tailAfterStop = tail,
		histogram = hist(incs),
		zeroFrames = zeroAt,
		fractionalFrames = fracAt,
		seconds = os.clock() - t0,
	}
	folder:Destroy()
	return report
end

-- Sleep study: drive one reservoir with a constant small input for many bars and record how often node
-- velocities read exactly zero while displaced, per drive level. args = {drives, bars}
function StepStudy.sleep(ctx, args)
	local Config = require("../Config")
	local Reservoir = require("../Physics/Reservoir")
	local ExplicitRunner = require("../Physics/ExplicitRunner")
	local Projection = require("../Physics/Projection")
	local physics = Config.values.physics
	local out = { allowSleep = settings().Physics.AllowSleep }
	local folder = Instance.new("Folder")
	folder.Name = "MarketReservoirStepStudy"
	folder.Parent = workspace
	local reservoirs = {}
	for k, d in args.drives do
		reservoirs[k] = Reservoir.build(folder, {
			physics = physics, presetId = "P2", projection = Projection.generate(physics.seed, 24, 14),
			driveDisplacement = d, name = "Sleep" .. k,
		})
	end
	local runner = ExplicitRunner.new(reservoirs, { dt = physics.dt, stepsPerBar = 12, settleSteps = 60, parent = folder })
	local rng = Random.new(3)
	runner:resetSegment()
	local zero = table.create(#reservoirs, 0)
	local perNode = {}
	local stuck = table.create(#reservoirs, 0)
	local maxAbsV = table.create(#reservoirs, 0)
	local prev = {}
	for k = 1, #reservoirs do
		perNode[k] = table.create(24, 0)
	end
	for b = 1, args.bars or 60 do
		local x = table.create(14, 0)
		for j = 1, 14 do
			x[j] = rng:NextNumber(-1.5, 1.5)
		end
		local inputs = {}
		for k = 1, #reservoirs do
			inputs[k] = x
		end
		local states = runner:stepBar(inputs)
		for k, s in states do
			for n = 1, 24 do
				local v = s[24 + n]
				maxAbsV[k] = math.max(maxAbsV[k], math.abs(v * 3 * reservoirs[k].nodes[n].omega))
				if v == 0 then
					zero[k] += 1
					perNode[k][n] += 1
					if prev[k] and prev[k][n] == s[n] then
						stuck[k] += 1 -- same position as the previous bar and zero velocity: frozen
					end
				end
			end
			prev[k] = s
		end
	end
	for k, d in args.drives do
		table.insert(out, { drive = d, zeroVelocityReadings = zero[k], frozenAcrossBars = stuck[k], of = 24 * (args.bars or 60), perNode = perNode[k], maxAbsVelocityStudsPerSecond = maxAbsV[k] })
	end
	out.stats = runner:stats()
	runner:destroy()
	folder:Destroy()
	return out
end

-- Lane equivalence: the same synthetic segments through 1 lane and through `lanes` lanes must give identical
-- states (each segment starts from the same reset). Also reports throughput. args = {lanes, segments, perLane}
function StepStudy.lanes(ctx, args)
	local PhysicsJob = require("./PhysicsJob")
	local Projection = require("../Physics/Projection")
	local Config = require("../Config")
	local physics = Config.values.physics
	local rng = Random.new(5)
	local rows = {}
	local i = 0
	for s = 1, args.segments or 6 do
		local len = 4 + (s % 5)
		for off = 1, len do
			i += 1
			local x = table.create(14, 0)
			for j = 1, 14 do
				x[j] = rng:NextNumber(-3, 3)
			end
			rows[i] = { i = i, t = 1000000 + i * 3600, seg = s, off = off, x = { O14 = x } }
		end
	end
	local specs = {}
	for _, p in { "P1", "P2", "P3" } do
		for k = 1, (args.perLane or 1) do
			table.insert(specs, { key = "O14:" .. p .. ":" .. k, profileId = "O14", presetId = p, drive = 0.3 })
		end
	end
	local proj = { O14 = Projection.generate(physics.seed, 24, 14) }
	local registry = {}
	local c = { registry = registry }
	local function run(jobId, lanes)
		PhysicsJob.start(c, { jobId = jobId, reservoirs = specs, projections = proj, lanes = lanes })
		local t0 = os.clock()
		local res = PhysicsJob.stepRows(c, { jobId = jobId, rows = rows })
		local secs = os.clock() - t0
		local stopped = PhysicsJob.stop(c, { jobId = jobId })
		return res, secs, stopped
	end
	local function compare(a, b)
		local diffs = {}
		local maxDiff = 0
		for n = 1, #a.rows do
			for key, st in a.rows[n].s do
				local other = b.rows[n].s[key]
				for k = 1, 48 do
					local d = math.abs(st[k] - other[k])
					table.insert(diffs, d)
					maxDiff = math.max(maxDiff, d)
				end
			end
		end
		table.sort(diffs)
		return { max = maxDiff, median = diffs[(#diffs + 1) // 2], p99 = diffs[math.floor(#diffs * 0.99)] }
	end
	local a, secsA, stopA = run("laneA", 1)
	local b, secsB, stopB = run("laneB", args.lanes or 3)
	local b2 = run("laneC", args.lanes or 3)
	local a2 = run("laneD", 1)
	return {
		rows = #rows,
		reservoirsPerLane = #specs,
		oneLane = { seconds = secsA, steps = a.steps, stepsPerSecond = a.steps / secsA, replays = a.segmentReplays, stats = stopA.stats },
		multiLane = { lanes = args.lanes or 3, seconds = secsB, steps = b.steps, stepsPerSecond = b.steps / secsB, replays = b.segmentReplays, stats = stopB.stats },
		sequentialVsLanes = compare(a, b),
		lanesRepeat = compare(b, b2),
		sequentialRepeat = compare(a, a2),
		speedup = secsA / secsB,
	}
end

-- Records per-step metronome increments under the confirm-before-next protocol, without raising.
-- args = {steps, resetEvery (0 = never), withNode (bool), metronomeY}
function StepStudy.trace(ctx, args)
	local folder = Instance.new("Folder")
	folder.Name = "MarketReservoirStepStudy"
	folder.Parent = workspace
	local parts = {}
	if args.withNode then
		local guide = clockPart(folder, 0); guide.Anchored = true; guide.CFrame = CFrame.new(0, 8, 0)
		local anchor = clockPart(folder, 0); anchor.Anchored = true; anchor.CFrame = CFrame.new(-6, 8, 0)
		local node = clockPart(folder, 0); node.CFrame = CFrame.new(0, 8, 0)
		node.CustomPhysicalProperties = PhysicalProperties.new(1, 0.3, 0, 1, 1)
		local ga = Instance.new("Attachment"); ga.Parent = guide
		local na = Instance.new("Attachment"); na.Parent = node
		local aa = Instance.new("Attachment"); aa.Parent = anchor
		local rail = Instance.new("PrismaticConstraint")
		rail.Attachment0 = ga; rail.Attachment1 = na; rail.ActuatorType = Enum.ActuatorType.None
		rail.LimitsEnabled = true; rail.LowerLimit = -3; rail.UpperLimit = 3; rail.Restitution = 0; rail.Parent = node
		local sp = Instance.new("SpringConstraint")
		sp.Attachment0 = aa; sp.Attachment1 = na; sp.FreeLength = 6; sp.Stiffness = 9; sp.Damping = 1.5; sp.MaxForce = 100000; sp.Parent = node
		local vf = Instance.new("VectorForce")
		vf.Attachment0 = na; vf.RelativeTo = Enum.ActuatorRelativeTo.World; vf.ApplyAtCenterOfMass = true
		vf.Force = Vector3.new(9 * 0.6, 0, 0); vf.Parent = node
		table.insert(parts, node)
	end
	local y0 = args.metronomeY or 4000
	local m1 = clockPart(folder, 300); m1.CFrame = CFrame.new(300, y0, 0)
	local m2 = clockPart(folder, -300); m2.CFrame = CFrame.new(-300, y0, 0)
	table.insert(parts, m1)
	table.insert(parts, m2)
	for _ = 1, 20 do
		RunService.Heartbeat:Wait()
	end
	local g = workspace.Gravity * DT
	local function c1() return -m1.AssemblyLinearVelocity.Y / g end
	local function c2() return -m2.AssemblyLinearVelocity.Y / g end
	local incs, anomalies = {}, {}
	local done, dropped = 0, 0
	while done < (args.steps or 120) do
		if args.resetEvery and args.resetEvery > 0 and done % args.resetEvery == 0 then
			for _, m in { m1, m2 } do
				m.CFrame = CFrame.new(m.Position.X, y0, 0)
				m.AssemblyLinearVelocity = Vector3.zero
			end
		end
		local b1, b2 = c1(), c2()
		workspace:StepPhysics(DT, parts)
		RunService.Heartbeat:Wait()
		local i1, i2 = c1() - b1, c2() - b2
		if math.abs(i1) < 1e-6 then
			dropped += 1
		else
			done += 1
			table.insert(incs, i1)
			if math.abs(i1 - 1) > 1e-4 or math.abs(i2 - 1) > 1e-4 then
				table.insert(anomalies, string.format("step %d: %.4f/%.4f vy=%.2f y=%.1f", done, i1, i2, m1.AssemblyLinearVelocity.Y, m1.Position.Y))
			end
		end
	end
	folder:Destroy()
	return { args = args, completed = done, dropped = dropped, anomalies = anomalies, histogram = hist(incs) }
end

-- Confirm-before-next protocol on the real 24-node reservoir plus two independent metronomes.
-- args = {steps, drive}
function StepStudy.confirmed(ctx, args)
	local Config = require("../Config")
	local Reservoir = require("../Physics/Reservoir")
	local Projection = require("../Physics/Projection")
	local physics = Config.values.physics
	local folder = Instance.new("Folder")
	folder.Name = "MarketReservoirStepStudy"
	folder.Parent = workspace
	local r = Reservoir.build(folder, {
		physics = physics, presetId = "P2", projection = Projection.generate(physics.seed, 24, 14),
		driveDisplacement = args.drive or 0.3, name = "StudyReservoir",
	})
	local m1 = clockPart(folder, 300)
	local m2 = clockPart(folder, -300)
	local parts = table.clone(r:movingParts())
	table.insert(parts, m1)
	table.insert(parts, m2)
	local g = workspace.Gravity * DT
	local function c1() return -m1.AssemblyLinearVelocity.Y / g end
	local function c2() return -m2.AssemblyLinearVelocity.Y / g end
	for _ = 1, 5 do
		RunService.Heartbeat:Wait()
	end
	local rng = Random.new(11)
	local x = table.create(14, 0)
	local target = args.steps or 600
	local done, issued, timeouts, disagree = 0, 0, 0, 0
	local incs = {}
	local framesTotal = 0
	local waitHist = {}
	local t0 = os.clock()
	while done < target do
		if done % 12 == 0 then
			for j = 1, 14 do
				x[j] = rng:NextNumber(-2, 2)
			end
			r:drive(x)
			-- keep the metronomes far above FallenPartsDestroyHeight
			for _, m in { m1, m2 } do
				m.CFrame = CFrame.new(m.Position.X, 4000, 0)
				m.AssemblyLinearVelocity = Vector3.zero
			end
		end
		if issued > target * 3 then
			error("StepStudy: too many lost requests")
		end
		local b1, b2 = c1(), c2()
		workspace:StepPhysics(DT, parts)
		issued += 1
		local waited = 0
		local inc1, inc2 = 0, 0
		local lossFrames = args.lossFrames or 6
		repeat
			RunService.Heartbeat:Wait()
			framesTotal += 1
			waited += 1
			inc1, inc2 = c1() - b1, c2() - b2
		until inc1 > 1e-6 or waited >= lossFrames
		waitHist["f" .. waited] = (waitHist["f" .. waited] or 0) + 1
		if inc1 <= 1e-6 then
			timeouts += 1
		else
			done += 1
			table.insert(incs, inc1)
			if math.abs(inc1 - inc2) > 1e-4 then
				disagree += 1
			end
		end
	end
	local seconds = os.clock() - t0
	local nonUnit = {}
	for k, v in incs do
		if math.abs(v - 1) > 1e-4 then
			table.insert(nonUnit, { step = k, inc = v })
		end
	end
	local bars, cleanBars = 0, 0
	for b = 0, math.floor(#incs / 12) - 1 do
		bars += 1
		local clean = true
		for k = b * 12 + 1, b * 12 + 12 do
			if math.abs(incs[k] - 1) > 1e-4 then
				clean = false
			end
		end
		if clean then
			cleanBars += 1
		end
	end
	local diag = r:diagnostics()
	folder:Destroy()
	return {
		diagnostics = diag,
		context = ctx and ctx.context,
		completed = done,
		issued = issued,
		timeouts = timeouts,
		metronomeDisagreements = disagree,
		histogram = hist(incs),
		nonUnit = nonUnit,
		bars = bars,
		cleanBars = cleanBars,
		frames = framesTotal,
		seconds = seconds,
		stepsPerSecond = done / seconds,
		framesWaitedHistogram = waitHist,
	}
end

return StepStudy
