local Presentation = require("../src/SpringArrayPresentation")
local Frozen = require("../src/SpringFrozenV1")
local function near(a, b) assert(math.abs(a - b) < 1e-10, string.format("%.17g ~= %.17g", a, b)) end
local function sample(rowIndex)
	return { phase = "recorded", rowIndex = rowIndex, label = "2025-01-06 09:35",
		coupled = table.create(51, 0), independent = table.create(51, 0) }
end

local measured = sample(411)
measured.coupled[1], measured.coupled[2], measured.coupled[3], measured.coupled[4] = 2 / 64, -1 / 64, 1 / 64, -3 / 64
measured.coupled[25] = 1 / (64 * Frozen.descriptor.nodes[1].omega)
measured.coupled[26] = -2 / (64 * Frozen.descriptor.nodes[2].omega)
local telemetry = Presentation.telemetry(measured, Frozen.descriptor, Frozen.nativeConfig2024)
near(telemetry.coupled.meanX, -1 / 24)
near(telemetry.coupled.rmsX, math.sqrt(15 / 24))
near(telemetry.coupled.peakX, 3)
near(telemetry.coupled.meanSpeed, 3 / 24)
near(telemetry.coupled.peakSpeed, 2)
near(telemetry.coupled.bankMeanX[1], -1 / 8)
near(telemetry.coupled.bankMeanX[2], 0)
near(telemetry.coupled.normalizedRmsX, math.sqrt(15 / 24) / 64)
assert(telemetry.coupled.active == 2 and telemetry.coupled.positive == 2 and telemetry.coupled.negative == 2 and telemetry.coupled.zero == 20)
assert(telemetry.nodeCount == 24 and telemetry.couplingLinks == 37 and telemetry.axialLinks == 24 and telemetry.activeThresholdStuds == 1)
local translation = sample(412)
for i = 1, 24 do translation.coupled[i] = 2 / 64 end
local translated = Presentation.telemetry(translation, Frozen.descriptor, Frozen.nativeConfig2024)
near(translated.couplingStretchRms, 64) -- 256-stud rest separation minus 192-stud free length; translation preserves it.
near(translated.differenceRms, 2)
near(translated.coupled.bankMeanX[3], 2)
local corner = sample(413)
corner.coupled[1] = 10 / 64
local edgeStretch = math.sqrt(256 * 256 + 10 * 10) - 192
near(Presentation.telemetry(corner, Frozen.descriptor, Frozen.nativeConfig2024).couplingStretchRms,
	math.sqrt((2 * edgeStretch ^ 2 + 35 * 64 ^ 2) / 37)) -- Corner node has exactly two incident links.
assert(not pcall(function() Presentation.telemetry({ phase = "warmup" }, Frozen.descriptor, Frozen.nativeConfig2024) end))
print("PASS exact physical units, signed displacement, active threshold and coupling geometry")
local function signal()
	local s = { listeners = {} }
	function s:Connect(fn)
		local c = { Connected = true }
		function c:Disconnect() self.Connected = false end
		table.insert(self.listeners, { fn = fn, c = c })
		return c
	end
	function s:Fire(...)
		for _, entry in self.listeners do if entry.c.Connected then entry.fn(...) end end
	end
	return s
end
local function dim(xs, xo, ys, yo) return { X = { Scale = xs, Offset = xo }, Y = { Scale = ys, Offset = yo } } end
local methods, meta = {}, {}
meta.__index = function(self, key)
	if methods[key] then return methods[key] end
	if self.props[key] ~= nil then return self.props[key] end
	for _, child in self.children do if child.Name == key then return child end end
	return nil
end
meta.__newindex = function(self, key, value)
	if key == "Parent" then
		local old = self.props.Parent
		if old then for i, child in old.children do if child == self then table.remove(old.children, i); break end end end
		if value then table.insert(value.children, self) end
	end
	self.props[key] = value
end
function methods:FindFirstChild(name) for _, child in self.children do if child.Name == name then return child end end return nil end
function methods:GetChildren() return table.clone(self.children) end
function methods:GetDescendants()
	local all = {}
	for _, child in self.children do
		table.insert(all, child)
		for _, descendant in child:GetDescendants() do table.insert(all, descendant) end
	end
	return all
end
function methods:IsA(class)
	return self.ClassName == class or (class == "GuiObject" and
		(self.ClassName == "Frame" or self.ClassName == "TextLabel" or self.ClassName == "TextButton" or self.ClassName == "TextBox"))
end
function methods:IsDescendantOf(ancestor)
	local parent = self.Parent
	while parent do if parent == ancestor then return true end parent = parent.Parent end
	return false
