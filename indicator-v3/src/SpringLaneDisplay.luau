-- Translation-only live view for L21. The native rigs stay at their validated coordinates; their bodies drive these
-- adornments and beams through NEW visual attachments. No physics object, original property, or stepper list is written.
-- There is no pose callback or per-frame polling. Identity source rotations are required because offsets are local.
local Display = {}
Display.__index = Display
Display.SCHEMA = "roalgo-spring-lane-display-1"
Display.ROOT_NAME = "RoAlgoSpringLaneDisplay"
Display.LAYER_SPACING = 800
Display.SPHERE_RADIUS = 16

local PHYSICS_FIELDS = {
	BasePart = { "CFrame", "Size", "Anchored", "AssemblyLinearVelocity", "AssemblyAngularVelocity", "AssemblyMass" },
	Attachment = { "CFrame" },
	SpringConstraint = { "Attachment0", "Attachment1", "FreeLength", "Stiffness", "Damping", "MaxForce", "Enabled" },
	PrismaticConstraint = { "Attachment0", "Attachment1", "ActuatorType", "LimitsEnabled", "LowerLimit", "UpperLimit", "Restitution", "Enabled" },
	VectorForce = { "Attachment0", "Force", "RelativeTo", "ApplyAtCenterOfMass", "Enabled" },
}
local VISUAL_CLASSES = { Folder = true, Attachment = true, SphereHandleAdornment = true, Beam = true }

local function check(ok, why) assert(ok, "SpringLaneDisplay: " .. why) end
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < math.huge end
local function path(instance) return instance:GetFullName() end

local function nativeSnapshot(container, runner, owned)
	local records = {}
	for _, instance in container:GetDescendants() do
		if not owned[instance] then
			for class, fields in PHYSICS_FIELDS do
				if instance:IsA(class) then
					local values = { Parent = instance.Parent }
					for _, key in fields do values[key] = instance[key] end
					table.insert(records, { instance = instance, values = values })
					break
				end
			end
		end
	end
	return { records = records, partList = runner.parts, parts = table.clone(runner.parts) }
end

local function verifySnapshot(before, runner)
	check(runner.parts == before.partList and #runner.parts == #before.parts, "native runner part list changed")
	for i, part in before.parts do check(runner.parts[i] == part, "native runner part identity/order changed at " .. i) end
	for _, record in before.records do
		for key, value in record.values do
			check(record.instance[key] == value, "native " .. path(record.instance) .. "." .. key .. " changed")
		end
	end
end

local function basisError(part)
	check(part and part:IsA("BasePart"), "every display source must be a BasePart")
	local components = { part.CFrame:GetComponents() }
	local identity, maxError = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }, 0
	for i = 1, 9 do
		local value = components[i + 3]
		check(finite(value), "source rotation must be finite")
		maxError = math.max(maxError, math.abs(value - identity[i]))
	end
	check(maxError <= 1e-8, "source rotation must be identity: " .. path(part))
	return maxError
end

