--!strict
-- Native mechanical reservoir (plan section 4). ENGINE CODE: Studio only.
-- Builds 24 nodes on passive prismatic rails with native axial springs, 38 native coupling springs and one
-- VectorForce per node. Luau only sets forces and reads measurements; Roblox's solver moves the bodies.
-- Only build() and reset() may set node transforms or velocities.

local Reservoir = {}
Reservoir.__index = Reservoir

export type Node = {
	index: number,
	row: number, -- 0..3
	column: number, -- 0..5
	part: BasePart,
	guide: BasePart,
	anchor: BasePart,
	attachment: Attachment,
	rail: PrismaticConstraint,
	axial: SpringConstraint,
	force: VectorForce,
	rest: Vector3,
	mass: number,
	omega: number,
	zeta: number,
	k: number,
	c: number,
}

export type ReservoirConfig = {
	physics: any, -- Config.values.physics
	presetId: string, -- "P1" | "P2" | "P3"
	projection: { { number } }, -- 24 x D, rows unit norm
	driveDisplacement: number, -- studs
	name: string?,
	origin: Vector3?, -- world offset for side-by-side reservoirs
	visual: boolean?, -- colour nodes by drive (presentation only; never read back)
}

export type Reservoir = typeof(setmetatable(
	{} :: {
		config: ReservoirConfig,
		model: Model,
		nodes: { Node },
		couplings: { SpringConstraint },
		parts: { BasePart },
		dimension: number,
		invSqrtD: number,
		lastQ: { number },
	},
	Reservoir
))

