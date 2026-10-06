--!strict
-- Native mechanics only. Construction/reset place bodies; step changes forces and reads the solver.
-- Parameters and units are documented in indicator/engine-report.md.
local RunService = game:GetService("RunService")
local VerifiedStepper = require(script.Parent.VerifiedStepper)

local Engine = {}
Engine.__index = Engine

local DT = 1 / 60
local STEPS_PER_BAR = 12
-- Native study: D=1 retained slow q~0.536 after 40 zero bars; D=8 reduced it to ~0.026.
-- A larger physical signal lowers that native resting-motion floor in normalized units.
-- Keep body size/mass and omega fixed; scale force, travel, and spring length together.
local DISPLACEMENT = 64 -- studs per unit drive; held +1 still has normalized q=+1
local DRIVE_LIMIT = 2
local RAIL_LIMIT = 3.5 * DISPLACEMENT
local ANCHOR_OFFSET = 8 * DISPLACEMENT
-- Only the directional vote ignores native resting residue. Measured q/v stay untouched.
local SIGN_DEADBAND = 0.005 -- normalized units; both D=64 native tails measured below this floor
local CHANNELS = {
	{ name = "Fast", omega = 5, color = Color3.fromRGB(72, 214, 169) },
	{ name = "Medium", omega = 2.5, color = Color3.fromRGB(255, 194, 95) },
	{ name = "Slow", omega = 1.25, color = Color3.fromRGB(105, 160, 255) },
}

export type Options = { name: string?, origin: Vector3? }
export type State = {
	fast: number, medium: number, slow: number,
	velocity: number, energy: number, agreement: number,
}

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function sign(value: number): number
	return if math.abs(value) <= SIGN_DEADBAND then 0 else math.sign(value)
end