local function validate(lanes, runner)
	check(type(lanes) == "table" and #lanes > 0, "lanes required")
	check(type(runner) == "table" and type(runner.parts) == "table", "native runner required")
	local membership, bodies, maxError = {}, {}, 0
	for _, part in runner.parts do
		check(not membership[part], "duplicate native runner part")
		membership[part] = true
	end
	local bodyCount = 0
	for k, lane in lanes do
		check(lane.index == k and finite(lane.offsetZ), "ordered lanes with finite native offsets required")
		for _, rig in { lane.coupled, lane.independent } do
			check(type(rig.nodes) == "table" and #rig.nodes > 0, "native rig nodes required")
			local centers = {}
			for _, node in rig.nodes do
				for _, part in { node.part, node.anchor, node.guide } do maxError = math.max(maxError, basisError(part)) end
				check(membership[node.part] and not bodies[node.part], "display body must occur once in the native runner")
				bodies[node.part], bodyCount = true, bodyCount + 1
				check(node.attachment and node.attachment:IsA("Attachment") and node.attachment.Parent == node.part,
					"native center attachment ownership differs")
				check(node.axial and node.axial:IsA("SpringConstraint") and node.axial.Attachment0
					and node.axial.Attachment0.Parent == node.anchor and node.axial.Attachment1 == node.attachment,
					"native axial endpoints differ")
				check(node.rail and node.rail:IsA("PrismaticConstraint") and node.rail.Attachment0
					and node.rail.Attachment0.Parent == node.guide and node.rail.Attachment1 == node.attachment,
					"native rail endpoints differ")
				check(node.force and node.force:IsA("VectorForce") and node.force.Attachment0 == node.attachment,
					"native force endpoint differs")
				centers[node.attachment] = true
			end
			for _, spring in rig.couplings do
				check(spring:IsA("SpringConstraint") and centers[spring.Attachment0] and centers[spring.Attachment1],
					"native coupling endpoints must belong to the same rig")
			end
		end
	end
	check(#runner.parts == bodyCount + 2, "native runner must contain exactly the display bodies plus two metronomes")
	return bodyCount, maxError
end

function Display:describe()
	local translations = {}
	for k, delta in self.translations do translations[k] = { lane = k, x = delta.X, y = delta.Y, z = delta.Z } end
	return { schema = Display.SCHEMA, rootName = Display.ROOT_NAME, label = "Translated live native view",
		translationOnly = true, displayAxis = "X", layerSpacing = Display.LAYER_SPACING, sphereRadius = Display.SPHERE_RADIUS,
		bodyCount = self.bodyCount, axialCount = self.axialCount, couplingCount = self.couplingCount,
		nativeParts = #self.runner.parts, translations = translations, maxSourceBasisError = self.maxSourceBasisError,
		destroyed = self.destroyed, invariants = table.clone(self.invariants) }
end

local function removeOwned(self)
	local problems = {}
	if self.connection then self.connection:Disconnect(); self.connection = nil end
	for i = #self.created, 1, -1 do
		local ok, err = pcall(function() self.created[i]:Destroy() end)
		if not ok then table.insert(problems, tostring(err)) end
	end
	check(#problems == 0, "visual cleanup failed: " .. table.concat(problems, "; "))
end

function Display:destroy()
	if self.destroyed or self.removing then return false end
	self.removing = true
	local ok, err = pcall(function()
		local before = nativeSnapshot(self.container, self.runner, self.owned)
		removeOwned(self)
		verifySnapshot(before, self.runner)
		self.invariants.destroyPhysicsUnchanged = true
		self.destroyed = true
	end)
	self.removing = false
	if not ok then error(err, 0) end
	return true
end

function Display.mount(container, lanes, opts)
	check(container and container:IsA("Model"), "native lane container required")
	check(container:FindFirstChild(Display.ROOT_NAME) == nil, "a translated display already exists")
	local runner = opts and opts.runner
	local bodyCount, maxError = validate(lanes, runner)
	local self = setmetatable({ container = container, runner = runner, created = {}, owned = {}, labelAnchors = {},
		translations = {}, bodyCount = bodyCount, axialCount = 0, couplingCount = 0, maxSourceBasisError = maxError,
		destroyed = false, removing = false, invariants = {} }, Display)
	local before = nativeSnapshot(container, runner, self.owned)
	local function make(class, name, parent, sourcePaths)
		check(VISUAL_CLASSES[class], "only non-physical visual instances may be created")
		local instance = Instance.new(class)
		table.insert(self.created, instance)
		self.owned[instance] = true
		instance.Name = name
		instance:SetAttribute("VisualOnly", true)
		instance:SetAttribute("TranslationOnly", true)
		instance:SetAttribute("SourcePaths", sourcePaths)
		instance.Parent = parent
		return instance
	end
	local ok, err = pcall(function()
		self.root = make("Folder", Display.ROOT_NAME, container, path(container))
		self.root:SetAttribute("Schema", Display.SCHEMA)
		self.root:SetAttribute("LayerSpacing", Display.LAYER_SPACING)
		self.root:SetAttribute("DisplayAxis", "X")
		for k, lane in lanes do
			local delta = Vector3.new((k - (#lanes + 1) / 2) * Display.LAYER_SPACING, 0, -lane.offsetZ)
			self.translations[k] = delta
			local folder = make("Folder", string.format("Lane%02d", k), self.root, path(lane.coupled.model) .. ";" .. path(lane.independent.model))
			folder:SetAttribute("Translation", delta)
			local shifted = {}
			local function visualAttachment(original)
				if shifted[original] then return shifted[original] end
				local attachment = make("Attachment", "SpringDisplay_" .. original.Name, original.Parent, path(original))
				attachment.CFrame = original.CFrame + delta
				shifted[original] = attachment
				return attachment
			end
			local function beam(spring, color)
				local line = make("Beam", spring.Name, folder, path(spring))
				line.Attachment0, line.Attachment1 = visualAttachment(spring.Attachment0), visualAttachment(spring.Attachment1)
				line.Width0, line.Width1 = 2, 2
				line.FaceCamera, line.LightEmission, line.LightInfluence = true, 1, 0
				line.Transparency = NumberSequence.new(0.4)
				line.Color = ColorSequence.new(color)
				line.Segments = 1
			end
			for _, rig in { lane.coupled, lane.independent } do
				for _, node in rig.nodes do
					local marker = make("SphereHandleAdornment", node.part.Name, folder, path(node.part))
					marker.Adornee, marker.CFrame = node.part, CFrame.new(delta)
					marker.Radius, marker.Color3, marker.Transparency = Display.SPHERE_RADIUS, node.part.Color, 0
					marker.AlwaysOnTop = false
					beam(node.axial, node.part.Color)
					self.axialCount += 1
				end
				for _, spring in rig.couplings do
					beam(spring, spring.Attachment1.Parent.Color)
					self.couplingCount += 1
				end
			end
			local guide = lane.coupled.nodes[1].guide
			local label = make("Attachment", "SpringDisplay_Label", guide, path(guide))
			label.CFrame = CFrame.new(delta)
			self.labelAnchors[k] = label
		end
		verifySnapshot(before, runner)
		self.invariants.mountPhysicsUnchanged = true
		self.invariants.runnerPartListUnchanged = true
		self.invariants.originalAttachmentsUnchanged = true
		self.invariants.noPhysicsInstances = true
		-- One lifecycle event, never a pose-update callback. Attachments owned by this view live on native parts and
		-- therefore also need removal when someone deletes the visual Folder directly in Studio.
		self.connection = self.root.Destroying:Connect(function() self:destroy() end)
	end)
	if not ok then
		pcall(removeOwned, self)
		verifySnapshot(before, runner)
		error("SpringLaneDisplay.mount: " .. tostring(err), 0)
	end
	return self
end

return Display
