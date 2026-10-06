-- Recorded motion in an inert copy of the research rig. The original is parked intact
-- until this view closes. Guides supply rest coordinates; no physics is advanced.
local Companion = {}
Companion.__index = Companion

local MODEL_NAME = "RoAlgoSpringArrayCompanion"
local PARK_NAME = "RoAlgoSpringArrayCompanionOriginal"
local VARIANTS = { coupled = "Coupled", independent = "Independent" }
local DIM = 0.72

local function finite(x)
	return type(x) == "number" and x == x and math.abs(x) < math.huge
end

local function nodesOf(root)
	local result = {}
	for variant, name in VARIANTS do
		local rig = assert(root:FindFirstChild(name), "SpringArrayCompanionView: missing " .. name)
		local bodies, guides = {}, {}
		for _, item in rig:GetDescendants() do
			if item:IsA("BasePart") then
				local index = item:GetAttribute("NodeIndex")
				if index ~= nil then
					assert(finite(index) and index % 1 == 0 and index >= 1 and index <= 24,
						"SpringArrayCompanionView: invalid NodeIndex")
					assert(not bodies[index], "SpringArrayCompanionView: duplicate NodeIndex")
					bodies[index] = item
				end
				local guideIndex = tonumber(string.match(item.Name, "^Guide(%d+)$"))
				if guideIndex then
					assert(not guides[guideIndex], "SpringArrayCompanionView: duplicate guide")
					guides[guideIndex] = item
				end
			end
		end
		result[variant] = {}
		for i = 1, 24 do
			local body = assert(bodies[i], "SpringArrayCompanionView: missing " .. name .. " node " .. i)
			local guide = assert(guides[i], "SpringArrayCompanionView: missing " .. name .. " Guide" .. i)
			assert(guide.Anchored, "SpringArrayCompanionView: guide must be anchored")
			local p = guide.Position
			assert(finite(p.X) and finite(p.Y) and finite(p.Z), "SpringArrayCompanionView: invalid guide pose")
			result[variant][i] = { body = body, rest = body.CFrame + (p - body.Position) }
		end
	end
	return result
end

local function snapshot(root)
	local saved = {}
	for _, item in root:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(saved, { part = item, cf = item.CFrame, anchored = item.Anchored,
				linear = item.AssemblyLinearVelocity, angular = item.AssemblyAngularVelocity })
		end
	end
	return saved
end

local function originalUnchanged(saved)
	for _, s in saved do
		if s.part.CFrame ~= s.cf or s.part.Anchored ~= s.anchored
			or s.part.AssemblyLinearVelocity ~= s.linear or s.part.AssemblyAngularVelocity ~= s.angular then
			return false
		end
	end
	return true
end

local function validateVisualReferences(root)
	for _, item in root:GetDescendants() do
		if item:IsA("Beam") or item:IsA("Trail") then
			assert(item.Attachment0 and item.Attachment1
				and item.Attachment0:IsDescendantOf(root) and item.Attachment1:IsDescendantOf(root),
				"SpringArrayCompanionView: external or missing visual attachment")
		end
		local ok, adornee = pcall(function() return item.Adornee end)
		if ok and adornee ~= nil then
			assert(adornee == root or adornee:IsDescendantOf(root),
				"SpringArrayCompanionView: external visual Adornee")
		end
	end
end

local function bindReadouts(self, descriptor)
	local byBody = {}
	for variant in VARIANTS do
		for i, node in self.nodes[variant] do byBody[node.body] = { variant = variant, index = i, node = node } end
	end
	self.readoutCount = 0
	for _, gui in self.model:GetDescendants() do
		if not gui:IsA("BillboardGui") then continue end
		local binding = byBody[gui.Adornee]
		if not binding then continue end
		local card = gui:FindFirstChild("NodeCard")
		if not card then continue end
		local identity, readout = card:FindFirstChild("NodeIdentity"), card:FindFirstChild("MixedDriveMeaning")
		local metadata = descriptor.nodes and descriptor.nodes[binding.index]
		if metadata then
			if identity and identity:IsA("TextLabel") then
				identity.Text = (if binding.variant == "coupled" then "C" else "I") .. " · " .. metadata.name
			end
			gui:SetAttribute("InputMeaning", metadata.dominantName)
			gui:SetAttribute("DominantDriveChannel", metadata.dominantChannel)
			gui:SetAttribute("BankMeaning", metadata.bankName)
			gui:SetAttribute("FinancialGroup", nil)
			gui:SetAttribute("FixedSignedProjection", if metadata.projection then table.concat(metadata.projection, ",") else nil)
		end
		local oldGroup = card:FindFirstChild("FinancialGroupMeaning")
		if oldGroup and oldGroup:IsA("TextLabel") then oldGroup.Visible = false end
		if readout and readout:IsA("TextLabel") then
			binding.node.readout = readout
			self.readoutCount += 1
		end
	end
end