end
function methods:GetAttribute(name) return self.attributes[name] end
function methods:SetAttribute(name, value) self.attributes[name] = value end
function methods:Destroy() for _, child in self:GetChildren() do child:Destroy() end self.Parent = nil end
local function object(class, name, parent, y)
	local properties = { ClassName = class, Name = name or class, Visible = true, Enabled = false,
		Text = "initial " .. (name or class), Position = dim(0, 12, 0, y or 0), Size = dim(0, 62, 0, 24),
		BackgroundColor3 = "bg", TextColor3 = "text", Font = "font", TextSize = 11, TextTruncate = "end",
		BackgroundTransparency = 0, AutoButtonColor = true, BorderSizePixel = 0, AbsoluteSize = { X = 416 }, AbsolutePosition = { X = 12 } }
	for _, event in { "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseMoved", "MouseLeave" } do properties[event] = signal() end
	local result = setmetatable({ props = properties, children = {}, attributes = {} }, meta)
	result.Parent = parent
	return result
end
local env = { Instance = { new = function(class) return object(class) end }, UDim2 = { new = dim,
	fromOffset = function(x, y) return dim(0, x, 0, y) end }, UDim = { new = function(s, o) return { Scale = s, Offset = o } end },
	Enum = { TextXAlignment = { Left = "left" } } }
local function fixture()
	local core = object("Folder", "Core")
	local panel, chart = object("ScreenGui", "RoAlgoSpringPanel", core), object("ScreenGui", "RoAlgoSpringChart", core)
	local content = object("Frame", "Content", object("Frame", "Dock", panel))
	local frame = object("Frame", "Chart", chart)
	object("TextLabel", "Title", frame)
	object("Frame", "Speed", frame)
	object("TextLabel", "Readout", frame).Text = "2025-01-06 09:35 · close 590.12"
	for _, name in { "Previous", "PlayPause", "Next", "Exit", "ScrubTrack", "Run_coupled" } do object("TextButton", name, content, 166) end
	for _, name in { "Header", "Provenance", "Status", "CompareHeader", "RunCaption", "Timestamp", "Partition", "RowCounter" } do object("TextLabel", name, content, 70) end
	object("TextBox", "GoTo", content, 166)
	object("TextLabel", "Score", content, 214).Text = "SCORE -0.02"
	object("Frame", "ScoreBar", content, 250)
	object("Frame", "BankBar1", content, 266)
	for _, name in { "ContributionCaption", "PolicyCaption", "PolicyCounters", "Intent", "Position", "Fill3" } do
		object("TextLabel", name, content, 312).Text = "old strategy detail"
	end
	object("TextLabel", "Evidence", content, 583).Text = "capture provenance"
	local original = {}
	for _, item in core:GetDescendants() do original[item] = table.clone(item.props) end
	local calls, seeks, control = {}, {}, {}
	function control:Invoke(command, value)
		table.insert(calls, { command, value })
		if command == "seek" then
			table.insert(seeks, value)
			panel:SetAttribute("RowIndex", value); chart:SetAttribute("Index", value)
			content.Header.Text = "LIVE CAPTURE · " .. value
			frame.Title.Text = "SPY · RECORDED"
		end
	end
	local actions = {}
	local callbacks = { env = env, descriptor = Frozen.descriptor, nativeConfig = Frozen.nativeConfig2024 }
	for _, name in { "play", "seek", "seekRow", "lane", "rate" } do callbacks[name] = function(value) table.insert(actions, { name, value }) end end
	local view = Presentation.mount(core, control, callbacks)
	local state = { tick = 15, totalTicks = 100, loadedRows = 1001, selectedLane = 7, rate = 6, playing = false }
	return { view = view, panel = panel, chart = chart, content = content, frame = frame, seeks = seeks, calls = calls,
		actions = actions, state = state, original = original, core = core }
