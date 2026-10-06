-- Recorded array display only. Saved normalized x is mapped to studs by the supplied frozen D. All Parts are anchored;
-- beams are visual links, never constraints. Missing warm-up/finished states are shown at dim rest, never simulated.
local View = {}
View.__index = View
View.MODEL_NAME = "RoAlgoSpringArrayReplay"
View.SCHEMA = "roalgo-spring-array-replay-view-1"
local VARIANTS = { "coupled", "independent" }
local function finite(x) return type(x) == "number" and x == x and math.abs(x) < math.huge end
local function check(ok, why) assert(ok, "SpringArrayReplayView: " .. why) end
local function integer(x) return finite(x) and x % 1 == 0 end
local function numericText(x)
	local rounded = math.round(x * 1000) / 1000
	if rounded == 0 then rounded = 0 end
	return string.format("x %+.3f", rounded)
end

local function flushReadouts(lane)
	if not lane.readoutsDirty then return end
	for _, variant in VARIANTS do
		for _, node in lane.nodes[variant] do
			local text = if lane.phase == "recorded" then numericText(node.x) else "x --"
			if node.label.Text ~= text then node.label.Text = text end
		end
	end
	lane.readoutsDirty = false
end

function View:updateLane(sample)
	check(not self.destroyed, "update after destroy")
	check(type(sample) == "table" and integer(sample.lane) and sample.lane >= 1 and sample.lane <= #self.lanes, "valid lane required")
	check(sample.phase == "recorded" or sample.phase == "warmup" or sample.phase == "idle", "phase must be recorded, warmup, or idle")
	check(sample.blockId == nil or (integer(sample.blockId) and sample.blockId > 0), "invalid blockId")
	check(sample.label == nil or type(sample.label) == "string", "label must be text")
	check(sample.t == nil or finite(sample.t), "invalid timestamp")
	-- Validate both complete vectors before changing any lane. Never leave half an invalid sample on screen.
	if sample.phase == "recorded" then
		check(integer(sample.rowIndex) and sample.rowIndex > 0, "recorded rowIndex required")
		for _, variant in VARIANTS do
			local vector = sample[variant]
			check(type(vector) == "table" and #vector == 51, variant .. " needs exactly 51 saved values")
			for i = 1, 51 do check(finite(vector[i]), variant .. " has a non-finite saved value") end
			for i = 1, 24 do check(finite(vector[i] * self.D), "displacement exceeds finite display coordinates") end
		end
	end
	local lane, E = self.lanes[sample.lane], self.env
	local phaseChanged = lane.phase ~= sample.phase
	lane.phase, lane.blockId, lane.rowIndex, lane.t = sample.phase, sample.blockId, sample.rowIndex, sample.t
	local recorded = sample.phase == "recorded"
	for _, variant in VARIANTS do
		for i, node in lane.nodes[variant] do
			local x = if recorded then self.D * sample[variant][i] else 0
			if node.x ~= x then node.part.CFrame = E.CFrame.new(node.rest + E.Vector3.new(x, 0, 0)) end
			node.x = x
			if phaseChanged then node.part.Transparency = if recorded then 0 else 0.68 end
		end
	end
	if phaseChanged then
		for _, beam in lane.beams do beam.Transparency = E.NumberSequence.new(if recorded then 0.4 else 0.86) end
	end
	local block = if sample.blockId then " · block " .. sample.blockId else ""
	local detail = if recorded then "" elseif sample.phase == "warmup" then " · settling" else " · finished"
	local label = if sample.label and #sample.label > 0 then " · " .. sample.label else ""
	lane.caption.Text = "LAYER " .. sample.lane .. block .. detail .. label
	lane.model:SetAttribute("Phase", sample.phase)
	lane.model:SetAttribute("BlockId", sample.blockId)
	lane.model:SetAttribute("RowIndex", if recorded then sample.rowIndex else nil)
	lane.model:SetAttribute("RecordedT", if recorded then sample.t else nil)
	lane.readoutsDirty = true
	if phaseChanged then flushReadouts(lane) end
	self.updates += 1
	return true
end

function View:stats()
	local lanes = {}
	for i, lane in self.lanes do
		lanes[i] = { lane = i, phase = lane.phase, blockId = lane.blockId, rowIndex = lane.rowIndex, t = lane.t }
	end
	return { schema = View.SCHEMA, laneCount = #self.lanes, nodeCount = #self.lanes * 48,
		axialBeams = #self.lanes * 48, couplingBeams = #self.lanes * 37, anchoredParts = #self.lanes * 49,
		layerSpacing = self.layerSpacing, D = self.D, readoutInterval = self.readoutInterval,
		updates = self.updates, destroyed = self.destroyed, recordedOnly = true, lanes = lanes }
end

function View:destroy()
	if self.destroyed then return false end
	self.destroyed = true
	for _, connection in self.connections do connection:Disconnect() end
	table.clear(self.connections)
	if self.model then self.model:Destroy() end
	return true
end

function View.mount(parent, descriptor, nativeConfig, opts)
	opts = opts or {}
	local E = opts.env or { Instance = Instance, Vector3 = Vector3, CFrame = CFrame, UDim2 = UDim2, Enum = Enum,
		Color3 = Color3, ColorSequence = ColorSequence, NumberSequence = NumberSequence, RunService = game:GetService("RunService") }
	local count, spacing, interval = opts.laneCount or 8, opts.layerSpacing or 800, opts.readoutInterval or 0.1
	check(integer(count) and count >= 1 and count <= 64, "laneCount must be 1..64")
	check(finite(spacing) and spacing > 0 and finite(interval) and interval > 0, "positive spacing and readout interval required")
	check(type(nativeConfig) == "table" and type(nativeConfig.nodes) == "table" and #nativeConfig.nodes == 24
		and type(nativeConfig.edges) == "table" and #nativeConfig.edges == 37, "frozen 24-node/37-edge configuration required")
	check(type(descriptor) == "table" and descriptor.nodeCount == 24 and descriptor.D == nativeConfig.D
		and descriptor.spacing == nativeConfig.spacing, "descriptor must agree with the frozen configuration")
	for _, key in { "D", "spacing", "anchorOffset" } do check(finite(nativeConfig[key]) and nativeConfig[key] > 0, "invalid config " .. key) end
	local minY, maxY, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, node in nativeConfig.nodes do
		check(finite(node.y) and finite(node.z) and integer(node.bank) and node.bank >= 1 and node.bank <= 3, "invalid node layout")
		minY, maxY = math.min(minY, node.y), math.max(maxY, node.y)
		minZ, maxZ = math.min(minZ, node.z), math.max(maxZ, node.z)
	end
	for _, edge in nativeConfig.edges do
		check(integer(edge.a) and integer(edge.b) and edge.a >= 1 and edge.a <= 24 and edge.b >= 1 and edge.b <= 24, "invalid coupling endpoints")
	end
	local origin = opts.origin or E.Vector3.new(0, 1024, 1024)
	check(finite(origin.X) and finite(origin.Y) and finite(origin.Z), "finite origin required")
	check(parent and parent:FindFirstChild(View.MODEL_NAME) == nil, "an array replay view already exists")
	local self = setmetatable({ env = E, lanes = {}, connections = {}, D = nativeConfig.D, layerSpacing = spacing,
		readoutInterval = interval, updates = 0, destroyed = false }, View)
	local function make(class, name, owner)
		local object = E.Instance.new(class)
		object.Name = name
		object:SetAttribute("VisualOnly", true)
		object:SetAttribute("ReplayOnly", true)
		if class == "Part" then
			object.Anchored, object.CanCollide, object.CanTouch, object.CanQuery = true, false, false, false
			object.CastShadow, object.Massless = false, true
		end
		object.Parent = owner
		return object
	end
	local function textGui(name, owner, attachment, width, height, textSize, rise)
		local gui = make("BillboardGui", name, owner)
		gui.Adornee, gui.Size = attachment, E.UDim2.fromOffset(width, height)
		gui.StudsOffsetWorldSpace = E.Vector3.new(0, rise, 0)
		gui.AlwaysOnTop, gui.MaxDistance, gui.LightInfluence = false, 0, 0
		local text = make("TextLabel", "Text", gui)
		text.Size = E.UDim2.fromScale(1, 1)
		text.BackgroundColor3, text.BackgroundTransparency, text.BorderSizePixel = E.Color3.fromRGB(12, 15, 20), 0.5, 0
		text.TextColor3, text.Font, text.TextSize = E.Color3.fromRGB(240, 240, 240), E.Enum.Font.RobotoMono, textSize
		text.TextScaled, text.TextWrapped, text.RichText = false, false, false
		return text
	end
	local ok, err = pcall(function()
		self.model = make("Model", View.MODEL_NAME, parent)
		self.model:SetAttribute("Schema", View.SCHEMA)
		self.model:SetAttribute("RunKind", "recorded_native")
		self.model:SetAttribute("DisplayAxis", "X")
		self.model:SetAttribute("LaneCount", count)
		self.model:SetAttribute("LayerSpacing", spacing)
		local depth = maxZ - minZ + 11 * nativeConfig.spacing
		local focus = origin + E.Vector3.new(0, (minY + maxY) / 2, minZ + depth / 2)
		local cameraScale = math.max(1, (count - 1) * spacing / 5600, depth / 4608)
		self.model:SetAttribute("FocusPosition", focus)
		self.model:SetAttribute("ViewPosition", focus + E.Vector3.new(-6500, 1220, -4328) * cameraScale)
		self.model:SetAttribute("ViewFieldOfView", 70)
		local colors = { E.Color3.fromRGB(72, 214, 169), E.Color3.fromRGB(255, 194, 95), E.Color3.fromRGB(105, 160, 255) }
		for k = 1, count do
			local lane = { model = make("Model", string.format("Lane%02d", k), self.model), nodes = {}, beams = {}, phase = "idle" }
			self.lanes[k] = lane
			local laneOrigin = origin + E.Vector3.new((k - (count + 1) / 2) * spacing, 0, 0)
			local carrier = make("Part", "VisualAnchors", lane.model)
			carrier.Size, carrier.CFrame, carrier.Transparency = E.Vector3.new(1, 1, 1), E.CFrame.new(laneOrigin), 1
			local function beam(name, a, b, color)
				local line = make("Beam", name, lane.model)
				line.Attachment0, line.Attachment1 = a, b
				local width = if string.sub(name, 1, 8) == "Coupling" then 4 else 2
				line.Width0, line.Width1, line.FaceCamera = width, width, true
				line.LightEmission, line.LightInfluence, line.Segments = 1, 0, 1
				line.Color, line.Transparency = E.ColorSequence.new(color), E.NumberSequence.new(0.86)
				table.insert(lane.beams, line)
			end
			for r, variant in VARIANTS do
				lane.nodes[variant] = {}
				local folder = make("Folder", variant, lane.model)
				local dz = if r == 1 then 0 else 11 * nativeConfig.spacing
				for i, n in nativeConfig.nodes do
					local rest = laneOrigin + E.Vector3.new(0, n.y, n.z + dz)
					local part = make("Part", n.name or ("Node" .. i), folder)
					part.Shape, part.Size, part.CFrame = E.Enum.PartType.Ball, E.Vector3.new(32, 32, 32), E.CFrame.new(rest)
					part.Color, part.Material, part.Transparency = colors[n.bank], E.Enum.Material.Neon, 0.68
					local center = make("Attachment", "Center", part)
					local anchor = make("Attachment", variant .. "Anchor" .. i, carrier)
					anchor.CFrame = E.CFrame.new(-nativeConfig.anchorOffset, n.y, n.z + dz)
					beam(variant .. "Axial" .. i, anchor, center, colors[n.bank])
					local label = textGui("Displacement", folder, center, 76, 16, 11, 40)
					label.Text = "x --"
					label:SetAttribute("Units", "studs")
					lane.nodes[variant][i] = { part = part, center = center, rest = rest, x = 0, label = label }
				end
			end
			for i, edge in nativeConfig.edges do
				beam("Coupling" .. i, lane.nodes.coupled[edge.a].center, lane.nodes.coupled[edge.b].center,
					colors[nativeConfig.nodes[edge.b].bank])
			end
			local caption = make("Attachment", "LaneCaption", carrier)
			caption.CFrame = E.CFrame.new(0, maxY, minZ)
			lane.caption = textGui("LaneCaption", lane.model, caption, 420, 18, 12, 80)
			lane.caption.Text = "LAYER " .. k
			lane.model:SetAttribute("Phase", "idle")
		end
		local elapsed = 0
		table.insert(self.connections, E.RunService.Heartbeat:Connect(function(dt)
			if self.model.Parent == nil then self:destroy(); return end
			elapsed += dt
			if elapsed >= interval then
				elapsed %= interval
				for _, lane in self.lanes do flushReadouts(lane) end
			end
		end))
		table.insert(self.connections, self.model.Destroying:Connect(function() self:destroy() end))
	end)
	if not ok then self:destroy(); error("SpringArrayReplayView.mount: " .. tostring(err), 0) end
	return self
end

return View