function Companion.mount(original, descriptor)
	assert(not game:GetService("RunService"):IsRunning(), "SpringArrayCompanionView: Edit mode only")
	assert(original and original.Parent and original:IsA("Model"), "SpringArrayCompanionView: original model required")
	assert(type(descriptor) == "table" and descriptor.nodeCount == 24 and finite(descriptor.D) and descriptor.D > 0,
		"SpringArrayCompanionView: expected 24-node descriptor with positive D")
	local parent, storage = original.Parent, game:GetService("ServerStorage")
	assert(not parent:FindFirstChild(MODEL_NAME) and not storage:FindFirstChild(PARK_NAME),
		"SpringArrayCompanionView: companion already exists or original awaits restoration")
	nodesOf(original) -- Reject incomplete sources before cloning or changing their parent.
	local self = setmetatable({ original = original, originalParent = parent, saved = snapshot(original),
		D = descriptor.D, phase = "idle", updates = 0, destroyed = false, visuals = {},
		partCount = 0, removedPhysics = 0, originalPreserved = true }, Companion)
	local ok, err = pcall(function()
		self.model = assert(original:Clone(), "SpringArrayCompanionView: original is not Archivable")
		self.model.Name = MODEL_NAME
		self.model:SetAttribute("VisualOnly", true)
		for _, item in self.model:GetDescendants() do
			if item:IsA("Constraint") or item:IsA("BodyMover") or item:IsA("JointInstance") then
				self.removedPhysics += 1
				item:Destroy()
			elseif item:IsA("LuaSourceContainer") or item:IsA("Script") or item:IsA("LocalScript") then
				item:Destroy()
			elseif item:IsA("BasePart") then
				item.Anchored, item.CanCollide, item.CanTouch, item.CanQuery = true, false, false, false
				self.partCount += 1
				table.insert(self.visuals, { item = item, transparency = item.Transparency, sequence = false })
			elseif item:IsA("Beam") or item:IsA("Trail") then
				if item:IsA("Beam") and string.match(item.Name, "^Visual_Couple") then
					item.Width0, item.Width1 = 8, 8
				end
				table.insert(self.visuals, { item = item, transparency = item.Transparency, sequence = true })
			elseif item:IsA("HandleAdornment") or item:IsA("SphereHandleAdornment") then
				table.insert(self.visuals, { item = item, transparency = item.Transparency, sequence = false })
			end
		end
		self.nodes = nodesOf(self.model)
		validateVisualReferences(self.model)
		bindReadouts(self, descriptor)
		self:update({ phase = "idle" })
		self.park = Instance.new("Folder")
		self.park.Name, self.park.Parent = PARK_NAME, storage
		original.Parent = self.park
		self.model.Parent = parent
		assert(originalUnchanged(self.saved), "SpringArrayCompanionView: original changed while mounting")
		self.connection = self.model.Destroying:Connect(function() self:destroy() end)
	end)
	if not ok then
		-- Restore parent before disposing the owned parking folder, even after partial mount.
		if self.park and original.Parent == self.park then original.Parent = parent end
		if self.model then self.model:Destroy() end
		if self.park and #self.park:GetChildren() == 0 then self.park:Destroy() end
		error(err, 0)
	end
	return self
end

function Companion:update(sample)
	assert(not self.destroyed, "SpringArrayCompanionView: update after destroy")
	assert(type(sample) == "table" and (sample.phase == "recorded" or sample.phase == "warmup" or sample.phase == "idle"),
		"SpringArrayCompanionView: invalid sample phase")
	local recorded = sample.phase == "recorded"
	if recorded then
		-- Validate both complete endpoint vectors before writing any clone property.
		for variant in VARIANTS do
			local vector = sample[variant]
			assert(type(vector) == "table" and #vector == 51, "SpringArrayCompanionView: expected 51-state vector")
			for i = 1, 51 do assert(finite(vector[i]), "SpringArrayCompanionView: nonfinite state") end
			for i = 1, 24 do
				assert(finite(self.nodes[variant][i].rest.Position.X + self.D * vector[i]),
					"SpringArrayCompanionView: nonfinite display coordinate")
			end
		end
	end
	for variant in VARIANTS do
		for i, node in self.nodes[variant] do
			local x = if recorded then self.D * sample[variant][i] else 0
			node.body.CFrame = node.rest + Vector3.new(x, 0, 0)
			if node.readout then
				local rounded = math.round(x * 10) / 10
				local text = if recorded then string.format("x %+.1f studs", if rounded == 0 then 0 else rounded) else "x -- studs"
				if node.readout.Text ~= text then node.readout.Text = text end
			end
		end
	end
	if self.phase ~= sample.phase or self.updates == 0 then
		for _, visual in self.visuals do
			visual.item.Transparency = if recorded then visual.transparency
				elseif visual.sequence then NumberSequence.new(DIM) else math.max(DIM, visual.transparency)
		end
	end
	self.phase, self.rowIndex, self.lane = sample.phase, sample.rowIndex, sample.lane
	self.updates += 1
	return true
end

function Companion:stats()
	return { phase = self.phase, lane = self.lane, rowIndex = self.rowIndex, updates = self.updates,
		nodeCount = 48, partCount = self.partCount, readoutCount = self.readoutCount, removedPhysics = self.removedPhysics,
		destroyed = self.destroyed, originalPreserved = self.originalPreserved }
end

function Companion:destroy()
	if self.destroyed then return false end
	self.destroyed = true
	if self.connection then self.connection:Disconnect(); self.connection = nil end
	if self.original.Parent == self.park then self.original.Parent = self.originalParent end
	if self.model then self.model:Destroy() end
	if self.park and #self.park:GetChildren() == 0 then self.park:Destroy() end
	self.originalPreserved = originalUnchanged(self.saved)
	assert(self.originalPreserved, "SpringArrayCompanionView: original motion properties changed externally")
	return true
end

return Companion