local function makePart(name: string, position: Vector3, size: number, anchored: boolean, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = Vector3.new(size, size, size)
	p.CFrame = CFrame.new(position)
	p.Anchored = anchored
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

function Reservoir.build(parent: Instance, config: ReservoirConfig): Reservoir
	local phys = config.physics
	local multiplier = phys.presets[config.presetId]
	assert(type(multiplier) == "number", "Reservoir: unknown preset " .. tostring(config.presetId))
	local nodeCount = phys.rows * phys.columns
	assert(#config.projection == nodeCount, "Reservoir: projection must have one row per node")
	local dimension = #config.projection[1]
	for i = 1, nodeCount do
		assert(#config.projection[i] == dimension, "Reservoir: ragged projection")
	end
	assert(config.driveDisplacement > 0, "Reservoir: drive displacement must be positive")

	local origin = config.origin or Vector3.zero
	local model = Instance.new("Model")
	model.Name = config.name or "MarketReservoirLab"
	model:SetAttribute("PresetId", config.presetId)
	model:SetAttribute("Dimension", dimension)
	model:SetAttribute("DriveDisplacement", config.driveDisplacement)
	local nodesFolder = Instance.new("Folder")
	nodesFolder.Name = "Nodes"
	nodesFolder.Parent = model
	local fixedFolder = Instance.new("Folder")
	fixedFolder.Name = "Fixed"
	fixedFolder.Parent = model
	local couplingFolder = Instance.new("Folder")
	couplingFolder.Name = "Couplings"
	couplingFolder.Parent = model

	local nodes: { Node } = {}
	local parts: { BasePart } = {}
	for row = 0, phys.rows - 1 do
		for column = 0, phys.columns - 1 do
			local i = row * phys.columns + column + 1
			local rest = origin + Vector3.new(0, phys.baseHeight + row * phys.rowSpacing, column * phys.columnSpacing)
			local guide = makePart(string.format("Guide%02d", i), rest, phys.nodeSize * 0.6, true, fixedFolder)
			guide.Transparency = 0.85
			local anchor = makePart(
				string.format("SpringAnchor%02d", i),
				rest - Vector3.new(phys.axialAnchorOffset, 0, 0),
				phys.nodeSize * 0.5,
				true,
				fixedFolder
			)
			anchor.Transparency = 0.6
			local node = makePart(string.format("Node%02d", i), rest, phys.nodeSize, false, nodesFolder)
			node.Material = Enum.Material.SmoothPlastic
			-- density 1 per the plan; friction/elasticity are irrelevant (no collisions)
			node.CustomPhysicalProperties = PhysicalProperties.new(1, 0.3, 0, 1, 1)
			node:SetAttribute("NodeIndex", i)

			local guideAtt = Instance.new("Attachment")
			guideAtt.Name = "RailGuide"
			guideAtt.Parent = guide -- default orientation: Axis = +X, SecondaryAxis = +Y
			local nodeAtt = Instance.new("Attachment")
			nodeAtt.Name = "Center"
			nodeAtt.Parent = node
			local anchorAtt = Instance.new("Attachment")
			anchorAtt.Name = "AxialAnchor"
			anchorAtt.Parent = anchor

			local rail = Instance.new("PrismaticConstraint")
			rail.Name = "Rail"
			rail.Attachment0 = guideAtt
			rail.Attachment1 = nodeAtt
			rail.ActuatorType = Enum.ActuatorType.None
			rail.LimitsEnabled = true
			rail.LowerLimit = -phys.railLimit
			rail.UpperLimit = phys.railLimit
			rail.Restitution = 0
			rail.Visible = false
			rail.Parent = node

			local force = Instance.new("VectorForce")
			force.Name = "Drive"
			force.Attachment0 = nodeAtt
			force.RelativeTo = Enum.ActuatorRelativeTo.World
			force.ApplyAtCenterOfMass = true
			force.Force = Vector3.zero
			force.Visible = false
			force.Parent = node

			local axial = Instance.new("SpringConstraint")
			axial.Name = "Axial"
			axial.Attachment0 = anchorAtt
			axial.Attachment1 = nodeAtt
			axial.FreeLength = phys.axialFreeLength
			axial.MaxForce = phys.springMaxForce
			axial.Visible = true
			axial.Coils = 6
			axial.Radius = 0.25
			axial.Parent = node

			table.insert(nodes, {
				index = i,
				row = row,
				column = column,
				part = node,
				guide = guide,
				anchor = anchor,
				attachment = nodeAtt,
				rail = rail,
				axial = axial,
				force = force,
				rest = rest,
				mass = 0,
				omega = phys.omegaByColumn[column + 1] * multiplier,
				zeta = phys.zetaByRow[row + 1],
				k = 0,
				c = 0,
			})
			table.insert(parts, node)
		end
	end

	model.Parent = parent

	-- Stiffness and damping from the measured assembly mass (read after construction).
	for _, n in nodes do
		n.mass = n.part.AssemblyMass
		assert(n.mass > 0, "Reservoir: zero assembly mass")
		n.k = n.mass * n.omega * n.omega
		n.c = 2 * n.zeta * n.mass * n.omega
		n.axial.Stiffness = n.k
		n.axial.Damping = n.c
	end

	-- Nearest-neighbour coupling springs: horizontal (same row) then vertical (same column). No diagonals.
	local couplings: { SpringConstraint } = {}
	local function couple(a: Node, b: Node)
		local s = Instance.new("SpringConstraint")
		s.Name = string.format("Couple%02d_%02d", a.index, b.index)
		s.Attachment0 = a.attachment
		s.Attachment1 = b.attachment
		s.FreeLength = phys.couplingFreeLength
		s.Stiffness = phys.couplingStiffnessRatio * math.sqrt(a.k * b.k)
		s.Damping = phys.couplingDampingRatio * math.sqrt(a.c * b.c)
		s.MaxForce = phys.springMaxForce
		s.Visible = true
		s.Coils = 3
		s.Radius = 0.15
		s.Parent = couplingFolder
		table.insert(couplings, s)
	end
	for row = 0, phys.rows - 1 do
		for column = 0, phys.columns - 2 do
			couple(nodes[row * phys.columns + column + 1], nodes[row * phys.columns + column + 2])
		end
	end
	for row = 0, phys.rows - 2 do
		for column = 0, phys.columns - 1 do
			couple(nodes[row * phys.columns + column + 1], nodes[(row + 1) * phys.columns + column + 1])
		end
	end

	local self = setmetatable({
		config = config,
		model = model,
		nodes = nodes,
		couplings = couplings,
		parts = parts,
		dimension = dimension,
		invSqrtD = 1 / math.sqrt(dimension),
		lastQ = table.create(nodeCount, 0),
	}, Reservoir)
	return self
end

function Reservoir.counts(self: Reservoir)
	local rails, axial, forces = 0, 0, 0
	for _, n in self.nodes do
		if n.rail.Parent then rails += 1 end
		if n.axial.Parent then axial += 1 end
		if n.force.Parent then forces += 1 end
	end
	return { nodes = #self.nodes, rails = rails, axial = axial, couplings = #self.couplings, forces = forces }
end

function Reservoir.movingParts(self: Reservoir): { BasePart }
	return self.parts
end

-- Clears forces, returns every node to equilibrium with zero linear and angular velocity.
function Reservoir.reset(self: Reservoir)
	for _, n in self.nodes do
		n.force.Force = Vector3.zero
		n.part.CFrame = CFrame.new(n.rest)
		n.part.AssemblyLinearVelocity = Vector3.zero
		n.part.AssemblyAngularVelocity = Vector3.zero
		self.lastQ[n.index] = 0
	end
end

-- Sets the held drive force for the next interval. input has the profile dimension.
function Reservoir.drive(self: Reservoir, input: { number })
	assert(#input == self.dimension, "Reservoir: input dimension mismatch")
	local disp = self.config.driveDisplacement
	local projection = self.config.projection
	for _, n in self.nodes do
		local row = projection[n.index]
		local q = 0
		for j = 1, self.dimension do
			q += row[j] * input[j]
		end
		q *= self.invSqrtD
		self.lastQ[n.index] = q
		n.force.Force = Vector3.new(n.k * disp * q, 0, 0)
	end
	if self.config.visual then
		for _, n in self.nodes do
			local q = math.clamp(self.lastQ[n.index], -1, 1)
			n.part.Color = if q >= 0
				then Color3.new(1, 1, 1):Lerp(Color3.fromRGB(46, 160, 67), q)
				else Color3.new(1, 1, 1):Lerp(Color3.fromRGB(207, 34, 46), -q)
		end
	end
end

-- 48 values: 24 displacements x_i/3 then 24 velocities v_i/(3 omega_i), in node index order.
function Reservoir.read(self: Reservoir): { number }
	local out = table.create(2 * #self.nodes, 0)
	local count = #self.nodes
	for _, n in self.nodes do
		local x = n.part.Position.X - n.rest.X
		out[n.index] = x / 3
		out[count + n.index] = n.part.AssemblyLinearVelocity.X / (3 * n.omega)
	end
	return out
end

-- Diagnostics only (not model inputs): off-axis drift, spring lengths, rail contacts.
function Reservoir.diagnostics(self: Reservoir)
	local maxAbsX, maxOffAxis, railHits = 0, 0, 0
	local limit = self.config.physics.saturationThreshold
	for _, n in self.nodes do
		local p = n.part.Position
		local x = p.X - n.rest.X
		maxAbsX = math.max(maxAbsX, math.abs(x))
		maxOffAxis = math.max(maxOffAxis, math.abs(p.Y - n.rest.Y), math.abs(p.Z - n.rest.Z))
		if math.abs(x) >= limit then
			railHits += 1
		end
	end
	return { maxAbsX = maxAbsX, maxOffAxis = maxOffAxis, saturatedNodes = railHits }
end

function Reservoir.parameters(self: Reservoir)
	local out = {}
	for _, n in self.nodes do
		table.insert(out, { index = n.index, mass = n.mass, omega = n.omega, zeta = n.zeta, k = n.k, c = n.c })
	end
	return out
end

function Reservoir.destroy(self: Reservoir)
	self.model:Destroy()
	table.clear(self.nodes)
	table.clear(self.parts)
end

return Reservoir