local function makePart(name: string, position: Vector3, size: Vector3, anchored: boolean, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Anchored = anchored
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function attach(name: string, parent: Instance): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Axis = Vector3.xAxis
	attachment.SecondaryAxis = Vector3.yAxis
	attachment.Parent = parent
	return attachment
end

-- This adapter supplies the unchanged verified runner's reservoir contract.
-- No state integration, tween, servo, or motor belongs in this adapter.
local Rig = {}
Rig.__index = Rig

function Rig:movingParts(): { BasePart }
	return self.parts
end

function Rig:reset()
	for _, node in self.nodes do
		node.force.Force = Vector3.zero
		node.part.CFrame = CFrame.new(node.rest)
		node.part.AssemblyLinearVelocity = Vector3.zero
		node.part.AssemblyAngularVelocity = Vector3.zero
	end
	self.lastDrive = 0
end

function Rig:drive(input: { number })
	assert(#input == 1 and finite(input[1]), "Engine: expected one finite signed drive")
	self.lastDrive = math.clamp(input[1], -DRIVE_LIMIT, DRIVE_LIMIT)
	for _, node in self.nodes do
		node.force.Force = Vector3.new(node.k * DISPLACEMENT * self.lastDrive, 0, 0)
	end
end

function Rig:read(): { number }
	local state = table.create(6, 0)
	for i, node in self.nodes do
		state[i] = (node.part.Position.X - node.rest.X) / DISPLACEMENT
		state[3 + i] = node.part.AssemblyLinearVelocity.X / (DISPLACEMENT * node.omega)
		assert(finite(state[i]) and finite(state[3 + i]), "Engine: non-finite native state")
	end
	return state
end

function Engine.new(parent: Instance, options: Options?): any
	assert(not RunService:IsRunning(), "Engine: native indicator requires Studio Edit mode")
	assert(typeof(parent) == "Instance" and (parent == workspace or parent:IsDescendantOf(workspace)),
		"Engine: parent must be beneath Workspace")
	local ancestor: Instance? = parent
	while ancestor and ancestor ~= workspace do
		assert(not ancestor:IsA("WorldModel"), "Engine: WorldModel stepping is not supported")
		ancestor = ancestor.Parent
	end
	assert(finite(workspace.Gravity) and workspace.Gravity > 0, "Engine: metronomes require positive Workspace gravity")
	local opts = options or {}
	local origin = opts.origin or Vector3.new(0, 60, 300)
	assert(typeof(origin) == "Vector3" and finite(origin.X) and finite(origin.Y) and finite(origin.Z),
		"Engine: origin must be a finite Vector3")
	local model = Instance.new("Model")
	model.Name = opts.name or "RoAlgoNativeIndicator"
	model:SetAttribute("NativeIndicator", true)
	model:SetAttribute("Integrator", "Roblox StepPhysics; two metronomes")
	model:SetAttribute("SecondsPerBar", DT * STEPS_PER_BAR)
	model:SetAttribute("DisplacementStudsPerDrive", DISPLACEMENT)
	model:SetAttribute("DriveLimit", DRIVE_LIMIT)
	local nodes: { any } = {}
	local parts: { BasePart } = {}
	local ok, buildError = pcall(function()
		for index, channel in CHANNELS do
			local rest = origin + Vector3.new(0, (3 - index) * 5, 0)
			local group = Instance.new("Model")
			group.Name = channel.name
			group.Parent = model
			local guide = makePart("PassiveRailGuide", rest, Vector3.new(2 * RAIL_LIMIT, 0.18, 0.18), true, group)
			guide.Color = Color3.fromRGB(66, 77, 96)
			guide.Transparency = 0.4
			local anchor = makePart("FixedSpringAnchor", rest - Vector3.new(ANCHOR_OFFSET, 0, 0), Vector3.one, true, group)
			anchor.Color = channel.color
			local part = makePart(channel.name .. "Mass", rest, Vector3.new(1.5, 1.5, 1.5), false, group)
			part.Color = channel.color
			part.CustomPhysicalProperties = PhysicalProperties.new(1, 0.3, 0, 1, 1)
			part:SetAttribute("Channel", string.lower(channel.name))
			part:SetAttribute("OmegaRadiansPerSecond", channel.omega)
			part:SetAttribute("DampingRatio", 1)
			local centerAttachment = attach("Center", part)
			local guideAttachment = attach("GuideAxis", guide)
			local anchorAttachment = attach("SpringAnchor", anchor)

			local rail = Instance.new("PrismaticConstraint")
			rail.Name = "PassiveXAxisRail"
			rail.Attachment0 = guideAttachment
			rail.Attachment1 = centerAttachment
			rail.ActuatorType = Enum.ActuatorType.None
			rail.LimitsEnabled = true
			rail.LowerLimit = -RAIL_LIMIT
			rail.UpperLimit = RAIL_LIMIT
			rail.Restitution = 0
			rail.Visible = false
			rail.Parent = part

			local spring = Instance.new("SpringConstraint")
			spring.Name = "NativeCriticallyDampedSpring"
			spring.Attachment0 = anchorAttachment
			spring.Attachment1 = centerAttachment
			spring.FreeLength = ANCHOR_OFFSET
			spring.MaxForce = 1e6
			spring.Coils = 8
			spring.Radius = 0.3
			spring.Thickness = 0.08
			spring.Visible = true
			spring.Parent = part

			local force = Instance.new("VectorForce")
			force.Name = "SignedMarketDrive"
			force.Attachment0 = centerAttachment
			force.RelativeTo = Enum.ActuatorRelativeTo.World
			force.ApplyAtCenterOfMass = true
			force.Force = Vector3.zero
			force.Parent = part
			table.insert(nodes, {
				name = channel.name, part = part, rest = rest, guide = guide, anchor = anchor,
				rail = rail, spring = spring, force = force, omega = channel.omega, mass = 0, k = 0, c = 0,
			})
			table.insert(parts, part)
		end
		model.Parent = parent
		for _, node in nodes do
			node.mass = node.part.AssemblyMass
			assert(finite(node.mass) and node.mass > 0, "Engine: invalid native assembly mass")
			node.k = node.mass * node.omega * node.omega
			node.c = 2 * node.mass * node.omega
			node.spring.Stiffness = node.k
			node.spring.Damping = node.c
			node.part:SetAttribute("MeasuredMass", node.mass)
			node.part:SetAttribute("SpringStiffness", node.k)
			node.part:SetAttribute("SpringDamping", node.c)
		end
	end)
	if not ok then
		model:Destroy()
		error(tostring(buildError), 2)
	end
	local rig = setmetatable({ model = model, nodes = nodes, parts = parts, lastDrive = 0 }, Rig)
	local runner = VerifiedStepper.new({ rig }, {
		dt = DT, stepsPerBar = STEPS_PER_BAR, settleSteps = 0, parent = model,
	})
	local self = setmetatable({
		model = model, rig = rig, runner = runner, destroyed = false, busy = false,
		fault = nil, failedBars = 0, clippedInputs = 0,
		maxAbsX = 0, maxOffAxis = 0, saturationObservations = 0,
	}, Engine)
	self:reset()
	return self
end

function Engine:reset()
	assert(not self.destroyed, "Engine: destroyed")
	assert(not self.busy, "Engine: cannot reset during a bar")
	self.runner:recover()
	self.runner:resetSegment()
	self.fault = nil
end

function Engine:step(drive: number): State
	assert(not self.destroyed, "Engine: destroyed")
	assert(not self.busy, "Engine: concurrent steps are not permitted")
	assert(not self.fault, "Engine: reset and replay the segment after a failed native step")
	assert(finite(drive), "Engine: drive must be a finite number")
	if math.abs(drive) > DRIVE_LIMIT then self.clippedInputs += 1 end
	self.busy = true
	local ok, value = pcall(function()
		local values = self.runner:stepBar({ { drive } })[1]
		local energy = 0
		local agreement = 0
		for i, node in self.rig.nodes do
			energy += 0.5 * (values[i] * values[i] + values[3 + i] * values[3 + i]) / 3
			agreement += sign(values[i]) / 3
			local delta = node.part.Position - node.rest
			self.maxAbsX = math.max(self.maxAbsX, math.abs(delta.X))
			self.maxOffAxis = math.max(self.maxOffAxis, math.abs(delta.Y), math.abs(delta.Z))
			if math.abs(delta.X) >= RAIL_LIMIT - 0.01 then self.saturationObservations += 1 end
		end
		return { fast = values[1], medium = values[2], slow = values[3],
			velocity = values[4], energy = energy, agreement = agreement }
	end)
	self.busy = false
	if not ok then
		self.failedBars += 1
		self.fault = tostring(value)
		self.rig:drive({ 0 })
		error(value, 2)
	end
	return value :: State
end

function Engine:stats(): any
	local stats = self.runner:stats()
	local counts = { nodes = 0, springs = 0, rails = 0, forces = 0, metronomes = 0 }
	local saturatedNodes = 0
	local parameters = {}
	for _, node in self.rig.nodes do
		if node.part.Parent then counts.nodes += 1 end
		if node.spring.Parent then counts.springs += 1 end
		if node.rail.Parent then counts.rails += 1 end
		if node.force.Parent then counts.forces += 1 end
		if math.abs(node.part.Position.X - node.rest.X) >= RAIL_LIMIT - 0.01 then saturatedNodes += 1 end
		table.insert(parameters, { name = node.name, mass = node.mass, omega = node.omega, zeta = 1,
			stiffness = node.k, damping = node.c })
	end
	for _, metronome in self.runner.metronomes do
		if metronome.Parent then counts.metronomes += 1 end
	end
	stats.counts = counts
	stats.parameters = parameters
	stats.dt = DT
	stats.stepsPerBar = STEPS_PER_BAR
	stats.secondsPerBar = DT * STEPS_PER_BAR
	stats.displacementStudsPerDrive = DISPLACEMENT
	stats.driveLimit = DRIVE_LIMIT
	stats.railLimitStuds = RAIL_LIMIT
	stats.lastDrive = self.rig.lastDrive
	stats.maxAbsX = self.maxAbsX
	stats.maxOffAxis = self.maxOffAxis
	stats.saturatedNodes = saturatedNodes
	stats.saturationObservations = self.saturationObservations
	stats.clippedInputs = self.clippedInputs
	stats.failedBars = self.failedBars
	stats.fault = self.fault
	stats.destroyed = self.destroyed
	return stats
end

function Engine:destroy()
	if self.destroyed then return end
	assert(not self.busy, "Engine: finish the active bar before destruction")
	self.destroyed = true
	self.runner:destroy()
	self.model:Destroy()
end

return Engine
