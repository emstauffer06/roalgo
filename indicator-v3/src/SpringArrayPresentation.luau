-- Reversible GUI adapter. The array host owns the only playback clock and all data.
local Presentation = {}
local Adapter = {}
Adapter.__index = Adapter

local HIDDEN = { Previous = true, PlayPause = true, Next = true, GoTo = true, ScrubTrack = true,
	Exit = true, Provenance = true, Status = true, CompareHeader = true, RunCaption = true,
	Partition = true, RowCounter = true, Setup = true }

local function finite(value)
	return type(value) == "number" and value == value and math.abs(value) < math.huge
end

local function validateLayout(descriptor, config)
	assert(type(descriptor) == "table" and descriptor.nodeCount == 24 and finite(descriptor.D) and descriptor.D > 0,
		"SpringArrayPresentation: 24-node descriptor with positive D required")
	assert(type(config) == "table" and config.D == descriptor.D and #config.nodes == 24 and #config.edges == 37,
		"SpringArrayPresentation: matching 24-node / 37-link native config required")
	for i, node in descriptor.nodes do
		local native = config.nodes[i]
		assert(finite(node.omega) and node.omega > 0 and finite(node.y) and finite(node.z)
			and node.bank == math.ceil(i / 8) and native.omega == node.omega and native.y == node.y and native.z == node.z,
			"SpringArrayPresentation: incompatible node geometry or velocity normalization")
	end
	for _, edge in config.edges do
		assert(finite(edge.a) and edge.a % 1 == 0 and edge.a >= 1 and edge.a <= 24
			and finite(edge.b) and edge.b % 1 == 0 and edge.b >= 1 and edge.b <= 24 and edge.a ~= edge.b
			and finite(edge.freeLength) and edge.freeLength >= 0, "SpringArrayPresentation: invalid coupling geometry")
	end
end

