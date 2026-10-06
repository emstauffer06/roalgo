--!strict
-- Capability probe for WorldRoot:StepPhysics in the current execution context (plan Task 3, section 11).
-- ENGINE CODE. Creates only temporary parts under Workspace.MarketReservoirProbe and removes them.
-- Reports whether each StepPhysics call completes synchronously, and if so runs the Task 3 mechanics probes.

local RunService = game:GetService("RunService")
local Reservoir = require("../Physics/Reservoir")
local ExplicitRunner = require("../Physics/ExplicitRunner")
local Projection = require("../Physics/Projection")
local Config = require("../Config")

local SteppingProbe = {}

local DT = 1 / 60

local function newPart(name: string, pos: Vector3, parent: Instance, anchored: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.new(1, 1, 1)
	p.CFrame = CFrame.new(pos)
	p.Anchored = anchored
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.Parent = parent
	return p
end

local function frames(n: number)
	for _ = 1, n do
		RunService.Heartbeat:Wait()
	end
end

-- Verified stepping for ad-hoc probe bodies: wraps them as a pseudo reservoir for ExplicitRunner.
local function verifiedStepper(root: Instance, parts: { BasePart })
	local pseudo = { model = root, movingParts = function() return parts end }
	local runner = ExplicitRunner.new({ pseudo }, {
		dt = DT,
		stepsPerBar = 12,
		settleSteps = 60,
		parent = root,
	})
	return function(n: number)
		runner:_steps(n)
	end, runner
end

-- Sync test: are completed steps visible immediately after each call?
local function syncTest(root: Instance)
	local g = workspace.Gravity * DT
	local clock = newPart("Clock", Vector3.new(200, 4000, 0), root, false)
	frames(3)
	local seq = {}
	for _ = 1, 12 do
		workspace:StepPhysics(DT, { clock })
		table.insert(seq, -clock.AssemblyLinearVelocity.Y / g)
	end
	local immediate = seq[#seq]
	frames(30)
	local settled = -clock.AssemblyLinearVelocity.Y / g
	clock:Destroy()
	local exact = true
	for i, v in seq do
		if math.abs(v - i) > 1e-3 then
			exact = false
		end
	end
	return { synchronousExact = exact, immediateAfter12 = immediate, settledAfter30Frames = settled, sequence = seq }
end

-- Task 3 one-node probe: passive rail + native spring + VectorForce.
local function oneNode(root: Instance)
	local guide = newPart("Guide", Vector3.new(0, 8, 0), root, true)
	local anchor = newPart("Anchor", Vector3.new(-6, 8, 0), root, true)
	local node = newPart("Node", Vector3.new(0, 8, 0), root, false)
	node.CustomPhysicalProperties = PhysicalProperties.new(1, 0.3, 0, 1, 1)
	local ga = Instance.new("Attachment"); ga.Parent = guide
	local na = Instance.new("Attachment"); na.Parent = node
	local aa = Instance.new("Attachment"); aa.Parent = anchor
	local rail = Instance.new("PrismaticConstraint")
	rail.Attachment0 = ga; rail.Attachment1 = na
	rail.ActuatorType = Enum.ActuatorType.None
	rail.LimitsEnabled = true; rail.LowerLimit = -3; rail.UpperLimit = 3; rail.Restitution = 0
	rail.Parent = node
	local mass = node.AssemblyMass
	local omega, zeta = 3, 0.25
	local spring = Instance.new("SpringConstraint")
	spring.Attachment0 = aa; spring.Attachment1 = na
	spring.FreeLength = 6; spring.Stiffness = mass * omega * omega; spring.Damping = 2 * zeta * mass * omega
	spring.MaxForce = 100000
	spring.Parent = node
	local vf = Instance.new("VectorForce")
	vf.Attachment0 = na; vf.RelativeTo = Enum.ActuatorRelativeTo.World; vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.new(spring.Stiffness * 0.6, 0, 0)
	vf.Parent = node
	frames(2)
	local step, runner = verifiedStepper(root, { node })
	step(60)
	local drivenX = node.Position.X
	local offAxis = math.max(math.abs(node.Position.Y - 8), math.abs(node.Position.Z))
	vf.Force = Vector3.zero
	local function energy()
		local x = node.Position.X
		local v = node.AssemblyLinearVelocity.X
		return v * v + omega * omega * x * x
	end
	local first, last = 0, 0
	for s = 1, 600 do
		step(1)
		if s <= 60 then first += energy() elseif s > 540 then last += energy() end
	end
	local stats = runner:stats()
	runner:destroy()
	return {
		mass = mass,
		drivenX = drivenX,
		expectedStaticX = 0.6,
		offAxis = offAxis,
		energyFirstSecond = first / 60,
		energyLastSecond = last / 60,
		moved = math.abs(drivenX) > 1e-3,
		constrained = offAxis < 1e-3,
		decays = (last / 60) < (first / 60),
		stepStats = stats,
	}
end

-- Task 3 two-node probe: drive only node 1; node 2 must respond through a native coupling spring.
local function twoNode(root: Instance)
	local made = {}
	for i = 1, 2 do
		local z = (i - 1) * 4
		local guide = newPart("Guide" .. i, Vector3.new(0, 8, z), root, true)
		local anchor = newPart("Anchor" .. i, Vector3.new(-6, 8, z), root, true)
		local node = newPart("Node" .. i, Vector3.new(0, 8, z), root, false)
		node.CustomPhysicalProperties = PhysicalProperties.new(1, 0.3, 0, 1, 1)
		local ga = Instance.new("Attachment"); ga.Parent = guide
		local na = Instance.new("Attachment"); na.Parent = node
		local aa = Instance.new("Attachment"); aa.Parent = anchor
		local rail = Instance.new("PrismaticConstraint")
		rail.Attachment0 = ga; rail.Attachment1 = na; rail.ActuatorType = Enum.ActuatorType.None
		rail.LimitsEnabled = true; rail.LowerLimit = -3; rail.UpperLimit = 3; rail.Restitution = 0
		rail.Parent = node
		local spring = Instance.new("SpringConstraint")
		spring.Attachment0 = aa; spring.Attachment1 = na; spring.FreeLength = 6
		spring.Stiffness = node.AssemblyMass * 9; spring.Damping = 2 * 0.25 * node.AssemblyMass * 3; spring.MaxForce = 100000
		spring.Parent = node
		made[i] = { node = node, att = na, k = spring.Stiffness }
	end
	local c = Instance.new("SpringConstraint")
	c.Attachment0 = made[1].att; c.Attachment1 = made[2].att; c.FreeLength = 3
	c.Stiffness = 0.15 * made[1].k; c.Damping = 0.05; c.MaxForce = 100000
	c.Parent = root
	local vf = Instance.new("VectorForce")
	vf.Attachment0 = made[1].att; vf.RelativeTo = Enum.ActuatorRelativeTo.World; vf.ApplyAtCenterOfMass = true
	vf.Force = Vector3.new(made[1].k * 0.6, 0, 0)
	vf.Parent = made[1].node
	frames(2)
	local step, runner = verifiedStepper(root, { made[1].node, made[2].node })
	step(120)
	runner:destroy()
	return { x1 = made[1].node.Position.X, x2 = made[2].node.Position.X, secondResponds = math.abs(made[2].node.Position.X) > 1e-4 }
end

local function reservoirProbe(root: Instance, bars: number)
	local cfg = Config.values
	local projection = Projection.generate(cfg.physics.seed, cfg.physics.nodeCount, 14)
	local r = Reservoir.build(root, {
		physics = cfg.physics,
		presetId = "P2",
		projection = projection,
		driveDisplacement = 0.3,
		name = "ProbeReservoir",
	})
	frames(2)
	local counts = r:counts()
	local runner = ExplicitRunner.new({ r }, {
		dt = cfg.physics.dt,
		stepsPerBar = cfg.physics.stepsPerBar,
		settleSteps = cfg.physics.settleSteps,
	})
	local rng = Random.new(7)
	local inputs = {}
	for b = 1, bars do
		local v = table.create(14, 0)
		for j = 1, 14 do
			v[j] = rng:NextNumber(-2, 2)
		end
		inputs[b] = v
	end
	runner:resetSegment()
	local t0 = os.clock()
	local first, last
	for b = 1, bars do
		local s = runner:stepBar({ inputs[b] })[1]
		if b == 1 then first = s end
		last = s
	end
	local elapsed = os.clock() - t0
	local diag = r:diagnostics()
	-- repeat the first 20 bars after a soft reset and compare
	runner:resetSegment()
	local again
	local maxDiff = 0
	local firstRun = {}
	runner:resetSegment()
	for b = 1, 20 do
		firstRun[b] = runner:stepBar({ inputs[b] })[1]
	end
	runner:resetSegment()
	for b = 1, 20 do
		again = runner:stepBar({ inputs[b] })[1]
		for k = 1, #again do
			maxDiff = math.max(maxDiff, math.abs(again[k] - firstRun[b][k]))
		end
	end
	local stats = runner:stats()
	runner:destroy()
	r:destroy()
	return {
		counts = counts,
		bars = bars,
		seconds = elapsed,
		barsPerSecond = bars / elapsed,
		firstStateSample = { first[1], first[25] },
		lastStateSample = { last[1], last[25] },
		diagnostics = diag,
		softResetRepeatMaxAbsDiff = maxDiff,
		runnerStats = stats,
	}
end

function SteppingProbe.run(contextLabel: string, opts: { bars: number? }?)
	assert(not RunService:IsRunning(), "SteppingProbe: Edit mode only")
	local report: { [string]: any } = { context = contextLabel, studioVersion = version(), placeId = game.PlaceId }
	local root = Instance.new("Folder")
	root.Name = "MarketReservoirProbe"
	root.Parent = workspace
	local ok, err = pcall(function()
		-- Mechanics probes use the verified (metronome-confirmed) stepping protocol.
		report.oneNode = oneNode(root)
		root:ClearAllChildren()
		report.twoNode = twoNode(root)
		root:ClearAllChildren()
		report.reservoir = reservoirProbe(root, (opts and opts.bars) or 200)
		root:ClearAllChildren()
		-- The burst-semantics test runs last: a burst of calls leaves queued simulation time behind that
		-- can surface as a fractional extra step on a later request (measured), so it must never precede
		-- verified stepping. It is skipped unless explicitly requested.
		if opts and opts.burstTest then
			report.sync = syncTest(root)
			frames(60)
		end
	end)
	root:Destroy()
	if not ok then
		report.error = tostring(err)
	end
	return report
end

function SteppingProbe.fromPlugin(ctx: any, args: any)
	return SteppingProbe.run((ctx and ctx.context) or "plugin", args)
end

return SteppingProbe