end
local f = fixture()
assert(f.calls[1][1] == "pause" and f.panel.Enabled and f.chart.Enabled)
f.view:update(measured, f.state)
f.view:update(measured, f.state)
assert(#f.seeks == 1 and f.seeks[1] == 411, "play/rate updates must not reseek")
assert(f.content.Header.Text == "SPRING CLUSTER · LAYER 7 · COUPLED")
assert(f.frame.Title.Text == "SPY 5-MIN · COUPLED" and f.frame.Readout.Text == "2025-01-06 09:35 · close 590.12")
assert(not f.content.Previous.Visible and not f.content.Run_coupled.Visible and not f.frame.Speed.Visible)
assert(not f.content.Provenance.Visible and not f.content.Evidence.Visible and f.content.Score.Text == "CONFIDENCE -0.02")
assert(f.content.ScoreBar.Visible and f.content.BankBar1.Visible, "confidence and bank bars must retain their data")
assert(f.view.confidenceNote.Text == "Signed signal index · not a probability")
assert(f.content.Timestamp.Text == measured.label and f.content.Timestamp.Visible)
assert(f.view.controls:FindFirstChild("Market").Text == "S&P 500 · SPY · 2025–2026 TEST DATA")
assert(f.view.telemetryLabels.Active.Text == "Active 2 / 24 (|x| > 1 stud) · +2 / −2 / zero 20")
assert(f.view.telemetryLabels.Speed.Text == "Mean speed 0.125 · peak speed 2.000 studs/s")
for _, name in { "ContributionCaption", "PolicyCaption", "PolicyCounters", "Intent", "Position", "Fill3" } do
	assert(not f.content:FindFirstChild(name).Visible, "stale strategy field remained visible: " .. name)
end
print("PASS retained historical data and chart with one changed-row seek")

f.view:update({ phase = "warmup" }, f.state)
assert(#f.seeks == 1 and not f.chart.Enabled and not f.content.Score.Visible and not f.content.Timestamp.Visible)
assert(f.view.controls.Visible and f.view.buttons.Play.Visible and f.view.buttons.Layer.Visible and f.view.settling.Visible)
assert(not f.view.telemetryFrame.Visible and not f.view.confidenceNote.Visible and f.view:stats().telemetry == nil)
f.view:update({ phase = "idle" }, f.state)
assert(f.view.settling.Text == "Finished" and #f.seeks == 1)
f.view:update(translation, f.state)
assert(f.chart.Enabled and f.content.Score.Visible and f.content.Timestamp.Visible and not f.view.settling.Visible)
assert(not f.content.Status.Visible and not f.content.CompareHeader.Visible)
assert(f.view.telemetryFrame.Visible and f.view.confidenceNote.Visible)
print("PASS gaps hide stale data while all controls survive and data returns")

f.view.buttons.Play.MouseButton1Click:Fire()
f.view.buttons.Layer.MouseButton1Click:Fire()
assert(f.actions[1][1] == "play" and f.actions[1][2] == true)
assert(f.actions[2][1] == "lane" and f.actions[2][2] == 8)
for _, name in { "Previous", "Next", "Speed", "Toggle", "Timeline" } do assert(not f.view.controls:FindFirstChild(name)) end
assert(f.view.buttons.Play.Text == "Run")
f.state.playing = true
f.view:update(translation, f.state)
assert(f.view.buttons.Play.Text == "Pause")
f.view.buttons.Play.MouseButton1Click:Fire()
assert(f.actions[3][1] == "play" and f.actions[3][2] == false and #f.actions == 3)
assert(#f.seeks == 2, "new transport must not invoke retained playback")
print("PASS only Run/Pause and layer controls exist and route to the host clock")

assert(f.view.rowCounter.Text == "Row 412 / 1001")
f.view.rowTrack.MouseButton1Down:Fire(12)
f.view.rowTrack.MouseMoved:Fire(220)
f.view.rowTrack.MouseMoved:Fire(500)
f.view.rowTrack.MouseButton1Up:Fire()
local countAfterDrag = #f.actions
f.view.rowTrack.MouseMoved:Fire(30)
assert(#f.actions == countAfterDrag and #f.actions == 9)
assert(f.actions[4][1] == "play" and f.actions[4][2] == false and f.actions[5][1] == "seekRow" and f.actions[5][2] == 1)
assert(f.actions[7][1] == "seekRow" and f.actions[7][2] == 501)
assert(f.actions[9][1] == "seekRow" and f.actions[9][2] == 1001)
assert(#f.seeks == 2, "row scrub must use the host mapping, not retained viewer seek")
print("PASS row scrub pauses and maps the full chronological row range")

local invalid = sample(999)
invalid.coupled[25] = 0 / 0
assert(not pcall(function() f.view:update(invalid, f.state) end))
assert(#f.seeks == 2 and f.panel:GetAttribute("RowIndex") == 412, "invalid telemetry changed retained cursor")
print("PASS invalid telemetry is rejected before any retained-cursor change")

f.chart:SetAttribute("Index", -1)
assert(not pcall(function() f.view:update(translation, f.state) end), "stale chart must be rejected")
print("PASS stale panel/chart row receipt is rejected")

local oldPlay = f.view.buttons.Play
local actionCount = #f.actions
f.view:destroy(); f.view:destroy()
assert(not f.content:FindFirstChild("ArrayPresentationControls") and not f.panel.Enabled and not f.chart.Enabled)
for _, name in { "Previous", "PlayPause", "Next", "Exit", "GoTo", "ScrubTrack", "Run_coupled", "Provenance", "Status", "CompareHeader", "Evidence", "Score", "Timestamp" } do
	assert(f.content:FindFirstChild(name).Visible == f.original[f.content:FindFirstChild(name)].Visible, "did not restore " .. name)
end
assert(f.content.Header.Text == f.original[f.content.Header].Text and f.frame.Title.Text == f.original[f.frame.Title].Text)
assert(f.content.RunCaption.Text == f.original[f.content.RunCaption].Text and f.frame.Speed.Visible)
assert(f.content.Score.Text == f.original[f.content.Score].Text and f.content.Score.Size == f.original[f.content.Score].Size)
assert(f.content.Timestamp.Text == f.original[f.content.Timestamp].Text and f.content.Timestamp.Position == f.original[f.content.Timestamp].Position)
oldPlay.MouseButton1Click:Fire()
assert(#f.actions == actionCount, "destroyed controls kept callbacks")
print("PASS cleanup restores original GUI properties and disconnects callbacks")
print("SpringArrayPresentation: 8 behavioral groups passed")