local function motion(vector, descriptor)
	assert(type(vector) == "table" and #vector == 51, "SpringArrayPresentation: 51 measured state values required")
	for _, value in vector do assert(finite(value), "SpringArrayPresentation: nonfinite measured state") end
	local out = { meanX = 0, rmsX = 0, peakX = 0, meanSpeed = 0, peakSpeed = 0, positive = 0, negative = 0,
		zero = 0, active = 0, bankMeanX = { 0, 0, 0 }, x = {} }
	for i = 1, 24 do
		local node = descriptor.nodes[i]
		local x = descriptor.D * vector[i]
		-- Native read() stores velocity / (D * omega_i), not velocity / D.
		local speed = math.abs(descriptor.D * node.omega * vector[24 + i])
		out.x[i] = x
		out.meanX += x / 24
		out.rmsX += x * x / 24
		out.peakX = math.max(out.peakX, math.abs(x))
		out.meanSpeed += speed / 24
		out.peakSpeed = math.max(out.peakSpeed, speed)
		out.bankMeanX[node.bank] += x / 8
		if x > 0 then out.positive += 1 elseif x < 0 then out.negative += 1 else out.zero += 1 end
		if math.abs(x) > 1 then out.active += 1 end
	end
	out.rmsX = math.sqrt(out.rmsX)
	out.normalizedRmsX = out.rmsX / descriptor.D
	return out
end

-- Pure display telemetry from measured endpoint state. State slots 49..51 are
-- normalized bank energies; they are deliberately not interpreted as forces.
function Presentation.telemetry(sample, descriptor, config)
	validateLayout(descriptor, config)
	assert(sample.phase == "recorded", "SpringArrayPresentation: telemetry requires a measured sample")
	local c, independent = motion(sample.coupled, descriptor), motion(sample.independent, descriptor)
	local stretchSquare, differenceSquare = 0, 0
	for _, edge in config.edges do
		local a, b = descriptor.nodes[edge.a], descriptor.nodes[edge.b]
		local length = math.sqrt((c.x[edge.b] - c.x[edge.a]) ^ 2 + (b.y - a.y) ^ 2 + (b.z - a.z) ^ 2)
		stretchSquare += (length - edge.freeLength) ^ 2 / #config.edges
	end
	for i = 1, 24 do differenceSquare += (c.x[i] - independent.x[i]) ^ 2 / 24 end
	return { coupled = c, independent = independent, couplingStretchRms = math.sqrt(stretchSquare),
		differenceRms = math.sqrt(differenceSquare), nodeCount = 24, couplingLinks = #config.edges,
		axialLinks = 24, activeThresholdStuds = 1 }
end

function Adapter:_paintTelemetry(value)
	local c, i, L = value.coupled, value.independent, self.telemetryLabels
	L.Topology.Text = "24 measured nodes · 37 coupling links · 24 axial links"
	L.Active.Text = string.format("Active %d / 24 (|x| > 1 stud) · +%d / −%d / zero %d", c.active, c.positive, c.negative, c.zero)
	L.Displacement.Text = string.format("x mean %+.3f · RMS %.3f · peak |x| %.3f studs", c.meanX, c.rmsX, c.peakX)
	L.Speed.Text = string.format("Mean speed %.3f · peak speed %.3f studs/s", c.meanSpeed, c.peakSpeed)
	L.Banks.Text = string.format("Mean x: fast %+.3f · medium %+.3f studs", c.bankMeanX[1], c.bankMeanX[2])
	L.Slow.Text = string.format("Mean x: slow %+.3f studs · normalized x RMS %.4f", c.bankMeanX[3], c.normalizedRmsX)
	L.Stretch.Text = string.format("Coupling stretch RMS %.3f studs (L − L0)", value.couplingStretchRms)
	L.IndependentX.Text = string.format("x mean %+.3f · RMS %.3f · peak |x| %.3f studs", i.meanX, i.rmsX, i.peakX)
	L.IndependentActive.Text = string.format("24 nodes · 0 coupling / 24 axial links · %d active (|x| > 1)", i.active)
	L.IndependentSpeed.Text = string.format("Mean speed %.3f · peak speed %.3f studs/s", i.meanSpeed, i.peakSpeed)
	L.Difference.Text = string.format("Coupled / independent x difference RMS %.3f studs", value.differenceRms)
end

function Adapter:_set(object, property, value)
	local saved = self.saved[object]
	if not saved then saved = {}; self.saved[object] = saved end
	if saved[property] == nil then saved[property] = { value = object[property] } end
	object[property] = value
end

local function provenance(text)
	local lower = string.lower(text)
	for _, word in { "replay", "recording", "recorded", "capture", "live run", "live_native" } do
		if string.find(lower, word, 1, true) then return true end
	end
	return false
end

function Adapter:_clean()
	for _, child in self.content:GetChildren() do
		if child:IsA("GuiObject") and child ~= self.controls and (HIDDEN[child.Name]
			or child.Position.Y.Offset >= 312 or string.sub(child.Name, 1, 4) == "Run_") then
			self:_set(child, "Visible", false)
		end
	end
	if self.chartSpeed then self:_set(self.chartSpeed, "Visible", false) end
	self:_set(self.header, "Text", string.format("SPRING CLUSTER · LAYER %d · COUPLED", self.state.selectedLane))
	self:_set(self.chartTitle, "Text", "SPY 5-MIN · COUPLED")
	local score = self.content:FindFirstChild("Score")
	if score then self:_set(score, "Text", (string.gsub(score.Text, "^SCORE", "CONFIDENCE"))) end
	-- The chart's title is the only provenance-bearing chart field. Its pooled plot
	-- objects contain dates/prices/trades, so do not traverse that large tree per tick.
	for _, child in self.panelText do
		if child.Parent and provenance(child.Text) then
			if self.masked[child] == nil then self.masked[child] = child.Visible end
			self:_set(child, "Visible", false)
		end
	end
end

function Adapter:update(sample, state)
	assert(not self.destroyed, "SpringArrayPresentation: adapter destroyed")
	assert(type(sample) == "table" and type(state) == "table", "SpringArrayPresentation: sample and state required")
	assert(finite(state.selectedLane) and state.selectedLane % 1 == 0 and state.selectedLane >= 1,
		"SpringArrayPresentation: selected lane required")
	assert(sample.phase == "recorded" or sample.phase == "warmup" or sample.phase == "idle",
		"SpringArrayPresentation: unsupported phase")
	-- Validate all telemetry inputs before changing either the retained cursor or the GUI.
	local measured = if sample.phase == "recorded" then Presentation.telemetry(sample, self.descriptor, self.nativeConfig) else nil
	self.state = table.clone(state)
	self.phase = sample.phase
	-- Remove only our temporary masks before the retained viewer paints the next row.
	for object, visible in self.masked do self:_set(object, "Visible", visible) end
	table.clear(self.masked)
	if sample.phase == "recorded" then
		assert(finite(sample.rowIndex) and sample.rowIndex % 1 == 0 and sample.rowIndex >= 1,
			"SpringArrayPresentation: recorded row index required")
		for object, visible in self.gapHidden do self:_set(object, "Visible", visible) end
		table.clear(self.gapHidden)
		if self.lastRow ~= sample.rowIndex then
			self.oldControl:Invoke("seek", sample.rowIndex)
			self.seeks += 1
			self.lastRow = sample.rowIndex
		end
		assert(self.panel:GetAttribute("RowIndex") == sample.rowIndex,
			"SpringArrayPresentation: panel did not render the selected row")
		assert(self.chart:GetAttribute("Index") == sample.rowIndex,
			"SpringArrayPresentation: chart did not render the selected row")
		self:_set(self.chart, "Enabled", true)
		self:_set(self.timestamp, "Text", sample.label or "Date unavailable")
		self:_paintTelemetry(measured)
	else
		-- Dates and all data below the controls would otherwise describe the previous row.
		for _, child in self.content:GetChildren() do
			if child:IsA("GuiObject") and child ~= self.controls and (child.Position.Y.Offset >= 214
				or child.Name == "Timestamp" or child.Name == "Partition" or child.Name == "RowCounter") then
				if self.gapHidden[child] == nil then self.gapHidden[child] = child.Visible end
				self:_set(child, "Visible", false)
			end
		end
		self:_set(self.chart, "Enabled", false)
	end
	self:_set(self.panel, "Enabled", true)
	self:_clean()
	self.buttons.Play.Text = if state.playing then "Pause" else "Run"
	self.buttons.Layer.Text = string.format("Layer %d / %d", state.selectedLane, state.laneCount or 8)
	local rows = state.loadedRows or state.totalRows or 1
	self.rowCounter.Text = if sample.phase == "recorded" then string.format("Row %d / %d", sample.rowIndex, rows)
		else string.format("Row — / %d", rows)
	local fraction = math.clamp(((sample.phase == "recorded" and sample.rowIndex or self.lastRow or 1) - 1) / math.max(rows - 1, 1), 0, 1)
	self.rowFill.Size = self.env.UDim2.new(fraction, 0, 1, 0)
	self.settling.Visible = sample.phase ~= "recorded"
	self.settling.Text = if sample.phase == "idle" then "Finished" else "Settling"
	self.telemetryFrame.Visible = sample.phase == "recorded"
	self.confidenceNote.Visible = sample.phase == "recorded"
	self.telemetry = measured
	return true
end

function Adapter:stats()
	return { destroyed = self.destroyed, phase = self.phase, rowIndex = self.lastRow, seeks = self.seeks,
		selectedLane = self.state.selectedLane, tick = self.state.tick, playing = self.state.playing,
		panelRowIndex = self.panel:GetAttribute("RowIndex"), chartIndex = self.chart:GetAttribute("Index"),
		clockOwnedByHost = true, telemetry = self.telemetry }
end

function Adapter:destroy()
	if self.destroyed then return end
	self.destroyed = true
	for _, connection in self.connections do connection:Disconnect() end
	table.clear(self.connections)
	if self.controls then self.controls:Destroy() end
	for object, properties in self.saved do
		for property, entry in properties do pcall(function() object[property] = entry.value end) end
	end
	table.clear(self.saved)
end

function Presentation.mount(core, oldControl, callbacks)
	assert(core and oldControl and type(callbacks) == "table", "SpringArrayPresentation: core, control and callbacks required")
	for _, name in { "play", "lane", "seekRow" } do
		assert(type(callbacks[name]) == "function", "SpringArrayPresentation: callback " .. name .. " required")
	end
	validateLayout(callbacks.descriptor, callbacks.nativeConfig)
	-- Optional environment is solely a CLI test seam; production uses Roblox globals.
	local env = callbacks.env or { Instance = Instance, UDim2 = UDim2, UDim = UDim, Enum = Enum }
	local panel, chart = core:FindFirstChild("RoAlgoSpringPanel"), core:FindFirstChild("RoAlgoSpringChart")
	assert(panel and chart, "SpringArrayPresentation: retained panel and chart required")
	local dock = panel:FindFirstChild("Dock")
	local content, chartFrame = dock and dock:FindFirstChild("Content"), chart:FindFirstChild("Chart")
	assert(content and chartFrame, "SpringArrayPresentation: retained GUI structure missing")
	assert(not content:FindFirstChild("ArrayPresentationControls"), "SpringArrayPresentation: adapter already mounted")
	local self = setmetatable({ panel = panel, chart = chart, content = content, oldControl = oldControl, env = env,
		header = content:FindFirstChild("Header"), chartTitle = chartFrame:FindFirstChild("Title"),
		timestamp = content:FindFirstChild("Timestamp"), descriptor = callbacks.descriptor, nativeConfig = callbacks.nativeConfig,
		chartSpeed = chartFrame:FindFirstChild("Speed"), saved = {}, masked = {}, gapHidden = {}, connections = {}, panelText = {},
		buttons = {}, seeks = 0, destroyed = false,
		state = { playing = false, rate = 6, tick = 1, selectedLane = 1, totalTicks = 1 } }, Adapter)
	assert(self.header and self.chartTitle and self.timestamp, "SpringArrayPresentation: retained headings missing")
	for _, child in panel:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then table.insert(self.panelText, child) end
	end
	local function make(class, parent, properties)
		local object = env.Instance.new(class)
		for property, value in properties do object[property] = value end
		object.Parent = parent
		return object
	end
	local function connect(signal, fn)
		table.insert(self.connections, signal:Connect(function(...)
			if not self.destroyed then fn(...) end
		end))
	end
	local ok, failure = pcall(function()
		local brand = content:FindFirstChild("Brand")
		if brand then self:_set(brand, "Text", "ROALGO · PHYSICS SIGNAL ENGINE") end
		oldControl:Invoke("pause")
		self.controls = make("Frame", content, { Name = "ArrayPresentationControls", BackgroundTransparency = 1,
			BorderSizePixel = 0, Position = env.UDim2.fromOffset(0, 0), Size = env.UDim2.new(1, 0, 0, 590), ZIndex = 3 })
		local function button(name, text, originalName, position, size, action)
			local original = assert(content:FindFirstChild(originalName), "Missing retained button " .. originalName)
			local properties = { Name = name, Text = text, Position = position or original.Position,
				Size = size or original.Size, Visible = true, ZIndex = 4 }
			for _, property in { "BackgroundColor3", "BackgroundTransparency", "TextColor3", "TextSize", "Font",
				"BorderSizePixel", "AutoButtonColor", "TextTruncate" } do properties[property] = original[property] end
			local item = make("TextButton", self.controls, properties)
			make("UICorner", item, { CornerRadius = env.UDim.new(0, 5) })
			connect(item.MouseButton1Click, action)
			self.buttons[name] = item
			return item
		end
		local function toggle() callbacks.play(not self.state.playing) end
		button("Play", "Run", "PlayPause", env.UDim2.fromOffset(12, 118), env.UDim2.fromOffset(136, 28), toggle)
		button("Layer", "Layer 1 / 8", "Previous", env.UDim2.fromOffset(154, 118), env.UDim2.fromOffset(170, 28), function()
			callbacks.lane(self.state.selectedLane % (self.state.laneCount or 8) + 1)
		end)
		local function textLabel(parent, name, text, y, size)
			return make("TextLabel", parent, { Name = name, Text = text, Position = env.UDim2.fromOffset(12, y),
				Size = env.UDim2.fromOffset(416, 17), BackgroundTransparency = 1, TextColor3 = self.header.TextColor3,
				Font = self.header.Font, TextSize = size or 11, TextXAlignment = env.Enum.TextXAlignment.Left, ZIndex = 4 })
		end
		textLabel(self.controls, "Market", "S&P 500 · SPY · 2025–2026 TEST DATA", 54, 14)
		self.rowCounter = textLabel(self.controls, "RowCounter", "Row —", 151, 11)
		local originalTrack = content:FindFirstChild("ScrubTrack")
		self.rowTrack = make("TextButton", self.controls, { Name = "RowScrubber", Text = "", AutoButtonColor = false,
			Position = env.UDim2.fromOffset(12, 174), Size = env.UDim2.fromOffset(416, 12),
			BackgroundColor3 = originalTrack.BackgroundColor3, BorderSizePixel = 0, ZIndex = 4 })
		self.rowFill = make("Frame", self.rowTrack, { Name = "Fill", Size = env.UDim2.new(0, 0, 1, 0),
			BackgroundColor3 = content.PlayPause.BackgroundColor3, BorderSizePixel = 0, ZIndex = 5 })
		local dragging = false
		local function scrub(x)
			if self.rowTrack.AbsoluteSize.X <= 0 then return end
			callbacks.play(false)
			local fraction = math.clamp((x - self.rowTrack.AbsolutePosition.X) / self.rowTrack.AbsoluteSize.X, 0, 1)
			callbacks.seekRow(1 + math.floor(fraction * math.max((self.state.loadedRows or self.state.totalRows or 1) - 1, 0) + 0.5))
		end
		connect(self.rowTrack.MouseButton1Down, function(x) dragging = true; scrub(x) end)
		connect(self.rowTrack.MouseMoved, function(x) if dragging then scrub(x) end end)
		connect(self.rowTrack.MouseButton1Up, function() dragging = false end)
		connect(self.rowTrack.MouseLeave, function() dragging = false end)
		self:_set(self.timestamp, "Position", env.UDim2.fromOffset(12, 78))
		self.confidenceNote = textLabel(self.controls, "ConfidenceMeaning", "Signed signal index · not a probability", 193, 11)
		local score = content:FindFirstChild("Score")
		if score then self:_set(score, "Size", env.UDim2.fromOffset(416, 20)) end
		self.telemetryFrame = make("Frame", self.controls, { Name = "Telemetry", BackgroundTransparency = 1,
			BorderSizePixel = 0, Position = env.UDim2.fromOffset(0, 312), Size = env.UDim2.fromOffset(440, 260), ZIndex = 4 })
		self.telemetryLabels = {}
		for _, row in {
			{ "Heading", "SPRING TELEMETRY · COUPLED", 0, 11 }, { "Topology", "", 18 }, { "Active", "", 36 },
			{ "Displacement", "", 54 }, { "Speed", "", 72 }, { "Banks", "", 90 }, { "Slow", "", 108 },
			{ "Stretch", "", 126 }, { "StretchMeaning", "L = endpoint distance; L0 = free length (includes prestretch)", 144, 10 },
			{ "IndependentHeading", "INDEPENDENT SPRINGS", 168, 11 }, { "IndependentX", "", 186 },
			{ "IndependentActive", "", 204, 10 }, { "IndependentSpeed", "", 222 }, { "Difference", "", 240, 10 },
		} do self.telemetryLabels[row[1]] = textLabel(self.telemetryFrame, row[1], row[2], row[3], row[4]) end
		self.settling = make("TextLabel", self.controls, { Name = "Gap", Text = "Settling", Visible = false,
			Position = env.UDim2.fromOffset(12, 78), Size = env.UDim2.fromOffset(416, 30), BackgroundTransparency = 1,
			TextColor3 = self.header.TextColor3, Font = self.header.Font, TextSize = 12,
			TextXAlignment = env.Enum.TextXAlignment.Left, ZIndex = 4 })
		self:_set(panel, "Enabled", true)
		self:_set(chart, "Enabled", true)
		self:_clean()
	end)
	if not ok then self:destroy(); error(failure, 2) end
	return self
end

return Presentation
