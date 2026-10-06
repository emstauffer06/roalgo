--!strict
-- PROVENANCE: copied from lab/src/Physics/ExplicitRunner.luau on 2026-10-05.
-- The original implementation below is unchanged. See docs/stepping-capability.md for evidence.
-- Explicit native stepping (plan section 4, Task 3). ENGINE CODE: Studio only, Edit mode.
--
-- One market observation = drive held constant for exactly stepsPerBar completed StepPhysics(dt, parts) steps.
--
-- Measured behaviour of WorldRoot:StepPhysics in Studio 0.741 (see docs/stepping-capability.md): the call
-- returns immediately and the step is applied by the engine on the next frame; roughly one request in
-- eight is dropped; bursts of several calls per frame lose steps and occasionally apply fractional
-- (1/240 s) extra sub-steps. This runner therefore uses a verified protocol:
--   * two free-falling metronome parts ride in every call; their velocity change measures completed steps,
--   * exactly one request is outstanding at a time; the next is issued only after the previous one is
--     confirmed as exactly one dt on both metronomes,
--   * a request not applied by the next frame was dropped (never observed late) and is re-issued,
--   * any non-unit or disagreeing increment raises ExplicitRunner.CORRUPT; callers replay the segment.
-- If a future engine applies steps synchronously, the increment is seen immediately and no frame is waited.

local RunService = game:GetService("RunService")

local ExplicitRunner = {}
ExplicitRunner.__index = ExplicitRunner
ExplicitRunner.CORRUPT = "ExplicitRunner: CORRUPT_STEP"

export type Stepper = (dt: number, parts: { BasePart }) -> ()

export type RunnerOptions = {
	dt: number,
	stepsPerBar: number,
	settleSteps: number,
	stepper: Stepper?, -- injectable for scheduling tests; default workspace:StepPhysics
	waitFrame: (() -> ())?, -- injectable; default RunService.Heartbeat:Wait()
	metronome: boolean?, -- default true; false only for scheduling tests with a recording stepper
	parent: Instance?,
	lossFrames: number?, -- frames to wait before treating a request as dropped (default 1)
	maxReissues: number?, -- per step (default 30)
	warmupFrames: number?, -- frames to wait after construction before the first step (default 20)
}

local TOL = 1e-4
-- The metronomes are re-launched every METRONOME_SPAN completed steps: a free-falling part that gets
-- fast (about 50 studs/s and above) is moved by the engine's adaptive timestepping to a different rate
-- and then shows 1.25-1.5 dt increments that are about the metronome, not the reservoir (measured).
local METRONOME_SPAN = 12

local function defaultStepper(dt: number, parts: { BasePart })
	workspace:StepPhysics(dt, parts)
end

local function defaultWait()
	RunService.Heartbeat:Wait()
end

local function newMetronome(name: string, x: number, parent: Instance): BasePart
	local m = Instance.new("Part")
	m.Name = name
	-- Large on purpose: the engine's adaptive timestepping reacts to speed relative to part size, and a
	-- 0.5-stud metronome already showed fractional increments at ~36 studs/s (measured); 8 studs keeps
	-- the 12-step span (max ~39 studs/s) far below that regime.
	m.Size = Vector3.new(8, 8, 8)
	m.Anchored = false
	m.CanCollide = false
	m.CanTouch = false
	m.CanQuery = false
	m.Transparency = 1
	m.CFrame = CFrame.new(x, 5000, -500)
	m.Parent = parent
	return m
end

function ExplicitRunner.new(reservoirs: { any }, options: RunnerOptions)
	assert(not RunService:IsRunning(), "ExplicitRunner: the offline lab requires Edit mode")
	assert(math.abs(options.dt - 1 / 60) < 1e-15, "ExplicitRunner: frozen dt is 1/60")
	assert(options.stepsPerBar == 12, "ExplicitRunner: frozen version uses 12 steps per bar")
	local parts: { BasePart } = {}
	for _, r in reservoirs do
		for _, p in r:movingParts() do
			table.insert(parts, p)
		end
	end
	local self = setmetatable({
		reservoirs = reservoirs,
		options = options,
		stepper = options.stepper or defaultStepper,
		waitFrame = options.waitFrame or defaultWait,
		parts = parts,
		metronomes = {} :: { BasePart },
		gravityStep = workspace.Gravity * options.dt,
		lossFrames = options.lossFrames or 1,
		maxReissues = options.maxReissues or 30,
		warmupFrames = options.warmupFrames or 20,
		warmedUp = false,
		launched = false,
		sinceLaunch = 0,
		totalSteps = 0,
		totalBars = 0,
		settleCount = 0,
		requests = 0,
		dropped = 0,
		framesWaited = 0,
		corrupt = 0,
	}, ExplicitRunner)
	if options.metronome ~= false then
		local parent = options.parent or reservoirs[1].model
		self.metronomes = { newMetronome("MetronomeA", -400, parent), newMetronome("MetronomeB", 400, parent) }
		for _, m in self.metronomes do
			table.insert(parts, m)
		end
	end
	return self
