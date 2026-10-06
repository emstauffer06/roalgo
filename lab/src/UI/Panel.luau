-- Lab status panel (plan Task 8). ENGINE CODE. Presentation only: nothing here feeds back into physics.
local HttpService = game:GetService("HttpService")

local Panel = {}
Panel.__index = Panel

function Panel.new(plugin: Plugin, state: any)
	local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 360, 420, 300, 240)
	local widget = plugin:CreateDockWidgetPluginGui("MarketReservoirLabPanel", info)
	widget.Title = "Market Reservoir Lab"
	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.BackgroundColor3 = Color3.fromRGB(24, 26, 31)
	scroll.BorderSizePixel = 0
	scroll.Parent = widget
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -16, 0, 0)
	label.Position = UDim2.fromOffset(8, 8)
	label.AutomaticSize = Enum.AutomaticSize.Y
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.fromRGB(225, 228, 232)
	label.Font = Enum.Font.RobotoMono
	label.TextSize = 13
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Parent = scroll
	local self = setmetatable({ widget = widget, label = label, state = state }, Panel)
	self:refresh()
	return self
end

function Panel:toggle()
	self.widget.Enabled = not self.widget.Enabled
	self:refresh()
end

function Panel:refresh()
	local lines = { "MARKET RESERVOIR LAB", "build " .. tostring(self.state.buildInfo) }
	local probe = self.state.loadProbe
	if probe then
		table.insert(lines, "")
		table.insert(lines, "StepPhysics probe (" .. tostring(probe.context) .. ")")
		if probe.sync then
			table.insert(lines, "synchronous exact: " .. tostring(probe.sync.synchronousExact))
		end
		if probe.reservoir then
			table.insert(lines, string.format("24-node reservoir: %.1f bars/s", probe.reservoir.barsPerSecond))
		end
		if probe.error then
			table.insert(lines, "error: " .. tostring(probe.error))
		end
	else
		table.insert(lines, "capability probe pending")
	end
	if self.state.status then
		table.insert(lines, "")
		table.insert(lines, HttpService:JSONEncode(self.state.status))
	end
	self.label.Text = table.concat(lines, "\n")
end

return Panel