end

function ExplicitRunner:_resetMetronomes()
	for _, m in self.metronomes do
		m.CFrame = CFrame.new(m.Position.X, 5000, -500)
		m.AssemblyLinearVelocity = Vector3.zero
		m.AssemblyAngularVelocity = Vector3.zero
	end
end

function ExplicitRunner:_counts(): (number, number)
	local a, b = self.metronomes[1], self.metronomes[2]
	return -a.AssemblyLinearVelocity.Y / self.gravityStep, -b.AssemblyLinearVelocity.Y / self.gravityStep
end

-- Performs exactly one verified step of dt over every moving part (all reservoirs and both metronomes).
-- After a CORRUPT_STEP the metronome velocities no longer match the confirmed count; the next step must
-- re-launch them without the span check, so a replayed segment starts from clean bookkeeping.
function ExplicitRunner:recover()
	self.launched = false
	self.sinceLaunch = METRONOME_SPAN
end

local function corrupt(self: any, message: string)
	self.corrupt += 1
	self:recover()
	error(message, 3)
end

function ExplicitRunner:stepOnce()
	local dt = self.options.dt
	if #self.metronomes == 0 then
		if self.options.metronome ~= false then
			error("ExplicitRunner: metronomes are gone (runner destroyed?); refusing to step unverified", 2)
		end
		self.stepper(dt, self.parts)
		self.totalSteps += 1
		return
	end
	if not self.warmedUp then
		-- Newly created assemblies join the engine's world over the next frames; let construction settle.
		for _ = 1, self.warmupFrames do
			self.waitFrame()
		end
		self.warmedUp = true
		self.sinceLaunch = METRONOME_SPAN
	end
	if self.sinceLaunch >= METRONOME_SPAN then
		-- span check before re-launch: cumulative count equals the steps confirmed since the last launch
		if self.sinceLaunch > 0 and self.launched then
			local f1, f2 = self:_counts()
			if math.abs(f1 - self.sinceLaunch) > TOL * 12 or math.abs(f2 - self.sinceLaunch) > TOL * 12 then
				corrupt(self, string.format("%s cumulative %.5f / %.5f for %d steps", ExplicitRunner.CORRUPT, f1, f2, self.sinceLaunch))
			end
		end
		self:_resetMetronomes()
		self.launched = true
		self.sinceLaunch = 0
	end
	local base1, base2 = self:_counts()
	local reissues = 0
	while true do
		self.stepper(dt, self.parts)
		self.requests += 1
		local c1, c2 = self:_counts()
		local waited = 0
		while c1 - base1 < 1 - TOL and waited < self.lossFrames do
			self.waitFrame()
			waited += 1
			self.framesWaited += 1
			c1, c2 = self:_counts()
		end
		local inc1, inc2 = c1 - base1, c2 - base2
		if math.abs(inc1) < TOL and math.abs(inc2) < TOL then
			-- dropped request: re-issue
			self.dropped += 1
			reissues += 1
			if reissues > self.maxReissues then
				error(string.format("ExplicitRunner: step not applied after %d requests", reissues), 2)
			end
			continue
		end
		if math.abs(inc1 - 1) > TOL or math.abs(inc2 - 1) > TOL then
			corrupt(self, string.format("%s increments %.5f / %.5f", ExplicitRunner.CORRUPT, inc1, inc2))
		end
		self.totalSteps += 1
		self.sinceLaunch += 1
		return
	end
end

-- Performs exactly n verified steps of dt over every moving part.
function ExplicitRunner:_steps(n: number)
	for _ = 1, n do
		self:stepOnce()
	end
end

-- Segment start: clear drive, return to equilibrium, settle with zero input.
function ExplicitRunner:resetSegment()
	for _, r in self.reservoirs do
		r:reset()
	end
	self:_steps(self.options.settleSteps)
	self.settleCount += 1
end

-- inputs[i] is the transformed input vector for reservoirs[i]. Returns the 48-value state of each.
function ExplicitRunner:stepBar(inputs: { { number } }): { { number } }
	assert(#inputs == #self.reservoirs, "ExplicitRunner: one input per reservoir")
	for i, r in self.reservoirs do
		r:drive(inputs[i])
	end
	self:_steps(self.options.stepsPerBar)
	self.totalBars += 1
	local states = table.create(#self.reservoirs)
	for i, r in self.reservoirs do
		states[i] = r:read()
	end
	return states
end

function ExplicitRunner:stats()
	return {
		totalSteps = self.totalSteps,
		totalBars = self.totalBars,
		settles = self.settleCount,
		requests = self.requests,
		droppedRequests = self.dropped,
		framesWaited = self.framesWaited,
		corruptSteps = self.corrupt,
		stepFailures = self.corrupt,
		parts = #self.parts,
		lossFrames = self.lossFrames,
	}
end

function ExplicitRunner:destroy()
	for _, m in self.metronomes do
		m:Destroy()
	end
	table.clear(self.metronomes)
end

return ExplicitRunner
